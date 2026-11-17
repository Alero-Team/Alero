//! Everything that is drawn, laid out the way the QNotch notch lays itself out: a 38 px pill hanging from the top
//! edge, and a 720 × 380 panel with a header (profile, sliding tab strip, actions) over a body of cards or tabs.
//! Sizes, radii, margins and colours are QNotch's own (its dark and light palettes, its card chrome, its rows).

use std::time::Instant;

use super::config::{luma, IslandConfig};
use super::gfx::{color, icon, mix, squircle, Canvas, Fonts, Icon, Rgb, Weight, R};
use super::model::{Media, Model, XState};
use super::ui::{Act, Hit, LocalTime, Note, Page, Peek, View};
use crate::lang::t;

pub const PANEL_W: f32 = 720.0;
pub const PANEL_H: f32 = 380.0;
pub const PILL_H: f32 = 38.0;
pub const PILL_R: f32 = 16.0;
pub const PANEL_R: f32 = 26.0;
pub const TAB_W: f32 = 40.0;
pub const TAB_GAP: f32 = 2.0;
const HEAD_H: f32 = 58.0;

const UNIT: f32 = 218.0;
const GAP: f32 = 10.0;
const ROW_H: f32 = 148.0;

/// QNotch's palette: surface and text brushes from `Theme.Dark.xaml` / `Theme.Light.xaml`, over the chosen background.
pub struct Pal {
    pub bg: Rgb,
    /// Base of the translucent overlays (white on dark, black on light).
    pub fg: Rgb,
    pub t1: Rgb,
    pub t2: Rgb,
    pub t3: Rgb,
    pub accent: Rgb,
    pub on_accent: Rgb,
    pub danger: Rgb,
    pub success: Rgb,
    pub warning: Rgb,
    pub card: Rgb,
    pub card_hover: Rgb,
    pub light: bool,
}

impl Pal {
    fn stroke(&self) -> f32 {
        if self.light { 0.10 } else { 0.15 }
    }
    fn stroke_strong(&self) -> f32 {
        if self.light { 0.20 } else { 0.25 }
    }
    fn control(&self) -> f32 {
        if self.light { 0.05 } else { 0.08 }
    }
    fn control_hover(&self) -> f32 {
        if self.light { 0.09 } else { 0.13 }
    }
    fn control_pressed(&self) -> f32 {
        if self.light { 0.13 } else { 0.18 }
    }
}

pub fn palette(cfg: &IslandConfig) -> Pal {
    let bg = cfg.background();
    let light = luma(bg) > 0.55;
    let accent = cfg.accent_rgb();
    let on_accent: Rgb = if luma(accent) > 0.55 { [0x0B, 0x0B, 0x0D] } else { [255, 255, 255] };
    if light {
        Pal {
            bg,
            fg: [0, 0, 0],
            t1: [0x13, 0x13, 0x16],
            t2: [0x5B, 0x5B, 0x67],
            t3: [0x8D, 0x8D, 0x99],
            accent,
            on_accent,
            danger: [0xD9, 0x3B, 0x3B],
            success: [0x1E, 0x9E, 0x5A],
            warning: [0xC7, 0x77, 0x00],
            card: mix(bg, [255, 255, 255], 0.8),
            card_hover: mix(bg, [0, 0, 0], 0.03),
            light,
        }
    } else {
        Pal {
            bg,
            fg: [255, 255, 255],
            t1: [0xF4, 0xF4, 0xF7],
            t2: [0xA1, 0xA1, 0xAD],
            t3: [0x6F, 0x6F, 0x7B],
            accent,
            on_accent,
            danger: [0xFF, 0x6B, 0x6B],
            success: [0x4C, 0xD9, 0x8C],
            warning: [0xFF, 0xB7, 0x4D],
            card: mix(bg, [255, 255, 255], 0.09),
            card_hover: mix(bg, [255, 255, 255], 0.13),
            light,
        }
    }
}

/// What the screens show, gathered from the island's state so the drawing code stays free of it.
pub struct Ui<'a> {
    pub model: &'a Model,
    pub cfg: &'a IslandConfig,
    pub view: &'a View,
    pub page: Page,
    pub note: &'a Note,
    pub tabs: &'a [(Icon, Page)],
    pub tab_x: f32,
    pub player_pc: Option<bool>,
    pub seen: Instant,
    pub copied: Option<(usize, f32)>,
    pub drag_over: bool,
    pub pinned: bool,
    pub time: LocalTime,
    pub peek: Option<&'a Peek>,
    pub peek_fade: f32,
}

pub struct Draw<'a> {
    pub cv: &'a mut Canvas,
    pub fonts: &'a mut Fonts,
    pub hits: &'a mut Vec<Hit>,
    pub pal: &'a Pal,
    pub pointer: Option<(f32, f32)>,
    pub pressed: Option<usize>,
}

pub fn fmt_size(b: u64) -> String {
    let f = b as f64;
    if f >= 1073741824.0 {
        format!("{:.1} GB", f / 1073741824.0)
    } else if f >= 1048576.0 {
        format!("{:.1} MB", f / 1048576.0)
    } else {
        format!("{:.0} KB", (f / 1024.0).max(1.0))
    }
}

fn fmt_time(ms: i64) -> String {
    let s = (ms.max(0) / 1000) as u64;
    format!("{}:{:02}", s / 60, s % 60)
}

/// Whether the computer's player (rather than the phone's) is the one to show.
pub fn pick_pc(m: &Model, pref: Option<bool>) -> bool {
    if let Some(v) = pref {
        return v;
    }
    let pc = m.pc_media.as_ref().filter(|x| !x.is_empty());
    let ph = m.phone_media.as_ref().filter(|x| !x.is_empty());
    match (pc, ph) {
        (Some(p), Some(f)) => p.playing || !f.playing,
        (Some(_), None) => true,
        _ => false,
    }
}

pub fn pick_media(m: &Model, pref: Option<bool>) -> Option<(&Media, bool)> {
    let pc = m.pc_media.as_ref().filter(|x| !x.is_empty());
    let ph = m.phone_media.as_ref().filter(|x| !x.is_empty());
    if pick_pc(m, pref) {
        pc.map(|x| (x, true)).or(ph.map(|x| (x, false)))
    } else {
        ph.map(|x| (x, false)).or(pc.map(|x| (x, true)))
    }
}

// ---------------------------------------------------------------------------------------------------------
// Shapes

const K: f32 = 0.5523;

/// The notch's outline: square on top (it hangs from the edge) and rounded at the bottom, or rounded all round when
/// it floats below the edge.
pub fn surf_path(s: R, r: f32, flat_top: bool) -> Option<tiny_skia::Path> {
    let r = r.min(s.w / 2.0).min(s.h / 2.0).max(0.0);
    if !flat_top {
        return squircle(s, r, 2.0);
    }
    let mut pb = tiny_skia::PathBuilder::new();
    let (x, y, w, h) = (s.x, s.y, s.w, s.h);
    pb.move_to(x, y);
    pb.line_to(x + w, y);
    pb.line_to(x + w, y + h - r);
    pb.cubic_to(x + w, y + h - r + K * r, x + w - r + K * r, y + h, x + w - r, y + h);
    pb.line_to(x + r, y + h);
    pb.cubic_to(x + r - K * r, y + h, x, y + h - r + K * r, x, y + h - r);
    pb.close();
    pb.finish()
}

/// The 1 px rim: left, bottom and right (no line along the top edge), like QNotch's `BorderThickness="1,0,1,1"`.
pub fn surf_rim(s: R, r: f32, flat_top: bool) -> Option<tiny_skia::Path> {
    let r = (r - 0.5).min(s.w / 2.0).min(s.h / 2.0).max(0.0);
    let (x, y, w, h) = (s.x + 0.5, s.y, s.w - 1.0, s.h - 0.5);
    if !flat_top {
        return squircle(R::new(x, s.y + 0.5, w, h), r, 2.0);
    }
    let mut pb = tiny_skia::PathBuilder::new();
    pb.move_to(x, y);
    pb.line_to(x, y + h - r);
    pb.cubic_to(x, y + h - r + K * r, x + r - K * r, y + h, x + r, y + h);
    pb.line_to(x + w - r, y + h);
    pb.cubic_to(x + w - r + K * r, y + h, x + w, y + h - r + K * r, x + w, y + h - r);
    pb.line_to(x + w, y);
    pb.finish()
}

