//! Search-box parser: free-text name + Scryfall-style inline filters (`bolt r:common`,
//! `c:r t:creature mv>=3`, `o:"draw a card"`, `-t:land`). 1:1 port of the former Swift
//! `QueryParser`; it works on grapheme clusters because Swift iterated `Character`s.
use crate::lower;
use unicode_segmentation::UnicodeSegmentation;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FilterField { Rarity, Color, Type, ManaValue, Oracle, Set }

/// `:` and `=` both map to `Eq`; the field's matcher decides if that means "equals" or "contains".
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FilterOp { Eq, Lt, Le, Gt, Ge }

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Filter {
    pub field: FilterField,
    pub op: FilterOp,
    pub value: String,
    pub negated: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Parsed {
    pub name: String,
    pub filters: Vec<Filter>,
}

fn field_for(key: &str) -> Option<FilterField> {
    Some(match key {
        "r" | "rarity" => FilterField::Rarity,
        "c" | "color" => FilterField::Color,
        "t" | "type" => FilterField::Type,
        "mv" | "cmc" => FilterField::ManaValue,
        "o" | "oracle" => FilterField::Oracle,
        "s" | "set" => FilterField::Set,
        _ => return None,
    })
}

/// Foundation's `CharacterSet.whitespaces`: Zs + tab.
fn is_blank(c: char) -> bool {
    matches!(c, '\t' | ' ' | '\u{A0}' | '\u{1680}' | '\u{2000}'..='\u{200A}' | '\u{202F}' | '\u{205F}' | '\u{3000}')
}

pub fn parse(raw: &str) -> Parsed {
    let mut name_parts: Vec<String> = Vec::new();
    let mut filters = Vec::new();
    for token in tokenize(raw) {
        match parse_filter(&token) {
            Some(f) => filters.push(f),
            None => name_parts.push(unquote(&token)),
        }
    }
    let name = name_parts.join(" ").trim_matches(is_blank).to_string();
    Parsed { name, filters }
}

/// Splits on spaces, keeping double-quoted runs together.
fn tokenize(s: &str) -> Vec<String> {
    let mut tokens = Vec::new();
    let mut cur = String::new();
    let mut in_quotes = false;
    for g in s.graphemes(true) {
        if g == "\"" {
            in_quotes = !in_quotes;
            cur.push_str(g);
        } else if g == " " && !in_quotes {
            if !cur.is_empty() { tokens.push(std::mem::take(&mut cur)); }
        } else {
            cur.push_str(g);
        }
    }
    if !cur.is_empty() { tokens.push(cur); }
    tokens
}

fn parse_filter(token: &str) -> Option<Filter> {
    let gs: Vec<&str> = token.graphemes(true).collect();
    let mut i = 0;
    let negated = gs.first() == Some(&"-");
    if negated { i = 1; }
    // Key = leading run of letters (Swift `Character.isLetter` = first scalar is alphabetic).
    let key_len = gs[i..].iter().take_while(|g| g.chars().next().is_some_and(char::is_alphabetic)).count();
    if key_len == 0 { return None; }
    let field = field_for(&lower(&gs[i..i + key_len].concat()))?;
    let rest = &gs[i + key_len..];
    let at = |k: usize, s: &str| rest.get(k) == Some(&s);
    let (op, skip) = if at(0, ">") && at(1, "=") { (FilterOp::Ge, 2) }
        else if at(0, "<") && at(1, "=") { (FilterOp::Le, 2) }
        else if at(0, ">") { (FilterOp::Gt, 1) }
        else if at(0, "<") { (FilterOp::Lt, 1) }
        else if at(0, "=") || at(0, ":") { (FilterOp::Eq, 1) }
        else { return None };
    let value = lower(&unquote(&rest[skip..].concat()));
    if value.is_empty() { return None; }
    Some(Filter { field, op, value, negated })
}

/// Strips one pair of surrounding double quotes.
fn unquote(s: &str) -> String {
    let gs: Vec<&str> = s.graphemes(true).collect();
    if gs.len() >= 2 && gs[0] == "\"" && gs[gs.len() - 1] == "\"" {
        gs[1..gs.len() - 1].concat()
    } else {
        s.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn f(field: FilterField, op: FilterOp, value: &str, negated: bool) -> Filter {
        Filter { field, op, value: value.into(), negated }
    }

    #[test]
    fn plain_query_has_no_filters() {
        let p = parse("lightning bolt");
        assert_eq!(p.name, "lightning bolt");
        assert!(p.filters.is_empty());
    }

    #[test]
    fn name_plus_rarity_filter() {
        let p = parse("bolt r:common");
        assert_eq!(p.name, "bolt");
        assert_eq!(p.filters, [f(FilterField::Rarity, FilterOp::Eq, "common", false)]);
    }

    #[test]
    fn rarity_comparison_operator() {
        let p = parse("r>=rare");
        assert_eq!(p.name, "");
        assert_eq!(p.filters, [f(FilterField::Rarity, FilterOp::Ge, "rare", false)]);
    }

    #[test]
    fn all_operators_parse() {
        assert_eq!(parse("mv>3").filters[0].op, FilterOp::Gt);
        assert_eq!(parse("mv<3").filters[0].op, FilterOp::Lt);
        assert_eq!(parse("mv<=3").filters[0].op, FilterOp::Le);
        assert_eq!(parse("mv=3").filters[0].op, FilterOp::Eq);
        assert_eq!(parse("cmc:3").filters[0].field, FilterField::ManaValue);
    }

    #[test]
    fn quoted_oracle_value() {
        let p = parse("o:\"draw a card\"");
        assert_eq!(p.name, "");
        assert_eq!(p.filters, [f(FilterField::Oracle, FilterOp::Eq, "draw a card", false)]);
    }

    #[test]
    fn negation() {
        let p = parse("elf -t:land");
        assert_eq!(p.name, "elf");
        assert_eq!(p.filters, [f(FilterField::Type, FilterOp::Eq, "land", true)]);
    }

    #[test]
    fn aliases_map_to_same_field() {
        assert_eq!(parse("rarity:rare").filters[0].field, FilterField::Rarity);
        assert_eq!(parse("color:r").filters[0].field, FilterField::Color);
        assert_eq!(parse("type:creature").filters[0].field, FilterField::Type);
        assert_eq!(parse("oracle:flying").filters[0].field, FilterField::Oracle);
        assert_eq!(parse("set:m21").filters[0].field, FilterField::Set);
    }

    #[test]
    fn unknown_key_falls_back_to_name() {
        let p = parse("foo:bar");
        assert_eq!(p.name, "foo:bar");
        assert!(p.filters.is_empty());
    }

    #[test]
    fn multiple_filters_and_name() {
        let p = parse("c:r t:creature mv>=3 dragon");
        assert_eq!(p.name, "dragon");
        assert_eq!(p.filters.len(), 3);
        assert!(p.filters.contains(&f(FilterField::Color, FilterOp::Eq, "r", false)));
        assert!(p.filters.contains(&f(FilterField::Type, FilterOp::Eq, "creature", false)));
        assert!(p.filters.contains(&f(FilterField::ManaValue, FilterOp::Ge, "3", false)));
    }

    #[test]
    fn values_are_lowercased() {
        assert_eq!(parse("R:Common").filters[0].value, "common");
    }
}
