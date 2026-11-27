//! The send-a-file animation: a phone that fills like a glass.
//!
//! One card for the whole trip, so nothing is swapped, faded out or resized between "drop here" and "sent":
//! a phone outline sits in the middle; a file over the island lifts and sways it, with an arrow bobbing on its
//! screen; a drop flies the file's thumbnail along a curve into the screen (the phone gives a little); the screen
//! then fills from the bottom, its surface rippling, as the file goes; a check appears on the full screen at the end.
//!
//! This module only draws and keeps its own little state. The island feeds it: [`AirDrop::hover`], [`AirDrop::dropped`],
//! [`AirDrop::progress`], [`AirDrop::finish`], steps it with [`AirDrop::update`] (false = nothing moves, no frame
//! needed) and calls [`AirDrop::draw`] (the card) or [`AirDrop::draw_pill`] (the compact closed island).

use std::f32::consts::{PI, TAU};

use tiny_skia::{PathBuilder, Point, Transform};

use super::gfx::{color, icon, Canvas, Fonts, Icon, Image, Rgb, Weight, R};
use super::motion::Spring;
use crate::lang::t;

const RED: Rgb = [255, 69, 58];
/// Size of the card (logical); it is the same from the first hover to the last frame.
pub const SIZE: (f32, f32) = (392.0, 172.0);
/// Scale reference for the landing squash (the squash spring rests at this, 1.0x).
const AVATAR: f32 = 26.0;
/// Seconds the file takes to fly into the picture.
const FLY: f32 = 0.40;
/// Where the picture is, from the top of the card.
const CENTER_Y: f32 = 64.0;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Stage {
    Idle,
    /// A file is over the island.
    Hover,
    /// Dropped: the thumbnail is on its way.
    Fly,
    /// The file is going; the ring fills.
    Send,
    Done,
    Failed,
}

/// What the card needs to draw itself and is not its own state.
pub struct Look<'a> {
    pub fg: Rgb,
    /// The island's accent and the colour that reads on it.
    pub accent: Rgb,
    pub on: Rgb,
    /// A preview of the file being sent; a file glyph when there is none.
    pub thumb: Option<&'a Image>,
}

pub struct AirDrop {
    pub stage: Stage,
    /// Reduced motion: no flight, waves, breathing or shake; the ring and short fades only.
    reduced: bool,
    clock: f32,
    /// Seconds in the current stage, and since the file hit the picture (large before it does).
    age: f32,
    impact: f32,
    glow: f32,
    ring: Spring,
    squash: Spring,
    pop: Spring,
    /// Where the ring is going, and whether the transfer ended (true = well) while it still fills.
    goal: f32,
    ending: Option<bool>,
    pct: i32,
    /// Texts, built when they change and not in every frame.
    hover_txt: String,
    file_txt: String,
    title: String,
    fail_txt: String,
}

impl AirDrop {
    pub fn new() -> Self {
        Self {
            stage: Stage::Idle,
            reduced: false,
            clock: 0.0,
            age: 0.0,
            impact: 99.0,
            glow: 0.0,
            ring: Spring::new(0.0, 0.5, 1.0),
            squash: Spring::new(1.0, 0.40, 0.42),
            pop: Spring::new(0.0, 0.42, 0.52),
            goal: 0.0,
            ending: None,
            pct: -1,
            hover_txt: String::new(),
            file_txt: String::new(),
            title: String::new(),
            fail_txt: String::new(),
        }
    }

    pub fn set_reduced(&mut self, on: bool) {
        self.reduced = on;
        self.ring.tune(if on { 0.12 } else { 0.5 }, 1.0);
    }

    /// The words: the phone's name (None: no phone is connected) and the file's. Cut to fit the card here, once.
    pub fn set_labels(&mut self, fonts: &mut Fonts, phone: Option<&str>, file: &str) {
        let max = SIZE.0 - 56.0;
        self.hover_txt = match phone {
            Some(p) => fonts.fit(&format!("{} {}", t("Suelta para enviar a", "Drop to send to"), p), 13.5, Weight::Medium, max),
            None => fonts.fit(t("Conecta un teléfono para enviar archivos", "Connect a phone to send files"), 13.5, Weight::Medium, max),
        };
        self.file_txt = fonts.fit(file, 12.0, Weight::Regular, max);
    }

