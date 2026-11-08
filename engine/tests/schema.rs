//! Schema parity with GRDB: the fixture is `sqlite_master` + the migration ledger of a DB created
//! by the Swift app's GRDB migrator (captured from a fresh `mtg-fetcher` DB at v9).
use engine::db;

fn describe(c: &rusqlite::Connection) -> String {
    let mut st = c.prepare("select type||'|'||name||'|'||tbl_name||'|'||ifnull(sql,'') from sqlite_master order by name").unwrap();
    let mut rows: Vec<String> = st.query_map([], |r| r.get(0)).unwrap().map(Result::unwrap).collect();
    let mut st = c.prepare("select 'ledger|'||identifier from grdb_migrations order by identifier").unwrap();
    rows.extend(st.query_map([], |r| r.get::<_, String>(0)).unwrap().map(Result::unwrap));
    rows.join("\n") + "\n"
}

#[test]
fn rust_schema_matches_grdb() {
    let dir = tempfile::tempdir().unwrap();
    let c = db::open(&dir.path().join("cards.sqlite")).unwrap();
    assert_eq!(describe(&c), include_str!("fixtures/grdb_schema.txt"));
}

#[test]
fn migrate_is_idempotent_and_skips_ledgered() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("cards.sqlite");
    drop(db::open(&p).unwrap());
    let mut c = db::open(&p).unwrap(); // second open must not re-run (ALTER would fail)
    db::migrate(&mut c).unwrap();
}
