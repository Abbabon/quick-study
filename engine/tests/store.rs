//! App-facing reads and card-list edits (ports of the Swift `CardStore*Tests`).
use engine::scryfall::{Artwork, Card, Printing, SetInfo};
use engine::{db, store, today_minus_days, today_plus_days};

fn open() -> (tempfile::TempDir, rusqlite::Connection) {
    let d = tempfile::tempdir().unwrap();
    let c = db::open(&d.path().join("cards.sqlite")).unwrap();
    (d, c)
}

fn card(id: &str, name: &str, days_ago: Option<u32>) -> Card {
    Card { id: id.into(), name: name.into(), mana_cost: Some("{R}".into()), type_line: Some("Instant".into()),
        oracle_text: None, power: None, toughness: None, colors: vec!["R".into(), "W".into()], scryfall_uri: "u".into(),
        set_code: Some("TST".into()), set_name: Some("Test Set".into()), oracle_id: Some(format!("o-{id}")),
        date_added: days_ago.map(today_minus_days), rarity: Some("uncommon".into()), cmc: Some(2.0) }
}

fn printing(id: &str, oracle: &str, set: &str, released: &str) -> Printing {
    Printing { printing_id: id.into(), oracle_id: oracle.into(), set_code: set.into(), set_name: format!("{set} name"),
        collector_number: Some("1".into()), released_at: Some(released.into()), rarity: Some("common".into()),
        digital: set == "MTGO", games: vec!["paper".into()] }
}

#[test]
fn card_detail_roundtrip_and_missing() {
    let (_d, mut c) = open();
    db::upsert_cards(&mut c, &[card("a", "Æther Vial", Some(1))]).unwrap();
    let got = store::card(&c, "a").unwrap().unwrap();
    assert_eq!((got.name.as_str(), got.colors.clone(), got.rarity.as_deref(), got.cmc), ("Æther Vial", vec!["R".to_string(), "W".into()], Some("uncommon"), Some(2.0)));
    assert_eq!(got.oracle_id.as_deref(), Some("o-a"));
    assert!(store::card(&c, "zzz").unwrap().is_none());
    assert_eq!(store::count(&c, "cards").unwrap(), 1);
    db::set_meta(&c, "last_refresh", "x").unwrap();
    assert_eq!(db::meta(&c, "last_refresh").unwrap().as_deref(), Some("x"));
    assert_eq!(db::meta(&c, "nope").unwrap(), None);
}

#[test]
fn printings_newest_first_with_set_tiebreak() {
    let (_d, mut c) = open();
    db::upsert_printings(&mut c, &[
        printing("1", "o", "LEA", "1993-08-05"), printing("2", "o", "M21", "2020-07-03"),
        printing("3", "o", "MTGO", "2020-07-03"), printing("4", "other", "XXX", "2021-01-01"),
    ]).unwrap();
    let ps = store::printings(&c, "o").unwrap();
    assert_eq!(ps.iter().map(|p| p.set_code.as_str()).collect::<Vec<_>>(), ["M21", "MTGO", "LEA"]);
    assert!(ps[1].digital && !ps[0].digital);
    assert_eq!(ps[0].games, ["paper"]);
}

#[test]
fn recently_added_window_order_limit() {
    let (_d, mut c) = open();
    db::upsert_cards(&mut c, &[card("a", "Alpha", Some(1)), card("b", "Bravo", Some(5)), card("c", "Charlie", Some(40))]).unwrap();
    let r = store::recently_added(&c, 30, 200).unwrap();
    assert_eq!(r.iter().map(|x| x.id.as_str()).collect::<Vec<_>>(), ["a", "b"]);
    assert_eq!(r[0].set_name.as_deref(), Some("Test Set"));
    assert_eq!(store::recently_added(&c, 30, 1).unwrap().len(), 1);
}

#[test]
fn future_dated_spoiler_surfaces_via_first_seen() {
    let (_d, mut c) = open();
    let mut future = card("future", "Spoiler", None);
    future.date_added = Some("2999-01-01".into());
    db::upsert_cards(&mut c, &[card("past", "Past", Some(3)), future]).unwrap();
    let r = store::recently_added(&c, 30, 200).unwrap();
    assert_eq!(r.iter().map(|x| x.id.as_str()).collect::<Vec<_>>(), ["future", "past"]);
    assert_eq!(r[0].first_seen, engine::today());
}

#[test]
fn artworks_load_with_colors() {
    let (_d, mut c) = open();
    let art = |i: &str| Artwork { illustration_id: i.into(), card_id: "c".into(), card_name: "Helix".into(), artist: "X".into(),
        art_crop_url: "u".into(), colors: vec!["R".into(), "W".into()], set_code: None };
    db::upsert_artworks(&mut c, &[art("a"), art("b")]).unwrap();
    assert_eq!(store::count(&c, "artworks").unwrap(), 2);
    let all = store::artworks(&c).unwrap();
    assert_eq!(all.len(), 2);
    assert_eq!(all[0].colors, ["R", "W"]);
}

