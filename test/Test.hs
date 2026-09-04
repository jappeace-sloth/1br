module Main where

import Aggregate qualified
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as ByteStringChar8
import Data.ByteString qualified as ByteString
import Data.Primitive.SmallArray (SmallArray)
import Generate qualified
import System.Directory (removeFile)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.IO (hClose, hSetBinaryMode)
import System.Process
    (CreateProcess (std_out), StdStream (CreatePipe), createProcess, proc,
    waitForProcess)
import Text.Read (readMaybe)
import Test.Tasty
import Test.Tasty.HUnit

main :: IO ()
main = do
  externalBinaries <- lookupExternalBinaries
  defaultMain (tests externalBinaries)

-- | The same suite runs against any number of external aggregator
-- binaries (the Rust port, the hand-optimized IR build): every binary
-- named by these environment variables faces the identical official
-- samples plus a cross-check against the Haskell aggregate of a
-- generated file. nix/ci.nix sets them, so CI always exercises the
-- Rust port; a bare `cabal test` without the variables runs the
-- Haskell-only suite.
lookupExternalBinaries :: IO [(String, FilePath)]
lookupExternalBinaries = do
  rustBinary <- lookupEnv "ONEBR_RUST_BIN"
  irBinary <- lookupEnv "ONEBR_RUST_LL_BIN"
  mhsBinary <- lookupEnv "ONEBR_MHS_BIN"
  pure
    (concatMap
      (\(label, found) -> maybe [] (\path -> [(label, path)]) found)
      [("rust", rustBinary), ("rust-ll", irBinary), ("mhs", mhsBinary)])

tests :: [(String, FilePath)] -> TestTree
tests externalBinaries = testGroup "1br"
  ( testGroup "official samples" (fmap sampleCase officialSamples)
  : testCase "generated file aggregates deterministically" generatorRoundTrip
  : fmap externalBinaryTests externalBinaries
  )

externalBinaryTests :: (String, FilePath) -> TestTree
externalBinaryTests (label, binary) = testGroup (label <> " binary")
  ( fmap (externalSampleCase binary) officialSamples
  <> [testCase "matches Haskell on a generated file"
       (externalGeneratedMatch label binary)]
  )

-- | Run an external aggregator binary and capture raw stdout bytes.
runAggregatorBinary :: FilePath -> FilePath -> IO ByteString
runAggregatorBinary binary input = do
  (_stdin, Just outHandle, _stderr, processHandle) <-
    createProcess (proc binary [input]) {std_out = CreatePipe}
  hSetBinaryMode outHandle True
  output <- ByteString.hGetContents outHandle
  exitCode <- waitForProcess processHandle
  hClose outHandle
  case exitCode of
    ExitSuccess -> pure output
    ExitFailure code ->
      error (binary <> " exited with " <> show code <> " on " <> input)

externalSampleCase :: FilePath -> String -> TestTree
externalSampleCase binary name = testCase name $ do
  expected <- ByteStringChar8.readFile ("test/samples/" <> name <> ".out")
  actual <- runAggregatorBinary binary ("test/samples/" <> name <> ".txt")
  assertEqual name expected actual

-- | The strongest cross-implementation check: both aggregators must
-- produce byte-identical reports for the same generated file.
-- | The temp file is per-label: tasty runs tests concurrently, and two
-- binaries sharing one generated file would race generation against
-- deletion.
externalGeneratedMatch :: String -> FilePath -> IO ()
externalGeneratedMatch label binary = do
  let path = "test-generated-" <> label <> ".txt"
  Generate.generateFile 10000 path
  haskellReport <- Aggregate.processFile path
  externalReport <- runAggregatorBinary binary path
  removeFile path
  assertEqual "reports identical" haskellReport externalReport

-- | Every sample pair shipped with the upstream 1brc repository: the
-- .out file is the exact output the reference Java implementation
-- produces for the .txt file, newline included. These cover rounding
-- semantics, boundary values, multi-byte UTF-8 names, names longer than
-- 16 bytes, and the 10 000 unique key stress case.
officialSamples :: [String]
officialSamples =
  [ "measurements-1"
  , "measurements-2"
  , "measurements-3"
  , "measurements-10"
  , "measurements-20"
  , "measurements-boundaries"
  , "measurements-complex-utf8"
  , "measurements-dot"
  , "measurements-rounding"
  , "measurements-short"
  , "measurements-shortest"
  , "measurements-10000-unique-keys"
  ]

sampleCase :: String -> TestTree
sampleCase name = testCase name $ do
  expected <- ByteStringChar8.readFile ("test/samples/" <> name <> ".out")
  actual <- Aggregate.processFile ("test/samples/" <> name <> ".txt")
  assertEqual name expected actual

