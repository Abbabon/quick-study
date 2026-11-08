//! In-memory card search: layered fuzzy ranker + inline filters. 1:1 port of the former Swift
//! `SearchEngine` (ranking changes are bugs). The index is built by reading SQLite directly.
//!
//! Scoring layers (higher = better). A card is ranked by the best of its name match and any
//! set (code/name) match that includes it:
//!   1000+bonus name exact, 800+bonus prefix, 600+bonus token-start, 500+bonus set-code exact,
//!   450+bonus set-name exact, 400+bonus name substring, 350+bonus set-name prefix/token-start,
//!   200-spread name subsequence. `bonus = max(0, 100 - name.count)` (short names win).
//!
//! Names made only of printable ASCII (all but ~100) are matched on raw bytes; anything else
//! uses a grapheme-cluster scorer that mimics Swift `String` semantics (Character equality is
//! canonical equivalence, which we get by comparing NFD forms of each grapheme).
use crate::query::{Filter, FilterField, FilterOp, Parsed, parse};
use crate::{Result, lower};
use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::Mutex;
use unicode_normalization::UnicodeNormalization;
use unicode_segmentation::UnicodeSegmentation;

/// A card as the UI needs it (also the per-keystroke FFI payload).
#[derive(Clone, Debug, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct Hit {
    pub id: String,
    pub name: String,
    /// Raw `colors` JSON array contents, e.g. ["R", "G"].
    pub colors: Vec<String>,
    /// As stored (uppercase); the UI lowercases.
    pub set_code: Option<String>,
    pub set_name: Option<String>,
    pub rarity: Option<String>,
}

#[derive(Clone, Debug, Default)]
pub struct FilterFields {
    pub colors: Vec<String>,
    pub type_line_lower: Option<String>,
    pub oracle_text_lower: Option<String>,
    pub cmc: Option<f64>,
    pub rarities: HashSet<String>,
}

#[derive(Clone, Debug)]
pub struct SetGroup {
    pub code: String,
    pub name: String,
    pub member_ids: Vec<String>,
}

#[derive(Default)]
pub struct IndexData {
    pub minis: Vec<Hit>,
    pub sets: Vec<SetGroup>,
    pub fields: HashMap<String, FilterFields>,
}

pub struct Counted {
    pub hits: Vec<Hit>,
    pub total: usize,
}

const NO_COLORS_BIT: u8 = 0x80;
const NONE: i32 = i32::MIN;

pub const DEFAULT_LIMIT: usize = 20;

// ---------------------------------------------------------------------------------------------
// Unicode helpers

/// Foundation's `CharacterSet.whitespacesAndNewlines`.
fn is_ws_nl(c: char) -> bool {
    matches!(c, '\t'..='\r' | ' ' | '\u{85}' | '\u{A0}' | '\u{1680}' | '\u{2000}'..='\u{200A}'
        | '\u{2028}' | '\u{2029}' | '\u{202F}' | '\u{205F}' | '\u{3000}')
}

/// Swift `Character`s of `s`, each as its NFD form so `==` is canonical equivalence.
fn chars(s: &str) -> Vec<String> {
    s.graphemes(true).map(|g| g.nfd().collect()).collect()
}

fn length_bonus(count: usize) -> i32 {
    100i32.saturating_sub(count as i32).max(0)
}

/// Swift's `String <` order: NFC-normalized scalar order. Identity for ASCII.
fn sort_key(s: &str) -> String {
    if s.is_ascii() { s.to_string() } else { s.nfc().collect() }
}

/// True when every scalar is its own grapheme with no canonical-equivalence partner, so
/// Character-level substring search equals UTF-8 byte search (see the Swift original).
fn is_simple_text(s: &str) -> bool {
    s.chars().all(|c| {
        let v = c as u32;
        (v < 0x300 && v != 0x0D) || (0x2010..=0x2027).contains(&v) || (0x2030..=0x205E).contains(&v)
            || (0x2190..=0x21FF).contains(&v) || v == 0x2212
    })
}

fn contains_slice(hay: &[String], needle: &[String]) -> bool {
    needle.is_empty() || hay.windows(needle.len()).any(|w| w == needle)
}

fn split_spaces(c: &[String]) -> Vec<&[String]> {
    c.split(|x| x == " ").filter(|t| !t.is_empty()).collect()
}

