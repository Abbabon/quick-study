//! Scryfall wire shapes + conversion to DB records (port of `ScryfallClient.swift`), and the
//! HTTP client. Bulk files are streamed line by line (JSONL; a legacy `[...]` array is accepted).
use crate::{Result, today};
use serde::Deserialize;
use std::fs::File;
use std::io::{BufRead, BufReader, Write};
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};

pub const USER_AGENT: &str = "QuickStudy/1.0 (+https://github.com/Abbabon/quick-study)";
const API: &str = "https://api.scryfall.com";
const JUNK_LAYOUTS: [&str; 4] = ["token", "double_faced_token", "art_series", "emblem"];

fn junk(layout: &Option<String>) -> bool {
    layout.as_deref().is_some_and(|l| JUNK_LAYOUTS.contains(&l))
}

// ---------- DB records ----------

pub struct Card {
    pub id: String, pub name: String, pub mana_cost: Option<String>, pub type_line: Option<String>,
    pub oracle_text: Option<String>, pub power: Option<String>, pub toughness: Option<String>,
    pub colors: Vec<String>, pub scryfall_uri: String, pub set_code: Option<String>,
    pub set_name: Option<String>, pub oracle_id: Option<String>, pub date_added: Option<String>,
    pub rarity: Option<String>, pub cmc: Option<f64>,
}

pub struct Artwork {
    pub illustration_id: String, pub card_id: String, pub card_name: String, pub artist: String,
    pub art_crop_url: String, pub colors: Vec<String>, pub set_code: Option<String>,
}

pub struct Printing {
    pub printing_id: String, pub oracle_id: String, pub set_code: String, pub set_name: String,
    pub collector_number: Option<String>, pub released_at: Option<String>, pub rarity: Option<String>,
    pub digital: bool, pub games: Vec<String>,
}

pub struct SetInfo {
    pub code: String, pub name: String, pub released_at: Option<String>, pub set_type: Option<String>,
    pub card_count: Option<i64>, pub icon_svg_uri: Option<String>,
}

pub struct CardImageRef { pub id: String, pub image_url: String, pub back_image_url: Option<String> }
pub struct ArtImageRef { pub illustration_id: String, pub image_url: String }

// ---------- wire shapes ----------

#[derive(Deserialize)]
struct Uris { normal: Option<String>, art_crop: Option<String> }

#[derive(Deserialize)]
struct Preview { previewed_at: Option<String> }

#[derive(Deserialize)]
struct Face {
    name: Option<String>, mana_cost: Option<String>, type_line: Option<String>, oracle_text: Option<String>,
    power: Option<String>, toughness: Option<String>, colors: Option<Vec<String>>, image_uris: Option<Uris>,
    artist: Option<String>, illustration_id: Option<String>,
}

/// Superset of the fields the card, artwork, printing and image passes need.
#[derive(Deserialize)]
struct Raw {
    id: Option<String>, name: Option<String>, mana_cost: Option<String>, type_line: Option<String>,
    oracle_text: Option<String>, power: Option<String>, toughness: Option<String>,
    colors: Option<Vec<String>>, color_identity: Option<Vec<String>>, image_uris: Option<Uris>,
    card_faces: Option<Vec<Face>>, scryfall_uri: Option<String>, layout: Option<String>,
    released_at: Option<String>, set: Option<String>, set_name: Option<String>, oracle_id: Option<String>,
    rarity: Option<String>, cmc: Option<f64>, preview: Option<Preview>, artist: Option<String>,
    illustration_id: Option<String>, collector_number: Option<String>, digital: Option<bool>,
    games: Option<Vec<String>>, lang: Option<String>,
}

fn missing(field: &str) -> crate::Error { format!("bulk row missing required field `{field}`").into() }

impl Raw {
    fn into_card(self) -> Result<Option<Card>> {
        let id = self.id.ok_or_else(|| missing("id"))?;
        let name = self.name.ok_or_else(|| missing("name"))?;
        if junk(&self.layout) { return Ok(None); }
        let first = self.card_faces.as_ref().and_then(|f| f.first());
        let oracle_text = self.oracle_text.clone().or_else(|| {
            self.card_faces.as_ref().map(|f| f.iter().filter_map(|x| x.oracle_text.clone()).collect::<Vec<_>>().join("\n//\n"))
        });
        Ok(Some(Card {
            mana_cost: self.mana_cost.clone().or_else(|| first.and_then(|f| f.mana_cost.clone())),
            type_line: self.type_line.clone().or_else(|| first.and_then(|f| f.type_line.clone())),
            oracle_text: oracle_text.filter(|t| !t.is_empty()),
            power: self.power.clone().or_else(|| first.and_then(|f| f.power.clone())),
            toughness: self.toughness.clone().or_else(|| first.and_then(|f| f.toughness.clone())),
            colors: self.colors.clone().or_else(|| first.and_then(|f| f.colors.clone())).unwrap_or_default(),
            scryfall_uri: self.scryfall_uri.clone().unwrap_or_else(|| format!("https://scryfall.com/card/{id}")),
            set_code: self.set.as_ref().map(|s| s.to_uppercase()),
            set_name: self.set_name.clone(),
            oracle_id: self.oracle_id.clone(),
            // Preview date, else release date, else today.
            date_added: Some(self.preview.as_ref().and_then(|p| p.previewed_at.clone())
                .or(self.released_at.clone()).unwrap_or_else(today)),
            rarity: self.rarity.clone(),
            cmc: self.cmc,
            id, name,
        }))
    }

