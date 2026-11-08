//! Same on-disk layout as `Sources/Shared/Paths.swift`.
//!
//! `QUICKSTUDY_DATA_DIR` (opt-in, used by parity tests) relocates everything to one
//! directory (logs go to `<dir>/logs`). Under the App Sandbox `$HOME` is already the
//! container's `Data` dir, so the default resolves into the container.
use std::fs;
use std::path::PathBuf;

const APP: &str = "QuickStudy";
const LEGACY: &str = "MTGSpotlight";

fn home() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .or_else(std::env::home_dir)
        .expect("no home directory")
}

fn override_dir() -> Option<PathBuf> {
    std::env::var_os("QUICKSTUDY_DATA_DIR").filter(|v| !v.is_empty()).map(PathBuf::from)
}

/// Moves `base/legacy` to `base/current` if only the legacy one exists, then creates `current`.
fn resolve(base: PathBuf) -> PathBuf {
    let dir = base.join(APP);
    let legacy = base.join(LEGACY);
    if !dir.exists() && legacy.exists() {
        let _ = fs::rename(&legacy, &dir);
    }
    let _ = fs::create_dir_all(&dir);
    dir
}

pub fn support_dir() -> PathBuf {
    if let Some(d) = override_dir() {
        let _ = fs::create_dir_all(&d);
        return d;
    }
    resolve(home().join("Library/Application Support"))
}

fn sub(name: &str) -> PathBuf {
    let d = support_dir().join(name);
    let _ = fs::create_dir_all(&d);
    d
}

pub fn images_dir() -> PathBuf { sub("images") }
pub fn art_dir() -> PathBuf { sub("art") }
pub fn database_path() -> PathBuf { support_dir().join("cards.sqlite") }

pub fn fetcher_log_path() -> PathBuf {
    let dir = match override_dir() {
        Some(d) => {
            let l = d.join("logs");
            let _ = fs::create_dir_all(&l);
            l
        }
        None => resolve(home().join("Library/Logs")),
    };
    dir.join("fetcher.log")
}

pub fn image_path(card_id: &str) -> PathBuf { images_dir().join(format!("{card_id}.jpg")) }
pub fn back_image_path(card_id: &str) -> PathBuf { images_dir().join(format!("{card_id}_back.jpg")) }
pub fn art_path(illustration_id: &str) -> PathBuf { art_dir().join(format!("{illustration_id}.jpg")) }