    /// The message of a transfer that failed (empty: the generic one).
    pub fn set_failure(&mut self, fonts: &mut Fonts, msg: &str) {
        self.fail_txt = fonts.fit(msg, 12.0, Weight::Regular, SIZE.0 - 56.0);
    }

    /// A file is over the island (or left it).
    pub fn hover(&mut self, on: bool) {
        match (on, self.stage) {
            (true, Stage::Idle | Stage::Done | Stage::Failed) => self.enter(Stage::Hover),
            (false, Stage::Hover) => self.enter(Stage::Idle),
            _ => {}
        }
    }

    /// The file was dropped: it flies in (reduced motion: it is simply taken).
    pub fn dropped(&mut self) {
        self.goal = 0.0;
        self.pct = -1;
        self.ending = None;
        self.ring.snap(0.0);
        self.pop.snap(0.0);
        self.enter(Stage::Fly);
        if self.reduced {
            self.land();
        }
    }

    /// Fraction sent, 0..1 (any time after the drop; it is smoothed).
    pub fn progress(&mut self, f: f32) {
        self.goal = f.clamp(0.0, 1.0);
    }

    /// The transfer ended. Well: the ring completes, then the check pops. Badly: red, a shake.
    pub fn finish(&mut self, ok: bool) {
        if self.ending.is_some() || matches!(self.stage, Stage::Done | Stage::Failed) {
            return;
        }
        if self.stage == Stage::Hover || self.stage == Stage::Idle {
            // Nothing was dropped here (the transfer began elsewhere): nothing to wrap up.
            return;
        }
        self.ending = Some(ok);
        if ok {
            self.goal = 1.0;
        } else {
            self.fail();
        }
    }

    /// Back to nothing (the card is gone).
    pub fn reset(&mut self) {
        let reduced = self.reduced;
        *self = Self::new();
        self.set_reduced(reduced);
    }

    /// Seconds since it ended (the island closes a moment after).
    pub fn done_for(&self) -> Option<f32> {
        matches!(self.stage, Stage::Done | Stage::Failed).then_some(self.age)
    }

    /// A transfer is on (so the closed island shows the compact pill).
    pub fn active(&self) -> bool {
        matches!(self.stage, Stage::Fly | Stage::Send | Stage::Done | Stage::Failed)
    }

    fn enter(&mut self, s: Stage) {
        self.stage = s;
        self.age = 0.0;
    }

    /// The thumbnail reaches the picture.
    fn land(&mut self) {
        self.enter(Stage::Send);
        self.impact = 0.0;
        if !self.reduced {
            self.squash.value = 0.80;
            self.squash.vel = 0.0;
            self.squash.to(1.0);
        }
    }

    fn fail(&mut self) {
        self.enter(Stage::Failed);
        self.pop.snap(0.0);
        self.pop.to(1.0);
    }

    /// Advances by `dt`; false when nothing moves any more (no frame needed until the next call that changes it).
    pub fn update(&mut self, dt: f32) -> bool {
        let dt = dt.clamp(0.0, 0.1);
        self.clock += dt;
        self.age += dt;
        self.impact += dt;
        if self.stage == Stage::Fly && self.age >= FLY {
            self.land();
        }
        // A transfer that is still sending: the ring follows the progress (a hair of it shows from the start).
        if matches!(self.stage, Stage::Send) {
            self.ring.to(self.goal.max(0.04));
        }
        self.ring.step(dt);
        self.squash.step(dt);
        self.pop.step(dt);
        // The ring has caught up with the end: the check.
        if self.stage == Stage::Send && self.ending == Some(true) && self.ring.value > 0.985 {
            self.enter(Stage::Done);
            self.pop.snap(0.0);
            self.pop.to(1.0);
        }
        // The ring shows a hair from the start; the number does not.
        let pct = (self.goal * 100.0).round() as i32;
        if self.stage == Stage::Send && pct != self.pct {
            self.pct = pct;
            self.title.clear();
            self.title.push_str(t("Enviando…", "Sending…"));
            self.title.push(' ');
            self.title.push_str(&pct.to_string());
            self.title.push('%');
        }
        let glow_goal = match self.stage {
            Stage::Hover | Stage::Fly => 1.0,
            Stage::Send | Stage::Done => 0.3,
            _ => 0.0,
        };
        self.glow += (glow_goal - self.glow) * (1.0 - (-dt * 9.0).exp());
        if (glow_goal - self.glow).abs() < 0.004 {
            self.glow = glow_goal;
        }
        match self.stage {
            Stage::Idle => self.glow != 0.0,
            Stage::Hover | Stage::Fly => true,
            Stage::Send => self.impact < 0.8 || !self.ring.settled(0.002) || !self.squash.settled(0.002) || self.glow != glow_goal,
            Stage::Done | Stage::Failed => self.age < 0.9 || !self.pop.settled(0.002) || !self.squash.settled(0.002) || self.glow != glow_goal,
        }
    }

