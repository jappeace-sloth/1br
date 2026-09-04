-- One billion row challenge, MicroHs edition. MicroHs compiles to
-- combinators run by a small C evaluator, so none of the GHC tricks in
-- src/Aggregate.hs (unboxed primops, mmap/pread FFI, SWAR words) are
-- available; this is the honest idiomatic-simple version: String line
-- folding into a strict unbalanced BST (MicroHs bundles no containers
-- package, and with at most 10 000 station keys a plain tree is fine).
--
-- Decision: String, not ByteString. MicroHs ByteStrings store one BYTE
-- per cell but its text-mode file input decodes UTF-8 to codepoints,
-- so any station name beyond Latin-1 (the official samples contain
-- emoji names) is truncated on read, and binary-mode reads cannot be
-- byte-faithfully written back to stdout (the handle re-encodes).
-- MicroHs Char is a full codepoint, so String round-trips exactly, and
-- codepoint order equals UTF-8 byte order, keeping the report sorted
-- identically to the GHC and Rust implementations. The interpreter
-- dominates the runtime either way; measured, the String version is
-- what MicroHs is honestly like to use.
--
-- Same output format and rounding as the main implementations,
-- verified by the same test suite.

module Main where

import Data.List (foldl')
import System.Environment (getArgs)
import System.Exit (die)

data Stats = Stats !Int !Int !Int !Int

data Tree = Leaf | Node !String !Stats !Tree !Tree

insertMeasurement :: String -> Int -> Tree -> Tree
insertMeasurement name value Leaf =
  Node name (Stats value value value 1) Leaf Leaf
insertMeasurement name value (Node storedName stats left right) =
  case compare name storedName of
    LT -> Node storedName stats (insertMeasurement name value left) right
    GT -> Node storedName stats left (insertMeasurement name value right)
    EQ ->
      case stats of
        Stats lo hi total count ->
          Node storedName
            (Stats (min lo value) (max hi value) (total + value) (count + 1))
            left right

toAscList :: Tree -> [(String, Stats)] -> [(String, Stats)]
toAscList Leaf rest = rest
toAscList (Node name stats left right) rest =
  toAscList left ((name, stats) : toAscList right rest)

-- | Temperature grammar is -?d?d.d; parse to signed tenths. Station
-- names cannot contain semicolons, so the first ';' splits the line.
parseLine :: String -> (String, Int)
parseLine line =
  case break (== ';') line of
    (name, ';' : temperature) -> (name, parseTenths temperature)
    _ -> error ("malformed line: " ++ line)

parseTenths :: String -> Int
parseTenths ('-' : rest) = negate (parseUnsignedTenths rest)
parseTenths text = parseUnsignedTenths text

parseUnsignedTenths :: String -> Int
parseUnsignedTenths =
  foldl'
    (\acc c -> if c == '.' then acc else acc * 10 + (fromEnum c - 48))
    0

foldLine :: Tree -> String -> Tree
foldLine tree line =
  case parseLine line of
    (name, value) -> insertMeasurement name value tree

tenths :: Int -> String
tenths value =
  let sign = if value < 0 then "-" else ""
      magnitude = abs value
  in sign ++ show (magnitude `div` 10) ++ "." ++ show (magnitude `mod` 10)

formatEntry :: (String, Stats) -> String
formatEntry (name, Stats lo hi total count) =
  name ++ "=" ++ tenths lo ++ "/" ++ tenths mean ++ "/" ++ tenths hi
  where
    -- mean rounded like Java's Math.round: half up towards +inf
    mean =
      floor ((fromIntegral total :: Double) / fromIntegral count + 0.5)

joinEntries :: [String] -> String
joinEntries [] = ""
joinEntries [single] = single
joinEntries (entry : rest) = entry ++ ", " ++ joinEntries rest

main :: IO ()
main = do
  arguments <- getArgs
  path <- case arguments of
    [] -> pure "measurements.txt"
    [givenPath] -> pure givenPath
    _ -> die "usage: onebr-mhs [measurements.txt]"
  content <- readFile path
  let tree = foldl' foldLine Leaf (lines content)
  putStr ("{" ++ joinEntries (map formatEntry (toAscList tree [])) ++ "}\n")