fn rr_path(r: R, rad: f32) -> Option<tiny_skia::Path> {
    squircle(r, rad, 2.0)
}

impl Draw<'_> {
    pub fn hot(&self, r: R) -> bool {
        self.pointer.is_some_and(|(x, y)| r.contains(x, y))
    }

    pub fn is_down(&self, r: R) -> bool {
        self.pressed.and_then(|i| self.hits.get(i)).is_some_and(|h| h.r == r)
    }

    pub fn add(&mut self, r: R, act: Act) {
        self.hits.push(Hit { r, act });
    }

    /// A filled rectangle with circular corners.
    pub fn rr(&mut self, r: R, rad: f32, c: Rgb, a: f32) {
        if r.w < 0.5 || r.h < 0.5 {
            return;
        }
        if let Some(p) = rr_path(r, rad) {
            self.cv.fill_path(&p, color(c, a), None);
        }
    }

    /// A 1 px outline drawn inside `r`.
    pub fn ring(&mut self, r: R, rad: f32, c: Rgb, a: f32, width: f32) {
        let h = width / 2.0;
        if let Some(p) = rr_path(R::new(r.x + h, r.y + h, r.w - width, r.h - width), (rad - h).max(0.0)) {
            self.cv.stroke_path(&p, color(c, a), width, None);
        }
    }

    pub fn overlay(&mut self, r: R, rad: f32, a: f32) {
        let fg = self.pal.fg;
        self.rr(r, rad, fg, a);
    }

    /// Text whose vertical centre is `cy`.
    pub fn text(&mut self, s: &str, x: f32, cy: f32, size: f32, w: Weight, c: Rgb, a: f32) -> f32 {
        self.cv.text(self.fonts, s, x, cy + size * 0.35, size, w, c, a)
    }

    pub fn text_fit(&mut self, s: &str, x: f32, cy: f32, max: f32, size: f32, w: Weight, c: Rgb, a: f32) -> f32 {
        let fit = self.fonts.fit(s, size, w, max);
        self.text(&fit, x, cy, size, w, c, a)
    }

    pub fn text_right(&mut self, s: &str, right: f32, cy: f32, size: f32, w: Weight, c: Rgb, a: f32) {
        let width = self.fonts.measure(s, size, w);
        self.text(s, right - width, cy, size, w, c, a);
    }

    pub fn text_center(&mut self, s: &str, cx: f32, cy: f32, size: f32, w: Weight, c: Rgb, a: f32) {
        let width = self.fonts.measure(s, size, w);
        self.text(s, cx - width / 2.0, cy, size, w, c, a);
    }

    pub fn glyph(&mut self, ic: Icon, cx: f32, cy: f32, size: f32, c: Rgb, a: f32) {
        icon(self.cv, ic, cx, cy, size, color(c, a), None);
    }

    /// The thin progress bar of QNotch: 5 px, a hover-grey track and an accent fill.
    pub fn bar(&mut self, r: R, f: f32, c: Rgb) {
        let hov = self.pal.control_hover();
        self.overlay(r, r.h * 0.6, hov);
        let w = (r.w * f.clamp(0.0, 1.0)).max(if f > 0.0 { r.h } else { 0.0 });
        if w > 0.0 {
            self.rr(R::new(r.x, r.y, w, r.h), r.h * 0.6, c, 1.0);
        }
    }

    /// Circle with the first letter (the "profile" look: accent-soft fill, accent letter).
    pub fn avatar(&mut self, c: (f32, f32), size: f32, label: &str) {
        let acc = self.pal.accent;
        self.cv.circle(c.0, c.1, size / 2.0, color(acc, 0.22), None);
        let ch = label.chars().next().map(|c| c.to_uppercase().to_string()).unwrap_or_else(|| "?".into());
        self.text_center(&ch, c.0, c.1, size * 0.44, Weight::Bold, acc, 1.0);
    }

    /// `IconButton` / `IconToggle`: 30 × 30, radius 8, a hover tint, accent-soft when on.
    pub fn icon_btn(&mut self, r: R, ic: Icon, act: Act, on: bool) {
        let (hot, down) = (self.hot(r), self.is_down(r));
        let (acc, t1, t2) = (self.pal.accent, self.pal.t1, self.pal.t2);
        if on {
            self.rr(r, 8.0, acc, 0.22);
        } else if down {
            let a = self.pal.control_pressed();
            self.overlay(r, 8.0, a);
        } else if hot {
            let a = self.pal.control_hover();
            self.overlay(r, 8.0, a);
        }
        let c = if on { acc } else if hot || down { t1 } else { t2 };
        self.glyph(ic, r.cx(), r.cy(), 14.0, c, 1.0);
        self.add(r, act);
    }

    /// A plain `Button` (control background, radius 8) or the `AccentButton`.
    pub fn button(&mut self, r: R, label: &str, act: Act, accent: bool) {
        let (hot, down) = (self.hot(r), self.is_down(r));
        let p = self.pal;
        if accent {
            let base = p.accent;
            let fill = if down { mix(base, p.bg, 0.15) } else if hot { mix(base, p.fg, 0.18) } else { base };
            self.rr(r, 8.0, fill, 1.0);
        } else {
            let a = if down { p.control_pressed() } else if hot { p.control_hover() } else { p.control() };
            self.overlay(r, 8.0, a);
        }
        let fg = if accent { p.on_accent } else { p.t1 };
        let label = self.fonts.fit(label, 12.0, Weight::Medium, r.w - 16.0);
        self.text_center(&label, r.cx(), r.cy(), 12.0, Weight::Medium, fg, 1.0);
        self.add(r, act);
    }

    /// A round glyph button (media transport, call buttons).
    pub fn round(&mut self, c: (f32, f32), size: f32, ic: Icon, act: Act, fill: Option<Rgb>, fg: Rgb, glyph: f32) {
        let r = R::new(c.0 - size / 2.0, c.1 - size / 2.0, size, size);
        let (hot, down) = (self.hot(r), self.is_down(r));
        match fill {
            Some(f) => {
                let f = if down { mix(f, self.pal.bg, 0.15) } else if hot { mix(f, self.pal.fg, 0.18) } else { f };
                self.cv.circle(c.0, c.1, size / 2.0, color(f, 1.0), None);
            }
            None => {
                if hot || down {
                    let a = if down { self.pal.control_pressed() } else { self.pal.control_hover() };
                    let fg0 = self.pal.fg;
                    self.cv.circle(c.0, c.1, size / 2.0, color(fg0, a), None);
                }
            }
        }
        self.glyph(ic, c.0, c.1, glyph, fg, 1.0);
        self.add(r, act);
    }

    /// QNotch's card chrome: radius 14, a 1 px stroke, a title in the corner. Returns the area for the body.
    fn card(&mut self, r: R, title: &str, act: Option<Act>, badge: Option<usize>) -> R {
        let hot = self.hot(r);
        let (fill, stroke) = if hot { (self.pal.card_hover, self.pal.stroke_strong()) } else { (self.pal.card, self.pal.stroke()) };
        self.rr(r, 14.0, fill, 1.0);
        let fg = self.pal.fg;
        self.ring(r, 14.0, fg, stroke, 1.0);
        let t2 = self.pal.t2;
        let tw = r.w - 28.0 - if badge.is_some() { 28.0 } else { 0.0 };
        self.text_fit(title, r.x + 14.0, r.y + 12.0 + 7.5, tw, 11.0, Weight::Medium, t2, 1.0);
        if let Some(n) = badge.filter(|n| *n > 0) {
            let (acc, on) = (self.pal.accent, self.pal.on_accent);
            let c = (r.right() - 14.0 - 10.0, r.y + 12.0 + 7.5);
            self.cv.circle(c.0, c.1, 10.0, color(acc, 1.0), None);
            self.text_center(&n.min(9).to_string(), c.0, c.1, 11.0, Weight::Bold, on, 1.0);
        }
        let body = R::new(r.x + 14.0, r.y + 12.0 + 15.0 + 8.0, r.w - 28.0, r.h - 12.0 - 15.0 - 8.0 - 12.0);
        let _ = act;
        body
    }
}

// ---------------------------------------------------------------------------------------------------------
// Pill

/// One piece of the collapsed pill.
enum Seg {
    Media { title: String, artist: String, art: bool },
    Battery { pct: i32, charging: bool },
    Unread(usize),
    Clock(String),
}