// ---------------------------------------------------------------------------------------------
// Grapheme (String-semantics) scorers: reference implementation and non-ASCII fallback.

fn token_start_slow(q: &[String], n: &[String]) -> bool {
    let tokens = split_spaces(n);
    if !q.iter().any(|c| c == " ") {
        return tokens.iter().any(|t| t.starts_with(q)) && !tokens.first().is_none_or(|t| t.starts_with(q));
    }
    let qw = split_spaces(q);
    if qw.len() > tokens.len() { return false; }
    (0..=tokens.len() - qw.len()).any(|s| qw.iter().enumerate().all(|(i, w)| tokens[s + i].starts_with(w)))
}

fn score_slow(q: &[String], n: &[String]) -> Option<i32> {
    let bonus = length_bonus(n.len());
    if n == q { return Some(1000 + bonus); }
    if n.starts_with(q) { return Some(800 + bonus); }
    if token_start_slow(q, n) { return Some(600 + bonus); }
    if contains_slice(n, q) { return Some(400 + bonus); }
    let (mut qi, mut first, mut last) = (0, -1i32, -1i32);
    for (i, c) in n.iter().enumerate() {
        if qi < q.len() && *c == q[qi] {
            if first < 0 { first = i as i32; }
            last = i as i32;
            qi += 1;
        }
    }
    (qi == q.len()).then(|| 200 - (last - first))
}

fn set_name_base_slow(q: &[String], n: &[String]) -> Option<i32> {
    if n == q { return Some(450); }
    (n.starts_with(q) || token_start_slow(q, n)).then_some(350)
}

// ---------------------------------------------------------------------------------------------
// Byte-level fast path

/// A trimmed, lowercased query prepared for byte matching.
struct Query {
    /// UTF-8 bytes when all printable ASCII.
    bytes: Option<Vec<u8>>,
    has_space: bool,
    /// Byte ranges of the space-separated words.
    words: Vec<(usize, usize)>,
    /// Bits every matching name must have (prefilter only).
    mask: u64,
    /// Some query Character decomposes to a non-ASCII scalar: no all-ASCII name can match.
    needs_non_ascii: bool,
}

fn tokens_of(u: &[u8]) -> Vec<(usize, usize)> {
    let mut out = Vec::new();
    let mut start = None;
    for (i, &b) in u.iter().enumerate() {
        if b == b' ' {
            if let Some(s) = start.take() { out.push((s, i)); }
        } else if start.is_none() {
            start = Some(i);
        }
    }
    if let Some(s) = start { out.push((s, u.len())); }
    out
}

fn mask_of(bytes: &[u8]) -> u64 {
    bytes.iter().filter(|&&b| b < 0x80).fold(0, |m, &b| m | (1 << (b & 63)))
}

impl Query {
    fn new(q: &str) -> Query {
        let u = q.as_bytes();
        let ascii = u.iter().all(|&b| (0x20..0x7F).contains(&b));
        // Graphemes that are a single ASCII scalar contribute a mask bit (others only weaken it).
        let mask = q.graphemes(true).filter(|g| g.len() == 1).fold(0, |m, g| m | mask_of(g.as_bytes()));
        Query {
            bytes: ascii.then(|| u.to_vec()),
            has_space: u.contains(&b' '),
            words: tokens_of(u),
            mask,
            needs_non_ascii: q.nfd().any(|c| !c.is_ascii()),
        }
    }
}

#[derive(Clone, Copy)]
struct Span {
    start: u32,
    /// Byte count, or -1 when the name isn't all printable ASCII.
    count: i32,
    token_start: u32,
    token_count: u32,
    length_bonus: i32,
    mask: u64,
}

/// Lowercased names stored contiguously for the per-keystroke scan.
#[derive(Default)]
struct FlatNames {
    bytes: Vec<u8>,
    spans: Vec<Span>,
    /// (start, end) byte offsets relative to the name's start, two entries per token.
    token_bounds: Vec<u32>,
    /// Characters of the non-fast names, keyed by span index.
    slow: HashMap<u32, Vec<String>>,
}

