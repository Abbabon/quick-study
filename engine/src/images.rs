//! Concurrent, resumable image downloads. Files already on disk are skipped; downloads go
//! to `<dest>.part` then rename. DB `image_path` writes are batched (not one txn per image).
use crate::scryfall::{ArtImageRef, CardImageRef, Client};
use crate::{Result, db, paths};
use futures_util::{StreamExt, stream};
use rusqlite::Connection;
use std::path::PathBuf;
use std::time::{Duration, Instant};

pub const CONCURRENCY: usize = 32;
const FLUSH_EVERY: usize = 500;

pub struct Item { pub url: String, pub dest: PathBuf, pub record_id: Option<String> }

/// Front always, back when present (back faces are never recorded in the DB).
pub fn card_items(refs: &[CardImageRef]) -> Vec<Item> {
    let mut v = Vec::with_capacity(refs.len());
    for r in refs {
        v.push(Item { url: r.image_url.clone(), dest: paths::image_path(&r.id), record_id: Some(r.id.clone()) });
        if let Some(b) = &r.back_image_url {
            v.push(Item { url: b.clone(), dest: paths::back_image_path(&r.id), record_id: None });
        }
    }
    v
}

/// Dedup by illustration_id (DFCs repeat across card objects); first occurrence wins.
pub fn art_items(refs: &[ArtImageRef]) -> Vec<Item> {
    let mut seen = std::collections::HashSet::new();
    refs.iter().filter(|r| seen.insert(r.illustration_id.clone()))
        .map(|r| Item { url: r.image_url.clone(), dest: paths::art_path(&r.illustration_id), record_id: None }).collect()
}

async fn fetch_one(client: &Client, item: &Item) -> bool {
    let go = async {
        let resp = client.http().get(&item.url).header("Accept", "*/*").send().await.ok()?;
        if resp.status().as_u16() != 200 { return None; }
        let bytes = resp.bytes().await.ok()?;
        let mut part = item.dest.clone().into_os_string();
        part.push(".part");
        let part = PathBuf::from(part);
        tokio::fs::write(&part, &bytes).await.ok()?;
        tokio::fs::rename(&part, &item.dest).await.ok()
    };
    // Failures are skipped silently; the next refresh retries.
    go.await.is_some()
}

/// `conn` is `Some` for card images (records `image_path`). `progress(done, total)` counts files,
/// called once up front and after every completion; the emitter throttles.
pub async fn download(client: &Client, items: Vec<Item>, mut conn: Option<&mut Connection>,
                      progress: impl Fn(usize, usize)) -> Result<()> {
    let total = items.len();
    let (pending, existing): (Vec<_>, Vec<_>) = items.into_iter().partition(|i| !i.dest.exists());
    let mut done = total - pending.len();
    progress(done, total);

    if let Some(c) = conn.as_deref_mut() {
        // Backfill image_path for fronts that are on disk but not yet recorded.
        let ids: Vec<String> = existing.iter().filter_map(|i| i.record_id.clone()).collect();
        for chunk in ids.chunks(5000) { db::set_image_paths(c, chunk)?; }
    }

    let mut ok_ids: Vec<String> = vec![];
    let mut last_flush = Instant::now();
    let mut results = stream::iter(pending.iter())
        .map(|it| async move { (it.record_id.as_ref(), fetch_one(client, it).await) })
        .buffer_unordered(CONCURRENCY);
    while let Some((rid, ok)) = results.next().await {
        done += 1;
        if let (true, Some(id)) = (ok, rid) { ok_ids.push(id.clone()); }
        if let Some(c) = conn.as_deref_mut() {
            if ok_ids.len() >= FLUSH_EVERY || (!ok_ids.is_empty() && last_flush.elapsed() > Duration::from_secs(1)) {
                db::set_image_paths(c, &ok_ids)?;
                ok_ids.clear();
                last_flush = Instant::now();
            }
        }
        progress(done, total);
    }
    if let (Some(c), false) = (conn, ok_ids.is_empty()) { db::set_image_paths(c, &ok_ids)?; }
    Ok(())
}