fn clock_text(t: &LocalTime) -> String {
    format!("{:02}:{:02}", t.hour, t.min)
}

fn segs(u: &Ui) -> Vec<Seg> {
    let mut v = Vec::new();
    if u.cfg.modules.player {
        if let Some((m, _)) = pick_media(u.model, u.player_pc).filter(|(m, _)| m.playing || !m.title.is_empty()) {
            v.push(Seg::Media { title: m.title.clone(), artist: m.artist.clone(), art: m.art.is_some() });
        }
    }
    if u.cfg.modules.status {
        if let Some(i) = u.model.target().and_then(|p| u.model.info.get(&p.id)).filter(|i| i.battery >= 0) {
            v.push(Seg::Battery { pct: i.battery.clamp(0, 100), charging: i.charging });
        }
    }
    if u.cfg.modules.notifications {
        let n = u.model.unread(u.seen);
        if n > 0 {
            v.push(Seg::Unread(n));
        }
    }
    v.push(Seg::Clock(clock_text(&u.time)));
    v
}

const PILL_PAD: (f32, f32) = (16.0, 18.0);

fn seg_width(f: &mut Fonts, s: &Seg) -> f32 {
    match s {
        Seg::Media { title, artist, .. } => {
            let tw = f.measure(title, 12.0, Weight::Bold).min(120.0);
            let aw = if artist.is_empty() { 0.0 } else { 6.0 + f.measure(artist, 12.0, Weight::Regular).min(80.0) };
            22.0 + 8.0 + tw + aw
        }
        Seg::Battery { pct, .. } => 15.0 + 4.0 + f.measure(&format!("{pct}%"), 12.0, Weight::Bold),
        Seg::Unread(n) => 13.0 + 5.0 + f.measure(&(*n).min(99).to_string(), 12.0, Weight::Bold),
        Seg::Clock(c) => f.measure(c, 13.0, Weight::Bold).max(36.0),
    }
}

/// Width the pill wants right now (QNotch: content plus margins, rounded up to a multiple of 4, plus 2; at least 96).
pub fn pill_width(f: &mut Fonts, u: &Ui, prev: f32) -> f32 {
    if let Some(p) = u.peek {
        let text = f.measure(&p.text, 13.0, Weight::Bold).min(320.0);
        let own = 20.0 + 14.0 + 8.0 + text + 22.0;
        // Always a bit wider than the pill was, however full it is, so the change catches the eye.
        return own.max((prev + 48.0).clamp(200.0, PANEL_W - 60.0)).ceil();
    }
    let list = segs(u);
    let mut w = 0.0;
    for (i, s) in list.iter().enumerate() {
        w += seg_width(f, s);
        if i + 1 < list.len() {
            w += if matches!(s, Seg::Media { .. }) { 18.0 } else { 12.0 };
        }
    }
    let content = PILL_PAD.0 + w + PILL_PAD.1;
    ((content / 4.0).ceil() * 4.0 + 2.0).max(96.0)
}

pub fn draw_pill(d: &mut Draw, u: &Ui, s: R) {
    let cy = s.y + PILL_H / 2.0 - 0.5;
    let p = d.pal;
    if let Some(pk) = u.peek {
        let text = d.fonts.fit(&pk.text, 13.0, Weight::Bold, 320.0);
        let tw = d.fonts.measure(&text, 13.0, Weight::Bold);
        let total = 14.0 + 8.0 + tw;
        let x = s.cx() - total / 2.0;
        let col = if pk.good { p.success } else { p.accent };
        d.glyph(pk.icon, x + 7.0, cy, 14.0, col, u.peek_fade);
        d.text(&text, x + 22.0, cy, 13.0, Weight::Bold, p.t1, u.peek_fade);
        return;
    }
    let list = segs(u);
    let widths: Vec<f32> = list.iter().map(|g| seg_width(d.fonts, g)).collect();
    let mut total = 0.0;
    for (i, g) in list.iter().enumerate() {
        total += widths[i];
        if i + 1 < list.len() {
            total += if matches!(g, Seg::Media { .. }) { 18.0 } else { 12.0 };
        }
    }
    let mut x = s.cx() - total / 2.0;
    for (i, g) in list.iter().enumerate() {
        match g {
            Seg::Media { title, artist, art } => {
                let tile = R::new(x, cy - 11.0, 22.0, 22.0);
                match u.model.pc_media.as_ref().filter(|m| *art && m.art.is_some()).or(u.model.phone_media.as_ref().filter(|m| *art && m.art.is_some())) {
                    Some(m) if m.art.is_some() => d.cv.image(m.art.as_ref().unwrap(), tile, 6.0, 1.0, None),
                    _ => {
                        let a = p.control_hover();
                        d.overlay(tile, 6.0, a);
                        d.glyph(Icon::Music, tile.cx(), tile.cy(), 11.0, p.t2, 1.0);
                    }
                }
                let tw = d.fonts.measure(title, 12.0, Weight::Bold).min(120.0);
                d.text_fit(title, x + 30.0, cy, 120.0, 12.0, Weight::Bold, p.t1, 1.0);
                if !artist.is_empty() {
                    d.text_fit(artist, x + 30.0 + tw + 6.0, cy, 80.0, 12.0, Weight::Regular, p.t2, 1.0);
                }
            }
            Seg::Battery { pct, charging } => {
                let col = if *charging { p.success } else if *pct < 20 { p.danger } else { p.t2 };
                d.glyph(if *charging { Icon::Bolt } else { Icon::Battery }, x + 7.5, cy, 15.0, col, 1.0);
                d.text(&format!("{pct}%"), x + 19.0, cy, 12.0, Weight::Bold, p.t1, 1.0);
            }
            Seg::Unread(n) => {
                d.glyph(Icon::Bell, x + 6.5, cy, 13.0, p.accent, 1.0);
                d.text(&(*n).min(99).to_string(), x + 18.0, cy, 12.0, Weight::Bold, p.t1, 1.0);
            }
            Seg::Clock(c) => {
                d.text(c, x, cy, 13.0, Weight::Bold, p.t1, 1.0);
            }
        }
        x += widths[i] + if matches!(g, Seg::Media { .. }) { 18.0 } else { 12.0 };
    }
}

// ---------------------------------------------------------------------------------------------------------
// Panel

pub fn view_size(v: &View) -> (f32, f32, f32) {
    match v {
        View::Page(_) => (PANEL_W, PANEL_H, PANEL_R),
        View::Call => (440.0, 100.0, 24.0),
        View::Offer => (440.0, 150.0, 24.0),
        View::Transfer(_) => (440.0, 108.0, 24.0),
        View::Note => (440.0, 86.0, 22.0),
        View::Drop => (440.0, 156.0, 24.0),
    }
}

pub fn tab_x(i: usize) -> f32 {
    i as f32 * (TAB_W + TAB_GAP)
}

