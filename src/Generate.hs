{-# LANGUAGE BangPatterns #-}

-- | Measurement file generator for benchmarking 'Aggregate'. Mirrors the
-- official 1brc generator closely enough for performance work: it picks
-- uniformly among the 413 station names from @data/stations.txt@ and
-- draws each temperature from a rough bell curve around the station's
-- listed mean, one decimal, clamped to the challenge's [-99.9, 99.9].
module Generate
  ( main
  , generateFile
  ) where

import Data.Bits (shiftR, xor)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as ByteStringChar8
import Data.ByteString.Unsafe qualified as ByteStringUnsafe
import Data.Primitive.SmallArray
    (SmallArray, indexSmallArray, sizeofSmallArray, smallArrayFromList)
import Data.Word (Word64, Word8)
import Foreign.Marshal.Alloc (free, mallocBytes)
import Foreign.Marshal.Utils (copyBytes)
import Foreign.Ptr (Ptr, castPtr, plusPtr)
import Foreign.Storable (pokeByteOff)
import System.Environment (getArgs)
import System.Exit (die)
import System.IO (Handle, IOMode (WriteMode), hPutBuf, withBinaryFile)
import Text.Read (readMaybe)

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    [countText, path] ->
      case readMaybe countText of
        Nothing -> die ("not a row count: " <> countText)
        Just rowCount -> generateFile rowCount path
    _ -> die "usage: generate <row-count> <output-path>"

-- Decision: numeric conversions in this module use fromIntegral, not
-- the unwitch library. All of them are total in context (Word64 values
-- already reduced below the station count or below 1024, digits 0-9 to
-- Word8) and the generator deliberately shares the aggregator's
-- minimal dependency footprint.

-- | One station to draw measurements for: the rendered @Name;@ prefix and
-- its mean temperature in tenths.
data Station = Station
  { stationPrefix     :: !ByteString
  , stationMeanTenths :: !Int
  }

generateFile :: Int -> FilePath -> IO ()
generateFile rowCount path = do
  stations <- loadStations "data/stations.txt"
  withBinaryFile path WriteMode $ \handle -> do
    buffer <- mallocBytes bufferSize
    writeRows handle buffer stations rowCount randomSeed 0
    free buffer

loadStations :: FilePath -> IO (SmallArray Station)
loadStations path = do
  content <- ByteStringChar8.readFile path
  case traverse parseStation (ByteStringChar8.lines content) of
    Left parseError -> die (path <> ": " <> parseError)
    Right [] -> die (path <> ": no stations found")
    Right entries -> pure (smallArrayFromList entries)

parseStation :: ByteString -> Either String Station
parseStation line =
  case ByteStringChar8.split ';' line of
    [name, meanText] ->
      case parseMeanTenths meanText of
        Left meanError -> Left meanError
        Right tenths -> Right (Station
          { stationPrefix = ByteStringChar8.snoc name ';'
          , stationMeanTenths = tenths
          })
    _ -> Left ("malformed stations line: " <> ByteStringChar8.unpack line)

-- | Means in the station list are @-?d?d.d@; reuse of the tenths trick
-- from the aggregator keeps everything integral.
parseMeanTenths :: ByteString -> Either String Int
parseMeanTenths meanText =
  case readMaybe (ByteStringChar8.unpack (ByteStringChar8.filter (/= '.') meanText)) of
    Nothing -> Left ("malformed station mean: " <> ByteStringChar8.unpack meanText)
    Just tenths -> Right tenths

bufferSize :: Int
bufferSize = 1024 * 1024

-- | Longest row we can emit: 100 name bytes, semicolon, sign, three
-- digits and a dot, newline; rounded up generously.
maxRowBytes :: Int
maxRowBytes = 128

randomSeed :: Word64
randomSeed = 0x1BF52E61BADC0FFE

-- | splitmix64: the state hops by the golden gamma and the output is the
-- finalizer mix of the new state.
nextState :: Word64 -> Word64
{-# INLINE nextState #-}
nextState state = state + 0x9E3779B97F4A7C15

mixOutput :: Word64 -> Word64
{-# INLINE mixOutput #-}
mixOutput state =
  let mixedA = (state `xor` (state `shiftR` 30)) * 0xBF58476D1CE4E5B9
      mixedB = (mixedA `xor` (mixedA `shiftR` 27)) * 0x94D049BB133111EB
  in mixedB `xor` (mixedB `shiftR` 31)

writeRows
  :: Handle
  -> Ptr Word8
  -> SmallArray Station
  -> Int
  -> Word64
  -> Int
  -> IO ()
writeRows handle buffer stations !remaining !state !bufferUsed =
  if | remaining == 0 -> hPutBuf handle buffer bufferUsed
     | bufferUsed > bufferSize - maxRowBytes -> do
          hPutBuf handle buffer bufferUsed
          writeRows handle buffer stations remaining state 0
     | otherwise -> do
          let stateA = nextState state
          let stationCount = fromIntegral (sizeofSmallArray stations)
          let pick = mixOutput stateA `mod` stationCount
          let station = indexSmallArray stations (fromIntegral pick)
          let stateB = nextState stateA
          let temperature =
                temperatureTenths (stationMeanTenths station) (mixOutput stateB)
          rowEnd <- writeRow buffer bufferUsed station temperature
          writeRows handle buffer stations (remaining - 1) stateB rowEnd

-- | Sum of three uniform draws, centered: a cheap bell-ish spread of
-- roughly plus or minus 15 degrees around the station mean.
temperatureTenths :: Int -> Word64 -> Int
temperatureTenths meanTenths randomBits =
  let drawA = fromIntegral (randomBits `shiftR` 0 `mod` 1024)
      drawB = fromIntegral (randomBits `shiftR` 20 `mod` 1024)
      drawC = fromIntegral (randomBits `shiftR` 40 `mod` 1024)
      spread = (drawA + drawB + drawC - 1536) * 100 `div` 1024
  in clampTenths (meanTenths + spread)

clampTenths :: Int -> Int
clampTenths tenths = max (-999) (min 999 tenths)

writeRow :: Ptr Word8 -> Int -> Station -> Int -> IO Int
writeRow buffer offset station temperature = do
  afterName <- writePrefix buffer offset (stationPrefix station)
  afterValue <- writeTenths buffer afterName temperature
  pokeByteOff buffer afterValue (10 :: Word8)
  pure (afterValue + 1)

writePrefix :: Ptr Word8 -> Int -> ByteString -> IO Int
writePrefix buffer offset prefix =
  ByteStringUnsafe.unsafeUseAsCStringLen prefix $ \(source, sourceLength) -> do
    copyBytes (buffer `plusPtr` offset) (castPtr source) sourceLength
    pure (offset + sourceLength)

writeTenths :: Ptr Word8 -> Int -> Int -> IO Int
writeTenths buffer offset tenths =
  if tenths < 0
    then do
      pokeByteOff buffer offset (45 :: Word8)
      writeTenths buffer (offset + 1) (negate tenths)
    else do
      let whole = tenths `div` 10
      let fraction = tenths `mod` 10
      afterWhole <-
        if whole >= 10
          then do
            pokeByteOff buffer offset (digitByte (whole `div` 10))
            pokeByteOff buffer (offset + 1) (digitByte (whole `mod` 10))
            pure (offset + 2)
          else do
            pokeByteOff buffer offset (digitByte whole)
            pure (offset + 1)
      pokeByteOff buffer afterWhole (46 :: Word8)
      pokeByteOff buffer (afterWhole + 1) (digitByte fraction)
      pure (afterWhole + 2)

digitByte :: Int -> Word8
digitByte digit = fromIntegral (48 + digit)
