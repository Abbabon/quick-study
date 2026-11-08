use engine::db;
use engine::images::{art_items, card_items};
use engine::scryfall::*;
use std::collections::HashSet;
use std::io::Write;

fn fixture(contents: &str) -> tempfile::NamedTempFile {
    let mut f = tempfile::NamedTempFile::new().unwrap();
    f.write_all(contents.as_bytes()).unwrap();
    f
}

fn card(id: &str, name: &str, date: Option<&str>) -> Card {
    Card { id: id.into(), name: name.into(), mana_cost: None, type_line: None, oracle_text: None, power: None,
        toughness: None, colors: vec![], scryfall_uri: String::new(), set_code: None, set_name: None,
        oracle_id: None, date_added: date.map(Into::into), rarity: None, cmc: None }
}

fn store() -> (tempfile::TempDir, rusqlite::Connection) {
    let d = tempfile::tempdir().unwrap();
    let c = db::open(&d.path().join("cards.sqlite")).unwrap();
    (d, c)
}

#[test]
fn lowercase_matches_swift_per_scalar() {
    assert_eq!(engine::lower("Æther Lim-Dûl Jötun"), "æther lim-dûl jötun");
    assert_eq!(engine::lower("ΟΔΥΣΣΕΥΣ"), "οδυσσευσ"); // no final-sigma context, like Swift
}

#[test]
fn bulk_index_decodes_current_shape() {
    let json = r#"{"object":"list","data":[
      {"object":"bulk_data","type":"oracle_cards","updated_at":"2026-11-07T22:02:07.434+00:00",
       "jsonl_download_uri":"https://data.scryfall.io/oracle-cards/x.jsonl.gz","compressed_size":25360662},
      {"object":"bulk_data","type":"future_thing","updated_at":"2026-11-07T22:00:00.000+00:00"}]}"#;
    let infos = decode_bulk_index(json.as_bytes()).unwrap();
    assert_eq!(infos.len(), 2);
    assert_eq!(infos[0].compressed_size, Some(25360662));
    assert!(infos[1].jsonl_download_uri.is_none());
}

#[test]
fn back_face_only_for_true_dfcs() {
    let f = fixture(r#"[
      {"id":"front-only","name":"Lightning Bolt","layout":"normal","image_uris":{"normal":"https://img/front-only.jpg"}},
      {"id":"dfc","name":"A // B","layout":"transform","card_faces":[
         {"name":"A","image_uris":{"normal":"https://img/dfc-front.jpg"}},{"name":"B","image_uris":{"normal":"https://img/dfc-back.jpg"}}]},
      {"id":"split","name":"Fire // Ice","layout":"split","image_uris":{"normal":"https://img/split.jpg"},"card_faces":[{"name":"Fire"},{"name":"Ice"}]},
      {"id":"token-dfc","name":"T","layout":"double_faced_token","card_faces":[
         {"name":"A","image_uris":{"normal":"https://img/t-front.jpg"}},{"name":"B","image_uris":{"normal":"https://img/t-back.jpg"}}]}]"#);
    let refs = parse_image_refs(f.path()).unwrap();
    let by = |id: &str| refs.iter().find(|r| r.id == id);
    assert_eq!(by("dfc").unwrap().image_url, "https://img/dfc-front.jpg");
    assert_eq!(by("dfc").unwrap().back_image_url.as_deref(), Some("https://img/dfc-back.jpg"));
    assert!(by("front-only").unwrap().back_image_url.is_none());
    assert!(by("split").unwrap().back_image_url.is_none());
    assert!(by("token-dfc").is_none());
}

#[test]
fn card_items_expand_back_faces_without_record_id() {
    let refs = vec![
        CardImageRef { id: "a".into(), image_url: "https://img/a.jpg".into(), back_image_url: None },
        CardImageRef { id: "b".into(), image_url: "https://img/b.jpg".into(), back_image_url: Some("https://img/b-back.jpg".into()) },
    ];
    let items = card_items(&refs);
    assert_eq!(items.len(), 3);
    assert_eq!(items[0].dest.file_name().unwrap(), "a.jpg");
    assert_eq!(items[1].record_id.as_deref(), Some("b"));
    assert_eq!(items[2].url, "https://img/b-back.jpg");
    assert_eq!(items[2].dest.file_name().unwrap(), "b_back.jpg");
    assert!(items[2].record_id.is_none());
    let art = art_items(&[ArtImageRef { illustration_id: "i".into(), image_url: "u1".into() },
                          ArtImageRef { illustration_id: "i".into(), image_url: "u2".into() }]);
    assert_eq!(art.len(), 1);
    assert_eq!(art[0].url, "u1");
}