    fn into_artworks(self) -> Result<Vec<Artwork>> {
        let id = self.id.ok_or_else(|| missing("id"))?;
        let name = self.name.ok_or_else(|| missing("name"))?;
        if junk(&self.layout) { return Ok(vec![]); }
        let fallback = self.colors.clone().or(self.color_identity.clone()).unwrap_or_default();
        let set = self.set.as_ref().map(|s| s.to_uppercase());
        let mut out = vec![];
        let mut make = |illus: Option<String>, crop: Option<String>, artist: Option<String>, n: Option<String>, colors: Option<Vec<String>>| {
            if let (Some(illustration_id), Some(art_crop_url), Some(artist)) = (illus, crop, artist) {
                out.push(Artwork { illustration_id, card_id: id.clone(), card_name: n.unwrap_or_else(|| name.clone()),
                    artist, art_crop_url, colors: colors.unwrap_or_else(|| fallback.clone()), set_code: set.clone() });
            }
        };
        make(self.illustration_id.clone(), self.image_uris.as_ref().and_then(|u| u.art_crop.clone()),
            self.artist.clone(), Some(name.clone()), Some(fallback.clone()));
        for f in self.card_faces.into_iter().flatten() {
            make(f.illustration_id, f.image_uris.and_then(|u| u.art_crop), f.artist.or(self.artist.clone()), f.name, f.colors);
        }
        Ok(out)
    }

    fn into_printing(self) -> Result<Option<Printing>> {
        let id = self.id.ok_or_else(|| missing("id"))?;
        let set = self.set.ok_or_else(|| missing("set"))?;
        let set_name = self.set_name.ok_or_else(|| missing("set_name"))?;
        if junk(&self.layout) { return Ok(None); }
        if self.lang.as_deref().is_some_and(|l| l != "en") { return Ok(None); }
        let Some(oracle_id) = self.oracle_id else { return Ok(None) };
        Ok(Some(Printing { printing_id: id, oracle_id, set_code: set.to_uppercase(), set_name,
            collector_number: self.collector_number, released_at: self.released_at, rarity: self.rarity,
            digital: self.digital.unwrap_or(false), games: self.games.unwrap_or_default() }))
    }

    fn into_image_ref(self) -> Option<CardImageRef> {
        let id = self.id?;
        if junk(&self.layout) { return None; }
        let faces = self.card_faces.unwrap_or_default();
        let normal = |u: &Option<Uris>| u.as_ref().and_then(|u| u.normal.clone());
        let front = normal(&self.image_uris).or_else(|| faces.first().and_then(|f| normal(&f.image_uris)))?;
        // Back only for true DFCs: both faces carry their own image_uris.
        let back = (faces.len() >= 2 && faces[0].image_uris.is_some()).then(|| normal(&faces[1].image_uris)).flatten();
        Some(CardImageRef { id, image_url: front, back_image_url: back })
    }
}

// ---------- streaming reader ----------

fn for_each_row(path: &Path, mut f: impl FnMut(Raw) -> Result<()>) -> Result<()> {
    let mut r = BufReader::with_capacity(1 << 20, File::open(path)?);
    let first = r.fill_buf()?.iter().copied().find(|b| *b > 0x20);
    if first == Some(b'[') {
        // ponytail: legacy array form is loaded whole; Scryfall serves JSONL now.
        let rows: Vec<Raw> = serde_json::from_reader(r)?;
        return rows.into_iter().try_for_each(f);
    }
    let mut line = String::new();
    loop {
        line.clear();
        if r.read_line(&mut line)? == 0 { return Ok(()); }
        if line.bytes().any(|b| b > 0x20) { f(serde_json::from_str(&line)?)?; }
    }
}