    // ------------------------------------------------------------------------------------------ drawing

    pub fn draw(&self, cv: &mut Canvas, fonts: &mut Fonts, body: R, look: &Look) {
        let shake = if self.stage == Stage::Failed && !self.reduced && self.age < 0.6 { (self.age * 40.0).sin() * 5.0 * (-self.age * 7.0).exp() } else { 0.0 };
        let c = (body.cx() + shake, body.y + CENTER_Y);
        let sending = matches!(self.stage, Stage::Send | Stage::Done | Stage::Failed);
        let r = AVATAR * if self.reduced { 1.0 } else { self.squash.value };

        let accent = look.accent;
        // While a file hovers the phone lifts and sways a little; it settles as the file flies in.
        let lift = match self.stage {
            Stage::Hover if !self.reduced => 1.0,
            Stage::Fly if !self.reduced => 1.0 - smooth(self.age / FLY),
            _ => 0.0,
        };
        let pop = if self.reduced { smooth(self.age / 0.18) } else { self.pop.value.max(0.0) };
        // The landing squashes it a touch; the check makes it hop.
        let mut k = 1.0 - (1.0 - r / AVATAR) * 0.4;
        if self.stage == Stage::Done && !self.reduced {
            k *= 1.0 + 0.08 * (self.age.min(0.5) * PI / 0.5).sin() * (-self.age * 3.0).exp();
        }
        let tf = Transform::from_translate(c.0, c.1 - 4.0 * lift * (0.5 + 0.5 * (self.clock * 4.0).sin()))
            .pre_rotate(lift * 3.4 * (self.clock * 2.2).sin())
            .pre_scale(k, k);
        let at = |x: f32, y: f32| {
            let mut pt = Point::from_xy(x, y);
            tf.map_point(&mut pt);
            (pt.x, pt.y)
        };
        let body_p = rounded(-24.0, -42.0, 48.0, 84.0, 11.0).and_then(|p| p.transform(tf));
        let screen = rounded(-20.0, -38.0, 40.0, 76.0, 8.0).and_then(|p| p.transform(tf));

        // The screen: tinted, brighter while a file is over it, then filling like a glass as the file goes.
        if let Some(sc) = &screen {
            cv.fill_path(sc, color(accent, 0.10 + 0.08 * self.glow), None);
            let level = match self.stage {
                Stage::Send | Stage::Failed => self.ring.value.clamp(0.0, 1.0),
                Stage::Done => 1.0,
                _ => 0.0,
            };
            if level > 0.001 {
                let (y, amp) = (38.0 - 76.0 * level, if self.stage == Stage::Send && !self.reduced { 2.4 } else { 0.0 });
                let mut pb = PathBuilder::new();
                let (x0, y0) = at(-22.0, 40.0);
                pb.move_to(x0, y0);
                for i in 0..=22 {
                    let x = -22.0 + 2.0 * i as f32;
                    let (px, py) = at(x, y + (x / 5.0 + self.clock * 7.0).sin() * amp);
                    pb.line_to(px, py);
                }
                let (x1, y1) = at(22.0, 40.0);
                pb.line_to(x1, y1);
                pb.close();
                if let (Some(liquid), Some(mask)) = (pb.finish(), cv.mask_path(sc)) {
                    cv.fill_path(&liquid, color(accent, 1.0), Some(&mask));
                }
            }
        }
        if let Some(b) = &body_p {
            cv.stroke_path(b, color(look.fg, 1.0), 2.4, None);
        }
        if let Some(sp) = rounded(-6.0, -38.0, 12.0, 3.4, 1.7).and_then(|p| p.transform(tf)) {
            cv.fill_path(&sp, color(look.fg, 1.0), None);
        }
        // A down arrow bobbing on the screen: "drop it in here".
        let arrow = match self.stage {
            Stage::Hover => 1.0,
            Stage::Fly => 1.0 - smooth(self.age / FLY),
            _ => 0.0,
        };
        if arrow > 0.01 {
            let b = if self.reduced { 0.0 } else { (self.clock * 5.0).sin() * 3.0 };
            stroke_lines(cv, &[&[at(0.0, -12.0 + b), at(0.0, 10.0 + b)], &[at(-8.0, 3.0 + b), at(0.0, 11.0 + b), at(8.0, 3.0 + b)]], color(accent, arrow), 2.6 * k);
        }
        // The check, on the full screen.
        if self.stage == Stage::Done && pop > 0.01 {
            let s = 30.0 * pop.min(1.15);
            stroke_lines(cv, &[&[at(-0.32 * s, 0.02 * s), at(-0.08 * s, 0.26 * s), at(0.34 * s, -0.24 * s)]], color(look.on, pop.min(1.0)), 0.14 * s * k);
        }
        if self.stage == Stage::Failed && pop > 0.01 {
            let ((bx, by), br) = (at(20.0, 36.0), 10.0 * pop.min(1.15));
            cv.circle(bx, by, br + 2.0, color([0, 0, 0], 1.0), None);
            cv.circle(bx, by, br, color(RED, 1.0), None);
            icon(cv, Icon::Close, bx, by, 12.0 * pop.min(1.15), color([255, 255, 255], pop.min(1.0)), None);
        }

        // The file in flight.
        if self.stage == Stage::Fly && !self.reduced {
            let u = (self.age / FLY).clamp(0.0, 1.0);
            // The file and two fading copies behind it: the whoosh.
            for (back, alpha) in [(0.05, 0.13), (0.0, 1.0)] {
                if u >= back {
                    let (size, a, p) = flight(u - back, c);
                    thumb(cv, look, p, size, alpha * a);
                }
            }
        }

        // Words.
        let (ty, sy) = (body.y + 140.0, body.y + 158.0);
        let swap = if sending { smooth((self.impact - 0.10) / 0.22) } else { 0.0 };
        let hover_a = if sending { 1.0 - smooth(self.impact / 0.10) } else { 1.0 };
        if hover_a > 0.01 {
            cv.text_centered(fonts, &self.hover_txt, body.cx(), ty - (1.0 - hover_a) * 3.0, 13.5, Weight::Medium, look.fg, hover_a);
        }
        if swap > 0.01 {
            let slide = (1.0 - swap) * 6.0;
            let ended = matches!(self.stage, Stage::Done | Stage::Failed);
            let late = if ended { smooth((self.age - 0.06) / 0.18) } else { 0.0 };
            if !ended || self.age < 0.1 {
                let gone = if ended { 1.0 - smooth(self.age / 0.08) } else { 1.0 };
                cv.text_centered(fonts, &self.title, body.cx(), ty + slide, 13.5, Weight::Medium, look.fg, swap * gone);
            }
            if late > 0.01 {
                let (msg, col) = if self.stage == Stage::Done { (t("Enviado", "Sent"), look.fg) } else { (t("No se pudo enviar", "Could not send"), RED) };
                cv.text_centered(fonts, msg, body.cx(), ty + (1.0 - late) * 5.0, 13.5, Weight::Medium, col, late);
            }
            let sub = if self.stage == Stage::Failed && !self.fail_txt.is_empty() { &self.fail_txt } else { &self.file_txt };
            cv.text_centered(fonts, sub, body.cx(), sy + slide, 12.0, Weight::Regular, look.fg, 0.58 * swap);
        }
    }