#[test]
fn printings_filter_and_map() {
    let f = fixture(r#"[
      {"id":"p1","oracle_id":"o1","set":"m21","set_name":"Core Set 2021","collector_number":"148","released_at":"2020-07-03","rarity":"uncommon","digital":false,"games":["paper","mtgo"],"lang":"en","layout":"normal"},
      {"id":"p2","oracle_id":"o1","set":"pmtg1","set_name":"MO Promos","released_at":"2019-01-01","rarity":"rare","digital":true,"games":["mtgo"],"lang":"en","layout":"normal"},
      {"id":"p3","oracle_id":"o1","set":"m21","set_name":"x","lang":"ja","layout":"normal"},
      {"id":"p4","oracle_id":"o2","set":"tm21","set_name":"x","lang":"en","layout":"token"},
      {"id":"p5","set":"m21","set_name":"x","lang":"en","layout":"normal"}]"#);
    let p = parse_printings(f.path()).unwrap();
    assert_eq!(p.iter().map(|p| p.printing_id.as_str()).collect::<Vec<_>>(), ["p1", "p2"]);
    assert_eq!(p[0].set_code, "M21");
    assert_eq!(p[0].games, ["paper", "mtgo"]);
    assert!(p[1].digital);
}

#[test]
fn card_parse_rarity_cmc_faces_and_dates() {
    // JSONL form (what Scryfall serves), blank line tolerated.
    let f = fixture("{\"id\":\"c1\",\"name\":\"Bolt\",\"cmc\":1.0,\"rarity\":\"common\",\"colors\":[\"R\"],\"layout\":\"normal\",\"set\":\"lea\",\"released_at\":\"1993-08-05\",\"oracle_id\":\"o1\"}\n\n\
        {\"id\":\"c2\",\"name\":\"Fire // Ice\",\"layout\":\"split\",\"preview\":{\"previewed_at\":\"2020-01-01\"},\"released_at\":\"2020-02-02\",\"card_faces\":[{\"name\":\"Fire\",\"mana_cost\":\"{1}{R}\",\"oracle_text\":\"a\",\"colors\":[\"R\"]},{\"name\":\"Ice\",\"oracle_text\":\"b\"}]}\n\
        {\"id\":\"t\",\"name\":\"Tok\",\"layout\":\"token\"}\n");
    let cards = parse_cards(f.path()).unwrap();
    assert_eq!(cards.len(), 2);
    assert_eq!((cards[0].rarity.as_deref(), cards[0].cmc, cards[0].set_code.as_deref()), (Some("common"), Some(1.0), Some("LEA")));
    assert_eq!(cards[0].scryfall_uri, "https://scryfall.com/card/c1");
    assert_eq!(cards[1].mana_cost.as_deref(), Some("{1}{R}"));
    assert_eq!(cards[1].oracle_text.as_deref(), Some("a\n//\nb"));
    assert_eq!(cards[1].colors, ["R"]);
    assert_eq!(cards[1].date_added.as_deref(), Some("2020-01-01")); // preview beats release
}

#[test]
fn artworks_flatten_faces_and_skip_junk() {
    let f = fixture(r#"[
      {"id":"a","name":"Bolt","artist":"X","illustration_id":"i1","image_uris":{"art_crop":"u1"},"colors":["R"],"set":"lea","layout":"normal"},
      {"id":"b","name":"A // B","artist":"Y","layout":"transform","color_identity":["U"],"card_faces":[
         {"name":"A","illustration_id":"i2","image_uris":{"art_crop":"u2"}},{"name":"B","artist":"Z","illustration_id":"i3","image_uris":{"art_crop":"u3"},"colors":["B"]}]},
      {"id":"c","name":"Tok","artist":"Q","illustration_id":"i4","image_uris":{"art_crop":"u4"},"layout":"token"}]"#);
    let a = parse_artworks(f.path()).unwrap();
    assert_eq!(a.iter().map(|a| a.illustration_id.as_str()).collect::<Vec<_>>(), ["i1", "i2", "i3"]);
    assert_eq!(a[0].set_code.as_deref(), Some("LEA"));
    assert_eq!((a[1].artist.as_str(), a[1].colors.clone()), ("Y", vec!["U".to_string()]));
    assert_eq!((a[2].artist.as_str(), a[2].colors.clone()), ("Z", vec!["B".to_string()]));
}

