//! Private bounded native history with a demand-driven Dart notification hook.
//! No disk or stderr sink. Producers use reviewed static codes and numeric data.
use serde::Serialize;
use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

const MAX_EVENTS: usize = 256;
const MAX_EVENT_BYTES: usize = 1024;
const MAX_BYTES: usize = 64 * 1024;
type Hook = Arc<dyn Fn() -> bool + Send + Sync>;

#[derive(Clone, Serialize)]
pub struct Event {
    pub code: &'static str,
    pub level: &'static str,
    pub fields: Vec<(&'static str, f64)>,
}
#[derive(Default)]
struct State {
    events: VecDeque<String>,
    bytes: usize,
    hook: Option<Hook>,
    notified: bool,
    detailed_until: Option<Instant>,
}
static STATE: Mutex<State> = Mutex::new(State {
    events: VecDeque::new(),
    bytes: 0,
    hook: None,
    notified: false,
    detailed_until: None,
});

fn valid_code(code: &str) -> bool {
    !code.is_empty()
        && code.len() <= 100
        && code
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"_.".contains(&c))
}
/// Returns false when bounded admission drops an event. Never waits for a busy
/// diagnostics mutex, performs I/O, or sends more than one outstanding signal.
pub fn record(
    code: &'static str,
    level: &'static str,
    fields: &[(&'static str, f64)],
    detailed: bool,
) -> bool {
    if !valid_code(code) || !matches!(level, "INFO" | "WARNING" | "SEVERE" | "FINE") {
        return false;
    }
    let Ok(mut state) = STATE.try_lock() else {
        return false;
    };
    if detailed
        && !state
            .detailed_until
            .is_some_and(|until| Instant::now() < until)
    {
        return false;
    }
    let event = Event {
        code,
        level,
        fields: fields
            .iter()
            .copied()
            .take(16)
            .filter(|(key, value)| valid_code(key) && value.is_finite())
            .collect(),
    };
    let Ok(line) = serde_json::to_string(&event) else {
        return false;
    };
    if line.len() > MAX_EVENT_BYTES {
        return false;
    }
    while state.events.len() >= MAX_EVENTS || state.bytes + line.len() > MAX_BYTES {
        if let Some(old) = state.events.pop_front() {
            state.bytes -= old.len();
        } else {
            break;
        }
    }
    state.bytes += line.len();
    state.events.push_back(line);
    let hook = if !state.notified {
        state.hook.clone()
    } else {
        None
    };
    if hook.is_some() {
        state.notified = true;
    }
    drop(state);
    if let Some(hook) = hook {
        let _ = hook();
    }
    true
}
/// The callback signals availability only. Dart drains the bounded queue before
/// native producers can send another notification. Replace on runtime startup;
/// install None at shutdown. Callbacks run outside the diagnostics mutex.
pub fn install_hook(hook: Option<Hook>) {
    let callback = {
        let Ok(mut state) = STATE.lock() else {
            return;
        };
        state.hook = hook;
        state.notified = !state.events.is_empty() && state.hook.is_some();
        if state.notified {
            state.hook.clone()
        } else {
            None
        }
    };
    if let Some(callback) = callback {
        let _ = callback();
    }
}
pub fn drain() -> Vec<String> {
    let Ok(mut state) = STATE.lock() else {
        return Vec::new();
    };
    state.bytes = 0;
    state.notified = false;
    state.events.drain(..).collect()
}
pub fn set_detailed(enabled: bool) {
    if let Ok(mut state) = STATE.lock() {
        if enabled {
            // Settings synchronization and Clear must not renew capture consent.
            state
                .detailed_until
                .get_or_insert_with(|| Instant::now() + Duration::from_secs(15 * 60));
        } else {
            state.detailed_until = None;
        }
    }
}
pub fn clear() {
    let _ = drain();
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    #[test]
    fn bounds_demand_and_consent() {
        clear();
        set_detailed(false);
        install_hook(None);
        assert!(!record("detail", "FINE", &[], true));
        assert!(!record("path/private", "INFO", &[], false));
        let signals = Arc::new(AtomicUsize::new(0));
        let counter = signals.clone();
        install_hook(Some(Arc::new(move || {
            counter.fetch_add(1, Ordering::SeqCst);
            true
        })));
        for _ in 0..1000 {
            record("native.stage", "INFO", &[("elapsed_ms", 12.0)], false);
        }
        assert_eq!(signals.load(Ordering::SeqCst), 1);
        let events = drain();
        assert!(events.len() <= MAX_EVENTS);
        assert!(events.iter().map(String::len).sum::<usize>() <= MAX_BYTES);
        record("native.after_drain", "INFO", &[], false);
        assert_eq!(signals.load(Ordering::SeqCst), 2);
        set_detailed(true);
        let deadline = STATE.lock().unwrap().detailed_until;
        set_detailed(true);
        assert_eq!(STATE.lock().unwrap().detailed_until, deadline);
        assert!(record("detail", "FINE", &[], true));
        set_detailed(false);
        assert!(!record("detail", "FINE", &[], true));
        install_hook(None);
        clear();
    }
}
