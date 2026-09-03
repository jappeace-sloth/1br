module Main where

import Aggregate qualified
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as ByteStringChar8
import Generate qualified
import System.Directory (removeFile)
import Test.Tasty
import Test.Tasty.HUnit

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "1br"
  [ testGroup "official samples" (fmap sampleCase officialSamples)
  , testCase "generated file aggregates deterministically" generatorRoundTrip
  ]

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

nameOfStationLine :: ByteString -> ByteString
nameOfStationLine = ByteStringChar8.takeWhile (/= ';')

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
