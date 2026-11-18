//! Spring motion tuned after the iPhone's Dynamic Island.
//!
//! Every spring is described the way SwiftUI describes it: a `response` (the period of the undamped oscillation, in
//! seconds) and a `damping` fraction (1 = critically damped, below 1 overshoots). All the numbers that decide how the
//! island feels are in [`Motion`], so they can be tuned in one place.

use std::f32::consts::PI;

#[derive(Clone, Copy, Debug)]
pub struct Spring {
    pub value: f32,
    pub vel: f32,
    pub target: f32,
    omega: f32,
    zeta: f32,
}

impl Spring {
    pub fn new(value: f32, response: f32, damping: f32) -> Self {
        let mut s = Self { value, vel: 0.0, target: value, omega: 1.0, zeta: 1.0 };
        s.tune(response, damping);
        s
    }

    pub fn tune(&mut self, response: f32, damping: f32) {
        self.omega = 2.0 * PI / response.max(0.02);
        self.zeta = damping.max(0.05);
    }

    pub fn to(&mut self, target: f32) {
        self.target = target;
    }

    pub fn snap(&mut self, value: f32) {
        self.value = value;
        self.target = value;
        self.vel = 0.0;
    }

    /// Advances by `dt` seconds. Fixed sub-steps keep it stable whatever the frame time is.
    pub fn step(&mut self, dt: f32) {
        let mut left = dt.clamp(0.0, 0.1);
        while left > 0.0 {
            let h = left.min(1.0 / 480.0);
            let a = -self.omega * self.omega * (self.value - self.target) - 2.0 * self.zeta * self.omega * self.vel;
            self.vel += a * h;
            self.value += self.vel * h;
            left -= h;
        }
    }

    /// At rest on its target, within `eps` (in the spring's own unit).
    pub fn settled(&self, eps: f32) -> bool {
        (self.value - self.target).abs() < eps && self.vel.abs() < eps * 6.0
    }
}

/// Style of the movement, from the settings.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Style {
    Normal,
    Soft,
    Off,
}

impl Style {
    pub fn parse(s: &str) -> Self {
        match s {
            "soft" => Style::Soft,
            "off" => Style::Off,
            _ => Style::Normal,
        }
    }
}

/// All the timing of the island.
#[allow(dead_code)]
#[derive(Clone, Copy, Debug)]
pub struct Motion {
    pub style: Style,
    /// Size spring when the island grows (response s, damping): a little bounce, like the iPhone's.
    pub expand: (f32, f32),
    /// Size spring when it shrinks: firmer, almost no bounce.
    pub collapse: (f32, f32),
    /// Size spring when one page replaces another.
    pub page: (f32, f32),
    /// Content spring (always critically damped: text must never wobble).
    pub content: (f32, f32),
    /// Seconds the content waits for the container to start growing before it appears.
    pub content_delay: f32,
    /// Scale the content has when it is not shown.
    pub content_scale: f32,
}

impl Motion {
    pub fn new(style: Style) -> Self {
        let base = Self {
            style,
            expand: (0.46, 0.72),
            collapse: (0.38, 0.88),
            page: (0.42, 0.80),
            content: (0.26, 1.0),
            content_delay: 0.07,
            content_scale: 0.90,
        };
        match style {
            Style::Normal => base,
            Style::Soft => Self { expand: (0.52, 0.90), collapse: (0.42, 0.95), page: (0.46, 0.92), content_scale: 0.95, ..base },
            // The springs are still there but so stiff that they settle at once.
            Style::Off => Self { expand: (0.04, 1.0), collapse: (0.04, 1.0), page: (0.04, 1.0), content: (0.04, 1.0), content_delay: 0.0, content_scale: 1.0, ..base },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(mut s: Spring, secs: f32) -> (f32, f32) {
        let mut peak = s.value;
        let mut t = 0.0;
        while t < secs {
            s.step(1.0 / 120.0);
            peak = peak.max(s.value);
            t += 1.0 / 120.0;
        }
        (s.value, peak)
    }

    #[test]
    fn a_spring_reaches_its_target() {
        let mut s = Spring::new(0.0, 0.46, 0.72);
        s.to(100.0);
        let (end, _) = run(s, 2.0);
        assert!((end - 100.0).abs() < 0.01, "{end}");
    }

    #[test]
    fn the_bounce_is_small_and_the_critical_spring_has_none() {
        let mut bouncy = Spring::new(0.0, 0.46, 0.72);
        bouncy.to(100.0);
        let (_, peak) = run(bouncy, 2.0);
        // ~3 % overshoot: visible, never silly.
        assert!(peak > 100.5 && peak < 108.0, "{peak}");
        let mut flat = Spring::new(0.0, 0.26, 1.0);
        flat.to(100.0);
        let (_, peak) = run(flat, 2.0);
        assert!(peak <= 100.001, "{peak}");
    }

    #[test]
    fn it_is_stable_with_huge_frame_times() {
        let mut s = Spring::new(0.0, 0.3, 0.7);
        s.to(10.0);
        for _ in 0..200 {
            s.step(5.0);
        }
        assert!(s.value.is_finite() && (s.value - 10.0).abs() < 0.01);
    }

    #[test]
    fn off_settles_in_a_blink() {
        let m = Motion::new(Style::Off);
        let mut s = Spring::new(0.0, m.expand.0, m.expand.1);
        s.to(50.0);
        for _ in 0..12 {
            s.step(1.0 / 120.0);
        }
        assert!(s.settled(0.5), "{:?}", s);
    }
}