impl FlatNames {
    fn push(&mut self, lower: &str) {
        let u = lower.as_bytes();
        let ascii = u.iter().all(|&b| (0x20..0x7F).contains(&b));
        let toks = if ascii { tokens_of(u) } else { Vec::new() };
        let cs = if ascii { None } else { Some(chars(lower)) };
        let count = cs.as_ref().map_or(u.len(), Vec::len);
        let mask = if ascii { mask_of(u) } else { mask_of(lower.nfd().collect::<String>().as_bytes()) };
        let idx = self.spans.len() as u32;
        self.spans.push(Span {
            start: self.bytes.len() as u32,
            count: if ascii { u.len() as i32 } else { -1 },
            token_start: (self.token_bounds.len()) as u32,
            token_count: toks.len() as u32,
            length_bonus: length_bonus(count),
            mask,
        });
        if ascii { self.bytes.extend_from_slice(u); }
        for (a, b) in toks { self.token_bounds.extend([a as u32, b as u32]); }
        if let Some(cs) = cs { self.slow.insert(idx, cs); }
    }

    #[inline] fn is_fast(&self, i: usize) -> bool { self.spans[i].count >= 0 }
    #[inline] fn bonus(&self, i: usize) -> i32 { self.spans[i].length_bonus }
    #[inline] fn mask(&self, i: usize) -> u64 { self.spans[i].mask }

    fn name(&self, s: &Span) -> &[u8] {
        &self.bytes[s.start as usize..s.start as usize + s.count as usize]
    }

    /// Characters of any name (bytes of fast names are their own Characters).
    fn chars(&self, i: usize) -> std::borrow::Cow<'_, [String]> {
        match self.slow.get(&(i as u32)) {
            Some(c) => std::borrow::Cow::Borrowed(c),
            None => std::borrow::Cow::Owned(self.name(&self.spans[i]).iter().map(|&b| (b as char).to_string()).collect()),
        }
    }

    /// `score_slow` on bytes. Requires `is_fast(i)`.
    fn score(&self, q: &Query, qp: &[u8], i: usize) -> Option<i32> {
        let s = &self.spans[i];
        let n = self.name(s);
        let (nc, qc) = (n.len(), qp.len());
        let bonus = s.length_bonus;
        // Subsequence first: every layer implies it, so most names are rejected in this pass.
        let (mut qi, mut first, mut last) = (0usize, -1i32, -1i32);
        for (j, &b) in n.iter().enumerate() {
            if b == qp[qi] {
                if first < 0 { first = j as i32; }
                last = j as i32;
                qi += 1;
                if qi == qc { break; }
            }
        }
        if qi != qc { return None; }
        let q0 = qp[0];
        if nc >= qc && n[0] == q0 && n[..qc] == *qp {
            return Some(if nc == qc { 1000 } else { 800 } + bonus);
        }
        if !q.has_space && s.token_count > 0 && self.token_bounds[s.token_start as usize] == 0 {
            // One scan finds both layers: an occurrence right after a space is a token start,
            // any other occurrence is a substring.
            let mut substring = false;
            if nc > qc {
                for at in 1..=(nc - qc) {
                    if n[at] == q0 && n[at..at + qc] == *qp {
                        if n[at - 1] == b' ' { return Some(600 + bonus); }
                        substring = true;
                    }
                }
            }
            if substring { return Some(400 + bonus); }
        } else {
            if self.token_start(q, qp, n, s) { return Some(600 + bonus); }
            if nc > qc && (1..=(nc - qc)).any(|at| n[at] == q0 && n[at..at + qc] == *qp) {
                return Some(400 + bonus);
            }
        }
        Some(200 - (last - first))
    }

    fn set_name_base(&self, q: &Query, qp: &[u8], i: usize) -> Option<i32> {
        let s = &self.spans[i];
        let n = self.name(s);
        if n.len() >= qp.len() && n[..qp.len()] == *qp {
            return Some(if n.len() == qp.len() { 450 } else { 350 });
        }
        self.token_start(q, qp, n, s).then_some(350)
    }

    fn token_start(&self, q: &Query, qp: &[u8], n: &[u8], s: &Span) -> bool {
        let tc = s.token_count as usize;
        let t0 = s.token_start as usize;
        let has_prefix = |k: usize, w: (usize, usize)| {
            let a = self.token_bounds[t0 + 2 * k] as usize;
            let b = self.token_bounds[t0 + 2 * k + 1] as usize;
            w.1 - w.0 <= b - a && n[a..a + (w.1 - w.0)] == qp[w.0..w.1]
        };
        if !q.has_space {
            let whole = (0, qp.len());
            return tc > 0 && !has_prefix(0, whole) && (1..tc).any(|k| has_prefix(k, whole));
        }
        if q.words.len() > tc { return false; }
        (0..=tc - q.words.len()).any(|st| q.words.iter().enumerate().all(|(k, &w)| has_prefix(st + k, w)))
    }
}