/// The header (a panel) and what is below it. `o` is the panel's top-left corner. `header` and `body` are drawn
/// separately because the body fades in on its own when the tab changes.
pub fn draw_header(d: &mut Draw, u: &Ui, o: (f32, f32)) {
    let p = d.pal;
    let cy = o.1 + 34.0;
    // Profile: the phone that is connected, in the place of QNotch's profile picture.
    let name = u.model.target().map(|x| x.name.clone()).unwrap_or_else(|| "Alero".into());
    d.avatar((o.0 + 23.0 + 16.0, cy), 32.0, &name);
    d.add(R::new(o.0 + 23.0, cy - 16.0, 190.0, 32.0), Act::Device);
    d.text_fit(&name, o.0 + 23.0 + 42.0, cy - 8.0, 150.0, 13.0, Weight::Bold, p.t1, 1.0);
    d.text_fit(&date_text(&u.time), o.0 + 23.0 + 42.0, cy + 9.0, 170.0, 11.0, Weight::Regular, p.t3, 1.0);
    // Tabs: one container, one sliding indicator, the icons on top.
    let n = u.tabs.len() as f32;
    let cw = 6.0 + n * TAB_W + (n - 1.0) * TAB_GAP;
    let cont = R::new(o.0 + 23.0 + 680.0 / 2.0 - cw / 2.0, cy - 18.0, cw, 36.0);
    let a = p.control();
    d.overlay(cont, 12.0, a);
    let ind = R::new(cont.x + 3.0 + u.tab_x, cont.y + 3.0, TAB_W, 30.0);
    let a = p.control_hover();
    d.overlay(ind, 9.0, a);
    let fg = p.fg;
    d.ring(ind, 9.0, fg, p.stroke(), 1.0);
    for (i, (ic, page)) in u.tabs.iter().enumerate() {
        let r = R::new(cont.x + 3.0 + tab_x(i), cont.y + 3.0, TAB_W, 30.0);
        let on = *page == u.page && matches!(u.view, View::Page(_));
        let hot = d.hot(r);
        if hot && !on {
            let a = p.control();
            d.overlay(r, 9.0, a);
        }
        let c = if on { p.accent } else if hot { p.t1 } else { p.t3 };
        d.glyph(*ic, r.cx(), r.cy(), 15.0, c, 1.0);
        if *page == Page::Notifs {
            let n = u.model.unread(u.seen);
            if n > 0 && !on {
                d.cv.circle(r.right() - 9.0, r.y + 7.0, 4.5, color(p.accent, 1.0), None);
            }
        }
        d.add(r, Act::Go(*page));
    }
    // Actions.
    let right = o.0 + PANEL_W - 17.0;
    let open = R::new(right - 30.0, cy - 15.0, 30.0, 30.0);
    let pin = R::new(open.x - 4.0 - 30.0, cy - 15.0, 30.0, 30.0);
    d.icon_btn(pin, Icon::Pin, Act::Pin, u.pinned);
    d.icon_btn(open, Icon::Open, Act::OpenApp, false);
}

fn date_text(t: &LocalTime) -> String {
    const ES_D: [&str; 7] = ["domingo", "lunes", "martes", "miércoles", "jueves", "viernes", "sábado"];
    const EN_D: [&str; 7] = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
    const ES_M: [&str; 12] = ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre"];
    const EN_M: [&str; 12] = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
    let (wd, mo) = ((t.wday % 7) as usize, (t.month.clamp(1, 12) - 1) as usize);
    if crate::lang::spanish() {
        format!("{}, {} de {}", ES_D[wd], t.day, ES_M[mo])
    } else {
        format!("{}, {} {}", EN_D[wd], EN_M[mo], t.day)
    }
}

pub fn draw_body(d: &mut Draw, u: &Ui, o: (f32, f32)) {
    let body = R::new(o.0 + 4.0, o.1 + HEAD_H, PANEL_W - 8.0, PANEL_H - HEAD_H);
    match u.view {
        View::Page(Page::Home) => home(d, u, body),
        View::Page(Page::Player) => player_tab(d, u, body),
        View::Page(Page::Files) => files_tab(d, u, body),
        View::Page(Page::Notifs) => notifs_tab(d, u, body),
        View::Page(Page::Clipboard) => clipboard_tab(d, u, body),
        View::Page(Page::Controls) => controls_tab(d, u, body),
        _ => {}
    }
}

/// The compact screens (a call, an offer, a transfer, a note, the drop target): one rounded surface, no header.
pub fn draw_event(d: &mut Draw, u: &Ui, s: R) {
    match u.view {
        View::Call => call(d, u, s),
        View::Offer => offer(d, u, s),
        View::Transfer(id) => transfer(d, u, s, id),
        View::Note => note(d, u, s),
        View::Drop => drop_screen(d, u, s),
        _ => {}
    }
}

// ---- Home: the card grid ------------------------------------------------------------------------------------

#[derive(Clone, Copy, PartialEq)]
enum CardKind {
    Media,
    Phone,
    Notifs,
    Clip,
    Quick,
}

fn home(d: &mut Draw, u: &Ui, body: R) {
    let m = &u.cfg.modules;
    let mut cards: Vec<(CardKind, usize)> = Vec::new();
    if m.player {
        cards.push((CardKind::Media, 2));
    }
    if m.status {
        cards.push((CardKind::Phone, 1));
    }
    if m.notifications {
        cards.push((CardKind::Notifs, 1));
    }
    if m.clipboard {
        cards.push((CardKind::Clip, 1));
    }
    if m.controls {
        cards.push((CardKind::Quick, 1));
    }
    if cards.is_empty() {
        d.text_center(t("Tu Home está vacío", "Your Home is empty"), body.cx(), body.cy() - 8.0, 14.0, Weight::Bold, d.pal.t1, 1.0);
        d.text_center(t("Elige qué aparece aquí en Ajustes › Alero Island.", "Choose what appears here in Settings › Alero Island."), body.cx(), body.cy() + 12.0, 12.0, Weight::Regular, d.pal.t3, 1.0);
        return;
    }
    // WrapPanel of three columns, 218 wide each with a 10 gap (every card has a 5 px margin on each side).
    let left = body.x + (body.w - 3.0 * (UNIT + GAP)) / 2.0 + GAP / 2.0;
    let (mut col, mut row) = (0usize, 0usize);
    for (kind, span) in cards {
        if col + span > 3 {
            col = 0;
            row += 1;
        }
        let r = R::new(left + col as f32 * (UNIT + GAP), body.y + row as f32 * (ROW_H + GAP), span as f32 * (UNIT + GAP) - GAP, ROW_H);
        col += span;
        if r.bottom() > body.bottom() + 8.0 {
            break;
        }
        match kind {
            CardKind::Media => media_card(d, u, r),
            CardKind::Phone => phone_card(d, u, r),
            CardKind::Notifs => notifs_card(d, u, r),
            CardKind::Clip => clip_card(d, u, r),
            CardKind::Quick => quick_card(d, u, r),
        }
    }
}

fn media_card(d: &mut Draw, u: &Ui, r: R) {
    let c = d.card(r, t("Reproductor", "Now playing"), None, None);
    let p = d.pal;
    let Some((md, is_pc)) = pick_media(u.model, u.player_pc) else {
        d.glyph(Icon::Music, c.cx(), c.cy() - 8.0, 22.0, p.t3, 1.0);
        d.text_center(t("Nada en reproducción", "Nothing is playing"), c.cx(), c.cy() + 16.0, 12.0, Weight::Regular, p.t2, 1.0);
        d.add(r, Act::Go(Page::Player));
        return;
    };
    let both = u.model.pc_media.as_ref().is_some_and(|m| !m.is_empty()) && u.model.phone_media.as_ref().is_some_and(|m| !m.is_empty());
    // Artwork, 74 px, radius 10.
    let art = R::new(c.x, c.cy() - 37.0, 74.0, 74.0);
    art_tile(d, md, art, 10.0, 26.0);
    // Controls column: 112 px on the right.
    let ctrl_cx = c.right() - 56.0;
    let mut ctrl_cy = c.cy();
    if both {
        source_chips(d, u, ctrl_cx, c.cy() - 24.0, is_pc);
        ctrl_cy = c.cy() + 14.0;
    }
    let tx = art.right() + 12.0;
    let tw = (c.right() - 112.0 - 12.0) - tx;
    d.text_fit(&md.title, tx, c.cy() - 28.0, tw, 13.0, Weight::Bold, p.t1, 1.0);
    d.text_fit(&md.artist, tx, c.cy() - 10.0, tw, 12.0, Weight::Regular, p.t2, 1.0);
    if md.duration_ms > 0 {
        let pos = md.position_now();
        d.bar(R::new(tx, c.cy() + 10.0, tw, 4.0), pos as f32 / md.duration_ms as f32, p.accent);
        d.text(&fmt_time(pos), tx, c.cy() + 26.0, 11.0, Weight::Regular, p.t3, 1.0);
        d.text_right(&fmt_time(md.duration_ms), tx + tw, c.cy() + 26.0, 11.0, Weight::Regular, p.t3, 1.0);
    }
    transport(d, (ctrl_cx, ctrl_cy), is_pc, md.playing, (32.0, 40.0, 13.0, 16.0));
    d.add(r, Act::Go(Page::Player));
}

