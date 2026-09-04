{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

-- | The one billion row challenge through the effectful library, as a
-- benchmark of what an effect system costs on a hot path.
--
-- Decision: everything except the per-line loop is shared with
-- "Aggregate" via its 'ChunkParser' hook, so the two implementations
-- are byte-identical by construction and the ONLY difference is that
-- this module's line walker runs in 'Eff': one effect-system bind
-- plus a 'liftIO' per row, two of them per pair-loop turn, a billion
-- rows per run. That is precisely where effect overhead would land,
-- and nothing else is measured. Alternatives considered: running the
-- whole pipeline in Eff (adds noise from orchestration code that runs
-- 512 times, not a billion) and wrapping stepLine itself in Eff
-- internals (measures the same thing with more code duplicated).
-- runEff happens once per chunk, off the hot path.
module AggregateEffectful
  ( main
  , mainDynamic
  , processFile
  , processFileDynamic
  ) where

import Data.ByteString (ByteString)
import Data.Word (Word8)
import Effectful
    (Dispatch (Dynamic), DispatchOf, Eff, Effect, IOE, liftIO, runEff, (:>))
import Effectful.Dispatch.Dynamic (interpret_, send)
import Foreign.Ptr (Ptr)

import Aggregate
    (ChunkParser, WorkerTable, mainWith, processFileWith, scanPastNewline,
    stepLine)

main :: IO ()
main = mainWith processFile

mainDynamic :: IO ()
mainDynamic = mainWith processFileDynamic

processFile :: FilePath -> IO ByteString
processFile = processFileWith effectfulChunkParser

processFileDynamic :: FilePath -> IO ByteString
processFileDynamic = processFileWith dynamicChunkParser

-- | Advancing one line is a proper domain effect here, dynamically
-- dispatched: the loop 'send's it and an interpreter chosen at the
-- chunk boundary performs it. This is what idiomatic effectful with
-- swappable interpreters looks like, and it prices the machinery the
-- 'liftIO' variant never touches: one 'send' plus a handler
-- indirection through the effect environment per row.
data StepLineEffect :: Effect where
  AdvanceLine :: Int -> StepLineEffect m Int
  FindLineStart :: Int -> Int -> StepLineEffect m Int

type instance DispatchOf StepLineEffect = Dynamic

advanceLine :: StepLineEffect :> es => Int -> Eff es Int
advanceLine = send . AdvanceLine

-- | Line start at or after the probe index, capped at the limit.
findLineStart :: StepLineEffect :> es => Int -> Int -> Eff es Int
findLineStart limit index = send (FindLineStart limit index)

-- | The production interpreter, performing against the real buffer and
-- table. Every IO the walker needs goes through the effect, so the
-- walker itself carries no 'IOE' and can be reinterpreted wholesale
-- (against a mock buffer, a tracing handler, whatever).
runStepLine
  :: IOE :> es
  => Ptr Word8 -> WorkerTable -> Eff (StepLineEffect : es) a -> Eff es a
runStepLine buffer table =
  interpret_ (\case
    AdvanceLine index -> liftIO (stepLine buffer table index)
    FindLineStart limit index ->
      liftIO (scanPastNewline buffer limit index))

dynamicChunkParser :: ChunkParser
dynamicChunkParser buffer table parseFrom boundary =
  runEff
    (runStepLine buffer table (pairLinesDynamic parseFrom boundary))

pairLinesDynamic
  :: StepLineEffect :> es => Int -> Int -> Eff es ()
pairLinesDynamic parseFrom boundary = do
  let half = parseFrom + (boundary - parseFrom) `div` 2
  split <-
    if half >= boundary
      then pure boundary
      else findLineStart boundary half
  pairLineLoopDynamic parseFrom split split boundary

pairLineLoopDynamic
  :: StepLineEffect :> es => Int -> Int -> Int -> Int -> Eff es ()
pairLineLoopDynamic !indexA !endA !indexB !endB =
  if indexA >= endA || indexB >= endB
    then do
      lineLoopDynamic indexA endA
      lineLoopDynamic indexB endB
    else do
      nextA <- advanceLine indexA
      nextB <- advanceLine indexB
      pairLineLoopDynamic nextA endA nextB endB

lineLoopDynamic :: StepLineEffect :> es => Int -> Int -> Eff es ()
lineLoopDynamic !index !end =
  if index >= end
    then pure ()
    else do
      next <- advanceLine index
      lineLoopDynamic next end

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
