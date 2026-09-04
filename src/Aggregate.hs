{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE MagicHash #-}

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
--
-- Decision: numeric conversions in this module use fromIntegral, not
-- the unwitch library. Every conversion is either a widening (Word8 to
-- Int, digit arithmetic) or an intentional bit-preserving
-- reinterpretation (hash bits to a slot index, the first 16 name bytes
-- stored verbatim in Int slot fields), all in the per-line hot path of
-- a benchmark whose whole point is the hot path; routing them through a
-- conversion library makes none of them safer and puts a dependency
-- between the reader and the bit manipulation.
module Aggregate
  ( main
  , mainWith
  , processFile
    -- * Shared machinery for alternative drivers
    --
    -- | AggregateEffectful reuses everything below and differs only in
    -- how it walks lines within a chunk, so any output difference
    -- between the two is the effect system's doing and nothing else.
  , ChunkParser
  , processFileWith
  , WorkerTable
  , pairLines
  , stepLine
  , scanPastNewline
  ) where

import Control.Concurrent (forkIO, getNumCapabilities)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Monad (foldM, forM, forM_, when)
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
import Data.Primitive.ByteArray
    (MutableByteArray (MutableByteArray), newAlignedPinnedByteArray)
import Data.Primitive.PrimArray
    (MutablePrimArray (MutablePrimArray), newPrimArray, readPrimArray,
    setPrimArray, writePrimArray)
import Data.Word (Word64, Word8)
import Foreign.C.Types (CInt (..), CLong (..), CSize (..))
import Foreign.Marshal.Alloc (free, mallocBytes)
import Foreign.Marshal.Utils (copyBytes, fillBytes)
import Foreign.Ptr (Ptr, castPtr, plusPtr)
import Foreign.Storable (peekByteOff)
import GHC.Exts (Int (I#), RealWorld, indexWord64OffAddr#)
import GHC.Ptr (Ptr (Ptr))
import GHC.Word (Word64 (W64#))
import System.Environment (getArgs)
import System.Exit (die)
import Foreign.C.String (CString, withCString)

foreign import ccall unsafe "string.h memcmp"
  c_memcmp :: Ptr Word8 -> Ptr Word8 -> CSize -> IO CInt

foreign import ccall unsafe "open"
  c_open :: CString -> CInt -> IO CInt

foreign import ccall safe "pread"
  c_pread :: CInt -> Ptr Word8 -> CSize -> CLong -> IO CLong

foreign import ccall unsafe "lseek"
  c_lseek :: CInt -> CLong -> CInt -> IO CLong

main :: IO ()
main = mainWith processFile

mainWith :: (FilePath -> IO ByteString) -> IO ()
mainWith aggregate = do
  arguments <- getArgs
  case arguments of
    [] -> ByteString.putStr =<< aggregate "measurements.txt"
    [path] -> ByteString.putStr =<< aggregate path
    _ -> die "usage: exe [measurements.txt]"

-- | Run the whole pipeline on one file and return the formatted report,
-- e.g. @{Abha=-23.0\/18.0\/59.2, Adamstown=...}\\n@.
processFile :: FilePath -> IO ByteString
processFile = processFileWith pairLines

-- | Parses every line starting in @[parseFrom, boundary)@ of a chunk
-- buffer into the table: @parser buffer table parseFrom boundary@.
type ChunkParser = Ptr Word8 -> WorkerTable -> Int -> Int -> IO ()

-- | The whole pipeline with the per-chunk line walker pluggable; the
-- indirect call happens once per chunk, far off the hot path.
processFileWith :: ChunkParser -> FilePath -> IO ByteString
processFileWith parser path = do
  fileDescriptor <- withCString path (`c_open` 0)
  when (fileDescriptor < 0) $ die (path <> ": cannot open")
  dataSize64 <- c_lseek fileDescriptor 0 2
  let dataSize = fromIntegral dataSize64 :: Int
  if dataSize == 0
    then pure "{}\n"
    else do
      lastByte <- preadLastByte fileDescriptor dataSize
      when (lastByte /= newlineByte) $
        die (path <> ": missing trailing newline, refusing to parse")
      perStation <- aggregateFile parser fileDescriptor dataSize
      pure
        (LazyByteString.toStrict
          (Builder.toLazyByteString (formatReport perStation)))

preadLastByte :: CInt -> Int -> IO Word8
preadLastByte fileDescriptor dataSize = do
  buffer <- mallocBytes 1
  got <- c_pread fileDescriptor buffer 1 (fromIntegral (dataSize - 1))
  when (got /= 1) $ die "cannot read final byte"
  byte <- peekByteAt buffer 0
  free buffer
  pure byte

-- | Aggregate a non-empty file by having workers pread it in chunks.
--
-- Decision: plain pread into per-worker reusable buffers instead of
-- mmap. mmap costs a minor page fault per 4 KiB on first touch even
-- when the file is fully in page cache (~0.85s of system time per
-- billion-row run across the workers); pread copies from the page
-- cache into an already-faulted buffer instead, trading that for a
-- memcpy the kernel does at streaming speed. This also deletes the
-- mmap tail-overread machinery: our own buffers carry padding, so the
-- parser can always read 16 bytes ahead safely. The idea is borrowed
-- from vshabanov's 1brc discourse entry, which hit the same mmap
-- fault wall at high thread counts.
--
-- Workers pull chunks from a shared counter (one atomic fetch-add per
-- chunk) so a delayed core cannot stretch the whole run; because
-- stored names must outlive the reused read buffer, first sight of a
-- station copies its name into a per-worker arena.
aggregateFile :: ChunkParser -> CInt -> Int -> IO (Map ByteString StationStats)
aggregateFile parser fileDescriptor dataSize = do
  workerCount <- getNumCapabilities
  let chunkCount = workerCount * chunksPerWorker
  nextChunk <- newIORef 0
  resultVars <- forM [1 .. workerCount] $ \_workerIndex -> do
    resultVar <- newEmptyMVar
    _ <- forkIO $ do
      -- +32 so the zero pad written after a full read stays in bounds
      let bufferBytes = chunkLength dataSize chunkCount + 1 + chunkSlop + 32
      buffer <- mallocBytes bufferBytes
      table <- newTable
      readWorkLoop parser fileDescriptor dataSize chunkCount table buffer nextChunk
      free buffer
      putMVar resultVar table
    pure resultVar
  tables <- forM resultVars takeMVar
  merged <- mergeTables tables
  forM_ tables (free . tableArena)
  pure merged

chunksPerWorker :: Int
chunksPerWorker = 32

-- | Bytes of one chunk, rounding up so chunkCount chunks cover the file.
chunkLength :: Int -> Int -> Int
chunkLength dataSize chunkCount = (dataSize + chunkCount - 1) `div` chunkCount

-- | Slack read beyond a chunk boundary: the final line starting inside
-- the chunk may run up to a full line past it, and the parser reads up
-- to 16 bytes ahead of a line start; rounded up generously.
chunkSlop :: Int
chunkSlop = 160

-- | Claim and process chunks until the shared counter runs off the end.
readWorkLoop
  :: ChunkParser -> CInt -> Int -> Int -> WorkerTable -> Ptr Word8
  -> IORef Int -> IO ()
readWorkLoop parser fileDescriptor dataSize chunkCount table buffer nextChunk = do
  claimed <- atomicModifyIORef' nextChunk (\index -> (index + 1, index))
  if claimed >= chunkCount
    then pure ()
    else do
      processChunk parser fileDescriptor dataSize chunkCount table buffer claimed
      readWorkLoop parser fileDescriptor dataSize chunkCount table buffer nextChunk

-- | Read one chunk (plus one leading byte to find the first line start
-- and slop for the trailing line) and parse every line that STARTS
-- inside @[chunkStart, chunkEnd)@. Lines may end past chunkEnd inside
-- the slop; the next chunk skips them because it only starts parsing
-- at its own first line start.
processChunk
  :: ChunkParser -> CInt -> Int -> Int -> WorkerTable -> Ptr Word8 -> Int
  -> IO ()
processChunk parser fileDescriptor dataSize chunkCount table buffer claimed = do
  let stride = chunkLength dataSize chunkCount
  let chunkStart = claimed * stride
  let chunkEnd = min dataSize (chunkStart + stride)
  if chunkStart >= dataSize
    then pure ()
    else do
      let readStart = if chunkStart == 0 then 0 else chunkStart - 1
      let wanted = min (dataSize - readStart) (chunkEnd - readStart + chunkSlop)
      preadFully fileDescriptor buffer wanted readStart
      -- zero the padding so overreads past EOF see no stray digits
      fillBytes (buffer `plusPtr` wanted) 0 32
      let boundary = chunkEnd - readStart
      parseFrom <-
        if chunkStart == 0
          then pure 0
          else scanPastNewline buffer wanted 0
      parser buffer table parseFrom boundary

-- | Buffer index just past the first newline at or after @index@,
-- capped at @limit@ (a chunk with no newline yields the cap, which
-- makes the callers parse nothing rather than walk into the padding).
scanPastNewline :: Ptr Word8 -> Int -> Int -> IO Int
scanPastNewline buffer limit index =
  if index >= limit
    then pure limit
    else do
      byte <- peekByteAt buffer index
      if byte == newlineByte
        then pure (index + 1)
        else scanPastNewline buffer limit (index + 1)

-- | pread until the requested byte count arrived (short reads happen).
preadFully :: CInt -> Ptr Word8 -> Int -> Int -> IO ()
preadFully fileDescriptor buffer wanted offset =
  if wanted == 0
    then pure ()
    else do
      got <-
        c_pread fileDescriptor buffer (fromIntegral wanted)
          (fromIntegral offset)
      when (got <= 0) $ error "pread failed mid-file"
      preadFully fileDescriptor (buffer `plusPtr` fromIntegral got)
        (wanted - fromIntegral got) (offset + fromIntegral got)

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
data WorkerTable = WorkerTable
  { tableSlots       :: !(MutablePrimArray RealWorld Int)
  , tableArena       :: !(Ptr Word8)
  , tableArenaCursor :: !(MutablePrimArray RealWorld Int)
  }

slotCount :: Int
slotCount = 65536

slotMask :: Int
slotMask = slotCount - 1

fieldsPerSlot :: Int
fieldsPerSlot = 8

emptyOffset :: Int
emptyOffset = -1

-- | The alignment is not decoration: a slot is one cache line only if
-- it starts on one. newPrimArray payloads begin 16 bytes into the heap
-- block, which would make every slot straddle two lines and double the
-- table's line traffic. Pinned is a side effect of requesting alignment
-- and harmless at 4 MiB per worker.
newTable :: IO WorkerTable
newTable = do
  MutableByteArray raw <-
    newAlignedPinnedByteArray (slotCount * fieldsPerSlot * 8) 64
  let slots = MutablePrimArray raw
  setPrimArray slots 0 (slotCount * fieldsPerSlot) emptyOffset
  arena <- mallocBytes arenaBytes
  cursor <- newPrimArray 1
  writePrimArray cursor 0 0
  pure (WorkerTable
    { tableSlots = slots
    , tableArena = arena
    , tableArenaCursor = cursor
    })

-- | Name storage that outlives the reused read buffer: the challenge
-- caps stations at 10 000 of at most 100 bytes, doubled for headroom.
arenaBytes :: Int
arenaBytes = 2 * 1000 * 1000

-- ---------------------------------------------------------------------------
-- Hot loop
-- ---------------------------------------------------------------------------

-- | Parse every line starting in @[parseFrom, boundary)@ of the chunk
-- buffer; both cursors' final line may run past @boundary@ into the
-- chunk's slop bytes, which is safe and by design.
--
-- Decision: the range is split into two sub-ranges walked by two
-- interleaved cursors in one loop, revised down from four when perf
-- counters became available. A single line's work is one long
-- dependency chain (load name word, find the semicolon, hash, load the
-- slot, compare, update), so a lone cursor leaves the core
-- latency-bound; independent chains overlap that. But every extra
-- cursor also grows the loop's live state, and past two GHC runs out
-- of registers: measured with perf on GHC 9.12 builds of this source
-- BEFORE the mask-table change below, the four-cursor version
-- executed 212 instructions per line (a large share stack-spill
-- traffic, 68 L1 loads per line against ~10 algorithmic ones) versus
-- 190 for two cursors and 183 for one, and the quad's extra ILP never
-- paid for the spills. Two cursors combined with the mask table
-- measured lowest in cycles and lands at ~171 instructions per line
-- in the shipped build; one cursor ties it on wall time but loses the
-- overlap that hides table-load latency on quiet machines.
pairLines :: Ptr Word8 -> WorkerTable -> Int -> Int -> IO ()
pairLines buffer table parseFrom boundary = do
  let half = parseFrom + (boundary - parseFrom) `div` 2
  split <-
    if half >= boundary
      then pure boundary
      else scanPastNewline buffer boundary half
  pairLineLoop buffer table parseFrom split split boundary

-- | Advance two cursors through their own sub-ranges, one line each
-- per iteration. When either cursor exhausts its sub-range the
-- remainders finish in plain single-cursor loops.
pairLineLoop
  :: Ptr Word8 -> WorkerTable -> Int -> Int -> Int -> Int -> IO ()
pairLineLoop filePtr table !indexA !endA !indexB !endB =
  if indexA >= endA || indexB >= endB
    then do
      lineLoop filePtr table indexA endA
      lineLoop filePtr table indexB endB
    else do
      nextA <- stepLine filePtr table indexA
      nextB <- stepLine filePtr table indexB
      pairLineLoop filePtr table nextA endA nextB endB

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
-- byteIndex 0 through 8 inclusive.
--
-- Decision: a static 9-entry mask table instead of computing the mask
-- with shifts. A branchless shift version needs two variable shifts
-- (a single @64 - 8*k@ shift is undefined at k=0), and x86 variable
-- shifts want their count in %cl, so perf showed each mask costing a
-- register-shuffling dance twice per line. The table turns that into
-- one load from a 72-byte constant that lives in L1.
maskBelowByte :: Int -> Word64 -> Word64
{-# INLINE maskBelowByte #-}
maskBelowByte (I# byteIndex) word =
  case byteMaskTable of
    Ptr tableAddr -> word .&. W64# (indexWord64OffAddr# tableAddr byteIndex)

-- | Little-endian Word64 entries; entry k has its low k bytes set.
byteMaskTable :: Ptr Word64
byteMaskTable = Ptr "\x00\x00\x00\x00\x00\x00\x00\x00\xff\x00\x00\x00\x00\x00\x00\x00\xff\xff\x00\x00\x00\x00\x00\x00\xff\xff\xff\x00\x00\x00\x00\x00\xff\xff\xff\xff\x00\x00\x00\x00\xff\xff\xff\xff\xff\x00\x00\x00\xff\xff\xff\xff\xff\xff\x00\x00\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff"#

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
      -- first sight of this station: the chunk buffer it points into
      -- will be overwritten, so copy the name into the arena and store
      -- the arena offset instead
      arenaOffset <- readPrimArray (tableArenaCursor table) 0
      when (arenaOffset + nameLength > arenaBytes) $
        error "station name arena full"
      copyBytes
        (tableArena table `plusPtr` arenaOffset)
        (filePtr `plusPtr` nameOffset)
        nameLength
      writePrimArray (tableArenaCursor table) 0 (arenaOffset + nameLength)
      writePrimArray slots slotBase arenaOffset
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
              else
                longNamesEqual (tableArena table) storedOffset filePtr
                  nameOffset nameLength
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

-- | Compare the bytes beyond the first 16 of a stored (arena) name and
-- a looked-up (chunk buffer) name.
longNamesEqual :: Ptr Word8 -> Int -> Ptr Word8 -> Int -> Int -> IO Bool
{-# INLINE longNamesEqual #-}
longNamesEqual arenaPtr storedOffset bufferPtr nameOffset nameLength = do
  comparison <-
    c_memcmp
      (arenaPtr `plusPtr` (storedOffset + 16))
      (bufferPtr `plusPtr` (nameOffset + 16))
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
-- out of the arenas they were stored in.
mergeTables :: [WorkerTable] -> IO (Map ByteString StationStats)
mergeTables = foldM mergeOneTable Map.empty

mergeOneTable
  :: Map ByteString StationStats
  -> WorkerTable
  -> IO (Map ByteString StationStats)
mergeOneTable startMap table =
  foldM (mergeSlot (tableArena table) table) startMap [0 .. slotCount - 1]

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

