use engine::{fetch, paths, progress::Emitter};

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    let flags = fetch::Flags::parse(&args);
    let em = Emitter::new(&paths::fetcher_log_path());
    em.msg("start", &format!(
        "mtg-fetcher starting (imagesOnly={} skipImages={} artwork={} downloadArt={} printings={})",
        flags.images_only, flags.no_images, flags.artwork, flags.download_art, flags.printings));
    if let Err(e) = fetch::run(flags, &em).await {
        em.msg("error", &e.to_string());
        std::process::exit(1);
    }
}
