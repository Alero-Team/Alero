//! Connect / disconnect alerts of the island: which transitions are worth announcing, and when.
//!
//! No drawing and no clock of its own (the caller passes seconds), so it is tested on its own. Rules:
//! - a state must hold for [`SETTLE`] seconds before it is announced, and a newer state of the same device replaces
//!   the older one: connect / disconnect / connect in a few seconds is one alert for the last state, or none if that
//!   is the state the user already knew (no flicker, no pile-up);
//! - nothing is announced in the first [`QUIET`] seconds: the engine reconnecting the paired devices as the daemon
//!   starts is not news;
//! - alerts of different devices queue (at most [`MAX_READY`]) and each one gives up after [`TTL`] seconds of waiting
//!   (the island may be busy; an old alert is worse than none).

use std::collections::{HashMap, VecDeque};

/// Seconds a state must hold before it is announced.
pub const SETTLE: f64 = 1.2;
/// Seconds after start in which transitions are only recorded.
pub const QUIET: f64 = 6.0;
/// Seconds a settled alert waits for the island to be free.
pub const TTL: f64 = 10.0;
pub const MAX_READY: usize = 3;

#[derive(Clone, Debug, PartialEq)]
pub struct Alert {
    pub id: String,
    pub name: String,
    pub up: bool,
}

#[derive(Default)]
pub struct LinkAlerts {
    /// The state the user last knew of each device.
    known: HashMap<String, bool>,
    /// Settling: (alert, announce at), one per device.
    pending: Vec<(Alert, f64)>,
    /// Settled and waiting for the island: (alert, give up at).
    ready: VecDeque<(Alert, f64)>,
}

impl LinkAlerts {
    /// The state a device was in when the island started: not an event.
    pub fn seed(&mut self, id: &str, up: bool) {
        self.known.insert(id.to_string(), up);
    }

    pub fn push(&mut self, now: f64, a: Alert) {
        if now < QUIET {
            self.known.insert(a.id.clone(), a.up);
            return;
        }
        self.push_now(now, a);
    }

    /// Like `push` without the quiet period at start (the debug simulation).
    pub fn push_now(&mut self, now: f64, a: Alert) {
        self.pending.retain(|(p, _)| p.id != a.id);
        self.pending.push((a, now + SETTLE));
    }

    /// Forgets what is waiting (the alerts are off) but keeps the states as known, so turning them on later does not
    /// announce what happened in between.
    pub fn drop_pending(&mut self) {
        for (a, _) in self.pending.drain(..).chain(self.ready.drain(..)) {
            self.known.insert(a.id, a.up);
        }
    }

    /// The next alert to show, if one is due and `can_show` (the island is free).
    pub fn poll(&mut self, now: f64, can_show: bool) -> Option<Alert> {
        let mut i = 0;
        while i < self.pending.len() {
            if self.pending[i].1 > now {
                i += 1;
                continue;
            }
            let (a, _) = self.pending.remove(i);
            if self.known.insert(a.id.clone(), a.up) != Some(a.up) {
                self.ready.push_back((a, now + TTL));
                if self.ready.len() > MAX_READY {
                    self.ready.pop_front();
                }
            }
        }
        self.ready.retain(|(_, until)| *until > now);
        if can_show {
            self.ready.pop_front().map(|(a, _)| a)
        } else {
            None
        }
    }

    #[cfg(test)]
    fn is_idle(&self) -> bool {
        self.pending.is_empty() && self.ready.is_empty()
    }
}

/// `ALERO_ISLAND_SIM`: a script of fake transitions to test the alerts without a device, `seconds:name:up|down`
/// separated by `;` (`2:Pixel 8:up;7:Pixel 8:down`). `1` or `demo` is a short demo. Seconds count from the start of
/// the island; entries that do not parse are skipped. They go through the same debounce as real ones, except that
/// the quiet period at start does not apply (give them a few seconds, or they are the "already connected" case).
pub fn parse_sim(spec: &str) -> Vec<(f64, Alert)> {
    let spec = if matches!(spec.trim(), "1" | "demo") { "8:Pixel 8:up;14:Pixel 8:down;20:Galaxy A54:up" } else { spec };
    let mut v: Vec<(f64, Alert)> = spec
        .split(';')
        .filter_map(|e| {
            let mut p = e.splitn(3, ':');
            let at = p.next()?.trim().parse::<f64>().ok()?;
            let name = p.next()?.trim();
            let up = match p.next()?.trim() {
                "up" => true,
                "down" => false,
                _ => return None,
            };
            (!name.is_empty()).then(|| (at, Alert { id: format!("sim:{name}"), name: name.to_string(), up }))
        })
        .collect();
    v.sort_by(|a, b| a.0.total_cmp(&b.0));
    v
}