-- | Run the real generator and the real aggregator against each other:
-- the aggregate of a generated file must be identical across two runs
-- (fixed seed, so also across machines), every station it mentions must
-- come from the station list the generator drew from, and every
-- aggregated minimum and maximum must respect the generator's clamp.
generatorRoundTrip :: IO ()
generatorRoundTrip = do
  let path = "test-generated-measurements.txt"
  Generate.generateFile 10000 path
  firstRun <- Aggregate.processFile path
  secondRun <- Aggregate.processFile path
  removeFile path
  assertEqual "deterministic" firstRun secondRun
  stationsFile <- ByteStringChar8.readFile "data/stations.txt"
  let knownNames = fmap nameOfStationLine (ByteStringChar8.lines stationsFile)
  mapM_ (assertKnownStation knownNames) (reportStationNames firstRun)
  stations <- Generate.loadStations "data/stations.txt"
  mapM_ (assertPlausibleStats stations) (reportEntryPairs firstRun)

-- | Each aggregated station must scatter around its listed mean: the
-- generator draws from a bell of roughly plus-minus 15 degrees, so with
-- a fixed seed and ~24 rows per station the sample mean sits well
-- within 5 degrees of the list mean, and min must lie strictly below
-- max. This is the check that catches a mean mis-parsed by a factor of
-- ten: the clamp then pins every draw to 99.9, collapsing min == max
-- and dragging the mean far from the listed one.
assertPlausibleStats :: SmallArray Generate.Station -> (ByteString, ByteString) -> IO ()
assertPlausibleStats stations (name, values) = do
  let listedTenths = listedMeanTenths stations name
  let (minTenths, meanTenths, maxTenths) = parseValueTriple values
  assertBool
    (ByteStringChar8.unpack name <> ": min " <> show minTenths
       <> " not below max " <> show maxTenths)
    (minTenths < maxTenths)
  assertBool
    (ByteStringChar8.unpack name <> ": mean " <> show meanTenths
       <> " tenths too far from listed " <> show listedTenths)
    (abs (meanTenths - listedTenths) <= 50)

listedMeanTenths :: SmallArray Generate.Station -> ByteString -> Int
listedMeanTenths stations name =
  case foldr (matchStation name) Nothing stations of
    Nothing -> error ("station not in list: " <> ByteStringChar8.unpack name)
    Just tenths -> tenths

matchStation :: ByteString -> Generate.Station -> Maybe Int -> Maybe Int
matchStation name station found =
  case found of
    Just tenths -> Just tenths
    Nothing ->
      if Generate.stationPrefix station == ByteStringChar8.snoc name ';'
        then Just (Generate.stationMeanTenths station)
        else Nothing

-- | Parse @-?d+.d@ triple @min\/mean\/max@ into tenths.
parseValueTriple :: ByteString -> (Int, Int, Int)
parseValueTriple values =
  case ByteStringChar8.split '/' values of
    [minText, meanText, maxText] ->
      (valueTenths minText, valueTenths meanText, valueTenths maxText)
    _ -> error ("malformed value triple: " <> ByteStringChar8.unpack values)

valueTenths :: ByteString -> Int
valueTenths text =
  case readMaybe (ByteStringChar8.unpack (ByteStringChar8.filter (/= '.') text)) of
    Nothing -> error ("malformed value: " <> ByteStringChar8.unpack text)
    Just tenths -> tenths

nameOfStationLine :: ByteString -> ByteString
nameOfStationLine = ByteStringChar8.takeWhile (/= ';')

-- | Pair every station name with its @min\/mean\/max@ value text. Names
-- follow the same comma-safe extraction as 'reportStationNames'; the
-- value text is the piece of each @=@-fragment before its separator.
reportEntryPairs :: ByteString -> [(ByteString, ByteString)]
reportEntryPairs report =
  zip (reportStationNames report) (reportEntryValues report)

reportEntryValues :: ByteString -> [ByteString]
reportEntryValues report =
  case ByteStringChar8.split '=' (reportBody report) of
    [] -> []
    (_leadingName : fragments) -> fmap valuesBeforeSeparator fragments

valuesBeforeSeparator :: ByteString -> ByteString
valuesBeforeSeparator fragment =
  fst (ByteStringChar8.breakSubstring ", " fragment)

-- | Extract the station names from @{a=1.0\/2.0\/3.0, b=...}\\n@. Names
-- may contain commas (e.g. @Washington, D.C.@) so splitting on commas is
-- wrong; instead split on @=@, which never occurs in the value part, and
-- take what follows the @", "@ separator in each fragment. The final
-- fragment holds only the last entry's values, hence the 'init'.
reportStationNames :: ByteString -> [ByteString]
reportStationNames report =
  case ByteStringChar8.split '=' (reportBody report) of
    [] -> []
    (firstName : laterFragments) ->
      case laterFragments of
        [] -> []
        _ -> firstName : fmap nameAfterValues (init laterFragments)

reportBody :: ByteString -> ByteString
reportBody report =
  ByteStringChar8.takeWhile (/= '}') (ByteStringChar8.drop 1 report)

nameAfterValues :: ByteString -> ByteString
nameAfterValues fragment =
  ByteStringChar8.drop 2 (snd (ByteStringChar8.breakSubstring ", " fragment))

assertKnownStation :: [ByteString] -> ByteString -> IO ()
assertKnownStation knownNames name =
  assertBool
    ("unknown station in report: " <> ByteStringChar8.unpack name)
    (name `elem` knownNames)