#[test]
fn lists_crud_order_and_cascade() {
    let (_d, mut c) = open();
    db::upsert_cards(&mut c, &[card("a", "Alpha", None), card("b", "Bravo", None), card("c", "Charlie", None)]).unwrap();
    let one = store::create_list(&c, "One").unwrap();
    assert_eq!(one.id.len(), 36);
    assert_eq!(one.id, one.id.to_uppercase());
    let two = store::create_list(&c, "Two").unwrap();
    assert_eq!(store::load_lists(&c).unwrap().iter().map(|l| l.id.clone()).collect::<Vec<_>>().len(), 2);

    for id in ["a", "b", "c"] { store::add_card(&mut c, id, &one.id).unwrap(); }
    store::add_card(&mut c, "a", &one.id).unwrap(); // duplicate: no-op
    store::add_card(&mut c, "b", &two.id).unwrap();
    assert_eq!(items(&c, &one.id), ["a", "b", "c"]);
    assert_eq!(items(&c, &two.id), ["b"]);
    assert_eq!(store::list_items(&c, &one.id).unwrap()[0].rarity, None);

    store::set_list_order(&mut c, &one.id, &["c".into(), "a".into(), "b".into(), "ghost".into()]).unwrap();
    assert_eq!(items(&c, &one.id), ["c", "a", "b"]);

    store::remove_card(&mut c, "a", &one.id).unwrap();
    assert_eq!(items(&c, &one.id), ["c", "b"]);
    let lists = store::load_lists(&c).unwrap();
    assert_eq!(lists.iter().find(|l| l.id == one.id).unwrap().item_count, 2);

    store::rename_list(&c, &one.id, "Renamed").unwrap();
    assert_eq!(store::load_lists(&c).unwrap().iter().find(|l| l.id == one.id).unwrap().name, "Renamed");

    store::delete_list(&mut c, &one.id).unwrap();
    assert_eq!(store::load_lists(&c).unwrap().len(), 1);
    assert!(items(&c, &one.id).is_empty());
    let orphans: i64 = c.query_row("SELECT COUNT(*) FROM card_list_items WHERE list_id = ?", [&one.id], |r| r.get(0)).unwrap();
    assert_eq!(orphans, 0);
}

#[test]
fn list_items_skip_cards_missing_from_cards() {
    let (_d, mut c) = open();
    db::upsert_cards(&mut c, &[card("a", "Alpha", None)]).unwrap();
    let l = store::create_list(&c, "L").unwrap();
    store::add_card(&mut c, "a", &l.id).unwrap();
    store::add_card(&mut c, "gone", &l.id).unwrap();
    assert_eq!(store::list_items(&c, &l.id).unwrap().len(), 1);
    assert_eq!(store::load_lists(&c).unwrap()[0].item_count, 2);
}

fn items(c: &rusqlite::Connection, l: &str) -> Vec<String> {
    store::list_items(c, l).unwrap().into_iter().map(|h| h.id).collect()
}

#[test]
fn recent_sets_filters_orders_and_previews() {
    let (_d, mut c) = open();
    assert!(store::recent_sets(&c, 5, 14).unwrap().is_empty());
    let set = |code: &str, ty: &str, released: Option<String>| SetInfo { code: code.into(), name: format!("{code} name"),
        released_at: released, set_type: Some(ty.into()), card_count: Some(1), icon_svg_uri: Some(format!("https://x/{code}.svg")) };
    db::upsert_sets(&mut c, &[
        set("old", "expansion", Some("2020-01-01".into())), set("new", "commander", Some(today_minus_days(3))),
        set("soon", "expansion", Some(today_plus_days(7))), set("far", "expansion", Some(today_plus_days(60))),
        set("tok", "token", Some(today_minus_days(1))), set("nodate", "expansion", None),
    ]).unwrap();
    let r = store::recent_sets(&c, 5, 14).unwrap();
    assert_eq!(r.iter().map(|s| s.code.as_str()).collect::<Vec<_>>(), ["soon", "new", "old"]);
    assert_eq!(r[0].icon_svg_uri.as_deref(), Some("https://x/soon.svg"));
    assert_eq!(store::recent_sets(&c, 1, 14).unwrap().len(), 1);
}

#[test]
fn random_card_id_none_then_some() {
    let (_d, mut c) = open();
    assert_eq!(store::random_card_id(&c).unwrap(), None);
    db::upsert_cards(&mut c, &[card("a", "Alpha", None)]).unwrap();
    assert_eq!(store::random_card_id(&c).unwrap().as_deref(), Some("a"));
}