// ---------------------------------------------------------------------------------------------
// Filters

struct Compiled<'a> {
    f: &'a Filter,
    color_want: u8,
    mana_target: Option<f64>,
    simple_value: bool,
}

fn color_bit(c: &str) -> u8 {
    match c { "W" => 1, "U" => 2, "B" => 4, "R" => 8, "G" => 16, _ => 0 }
}

/// Bitmask for `c:r` / `c:wu` / `c:colorless`; 0 means colorless.
fn color_want(v: &str) -> u8 {
    match v {
        "white" => return 1,
        "blue" => return 2,
        "black" => return 4,
        "red" => return 8,
        "green" => return 16,
        "colorless" => return 0,
        _ => {}
    }
    let mut m = 0;
    for g in v.graphemes(true) {
        match g {
            "w" => m |= 1,
            "u" => m |= 2,
            "b" => m |= 4,
            "r" => m |= 8,
            "g" => m |= 16,
            "c" => return 0,
            _ => {}
        }
    }
    m
}

fn rarity_rank(r: &str) -> Option<i32> {
    Some(match r { "common" => 0, "uncommon" => 1, "rare" => 2, "mythic" => 3, _ => return None })
}

fn canon_rarity(v: &str) -> &str {
    match v { "c" => "common", "u" => "uncommon", "r" => "rare", "m" | "mythic rare" => "mythic", _ => v }
}

fn matches_rarity(f: &Filter, rarities: &HashSet<String>) -> bool {
    let target = canon_rarity(&f.value);
    let tr = match rarity_rank(target) {
        Some(tr) if f.op != FilterOp::Eq => tr,
        _ => return rarities.contains(target),
    };
    rarities.iter().any(|r| {
        let Some(rank) = rarity_rank(r) else { return false };
        match f.op {
            FilterOp::Gt => rank > tr,
            FilterOp::Ge => rank >= tr,
            FilterOp::Lt => rank < tr,
            FilterOp::Le => rank <= tr,
            FilterOp::Eq => rank == tr,
        }
    })
}

fn matches_mana_value(op: FilterOp, cmc: Option<f64>, target: Option<f64>) -> bool {
    let (Some(c), Some(t)) = (cmc, target) else { return false };
    match op {
        FilterOp::Eq => c == t,
        FilterOp::Gt => c > t,
        FilterOp::Ge => c >= t,
        FilterOp::Lt => c < t,
        FilterOp::Le => c <= t,
    }
}

/// Character-level `text.contains(value)`: byte search when both sides are simple text.
fn text_contains(text: &str, text_simple: bool, cf: &Compiled) -> bool {
    if cf.simple_value && text_simple {
        return text.contains(cf.f.value.as_str());
    }
    contains_slice(&chars(text), &chars(&cf.f.value))
}

struct Fields {
    type_lower: Option<String>,
    oracle_lower: Option<String>,
    cmc: Option<f64>,
    rarities: HashSet<String>,
    type_simple: bool,
    oracle_simple: bool,
}

// ---------------------------------------------------------------------------------------------
// Index

struct Scratch {
    best: Vec<i32>,
    touched: Vec<u32>,
}

pub struct Index {
    minis: Vec<Hit>,
    set_codes: Vec<String>,
    set_members: Vec<Vec<u32>>,
    fields: Vec<Option<Fields>>,
    color_masks: Vec<u8>,
    set_code_lower: Vec<Option<String>>,
    set_members_by_code: HashMap<String, HashSet<u32>>,
    names: FlatNames,
    canonical: Vec<u32>,
    rank: Vec<u32>,
    scratch: Mutex<Scratch>,
    set_chars: Vec<Vec<String>>,
}

impl Index {
    pub fn empty() -> Index { Index::new(IndexData::default()) }

    /// Reads the cards/printings tables through a read-only connection and builds the index.
    pub fn open(db_path: &Path) -> Result<Index> {
        Ok(Index::new(load(db_path)?))
    }

