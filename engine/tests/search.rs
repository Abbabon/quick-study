//! Golden search cases, ported 1:1 from the former Swift `SearchEngineTests` /
//! `SearchEngineFilterTests`. Ranking changes are bugs: add a case before touching weights.
use engine::query::{Filter, FilterField, FilterOp, parse};
use engine::search::{FilterFields, Hit, Index, IndexData, SetGroup};
use std::collections::HashMap;

fn mini(id: &str, name: &str) -> Hit {
    Hit { id: id.into(), name: name.into(), colors: vec![], set_code: None, set_name: None, rarity: None }
}

fn mini_set(id: &str, name: &str, colors: &[&str], code: &str, set: &str, rarity: Option<&str>) -> Hit {
    Hit {
        id: id.into(), name: name.into(), colors: colors.iter().map(|s| s.to_string()).collect(),
        set_code: Some(code.into()), set_name: Some(set.into()), rarity: rarity.map(Into::into),
    }
}

fn group(code: &str, name: &str, ids: &[&str]) -> SetGroup {
    SetGroup { code: code.into(), name: name.into(), member_ids: ids.iter().map(|s| s.to_string()).collect() }
}

fn corpus() -> Vec<Hit> {
    ["Lightning Bolt", "Lightning Strike", "Lightning Helix", "Chain Lightning", "Lightning Greaves",
     "Bolt of Keranos", "Shock", "Ball Lightning", "Jace, the Mind Sculptor", "Black Lotus"]
        .iter().enumerate().map(|(i, n)| mini(&format!("id-{i}"), n)).collect()
}

fn engine(minis: Vec<Hit>) -> Index {
    Index::new(IndexData { minis, ..Default::default() })
}

fn names(ix: &Index, q: &str, limit: usize) -> Vec<String> {
    ix.search(q, limit).hits.into_iter().map(|h| h.name).collect()
}

fn pos(v: &[String], n: &str) -> usize {
    v.iter().position(|x| x == n).unwrap_or(usize::MAX)
}

#[test]
fn prefix_beats_substring() {
    let ix = engine(corpus());
    let r = names(&ix, "lightni", 20);
    assert_eq!(r[0], "Lightning Bolt");
    assert!(pos(&r, "Lightning Bolt") < pos(&r, "Chain Lightning"));
}

#[test]
fn case_insensitive() {
    let ix = engine(corpus());
    assert_eq!(names(&ix, "BOLT", 20).first(), names(&ix, "bolt", 20).first());
    assert!(!names(&ix, "BOLT", 20).is_empty());
}

#[test]
fn exact_match_wins_over_prefix() {
    assert_eq!(names(&engine(corpus()), "shock", 20)[0], "Shock");
}

#[test]
fn token_start_match_for_second_word() {
    assert!(names(&engine(corpus()), "bolt", 20).contains(&"Lightning Bolt".to_string()));
}

#[test]
fn initialism_subsequence() {
    assert!(names(&engine(corpus()), "lb", 20).contains(&"Lightning Bolt".to_string()));
}

fn set_corpus() -> Index {
    Index::new(IndexData {
        minis: vec![
            mini_set("s0", "Mox Sapphire", &[], "MSC", "Mishra's Set", None),
            mini_set("s1", "Black Lotus", &[], "MSC", "Mishra's Set", None),
            mini_set("s2", "Modern Staple", &[], "MH3", "Modern Horizons 3", None),
            mini_set("s3", "Mind Sculptor Clone", &[], "JTM", "Jace's Tome", None),
            mini_set("s4", "Shock", &[], "M21", "Core 2021", None),
            mini_set("s5", "MSC Promo", &[], "ZZZ", "Promo Set", None),
        ],
        sets: vec![
            group("MSC", "Mishra's Set", &["s0", "s1"]),
            group("MH3", "Modern Horizons 3", &["s2"]),
            group("JTM", "Jace's Tome", &["s3"]),
            group("M21", "Core 2021", &["s4"]),
            group("ZZZ", "Promo Set", &["s5"]),
        ],
        ..Default::default()
    })
}

#[test]
fn exact_set_code_surfaces_set_cards() {
    let r = names(&set_corpus(), "msc", 20);
    assert!(r.contains(&"Mox Sapphire".to_string()) && r.contains(&"Black Lotus".to_string()));
}

#[test]
fn set_code_beats_name_subsequence() {
    let r = names(&set_corpus(), "msc", 20);
    assert!(pos(&r, "Mox Sapphire") < pos(&r, "Mind Sculptor Clone"));
}

#[test]
fn name_prefix_beats_set_code() {
    assert_eq!(names(&set_corpus(), "msc", 20)[0], "MSC Promo");
}