pub fn parse_cards(path: &Path) -> Result<Vec<Card>> {
    let mut v = vec![];
    for_each_row(path, |r| { v.extend(r.into_card()?); Ok(()) })?;
    Ok(v)
}
pub fn parse_artworks(path: &Path) -> Result<Vec<Artwork>> {
    let mut v = vec![];
    for_each_row(path, |r| { v.extend(r.into_artworks()?); Ok(()) })?;
    Ok(v)
}
pub fn parse_printings(path: &Path) -> Result<Vec<Printing>> {
    let mut v = vec![];
    for_each_row(path, |r| { v.extend(r.into_printing()?); Ok(()) })?;
    Ok(v)
}
pub fn parse_image_refs(path: &Path) -> Result<Vec<CardImageRef>> {
    let mut v = vec![];
    for_each_row(path, |r| { v.extend(r.into_image_ref()); Ok(()) })?;
    Ok(v)
}

// ---------- HTTP ----------

#[derive(Deserialize, Debug, Clone)]
pub struct BulkInfo {
    #[serde(rename = "type")] pub kind: String,
    pub jsonl_download_uri: Option<String>,
    pub updated_at: String,
    pub compressed_size: Option<u64>,
}

#[derive(Deserialize)] struct BulkIndex { data: Vec<BulkInfo> }
#[derive(Deserialize)] struct RawSet { code: String, name: String, released_at: Option<String>, set_type: Option<String>, card_count: Option<i64>, icon_svg_uri: Option<String> }
#[derive(Deserialize)] struct RawSetList { data: Vec<RawSet> }

pub fn decode_bulk_index(body: &[u8]) -> Result<Vec<BulkInfo>> { Ok(serde_json::from_slice::<BulkIndex>(body)?.data) }

/// Shared HTTP client. `api.scryfall.com` calls are spaced >= 100 ms apart (limit is 10 req/s);
/// the image/bulk CDN (`*.scryfall.io`) is not rate limited.
#[derive(Clone)]
pub struct Client { http: reqwest::Client, last_api: Arc<tokio::sync::Mutex<Option<Instant>>> }

impl Client {
    pub fn new() -> Result<Self> {
        let http = reqwest::Client::builder().user_agent(USER_AGENT).timeout(Duration::from_secs(60))
            .pool_max_idle_per_host(32).build()?;
        Ok(Self { http, last_api: Default::default() })
    }

    pub fn http(&self) -> &reqwest::Client { &self.http }

    async fn api_get(&self, path: &str) -> Result<Vec<u8>> {
        {
            let mut last = self.last_api.lock().await;
            if let Some(t) = *last { tokio::time::sleep(Duration::from_millis(100).saturating_sub(t.elapsed())).await; }
            *last = Some(Instant::now());
        }
        let resp = self.http.get(format!("{API}{path}")).header("Accept", "application/json").send().await?;
        let status = resp.status();
        if !status.is_success() { return Err(format!("GET {path} -> HTTP {status}").into()); }
        Ok(resp.bytes().await?.to_vec())
    }

    pub async fn bulk_info(&self, kind: &str) -> Result<BulkInfo> {
        let body = self.api_get("/bulk-data").await?;
        decode_bulk_index(&body)?.into_iter().find(|i| i.kind == kind)
            .ok_or_else(|| format!("bulk type {kind} not found").into())
    }

    pub async fn fetch_sets(&self) -> Result<Vec<SetInfo>> {
        let list: RawSetList = serde_json::from_slice(&self.api_get("/sets").await?)?;
        Ok(list.data.into_iter().map(|s| SetInfo { code: s.code.to_uppercase(), name: s.name,
            released_at: s.released_at, set_type: s.set_type, card_count: s.card_count, icon_svg_uri: s.icon_svg_uri }).collect())
    }

    /// Downloads the gzipped JSONL bulk file and gunzips it in-process to `dest` (via `dest.part`).
    pub async fn download_bulk(&self, info: &BulkInfo, dest: &Path) -> Result<()> {
        use futures_util::StreamExt;
        let url = info.jsonl_download_uri.as_deref()
            .ok_or_else(|| format!("bulk entry {} has no jsonl_download_uri", info.kind))?;
        let resp = self.http.get(url).header("Accept", "*/*").send().await?;
        if !resp.status().is_success() { return Err(format!("GET {url} -> HTTP {}", resp.status()).into()); }
        let gz = dest.with_extension("jsonl.gz.part");
        let mut f = File::create(&gz)?;
        let mut s = resp.bytes_stream();
        while let Some(chunk) = s.next().await { f.write_all(&chunk?)?; }
        f.flush()?;
        let part = dest.with_extension("jsonl.part");
        let res = (|| -> Result<()> {
            let mut dec = flate2::read::MultiGzDecoder::new(File::open(&gz)?);
            let mut out = std::io::BufWriter::new(File::create(&part)?);
            std::io::copy(&mut dec, &mut out)?;
            out.flush()?;
            std::fs::rename(&part, dest)?;
            Ok(())
        })();
        let _ = std::fs::remove_file(&gz);
        if res.is_err() { let _ = std::fs::remove_file(&part); }
        res.map_err(|e| format!("gunzip failed: {e}").into())
    }
}