fn source_chips(d: &mut Draw, u: &Ui, cx: f32, cy: f32, is_pc: bool) {
    let _ = u;
    let p = d.pal;
    let cont = R::new(cx - 34.0, cy - 13.0, 68.0, 26.0);
    let a = p.control();
    d.overlay(cont, 13.0, a);
    for (i, (ic, pc)) in [(Icon::Phone, false), (Icon::Open, true)].into_iter().enumerate() {
        let chip = R::new(cont.x + 2.0 + i as f32 * 32.0, cont.y + 2.0, 32.0, 22.0);
        let on = pc == is_pc;
        if on {
            let a = p.control_pressed();
            d.overlay(chip, 11.0, a);
            let fg = p.fg;
            d.ring(chip, 11.0, fg, p.stroke(), 1.0);
        } else if d.hot(chip) {
            let a = p.control_hover();
            d.overlay(chip, 11.0, a);
        }
        d.glyph(if pc { Icon::Music } else { ic }, chip.cx(), chip.cy(), 12.0, p.t1, if on { 1.0 } else { 0.5 });
        d.add(chip, Act::Source);
    }
}

fn transport(d: &mut Draw, c: (f32, f32), is_pc: bool, playing: bool, sizes: (f32, f32, f32, f32)) {
    let (side, mid, gs, gm) = sizes;
    let gap = 2.0;
    let (prev, toggle, next) = if is_pc { (Act::PcMedia("prev"), Act::PcMedia("toggle"), Act::PcMedia("next")) } else { (Act::PhoneMedia("prev"), Act::PhoneMedia("toggle"), Act::PhoneMedia("next")) };
    let (t1, acc, on) = (d.pal.t1, d.pal.accent, d.pal.on_accent);
    let total = side * 2.0 + mid + gap * 2.0 + if mid > 50.0 { 12.0 } else { 0.0 };
    let off = (mid + side) / 2.0 + gap + if mid > 50.0 { 6.0 } else { 0.0 };
    let _ = total;
    d.round((c.0 - off, c.1), side, Icon::Prev, prev, None, t1, gs);
    d.round((c.0, c.1), mid, if playing { Icon::Pause } else { Icon::Play }, toggle, Some(acc), on, gm);
    d.round((c.0 + off, c.1), side, Icon::Next, next, None, t1, gs);
}

fn art_tile(d: &mut Draw, md: &Media, r: R, rad: f32, glyph: f32) {
    let p = d.pal;
    let a = p.control_hover();
    d.overlay(r, rad, a);
    match &md.art {
        Some(img) => d.cv.image(img, r, rad, 1.0, None),
        None => d.glyph(Icon::Music, r.cx(), r.cy(), glyph, p.t3, 1.0),
    }
    let fg = p.fg;
    d.ring(r, rad, fg, p.stroke(), 1.0);
}

fn phone_card(d: &mut Draw, u: &Ui, r: R) {
    let c = d.card(r, t("Teléfono", "Phone"), None, None);
    let p = d.pal;
    let m = u.model;
    match m.target() {
        Some(ph) => {
            let multi = m.phones().len() > 1;
            d.text_fit(&ph.name, c.x, c.y + 8.0, c.w, 13.0, Weight::Bold, p.t1, 1.0);
            let sub = if multi { t("Conectado · toca para cambiar", "Connected · tap to switch") } else { t("Conectado", "Connected") };
            d.text_fit(sub, c.x, c.y + 26.0, c.w, 11.0, Weight::Regular, p.t3, 1.0);
            if let Some(i) = m.info.get(&ph.id).filter(|i| i.battery >= 0) {
                d.text(t("Batería", "Battery"), c.x, c.y + 52.0, 11.0, Weight::Regular, p.t2, 1.0);
                let col = if i.charging { p.success } else if i.battery < 20 { p.danger } else { p.t1 };
                d.text_right(&format!("{}%", i.battery), c.right(), c.y + 52.0, 12.0, Weight::Bold, col, 1.0);
                d.bar(R::new(c.x, c.y + 62.0, c.w, 5.0), i.battery.clamp(0, 100) as f32 / 100.0, if i.charging { p.success } else if i.battery < 20 { p.danger } else { p.accent });
                if i.charging {
                    d.text(t("Cargando", "Charging"), c.x, c.y + 80.0, 11.0, Weight::Regular, p.success, 1.0);
                }
            }
        }
        None => {
            d.text_fit(t("Sin teléfono conectado", "No phone connected"), c.x, c.y + 8.0, c.w, 13.0, Weight::Bold, p.t1, 1.0);
            d.text_fit(t("Abre Alero para vincular uno", "Open Alero to pair one"), c.x, c.y + 26.0, c.w, 11.0, Weight::Regular, p.t3, 1.0);
        }
    }
    d.add(r, Act::Device);
}

fn notifs_card(d: &mut Draw, u: &Ui, r: R) {
    let unread = u.model.unread(u.seen);
    let c = d.card(r, t("Notificaciones", "Notifications"), None, Some(unread));
    let p = d.pal;
    if u.model.notifs.is_empty() {
        d.glyph(Icon::Bell, c.cx(), c.cy() - 8.0, 20.0, p.t3, 1.0);
        d.text_center(t("Sin notificaciones", "No notifications"), c.cx(), c.cy() + 14.0, 12.0, Weight::Regular, p.t2, 1.0);
    }
    for (i, n) in u.model.notifs.iter().take(2).enumerate() {
        let y = c.y + 2.0 + i as f32 * 41.0;
        let tile = R::new(c.x, y + 4.0, 28.0, 28.0);
        match u.model.icon(&n.pkg) {
            Some(img) => d.cv.image(img, tile, 6.0, 1.0, None),
            None => {
                d.rr(tile, 6.0, p.accent, 0.22);
                let ch = n.app.chars().next().map(|c| c.to_uppercase().to_string()).unwrap_or_else(|| "?".into());
                d.text_center(&ch, tile.cx(), tile.cy(), 12.0, Weight::Bold, p.accent, 1.0);
            }
        }
        let title = if n.title.is_empty() { n.app.clone() } else { n.title.clone() };
        d.text_fit(&title, c.x + 36.0, y + 11.0, c.w - 36.0, 12.0, Weight::Medium, p.t1, 1.0);
        d.text_fit(&n.text.replace('\n', " "), c.x + 36.0, y + 27.0, c.w - 36.0, 11.0, Weight::Regular, p.t2, 1.0);
    }
    d.add(r, Act::Go(Page::Notifs));
}

fn clip_card(d: &mut Draw, u: &Ui, r: R) {
    let c = d.card(r, t("Portapapeles", "Clipboard"), None, None);
    let p = d.pal;
    let m = u.model;
    for (i, clip) in m.clips.iter().take(2).enumerate() {
        let row = R::new(c.x, c.y + i as f32 * 28.0, c.w, 24.0);
        let a = if d.hot(row) { p.control_hover() } else { p.control() };
        d.overlay(row, 8.0, a);
        let done = u.copied.is_some_and(|(k, _)| k == i);
        d.glyph(if done { Icon::Check } else { Icon::Copy }, row.x + 13.0, row.cy(), 12.0, if done { p.success } else { p.t2 }, 1.0);
        d.text_fit(&clip.text.replace('\n', " "), row.x + 26.0, row.cy(), row.w - 34.0, 11.0, Weight::Regular, p.t1, 1.0);
        d.add(row, Act::CopyClip(i));
    }
    if m.clips.is_empty() {
        d.text_center(t("Lo que copies en el teléfono", "What you copy on the phone"), c.cx(), c.y + 12.0, 11.0, Weight::Regular, p.t3, 1.0);
        d.text_center(t("aparece aquí", "shows up here"), c.cx(), c.y + 27.0, 11.0, Weight::Regular, p.t3, 1.0);
    }
    let sent = u.copied.is_some_and(|(k, _)| k == usize::MAX);
    let b = R::new(c.x, c.bottom() - 26.0, c.w, 26.0);
    if m.target().is_some() {
        d.button(b, if sent { t("Enviado", "Sent") } else { t("Enviar mi portapapeles", "Send my clipboard") }, Act::SendClip, true);
    } else {
        d.button(b, t("Sin teléfono", "No phone"), Act::OpenApp, false);
    }
    d.add(r, Act::Go(Page::Clipboard));
}

