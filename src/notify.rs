//! Terminal-only alarm / focus-grab: ring the bell and set a standing title.
//!
//! When a task needs a human (blocked, exited, or escalated) the TUI fires an
//! attention signal. Scope is **terminal-only** (see `.agtx/research.md`): no
//! spawned OS processes, no system notifications — just escape sequences written
//! to stdout.
//!
//! This module is deliberately free of TUI and database types (it depends only on
//! `crate::db::PhaseStatus`) so the emitter and the attention predicate can be
//! unit-tested in isolation — the same precedent as `src/agent/hook_status.rs`.

use std::io::Write;
use std::sync::{Arc, Mutex};

use crate::db::PhaseStatus;

/// Emits an attention signal to the terminal.
///
/// Implementations are fire-and-forget and **must never block the event loop** —
/// the TUI blocks on a channel and draws on change, so a notifier that waits here
/// would stall the whole board.
pub trait Notifier: Send + Sync {
    /// Ring the terminal bell once.
    fn ring(&self);

    /// Set the terminal (window/tab) title, via an OSC 2 sequence.
    fn set_title(&self, title: &str);
}

/// The real notifier: writes escape sequences straight to the process stdout.
///
/// A fresh `std::io::stdout()` handle shares the same file descriptor as the one
/// the TUI's backend uses, so this reaches the terminal emulator directly without
/// touching ratatui.
pub struct StdoutNotifier;

impl Notifier for StdoutNotifier {
    fn ring(&self) {
        write_bell();
    }

    fn set_title(&self, title: &str) {
        set_title_raw(title);
    }
}

/// Write a single BEL (`\x07`) and flush.
fn write_bell() {
    let mut out = std::io::stdout();
    let _ = out.write_all(b"\x07");
    let _ = out.flush();
}

/// Write an OSC 2 title sequence (`ESC ] 2 ; <title> BEL`) and flush.
fn set_title_raw(title: &str) {
    let seq = format!("\x1b]2;{}\x07", title);
    let mut out = std::io::stdout();
    let _ = out.write_all(seq.as_bytes());
    let _ = out.flush();
}

/// A test double that records every call so tests can assert what would have been
/// rung or titled, without touching the real terminal.
pub struct RecordingNotifier {
    pub events: Arc<Mutex<Vec<String>>>,
}

impl Default for RecordingNotifier {
    fn default() -> Self {
        Self {
            events: Arc::new(Mutex::new(Vec::new())),
        }
    }
}

impl RecordingNotifier {
    pub fn new() -> Self {
        Self::default()
    }

    /// A copy of the recorded events, in call order.
    pub fn snapshot(&self) -> Vec<String> {
        self.events.lock().unwrap().clone()
    }
}

impl Notifier for RecordingNotifier {
    fn ring(&self) {
        self.events.lock().unwrap().push("ring".to_string());
    }

    fn set_title(&self, title: &str) {
        self.events.lock().unwrap().push(format!("title:{title}"));
    }
}

/// Whether a task in `phase` (optionally escalated) needs the user, given the
/// configured attention `states` list.
///
/// `states` are the names from `[alarm].states`, mapped to a phase:
/// `blocked` → [`PhaseStatus::Blocked`], `exited` → [`PhaseStatus::Exited`],
/// `idle` → [`PhaseStatus::Idle`], `escalation` → the task carries an
/// `escalation_note` (independent of phase). Unknown names are ignored.
pub fn is_attention(phase: PhaseStatus, has_escalation: bool, states: &[String]) -> bool {
    for state in states {
        let matches = match state.as_str() {
            "blocked" => phase == PhaseStatus::Blocked,
            "exited" => phase == PhaseStatus::Exited,
            "idle" => phase == PhaseStatus::Idle,
            "escalation" => has_escalation,
            _ => false,
        };
        if matches {
            return true;
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    fn states(names: &[&str]) -> Vec<String> {
        names.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn is_attention_matches_each_named_state() {
        assert!(is_attention(PhaseStatus::Blocked, false, &states(&["blocked"])));
        assert!(is_attention(PhaseStatus::Exited, false, &states(&["exited"])));
        assert!(is_attention(PhaseStatus::Idle, false, &states(&["idle"])));
        assert!(is_attention(PhaseStatus::Working, true, &states(&["escalation"])));
    }

    #[test]
    fn is_attention_respects_the_configured_subset() {
        // The default set excludes `idle`: an idle task must not trip the alarm.
        let default = states(&["blocked", "exited", "escalation"]);
        assert!(!is_attention(PhaseStatus::Idle, false, &default));
        assert!(is_attention(PhaseStatus::Blocked, false, &default));
        assert!(is_attention(PhaseStatus::Working, true, &default));
    }

    #[test]
    fn is_attention_ignores_unknown_names_and_needs_escalation_flag() {
        assert!(!is_attention(PhaseStatus::Blocked, false, &states(&["idle"])));
        assert!(!is_attention(PhaseStatus::Working, false, &states(&["escalation"])));
        assert!(!is_attention(PhaseStatus::Working, false, &states(&["bogus"])));
        assert!(is_attention(PhaseStatus::Working, true, &states(&["escalation"])));
    }

    #[test]
    fn recording_notifier_records_rings_and_titles_in_order() {
        let n = RecordingNotifier::new();
        n.ring();
        n.set_title("⚠ agtx: 2 need input");
        assert_eq!(
            n.snapshot(),
            vec!["ring".to_string(), "title:⚠ agtx: 2 need input".to_string()]
        );
    }
}
