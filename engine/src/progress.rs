//! NDJSON progress events on stdout (the app's `FetcherProcess` contract), mirrored to the log.
//! Progress ticks (`done < total`, no message) are throttled to ~10/s; everything else passes.
use serde::Serialize;
use std::fs::{File, OpenOptions};
use std::io::Write;
use std::path::Path;
use std::sync::Mutex;
use std::time::{Duration, Instant};

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Event<'a> {
    phase: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    done: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    total: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    message: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    new_cards: Option<usize>,
}

pub struct Emitter {
    inner: Mutex<(Option<File>, Option<Instant>)>,
    min_gap: Duration,
}

impl Emitter {
    pub fn new(log: &Path) -> Self {
        let f = OpenOptions::new().create(true).append(true).open(log).ok();
        Self { inner: Mutex::new((f, None)), min_gap: Duration::from_millis(100) }
    }

    pub fn emit(&self, phase: &str, done: Option<usize>, total: Option<usize>, message: Option<&str>, new_cards: Option<usize>) {
        let mut g = self.inner.lock().unwrap();
        let tick = matches!((done, total), (Some(d), Some(t)) if d < t) && message.is_none();
        if tick {
            if let Some(last) = g.1 {
                if last.elapsed() < self.min_gap {
                    return;
                }
            }
            g.1 = Some(Instant::now());
        }
        let ev = Event { phase, done, total, message, new_cards };
        let mut line = serde_json::to_string(&ev).unwrap();
        line.push('\n');
        let out = std::io::stdout();
        let mut o = out.lock();
        let _ = o.write_all(line.as_bytes());
        let _ = o.flush();
        if let Some(f) = g.0.as_mut() {
            let s = |v: Option<usize>| v.map_or("-".into(), |n| n.to_string());
            let _ = writeln!(f, "[{}] {phase} done={} total={} newCards={} {}", crate::iso_now(),
                s(done), s(total), s(new_cards), message.unwrap_or(""));
        }
    }

    pub fn msg(&self, phase: &str, message: &str) { self.emit(phase, None, None, Some(message), None) }
    pub fn progress(&self, phase: &str, done: usize, total: usize) { self.emit(phase, Some(done), Some(total), None, None) }
}