fn quick_card(d: &mut Draw, u: &Ui, r: R) {
    let c = d.card(r, t("Controles", "Controls"), None, None);
    let p = d.pal;
    let Some(id) = u.model.target_id() else {
        d.text_center(t("Sin teléfono conectado", "No phone connected"), c.cx(), c.cy(), 12.0, Weight::Regular, p.t2, 1.0);
        d.add(r, Act::Go(Page::Controls));
        return;
    };
    let st = u.model.phone.get(&id).cloned().unwrap_or_default();
    let tiles = [(Icon::Moon, st.dnd, Act::Toggle("dnd")), (Icon::Torch, st.torch, Act::Toggle("torch")), (Icon::Find, st.finding, Act::Toggle("find"))];
    let w = (c.w - 2.0 * 8.0) / 3.0;
    for (i, (ic, on, act)) in tiles.into_iter().enumerate() {
        let b = R::new(c.x + i as f32 * (w + 8.0), c.y, w, 44.0);
        let (hot, down) = (d.hot(b), d.is_down(b));
        if on {
            d.rr(b, 12.0, p.accent, if down { 0.45 } else if hot { 0.34 } else { 0.26 });
        } else {
            let a = if down { p.control_pressed() } else if hot { p.control_hover() } else { p.control() };
            d.overlay(b, 12.0, a);
        }
        d.glyph(ic, b.cx(), b.cy(), 18.0, if on { p.accent } else { p.t1 }, 1.0);
        d.add(b, act);
    }
    volume_slider(d, R::new(c.x, c.bottom() - 18.0, c.w, 18.0), &st);
    d.add(r, Act::Go(Page::Controls));
}

fn volume_slider(d: &mut Draw, r: R, st: &super::model::PhoneSt) {
    let p = d.pal;
    let f = (st.media as f32 / st.media_max.max(1) as f32).clamp(0.0, 1.0);
    let track = R::new(r.x + 22.0, r.cy() - 2.0, r.w - 22.0, 4.0);
    d.glyph(Icon::Volume, r.x + 8.0, r.cy(), 14.0, p.t2, 1.0);
    d.bar(track, f, p.accent);
    let tx = track.x + (track.w * f).clamp(7.0, track.w - 7.0);
    let hot = d.hot(r.inflate(4.0));
    d.cv.circle(tx, track.cy(), 8.0, color(p.accent, 1.0), None);
    d.cv.circle(tx, track.cy(), 6.0, color(if hot { p.accent } else { p.t1 }, 1.0), None);
    d.add(R::new(track.x - 6.0, r.y - 4.0, track.w + 12.0, r.h + 8.0), Act::Volume);
}

// ---- Tabs ----------------------------------------------------------------------------------------------------

fn player_tab(d: &mut Draw, u: &Ui, body: R) {
    let p = d.pal;
    let Some((md, is_pc)) = pick_media(u.model, u.player_pc) else {
        d.glyph(Icon::Music, body.cx(), body.cy() - 14.0, 40.0, p.t3, 1.0);
        d.text_center(t("Nada en reproducción", "Nothing is playing"), body.cx(), body.cy() + 22.0, 14.0, Weight::Bold, p.t2, 1.0);
        d.text_center(t("Pon algo en este equipo o en el teléfono.", "Play something on this computer or the phone."), body.cx(), body.cy() + 42.0, 12.0, Weight::Regular, p.t3, 1.0);
        return;
    };
    let both = u.model.pc_media.as_ref().is_some_and(|m| !m.is_empty()) && u.model.phone_media.as_ref().is_some_and(|m| !m.is_empty());
    let inner = R::new(body.x + 19.0, body.y, body.w - 38.0, body.h - 8.0);
    let art = R::new(inner.x, inner.cy() - 110.0, 220.0, 220.0);
    art_tile(d, md, art, 16.0, 56.0);
    let x = art.right() + 32.0;
    let w = inner.right() - x;
    let top = inner.cy() - 100.0;
    // Source row, 32 high.
    let src = if is_pc { t("Este equipo", "This computer") } else { t("Teléfono", "Phone") };
    d.glyph(if is_pc { Icon::Music } else { Icon::Phone }, x + 7.0, top + 16.0, 13.0, p.t2, 1.0);
    let sw = d.text(src, x + 20.0, top + 16.0, 11.0, Weight::Regular, p.t2, 1.0);
    if !md.playing {
        d.text(t("  Pausado", "  Paused"), x + 20.0 + sw, top + 16.0, 11.0, Weight::Regular, p.t3, 1.0);
    }
    if both {
        source_chips(d, u, inner.right() - 34.0, top + 16.0, is_pc);
    }
    d.text_fit(&md.title, x, top + 56.0, w, 22.0, Weight::Bold, p.t1, 1.0);
    d.text_fit(&md.artist, x, top + 82.0, w, 14.0, Weight::Regular, p.t2, 1.0);
    if md.duration_ms > 0 {
        let pos = md.position_now();
        d.bar(R::new(x, top + 118.0, w, 4.0), pos as f32 / md.duration_ms as f32, p.accent);
        d.text(&fmt_time(pos), x, top + 136.0, 11.0, Weight::Regular, p.t2, 1.0);
        d.text_right(&fmt_time(md.duration_ms), x + w, top + 136.0, 11.0, Weight::Regular, p.t2, 1.0);
    }
    transport(d, (x + w / 2.0, top + 176.0), is_pc, md.playing, (44.0, 56.0, 18.0, 22.0));
}

fn tab_inner(body: R) -> R {
    R::new(body.x + 19.0, body.y + 2.0, body.w - 38.0, body.h - 2.0)
}

fn row_bg(d: &mut Draw, r: R) {
    let a = if d.hot(r) { d.pal.control_hover() } else { d.pal.control() };
    d.overlay(r, 8.0, a);
}

fn files_tab(d: &mut Draw, u: &Ui, body: R) {
    let p = d.pal;
    let inner = tab_inner(body);
    let zone = R::new(inner.x, inner.y + 4.0, inner.w, 74.0);
    d.rr(zone, 14.0, p.card, 1.0);
    d.ring(zone, 14.0, p.fg, p.stroke(), 1.0);
    d.rr(R::new(zone.x + 16.0, zone.cy() - 22.0, 44.0, 44.0), 12.0, p.accent, 0.22);
    d.glyph(Icon::Send, zone.x + 38.0, zone.cy(), 22.0, p.accent, 1.0);
    match u.model.target() {
        Some(ph) => {
            d.text(t("Arrastra archivos hasta la isla", "Drag files onto the island"), zone.x + 74.0, zone.cy() - 9.0, 13.0, Weight::Bold, p.t1, 1.0);
            let sub = format!("{} {}", t("Se envían a", "Sent to"), ph.name);
            d.text_fit(&sub, zone.x + 74.0, zone.cy() + 10.0, zone.w - 90.0, 11.0, Weight::Regular, p.t2, 1.0);
        }
        None => {
            d.text(t("Conecta un teléfono para enviar archivos", "Connect a phone to send files"), zone.x + 74.0, zone.cy(), 13.0, Weight::Bold, p.t2, 1.0);
        }
    }
    let mut y = zone.bottom() + 10.0;
    for x in u.model.xfers.iter().take(4) {
        xfer_row(d, x, R::new(inner.x, y, inner.w, 46.0));
        y += 50.0;
    }
    if u.model.xfers.is_empty() {
        d.text_center(t("Aquí verás lo que envías y recibes", "What you send and receive shows up here"), inner.cx(), y + 40.0, 12.0, Weight::Regular, p.t3, 1.0);
    }
}

fn xfer_row(d: &mut Draw, x: &super::model::Xfer, r: R) {
    let p = d.pal;
    row_bg(d, r);
    let (ic, col) = match (&x.state, x.incoming) {
        (XState::Done, _) => (Icon::Check, p.success),
        (XState::Failed(_), _) => (Icon::Close, p.danger),
        (_, true) => (Icon::Download, p.accent),
        _ => (Icon::Send, p.accent),
    };
    let tile = R::new(r.x + 10.0, r.cy() - 14.0, 28.0, 28.0);
    d.rr(tile, 6.0, col, 0.22);
    d.glyph(ic, tile.cx(), tile.cy(), 14.0, col, 1.0);
    let right = match &x.state {
        XState::Running => format!("{}%", (x.fraction() * 100.0) as u32),
        XState::Done => t("Listo", "Done").to_string(),
        XState::Failed(_) => t("Falló", "Failed").to_string(),
    };
    d.text_right(&right, r.right() - 12.0, r.y + 15.0, 11.0, Weight::Regular, p.t2, 1.0);
    d.text_fit(&x.name, r.x + 48.0, r.y + 15.0, r.w - 48.0 - 60.0, 12.0, Weight::Medium, p.t1, 1.0);
    d.bar(R::new(r.x + 48.0, r.y + 30.0, r.w - 48.0 - 12.0, 5.0), x.fraction(), col);
}