    pub fn len(&self) -> usize { self.minis.len() }
    pub fn is_empty(&self) -> bool { self.minis.is_empty() }

    pub fn new(data: IndexData) -> Index {
        let IndexData { minis, sets, fields: mut ff } = data;
        let mut first_index: HashMap<&str, u32> = HashMap::with_capacity(minis.len());
        let canonical: Vec<u32> = minis.iter().enumerate()
            .map(|(i, m)| *first_index.entry(m.id.as_str()).or_insert(i as u32)).collect();

        let name_lower: Vec<String> = minis.iter().map(|m| lower(&m.name)).collect();
        let keys: Vec<String> = name_lower.iter().map(|n| sort_key(n)).collect();
        let mut order: Vec<usize> = (0..minis.len()).collect();
        order.sort_by(|&a, &b| keys[a].cmp(&keys[b]).then_with(|| minis[a].id.cmp(&minis[b].id)).then(a.cmp(&b)));
        let mut rank = vec![0u32; minis.len()];
        for (r, &i) in order.iter().enumerate() { rank[i] = r as u32; }

        let fields: Vec<Option<Fields>> = minis.iter().map(|m| {
            // Swift's dictionary lookup by id; duplicates share the same entry.
            ff.get(&m.id).map(|f| Fields {
                type_simple: f.type_line_lower.as_deref().is_some_and(is_simple_text),
                oracle_simple: f.oracle_text_lower.as_deref().is_some_and(is_simple_text),
                type_lower: f.type_line_lower.clone(),
                oracle_lower: f.oracle_text_lower.clone(),
                cmc: f.cmc,
                rarities: f.rarities.clone(),
            })
        }).collect();
        let color_masks = minis.iter().map(|m| match ff.get(&m.id) {
            Some(f) if !f.colors.is_empty() => f.colors.iter().fold(0, |a, c| a | color_bit(&c.to_uppercase())),
            _ => NO_COLORS_BIT,
        }).collect();
        ff.clear();

        let set_codes: Vec<String> = sets.iter().map(|s| lower(&s.code)).collect();
        let set_members: Vec<Vec<u32>> = sets.iter()
            .map(|s| s.member_ids.iter().filter_map(|id| first_index.get(id.as_str()).copied()).collect()).collect();
        let mut by_code: HashMap<String, HashSet<u32>> = HashMap::new();
        for (c, m) in set_codes.iter().zip(&set_members) {
            by_code.entry(c.clone()).or_default().extend(m.iter().copied());
        }

        let mut names = FlatNames::default();
        for n in &name_lower { names.push(n); }
        let set_lower: Vec<String> = sets.iter().map(|s| lower(&s.name)).collect();
        for n in &set_lower { names.push(n); }

        let n = minis.len();
        Index {
            set_code_lower: minis.iter().map(|m| m.set_code.as_deref().map(lower)).collect(),
            set_chars: set_lower.iter().map(|s| chars(s)).collect(),
            set_codes,
            set_members,
            fields,
            color_masks,
            set_members_by_code: by_code,
            names,
            canonical,
            rank,
            scratch: Mutex::new(Scratch { best: vec![NONE; n], touched: Vec::new() }),
            minis,
        }
    }

    /// Parses the raw search-box string and searches.
    pub fn search(&self, query: &str, limit: usize) -> Counted {
        let Parsed { name, filters } = parse(query);
        self.search_counted(&name, &filters, limit)
    }

    /// Up to `limit` cards best-first plus `total` matches before the limit. With an empty
    /// name but filters present, all matching cards are returned, shortest-name first.
    pub fn search_counted(&self, name: &str, filters: &[Filter], limit: usize) -> Counted {
        let (top, total) = self.search_idx(name, filters, limit);
        Counted { hits: top.into_iter().map(|i| self.minis[i as usize].clone()).collect(), total }
    }

