{-# LANGUAGE BangPatterns #-}

-- | The one billion row challenge through mtl, as the classical
-- counterpart to "AggregateEffectful".
--
-- Decision: the per-line loop is written the way idiomatic mtl code
-- is written, polymorphic over @(MonadReader LineWalkEnv m, MonadIO
-- m)@ with the loop invariants (buffer, table) in the reader
-- environment, instantiated at @ReaderT LineWalkEnv IO@ by the chunk
-- parser adapter. Everything else is shared with "Aggregate" through
-- its 'ChunkParser' hook, so output is byte-identical by construction
-- and any measured difference against the native or effectful
-- variants is the transformer stack's doing: per row this costs one
-- reader ask, one class-dictionary-mediated bind and a 'liftIO'.
-- Whether GHC specializes those away is exactly what the benchmark
-- exists to answer.
module AggregateMtl
  ( main
  , processFile
  ) where

import Control.Monad.Reader
    (MonadIO, MonadReader, asks, liftIO, runReaderT)
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

-- | 'ChunkParser' is @Ptr Word8 -> WorkerTable -> Int -> Int -> IO ()@
-- (buffer, table, parseFrom, boundary); 'runReaderT' instantiates the
-- polymorphic walker at @ReaderT LineWalkEnv IO@.
mtlChunkParser :: ChunkParser
mtlChunkParser buffer table parseFrom boundary =
  runReaderT
    (pairLinesMtl parseFrom boundary)
    (LineWalkEnv {walkBuffer = buffer, walkTable = table})

-- | Mirror of Aggregate's pairLines: split the range in two and walk
-- both halves with interleaved cursors, remainders single-cursor. Same
-- shape, but every line advance goes through the mtl stack.
pairLinesMtl
  :: (MonadReader LineWalkEnv m, MonadIO m) => Int -> Int -> m ()
pairLinesMtl parseFrom boundary = do
  buffer <- asks walkBuffer
  let half = parseFrom + (boundary - parseFrom) `div` 2
  split <-
    if half >= boundary
      then pure boundary
      else liftIO (scanPastNewline buffer boundary half)
  pairLineLoopMtl parseFrom split split boundary

pairLineLoopMtl
  :: (MonadReader LineWalkEnv m, MonadIO m)
  => Int -> Int -> Int -> Int -> m ()
pairLineLoopMtl !indexA !endA !indexB !endB =
  if indexA >= endA || indexB >= endB
    then do
      lineLoopMtl indexA endA
      lineLoopMtl indexB endB
    else do
      nextA <- stepLineMtl indexA
      nextB <- stepLineMtl indexB
      pairLineLoopMtl nextA endA nextB endB

lineLoopMtl
  :: (MonadReader LineWalkEnv m, MonadIO m) => Int -> Int -> m ()
lineLoopMtl !index !end =
  if index >= end
    then pure ()
    else do
      next <- stepLineMtl index
      lineLoopMtl next end

stepLineMtl
  :: (MonadReader LineWalkEnv m, MonadIO m) => Int -> m Int
stepLineMtl !index = do
  buffer <- asks walkBuffer
  table <- asks walkTable
  liftIO (stepLine buffer table index)
