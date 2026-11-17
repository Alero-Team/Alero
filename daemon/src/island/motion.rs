//! Time-based motion, with the curves and durations of the QNotch notch it is modelled on.
//!
//! The panel opens in 240 ms with a gentle overshoot (ease-out-back, 0.7), closes in 180 ms (ease-out cubic), the tab
//! indicator slides in 220 ms and a tab's content fades in over 180 ms. Everything is a plain tween: a start, an end,
//! a duration and an easing, so what the eye sees is exactly what is written here.

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

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Ease {
    /// Overshoots by a little and settles; the number is the strength (QNotch uses 0.7 on opening).
    Back(f32),
    Cubic,
}

pub fn ease(e: Ease, p: f32) -> f32 {
    let p = p.clamp(0.0, 1.0);
    match e {
        Ease::Back(c1) => {
            let c3 = c1 + 1.0;
            let q = p - 1.0;
            1.0 + c3 * q * q * q + c1 * q * q
        }
        Ease::Cubic => {
            let q = 1.0 - p;
            1.0 - q * q * q
        }
    }
}

/// One animated number.
#[derive(Clone, Copy, Debug)]
pub struct Anim {
    pub v: f32,
    from: f32,
    to: f32,
    t: f32,
    dur: f32,
    e: Ease,
}

impl Anim {
    pub fn new(v: f32) -> Self {
        Self { v, from: v, to: v, t: 0.0, dur: 0.0, e: Ease::Cubic }
    }

    /// Goes to `to` in `ms` milliseconds. Zero (or less) jumps there.
    pub fn go(&mut self, to: f32, ms: f32, e: Ease) {
        if ms <= 0.5 {
            self.snap(to);
            return;
        }
        self.from = self.v;
        self.to = to;
        self.t = 0.0;
        self.dur = ms / 1000.0;
        self.e = e;
    }

    pub fn snap(&mut self, v: f32) {
        self.v = v;
        self.from = v;
        self.to = v;
        self.t = 0.0;
        self.dur = 0.0;
    }

    pub fn target(&self) -> f32 {
        self.to
    }

    pub fn running(&self) -> bool {
        self.t < self.dur
    }

    pub fn step(&mut self, dt: f32) {
        if !self.running() {
            return;
        }
        self.t += dt.max(0.0);
        if self.t >= self.dur {
            self.v = self.to;
            self.t = self.dur;
        } else {
            self.v = self.from + (self.to - self.from) * ease(self.e, self.t / self.dur);
        }
    }
}

/// How the settings change the motion: "normal" is QNotch's own timing, "soft" is slower with less bounce.
#[derive(Clone, Copy, Debug)]
pub struct Motion {
    pub style: Style,
}

impl Motion {
    pub fn new(style: Style) -> Self {
        Self { style }
    }

    /// A base duration in milliseconds, as this style wants it.
    pub fn ms(&self, base: f32) -> f32 {
        match self.style {
            Style::Normal => base,
            Style::Soft => base * 1.4,
            Style::Off => 0.0,
        }
    }

    /// Strength of the overshoot on opening.
    pub fn bounce(&self) -> f32 {
        match self.style {
            Style::Normal => 0.7,
            Style::Soft => 0.25,
            Style::Off => 0.0,
        }
    }

    pub fn off(&self) -> bool {
        self.style == Style::Off
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(mut a: Anim, secs: f32) -> (f32, f32) {
        let mut peak = a.v;
        let mut t = 0.0;
        while t < secs {
            a.step(1.0 / 240.0);
            peak = peak.max(a.v);
            t += 1.0 / 240.0;
        }
        (a.v, peak)
    }

    #[test]
    fn the_opening_overshoots_about_three_percent_and_lands() {
        let mut a = Anim::new(0.0);
        a.go(1.0, 240.0, Ease::Back(0.7));
        let (end, peak) = run(a, 0.5);
        assert!((end - 1.0).abs() < 1e-5);
        assert!(peak > 1.01 && peak < 1.06, "{peak}");
    }

    #[test]
    fn the_closing_has_no_bounce() {
        let mut a = Anim::new(1.0);
        a.go(0.0, 180.0, Ease::Cubic);
        let mut min = 1.0f32;
        let mut t = 0.0;
        while t < 0.3 {
            a.step(1.0 / 240.0);
            min = min.min(a.v);
            t += 1.0 / 240.0;
        }
        assert!(min >= 0.0 && a.v == 0.0);
    }

    #[test]
    fn it_is_stable_with_huge_frame_times() {
        let mut a = Anim::new(0.0);
        a.go(10.0, 200.0, Ease::Back(0.7));
        a.step(5.0);
        assert_eq!(a.v, 10.0);
        assert!(!a.running());
    }

    #[test]
    fn off_jumps() {
        let m = Motion::new(Style::Off);
        let mut a = Anim::new(0.0);
        a.go(5.0, m.ms(240.0), Ease::Cubic);
        assert_eq!(a.v, 5.0);
    }
}
