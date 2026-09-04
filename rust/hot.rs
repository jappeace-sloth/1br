// The hot loop, isolated behind a C ABI so it can be built two ways:
// as a plain module of rust/main.rs (the default), or compiled to LLVM
// IR (rustc --crate-type=lib --emit=llvm-ir), optionally hand-edited,
// lowered with llc and linked into main.rs built with --cfg hot_extern.
// The delta between those builds measures what backend tuning is worth
// on top of rustc's defaults: the "true floor" experiment.
//
// Everything here is core-only (no allocation, no std calls): the
// caller owns the slot table and the name arena, and failures return
// status codes instead of panicking so the standalone object file
// carries no unwinding machinery.

#![cfg_attr(not(test), allow(dead_code))]

#[path = "slot.rs"]
pub mod slot;

use slot::{Slot, ARENA_BYTES, PARSE_ARENA_FULL, PARSE_OK, PARSE_TABLE_FULL, SLOT_COUNT};

// Little-endian entry k has its low k bytes set (the Haskell side keeps
// this as a static Addr# table for the same reason: computing it needs
// two variable shifts and x86 wants shift counts in %cl).
const BYTE_MASKS: [u64; 9] = [
    0x0000000000000000,
    0x00000000000000FF,
    0x000000000000FFFF,
    0x0000000000FFFFFF,
    0x00000000FFFFFFFF,
    0x000000FFFFFFFFFF,
    0x0000FFFFFFFFFFFF,
    0x00FFFFFFFFFFFFFF,
    0xFFFFFFFFFFFFFFFF,
];

#[inline(always)]
unsafe fn read_u64(buffer: *const u8, index: usize) -> u64 {
    (buffer.add(index) as *const u64).read_unaligned()
}

/// SWAR: a byte of the result has its high bit set exactly where the
/// input word holds a semicolon (0x3B, broadcast eight times below).
#[inline(always)]
fn semicolon_matches(word: u64) -> u64 {
    let masked = word ^ 0x3B3B3B3B3B3B3B3B;
    masked.wrapping_sub(0x0101010101010101) & !masked & 0x8080808080808080
}

/// Multiply-xor hash of the first 16 name bytes, reduced to a slot.
#[inline(always)]
fn start_slot(word0: u64, word1: u64) -> usize {
    let mixed = word0.wrapping_mul(0x9E3779B97F4A7C15)
        ^ word1.wrapping_mul(0xC2B2AE3D27D4EB4F);
    let avalanched = mixed ^ (mixed >> 29);
    (avalanched as usize) & (SLOT_COUNT - 1)
}

/// Buffer index just past the first newline at or after `index`, capped
/// at `limit`.
unsafe fn scan_past_newline(buffer: *const u8, limit: usize, mut index: usize) -> usize {
    while index < limit {
        if *buffer.add(index) == b'\n' {
            return index + 1;
        }
        index += 1;
    }
    limit
}

struct TableRef {
    slots: *mut Slot,
    arena: *mut u8,
    arena_len: usize,
}

/// Parse one line starting at `index`, fold it into the table, and
/// return the next line's start (or an error via `status`).
#[inline(always)]
unsafe fn step_line(
    buffer: *const u8,
    table: &mut TableRef,
    index: usize,
    status: &mut i32,
) -> usize {
    // Both name words load unconditionally and the semicolon position
    // resolves arithmetically: whether a name is shorter or longer than
    // eight bytes varies per station, so branching on it would
    // mispredict constantly. byte_a/byte_b are the semicolon's byte
    // position within each word, and because trailing_zeros of an
    // empty match word is 64, they equal 8 exactly when that word has
    // no semicolon, which the arithmetic below leans on.
    let word_a = read_u64(buffer, index);
    let word_b = read_u64(buffer, index + 8);
    let match_a = semicolon_matches(word_a);
    let match_b = semicolon_matches(word_b);
    let byte_a = (match_a.trailing_zeros() >> 3) as usize;
    let byte_b = (match_b.trailing_zeros() >> 3) as usize;
    // all-ones when word_a holds no semicolon, all-zeroes otherwise:
    // a branch-free select for "does word_b's result count?"
    let missing_a = ((match_a != 0) as usize).wrapping_sub(1);
    let (name_length, word0, word1);
    if match_a | match_b == 0 {
        // names longer than 16 bytes: byte-wise fallback, rare
        let mut end = index + 16;
        while *buffer.add(end) != b';' {
            end += 1;
        }
        name_length = end - index;
        word0 = word_a;
        word1 = word_b;
    } else {
        // semicolon in word_a: length is byte_a, word1 masks to zero.
        // semicolon only in word_b: byte_a is 8, so length is
        // 8 + byte_b and word1 keeps byte_b bytes.
        name_length = byte_a + (byte_b & missing_a);
        word0 = word_a & BYTE_MASKS[byte_a];
        word1 = word_b & BYTE_MASKS[byte_b & missing_a];
    }
    // Branchless temperature parse (Quan Anh Mai's 1brc trick). The
    // grammar is exactly -?d?d.d, so within the 8 bytes loaded at the
    // value: byte 0 is '-' or a digit, and the dot sits at byte 1, 2
    // or 3. Bit 4 of every byte distinguishes them: it is 0 for '-'
    // (0x2d) and '.' (0x2e) but 1 for every digit (0x3x).
    let value_position = index + name_length + 1;
    let value_word = read_u64(buffer, value_position);
    // byte 0's bit 4, complemented, shifted to the sign bit and
    // arithmetic-shifted back down: all-ones iff the first byte is '-'
    let signed = ((!value_word << 59) as i64) >> 63;
    // zero out the '-' byte so only digit and dot bytes remain
    let unsigned_word = value_word & !(signed as u64 & 0xFF);
    // 0x10101000 selects bit 4 of bytes 1..3; the complement marks the
    // dot, and its bit index (12, 20 or 28) encodes the dot position
    let dot_bit = (!value_word & 0x10101000).trailing_zeros() as usize;
    // line the hundreds/tens/units digits up at fixed byte positions
    let digits = (unsigned_word << (28 - dot_bit)) & 0x0F000F0F00;
    // one multiply gathers d*100 + d*10 + d into bits 32..41
    let magnitude = (digits.wrapping_mul(0x640A0001) >> 32) & 0x3FF;
    // two's-complement negate iff signed is all-ones
    let value = (magnitude as i64 ^ signed) - signed;
    record(buffer, table, index, name_length, word0, word1, value, status);
    value_position + (dot_bit >> 3) + 3
}

