// SPDX-License-Identifier: MIT OR Apache-2.0

//! Logging initialisation for the Floresta FFI layer.
//!
//! Adapted from `bin/florestad/src/logger.rs` — uses `try_init` instead of
//! `init` so it is safe to call from a shared library that may be loaded more
//! than once in the same process.

use core::fmt;
use std::fs;
use std::io;
use std::path::Path;

use tracing::Level;
use tracing_appender::non_blocking::WorkerGuard;
use tracing_subscriber::EnvFilter;
use tracing_subscriber::Layer;
use tracing_subscriber::fmt::FmtContext;
use tracing_subscriber::fmt::FormatEvent;
use tracing_subscriber::fmt::FormatFields;
use tracing_subscriber::fmt::format::Writer;
use tracing_subscriber::fmt::layer;
use tracing_subscriber::fmt::time::ChronoLocal;
use tracing_subscriber::fmt::time::FormatTime;
use tracing_subscriber::layer::SubscriberExt;
use tracing_subscriber::registry::LookupSpan;
use tracing_subscriber::util::SubscriberInitExt;

pub(crate) const LOG_FILE: &str = "debug.log";
const CHRONO_FORMATTER: &str = "%Y-%m-%d %H:%M:%S";
const CHRONO_FORMATTER_DEBUG: &str = "%Y-%m-%d %H:%M:%S%.3f";

/// A compact log formatter that shortens `floresta_*` crate paths.
pub struct ShortTargetFormatter {
    timer: ChronoLocal,
}

impl ShortTargetFormatter {
    pub fn new(debug: bool) -> Self {
        let fmt = if debug { CHRONO_FORMATTER_DEBUG } else { CHRONO_FORMATTER };
        Self { timer: ChronoLocal::new(fmt.to_string()) }
    }

    fn short_target(target: &str) -> &str {
        if target.starts_with("floresta_chain")           { "chain" }
        else if target.starts_with("floresta_electrum")   { "electrum" }
        else if target.starts_with("floresta_compact_filters") { "filters" }
        else if target.starts_with("floresta_mempool")    { "mempool" }
        else if target.starts_with("floresta_node")       { "node" }
        else if target.starts_with("floresta_wire")       { "wire" }
        else if target.starts_with("floresta_watch_only") { "watch_only" }
        else if target.starts_with("florestad")           { "florestad" }
        else { target }
    }
}

impl<S, N> FormatEvent<S, N> for ShortTargetFormatter
where
    S: tracing::Subscriber + for<'a> LookupSpan<'a>,
    N: for<'a> FormatFields<'a> + 'static,
{
    fn format_event(
        &self,
        ctx: &FmtContext<'_, S, N>,
        mut writer: Writer<'_>,
        event: &tracing::Event<'_>,
    ) -> fmt::Result {
        let meta = event.metadata();
        self.timer.format_time(&mut writer)?;
        write!(writer, " {:>5} ", meta.level())?;
        let target = if tracing::enabled!(Level::DEBUG) {
            meta.target()
        } else {
            Self::short_target(meta.target())
        };
        write!(writer, "{}: ", target)?;
        ctx.format_fields(writer.by_ref(), event)?;
        writeln!(writer)
    }
}

/// Initialise the global tracing subscriber.
///
/// Safe to call from a `.so` / `.dylib` — uses `try_init` so a second call
/// is silently ignored rather than panicking.
///
/// Returns the `WorkerGuard` that must be kept alive for file logging to flush.
pub fn start_logger(
    datadir: impl AsRef<Path>,
    log_to_file: bool,
    log_to_stdout: bool,
    log_level: Level,
) -> Option<WorkerGuard> {
    let datadir = datadir.as_ref();
    let is_debug = log_level >= Level::DEBUG;

    let make_filter = || {
        EnvFilter::try_from_default_env()
            .unwrap_or_else(|_| EnvFilter::new(log_level.to_string()))
    };

    let fmt_layer_stdout = log_to_stdout.then(|| {
        layer()
            .with_writer(io::stderr)   // stderr avoids iOS ATS blocking stdout
            .with_ansi(false)
            .event_format(ShortTargetFormatter::new(is_debug))
            .with_filter(make_filter())
    });

    let mut guard = None;
    let fmt_layer_logfile = log_to_file.then(|| {
        // Pre-create the file so we fail early with a clear message.
        let path = datadir.join(LOG_FILE);
        if let Err(e) = fs::OpenOptions::new().create(true).append(true).open(&path) {
            eprintln!("[floresta-ffi] cannot open log file {}: {e}", path.display());
            return None;
        }
        let file_appender = tracing_appender::rolling::never(datadir, LOG_FILE);
        let (non_blocking, file_guard) = tracing_appender::non_blocking(file_appender);
        guard = Some(file_guard);
        Some(layer()
            .with_writer(non_blocking)
            .with_ansi(false)
            .event_format(ShortTargetFormatter::new(is_debug))
            .with_filter(make_filter()))
    }).flatten();

    // try_init: silently returns Err if a subscriber is already installed.
    let _ = tracing_subscriber::registry()
        .with(fmt_layer_stdout)
        .with(fmt_layer_logfile)
        .try_init();

    guard
}
