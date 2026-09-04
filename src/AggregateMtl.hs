{-# LANGUAGE BangPatterns #-}

-- | The one billion row challenge through mtl, as the classical
-- counterpart to "AggregateEffectful".
--
-- Decision: the line walker's operations are a capability class,
-- 'MonadStepLine', which is mtl's way of spelling a domain effect:
-- the walker is polymorphic over the class alone (no 'MonadIO', no
-- 'MonadReader' leaks into it) and reinterpretation means writing
-- another carrier type with another instance. The production carrier
-- is a newtype over @ReaderT LineWalkEnv IO@. Everything else is
-- shared with "Aggregate" through its 'ChunkParser' hook, so output
-- is byte-identical by construction. The measured point of the
-- exercise: mtl dispatches its effects through class dictionaries
-- that GHC specializes at compile time, so the same abstraction that
-- costs effectful's dynamic dispatch ~148 instructions per row should
-- cost mtl almost nothing, and the price is paid elsewhere, in
-- boilerplate per interpretation and no runtime interpreter choice.
module AggregateMtl
  ( main
  , processFile
  ) where

import Control.Monad.Reader
    (ReaderT, asks, liftIO, runReaderT)
import Data.ByteString (ByteString)
import Data.Word (Word8)
import Foreign.Ptr (Ptr)

import Aggregate
    (ChunkParser, WorkerTable, mainWith, processFileWith, scanPastNewline,
    stepLine)

main :: IO ()
main = mainWith processFile

processFile :: FilePath -> IO ByteString
processFile = processFileWith mtlChunkParser

-- | The loop invariants, carried by the reader instead of by argument
-- threading; this is the shape mtl steers programs toward.
data LineWalkEnv = LineWalkEnv
  { walkBuffer :: !(Ptr Word8)
  , walkTable  :: !WorkerTable
  }

-- | The walker's operations as a capability class: mtl's spelling of
-- a domain effect. A different interpretation is a different carrier
-- type with its own instance.
class Monad m => MonadStepLine m where
  advanceLineM :: Int -> m Int
  -- | Line start at or after the probe index, capped at the limit.
  findLineStartM :: Int -> Int -> m Int

-- | The production carrier: performs against the real buffer and
-- table held in the reader environment.
newtype LineWalk a = LineWalk (ReaderT LineWalkEnv IO a)
  deriving newtype (Functor, Applicative, Monad)

instance MonadStepLine LineWalk where
  advanceLineM index = LineWalk $ do
    buffer <- asks walkBuffer
    table <- asks walkTable
    liftIO (stepLine buffer table index)
  findLineStartM limit index = LineWalk $ do
    buffer <- asks walkBuffer
    liftIO (scanPastNewline buffer limit index)

runLineWalk :: LineWalk a -> LineWalkEnv -> IO a
runLineWalk (LineWalk walk) = runReaderT walk

-- | 'ChunkParser' is @Ptr Word8 -> WorkerTable -> Int -> Int -> IO ()@
-- (buffer, table, parseFrom, boundary); 'runLineWalk' picks the
-- production interpretation.
mtlChunkParser :: ChunkParser
mtlChunkParser buffer table parseFrom boundary =
  runLineWalk
    (pairLinesMtl parseFrom boundary)
    (LineWalkEnv {walkBuffer = buffer, walkTable = table})

-- | Mirror of Aggregate's pairLines: split the range in two and walk
-- both halves with interleaved cursors, remainders single-cursor. Same
-- shape, but every line advance goes through the capability class.
pairLinesMtl :: MonadStepLine m => Int -> Int -> m ()
pairLinesMtl parseFrom boundary = do
  let half = parseFrom + (boundary - parseFrom) `div` 2
  split <-
    if half >= boundary
      then pure boundary
      else findLineStartM boundary half
  pairLineLoopMtl parseFrom split split boundary

pairLineLoopMtl :: MonadStepLine m => Int -> Int -> Int -> Int -> m ()
pairLineLoopMtl !indexA !endA !indexB !endB =
  if indexA >= endA || indexB >= endB
    then do
      lineLoopMtl indexA endA
      lineLoopMtl indexB endB
    else do
      nextA <- advanceLineM indexA
      nextB <- advanceLineM indexB
      pairLineLoopMtl nextA endA nextB endB

lineLoopMtl :: MonadStepLine m => Int -> Int -> m ()
lineLoopMtl !index !end =
  if index >= end
    then pure ()
    else do
      next <- advanceLineM index
      lineLoopMtl next end