    /// The closed island while a file is dragged toward it: the same phone, small, with its arrow (`a` fades it in).
    pub fn draw_hint(cv: &mut Canvas, c: (f32, f32), fg: Rgb, accent: Rgb, a: f32) {
        if let Some(p) = rounded(c.0 - 7.0, c.1 - 11.0, 14.0, 22.0, 3.6) {
            cv.stroke_path(&p, color(fg, a), 1.6, None);
        }
        stroke_lines(cv, &[&[(c.0, c.1 - 5.0), (c.0, c.1 + 4.0)], &[(c.0 - 3.2, c.1 + 1.0), (c.0, c.1 + 4.2), (c.0 + 3.2, c.1 + 1.0)]], color(accent, a), 1.6);
    }

    /// The compact closed island while a file goes: its thumbnail at the left, a tiny progress ring at the right.
    pub fn draw_pill(&self, cv: &mut Canvas, pill: R, thumb_img: Option<&Image>, fg: Rgb, accent: Rgb, a: f32) {
        let (ty, c) = (pill.cy() - 11.0, (pill.right() - 18.0, pill.cy()));
        let tr = R::new(pill.x + 14.0, ty, 22.0, 22.0);
        match thumb_img {
            Some(img) => cv.image(img, tr, 6.0, a, None),
            None => {
                cv.squircle(tr, 6.0, color(fg, 0.16 * a), None);
                icon(cv, Icon::File, tr.cx(), tr.cy(), 14.0, color(fg, a), None);
            }
        }
        cv.ring(c.0, c.1, 8.5, color(fg, 0.16 * a), 2.4, None);
        if self.stage == Stage::Done {
            let s = if self.reduced { 1.0 } else { self.pop.value.clamp(0.0, 1.12) };
            cv.circle(c.0, c.1, 9.0 * s, color(accent, a), None);
            icon(cv, Icon::Check, c.0, c.1, 12.0 * s, color(if luma(accent) > 0.6 { [10, 10, 12] } else { [255, 255, 255] }, a), None);
        } else if let Some(p) = arc(c, 8.5, -PI / 2.0, self.ring.value.clamp(0.0, 1.0).max(0.04) * TAU) {
            let col = if self.stage == Stage::Failed { RED } else { accent };
            cv.stroke_path(&p, color(col, a), 2.4, None);
        }
    }
}

