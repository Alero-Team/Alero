//! The island itself: what it shows, how it opens and closes, and how it moves.
//!
//! The look is QNotch's: a pill hanging from the top edge that grows into a 720 × 380 panel (see `view`), with its
//! timing (see `motion`). Nothing here touches the operating system. A host (Windows or X11) feeds it the pointer,
//! the engine's events and the passing of time, asks for a frame, and executes the commands it returns. That keeps
//! the whole behaviour testable and the platform code small.

use std::path::PathBuf;
use std::time::Instant;

use serde_json::{json, Value};
use tiny_skia::Pixmap;

use super::config::IslandConfig;
use super::gfx::{color, Canvas, Fonts, Icon, R};
use super::model::{Model, Notice};
use super::motion::{Anim, Ease, Motion, Style};
use super::view::{self, Draw, Ui, PILL_H, PILL_R};
use crate::lang::t;

/// Logical size of the drawing surface (the window is this big times the scale): QNotch's window, 760 × 430.
pub const CANVAS_W: f32 = 760.0;
pub const CANVAS_H: f32 = 430.0;
const OPEN_MS: f32 = 240.0;
const CLOSE_MS: f32 = 180.0;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Page {
    Home,
    Player,
    Files,
    Notifs,
    Clipboard,
    Controls,
}

#[derive(Clone, PartialEq, Debug)]
pub enum View {
    Page(Page),
    Call,
    Offer,
    Transfer(String),
    Note,
    Drop,
}

impl View {
    fn rank(&self) -> u8 {
        match self {
            View::Call => 5,
            View::Offer => 4,
            View::Drop => 3,
            View::Transfer(_) | View::Note => 2,
            View::Page(_) => 1,
        }
    }
}