    fn search_idx(&self, name: &str, filters: &[Filter], limit: usize) -> (Vec<u32>, usize) {
        let q = lower(name.trim_matches(is_ws_nl));
        let compiled: Vec<Compiled> = filters.iter().map(|f| Compiled {
            f,
            color_want: color_want(&f.value),
            mana_target: f.value.parse::<f64>().ok(),
            simple_value: is_simple_text(&f.value),
        }).collect();

        if q.is_empty() {
            if filters.is_empty() { return (vec![], 0); }
            let cands = (0..self.minis.len()).filter(|&i| self.passes(&compiled, i)).map(|i| i as u32);
            return select_top_k(cands, limit, |&a, &b| {
                let (la, lb) = (self.names.bonus(a as usize), self.names.bonus(b as usize));
                if la != lb { la > lb } else { self.rank[a as usize] < self.rank[b as usize] }
            });
        }

        let mut guard = self.scratch.lock().unwrap_or_else(|e| e.into_inner());
        let Scratch { best, touched } = &mut *guard;
        touched.clear();

        let query = Query::new(&q);
        let qb: &[u8] = query.bytes.as_deref().unwrap_or(&[]);
        let fast = query.bytes.is_some();
        // Characters of the query, only needed off the byte path.
        let qchars = std::cell::OnceCell::new();
        let qc = || qchars.get_or_init(|| chars(&q)).as_slice();
        let n = self.minis.len();

        for i in 0..n {
            if self.names.mask(i) & query.mask != query.mask { continue; }
            let score = if self.names.is_fast(i) {
                if query.needs_non_ascii { continue; }
                if fast { self.names.score(&query, qb, i) } else { score_slow(qc(), &self.names.chars(i)) }
            } else {
                score_slow(qc(), &self.names.chars(i))
            };
            let Some(s) = score else { continue };
            let c = self.canonical[i] as usize;
            if best[c] == NONE { touched.push(c as u32); }
            if s > best[c] { best[c] = s; }
        }

        // A matching set contributes every member card in a band below high-confidence matches.
        for (k, code) in self.set_codes.iter().enumerate() {
            let mut base: Option<i32> = (q == *code || (!q.is_ascii() && q.nfd().eq(code.nfd()))).then_some(500);
            let j = n + k;
            let name_base = if fast && self.names.is_fast(j) {
                self.names.set_name_base(&query, qb, j)
            } else {
                set_name_base_slow(qc(), &self.set_chars[k])
            };
            if let Some(s) = name_base { base = Some(base.map_or(s, |b| b.max(s))); }
            let Some(set_base) = base else { continue };
            for &c in &self.set_members[k] {
                let cand = set_base + self.names.bonus(c as usize);
                let c = c as usize;
                if best[c] == NONE { touched.push(c as u32); }
                if cand > best[c] { best[c] = cand; }
            }
        }

        let cands = touched.iter().copied()
            .filter(|&c| compiled.is_empty() || self.passes(&compiled, c as usize))
            .map(|c| (best[c as usize], c));
        let (top, total) = select_top_k(cands, limit, |a, b| {
            if a.0 != b.0 { a.0 > b.0 } else { self.rank[a.1 as usize] < self.rank[b.1 as usize] }
        });
        for &c in touched.iter() { best[c as usize] = NONE; }
        (top.into_iter().map(|(_, c)| c).collect(), total)
    }

    fn passes(&self, filters: &[Compiled], i: usize) -> bool {
        filters.iter().all(|cf| self.matches(cf, i))
    }

    fn matches(&self, cf: &Compiled, i: usize) -> bool {
        let f = cf.f;
        let fields = self.fields[i].as_ref();
        let raw = match f.field {
            FilterField::Rarity => fields.is_some_and(|x| matches_rarity(f, &x.rarities)),
            FilterField::Color => {
                let have = self.color_masks[i];
                if cf.color_want == 0 { have == NO_COLORS_BIT } else { have & cf.color_want == cf.color_want }
            }
            FilterField::Type => fields.and_then(|x| x.type_lower.as_deref().map(|t| text_contains(t, x.type_simple, cf))).unwrap_or(false),
            FilterField::Oracle => fields.and_then(|x| x.oracle_lower.as_deref().map(|t| text_contains(t, x.oracle_simple, cf))).unwrap_or(false),
            FilterField::ManaValue => matches_mana_value(f.op, fields.and_then(|x| x.cmc), cf.mana_target),
            FilterField::Set => {
                self.set_code_lower[i].as_deref() == Some(f.value.as_str())
                    || self.set_members_by_code.get(&f.value).is_some_and(|m| m.contains(&self.canonical[i]))
            }
        };
        raw != f.negated
    }
}