#[test]
fn set_name_prefix_surfaces_cards() {
    assert!(names(&set_corpus(), "modern", 20).contains(&"Modern Staple".to_string()));
}

#[test]
fn set_name_returns_all_members() {
    let r = names(&set_corpus(), "mishra", 20);
    assert!(r.contains(&"Mox Sapphire".to_string()) && r.contains(&"Black Lotus".to_string()));
}

#[test]
fn empty_query_returns_nothing() {
    let ix = engine(corpus());
    assert!(names(&ix, "", 20).is_empty());
    assert!(names(&ix, "   ", 20).is_empty());
}

#[test]
fn limit_respected() {
    assert!(names(&engine(corpus()), "l", 3).len() <= 3);
}

#[test]
fn top_k_limit_is_prefix_of_full_ranking() {
    let ix = engine(corpus());
    let full = names(&ix, "l", 10_000);
    assert!(full.len() > 1);
    for n in 1..=full.len() {
        assert_eq!(names(&ix, "l", n), full[..n]);
    }
}

#[test]
fn top_k_filter_only_limit_is_prefix() {
    let ix = engine(vec![
        mini_set("a", "Aaa", &[], "ABC", "Alpha", None), mini_set("b", "Bb", &[], "ABC", "Alpha", None),
        mini_set("c", "Cccc", &[], "ABC", "Alpha", None), mini_set("d", "Dd", &[], "ABC", "Alpha", None),
    ]);
    let ids = |n| ix.search_counted("", &parse("s:abc").filters, n).hits.into_iter().map(|h| h.id).collect::<Vec<_>>();
    let full = ids(10_000);
    assert_eq!(full.len(), 4);
    for n in 1..=4 { assert_eq!(ids(n), full[..n]); }
}

#[test]
fn search_counted_reports_total_beyond_limit() {
    let ix = engine(corpus());
    let unlimited = names(&ix, "l", 1000).len();
    let c = ix.search_counted("l", &[], 3);
    assert!(c.hits.len() <= 3);
    assert_eq!(c.total, unlimited);
    assert!(c.total >= c.hits.len());
}

// Edge semantics: guard the ASCII fast path against the Unicode-aware grapheme path.
fn edge(q: &str) -> Vec<String> {
    let ix = engine(["Æther Vial", "Aether Vial", "Lim-Dûl's Vault", "Jötun Grunt", "Jotun Owl Keeper",
        "Bolt", "Lightning  Bolt", "Fire // Ice", "Boltwave", "Abolt"]
        .iter().enumerate().map(|(i, n)| mini(&format!("e{i}"), n)).collect());
    names(&ix, q, 50)
}

#[test]
fn full_ranking_order_is_stable() {
    assert_eq!(edge("bolt"), ["Bolt", "Boltwave", "Lightning  Bolt", "Abolt"]);
    assert_eq!(edge("lb"), ["Lightning  Bolt"]);
}

#[test]
fn non_ascii_names_match_by_character() {
    assert_eq!(edge("æther")[0], "Æther Vial");
    assert_eq!(edge("aether"), ["Aether Vial"]);
    assert_eq!(edge("jötun"), ["Jötun Grunt"]);
    assert_eq!(edge("jotun"), ["Jotun Owl Keeper"]);
    assert_eq!(edge("dûl")[0], "Lim-Dûl's Vault");
    assert_eq!(edge("ther"), ["Æther Vial", "Aether Vial"]);
    // Decomposed input (u + combining circumflex) equals the precomposed name character.
    assert_eq!(edge("du\u{302}l")[0], "Lim-Dûl's Vault");
}

#[test]
fn multi_word_token_start() {
    assert_eq!(edge("lig bol")[0], "Lightning  Bolt");
    assert_eq!(edge("lim vau")[0], "Lim-Dûl's Vault");
    assert_eq!(edge("fire ice"), ["Fire // Ice"]);
    assert_eq!(edge("fire // ice")[0], "Fire // Ice");
}

// ---- inline filters -------------------------------------------------------------------------

fn ff(colors: &[&str], t: &str, o: &str, cmc: f64, r: &[&str]) -> FilterFields {
    FilterFields {
        colors: colors.iter().map(|s| s.to_string()).collect(),
        type_line_lower: Some(t.into()), oracle_text_lower: Some(o.into()), cmc: Some(cmc),
        rarities: r.iter().map(|s| s.to_string()).collect(),
    }
}

