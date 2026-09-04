// Shared between rust/main.rs and rust/hot.rs (included via #[path]),
// so the native build and the hand-optimized-IR build agree on layout.

pub const SLOT_COUNT: usize = 65536;
pub const ARENA_BYTES: usize = 2_000_000;

/// One station's slot: exactly one aligned cache line, same field order
/// as the Haskell table (offset | length | word0 | word1 | min | max |
/// sum | count).
#[derive(Clone, Copy)]
#[repr(C, align(64))]
pub struct Slot {
    pub offset: i64,
    pub length: i64,
    pub word0: u64,
    pub word1: u64,
    pub min: i64,
    pub max: i64,
    pub sum: i64,
    pub count: i64,
}

pub const EMPTY_SLOT: Slot = Slot {
    offset: -1,
    length: -1,
    word0: 0,
    word1: 0,
    min: 0,
    max: 0,
    sum: 0,
    count: 0,
};

/// parse_chunk status codes: the hot module reports failure instead of
/// panicking so its object file needs no unwinding machinery. (The
/// failure codes are constructed in hot.rs and only inspected by
/// main.rs's status assertion, hence the allows: each build mode uses
/// a different subset.)
pub const PARSE_OK: i32 = 0;
#[allow(dead_code)]
pub const PARSE_TABLE_FULL: i32 = 1;
#[allow(dead_code)]
pub const PARSE_ARENA_FULL: i32 = 2;