impl Default for AirDrop {
    fn default() -> Self {
        Self::new()
    }
}

fn smooth(x: f32) -> f32 {
    let x = x.clamp(0.0, 1.0);
    x * x * (3.0 - 2.0 * x)
}

/// A rounded rectangle (circular corners), for the phone's outline and screen.
fn rounded(x: f32, y: f32, w: f32, h: f32, r: f32) -> Option<tiny_skia::Path> {
    let k = 0.5523 * r;
    let mut pb = PathBuilder::new();
    pb.move_to(x + r, y);
    pb.line_to(x + w - r, y);
    pb.cubic_to(x + w - r + k, y, x + w, y + r - k, x + w, y + r);
    pb.line_to(x + w, y + h - r);
    pb.cubic_to(x + w, y + h - r + k, x + w - r + k, y + h, x + w - r, y + h);
    pb.line_to(x + r, y + h);
    pb.cubic_to(x + r - k, y + h, x, y + h - r + k, x, y + h - r);
    pb.line_to(x, y + r);
    pb.cubic_to(x, y + r - k, x + r - k, y, x + r, y);
    pb.close();
    pb.finish()
}

/// Open polylines with round ends (arrows, the check).
fn stroke_lines(cv: &mut Canvas, lines: &[&[(f32, f32)]], c: tiny_skia::Color, width: f32) {
    let mut pb = PathBuilder::new();
    for l in lines {
        pb.move_to(l[0].0, l[0].1);
        for p in &l[1..] {
            pb.line_to(p.0, p.1);
        }
    }
    if let Some(p) = pb.finish() {
        cv.stroke_path(&p, c, width, None);
    }
}

fn luma(c: Rgb) -> f32 {
    (0.299 * c[0] as f32 + 0.587 * c[1] as f32 + 0.114 * c[2] as f32) / 255.0
}

/// The thumbnail's place along its path at `u` (0..1): from up-left of the picture, over an arch, accelerating in.
/// Returns (side, alpha, centre).
fn flight(u: f32, c: (f32, f32)) -> (f32, f32, (f32, f32)) {
    let e = u.powf(1.7);
    let (p0, p1) = ((c.0 - 140.0, c.1 - 20.0), (c.0 - 58.0, c.1 - 62.0));
    let (a, b) = ((1.0 - e).powi(2), 2.0 * (1.0 - e) * e);
    let p = (a * p0.0 + b * p1.0 + e * e * c.0, a * p0.1 + b * p1.1 + e * e * c.1);
    // Full size at the start, shrinking to a third by the time it is inside the picture, gone in the last 15 %.
    (46.0 * (1.0 - 0.66 * e), (1.0 - (u - 0.85).max(0.0) / 0.15).clamp(0.0, 1.0), p)
}