#[cfg(test)]
mod tests {
    use super::*;

    fn a(id: &str, up: bool) -> Alert {
        Alert { id: id.into(), name: format!("Phone {id}"), up }
    }

    #[test]
    fn nothing_is_announced_at_start_and_the_state_is_still_learned() {
        let mut l = LinkAlerts::default();
        // The phone connects while the daemon starts: known, not news.
        l.push(1.0, a("p", true));
        assert!(l.poll(3.0, true).is_none() && l.is_idle());
        // The first real transition is announced.
        l.push(30.0, a("p", false));
        assert!(l.poll(30.5, true).is_none(), "still settling");
        assert_eq!(l.poll(31.3, true), Some(a("p", false)));
    }

    #[test]
    fn a_device_already_connected_at_start_is_not_announced_again() {
        let mut l = LinkAlerts::default();
        l.seed("p", true);
        l.push(20.0, a("p", true));
        assert!(l.poll(25.0, true).is_none());
    }

    #[test]
    fn quick_reconnects_show_only_the_final_state() {
        let mut l = LinkAlerts::default();
        l.seed("p", true);
        // down, up, down: one "down".
        l.push(20.0, a("p", false));
        l.push(20.4, a("p", true));
        l.push(20.9, a("p", false));
        assert!(l.poll(21.5, true).is_none(), "the last state has not settled");
        assert_eq!(l.poll(22.2, true), Some(a("p", false)));
        assert!(l.poll(40.0, true).is_none());
        // down, up: nothing, the user ends where they were.
        l.seed("q", true);
        l.push(50.0, a("q", false));
        l.push(50.5, a("q", true));
        assert!(l.poll(60.0, true).is_none() && l.is_idle());
    }

    #[test]
    fn two_devices_queue_one_after_the_other() {
        let mut l = LinkAlerts::default();
        l.push(10.0, a("p", true));
        l.push(10.1, a("q", true));
        assert_eq!(l.poll(11.5, false), None, "island busy");
        assert_eq!(l.poll(11.6, true), Some(a("p", true)));
        assert_eq!(l.poll(14.0, true), Some(a("q", true)));
        assert!(l.poll(14.1, true).is_none());
    }

    #[test]
    fn a_stale_alert_is_dropped_and_the_queue_is_short() {
        let mut l = LinkAlerts::default();
        l.push(10.0, a("p", true));
        assert!(l.poll(11.5, false).is_none());
        assert!(l.poll(11.5 + TTL + 1.0, true).is_none(), "waited too long");
        for i in 0..6 {
            l.push(100.0, a(&format!("d{i}"), true));
        }
        assert_eq!(l.poll(102.0, true).map(|x| x.id), Some("d3".into()), "the oldest were dropped");
    }

    #[test]
    fn turning_alerts_off_forgets_the_backlog_but_not_the_state() {
        let mut l = LinkAlerts::default();
        l.push(10.0, a("p", true));
        l.drop_pending();
        assert!(l.poll(20.0, true).is_none());
        // Same state again later: it was known.
        l.push(30.0, a("p", true));
        assert!(l.poll(32.0, true).is_none());
    }

    #[test]
    fn the_simulation_script_parses() {
        let s = parse_sim("7:Pixel 8:down; 2:Pixel 8:up;x:bad:up;3:Zero:sideways");
        assert_eq!(s.len(), 2);
        assert_eq!((s[0].0, s[0].1.up, s[0].1.name.as_str()), (2.0, true, "Pixel 8"));
        assert!(!s[1].1.up);
        assert_eq!(parse_sim("demo").len(), 3);
    }
}
