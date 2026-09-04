// One billion row challenge, Rust port of the Haskell implementation in
// src/Aggregate.hs. Deliberately the SAME algorithm, mirrored
// constant-for-constant: pread into per-worker reusable padded buffers
// claimed off an atomic counter, two interleaved line cursors, SWAR
// semicolon search and branchless temperature parse, an open-addressing
// table of 64-byte aligned slots, and a per-worker name arena.
//
// Decision: this port exists to price GHC's pinned-register calling
// convention. Haskell reserves ten general-purpose registers for the
// STG machine (rts/include/stg/MachRegs/x86.h) and its hot loop spills
// accordingly (~171 instructions per line measured); rustc/LLVM may
// allocate the full file. Same algorithm, same machine, different
// backend: the wall-clock delta is the cost of the trade.
//
// No crates: std's FileExt::read_at is pread(2), std threads suffice.

use std::collections::BTreeMap;
use std::env;
use std::fs::File;
use std::io::Write;
use std::os::unix::fs::FileExt;
use std::process::exit;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::thread;

const SLOT_COUNT: usize = 65536;
const CHUNKS_PER_WORKER: usize = 32;
const CHUNK_SLOP: usize = 160;
const ARENA_BYTES: usize = 2_000_000;

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

/// One station's slot: exactly one aligned cache line, same field order
/// as the Haskell table (offset | length | word0 | word1 | min | max |
/// sum | count).
#[derive(Clone, Copy)]
#[repr(C, align(64))]
struct Slot {
    offset: i64,
    length: i64,
    word0: u64,
    word1: u64,
    min: i64,
    max: i64,
    sum: i64,
    count: i64,
}

const EMPTY_SLOT: Slot = Slot {
    offset: -1,
    length: -1,
    word0: 0,
    word1: 0,
    min: 0,
    max: 0,
    sum: 0,
    count: 0,
};

struct Table {
    slots: Vec<Slot>,
    arena: Vec<u8>,
}

fn new_table() -> Table {
    Table {
        slots: vec![EMPTY_SLOT; SLOT_COUNT],
        arena: Vec::with_capacity(ARENA_BYTES),
    }
}

#[inline(always)]
unsafe fn read_u64(buffer: *const u8, index: usize) -> u64 {
    (buffer.add(index) as *const u64).read_unaligned()
}

/// SWAR: a byte of the result has its high bit set exactly where the
/// input word holds a semicolon.
#[inline(always)]
fn semicolon_matches(word: u64) -> u64 {
    let masked = word ^ 0x3B3B3B3B3B3B3B3B;
    masked.wrapping_sub(0x0101010101010101) & !masked & 0x8080808080808080
}

/// Multiply-xor hash of the first 16 name bytes, reduced to a slot.
#[inline(always)]
fn start_slot(word0: u64, word1: u64) -> usize {
    let mixed = word0
        .wrapping_mul(0x9E3779B97F4A7C15)
        ^ word1.wrapping_mul(0xC2B2AE3D27D4EB4F);
    let avalanched = mixed ^ (mixed >> 29);
    (avalanched as usize) & (SLOT_COUNT - 1)
}

/// Parse one line starting at `index`, fold it into the table, and
/// return the next line's start. Mirrors stepLine/scanValue/finishLine.
#[inline(always)]
unsafe fn step_line(buffer: *const u8, table: &mut Table, index: usize) -> usize {
    let word_a = read_u64(buffer, index);
    let word_b = read_u64(buffer, index + 8);
    let match_a = semicolon_matches(word_a);
    let match_b = semicolon_matches(word_b);
    // trailing_zeros of 0 is 64, so byte_a/byte_b are 8 exactly when
    // their word has no semicolon; the mask arithmetic exploits that.
    let byte_a = (match_a.trailing_zeros() >> 3) as usize;
    let byte_b = (match_b.trailing_zeros() >> 3) as usize;
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
        name_length = byte_a + (byte_b & missing_a);
        word0 = word_a & BYTE_MASKS[byte_a];
        word1 = word_b & BYTE_MASKS[byte_b & missing_a];
    }
    // branchless temperature parse (Quan Anh Mai's 1brc trick): the
    // grammar is -?d?d.d, sign and dot position both come from bit 4
    let value_position = index + name_length + 1;
    let value_word = read_u64(buffer, value_position);
    let signed = ((!value_word << 59) as i64) >> 63;
    let unsigned_word = value_word & !(signed as u64 & 0xFF);
    let dot_bit = (!value_word & 0x10101000).trailing_zeros() as usize;
    let digits = (unsigned_word << (28 - dot_bit)) & 0x0F000F0F00;
    let magnitude = (digits.wrapping_mul(0x640A0001) >> 32) & 0x3FF;
    let value = (magnitude as i64 ^ signed) - signed;
    record(buffer, table, index, name_length, word0, word1, value);
    value_position + (dot_bit >> 3) + 3
}