/// Selects the best `limit` elements (`is_better` is a strict total order) in one pass,
/// also returning the total candidate count.
fn select_top_k<T>(cands: impl Iterator<Item = T>, limit: usize, is_better: impl Fn(&T, &T) -> bool) -> (Vec<T>, usize) {
    let mut top: Vec<T> = Vec::with_capacity(limit.min(1024));
    let mut total = 0;
    for c in cands {
        total += 1;
        if limit == 0 { continue; }
        if top.len() < limit {
            let idx = top.iter().position(|t| is_better(&c, t)).unwrap_or(top.len());
            top.insert(idx, c);
        } else if is_better(&c, &top[limit - 1]) {
            let idx = top.iter().position(|t| is_better(&c, t)).unwrap_or(top.len());
            top.insert(idx, c);
            top.pop();
        }
    }
    (top, total)
}

// ---------------------------------------------------------------------------------------------
// SQLite loading (read-only)

fn load(path: &Path) -> Result<IndexData> {
    use rusqlite::{Connection, OpenFlags};
    let c = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX)?;
    c.busy_timeout(std::time::Duration::from_secs(5))?;
    let colors = |raw: Option<String>| -> Vec<String> {
        raw.and_then(|r| serde_json::from_str::<Vec<String>>(&r).ok()).unwrap_or_default()
    };

    let mut minis = Vec::new();
    {
        let mut st = c.prepare("SELECT id, name, colors, set_code, set_name, rarity FROM cards")?;
        let mut rows = st.query([])?;
        while let Some(r) = rows.next()? {
            minis.push(Hit {
                id: r.get(0)?, name: r.get(1)?, colors: colors(r.get(2)?),
                set_code: r.get(3)?, set_name: r.get(4)?, rarity: r.get(5)?,
            });
        }
    }

    let mut by_oracle: HashMap<String, HashSet<String>> = HashMap::new();
    {
        let mut st = c.prepare("SELECT oracle_id, rarity FROM printings WHERE oracle_id IS NOT NULL AND rarity IS NOT NULL")?;
        let mut rows = st.query([])?;
        while let Some(r) = rows.next()? {
            let (oid, rar): (String, String) = (r.get(0)?, r.get(1)?);
            by_oracle.entry(oid).or_default().insert(lower(&rar));
        }
    }
    let mut fields = HashMap::with_capacity(minis.len());
    {
        let mut st = c.prepare("SELECT id, oracle_id, colors, type_line, oracle_text, cmc, rarity FROM cards")?;
        let mut rows = st.query([])?;
        while let Some(r) = rows.next()? {
            let id: String = r.get(0)?;
            let oid: Option<String> = r.get(1)?;
            let mut rarities = oid.and_then(|o| by_oracle.get(&o).cloned()).unwrap_or_default();
            if let Some(rep) = r.get::<_, Option<String>>(6)? { rarities.insert(lower(&rep)); }
            fields.insert(id, FilterFields {
                colors: colors(r.get(2)?),
                type_line_lower: r.get::<_, Option<String>>(3)?.map(|s| lower(&s)),
                oracle_text_lower: r.get::<_, Option<String>>(4)?.map(|s| lower(&s)),
                cmc: r.get(5)?,
                rarities,
            });
        }
    }

    let mut order: Vec<String> = Vec::new();
    let mut names: HashMap<String, String> = HashMap::new();
    let mut members: HashMap<String, Vec<String>> = HashMap::new();
    let mut seen: HashMap<String, HashSet<String>> = HashMap::new();
    {
        let mut st = c.prepare("SELECT p.set_code, p.set_name, c.id FROM printings p JOIN cards c ON c.oracle_id = p.oracle_id")?;
        let mut rows = st.query([])?;
        while let Some(r) = rows.next()? {
            let (code, name, id): (String, String, String) = (r.get(0)?, r.get(1)?, r.get(2)?);
            if !members.contains_key(&code) {
                order.push(code.clone());
                members.insert(code.clone(), Vec::new());
                seen.insert(code.clone(), HashSet::new());
                names.insert(code.clone(), name);
            }
            if seen.get_mut(&code).unwrap().insert(id.clone()) {
                members.get_mut(&code).unwrap().push(id);
            }
        }
    }
    let sets = order.into_iter().map(|code| SetGroup {
        name: names.remove(&code).unwrap_or_else(|| code.clone()),
        member_ids: members.remove(&code).unwrap_or_default(),
        code,
    }).collect();
    Ok(IndexData { minis, sets, fields })
}