fn notifs_tab(d: &mut Draw, u: &Ui, body: R) {
    let p = d.pal;
    let inner = tab_inner(body);
    if u.model.notifs.is_empty() {
        d.glyph(Icon::Bell, body.cx(), body.cy() - 16.0, 30.0, p.t3, 1.0);
        d.text_center(t("Sin notificaciones", "No notifications"), body.cx(), body.cy() + 18.0, 14.0, Weight::Bold, p.t2, 1.0);
        d.text_center(t("Las del teléfono aparecerán aquí.", "The phone's will show up here."), body.cx(), body.cy() + 38.0, 12.0, Weight::Regular, p.t3, 1.0);
        return;
    }
    let mut y = inner.y + 4.0;
    for n in u.model.notifs.iter().take(5) {
        let r = R::new(inner.x, y, inner.w, 54.0);
        let hot = d.hot(r);
        row_bg(d, r);
        let tile = R::new(r.x + 10.0, r.y + 8.0, 28.0, 28.0);
        match u.model.icon(&n.pkg) {
            Some(img) => d.cv.image(img, tile, 6.0, 1.0, None),
            None => {
                d.rr(tile, 6.0, p.accent, 0.22);
                let ch = n.app.chars().next().map(|c| c.to_uppercase().to_string()).unwrap_or_else(|| "?".into());
                d.text_center(&ch, tile.cx(), tile.cy(), 13.0, Weight::Bold, p.accent, 1.0);
            }
        }
        let title = if n.title.is_empty() { n.app.clone() } else { n.title.clone() };
        let rw = r.w - 48.0 - 44.0;
        d.text_fit(&title, r.x + 48.0, r.y + 15.0, rw, 12.0, Weight::Medium, p.t1, 1.0);
        d.text_fit(&n.text.replace('\n', " "), r.x + 48.0, r.y + 32.0, rw, 12.0, Weight::Regular, p.t2, 1.0);
        let meta = format!("{} · {}", n.app, ago(n.at));
        d.text_fit(&meta, r.x + 48.0, r.y + 46.5, rw, 10.5, Weight::Regular, p.t3, 1.0);
        d.add(R::new(r.x, r.y, r.w - 40.0, r.h), Act::OpenApp);
        if hot {
            let b = R::new(r.right() - 36.0, r.cy() - 13.0, 26.0, 26.0);
            d.icon_btn(b, Icon::Close, Act::Dismiss(n.key.clone()), false);
        }
        y += 58.0;
    }
}

fn ago(at: Instant) -> String {
    let s = at.elapsed().as_secs();
    if s < 60 {
        t("ahora", "now").to_string()
    } else if s < 3600 {
        format!("{} min", s / 60)
    } else {
        format!("{} h", s / 3600)
    }
}

fn clipboard_tab(d: &mut Draw, u: &Ui, body: R) {
    let p = d.pal;
    let inner = tab_inner(body);
    d.text(t("Del teléfono", "From the phone"), inner.x + 2.0, inner.y + 18.0, 14.0, Weight::Bold, p.t1, 1.0);
    let sent = u.copied.is_some_and(|(k, _)| k == usize::MAX);
    let bw = 232.0;
    let b = R::new(inner.right() - bw, inner.y + 3.0, bw, 30.0);
    if u.model.target().is_some() {
        d.button(b, if sent { t("Enviado al teléfono", "Sent to the phone") } else { t("Enviar mi portapapeles al teléfono", "Send my clipboard to the phone") }, Act::SendClip, true);
    } else {
        d.button(b, t("Sin teléfono conectado", "No phone connected"), Act::OpenApp, false);
    }
    if u.model.clips.is_empty() {
        d.glyph(Icon::Clipboard, body.cx(), body.cy() + 4.0, 30.0, p.t3, 1.0);
        d.text_center(t("Lo que copies en el teléfono aparece aquí", "What you copy on the phone shows up here"), body.cx(), body.cy() + 38.0, 12.0, Weight::Regular, p.t3, 1.0);
        return;
    }
    let mut y = inner.y + 46.0;
    for (i, c) in u.model.clips.iter().take(5).enumerate() {
        let r = R::new(inner.x, y, inner.w, 42.0);
        let hot = d.hot(r);
        row_bg(d, r);
        let done = u.copied.is_some_and(|(k, _)| k == i);
        let link = c.text.starts_with("http://") || c.text.starts_with("https://");
        d.text_fit(&c.text.replace('\n', " "), r.x + 12.0, r.y + 15.0, r.w - 24.0 - 80.0, 12.0, Weight::Regular, if link { p.accent } else { p.t1 }, 1.0);
        d.text_fit(&c.from, r.x + 12.0, r.y + 31.0, r.w - 100.0, 10.5, Weight::Regular, p.t3, 1.0);
        if hot || done {
            d.glyph(if done { Icon::Check } else { Icon::Copy }, r.right() - 22.0, r.cy(), 14.0, if done { p.success } else { p.t2 }, 1.0);
        }
        d.add(r, Act::CopyClip(i));
        y += 46.0;
    }
}

fn controls_tab(d: &mut Draw, u: &Ui, body: R) {
    let p = d.pal;
    let inner = tab_inner(body);
    let Some(id) = u.model.target_id() else {
        d.glyph(Icon::Phone, body.cx(), body.cy() - 16.0, 30.0, p.t3, 1.0);
        d.text_center(t("Sin teléfono conectado", "No phone connected"), body.cx(), body.cy() + 18.0, 14.0, Weight::Bold, p.t2, 1.0);
        d.text_center(t("Conecta uno para controlarlo desde aquí.", "Connect one to control it from here."), body.cx(), body.cy() + 38.0, 12.0, Weight::Regular, p.t3, 1.0);
        return;
    };
    let st = u.model.phone.get(&id).cloned().unwrap_or_default();
    let ringer = match st.ringer.as_str() {
        "silent" => t("Silencio", "Silent"),
        "vibrate" => t("Vibrar", "Vibrate"),
        _ => t("Sonido", "Sound"),
    };
    let tiles: [(Icon, &str, &str, bool, Act); 4] = [
        (Icon::Moon, t("No molestar", "Do not disturb"), if st.dnd { t("Activado", "On") } else { t("Desactivado", "Off") }, st.dnd, Act::Toggle("dnd")),
        (Icon::Torch, t("Linterna", "Flashlight"), if st.torch { t("Encendida", "On") } else { t("Apagada", "Off") }, st.torch, Act::Toggle("torch")),
        (Icon::Find, t("Buscar teléfono", "Find phone"), if st.finding { t("Sonando", "Ringing") } else { t("Tocar para sonar", "Tap to ring") }, st.finding, Act::Toggle("find")),
        (Icon::Volume, t("Timbre", "Ringer"), ringer, st.ringer == "silent" || st.ringer == "vibrate", Act::Ringer),
    ];
    let w = (inner.w - 3.0 * 10.0) / 4.0;
    for (i, (ic, title, sub, on, act)) in tiles.into_iter().enumerate() {
        let r = R::new(inner.x + i as f32 * (w + 10.0), inner.y + 4.0, w, 104.0);
        let (hot, down) = (d.hot(r), d.is_down(r));
        let fill = if on { mix(p.card, p.accent, if down { 0.30 } else if hot { 0.24 } else { 0.18 }) } else if hot || down { p.card_hover } else { p.card };
        d.rr(r, 14.0, fill, 1.0);
        d.ring(r, 14.0, if on { p.accent } else { p.fg }, if on { 0.55 } else { p.stroke() }, 1.0);
        let tile = R::new(r.x + 14.0, r.y + 14.0, 36.0, 36.0);
        if on {
            d.rr(tile, 10.0, p.accent, 1.0);
        } else {
            let a = p.control_hover();
            d.overlay(tile, 10.0, a);
        }
        d.glyph(ic, tile.cx(), tile.cy(), 18.0, if on { p.on_accent } else { p.t1 }, 1.0);
        d.text_fit(title, r.x + 14.0, r.y + 68.0, r.w - 24.0, 12.0, Weight::Medium, p.t1, 1.0);
        d.text_fit(sub, r.x + 14.0, r.y + 85.0, r.w - 24.0, 11.0, Weight::Regular, if on { p.accent } else { p.t3 }, 1.0);
        d.add(r, act);
    }
    let r = R::new(inner.x, inner.y + 4.0 + 104.0 + 10.0, inner.w, 84.0);
    d.rr(r, 14.0, p.card, 1.0);
    d.ring(r, 14.0, p.fg, p.stroke(), 1.0);
    d.text(t("Volumen multimedia", "Media volume"), r.x + 14.0, r.y + 20.0, 11.0, Weight::Medium, p.t2, 1.0);
    d.text_right(&format!("{}%", (st.media as f32 / st.media_max.max(1) as f32 * 100.0).round() as i32), r.right() - 14.0, r.y + 20.0, 12.0, Weight::Bold, p.t1, 1.0);
    volume_slider(d, R::new(r.x + 14.0, r.y + 40.0, r.w - 28.0, 28.0), &st);
}