/// Linear-probe for the station's slot and fold one measurement in,
/// copying the name into the arena on first sight (the read buffer it
/// points into gets overwritten by later chunks).
#[inline(always)]
unsafe fn record(
    buffer: *const u8,
    table: &mut Table,
    name_offset: usize,
    name_length: usize,
    word0: u64,
    word1: u64,
    value: i64,
) {
    let mut slot_index = start_slot(word0, word1);
    let mut probes = 0;
    loop {
        let slot = table.slots.get_unchecked_mut(slot_index);
        if slot.offset < 0 {
            let arena_offset = table.arena.len();
            assert!(
                arena_offset + name_length <= ARENA_BYTES,
                "station name arena full"
            );
            table.arena.extend_from_slice(std::slice::from_raw_parts(
                buffer.add(name_offset),
                name_length,
            ));
            *table.slots.get_unchecked_mut(slot_index) = Slot {
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
        let key_difference = (slot.length ^ name_length as i64)
            | (slot.word0 ^ word0) as i64
            | (slot.word1 ^ word1) as i64;
        if key_difference == 0
            && (name_length <= 16
                || long_names_equal(table, slot_index, buffer, name_offset, name_length))
        {
            let slot = table.slots.get_unchecked_mut(slot_index);
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
        assert!(probes <= SLOT_COUNT, "station table full");
    }
}

#[inline(never)]
unsafe fn long_names_equal(
    table: &Table,
    slot_index: usize,
    buffer: *const u8,
    name_offset: usize,
    name_length: usize,
) -> bool {
    let slot = table.slots.get_unchecked(slot_index);
    let stored =
        &table.arena[slot.offset as usize + 16..slot.offset as usize + name_length];
    let looked_up =
        std::slice::from_raw_parts(buffer.add(name_offset + 16), name_length - 16);
    stored == looked_up
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

/// Parse every line starting in [parse_from, boundary): two interleaved
/// cursors, remainders finish single-cursor. Final lines may run past
/// `boundary` into the chunk's slop, which is safe and by design.
unsafe fn pair_lines(buffer: *const u8, table: &mut Table, parse_from: usize, boundary: usize) {
    let half = parse_from + (boundary.saturating_sub(parse_from)) / 2;
    let split = if half >= boundary {
        boundary
    } else {
        scan_past_newline(buffer, boundary, half)
    };
    let (mut cursor_a, mut cursor_b) = (parse_from, split);
    while cursor_a < split && cursor_b < boundary {
        cursor_a = step_line(buffer, table, cursor_a);
        cursor_b = step_line(buffer, table, cursor_b);
    }
    while cursor_a < split {
        cursor_a = step_line(buffer, table, cursor_a);
    }
    while cursor_b < boundary {
        cursor_b = step_line(buffer, table, cursor_b);
    }
}

fn chunk_length(data_size: usize, chunk_count: usize) -> usize {
    data_size.div_ceil(chunk_count)
}

/// Read one chunk (one leading byte to find the first line start, slop
/// for the trailing line) and parse every line that starts inside it.
fn process_chunk(
    file: &File,
    data_size: usize,
    chunk_count: usize,
    table: &mut Table,
    buffer: &mut [u8],
    claimed: usize,
) {
    let stride = chunk_length(data_size, chunk_count);
    let chunk_start = claimed * stride;
    if chunk_start >= data_size {
        return;
    }
    let chunk_end = data_size.min(chunk_start + stride);
    let read_start = chunk_start.saturating_sub(1);
    let wanted = (data_size - read_start).min(chunk_end - read_start + CHUNK_SLOP);
    let mut filled = 0;
    while filled < wanted {
        let got = file
            .read_at(&mut buffer[filled..wanted], (read_start + filled) as u64)
            .expect("pread failed mid-file");
        assert!(got > 0, "unexpected EOF mid-file");
        filled += got;
    }
    buffer[wanted..wanted + 32].fill(0);
    let pointer = buffer.as_ptr();
    unsafe {
        let boundary = chunk_end - read_start;
        let parse_from = if chunk_start == 0 {
            0
        } else {
            scan_past_newline(pointer, wanted, 0)
        };
        pair_lines(pointer, table, parse_from, boundary);
    }
}

fn tenths(value: i64) -> String {
    let sign = if value < 0 { "-" } else { "" };
    let magnitude = value.abs();
    format!("{}{}.{}", sign, magnitude / 10, magnitude % 10)
}

fn main() {
    let arguments: Vec<String> = env::args().collect();
    let path = match arguments.len() {
        1 => "measurements.txt",
        2 => arguments[1].as_str(),
        _ => {
            eprintln!("usage: onebr-rust [measurements.txt]");
            exit(1);
        }
    };
    let file = Arc::new(File::open(path).unwrap_or_else(|error| {
        eprintln!("{path}: {error}");
        exit(1)
    }));
    let data_size = file.metadata().expect("stat failed").len() as usize;
    let stdout = std::io::stdout();
    if data_size == 0 {
        stdout.lock().write_all(b"{}\n").expect("write failed");
        return;
    }
    let mut last_byte = [0u8; 1];
    file.read_at(&mut last_byte, (data_size - 1) as u64)
        .expect("cannot read final byte");
    if last_byte[0] != b'\n' {
        eprintln!("{path}: missing trailing newline, refusing to parse");
        exit(1);
    }
    let worker_count = thread::available_parallelism().map_or(1, |n| n.get());
    let chunk_count = worker_count * CHUNKS_PER_WORKER;
    let next_chunk = Arc::new(AtomicUsize::new(0));
    let mut handles = Vec::new();
    for _ in 0..worker_count {
        let file = Arc::clone(&file);
        let next_chunk = Arc::clone(&next_chunk);
        handles.push(thread::spawn(move || {
            let mut table = new_table();
            let mut buffer =
                vec![0u8; chunk_length(data_size, chunk_count) + 1 + CHUNK_SLOP + 32];
            loop {
                let claimed = next_chunk.fetch_add(1, Ordering::Relaxed);
                if claimed >= chunk_count {
                    break;
                }
                process_chunk(&file, data_size, chunk_count, &mut table, &mut buffer, claimed);
            }
            table
        }));
    }
    let mut merged: BTreeMap<Vec<u8>, (i64, i64, i64, i64)> = BTreeMap::new();
    for handle in handles {
        let table = handle.join().expect("worker panicked");
        for slot in &table.slots {
            if slot.offset < 0 {
                continue;
            }
            let name = table.arena
                [slot.offset as usize..(slot.offset + slot.length) as usize]
                .to_vec();
            let entry = merged
                .entry(name)
                .or_insert((i64::MAX, i64::MIN, 0, 0));
            entry.0 = entry.0.min(slot.min);
            entry.1 = entry.1.max(slot.max);
            entry.2 += slot.sum;
            entry.3 += slot.count;
        }
    }
    let mut report = Vec::with_capacity(16384);
    report.push(b'{');
    let mut first = true;
    for (name, (minimum, maximum, sum, count)) in &merged {
        if !first {
            report.extend_from_slice(b", ");
        }
        first = false;
        report.extend_from_slice(name);
        // mean rounded like Java's Math.round: half up towards +inf
        let mean = ((*sum as f64) / (*count as f64) + 0.5).floor() as i64;
        report.extend_from_slice(
            format!("={}/{}/{}", tenths(*minimum), tenths(mean), tenths(*maximum)).as_bytes(),
        );
    }
    report.extend_from_slice(b"}\n");
    stdout.lock().write_all(&report).expect("write failed");
}