/// The file's preview as a rounded square, or a file glyph on a chip.
fn thumb(cv: &mut Canvas, look: &Look, p: (f32, f32), side: f32, a: f32) {
    if a < 0.01 {
        return;
    }
    let r = R::new(p.0 - side / 2.0, p.1 - side / 2.0, side, side);
    match look.thumb {
        Some(img) => cv.image(img, r, side * 0.24, a, None),
        None => {
            cv.squircle(r, side * 0.24, color(look.fg, 0.20 * a), None);
            cv.squircle(r.inset(1.0, 1.0, 1.0, 1.0), side * 0.22, color([38, 44, 58], a), None);
            icon(cv, Icon::File, p.0, p.1, side * 0.52, color(look.fg, a), None);
        }
    }
}

/// An arc of `sweep` radians (clockwise on screen) starting at angle `a0`, in cubic pieces of at most a quarter turn.
fn arc(c: (f32, f32), r: f32, a0: f32, sweep: f32) -> Option<tiny_skia::Path> {
    let mut pb = PathBuilder::new();
    pb.move_to(c.0 + r * a0.cos(), c.1 + r * a0.sin());
    let n = (sweep / (PI / 2.0)).ceil().max(1.0) as usize;
    let step = sweep / n as f32;
    let k = 4.0 / 3.0 * (step / 4.0).tan();
    for i in 0..n {
        let (a, b) = (a0 + step * i as f32, a0 + step * (i + 1) as f32);
        let (p0, p3) = ((c.0 + r * a.cos(), c.1 + r * a.sin()), (c.0 + r * b.cos(), c.1 + r * b.sin()));
        pb.cubic_to(p0.0 - k * r * a.sin(), p0.1 + k * r * a.cos(), p3.0 + k * r * b.sin(), p3.1 - k * r * b.cos(), p3.0, p3.1);
    }
    pb.finish()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(a: &mut AirDrop, secs: f32) {
        let mut t = 0.0;
        while t < secs {
            a.update(1.0 / 120.0);
            t += 1.0 / 120.0;
        }
    }

    #[test]
    fn it_goes_through_the_whole_trip_and_then_asks_for_no_more_frames() {
        let mut a = AirDrop::new();
        assert!(!a.update(0.016), "idle needs nothing");
        a.hover(true);
        assert!(a.update(0.016), "hover breathes");
        a.dropped();
        assert_eq!(a.stage, Stage::Fly);
        run(&mut a, 0.6);
        assert_eq!(a.stage, Stage::Send);
        a.progress(0.5);
        run(&mut a, 1.5);
        assert!((a.ring.value - 0.5).abs() < 0.02);
        assert!(!a.update(0.016), "a steady ring needs no frames");
        a.finish(true);
        run(&mut a, 1.0);
        assert_eq!(a.stage, Stage::Done);
        assert!(a.done_for().is_some());
        run(&mut a, 1.0);
        assert!(!a.update(0.016));
    }

    #[test]
    fn a_failure_shakes_and_settles() {
        let mut a = AirDrop::new();
        a.hover(true);
        a.dropped();
        run(&mut a, 0.6);
        a.finish(false);
        assert_eq!(a.stage, Stage::Failed);
        run(&mut a, 1.5);
        assert!(!a.update(0.016));
    }

    #[test]
    fn reduced_motion_skips_the_flight() {
        let mut a = AirDrop::new();
        a.set_reduced(true);
        a.hover(true);
        a.dropped();
        assert_eq!(a.stage, Stage::Send, "no flight");
    }

    #[test]
    fn a_finish_without_a_drop_here_is_ignored() {
        let mut a = AirDrop::new();
        a.finish(true);
        assert_eq!(a.stage, Stage::Idle);
    }

    #[test]
    fn the_arc_is_a_closed_path_at_full_sweep() {
        assert!(arc((50.0, 50.0), 30.0, -PI / 2.0, TAU).is_some());
        assert!(arc((50.0, 50.0), 30.0, -PI / 2.0, 0.1).is_some());
    }
}