fn filter_engine() -> Index {
    let fields: HashMap<String, FilterFields> = HashMap::from([
        ("bolt".into(), ff(&["R"], "instant", "lightning bolt deals 3 damage to any target", 1.0, &["common"])),
        ("shock".into(), ff(&["R"], "instant", "shock deals 2 damage to any target", 1.0, &["common", "uncommon"])),
        ("jace".into(), ff(&["U"], "legendary planeswalker — jace", "brainstorm: draw three cards", 4.0, &["mythic"])),
        ("bear".into(), ff(&["G"], "creature — bear", "", 2.0, &["common"])),
        ("drake".into(), ff(&["U"], "creature — bird", "flying", 2.0, &["uncommon"])),
    ]);
    Index::new(IndexData {
        minis: vec![
            mini_set("bolt", "Lightning Bolt", &["R"], "LEA", "Limited Edition Alpha", Some("common")),
            mini_set("shock", "Shock", &["R"], "M21", "Core 2021", Some("common")),
            mini_set("jace", "Jace, the Mind Sculptor", &["U"], "WWK", "Worldwake", Some("mythic")),
            mini_set("bear", "Grizzly Bears", &["G"], "M21", "Core 2021", Some("common")),
            mini_set("drake", "Storm Crow", &["U"], "9ED", "Ninth Edition", Some("uncommon")),
        ],
        sets: vec![group("M21", "Core 2021", &["shock", "bear"])],
        fields,
    })
}

fn flt(field: FilterField, op: FilterOp, value: &str, negated: bool) -> Vec<Filter> {
    vec![Filter { field, op, value: value.into(), negated }]
}

fn fnames(name: &str, f: Vec<Filter>) -> Vec<String> {
    filter_engine().search_counted(name, &f, 20).hits.into_iter().map(|h| h.name).collect()
}

fn sorted(mut v: Vec<String>) -> Vec<String> { v.sort(); v }

#[test]
fn rarity_filter_narrows_name_matches() {
    let n = fnames("s", flt(FilterField::Rarity, FilterOp::Eq, "uncommon", false));
    assert!(n.contains(&"Storm Crow".to_string()) && n.contains(&"Shock".to_string()));
    assert!(!n.contains(&"Grizzly Bears".to_string()));
}

#[test]
fn pauper_filter_ever_printed_common() {
    assert_eq!(sorted(fnames("", flt(FilterField::Rarity, FilterOp::Eq, "common", false))),
        ["Grizzly Bears", "Lightning Bolt", "Shock"]);
}

#[test]
fn rarity_comparison_greater_equal() {
    assert_eq!(fnames("", flt(FilterField::Rarity, FilterOp::Ge, "rare", false)), ["Jace, the Mind Sculptor"]);
}

#[test]
fn color_filter() {
    assert_eq!(sorted(fnames("", flt(FilterField::Color, FilterOp::Eq, "r", false))), ["Lightning Bolt", "Shock"]);
}

#[test]
fn type_filter_is_substring() {
    assert_eq!(sorted(fnames("", flt(FilterField::Type, FilterOp::Eq, "creature", false))), ["Grizzly Bears", "Storm Crow"]);
}

#[test]
fn mana_value_comparison() {
    assert_eq!(fnames("", flt(FilterField::ManaValue, FilterOp::Ge, "3", false)), ["Jace, the Mind Sculptor"]);
    assert_eq!(sorted(fnames("", flt(FilterField::ManaValue, FilterOp::Eq, "1", false))), ["Lightning Bolt", "Shock"]);
}

#[test]
fn oracle_text_filter() {
    assert_eq!(fnames("", flt(FilterField::Oracle, FilterOp::Eq, "draw", false)), ["Jace, the Mind Sculptor"]);
}

#[test]
fn negation_excludes() {
    let n = fnames("", flt(FilterField::Type, FilterOp::Eq, "creature", true));
    assert!(!n.contains(&"Grizzly Bears".to_string()) && n.contains(&"Lightning Bolt".to_string()));
}

#[test]
fn set_filter_uses_membership() {
    assert_eq!(sorted(fnames("", flt(FilterField::Set, FilterOp::Eq, "m21", false))), ["Grizzly Bears", "Shock"]);
}

#[test]
fn name_and_filter_intersect() {
    assert_eq!(fnames("bolt", flt(FilterField::Rarity, FilterOp::Eq, "common", false)), ["Lightning Bolt"]);
    assert!(fnames("bolt", flt(FilterField::Rarity, FilterOp::Eq, "mythic", false)).is_empty());
}

#[test]
fn no_filters_matches_legacy_behavior() {
    let ix = filter_engine();
    assert_eq!(ix.search("bolt", 20).hits[0].name, "Lightning Bolt");
    assert_eq!(ix.search_counted("", &[], 20).hits.len(), 0);
}

#[test]
fn parsed_query_drives_filters_end_to_end() {
    let r = filter_engine().search("bolt r:common", 20);
    assert_eq!(r.hits.iter().map(|h| h.name.as_str()).collect::<Vec<_>>(), ["Lightning Bolt"]);
    assert_eq!(r.total, 1);
}