/// Linear-probe for the station's slot and fold one measurement in,
/// copying the name into the arena on first sight (the read buffer it
/// points into gets overwritten by later chunks).
#[inline(always)]
#[allow(clippy::too_many_arguments)]
unsafe fn record(
    buffer: *const u8,
    table: &mut TableRef,
    name_offset: usize,
    name_length: usize,
    word0: u64,
    word1: u64,
    value: i64,
    status: &mut i32,
) {
    let mut slot_index = start_slot(word0, word1);
    let mut probes = 0;
    loop {
        let slot = &mut *table.slots.add(slot_index);
        if slot.offset < 0 {
            let arena_offset = table.arena_len;
            if arena_offset + name_length > ARENA_BYTES {
                *status = PARSE_ARENA_FULL;
                return;
            }
            core::ptr::copy_nonoverlapping(
                buffer.add(name_offset),
                table.arena.add(arena_offset),
                name_length,
            );
            table.arena_len = arena_offset + name_length;
            *slot = Slot {
                offset: arena_offset as i64,
                length: name_length as i64,
                word0,
                word1,
                min: value,
                max: value,
                sum: value,
                count: 1,
            };
            return;
        }
        // fold the three equality checks into one word so the hit test
        // is a single well-predicted branch; zero iff all three match.
        // Names of at most 16 bytes live entirely in word0/word1, so
        // only longer ones need the byte comparison against the arena.
        let key_difference = (slot.length ^ name_length as i64)
            | (slot.word0 ^ word0) as i64
            | (slot.word1 ^ word1) as i64;
        if key_difference == 0
            && (name_length <= 16
                || long_names_equal(table, slot_index, buffer, name_offset, name_length))
        {
            let slot = &mut *table.slots.add(slot_index);
            if value < slot.min {
                slot.min = value;
            }
            if value > slot.max {
                slot.max = value;
            }
            slot.sum += value;
            slot.count += 1;
            return;
        }
        slot_index = (slot_index + 1) & (SLOT_COUNT - 1);
        probes += 1;
        if probes > SLOT_COUNT {
            *status = PARSE_TABLE_FULL;
            return;
        }
    }
}

#[inline(never)]
unsafe fn long_names_equal(
    table: &TableRef,
    slot_index: usize,
    buffer: *const u8,
    name_offset: usize,
    name_length: usize,
) -> bool {
    let slot = &*table.slots.add(slot_index);
    let stored = core::slice::from_raw_parts(
        table.arena.add(slot.offset as usize + 16),
        name_length - 16,
    );
    let looked_up =
        core::slice::from_raw_parts(buffer.add(name_offset + 16), name_length - 16);
    stored == looked_up
}

/// Parse every line starting in [parse_from, boundary): the range is
/// split in two and walked by two interleaved cursors, one line each
/// per loop turn, remainders finishing single-cursor. The point is
/// instruction-level parallelism, not caching: one line's work is a
/// long dependency chain (load name words, find the semicolon, hash,
/// load the slot, compare, update), and two independent chains overlap
/// in the out-of-order window. Final lines may run past `boundary`
/// into the chunk's slop, which is safe and by design.
///
/// Returns PARSE_OK or the first failure code. `arena_len` is read and
/// written through the pointer so the caller's arena stays consistent
/// across chunks.
///
/// # Safety
/// `buffer` must stay readable 16 bytes past the last newline before
/// `boundary` plus the final line's overhang; `slots` must point at
/// SLOT_COUNT slots; `arena` at ARENA_BYTES bytes.
#[no_mangle]
pub unsafe extern "C" fn parse_chunk(
    buffer: *const u8,
    parse_from: usize,
    boundary: usize,
    slots: *mut Slot,
    arena: *mut u8,
    arena_len: *mut usize,
) -> i32 {
    let mut table = TableRef {
        slots,
        arena,
        arena_len: *arena_len,
    };
    let mut status = PARSE_OK;
    let half = parse_from + (boundary.saturating_sub(parse_from)) / 2;
    let split = if half >= boundary {
        boundary
    } else {
        scan_past_newline(buffer, boundary, half)
    };
    let (mut cursor_a, mut cursor_b) = (parse_from, split);
    while cursor_a < split && cursor_b < boundary && status == PARSE_OK {
        cursor_a = step_line(buffer, &mut table, cursor_a, &mut status);
        cursor_b = step_line(buffer, &mut table, cursor_b, &mut status);
    }
    while cursor_a < split && status == PARSE_OK {
        cursor_a = step_line(buffer, &mut table, cursor_a, &mut status);
    }
    while cursor_b < boundary && status == PARSE_OK {
        cursor_b = step_line(buffer, &mut table, cursor_b, &mut status);
    }
    *arena_len = table.arena_len;
    status
}