// ---- Compact screens -----------------------------------------------------------------------------------------

fn call(d: &mut Draw, u: &Ui, s: R) {
    let Some((_, c)) = u.model.call() else { return };
    let p = d.pal;
    let name = if c.name.is_empty() { t("Número desconocido", "Unknown number").to_string() } else { c.name.clone() };
    d.avatar((s.x + 22.0 + 22.0, s.cy()), 44.0, &name);
    let status = if c.ringing { t("Llamada entrante…", "Incoming call…") } else { t("En llamada", "On a call") };
    let tx = s.x + 22.0 + 56.0;
    d.text_fit(&name, tx, s.cy() - 9.0, s.w - 22.0 - 56.0 - 22.0 - 116.0, 14.0, Weight::Bold, p.t1, 1.0);
    d.text(status, tx, s.cy() + 10.0, 12.0, Weight::Regular, if c.ringing { p.accent } else { p.t2 }, 1.0);
    let y = s.cy();
    let white = [255, 255, 255];
    if c.ringing {
        d.round((s.right() - 22.0 - 72.0, y), 42.0, Icon::CallEnd, Act::Call("decline"), Some(p.danger), white, 18.0);
        if c.can_answer {
            d.round((s.right() - 22.0 - 21.0, y), 42.0, Icon::Call, Act::Call("answer"), Some(p.success), white, 18.0);
        }
    } else {
        d.round((s.right() - 22.0 - 21.0, y), 42.0, Icon::CallEnd, Act::Call("hangup"), Some(p.danger), white, 18.0);
    }
}

fn offer(d: &mut Draw, u: &Ui, s: R) {
    let Some(o) = u.model.offers.last() else { return };
    let p = d.pal;
    let tile = R::new(s.x + 22.0, s.y + 22.0, 40.0, 40.0);
    d.rr(tile, 10.0, p.accent, 0.22);
    d.glyph(Icon::File, tile.cx(), tile.cy(), 20.0, p.accent, 1.0);
    let tx = tile.right() + 12.0;
    let tw = s.right() - 22.0 - tx;
    let sub = format!("{} {}", o.peer_name, t("quiere enviarte un archivo", "wants to send you a file"));
    d.text_fit(&sub, tx, s.y + 30.0, tw, 11.0, Weight::Regular, p.t2, 1.0);
    d.text_fit(&o.name, tx, s.y + 48.0, tw, 14.0, Weight::Bold, p.t1, 1.0);
    d.text(&fmt_size(o.size), tx, s.y + 66.0, 11.0, Weight::Regular, p.t3, 1.0);
    let y = s.bottom() - 20.0 - 32.0;
    let half = (s.w - 44.0 - 10.0) / 2.0;
    d.button(R::new(s.x + 22.0, y, half, 32.0), t("Rechazar", "Decline"), Act::Decline(o.id.clone()), false);
    d.button(R::new(s.x + 22.0 + half + 10.0, y, half, 32.0), t("Aceptar", "Accept"), Act::Accept(o.id.clone()), true);
}

fn transfer(d: &mut Draw, u: &Ui, s: R, id: &str) {
    let Some(x) = u.model.xfers.iter().find(|x| x.id == id) else { return };
    let p = d.pal;
    let (ic, col) = match (&x.state, x.incoming) {
        (XState::Done, _) => (Icon::Check, p.success),
        (XState::Failed(_), _) => (Icon::Close, p.danger),
        (_, true) => (Icon::Download, p.accent),
        _ => (Icon::Send, p.accent),
    };
    let tile = R::new(s.x + 22.0, s.cy() - 20.0, 40.0, 40.0);
    d.rr(tile, 10.0, col, 0.22);
    d.glyph(ic, tile.cx(), tile.cy(), 20.0, col, 1.0);
    let tx = tile.right() + 12.0;
    let tw = s.right() - 22.0 - 34.0 - tx;
    d.text_fit(&x.name, tx, s.cy() - 16.0, tw, 13.0, Weight::Bold, p.t1, 1.0);
    let line = match &x.state {
        XState::Running => {
            let verb = if x.incoming { t("Recibiendo", "Receiving") } else { t("Enviando", "Sending") };
            if x.rate > 0 { format!("{verb} · {}/s", fmt_size(x.rate)) } else { verb.to_string() }
        }
        XState::Done => if x.incoming { t("Archivo recibido", "File received").into() } else { t("Enviado al teléfono", "Sent to the phone").into() },
        XState::Failed(msg) => if msg.is_empty() { t("No se pudo completar", "Could not finish").to_string() } else { msg.clone() },
    };
    d.text_fit(&line, tx, s.cy() + 1.0, tw, 11.0, Weight::Regular, p.t2, 1.0);
    d.bar(R::new(tx, s.cy() + 16.0, tw, 5.0), x.fraction(), col);
    if x.state == XState::Running {
        d.icon_btn(R::new(s.right() - 22.0 - 30.0, s.cy() - 15.0, 30.0, 30.0), Icon::Close, Act::Cancel(x.id.clone()), false);
    }
}

fn note(d: &mut Draw, u: &Ui, s: R) {
    let p = d.pal;
    let n = u.note;
    let tile = R::new(s.x + 22.0, s.cy() - 19.0, 38.0, 38.0);
    let col = if n.good { p.success } else { p.accent };
    d.rr(tile, 10.0, col, 0.22);
    if let Some(ic) = n.icon {
        d.glyph(ic, tile.cx(), tile.cy(), 18.0, col, 1.0);
    }
    let tx = tile.right() + 12.0;
    let tw = s.right() - 22.0 - tx;
    d.text_fit(&n.title, tx, s.cy() - 8.0, tw, 13.0, Weight::Bold, p.t1, 1.0);
    d.text_fit(&n.text, tx, s.cy() + 10.0, tw, 12.0, Weight::Regular, p.t2, 1.0);
}

/// The drop screen of QNotch: a title, a hint, and tiles that say where the files go.
fn drop_screen(d: &mut Draw, u: &Ui, s: R) {
    let p = d.pal;
    d.text(t("Soltar archivos", "Drop files"), s.x + 22.0, s.y + 28.0, 15.0, Weight::Bold, p.t1, 1.0);
    d.text(t("Elige adónde van", "Choose where they go"), s.x + 22.0, s.y + 47.0, 11.0, Weight::Regular, p.t3, 1.0);
    match u.model.target() {
        Some(ph) => {
            let tile = R::new(s.x + 22.0, s.y + 66.0, 190.0, 68.0);
            let a = p.control();
            d.overlay(tile, 9.0, a);
            let on = u.drag_over;
            d.ring(tile, 9.0, if on { p.accent } else { p.fg }, if on { 1.0 } else { 0.0 }, 1.5);
            d.glyph(Icon::Phone, tile.x + 22.0, tile.y + 22.0, 20.0, p.t1, 1.0);
            d.text_fit(&ph.name, tile.x + 12.0, tile.y + 43.0, tile.w - 24.0, 12.0, Weight::Bold, p.t1, 1.0);
            d.text_fit(t("Enviar al teléfono", "Send to the phone"), tile.x + 12.0, tile.y + 58.0, tile.w - 24.0, 11.0, Weight::Regular, p.t2, 1.0);
        }
        None => {
            d.text_center(t("Nada puede recibir estos archivos ahora mismo.", "Nothing can take these files right now."), s.cx(), s.y + 100.0, 12.0, Weight::Regular, p.t3, 1.0);
        }
    }
}
