{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}

-- | The one billion row challenge through the effectful library, as a
-- benchmark of what an effect system costs on a hot path.
--
-- Decision: everything except the per-line loop is shared with
-- "Aggregate" via its 'ChunkParser' hook, so the two implementations
-- are byte-identical by construction and the ONLY difference is that
-- this module's line walker runs in 'Eff' — one effect-system bind
-- plus a 'liftIO' per row, two of them per pair-loop turn, a billion
-- rows per run. That is precisely where effect overhead would land,
-- and nothing else is measured. Alternatives considered: running the
-- whole pipeline in Eff (adds noise from orchestration code that runs
-- 512 times, not a billion) and wrapping stepLine itself in Eff
-- internals (measures the same thing with more code duplicated).
-- runEff happens once per chunk, off the hot path.
module AggregateEffectful
  ( main
  , processFile
  ) where

import Data.ByteString (ByteString)
import Data.Word (Word8)
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import Foreign.Ptr (Ptr)

import Aggregate
    (ChunkParser, WorkerTable, mainWith, processFileWith, scanPastNewline,
    stepLine)

main :: IO ()
main = mainWith processFile

processFile :: FilePath -> IO ByteString
processFile = processFileWith effectfulChunkParser

-- | 'ChunkParser' is @Ptr Word8 -> WorkerTable -> Int -> Int -> IO ()@
-- (buffer, table, parseFrom, boundary); 'runEff' discharges the
-- 'Eff' computation back to the IO that hook expects.
effectfulChunkParser :: ChunkParser
effectfulChunkParser buffer table parseFrom boundary =
  runEff (pairLinesEff buffer table parseFrom boundary)

-- | Mirror of Aggregate's pairLines: split the range in two and walk
-- both halves with interleaved cursors, remainders single-cursor. Same
-- shape, but every line advance goes through 'Eff'.
pairLinesEff
  :: IOE :> es => Ptr Word8 -> WorkerTable -> Int -> Int -> Eff es ()
pairLinesEff buffer table parseFrom boundary = do
  let half = parseFrom + (boundary - parseFrom) `div` 2
  split <-
    if half >= boundary
      then pure boundary
      else liftIO (scanPastNewline buffer boundary half)
  pairLineLoopEff buffer table parseFrom split split boundary

pairLineLoopEff
  :: IOE :> es
  => Ptr Word8 -> WorkerTable -> Int -> Int -> Int -> Int -> Eff es ()
pairLineLoopEff buffer table !indexA !endA !indexB !endB =
  if indexA >= endA || indexB >= endB
    then do
      lineLoopEff buffer table indexA endA
      lineLoopEff buffer table indexB endB
    else do
      nextA <- liftIO (stepLine buffer table indexA)
      nextB <- liftIO (stepLine buffer table indexB)
      pairLineLoopEff buffer table nextA endA nextB endB

lineLoopEff
  :: IOE :> es => Ptr Word8 -> WorkerTable -> Int -> Int -> Eff es ()
lineLoopEff buffer table !index !end =
  if index >= end
    then pure ()
    else do
      next <- liftIO (stepLine buffer table index)
      lineLoopEff buffer table next end
