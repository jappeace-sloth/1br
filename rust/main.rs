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
// The hot loop lives in rust/hot.rs behind a C ABI so it can be built
// two ways: compiled here as a module (default), or emitted as LLVM
// IR, hand-tuned, lowered with llc and linked in (build with
// --cfg hot_extern and -C link-arg=hot.o). See rust/README.md.
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

#[cfg(not(hot_extern))]
#[path = "hot.rs"]
mod hot;
#[cfg(not(hot_extern))]
use hot::parse_chunk;
#[cfg(not(hot_extern))]
use hot::slot::{Slot, ARENA_BYTES, EMPTY_SLOT, PARSE_OK, SLOT_COUNT};

#[cfg(hot_extern)]
#[path = "slot.rs"]
mod slot;
#[cfg(hot_extern)]
use slot::{Slot, ARENA_BYTES, EMPTY_SLOT, PARSE_OK, SLOT_COUNT};
#[cfg(hot_extern)]
extern "C" {
    fn parse_chunk(
        buffer: *const u8,
        parse_from: usize,
        boundary: usize,
        slots: *mut Slot,
        arena: *mut u8,
        arena_len: *mut usize,
    ) -> i32;
}

const CHUNKS_PER_WORKER: usize = 32;
const CHUNK_SLOP: usize = 160;

/// Per-worker aggregation state; the arena holds every station name the
/// worker has seen (read buffers get overwritten, so names must move).
struct WorkerState {
    slots: Vec<Slot>,
    arena: Vec<u8>,
    arena_len: usize,
}

fn chunk_length(data_size: usize, chunk_count: usize) -> usize {
    data_size.div_ceil(chunk_count)
}

/// Buffer index just past the first newline at or after `index`, capped
/// at `limit` (duplicated from the hot module: in the hand-optimized-IR
/// build the hot internals are not callable from here, and this copy
/// runs once per chunk, not per line).
fn scan_past_newline(buffer: &[u8], limit: usize, mut index: usize) -> usize {
    while index < limit {
        if buffer[index] == b'\n' {
            return index + 1;
        }
        index += 1;
    }
    limit
}

/// Read one chunk (one leading byte to find the first line start, slop
/// for the trailing line) and parse every line that starts inside it.
fn process_chunk(
    file: &File,
    data_size: usize,
    chunk_count: usize,
    state: &mut WorkerState,
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
    // zero the tail so the parser's up-to-16-byte lookahead past the
    // final newline reads no stray digits or semicolons
    buffer[wanted..wanted + 32].fill(0);
    // boundary/parse_from are buffer indices; chunk_start/chunk_end are
    // file offsets, shifted by the one leading byte read for alignment
    let boundary = chunk_end - read_start;
    let parse_from = if chunk_start == 0 {
        0
    } else {
        scan_past_newline(buffer, wanted, 0)
    };
    let status = unsafe {
        parse_chunk(
            buffer.as_ptr(),
            parse_from,
            boundary,
            state.slots.as_mut_ptr(),
            state.arena.as_mut_ptr(),
            &mut state.arena_len,
        )
    };
    assert!(
        status == PARSE_OK,
        "parse_chunk failed with status {status} (1 = table full, 2 = arena full)"
    );
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
            let mut state = WorkerState {
                slots: vec![EMPTY_SLOT; SLOT_COUNT],
                arena: vec![0u8; ARENA_BYTES],
                arena_len: 0,
            };
            let mut buffer =
                vec![0u8; chunk_length(data_size, chunk_count) + 1 + CHUNK_SLOP + 32];
            loop {
                let claimed = next_chunk.fetch_add(1, Ordering::Relaxed);
                if claimed >= chunk_count {
                    break;
                }
                process_chunk(&file, data_size, chunk_count, &mut state, &mut buffer, claimed);
            }
            state
        }));
    }
    // BTreeMap iterates in byte order, which is the output order the
    // challenge requires
    let mut merged: BTreeMap<Vec<u8>, (i64, i64, i64, i64)> = BTreeMap::new();
    for handle in handles {
        let state = handle.join().expect("worker panicked");
        for slot in &state.slots {
            if slot.offset < 0 {
                continue;
            }
            let name = state.arena
                [slot.offset as usize..(slot.offset + slot.length) as usize]
                .to_vec();
            let entry = merged.entry(name).or_insert((i64::MAX, i64::MIN, 0, 0));
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