#[test]
fn upsert_keeps_first_seen_and_min_date_added() {
    let (_d, mut c) = store();
    db::upsert_cards(&mut c, &[card("a", "Alpha", Some("2030-01-01")), card("o", "Old", Some("1999-01-01"))]).unwrap();
    let row = |c: &rusqlite::Connection, id: &str| -> (Option<String>, Option<String>, String) {
        c.query_row("select date_added, first_seen, name_lower from cards where id=?", [id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?))).unwrap()
    };
    let (_, fs_future, _) = row(&c, "a");
    assert_eq!(fs_future.unwrap(), engine::today()); // future date clamps to today
    assert_eq!(row(&c, "o").1.as_deref(), Some("1999-01-01"));
    db::upsert_cards(&mut c, &[card("a", "Alpha 2", Some("2020-05-05")), card("o", "Old", Some("2025-01-01"))]).unwrap();
    let (da, fs, nl) = row(&c, "a");
    assert_eq!((da.as_deref(), fs.unwrap(), nl.as_str()), (Some("2020-05-05"), engine::today(), "alpha 2")); // date_added moved back
    assert_eq!(row(&c, "o").0.as_deref(), Some("1999-01-01")); // never moves forward
    assert_eq!(db::count_cards(&c).unwrap(), 2);
}

#[test]
fn reconcile_removes_stale_and_remaps_lists() {
    let (_d, mut c) = store();
    db::upsert_cards(&mut c, &[card("old", "Doomsday", None), card("new", "Doomsday", None), card("x", "Lonely", None), card("k", "Keep", None)]).unwrap();
    c.execute_batch("insert into card_lists values ('L','W','w','t','t');
        insert into card_list_items values ('L','old',0,'t'),('L','x',1,'t');
        insert into card_lists values ('M','V','v','t','t');
        insert into card_list_items values ('M','old',0,'t'),('M','new',1,'t');").unwrap();
    let keep: HashSet<String> = ["new", "k"].iter().map(|s| s.to_string()).collect();
    assert_eq!(db::reconcile_cards(&mut c, &keep).unwrap(), 2);
    let items = |l: &str| -> Vec<String> {
        c.prepare("select card_id from card_list_items where list_id=? order by position").unwrap()
            .query_map([l], |r| r.get(0)).unwrap().map(Result::unwrap).collect()
    };
    assert_eq!(items("L"), ["new"]); // remapped; dangling 'x' dropped
    assert_eq!(items("M"), ["new"]); // survivor already present: no duplicate
    assert_eq!(db::reconcile_cards(&mut c, &keep).unwrap(), 0);
}

#[test]
fn set_image_paths_uses_images_prefix() {
    let (_d, mut c) = store();
    db::upsert_cards(&mut c, &[card("a", "Alpha", None)]).unwrap();
    db::set_image_paths(&mut c, &["a".to_string(), "missing".to_string()]).unwrap();
    let p: String = c.query_row("select image_path from cards where id='a'", [], |r| r.get(0)).unwrap();
    assert_eq!(p, "images/a.jpg");
}

#[test]
fn artworks_printings_sets_upsert() {
    let (_d, mut c) = store();
    let art = |n: &str| Artwork { illustration_id: "i".into(), card_id: "c".into(), card_name: n.into(), artist: "Åsa".into(),
        art_crop_url: "u".into(), colors: vec!["R".into(), "W".into()], set_code: None };
    db::upsert_artworks(&mut c, &[art("Old"), art("New Name")]).unwrap();
    let (n, al, col): (String, String, String) = c.query_row("select card_name_lower, artist_lower, colors from artworks", [], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?))).unwrap();
    assert_eq!((n.as_str(), al.as_str(), col.as_str()), ("new name", "åsa", r#"["R","W"]"#));
    db::upsert_sets(&mut c, &[SetInfo { code: "M21".into(), name: "n".into(), released_at: None, set_type: None, card_count: Some(3), icon_svg_uri: None }]).unwrap();
    db::upsert_printings(&mut c, &[Printing { printing_id: "p".into(), oracle_id: "o".into(), set_code: "M21".into(), set_name: "n".into(),
        collector_number: None, released_at: None, rarity: None, digital: true, games: vec!["mtgo".into()] }]).unwrap();
    let (d, g): (i64, String) = c.query_row("select digital, games from printings", [], |r| Ok((r.get(0)?, r.get(1)?))).unwrap();
    assert_eq!((d, g.as_str()), (1, r#"["mtgo"]"#));
}