/// Where a click lands. Some carry the value to apply.
#[derive(Clone, Debug, PartialEq)]
pub enum Act {
    Go(Page),
    OpenApp,
    Pin,
    PcMedia(&'static str),
    PhoneMedia(&'static str),
    Source,
    Accept(String),
    Decline(String),
    Cancel(String),
    Call(&'static str),
    Toggle(&'static str),
    Ringer,
    Volume,
    CopyClip(usize),
    SendClip,
    Dismiss(String),
    Device,
}

/// What the host has to carry out (the island has no engine of its own).
#[derive(Clone, Debug, PartialEq)]
pub enum Cmd {
    OpenApp,
    PcMedia(&'static str),
    PhoneMedia(&'static str),
    Respond { id: String, accept: bool },
    Cancel(String),
    CallAction(&'static str),
    Phone { what: &'static str, body: Value },
    CopyText(String),
    SendClipboard,
    SendFiles(Vec<PathBuf>),
    Beep,
}

#[derive(Clone, Copy, PartialEq, Debug)]
enum Reason {
    Hover,
    /// Opened by an event: closes after this many seconds unless the pointer is on it. None: stays until resolved.
    Event(Option<f32>),
    Drag,
    Key,
}

/// A line of text with an icon, shown by [`View::Note`].
#[derive(Clone, Debug, Default)]
pub struct Note {
    pub icon: Option<Icon>,
    pub title: String,
    pub text: String,
    pub good: bool,
}

/// What the pill says in place of its usual segments for a few seconds (QNotch's "peek").
#[derive(Clone, Debug)]
pub struct Peek {
    pub icon: Icon,
    pub text: String,
    pub good: bool,
    left: f32,
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct LocalTime {
    pub hour: u32,
    pub min: u32,
    /// 0 = Sunday.
    pub wday: u32,
    pub month: u32,
    pub day: u32,
}

pub struct Hit {
    pub r: R,
    pub act: Act,
}

#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Drag {
    Enter,
    Over,
    Leave,
}

pub struct Status {
    pub visible: bool,
    pub animating: bool,
}

pub struct Island {
    pub cfg: IslandConfig,
    pub model: Model,
    motion: Motion,
    fonts: Fonts,
    open: bool,
    reason: Reason,
    view: View,
    /// The tab the panel opens on (the last one used).
    page: Page,
    /// 0 = the pill, 1 = the panel (overshoots a little while opening).
    o: Anim,
    /// Size morph between two views of different sizes.
    vs: Anim,
    size_from: (f32, f32, f32),
    size_to: (f32, f32, f32),
    /// Hidden mode: 0 = above the screen's edge, 1 = in place.
    reveal: Anim,
    hide_wait: f32,
    pill_w: Anim,
    pill_check: f32,
    tab_x: Anim,
    fade: Anim,
    peek: Option<Peek>,
    peek_fade: Anim,
    note: Note,
    pointer: Option<(f32, f32)>,
    pressed: Option<usize>,
    hits: Vec<Hit>,
    hot: bool,
    hot_for: f32,
    away_for: f32,
    armed_for: f32,
    drag_active: bool,
    drag_over: bool,
    life: f32,
    last_slider: f32,
    copied: Option<(usize, f32)>,
    player_pc: Option<bool>,
    seen_notifs: Instant,
    cmds: Vec<Cmd>,
    dirty: bool,
    layer: Option<Canvas>,
    body_layer: Option<Canvas>,
    clock: f32,
    reduce_motion: bool,
    suppressed: bool,
    pinned: bool,
    time: LocalTime,
}

impl Island {
    pub fn new(cfg: IslandConfig) -> Self {
        let motion = Motion::new(Style::parse(&cfg.animation));
        let size = view::view_size(&View::Page(Page::Home));
        let always = cfg.always_visible;
        let mut me = Self {
            cfg,
            model: Model::default(),
            motion,
            fonts: Fonts::new(),
            open: false,
            reason: Reason::Hover,
            view: View::Page(Page::Home),
            page: Page::Home,
            o: Anim::new(0.0),
            vs: Anim::new(1.0),
            size_from: size,
            size_to: size,
            reveal: Anim::new(if always { 1.0 } else { 0.0 }),
            hide_wait: 0.0,
            pill_w: Anim::new(96.0),
            pill_check: 0.0,
            tab_x: Anim::new(0.0),
            fade: Anim::new(1.0),
            peek: None,
            peek_fade: Anim::new(1.0),
            note: Note::default(),
            pointer: None,
            pressed: None,
            hits: Vec::new(),
            hot: false,
            hot_for: 0.0,
            away_for: 0.0,
            armed_for: 0.0,
            drag_active: false,
            drag_over: false,
            life: 0.0,
            last_slider: 0.0,
            copied: None,
            player_pc: None,
            seen_notifs: Instant::now(),
            cmds: Vec::new(),
            dirty: true,
            layer: None,
            body_layer: None,
            clock: 0.0,
            reduce_motion: false,
            suppressed: false,
            pinned: false,
            time: LocalTime::default(),
        };
        me.retune_motion();
        me.remeasure(true);
        me.pill_w.snap(me.pill_target());
        me
    }

    pub fn set_config(&mut self, cfg: IslandConfig) {
        self.cfg = cfg;
        self.retune_motion();
        if !self.cfg.enabled {
            self.snap_closed();
        }
        if self.cfg.always_visible {
            self.reveal.snap(1.0);
        }
        if !self.page_allowed(self.page) {
            self.page = Page::Home;
        }
        if let View::Page(p) = self.view {
            if !self.page_allowed(p) {
                self.view = View::Page(Page::Home);
            }
        }
        self.remeasure(true);
        self.dirty = true;
    }

    /// The system asks for less motion (Windows: animations off): everything jumps.
    pub fn set_reduce_motion(&mut self, on: bool) {
        if self.reduce_motion != on {
            self.reduce_motion = on;
            self.retune_motion();
        }
    }

    fn retune_motion(&mut self) {
        let style = if self.reduce_motion && self.cfg.respect_reduce_motion { Style::Off } else { Style::parse(&self.cfg.animation) };
        self.motion = Motion::new(style);
    }

    /// An application covers the screen (a game, a video): the island steps aside.
    pub fn set_suppressed(&mut self, on: bool) {
        if self.suppressed != on {
            self.suppressed = on;
            if on {
                self.reveal.snap(0.0);
            } else if self.cfg.always_visible {
                self.reveal.snap(1.0);
            }
            self.dirty = true;
        }
    }

    pub fn set_time(&mut self, t: LocalTime) {
        if self.time != t {
            self.time = t;
            self.pill_check = 0.0;
            self.dirty = true;
        }
    }

    pub fn is_open(&self) -> bool {
        self.open || self.o.v > 0.002
    }

    /// Is anything of the island on screen (the pill included)?
    pub fn visible(&self) -> bool {
        self.cfg.enabled && !self.suppressed && (self.cfg.always_visible || self.reveal.v > 0.002 || self.is_open() || self.peek.is_some())
    }

    pub fn take_cmds(&mut self) -> Vec<Cmd> {
        std::mem::take(&mut self.cmds)
    }

    /// Wants the media polled (the player is on screen, or the pill shows what plays).
    pub fn wants_media(&self) -> bool {
        self.cfg.enabled && self.cfg.modules.player && self.visible()
    }

    fn page_allowed(&self, p: Page) -> bool {
        let m = &self.cfg.modules;
        match p {
            Page::Home => true,
            Page::Player => m.player,
            Page::Files => m.send || m.incoming,
            Page::Notifs => m.notifications,
            Page::Clipboard => m.clipboard,
            Page::Controls => m.controls,
        }
    }

    pub fn tabs(&self) -> Vec<(Icon, Page)> {
        let mut v = vec![(Icon::Home, Page::Home)];
        for (ic, p) in [(Icon::Music, Page::Player), (Icon::Send, Page::Files), (Icon::Bell, Page::Notifs), (Icon::Clipboard, Page::Clipboard), (Icon::Sliders, Page::Controls)] {
            if self.page_allowed(p) {
                v.push((ic, p));
            }
        }
        v
    }

    fn tab_index(&self, p: Page) -> usize {
        self.tabs().iter().position(|(_, q)| *q == p).unwrap_or(0)
    }

    // ------------------------------------------------------------------------------------------------ input

    /// Pointer in canvas logical units, or None when it is somewhere else.
    pub fn set_pointer(&mut self, p: Option<(f32, f32)>) {
        if self.pointer != p {
            self.pointer = p;
            self.dirty = true;
        }
    }

    /// `hot`: the pointer is in the trigger zone. `button`: the left button is held (a file may be on its way).
    pub fn set_zone(&mut self, hot: bool, button: bool, dt: f32) {
        self.hot = hot && self.cfg.enabled;
        // A button held in the zone may be a file being carried: show the drop target after a moment.
        if self.hot && button && !self.open && self.cfg.modules.send {
            self.armed_for += dt;
            if self.armed_for >= 0.22 {
                self.armed_for = 0.0;
                self.open(View::Drop, Reason::Drag);
                self.life = 1.6;
            }
        } else if !(self.hot && button) {
            self.armed_for = 0.0;
        }
    }

    pub fn drag(&mut self, d: Drag) {
        if !self.cfg.enabled || !self.cfg.modules.send {
            return;
        }
        match d {
            Drag::Enter | Drag::Over => {
                self.drag_active = true;
                self.drag_over = true;
                self.life = 1.6;
                if !self.open || self.view != View::Drop {
                    self.open(View::Drop, Reason::Drag);
                }
            }
            Drag::Leave => {
                self.drag_over = false;
                self.life = 0.7;
            }
        }
        self.dirty = true;
    }

    pub fn dropped(&mut self, files: Vec<PathBuf>) {
        self.drag_active = false;
        self.drag_over = false;
        if files.is_empty() {
            return;
        }
        if self.model.target().is_none() {
            self.show_note(Note { icon: Some(Icon::Phone), title: t("Sin teléfono conectado", "No phone connected").into(), text: t("Conecta un teléfono para enviar archivos.", "Connect a phone to send files.").into(), good: false });
            return;
        }
        self.cmds.push(Cmd::SendFiles(files));
        self.life = 2.0;
    }

    pub fn hotkey(&mut self) {
        if self.open {
            self.close();
        } else if self.cfg.enabled {
            self.open(View::Page(self.page), Reason::Key);
            self.life = 6.0;
        }
    }

    pub fn press(&mut self) {
        let Some((x, y)) = self.pointer else { return };
        self.pressed = self.hits.iter().position(|h| h.r.contains(x, y));
        if let Some(i) = self.pressed {
            if self.hits[i].act == Act::Volume {
                self.slide(i, x, true);
            }
        }
        self.dirty = true;
    }

    pub fn moved(&mut self) {
        if let (Some(i), Some((x, _))) = (self.pressed, self.pointer) {
            if self.hits.get(i).is_some_and(|h| h.act == Act::Volume) {
                self.slide(i, x, false);
            }
        }
    }

    fn slide(&mut self, i: usize, x: f32, first: bool) {
        // The phone is asked at most ~15 times a second while dragging.
        if !first && self.clock - self.last_slider < 0.066 {
            return;
        }
        self.last_slider = self.clock;
        let r = self.hits[i].r;
        let v = ((x - r.x) / r.w).clamp(0.0, 1.0);
        let max = self.model.target_id().and_then(|id| self.model.phone.get(&id)).map_or(15, |p| p.media_max);
        let value = (v * max as f32).round() as i32;
        self.cmds.push(Cmd::Phone { what: "volume", body: json!({"stream": "media", "value": value}) });
        if let Some(id) = self.model.target_id() {
            if let Some(p) = self.model.phone.get_mut(&id) {
                p.media = value;
            }
        }
        self.dirty = true;
    }

    pub fn release(&mut self) {
        let down = self.pressed.take();
        let Some((x, y)) = self.pointer else { return };
        let Some(i) = down else { return };
        if self.hits.get(i).is_some_and(|h| h.r.contains(x, y)) {
            let act = self.hits[i].act.clone();
            self.act(act);
        }
        self.dirty = true;
    }

    pub fn wheel(&mut self, notches: f32) {
        // Over the volume slider the wheel changes the phone's media volume.
        let Some((x, y)) = self.pointer else { return };
        if self.hits.iter().any(|h| h.act == Act::Volume && h.r.inflate(8.0).contains(x, y)) {
            if let Some(id) = self.model.target_id() {
                let (cur, max) = self.model.phone.get(&id).map_or((0, 15), |p| (p.media, p.media_max));
                let value = (cur + notches.signum() as i32).clamp(0, max);
                self.cmds.push(Cmd::Phone { what: "volume", body: json!({"stream": "media", "value": value}) });
                if let Some(p) = self.model.phone.get_mut(&id) {
                    p.media = value;
                }
                self.dirty = true;
            }
        }
    }

    fn act(&mut self, a: Act) {
        match a {
            Act::Go(p) => {
                if p == Page::Notifs {
                    self.seen_notifs = Instant::now();
                }
                self.page = p;
                if self.open {
                    self.go(View::Page(p));
                }
            }
            Act::OpenApp => {
                self.cmds.push(Cmd::OpenApp);
                self.close();
            }
            Act::Pin => self.pinned = !self.pinned,
            Act::PcMedia(k) => self.cmds.push(Cmd::PcMedia(k)),
            Act::PhoneMedia(k) => self.cmds.push(Cmd::PhoneMedia(k)),
            Act::Source => self.player_pc = Some(!view::pick_pc(&self.model, self.player_pc)),
            Act::Accept(id) => self.cmds.push(Cmd::Respond { id, accept: true }),
            Act::Decline(id) => {
                self.cmds.push(Cmd::Respond { id, accept: false });
                self.close();
            }
            Act::Cancel(id) => {
                self.cmds.push(Cmd::Cancel(id));
                self.close();
            }
            Act::Call(k) => self.cmds.push(Cmd::CallAction(k)),
            Act::Toggle(what) => {
                let id = self.model.target_id().unwrap_or_default();
                let cur = self.model.phone.get(&id).map(|p| match what {
                    "dnd" => p.dnd,
                    "torch" => p.torch,
                    _ => p.finding,
                });
                let on = !cur.unwrap_or(false);
                self.cmds.push(Cmd::Phone { what, body: json!({"on": on}) });
                if let Some(p) = self.model.phone.get_mut(&id) {
                    match what {
                        "dnd" => p.dnd = on,
                        "torch" => p.torch = on,
                        _ => p.finding = on,
                    }
                }
            }
            Act::Ringer => {
                let id = self.model.target_id().unwrap_or_default();
                let cur = self.model.phone.get(&id).map_or("normal".to_string(), |p| p.ringer.clone());
                let next = match cur.as_str() {
                    "normal" => "vibrate",
                    "vibrate" => "silent",
                    _ => "normal",
                };
                self.cmds.push(Cmd::Phone { what: "ringer", body: json!({"mode": next}) });
                if let Some(p) = self.model.phone.get_mut(&id) {
                    p.ringer = next.into();
                }
            }
            Act::Volume => {}
            Act::CopyClip(i) => {
                if let Some(c) = self.model.clips.get(i) {
                    self.cmds.push(Cmd::CopyText(c.text.clone()));
                    self.copied = Some((i, 1.3));
                }
            }
            Act::SendClip => {
                self.cmds.push(Cmd::SendClipboard);
                self.copied = Some((usize::MAX, 1.3));
            }
            Act::Dismiss(key) => self.model.dismiss_notif(&key),
            Act::Device => self.model.cycle_target(),
        }
        self.dirty = true;
    }

    // ------------------------------------------------------------------------------------------------ events

    /// What the engine reported: opens the island for what matters, when the user wants that.
    pub fn notices(&mut self, list: Vec<Notice>) {
        for n in list {
            let m = &self.cfg.modules;
            match n {
                Notice::Call if m.call => {
                    if self.model.call().is_some() {
                        self.open_event(View::Call, None);
                        if self.cfg.sound && self.model.call().is_some_and(|c| c.1.ringing) {
                            self.cmds.push(Cmd::Beep);
                        }
                    } else if self.view == View::Call {
                        // The call is over: let it go in a moment.
                        self.life = 1.2;
                        self.reason = Reason::Event(Some(1.2));
                    }
                }
                Notice::Offer(_) if m.incoming => {
                    self.open_event(View::Offer, None);
                    if self.cfg.sound {
                        self.cmds.push(Cmd::Beep);
                    }
                }
                Notice::XferStarted(id) if m.send || m.incoming => self.open_event(View::Transfer(id), None),
                Notice::XferDone(id, ok) => {
                    if self.view == View::Transfer(id) {
                        self.life = if ok { 2.4 } else { 4.0 };
                        self.reason = Reason::Event(Some(self.life));
                    }
                }
                Notice::Notif(key) if m.notifications => {
                    if let Some(n) = self.model.notifs.iter().find(|n| n.key == key) {
                        let text = if n.title.is_empty() { n.app.clone() } else { format!("{}: {}", n.app, n.title) };
                        self.peek(Icon::Bell, text, false, self.cfg.event_secs as f32);
                    }
                }
                Notice::Clip if m.clipboard => {
                    let from = self.model.clips.front().map(|c| c.from.clone()).unwrap_or_default();
                    let text = if from.is_empty() { t("Portapapeles recibido", "Clipboard received").to_string() } else { format!("{} · {}", t("Portapapeles recibido", "Clipboard received"), from) };
                    self.peek(Icon::Clipboard, text, true, 3.0);
                }
                _ => {}
            }
        }
        self.dirty = true;
    }

    /// One line in place of the pill's segments for a few seconds. Only while the panel is closed.
    pub fn peek(&mut self, icon: Icon, text: String, good: bool, secs: f32) {
        if !self.cfg.enabled || !self.cfg.auto_expand || self.suppressed || self.is_open() {
            return;
        }
        let first = self.peek.is_none();
        self.peek = Some(Peek { icon, text, good, left: secs.clamp(1.0, 10.0) });
        if first {
            self.peek_fade.snap(0.0);
            self.peek_fade.go(1.0, self.motion.ms(180.0), Ease::Cubic);
        }
        self.remeasure(true);
        self.dirty = true;
    }

    fn show_note(&mut self, note: Note) {
        self.show_note_for(note, 3.0)
    }

    fn show_note_for(&mut self, note: Note, secs: f32) {
        self.note = note;
        // A note never replaces something that asks for an answer.
        if self.open && self.view.rank() > View::Note.rank() {
            return;
        }
        self.open_event(View::Note, Some(secs));
    }

    fn open_event(&mut self, v: View, secs: Option<f32>) {
        if !self.cfg.enabled || !self.cfg.auto_expand && v != View::Note {
            return;
        }
        if self.open && self.view.rank() > v.rank() {
            return;
        }
        if self.open {
            self.go(v.clone());
            self.reason = Reason::Event(secs);
        } else {
            self.open(v.clone(), Reason::Event(secs));
        }
        self.life = secs.unwrap_or(0.0);
    }

    // ------------------------------------------------------------------------------------------------ state

    fn snap_closed(&mut self) {
        self.open = false;
        self.o.snap(0.0);
        self.vs.snap(1.0);
        self.fade.snap(1.0);
        self.peek = None;
        if !self.cfg.always_visible {
            self.reveal.snap(0.0);
        }
    }

    fn cur_size(&self) -> (f32, f32, f32) {
        let k = self.vs.v;
        let (a, b) = (self.size_from, self.size_to);
        (a.0 + (b.0 - a.0) * k, a.1 + (b.1 - a.1) * k, a.2 + (b.2 - a.2) * k)
    }

    fn open(&mut self, v: View, why: Reason) {
        if !self.cfg.enabled || self.suppressed {
            return;
        }
        if self.open {
            self.go(v);
            self.reason = why;
            return;
        }
        // Never reopen on a tab that is off now.
        let v = match v {
            View::Page(p) if !self.page_allowed(p) => View::Page(Page::Home),
            other => other,
        };
        self.peek = None;
        self.remeasure(true);
        self.open = true;
        self.reason = why;
        if let View::Page(p) = v {
            self.page = p;
        }
        self.view = v;
        self.size_from = view::view_size(&self.view);
        self.size_to = self.size_from;
        self.vs.snap(1.0);
        self.fade.snap(1.0);
        let idx = self.tab_index(self.page) as f32;
        self.tab_x.snap(view::tab_x(idx as usize));
        // QNotch: 240 ms times the distance still to go (at least 35 %), with a gentle overshoot.
        let ms = self.motion.ms(OPEN_MS) * (1.0 - self.o.v).abs().max(0.35);
        self.o.go(1.0, ms, Ease::Back(self.motion.bounce()));
        self.away_for = 0.0;
        self.hot_for = 0.0;
        self.dirty = true;
    }

    /// Replaces what is shown: the surface morphs to the new size and the new content fades in.
    fn go(&mut self, v: View) {
        if self.view == v {
            return;
        }
        let from = self.cur_size();
        let to = view::view_size(&v);
        self.size_from = from;
        self.size_to = to;
        self.vs.snap(0.0);
        self.vs.go(1.0, self.motion.ms(220.0), Ease::Cubic);
        if let View::Page(p) = v {
            let idx = self.tab_index(p);
            self.tab_x.go(view::tab_x(idx), self.motion.ms(220.0), Ease::Cubic);
            if p == Page::Notifs {
                self.seen_notifs = Instant::now();
            }
        }
        // QNotch: a tab's content fades in over 180 ms, rising 6 px.
        self.fade.snap(0.0);
        self.fade.go(1.0, self.motion.ms(180.0), Ease::Cubic);
        self.view = v;
        self.dirty = true;
    }

    pub fn close(&mut self) {
        if !self.open {
            return;
        }
        self.open = false;
        let ms = self.motion.ms(CLOSE_MS) * self.o.v.abs().max(0.35);
        self.o.go(0.0, ms, Ease::Cubic);
        self.drag_active = false;
        self.drag_over = false;
        self.hide_wait = 0.0;
        self.dirty = true;
    }

    /// Where the pill's width is heading.
    fn pill_target(&self) -> f32 {
        self.pill_w.target()
    }

    /// Measures the pill again; it grows at once and shrinks only when it would be a lot narrower (so a changing
    /// title does not make it twitch), unless `exact`.
    fn remeasure(&mut self, exact: bool) {
        let tabs = self.tabs();
        let u = Ui {
            model: &self.model,
            cfg: &self.cfg,
            view: &self.view,
            page: self.page,
            note: &self.note,
            tabs: &tabs,
            tab_x: 0.0,
            player_pc: self.player_pc,
            seen: self.seen_notifs,
            copied: None,
            drag_over: false,
            pinned: self.pinned,
            time: self.time,
            peek: self.peek.as_ref(),
            peek_fade: 1.0,
        };
        let w = view::pill_width(&mut self.fonts, &u, self.pill_w.target());
        let cur = self.pill_w.target();
        if exact && w != cur || w > cur || w < cur - 24.0 {
            if self.open || self.o.v > 0.002 {
                self.pill_w.snap(w);
            } else {
                self.pill_w.go(w, self.motion.ms(200.0), Ease::Cubic);
            }
        }
    }

    /// Where the surface is, in canvas units.
    fn surface(&self) -> (R, f32) {
        let o = self.o.v;
        let (sw, sh, sr) = self.cur_size();
        let w = (self.pill_w.v + (sw - self.pill_w.v) * o).clamp(8.0, CANVAS_W - 2.0);
        let h = (PILL_H + (sh - PILL_H) * o).clamp(8.0, CANVAS_H - 4.0);
        let r = (PILL_R + (sr - PILL_R) * o.clamp(0.0, 1.0)).max(0.0);
        let top = self.cfg.top_margin as f32;
        let y = top + (self.reveal.v - 1.0) * (PILL_H + top + 2.0);
        (R::new((CANVAS_W - w) / 2.0, y, w, h), r)
    }

    /// Is the pointer on the island (or in the trigger zone, which is where it came from)?
    fn pointer_near(&self) -> bool {
        if self.hot {
            return true;
        }
        let Some((x, y)) = self.pointer else { return false };
        let (s, _) = self.surface();
        let r = s.inflate(if self.open { 10.0 } else { 4.0 });
        r.contains(x, y) || (x >= r.x && x < r.right() && y < r.y)
    }

    // ------------------------------------------------------------------------------------------------ time

    pub fn update(&mut self, dt: f32) -> Status {
        self.clock += dt;
        let dt = dt.min(0.1);
        if let Some((i, left)) = self.copied {
            self.copied = if left - dt <= 0.0 { None } else { Some((i, left - dt)) };
            self.dirty = true;
        }
        if !self.cfg.enabled {
            self.snap_closed();
            return Status { visible: false, animating: false };
        }
        self.model.tidy(Instant::now());
        self.validate();
        let near = self.pointer_near();

        // Hover: a pill that is there (or has just come out) opens the panel after the dwell.
        if !self.open {
            let ready = self.cfg.always_visible || self.reveal.v > 0.6;
            if near && ready && !self.suppressed && !self.drag_active {
                self.hot_for += dt;
                if self.hot_for * 1000.0 >= self.cfg.open_delay_ms as f32 {
                    self.hot_for = 0.0;
                    self.open(View::Page(self.page), Reason::Hover);
                }
            } else if !near {
                self.hot_for = 0.0;
            }
        }

        // Closing rules.
        if self.open {
            match self.reason {
                Reason::Hover | Reason::Key => {
                    if near || self.pinned {
                        self.away_for = 0.0;
                    } else {
                        self.away_for += dt;
                        let limit = if self.reason == Reason::Key { 5.0 } else { self.cfg.close_delay_ms as f32 / 1000.0 };
                        if self.away_for >= limit {
                            self.close();
                        }
                    }
                }
                Reason::Event(secs) => {
                    if near {
                        // Looking at it: it stays, and from now on it behaves like a hover.
                        self.away_for = 0.0;
                        if matches!(self.view, View::Page(_) | View::Note) {
                            self.reason = Reason::Hover;
                        }
                    } else if secs.is_some() {
                        self.life -= dt;
                        if self.life <= 0.0 {
                            self.close();
                        }
                    }
                }
                Reason::Drag => {
                    if self.pressed.is_none() && !self.drag_over && !self.hot {
                        self.life -= dt;
                        if self.life <= 0.0 && self.view == View::Drop {
                            self.close();
                        }
                    }
                    if self.drag_over || near {
                        self.life = self.life.max(0.6);
                    }
                }
            }
        }

        // The pill's coming and going (hidden mode).
        let wants = !self.suppressed && (self.cfg.always_visible || self.hot || near || self.open || self.o.v > 0.002 || self.peek.is_some() || self.drag_active);
        if self.suppressed {
            self.reveal.snap(0.0);
        } else if self.cfg.always_visible {
            if self.reveal.target() != 1.0 {
                self.reveal.snap(1.0);
            }
        } else if wants {
            self.hide_wait = 0.0;
            if self.reveal.target() != 1.0 {
                self.reveal.go(1.0, self.motion.ms(200.0), Ease::Cubic);
            }
        } else {
            self.hide_wait += dt;
            if self.hide_wait >= 0.7 && self.reveal.target() != 0.0 {
                self.reveal.go(0.0, self.motion.ms(180.0), Ease::Cubic);
            }
        }

        // A peek runs out.
        if let Some(p) = self.peek.as_mut() {
            p.left -= dt;
            if p.left <= 0.0 {
                self.peek = None;
                self.remeasure(true);
            }
            self.dirty = true;
        }
        // The pill follows its content (the clock, the title that is playing).
        self.pill_check -= dt;
        if self.pill_check <= 0.0 {
            self.pill_check = 0.5;
            if !self.is_open() {
                self.remeasure(false);
            }
        }

        let (a, b, c, d, e, f, g) = (self.o.running(), self.vs.running(), self.reveal.running(), self.pill_w.running(), self.tab_x.running(), self.fade.running(), self.peek_fade.running());
        let moving = a || b || c || d || e || f || g;
        self.o.step(dt);
        self.vs.step(dt);
        self.reveal.step(dt);
        self.pill_w.step(dt);
        self.tab_x.step(dt);
        self.fade.step(dt);
        self.peek_fade.step(dt);
        if moving {
            self.dirty = true;
        }
        if !self.open && self.o.v <= 0.002 && self.o.v != 0.0 {
            self.o.snap(0.0);
        }
        // The clock of the player and the progress bars.
        if self.open && matches!(self.view, View::Page(Page::Player) | View::Page(Page::Home) | View::Page(Page::Files) | View::Transfer(_)) && self.clock.fract() < dt {
            self.dirty = true;
        }
        Status { visible: self.visible(), animating: moving || self.dirty }
    }

    fn validate(&mut self) {
        // An offer that was answered elsewhere, or a call that ended, must not leave a dead card.
        if self.open && self.view == View::Offer && self.model.offers.is_empty() {
            self.close();
        }
        if self.open && self.view == View::Call && self.model.call().is_none() && !matches!(self.reason, Reason::Event(Some(_))) {
            self.reason = Reason::Event(Some(0.8));
            self.life = 0.8;
        }
    }

    pub fn mark_dirty(&mut self) {
        self.dirty = true;
    }

    /// Gives back the memory of the drawing layers (the island has been hidden for a while).
    pub fn release_buffers(&mut self) {
        self.layer = None;
        self.body_layer = None;
    }

    /// A short message from the executor (a file that could not be sent, say).
    pub fn flash(&mut self, good: bool, title: String, text: String) {
        let note = Note { icon: Some(if good { Icon::Check } else { Icon::Close }), title, text, good };
        // Even with automatic opening off, the answer to something the user just did is shown.
        self.show_note_for(note, if good { 2.5 } else { 4.5 });
    }

    /// True once after something changed, so the host draws only when needed.
    pub fn take_dirty(&mut self) -> bool {
        std::mem::take(&mut self.dirty)
    }

    // ------------------------------------------------------------------------------------------------ drawing

    #[cfg(test)]
    pub fn new_canvas(&self, k: f32) -> Canvas {
        Canvas::new(CANVAS_W, CANVAS_H, k)
    }

    /// Draws the current frame into `cv` (cleared first).
    pub fn render(&mut self, cv: &mut Canvas) {
        cv.clear();
        self.hits.clear();
        if !self.visible() {
            return;
        }
        let pal = view::palette(&self.cfg);
        let (s, r) = self.surface();
        let flat = self.cfg.top_margin == 0;
        let Some(path) = view::surf_path(s, r, flat) else { return };
        // While a file is being carried, the pixels around the island are made (all but) invisible but solid for hit
        // testing, so the system's drag-and-drop reaches the window even at the very edge of the screen.
        if self.open && self.view == View::Drop {
            cv.squircle(R::new(s.x - 40.0, 0.0, s.w + 80.0, s.bottom() + 18.0), 20.0, color([0, 0, 0], 0.012), None);
        }
        cv.fill_path(&path, color(pal.bg, 1.0), None);
        if let Some(rim) = view::surf_rim(s, r, flat) {
            cv.stroke_path(&rim, color(pal.fg, if pal.light { 0.10 } else { 0.15 }), 1.0, None);
        }
        let o = self.o.v;
        let pill_op = 1.0 - (o / 0.3).clamp(0.0, 1.0);
        let panel_op = ((o - 0.3) / 0.55).clamp(0.0, 1.0);
        let moving = self.o.running() || self.vs.running() || self.reveal.running() || self.pill_w.running();
        let mask = if moving { cv.mask_path(&path) } else { None };
        let tabs = self.tabs();
        let ui = Ui {
            model: &self.model,
            cfg: &self.cfg,
            view: &self.view,
            page: self.page,
            note: &self.note,
            tabs: &tabs,
            tab_x: self.tab_x.v,
            player_pc: self.player_pc,
            seen: self.seen_notifs,
            copied: self.copied,
            drag_over: self.drag_over,
            pinned: self.pinned,
            time: self.time,
            peek: self.peek.as_ref(),
            peek_fade: self.peek_fade.v,
        };
        let (ptr, prs) = (self.pointer, self.pressed);
        let fonts = &mut self.fonts;
        let hits = &mut self.hits;
        let layer = &mut self.layer;
        let body_layer = &mut self.body_layer;
        let fresh = |slot: &mut Option<Canvas>, cv: &Canvas| {
            let mut l = match slot.take() {
                Some(l) if l.width_px() == cv.width_px() && l.height_px() == cv.height_px() => l,
                _ => Canvas { pm: Pixmap::new(cv.width_px(), cv.height_px()).expect("layer"), k: cv.k },
            };
            l.clear();
            l
        };

        // The collapsed pill.
        if pill_op > 0.004 {
            if pill_op >= 0.999 && mask.is_none() {
                let mut d = Draw { cv, fonts, hits, pal: &pal, pointer: ptr, pressed: prs };
                view::draw_pill(&mut d, &ui, s);
            } else {
                let mut l = fresh(layer, cv);
                {
                    let mut d = Draw { cv: &mut l, fonts, hits, pal: &pal, pointer: ptr, pressed: prs };
                    view::draw_pill(&mut d, &ui, s);
                }
                cv.blit(&l.pm, pill_op, 1.0, 0.0, 0.0, mask.as_ref());
                *layer = Some(l);
            }
        }
        // The open panel (or one of the compact screens).
        if panel_op > 0.004 {
            let (vw, vh, _) = view::view_size(&self.view);
            let origin = ((CANVAS_W - vw) / 2.0, s.y.max(self.cfg.top_margin as f32 * 0.0));
            let shift = (1.0 - panel_op) * -8.0;
            let origin = (origin.0, if self.reveal.v < 1.0 { s.y } else { origin.1.min(s.y) } + shift);
            let is_page = matches!(self.view, View::Page(_));
            let direct = panel_op >= 0.999 && mask.is_none();
            let mut l = if direct { None } else { Some(fresh(layer, cv)) };
            {
                let target: &mut Canvas = match l.as_mut() {
                    Some(l) => l,
                    None => cv,
                };
                // The header and the compact screens are drawn straight; the body of a tab fades in on its own.
                if is_page {
                    let mut d = Draw { cv: target, fonts, hits, pal: &pal, pointer: ptr, pressed: prs };
                    view::draw_header(&mut d, &ui, origin);
                } else {
                    let rect = R::new(origin.0, origin.1, vw, vh);
                    let mut d = Draw { cv: target, fonts, hits, pal: &pal, pointer: ptr, pressed: prs };
                    view::draw_event(&mut d, &ui, rect);
                }
            }
            if is_page {
                let f = self.fade.v;
                let target: &mut Canvas = match l.as_mut() {
                    Some(l) => l,
                    None => cv,
                };
                if f >= 0.999 {
                    let mut d = Draw { cv: target, fonts, hits, pal: &pal, pointer: ptr, pressed: prs };
                    view::draw_body(&mut d, &ui, origin);
                } else {
                    let mut b = fresh(body_layer, target);
                    {
                        let mut d = Draw { cv: &mut b, fonts, hits, pal: &pal, pointer: ptr, pressed: prs };
                        view::draw_body(&mut d, &ui, origin);
                    }
                    target.blit_shift(&b.pm, f, (1.0 - f) * 6.0, None);
                    *body_layer = Some(b);
                }
            }
            if let Some(l) = l {
                cv.blit(&l.pm, panel_op, 1.0, 0.0, 0.0, mask.as_ref());
                *layer = Some(l);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use pb_core::engine::{Event, PeerState, PeerView};
    use serde_json::json;

    fn island() -> Island {
        let mut cfg = IslandConfig::default();
        cfg.animation = "off".into();
        Island::new(cfg)
    }

    fn run(i: &mut Island, secs: f32) {
        let mut t = 0.0;
        while t < secs {
            i.update(1.0 / 120.0);
            t += 1.0 / 120.0;
        }
    }

    fn with_phone(i: &mut Island) {
        let peer = PeerView { id: "p".into(), name: "Pixel 9a".into(), addr: String::new(), state: PeerState::Connected, trusted: true, detail: String::new() };
        i.model.feed(&Event::PeerChanged { peer });
        i.model.feed(&Event::Message { peer_id: "p".into(), kind: "pb.x.info".into(), body: json!({"kind":"phone","battery":{"level":78,"charging":false}}) });
        i.model.feed(&Event::Message { peer_id: "p".into(), kind: "pb.x.phone.state".into(), body: json!({"dnd":false,"torch":true,"ringer":"normal","media":6,"mediaMax":15}) });
    }

    /// The pointer on the pill, as a host would report it.
    fn hover(i: &mut Island) {
        let (s, _) = i.surface();
        i.set_pointer(Some((s.cx(), s.cy())));
    }

    #[test]
    fn it_opens_after_the_delay_and_not_before() {
        let mut i = island();
        i.set_zone(true, false, 0.0);
        i.update(0.05);
        assert!(!i.is_open());
        i.update(0.10);
        i.update(0.10);
        assert!(i.is_open());
        assert_eq!(i.view, View::Page(Page::Home));
    }

    #[test]
    fn passing_by_quickly_does_nothing() {
        let mut i = island();
        i.set_zone(true, false, 0.0);
        i.update(0.06);
        i.set_zone(false, false, 0.0);
        i.update(0.06);
        i.set_zone(true, false, 0.0);
        i.update(0.06);
        assert!(!i.is_open());
    }

    #[test]
    fn hidden_mode_shows_the_pill_only_while_the_pointer_is_there() {
        let mut i = island();
        assert!(!i.visible());
        i.set_zone(true, false, 0.0);
        i.update(0.02);
        assert!(i.visible());
        i.set_zone(false, false, 0.0);
        run(&mut i, 1.0);
        assert!(!i.visible());
    }

    #[test]
    fn always_visible_keeps_the_pill() {
        let mut cfg = IslandConfig::default();
        cfg.animation = "off".into();
        cfg.always_visible = true;
        let mut i = Island::new(cfg);
        run(&mut i, 2.0);
        assert!(i.visible() && !i.is_open());
        i.set_suppressed(true);
        assert!(!i.visible());
    }

    #[test]
    fn it_closes_when_the_pointer_leaves() {
        let mut i = island();
        i.set_zone(true, false, 0.0);
        run(&mut i, 0.5);
        assert!(i.is_open());
        i.set_zone(false, false, 0.0);
        i.set_pointer(Some((10.0, 400.0)));
        run(&mut i, 2.0);
        assert!(!i.is_open());
        assert!(!i.visible());
    }

    #[test]
    fn it_stays_while_the_pointer_is_on_it() {
        let mut i = island();
        i.set_zone(true, false, 0.0);
        run(&mut i, 0.5);
        i.set_zone(false, false, 0.0);
        hover(&mut i);
        run(&mut i, 3.0);
        assert!(i.is_open());
    }

    #[test]
    fn pinning_keeps_it_open() {
        let mut i = island();
        i.set_zone(true, false, 0.0);
        run(&mut i, 0.5);
        i.act(Act::Pin);
        i.set_zone(false, false, 0.0);
        i.set_pointer(Some((10.0, 400.0)));
        run(&mut i, 3.0);
        assert!(i.is_open());
        i.act(Act::Pin);
        run(&mut i, 2.0);
        assert!(!i.is_open());
    }

    #[test]
    fn tabs_change_the_view_and_remember_the_last_one() {
        let mut i = island();
        i.set_zone(true, false, 0.0);
        run(&mut i, 0.5);
        i.act(Act::Go(Page::Controls));
        assert_eq!(i.view, View::Page(Page::Controls));
        i.close();
        run(&mut i, 1.0);
        i.set_zone(true, false, 0.0);
        run(&mut i, 0.5);
        assert_eq!(i.view, View::Page(Page::Controls));
    }

    #[test]
    fn a_ringing_call_opens_it_and_stays_until_answered() {
        let mut i = island();
        with_phone(&mut i);
        let n = i.model.feed(&Event::Message { peer_id: "p".into(), kind: "pb.x.call".into(), body: json!({"active":true,"ringing":true,"canAnswer":true,"name":"Mamá"}) });
        i.notices(n);
        assert!(i.is_open());
        assert_eq!(i.view, View::Call);
        run(&mut i, 30.0);
        assert!(i.is_open(), "a ringing phone must not time out");
        let n = i.model.feed(&Event::Message { peer_id: "p".into(), kind: "pb.x.call".into(), body: json!({"active":false}) });
        i.notices(n);
        run(&mut i, 3.0);
        assert!(!i.is_open());
    }

    #[test]
    fn a_file_offer_waits_for_the_user_and_the_buttons_answer() {
        let mut i = island();
        with_phone(&mut i);
        let n = i.model.feed(&Event::TransferOffer { id: "t1".into(), peer_id: "p".into(), peer_name: "Pixel 9a".into(), name: "foto.jpg".into(), size: 3_000_000 });
        i.notices(n);
        run(&mut i, 20.0);
        assert!(i.is_open());
        let mut cv = i.new_canvas(1.0);
        i.render(&mut cv);
        let accept = i.hits.iter().find(|h| matches!(&h.act, Act::Accept(id) if id == "t1")).expect("accept button").r;
        i.set_pointer(Some((accept.cx(), accept.cy())));
        i.press();
        i.release();
        assert_eq!(i.take_cmds(), vec![Cmd::Respond { id: "t1".into(), accept: true }]);
    }

    #[test]
    fn a_notification_is_a_peek_on_the_pill_and_goes_away_by_itself() {
        let mut i = island();
        with_phone(&mut i);
        let n = i.model.feed(&Event::Message { peer_id: "p".into(), kind: "pb.x.notif.posted".into(), body: json!({"key":"k","app":"WhatsApp","title":"Ana","text":"¿Vienes?"}) });
        i.notices(n);
        assert!(!i.is_open(), "a notification does not open the panel");
        assert!(i.peek.is_some() && i.visible());
        run(&mut i, 7.0);
        assert!(i.peek.is_none());
        assert!(!i.visible());
    }

    #[test]
    fn modules_can_be_turned_off() {
        let mut i = island();
        i.cfg.modules.notifications = false;
        i.cfg.modules.call = false;
        with_phone(&mut i);
        let n = i.model.feed(&Event::Message { peer_id: "p".into(), kind: "pb.x.notif.posted".into(), body: json!({"key":"k","app":"A","title":"B","text":"C"}) });
        i.notices(n);
        let n = i.model.feed(&Event::Message { peer_id: "p".into(), kind: "pb.x.call".into(), body: json!({"active":true,"ringing":true}) });
        i.notices(n);
        assert!(!i.is_open() && i.peek.is_none());
        assert!(!i.tabs().iter().any(|(_, p)| *p == Page::Notifs));
    }

    #[test]
    fn disabled_means_it_never_opens() {
        let mut i = island();
        i.cfg.enabled = false;
        i.set_zone(true, false, 0.0);
        i.update(5.0);
        i.hotkey();
        assert!(!i.is_open() && !i.visible());
    }

    #[test]
    fn holding_the_button_in_the_zone_shows_the_drop_target_and_a_drop_sends() {
        let mut i = island();
        with_phone(&mut i);
        i.set_zone(true, true, 0.3);
        assert!(i.is_open());
        assert_eq!(i.view, View::Drop);
        i.drag(Drag::Enter);
        i.dropped(vec![PathBuf::from("/tmp/a.txt")]);
        assert_eq!(i.take_cmds(), vec![Cmd::SendFiles(vec![PathBuf::from("/tmp/a.txt")])]);
    }

    #[test]
    fn dragging_a_window_by_the_top_edge_does_not_leave_the_drop_target_up() {
        let mut i = island();
        with_phone(&mut i);
        i.set_zone(true, true, 0.3);
        assert!(i.is_open());
        i.set_zone(false, false, 0.0);
        i.set_pointer(Some((10.0, 400.0)));
        run(&mut i, 3.0);
        assert!(!i.is_open());
    }

    #[test]
    fn the_toggle_sends_the_new_state_and_updates_at_once() {
        let mut i = island();
        with_phone(&mut i);
        i.act(Act::Toggle("torch"));
        i.act(Act::Toggle("dnd"));
        let cmds = i.take_cmds();
        assert_eq!(cmds[0], Cmd::Phone { what: "torch", body: json!({"on": false}) });
        assert_eq!(cmds[1], Cmd::Phone { what: "dnd", body: json!({"on": true}) });
        assert!(i.model.phone["p"].dnd && !i.model.phone["p"].torch);
    }

    #[test]
    fn the_volume_slider_maps_to_the_phones_range() {
        let mut i = island();
        with_phone(&mut i);
        i.open(View::Page(Page::Controls), Reason::Hover);
        hover(&mut i);
        run(&mut i, 0.5);
        let mut cv = i.new_canvas(1.0);
        i.render(&mut cv);
        let slider = i.hits.iter().find(|h| h.act == Act::Volume).unwrap().r;
        let inner = slider.inflate(-8.0);
        i.set_pointer(Some((inner.x + inner.w * 0.5, inner.cy())));
        i.press();
        let cmds = i.take_cmds();
        match &cmds[0] {
            Cmd::Phone { what: "volume", body } => assert!((5..=10).contains(&body["value"].as_i64().unwrap()), "{body}"),
            c => panic!("{c:?}"),
        }
    }

    #[test]
    fn sizes_are_inside_the_canvas_with_room_for_the_bounce() {
        for v in [View::Page(Page::Home), View::Call, View::Offer, View::Note, View::Drop, View::Transfer("x".into())] {
            let (w, h, _) = view::view_size(&v);
            assert!(w * 1.04 <= CANVAS_W && h * 1.04 + 8.0 <= CANVAS_H, "{v:?} {w}x{h}");
        }
    }

    #[test]
    fn the_pill_grows_with_what_it_shows() {
        let mut i = island();
        let empty = i.pill_w.v;
        i.model.pc_media = Some(super::super::model::Media { title: "Un Verano Sin Ti".into(), artist: "Bad Bunny".into(), playing: true, speed: 1.0, ..Default::default() });
        i.remeasure(true);
        i.pill_w.snap(i.pill_w.target());
        assert!(i.pill_w.v > empty + 100.0, "{} vs {}", i.pill_w.v, empty);
    }

    /// Frames of a PNG sheet, for a visual check: `ISLAND_PNG_DIR=/tmp/x cargo test gallery`.
    fn shoot(i: &mut Island, dir: &str, name: &str, k: f32, bg: [u8; 3]) {
        let mut cv = i.new_canvas(k);
        i.render(&mut cv);
        let mut out = Canvas::new(CANVAS_W, CANVAS_H, k);
        out.pm.fill(tiny_skia::Color::from_rgba8(bg[0], bg[1], bg[2], 255));
        out.blit(&cv.pm, 1.0, 1.0, 0.0, 0.0, None);
        let mut rgba = out.pm.data().to_vec();
        for px in rgba.chunks_exact_mut(4) {
            px[3] = 255;
        }
        let file = std::fs::File::create(format!("{dir}/{name}.png")).unwrap();
        let mut enc = png::Encoder::new(file, out.width_px(), out.height_px());
        enc.set_color(png::ColorType::Rgba);
        enc.set_depth(png::BitDepth::Eight);
        enc.write_header().unwrap().write_image_data(&rgba).unwrap();
    }

    fn demo(cfg: IslandConfig) -> Island {
        let art = {
            let (w, h) = (64u32, 64u32);
            let mut data = Vec::new();
            for y in 0..h {
                for x in 0..w {
                    data.extend_from_slice(&[(x * 4) as u8, (y * 3 + 40) as u8, 200u8.saturating_sub((x + y) as u8), 255]);
                }
            }
            super::super::gfx::Image { w, h, data }
        };
        let mut i = Island::new(cfg);
        with_phone(&mut i);
        i.set_time(LocalTime { hour: 18, min: 42, wday: 2, month: 11, day: 17 });
        for (n, (app, title, text)) in [("WhatsApp", "Ana", "¿Vienes a cenar hoy? Te guardé un lugar"), ("Gmail", "Banco", "Tu estado de cuenta está listo"), ("Telegram", "Edwin", "ya lo subí al repo 👍")].iter().enumerate() {
            i.model.feed(&Event::Message { peer_id: "p".into(), kind: "pb.x.notif.posted".into(), body: json!({"key": format!("k{n}"), "app": app, "title": title, "text": text}) });
        }
        for c in ["https://github.com/Alero-Team/Alero", "Reunión mañana 10:00"] {
            i.model.feed(&Event::Message { peer_id: "p".into(), kind: "pb.x.clip".into(), body: json!({"text": c}) });
        }
        i.model.pc_media = Some(super::super::model::Media { title: "Un Verano Sin Ti".into(), artist: "Bad Bunny".into(), playing: true, position_ms: 83_000, duration_ms: 212_000, speed: 1.0, at: Some(Instant::now()), art: Some(art), ..Default::default() });
        i.model.feed(&Event::Message { peer_id: "p".into(), kind: "pb.x.call".into(), body: json!({"active":true,"ringing":true,"canAnswer":true,"name":"Mamá"}) });
        i.model.feed(&Event::TransferOffer { id: "o1".into(), peer_id: "p".into(), peer_name: "Pixel 9a".into(), name: "Vacaciones-2026.mp4".into(), size: 482_000_000 });
        i.model.feed(&Event::TransferStarted { id: "x1".into(), peer_id: "p".into(), peer_name: "Pixel 9a".into(), name: "informe-final.pdf".into(), size: 8_000_000, incoming: false });
        i.model.feed(&Event::TransferProgress { id: "x1".into(), done: 5_200_000, total: 8_000_000, bytes_per_sec: 3_400_000 });
        i.note = Note { icon: Some(Icon::Bell), title: "WhatsApp · Ana".into(), text: "¿Vienes a cenar hoy?".into(), good: false };
        i
    }

    #[test]
    fn gallery() {
        let Ok(dir) = std::env::var("ISLAND_PNG_DIR") else { return };
        let views: Vec<(&str, View)> = vec![
            ("home", View::Page(Page::Home)),
            ("player", View::Page(Page::Player)),
            ("files", View::Page(Page::Files)),
            ("notifs", View::Page(Page::Notifs)),
            ("clipboard", View::Page(Page::Clipboard)),
            ("controls", View::Page(Page::Controls)),
            ("call", View::Call),
            ("offer", View::Offer),
            ("transfer", View::Transfer("x1".into())),
            ("note", View::Note),
            ("drop", View::Drop),
        ];
        for (colour, tag) in [("#000000", "oled"), ("#f2efe9", "light")] {
            for (name, v) in &views {
                let mut cfg = IslandConfig::default();
                cfg.animation = "off".into();
                cfg.color = colour.into();
                let mut i = demo(cfg);
                i.open(v.clone(), Reason::Hover);
                let (s, _) = i.surface();
                i.set_pointer(Some((s.cx(), s.y + 70.0)));
                run(&mut i, 0.6);
                if *name == "drop" {
                    i.drag_over = true;
                }
                shoot(&mut i, &dir, &format!("{tag}-{name}"), 2.0, [70, 78, 92]);
            }
        }
        // The collapsed pill, with and without music.
        for (n, music) in [("pill", true), ("pill-empty", false)] {
            let mut cfg = IslandConfig::default();
            cfg.animation = "off".into();
            cfg.always_visible = true;
            let mut i = demo(cfg);
            if !music {
                i.model.pc_media = None;
            }
            i.model.offers.clear();
            i.remeasure(true);
            i.pill_w.snap(i.pill_w.target());
            run(&mut i, 0.3);
            shoot(&mut i, &dir, n, 2.0, [70, 78, 92]);
        }
    }

    /// Frames of the opening and of a tab change: `ISLAND_PNG_DIR=/tmp/x cargo test frames`.
    #[test]
    fn frames() {
        let Ok(dir) = std::env::var("ISLAND_PNG_DIR") else { return };
        let mut cfg = IslandConfig::default();
        cfg.animation = "normal".into();
        cfg.always_visible = true;
        let mut i = demo(cfg);
        i.model.calls.clear();
        i.model.offers.clear();
        i.remeasure(true);
        i.pill_w.snap(i.pill_w.target());
        run(&mut i, 0.2);
        let (s, _) = i.surface();
        i.set_pointer(Some((s.cx(), s.cy())));
        let mut shots: Vec<(String, f32)> = [0, 40, 80, 120, 160, 200, 260, 360, 520].iter().map(|ms| (format!("open-{ms:03}"), *ms as f32 / 1000.0)).collect();
        let mut t = 0.0f32;
        let dt = 1.0 / 240.0;
        i.set_zone(true, false, 0.0);
        i.update(0.2);
        i.open(View::Page(Page::Home), Reason::Hover);
        let mut phase2 = false;
        while !shots.is_empty() {
            i.update(dt);
            t += dt;
            if shots[0].1 <= t {
                let (name, _) = shots.remove(0);
                shoot(&mut i, &dir, &name, 1.0, [70, 78, 92]);
            }
            if shots.is_empty() && !phase2 {
                phase2 = true;
                run(&mut i, 0.6);
                i.act(Act::Go(Page::Player));
                t = 0.0;
                shots = [0, 40, 80, 120, 180, 260, 400].iter().map(|ms| (format!("tab-{ms:03}"), *ms as f32 / 1000.0)).collect();
            }
        }
    }
}
