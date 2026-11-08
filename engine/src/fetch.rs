//! Orchestration of the fetcher phases (port of `Fetcher.swift`).
use crate::scryfall::{self, Client};
use crate::{Result, db, images, iso_now, paths, progress::Emitter};
use std::collections::HashSet;
use std::path::PathBuf;

#[derive(Default, Debug, Clone, Copy)]
pub struct Flags { pub images_only: bool, pub no_images: bool, pub artwork: bool, pub download_art: bool, pub printings: bool }

impl Flags {
    pub fn parse(args: &[String]) -> Self {
        let has = |f: &str| args.iter().any(|a| a == f);
        Self { images_only: has("--images-only"), no_images: has("--no-images"), artwork: has("--artwork"),
            download_art: has("--download-art"), printings: has("--printings") }
    }
}

fn bulk_path(name: &str) -> PathBuf { paths::support_dir().join(name) }

/// 1000 rows per transaction, progress after each batch.
fn batched<T>(rows: &[T], mut write: impl FnMut(&[T]) -> Result<()>, mut tick: impl FnMut(usize)) -> Result<()> {
    let mut done = 0;
    for b in rows.chunks(1000) { write(b)?; done += b.len(); tick(done); }
    Ok(())
}

pub async fn run(flags: Flags, em: &Emitter) -> Result<()> {
    let mut conn = db::open(&paths::database_path())?;
    let client = Client::new()?;
    let prog = |phase: &'static str| move |d: usize, t: usize| em.progress(phase, d, t);

    if flags.artwork {
        let path = bulk_path("bulk-unique-artwork.jsonl");
        em.msg("json", "fetching unique_artwork bulk index");
        let info = client.bulk_info("unique_artwork").await?;
        em.msg("json", &format!("artwork bulk size {} updated_at {}", info.compressed_size.unwrap_or(0), info.updated_at));
        client.download_bulk(&info, &path).await?;
        em.msg("json", "artwork bulk JSON downloaded");

        let arts = scryfall::parse_artworks(&path)?;
        em.progress("artwork", 0, arts.len());
        batched(&arts, |b| db::upsert_artworks(&mut conn, b), |d| em.progress("artwork", d, arts.len()))?;
        db::set_meta(&conn, "artwork_updated_at", &info.updated_at)?;

        if flags.download_art {
            let refs: Vec<_> = arts.iter().map(|a| scryfall::ArtImageRef {
                illustration_id: a.illustration_id.clone(), image_url: a.art_crop_url.clone() }).collect();
            images::download(&client, images::art_items(&refs), None, prog("images")).await?;
        }
        em.msg("done", "artwork complete");
        return Ok(());
    }

    let bulk = bulk_path("bulk-oracle.jsonl");

    if flags.images_only {
        if !bulk.exists() {
            em.msg("json", "bulk JSON missing — downloading");
            let info = client.bulk_info("oracle_cards").await?;
            client.download_bulk(&info, &bulk).await?;
        }
        let refs = scryfall::parse_image_refs(&bulk)?;
        let items = images::card_items(&refs);
        drop(refs);
        images::download(&client, items, Some(&mut conn), prog("images")).await?;
        em.msg("done", "images complete");
        return Ok(());
    }

    em.msg("json", "fetching bulk index");
    let info = client.bulk_info("oracle_cards").await?;
    em.msg("json", &format!("bulk size {} updated_at {}", info.compressed_size.unwrap_or(0), info.updated_at));
    client.download_bulk(&info, &bulk).await?;
    em.msg("json", "bulk JSON downloaded");

    let cards = scryfall::parse_cards(&bulk)?;
    let before = db::count_cards(&conn)?;
    em.progress("ingest", 0, cards.len());
    batched(&cards, |b| db::upsert_cards(&mut conn, b), |d| em.progress("ingest", d, cards.len()))?;
    db::set_meta(&conn, "last_refresh", &iso_now())?;
    db::set_meta(&conn, "bulk_updated_at", &info.updated_at)?;
    // Delta before reconcile = brand-new cards (reconcile only removes already-stale rows).
    let new_cards = db::count_cards(&conn)?.saturating_sub(before);

    // Safe only because `cards` is the full, successfully parsed id set.
    let keep: HashSet<String> = cards.iter().map(|c| c.id.clone()).collect();
    drop(cards);
    let removed = db::reconcile_cards(&mut conn, &keep)?;
    if removed > 0 {
        em.emit("ingest", Some(keep.len()), Some(keep.len()), Some(&format!("removed {removed} stale cards")), None);
    }
    drop(keep);

    if flags.printings {
        em.msg("sets", "fetching set catalog");
        let sets = client.fetch_sets().await?;
        db::upsert_sets(&mut conn, &sets)?;
        em.progress("sets", sets.len(), sets.len());

        let dpath = bulk_path("bulk-default.jsonl");
        em.msg("printings", "fetching default_cards bulk index");
        let pinfo = client.bulk_info("default_cards").await?;
        // Re-download only when the file is missing or Scryfall's stamp moved.
        if !dpath.exists() || db::meta(&conn, "printings_updated_at")?.as_deref() != Some(pinfo.updated_at.as_str()) {
            client.download_bulk(&pinfo, &dpath).await?;
        }
        em.msg("printings", "parsing printings");
        // Two streaming passes (count, then upsert) keep peak memory flat; the app needs `total` up front.
        let total = scryfall::stream_printings(&dpath, 1000, |_, _| Ok(()))?;
        em.progress("printings", 0, total);
        scryfall::stream_printings(&dpath, 1000, |b, n| { db::upsert_printings(&mut conn, b)?; em.progress("printings", n, total); Ok(()) })?;
        db::set_meta(&conn, "printings_updated_at", &pinfo.updated_at)?;
    }

    if flags.no_images {
        em.emit("done", None, None, Some("skipping images"), Some(new_cards));
        return Ok(());
    }
    let refs = scryfall::parse_image_refs(&bulk)?;
    let items = images::card_items(&refs);
    drop(refs);
    images::download(&client, items, Some(&mut conn), prog("images")).await?;
    em.emit("done", None, None, Some("complete"), Some(new_cards));
    Ok(())
}
