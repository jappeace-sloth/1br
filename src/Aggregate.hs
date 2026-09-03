{-# LANGUAGE BangPatterns #-}

-- | One billion row challenge: aggregate min\/mean\/max temperature per
-- weather station from a @name;temp@ text file.
--
-- Decision: the hot path works on raw 'Ptr' 'Word8' from an mmap of the
-- whole file, split into one chunk per capability, each chunk feeding a
-- private open-addressing hash table of unboxed 'Int' fields. Alternatives
-- considered: lazy 'ByteString' chunking with 'Data.Map' (measured orders
-- of magnitude too slow for the 1.5s target), conduit\/streaming (same
-- problem), a shared concurrent table (contention, needs atomics). Private
-- tables merge in microseconds because there are at most 10 000 stations.
module Aggregate
  ( main
  , processFile
  ) where

import Control.Concurrent (forkIO, getNumCapabilities)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Monad (foldM, forM, when)
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Bits
    (complement, countTrailingZeros, shiftL, shiftR, unsafeShiftL,
    unsafeShiftR, xor, (.&.), (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List (intersperse)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Primitive.PrimArray
    (MutablePrimArray, newPrimArray, readPrimArray, setPrimArray,
    writePrimArray)
import Data.Word (Word64, Word8)
import Foreign.C.Types (CInt (..), CSize (..))
import Foreign.Marshal.Alloc (free, mallocBytes)
import Foreign.Marshal.Utils (copyBytes, fillBytes)
import Foreign.Ptr (Ptr, castPtr, plusPtr)
import Foreign.Storable (peekByteOff)
import GHC.Exts (RealWorld)
import System.Environment (getArgs)
import System.Exit (die)
import System.IO.MMap (Mode (ReadOnly), mmapFilePtr)

foreign import ccall unsafe "string.h memcmp"
  c_memcmp :: Ptr Word8 -> Ptr Word8 -> CSize -> IO CInt

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    [] -> ByteString.putStr =<< processFile "measurements.txt"
    [path] -> ByteString.putStr =<< processFile path
    _ -> die "usage: exe [measurements.txt]"

-- | Run the whole pipeline on one file and return the formatted report,
-- e.g. @{Abha=-23.0\/18.0\/59.2, Adamstown=...}\\n@.
processFile :: FilePath -> IO ByteString
processFile path = do
  (rawPtr, _rawSize, dataOffset, dataSize) <-
    mmapFilePtr path ReadOnly Nothing
  let filePtr = rawPtr `plusPtr` dataOffset
  if dataSize == 0
    then pure "{}\n"
    else do
      -- Parser invariant, not pedantry: chunk alignment scans forward
      -- for the next newline and the tail loop trusts that one exists,
      -- so a file without a final newline would walk past the end of
      -- the data. The challenge guarantees newline-terminated rows;
      -- anything else is malformed input and fails loudly here.
      lastByte <- peekByteAt filePtr (dataSize - 1)
      when (lastByte /= newlineByte) $
        die (path <> ": missing trailing newline, refusing to parse")
      perStation <- aggregateMapped filePtr dataSize
      pure
        (LazyByteString.toStrict
          (Builder.toLazyByteString (formatReport perStation)))

-- | Aggregate a non-empty mapped file: fan the safe region out over all
-- capabilities and run the final bytes through a zero-padded copy.
--
-- Decision: workers pull chunks from a shared counter instead of getting
-- one fixed chunk each. With a static split one delayed core (the host
-- runs other work too) stretches the whole wall time; with
-- 'chunksPerWorker' times more chunks the fast cores absorb the
-- difference. The counter is a single atomic fetch-add per chunk, so
-- contention is immaterial.
aggregateMapped :: Ptr Word8 -> Int -> IO (Map ByteString StationStats)
aggregateMapped filePtr dataSize = do
  mainEnd <- findMainEnd filePtr dataSize
  workerCount <- getNumCapabilities
  let ranges = chunkRanges mainEnd (workerCount * chunksPerWorker)
  nextChunk <- newIORef 0
  resultVars <- forM [1 .. workerCount] $ \_workerIndex -> do
    resultVar <- newEmptyMVar
    _ <- forkIO $ do
      table <- newTable
      workLoop filePtr table nextChunk ranges
      putMVar resultVar table
    pure resultVar
  (tailBuffer, tailTable) <- processTail filePtr mainEnd dataSize
  mainTables <- forM resultVars $ \resultVar -> do
    table <- takeMVar resultVar
    pure (filePtr, table)
  merged <- mergeTables ((tailBuffer, tailTable) : mainTables)
  free tailBuffer
  pure merged

-- | Enough slack for work stealing without shrinking chunks to where
-- per-chunk overhead (claiming, boundary alignment) shows up. Measured
-- against 1 (static split, stragglers under host load) and 8 (no
-- further gain) on the billion-row file.
chunksPerWorker :: Int
chunksPerWorker = 4

-- | Claim and process chunks until the shared counter runs off the end
-- of the range list.
workLoop
  :: Ptr Word8 -> WorkerTable -> IORef Int -> [(Int, Int)] -> IO ()
workLoop filePtr table nextChunk ranges = do
  claimed <- atomicModifyIORef' nextChunk (\index -> (index + 1, index))
  case drop claimed ranges of
    [] -> pure ()
    ((start, end) : _) -> do
      consumeLines filePtr table start end
      workLoop filePtr table nextChunk ranges

-- | End of the region that may be parsed straight from the mmap. The
-- parser reads up to 16 bytes ahead of a line start, so lines too close
-- to the end of the file must not be parsed in place: when the file size
-- is a multiple of the page size an overread past the last byte hits
-- unmapped memory and crashes. Everything from the returned offset on is
-- handled by 'processTail' via a padded copy instead. Returns 0 (whole
-- file is tail) when the file is small or contains no safely-parsable
-- prefix.
findMainEnd :: Ptr Word8 -> Int -> IO Int
findMainEnd filePtr dataSize =
  if dataSize <= tailSlack
    then pure 0
    else do
      lastSafeNewline <- scanNewlineBackward filePtr (dataSize - tailSlack)
      case lastSafeNewline of
        Nothing -> pure 0
        Just newlineIndex -> pure (newlineIndex + 1)

-- | How many bytes before the end of the file we stop parsing in place.
-- Must exceed the parser's maximum overread (16 bytes) plus the longest
-- suffix a line can put after its name start reads (name word reads only
-- happen at indices below the line's semicolon, so 33 is comfortably
-- conservative).
tailSlack :: Int
tailSlack = 33

scanNewlineBackward :: Ptr Word8 -> Int -> IO (Maybe Int)
scanNewlineBackward filePtr index =
  if index < 0
    then pure Nothing
    else do
      byte <- peekByteAt filePtr index
      if byte == newlineByte
        then pure (Just index)
        else scanNewlineBackward filePtr (index - 1)

-- | Parse the file tail through a zero-padded private copy, so the
-- 16-byte-ahead reads land in our own buffer instead of past the mapping.
-- The returned table's name offsets point into that copy, hence the
-- buffer pointer is returned alongside and freed only after merging.
processTail :: Ptr Word8 -> Int -> Int -> IO (Ptr Word8, WorkerTable)
processTail filePtr mainEnd dataSize = do
  let tailLength = dataSize - mainEnd
  tailBuffer <- mallocBytes (tailLength + overreadPadding)
  copyBytes tailBuffer (filePtr `plusPtr` mainEnd) tailLength
  fillBytes (tailBuffer `plusPtr` tailLength) 0 overreadPadding
  table <- newTable
  consumeLines tailBuffer table 0 tailLength
  pure (tailBuffer, table)

overreadPadding :: Int
overreadPadding = 32

-- | Split @[0, mainEnd)@ into roughly equal per-worker ranges, each
-- starting right after a newline so every worker sees whole lines.
chunkRanges :: Int -> Int -> [(Int, Int)]
chunkRanges mainEnd workerCount =
  fmap
    (\index ->
      ( mainEnd * index `div` workerCount
      , mainEnd * (index + 1) `div` workerCount))
    [0 .. workerCount - 1]

-- The ranges above are raw byte splits; align them before use.
alignRange :: Ptr Word8 -> (Int, Int) -> IO (Int, Int)
alignRange filePtr (start, end) = do
  alignedStart <- alignToLineStart filePtr start
  alignedEnd <- alignToLineStart filePtr end
  pure (alignedStart, alignedEnd)

-- | Move an arbitrary offset forward to the nearest line start (offset 0
-- already is one; anything else advances past the next newline).
alignToLineStart :: Ptr Word8 -> Int -> IO Int
alignToLineStart filePtr index =
  if index == 0
    then pure 0
    else do
      byte <- peekByteAt filePtr (index - 1)
      if byte == newlineByte
        then pure index
        else alignToLineStart filePtr (index + 1)

-- ---------------------------------------------------------------------------
-- Per-worker hash table
-- ---------------------------------------------------------------------------

-- Decision: open addressing with linear probing over one flat PrimArray
-- of Int, instead of Data.HashMap or a boxed structure. The challenge
-- allows at most 10 000 distinct stations; at 65 536 slots the load
-- factor stays under 0.16, so probe chains are short and no resizing
-- logic is needed. All fields are machine Ints so the hot loop never
-- allocates, and one slot's eight fields
--
--   offset | length | word0 | word1 | min | max | sum | count
--
-- are exactly 64 bytes: key check and stats update touch a single cache
-- line (keys and stats as two separate arrays measurably cost a second
-- line per row). word0/word1 hold the first 16 name bytes (masked below
-- the semicolon) and double as both hash input and fast equality check:
-- names of at most 16 bytes never need a memcmp.
newtype WorkerTable = WorkerTable
  { tableSlots :: MutablePrimArray RealWorld Int
  }

slotCount :: Int
slotCount = 65536

slotMask :: Int
slotMask = slotCount - 1

fieldsPerSlot :: Int
fieldsPerSlot = 8

emptyOffset :: Int
emptyOffset = -1

newTable :: IO WorkerTable
newTable = do
  slots <- newPrimArray (slotCount * fieldsPerSlot)
  setPrimArray slots 0 (slotCount * fieldsPerSlot) emptyOffset
  pure (WorkerTable {tableSlots = slots})

-- ---------------------------------------------------------------------------
-- Hot loop
-- ---------------------------------------------------------------------------

-- | Parse and accumulate every line in @[start, end)@. @end@ must sit
-- right after a newline.
--
-- Decision: the range is split into four sub-ranges walked by four
-- interleaved cursors in one loop. A single line's work is one long
-- dependency chain (load name word, find the semicolon, hash, load the
-- slot, compare, update), so a single cursor leaves the core's
-- out-of-order machinery starved; independent chains overlap and
-- measurably raise instructions per cycle, the same trick the leading
-- Java entries use.
consumeLines :: Ptr Word8 -> WorkerTable -> Int -> Int -> IO ()
consumeLines filePtr table rawStart rawEnd = do
  (start, end) <- alignRange filePtr (rawStart, rawEnd)
  let quarter = (end - start) `div` 4
  splitA <- alignToLineStart filePtr (start + quarter)
  splitB <- alignToLineStart filePtr (start + 2 * quarter)
  splitC <- alignToLineStart filePtr (start + 3 * quarter)
  quadLineLoop filePtr table
    start splitA splitA splitB splitB splitC splitC end

-- | Advance four cursors through their own sub-ranges, one line each
-- per iteration. When any cursor exhausts its sub-range the remainders
-- finish in plain single-cursor loops.
quadLineLoop
  :: Ptr Word8 -> WorkerTable -> Int -> Int -> Int -> Int -> Int -> Int
  -> Int -> Int -> IO ()
quadLineLoop filePtr table !indexA !endA !indexB !endB !indexC !endC !indexD !endD =
  if indexA >= endA || indexB >= endB || indexC >= endC || indexD >= endD
    then do
      lineLoop filePtr table indexA endA
      lineLoop filePtr table indexB endB
      lineLoop filePtr table indexC endC
      lineLoop filePtr table indexD endD
    else do
      nextA <- stepLine filePtr table indexA
      nextB <- stepLine filePtr table indexB
      nextC <- stepLine filePtr table indexC
      nextD <- stepLine filePtr table indexD
      quadLineLoop filePtr table
        nextA endA nextB endB nextC endC nextD endD

lineLoop :: Ptr Word8 -> WorkerTable -> Int -> Int -> IO ()
lineLoop filePtr table !index !end =
  if index >= end
    then pure ()
    else do
      next <- stepLine filePtr table index
      lineLoop filePtr table next end

-- The next three functions are one conceptual step, parse one line and
-- fold it into the table, written in continuation style: each stage
-- passes its results onward as strict arguments instead of returning
-- tuples. Written as tuple-returning stages this allocated ~17 bytes per
-- line (measured with +RTS -s); in this shape it allocates nothing. The
-- one true return value, the next line's start offset, unboxes via CPR.
stepLine :: Ptr Word8 -> WorkerTable -> Int -> IO Int
{-# INLINE stepLine #-}
stepLine filePtr table !index = do
  -- Both name words load unconditionally and the semicolon position in
  -- them resolves arithmetically: whether a name is shorter or longer
  -- than eight bytes varies per station, so branching on it mispredicts
  -- constantly. countTrailingZeros of a zero match word is 64, making
  -- byteA/byteB equal 8 exactly when their word has no semicolon, which
  -- the mask arithmetic below exploits. Only names longer than 16 bytes
  -- take a branch, and real inputs almost never have them.
  wordA <- peekWord64 filePtr index
  wordB <- peekWord64 filePtr (index + 8)
  let matchA = semicolonMatches wordA
  let matchB = semicolonMatches wordB
  let byteA = countTrailingZeros matchA `unsafeShiftR` 3
  let byteB = countTrailingZeros matchB `unsafeShiftR` 3
  -- all-ones when wordA holds no semicolon, all-zeroes otherwise
  let missingA = nonZeroBit matchA - 1
  let nameLength = byteA + (byteB .&. missingA)
  let word0 = maskBelowByte byteA wordA
  let word1 = maskBelowByte (byteB .&. missingA) wordB
  if matchA .|. matchB == 0
    then do
      extraLength <- scanSemicolonByByte filePtr (index + 16) 0
      scanValue filePtr table index (16 + extraLength) wordA wordB
    else scanValue filePtr table index nameLength word0 word1

-- | 1 when the argument is non-zero, 0 when it is zero, without a
-- branch: for any non-zero x, @x .|. negate x@ has the top bit set.
nonZeroBit :: Word64 -> Int
{-# INLINE nonZeroBit #-}
nonZeroBit x = fromIntegral ((x .|. negate x) `unsafeShiftR` 63)

-- | Stage two: parse the temperature after the semicolon without a
-- single branch, from one eight-byte load.
--
-- Decision: this is the SWAR number parse from Quan Anh Mai's 1brc
-- solution (also used by most top entries). The temperature grammar is
-- exactly @-?d?d.d@, so byte 1, 2 or 3 of the load is the dot; the sign
-- and the dot position both come from bit 4, which is 0 for '-' (0x2d)
-- and '.' (0x2e) but 1 for every digit (0x3x). A branchy digit-by-digit
-- parse mispredicts on the sign (roughly a quarter of rows are negative)
-- and on the one-versus-two integer digits split; this version replaced
-- it for a measurable win.
scanValue
  :: Ptr Word8 -> WorkerTable -> Int -> Int -> Word64 -> Word64
  -> IO Int
{-# INLINE scanValue #-}
scanValue filePtr table !index !nameLength !word0 !word1 = do
  let valuePosition = index + nameLength + 1
  valueWord <- peekWord64 filePtr valuePosition
  -- all-ones when the first byte is '-', all-zeroes otherwise
  let signMask =
        fromIntegral
          (shiftR
            (shiftL (fromIntegral (complement valueWord) :: Int) 59)
            63) :: Word64
  -- zero out the '-' byte so only digit and dot bytes remain
  let unsignedWord = valueWord .&. complement (signMask .&. 0xFF)
  let dotBit = countTrailingZeros (complement valueWord .&. 0x10101000)
  -- line up hundreds/tens/units digits at fixed byte positions
  let digitsWord =
        unsafeShiftL unsignedWord (28 - dotBit) .&. 0x0F000F0F00
  -- one multiply gathers digits*100 + digits*10 + digits into bits 32..41
  let magnitude =
        fromIntegral (unsafeShiftR (digitsWord * 0x640A0001) 32 .&. 0x3FF)
  -- branchless negate: xor with -1 and subtract -1 is two's-complement
  -- negation, xor with 0 and subtract 0 is the identity
  let signedInt = fromIntegral signMask :: Int
  let value = (magnitude `xor` signedInt) - signedInt
  finishLine filePtr table index nameLength word0 word1
    value
    (valuePosition + unsafeShiftR dotBit 3 + 3)

-- | Stage three: record the measurement and hand back the next line
-- start. The overwhelmingly common case, the station already sitting in
-- its home slot, is checked inline here so the hot loop stays free of
-- function calls (GHC passes at most six unboxed arguments in registers;
-- calling the ten-argument prober on every line costs stack traffic).
-- Probe chains and inserts happen at most a few thousand times per run
-- and go through the out-of-line 'recordMeasurement'.
finishLine
  :: Ptr Word8 -> WorkerTable -> Int -> Int -> Word64 -> Word64
  -> Int -> Int -> IO Int
{-# INLINE finishLine #-}
finishLine filePtr table !index !nameLength !word0 !word1 !value !nextLine = do
  let slot = startSlot word0 word1
  let slotBase = slot * fieldsPerSlot
  storedLength <- readPrimArray (tableSlots table) (slotBase + 1)
  storedWord0 <- readPrimArray (tableSlots table) (slotBase + 2)
  storedWord1 <- readPrimArray (tableSlots table) (slotBase + 3)
  -- fold the three equality checks into one word so the hit test is a
  -- single well-predicted branch instead of three
  let keyDifference =
        (storedLength `xor` nameLength)
          .|. (storedWord0 `xor` fromIntegral word0)
          .|. (storedWord1 `xor` fromIntegral word1)
  if keyDifference == 0 && nameLength <= 16
    then updateStats (tableSlots table) slotBase value
    else
      recordMeasurement filePtr table index nameLength word0 word1
        slot 0 value
  pure nextLine

-- | SWAR trick: a byte of the result has its high bit set exactly where
-- the input word holds a semicolon.
semicolonMatches :: Word64 -> Word64
{-# INLINE semicolonMatches #-}
semicolonMatches word =
  let masked = word `xor` 0x3B3B3B3B3B3B3B3B
  in (masked - 0x0101010101010101)
       .&. complement masked
       .&. 0x8080808080808080

-- | Zero every byte at position @byteIndex@ (0-based, little endian) and
-- above, keeping only the bytes before the semicolon. Valid for
-- byteIndex 0 through 8 inclusive: each of the two shifts moves by
-- @32 - 4*byteIndex@, i.e. between 0 and 32 bits, so both stay well
-- inside unsafeShiftR's defined range (below 64) even at the
-- endpoints, where a single 64-bit shift would need a branch for the
-- shift-by-64 case (byteIndex 0 must produce an all-zero mask).
maskBelowByte :: Int -> Word64 -> Word64
{-# INLINE maskBelowByte #-}
maskBelowByte byteIndex word =
  word
    .&. (complement 0
           `unsafeShiftR` (32 - byteIndex `unsafeShiftL` 2)
           `unsafeShiftR` (32 - byteIndex `unsafeShiftL` 2))

-- | Byte-wise fallback for names longer than 16 bytes; returns the
-- number of bytes until (excluding) the semicolon.
scanSemicolonByByte :: Ptr Word8 -> Int -> Int -> IO Int
scanSemicolonByByte filePtr index !accumulated = do
  byte <- peekByteAt filePtr index
  if byte == semicolonByte
    then pure accumulated
    else scanSemicolonByByte filePtr (index + 1) (accumulated + 1)

-- | Multiply-xor hash of the first 16 name bytes, reduced to a slot.
-- Names sharing those 16 bytes hash alike; the probe loop's full
-- comparison keeps that correct, merely costing an extra probe.
startSlot :: Word64 -> Word64 -> Int
{-# INLINE startSlot #-}
startSlot word0 word1 =
  let mixed =
        (word0 * 0x9E3779B97F4A7C15) `xor` (word1 * 0xC2B2AE3D27D4EB4F)
      avalanched = mixed `xor` (mixed `shiftR` 29)
  in fromIntegral avalanched .&. slotMask

-- | Linear-probe for the station's slot and fold one measurement into it,
-- claiming an empty slot on first sight of the name. The probe counter
-- exists so an input with more distinct stations than slots crashes
-- loudly instead of spinning forever in a full table; the challenge caps
-- stations at 10 000, far below 'slotCount'.
recordMeasurement
  :: Ptr Word8
  -> WorkerTable
  -> Int
  -> Int
  -> Word64
  -> Word64
  -> Int
  -> Int
  -> Int
  -> IO ()
recordMeasurement filePtr table !nameOffset !nameLength !word0 !word1 !slot !probes !value = do
  when (probes > slotCount) $
    error "station table full: more distinct station names than slots"
  let slots = tableSlots table
  let slotBase = slot * fieldsPerSlot
  storedOffset <- readPrimArray slots slotBase
  if storedOffset == emptyOffset
    then do
      writePrimArray slots slotBase nameOffset
      writePrimArray slots (slotBase + 1) nameLength
      writePrimArray slots (slotBase + 2) (fromIntegral word0)
      writePrimArray slots (slotBase + 3) (fromIntegral word1)
      writePrimArray slots (slotBase + 4) value
      writePrimArray slots (slotBase + 5) value
      writePrimArray slots (slotBase + 6) value
      writePrimArray slots (slotBase + 7) 1
    else do
      storedLength <- readPrimArray slots (slotBase + 1)
      storedWord0 <- readPrimArray slots (slotBase + 2)
      storedWord1 <- readPrimArray slots (slotBase + 3)
      matches <-
        if storedLength == nameLength
             && storedWord0 == fromIntegral word0
             && storedWord1 == fromIntegral word1
          then
            if nameLength <= 16
              then pure True
              else longNamesEqual filePtr storedOffset nameOffset nameLength
          else pure False
      if matches
        then updateStats slots slotBase value
        else
          recordMeasurement
            filePtr
            table
            nameOffset
            nameLength
            word0
            word1
            ((slot + 1) .&. slotMask)
            (probes + 1)
            value

-- | Compare the bytes beyond the first 16 of two names living in the
-- same mapped region.
longNamesEqual :: Ptr Word8 -> Int -> Int -> Int -> IO Bool
{-# INLINE longNamesEqual #-}
longNamesEqual filePtr offsetA offsetB nameLength = do
  comparison <-
    c_memcmp
      (filePtr `plusPtr` (offsetA + 16))
      (filePtr `plusPtr` (offsetB + 16))
      (fromIntegral (nameLength - 16))
  pure (comparison == 0)

updateStats :: MutablePrimArray RealWorld Int -> Int -> Int -> IO ()
{-# INLINE updateStats #-}
updateStats slots slotBase value = do
  currentMin <- readPrimArray slots (slotBase + 4)
  when (value < currentMin) $ writePrimArray slots (slotBase + 4) value
  currentMax <- readPrimArray slots (slotBase + 5)
  when (value > currentMax) $ writePrimArray slots (slotBase + 5) value
  currentSum <- readPrimArray slots (slotBase + 6)
  writePrimArray slots (slotBase + 6) (currentSum + value)
  currentCount <- readPrimArray slots (slotBase + 7)
  writePrimArray slots (slotBase + 7) (currentCount + 1)

-- ---------------------------------------------------------------------------
-- Merge and format
-- ---------------------------------------------------------------------------

-- | Aggregated values for one station, all in signed tenths of a degree.
data StationStats = StationStats
  { statsMin   :: !Int
  , statsMax   :: !Int
  , statsSum   :: !Int
  , statsCount :: !Int
  }

combineStats :: StationStats -> StationStats -> StationStats
combineStats left right = StationStats
  { statsMin = min (statsMin left) (statsMin right)
  , statsMax = max (statsMax left) (statsMax right)
  , statsSum = statsSum left + statsSum right
  , statsCount = statsCount left + statsCount right
  }

-- | Fold every worker table into one sorted map, copying station names
-- out of the regions they point into (each table carries its own base
-- pointer: the mmap for main workers, the padded copy for the tail).
mergeTables :: [(Ptr Word8, WorkerTable)] -> IO (Map ByteString StationStats)
mergeTables = foldM mergeOneTable Map.empty

mergeOneTable
  :: Map ByteString StationStats
  -> (Ptr Word8, WorkerTable)
  -> IO (Map ByteString StationStats)
mergeOneTable startMap (basePtr, table) =
  foldM (mergeSlot basePtr table) startMap [0 .. slotCount - 1]

mergeSlot
  :: Ptr Word8
  -> WorkerTable
  -> Map ByteString StationStats
  -> Int
  -> IO (Map ByteString StationStats)
mergeSlot basePtr table accumulated slot = do
  let slotBase = slot * fieldsPerSlot
  nameOffset <- readPrimArray (tableSlots table) slotBase
  if nameOffset == emptyOffset
    then pure accumulated
    else do
      nameLength <- readPrimArray (tableSlots table) (slotBase + 1)
      name <-
        ByteString.packCStringLen
          (castPtr (basePtr `plusPtr` nameOffset), nameLength)
      slotMin <- readPrimArray (tableSlots table) (slotBase + 4)
      slotMax <- readPrimArray (tableSlots table) (slotBase + 5)
      slotSum <- readPrimArray (tableSlots table) (slotBase + 6)
      slotCount' <- readPrimArray (tableSlots table) (slotBase + 7)
      let stats = StationStats
            { statsMin = slotMin
            , statsMax = slotMax
            , statsSum = slotSum
            , statsCount = slotCount'
            }
      pure (Map.insertWith combineStats name stats accumulated)

formatReport :: Map ByteString StationStats -> Builder.Builder
formatReport perStation =
  Builder.char7 '{'
    <> mconcat
         (intersperse
           (Builder.byteString ", ")
           (fmap formatStation (Map.toAscList perStation)))
    <> Builder.byteString "}\n"

formatStation :: (ByteString, StationStats) -> Builder.Builder
formatStation (name, stats) =
  Builder.byteString name
    <> Builder.char7 '='
    <> tenthsBuilder (statsMin stats)
    <> Builder.char7 '/'
    <> tenthsBuilder (meanTenths stats)
    <> Builder.char7 '/'
    <> tenthsBuilder (statsMax stats)

-- | Round the mean to one decimal the way Java's @Math.round@ does:
-- half-up towards positive infinity, applied to the value expressed in
-- tenths. This matches the reference implementation's
-- @Math.round(value * 10.0) \/ 10.0@.
meanTenths :: StationStats -> Int
meanTenths stats =
  floor
    ((fromIntegral (statsSum stats) :: Double)
       / fromIntegral (statsCount stats)
       + 0.5)

tenthsBuilder :: Int -> Builder.Builder
tenthsBuilder tenths =
  if tenths < 0
    then Builder.char7 '-' <> tenthsBuilder (negate tenths)
    else
      Builder.intDec (tenths `div` 10)
        <> Builder.char7 '.'
        <> Builder.intDec (tenths `mod` 10)

-- ---------------------------------------------------------------------------
-- Byte-level helpers
-- ---------------------------------------------------------------------------

-- Decision: unaligned little-endian Word64 loads via peekByteOff. This
-- assumes a little-endian target (x86-64\/aarch64), which is where the
-- challenge is benchmarked; the byte-order dependence is confined to
-- 'scanName' and 'maskBelowByte'.
peekWord64 :: Ptr Word8 -> Int -> IO Word64
{-# INLINE peekWord64 #-}
peekWord64 = peekByteOff

peekByteAt :: Ptr Word8 -> Int -> IO Word8
{-# INLINE peekByteAt #-}
peekByteAt = peekByteOff

newlineByte :: Word8
newlineByte = 10

semicolonByte :: Word8
semicolonByte = 59

