//! The island itself: what it shows, how it opens and closes, and how it moves.
//!
//! Nothing here touches the operating system. A host (Windows or X11) feeds it the pointer, the engine's events and
//! the passing of time, asks for a frame, and executes the commands it returns. That keeps the whole behaviour
//! testable and the platform code small.

use std::path::PathBuf;
use std::time::Instant;

use serde_json::{json, Value};
use tiny_skia::Pixmap;

use super::config::{luma, IslandConfig};
use super::gfx::{color, icon, mix, Canvas, Fonts, Icon, Image, Rgb, Weight, R};
use super::model::{Model, Notice, XState};
use super::motion::{Motion, Spring, Style};
use crate::lang::t;

/// Logical size of the drawing surface (the window is this big times the scale). The largest screen plus the
/// room the spring overshoots into and the shadow.
pub const CANVAS_W: f32 = 480.0;
pub const CANVAS_H: f32 = 344.0;
const PAD: f32 = 18.0;
/// The notch at rest: a slim tab on the top edge that says where the island is.
const PEEK: (f32, f32) = (132.0, 6.0);
const MAX_RADIUS: f32 = 32.0;
const SHADOW_DIV: f32 = 4.0;
/// The notch while something lives in it (music, charging): the iPhone's compact island.
const LIVE: (f32, f32) = (236.0, 34.0);

/// What the closed island shows, like the iPhone's Dynamic Island.
#[derive(Clone, Copy, PartialEq, Debug)]
enum Live {
    /// The phone was just plugged in (for a few seconds): its battery level.
    Charging(i32),
    /// Something started playing, or the song changed (for a few seconds).
    Media,
}
const DANGER: Rgb = [255, 69, 58];
const SUCCESS: Rgb = [48, 209, 88];

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
    /// A control that needs adb: "wifi", "bt", "rotate" or "lock".
    Adb(&'static str),
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
    Adb { what: &'static str, on: bool },
    /// Asks the phone what it is playing (its answer is a `pb.x.media.state`).
    AskMedia,
}

#[derive(Clone, Copy, PartialEq, Debug)]
enum Phase {
    Closed,
    Open,
    Closing,
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
    /// Width that fits the text (set when shown); 0: the default.
    pub w: f32,
    /// The app's own icon (a notification), drawn instead of [`Note::icon`].
    pub img: Option<Image>,
}

pub struct Hit {
    r: R,
    act: Act,
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
    phase: Phase,
    reason: Reason,
    shown: View,
    want: View,
    swap: bool,
    note: Note,
    w: Spring,
    h: Spring,
    content: Spring,
    content_wait: f32,
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
    last_slider: f64,
    /// Last volume value held back by the slider throttle: it is sent when the button is released.
    slide_unsent: Option<i32>,
    wheel_acc: f32,
    copied: Option<(usize, f32)>,
    player_pc: Option<bool>,
    seen_notifs: Instant,
    cmds: Vec<Cmd>,
    dirty: bool,
    layer: Option<Canvas>,
    /// The shadow, drawn at a quarter of the resolution: blurring it is the costliest step of a frame.
    shadow: Option<Canvas>,
    clock: f64,
    reduce_motion: bool,
    /// The resting notch is drawn (not over a full-screen game or video).
    rest: bool,
    /// Turning Wi-Fi off cuts a wireless connection: the tile asks for a second tap until this clock time.
    wifi_confirm: f64,
    /// Clock time until which the closed island shows the phone charging.
    charge_until: f64,
    /// Clock time until which the closed island shows what is playing, and what it last saw playing.
    media_until: f64,
    media_seen: Option<String>,
    /// The phone already asked for its media (an island started after the phone connected missed its first state).
    asked_media: Option<String>,
}

fn fmt_size(b: u64) -> String {
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

impl Island {
    pub fn new(cfg: IslandConfig) -> Self {
        let motion = Motion::new(Style::parse(&cfg.animation));
        let mut me = Self {
            cfg,
            model: Model::default(),
            motion,
            fonts: Fonts::new(),
            phase: Phase::Closed,
            reason: Reason::Hover,
            shown: View::Page(Page::Home),
            want: View::Page(Page::Home),
            swap: false,
            note: Note::default(),
            w: Spring::new(PEEK.0, motion.expand.0, motion.expand.1),
            h: Spring::new(PEEK.1, motion.expand.0, motion.expand.1),
            content: Spring::new(0.0, motion.content.0, motion.content.1),
            content_wait: 0.0,
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
            rest: true,
            wifi_confirm: 0.0,
            charge_until: 0.0,
            media_until: 0.0,
            media_seen: None,
            asked_media: None,
            slide_unsent: None,
            wheel_acc: 0.0,
            copied: None,
            player_pc: None,
            seen_notifs: Instant::now(),
            cmds: Vec::new(),
            dirty: true,
            layer: None,
            shadow: None,
            clock: 0.0,
            reduce_motion: false,
        };
        me.retune_motion();
        me
    }

    pub fn set_config(&mut self, cfg: IslandConfig) {
        self.cfg = cfg;
        self.retune_motion();
        if !self.cfg.enabled {
            self.snap_closed();
        }
        self.dirty = true;
    }

    /// The system asks for less motion (Windows: animations off): the springs become instantaneous.
    pub fn set_reduce_motion(&mut self, on: bool) {
        if self.reduce_motion != on {
            self.reduce_motion = on;
            self.retune_motion();
        }
    }

    fn retune_motion(&mut self) {
        let style = if self.reduce_motion && self.cfg.respect_reduce_motion { Style::Off } else { Style::parse(&self.cfg.animation) };
        self.motion = Motion::new(style);
        self.content.tune(self.motion.content.0, self.motion.content.1);
    }

    pub fn set_rest(&mut self, on: bool) {
        if self.rest != on {
            self.rest = on;
            self.dirty = true;
        }
    }

    pub fn is_open(&self) -> bool {
        self.phase != Phase::Closed
    }

    pub fn take_cmds(&mut self) -> Vec<Cmd> {
        std::mem::take(&mut self.cmds)
    }

    /// Wants the media polled (the player screens are on or about to be).
    /// The pointer is on the open island, or a file is being carried to it: the window must take the mouse.
    pub fn wants_input(&self) -> bool {
        self.phase == Phase::Open && (self.want == View::Drop || self.pointer.is_some_and(|(x, y)| self.pill().contains(x, y)))
    }

    /// Wants the phone polled over adb (the controls are on screen).
    pub fn wants_adb(&self) -> bool {
        self.phase == Phase::Open && self.shown == View::Page(Page::Controls)
    }

    /// Also while closed: the compact island shows what is playing.
    pub fn wants_media(&self) -> bool {
        self.cfg.enabled && self.cfg.modules.player
    }

    fn live(&self) -> Option<Live> {
        if self.clock < self.charge_until {
            if let Some(i) = self.model.target().and_then(|p| self.model.info.get(&p.id)) {
                return Some(Live::Charging(i.battery));
            }
        }
        (self.cfg.modules.player && self.clock < self.media_until && self.media_line().is_some_and(|(m, _)| m.playing)).then_some(Live::Media)
    }

    /// Playing started or the song changed: the closed island shows it for a moment, then steps back.
    fn watch_media(&mut self) {
        let now = self.media_line().filter(|(m, _)| m.playing).map(|(m, _)| format!("{} | {}", m.title, m.artist));
        if now != self.media_seen {
            if now.is_some() {
                self.media_until = self.clock + 4.0;
                self.dirty = true;
            }
            self.media_seen = now;
        }
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
        if self.hot && !button && self.phase != Phase::Open {
            self.hot_for += dt;
            if self.hot_for * 1000.0 >= self.cfg.open_delay_ms as f32 {
                self.hot_for = 0.0;
                self.open(View::Page(Page::Home), Reason::Hover);
            }
        } else if !self.hot {
            self.hot_for = 0.0;
        }
        // A button held in the zone may be a file being carried: show the drop target after a moment.
        if self.hot && button && self.phase != Phase::Open && self.cfg.modules.send {
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
                if self.phase != Phase::Open || self.shown != View::Drop {
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
            self.show_note(Note { icon: Some(Icon::Phone), title: t("Sin teléfono conectado", "No phone connected").into(), text: t("Conecta un teléfono para enviar archivos.", "Connect a phone to send files.").into(), good: false, w: 0.0, img: None });
            return;
        }
        self.cmds.push(Cmd::SendFiles(files));
        self.life = 2.0;
    }

    pub fn hotkey(&mut self) {
        if self.phase == Phase::Open {
            self.close();
        } else if self.cfg.enabled {
            self.open(View::Page(Page::Home), Reason::Key);
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
        let r = self.hits[i].r;
        let v = ((x - r.x) / r.w).clamp(0.0, 1.0);
        let max = self.model.target_id().and_then(|id| self.model.phone.get(&id)).map_or(15, |p| p.media_max);
        let value = (v * max as f32).round() as i32;
        // The phone is asked at most ~15 times a second while dragging.
        if !first && self.clock - self.last_slider < 0.066 {
            self.slide_unsent = Some(value);
            return;
        }
        self.slide_unsent = None;
        self.last_slider = self.clock;
        self.set_volume(value);
    }

    fn set_volume(&mut self, value: i32) {
        self.cmds.push(Cmd::Phone { what: "volume", body: json!({"stream": "media", "value": value}) });
        if let Some(p) = self.model.target_id().and_then(|id| self.model.phone.get_mut(&id)) {
            p.media = value;
        }
        self.dirty = true;
    }

    pub fn release(&mut self) {
        let down = self.pressed.take();
        if let Some(v) = self.slide_unsent.take() {
            if self.model.target_id().and_then(|id| self.model.phone.get(&id)).map(|p| p.media) != Some(v) {
                self.set_volume(v);
            }
        }
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
        if !self.hits.iter().any(|h| h.act == Act::Volume && h.r.inflate(8.0).contains(x, y)) {
            self.wheel_acc = 0.0;
            return;
        }
        // Touchpads and high-resolution wheels send fractions: a step goes out once they add up to a whole notch.
        self.wheel_acc += notches;
        let step = self.wheel_acc.trunc();
        if step == 0.0 {
            return;
        }
        self.wheel_acc -= step;
        if let Some(id) = self.model.target_id() {
            let (cur, max) = self.model.phone.get(&id).map_or((0, 15), |p| (p.media, p.media_max));
            self.set_volume((cur + step as i32).clamp(0, max));
        }
    }

    fn act(&mut self, a: Act) {
        match a {
            Act::Go(p) => {
                if p == Page::Notifs {
                    self.seen_notifs = Instant::now();
                }
                self.go(View::Page(p));
            }
            Act::OpenApp => {
                self.cmds.push(Cmd::OpenApp);
                self.close();
            }
            Act::PcMedia(k) => self.cmds.push(Cmd::PcMedia(k)),
            Act::PhoneMedia(k) => self.cmds.push(Cmd::PhoneMedia(k)),
            Act::Source => self.player_pc = Some(!self.use_pc()),
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
            Act::Adb(what) => {
                let id = self.model.target_id().unwrap_or_default();
                let Some(r) = self.model.adb.get_mut(&id) else { return };
                let cur = match what {
                    "wifi" => r.wifi,
                    "bt" => r.bt,
                    "rotate" => r.rotate,
                    _ => false,
                };
                if what == "wifi" && cur && self.clock >= self.wifi_confirm {
                    self.wifi_confirm = self.clock + 3.0;
                    self.dirty = true;
                    return;
                }
                self.wifi_confirm = 0.0;
                match what {
                    "wifi" => r.wifi = !cur,
                    "bt" => r.bt = !cur,
                    "rotate" => r.rotate = !cur,
                    _ => {}
                }
                self.cmds.push(Cmd::Adb { what, on: !cur });
            }
            Act::Device => self.model.cycle_target(),
        }
        self.dirty = true;
    }

    // ------------------------------------------------------------------------------------------------ events

    /// What the engine reported: opens the island for what matters, when the user wants that.
    pub fn notices(&mut self, list: Vec<Notice>) {
        for n in list {
            let m = &self.cfg.modules;
            let target = self.model.target_id();
            if target.is_some() && self.asked_media != target && self.model.phone_media.is_none() {
                self.asked_media = target;
                self.cmds.push(Cmd::AskMedia);
            }
            if std::mem::take(&mut self.model.charging_started) && m.status {
                self.charge_until = self.clock + 4.0;
                self.dirty = true;
            }
            match n {
                Notice::Call if m.call => {
                    if self.model.call().is_some() {
                        self.open_event(View::Call, None);
                        if self.cfg.sound && self.model.call().is_some_and(|c| c.1.ringing) {
                            self.cmds.push(Cmd::Beep);
                        }
                    } else if self.shown == View::Call {
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
                    if self.shown == View::Transfer(id) {
                        self.life = if ok { 2.4 } else { 4.0 };
                        self.reason = Reason::Event(Some(self.life));
                    }
                }
                Notice::Notif(key) if m.notifications => {
                    if let Some(n) = self.model.notifs.iter().find(|n| n.key == key) {
                        let note = Note { icon: Some(Icon::Bell), title: [n.app.as_str(), n.title.as_str()].iter().filter(|p| !p.is_empty()).copied().collect::<Vec<_>>().join(" · "), text: n.text.clone(), good: false, w: 0.0, img: self.model.icon(&n.pkg).cloned() };
                        self.show_note_for(note, self.cfg.event_secs as f32);
                    }
                }
                Notice::Clip if m.clipboard => {
                    let from = self.model.clips.front().map(|c| c.from.clone()).unwrap_or_default();
                    self.show_note(Note { icon: Some(Icon::Clipboard), title: t("Portapapeles recibido", "Clipboard received").into(), text: from, good: true, w: 0.0, img: None });
                }
                _ => {}
            }
        }
        self.dirty = true;
    }

    fn show_note(&mut self, note: Note) {
        self.show_note_for(note, 3.0)
    }

    fn show_note_for(&mut self, mut note: Note, secs: f32) {
        if !self.cfg.auto_expand {
            return;
        }
        // The card hugs its text, so a short note is not a long box with everything on the left.
        let text = self.fonts.measure(&note.title, 14.0, Weight::Bold).max(self.fonts.measure(&note.text, 12.5, Weight::Regular));
        note.w = (PAD + 52.0 + text + PAD + 8.0).clamp(280.0, 440.0);
        self.note = note;
        // A note never replaces something that asks for an answer.
        if self.phase == Phase::Open && self.shown.rank() > View::Note.rank() && self.want.rank() > View::Note.rank() {
            return;
        }
        self.open_event(View::Note, Some(secs));
    }

    fn open_event(&mut self, v: View, secs: Option<f32>) {
        // The files just dropped on the island: their progress takes the drop target's place, whatever the settings.
        let dropped = self.phase != Phase::Closed && self.want == View::Drop && matches!(v, View::Transfer(_));
        if !self.cfg.enabled || (!self.cfg.auto_expand && !dropped) {
            return;
        }
        if self.phase == Phase::Open && self.want.rank() > v.rank() && !dropped {
            return;
        }
        if self.phase == Phase::Open {
            self.go(v.clone());
            self.reason = Reason::Event(secs);
        } else {
            self.open(v.clone(), Reason::Event(secs));
        }
        self.life = secs.unwrap_or(0.0);
    }

    // ------------------------------------------------------------------------------------------------ state

    fn snap_closed(&mut self) {
        self.phase = Phase::Closed;
        self.w.snap(PEEK.0);
        self.h.snap(PEEK.1);
        self.content.snap(0.0);
        self.swap = false;
        self.pressed = None;
    }

    fn open(&mut self, v: View, why: Reason) {
        if !self.cfg.enabled {
            return;
        }
        if self.phase == Phase::Open {
            self.go(v);
            self.reason = why;
            return;
        }
        if self.phase == Phase::Closed {
            // It grows from the resting notch, wherever its swell left it.
            self.content.snap(0.0);
        }
        self.phase = Phase::Open;
        self.reason = why;
        self.content.tune(self.motion.content.0, self.motion.content.1);
        self.shown = v.clone();
        self.want = v;
        self.swap = false;
        self.away_for = 0.0;
        self.content_wait = self.motion.content_delay;
        let (tw, th) = self.size_of(&self.shown);
        self.w.tune(self.motion.expand.0, self.motion.expand.1);
        self.h.tune(self.motion.expand.0, self.motion.expand.1);
        self.w.to(tw);
        self.h.to(th);
        self.seen_notifs = if self.shown == View::Page(Page::Notifs) { Instant::now() } else { self.seen_notifs };
        self.dirty = true;
    }

    /// Replaces what is shown: the old content fades, the island morphs, the new content appears.
    fn go(&mut self, v: View) {
        if self.want == v && !self.swap {
            return;
        }
        let (tw, th) = self.size_of(&v);
        let grows = tw * th > self.w.target * self.h.target;
        let (r, d) = if grows { self.motion.page } else { (self.motion.page.0 * 0.92, self.motion.page.1 + 0.04) };
        self.w.tune(r, d);
        self.h.tune(r, d);
        self.w.to(tw);
        self.h.to(th);
        self.want = v;
        self.swap = self.want != self.shown;
        if self.swap {
            // A page change is quicker than the first opening: the old page leaves while the size is already moving.
            self.content.tune(self.motion.content.0 * 0.62, 1.0);
            self.content.to(0.0);
        }
        self.dirty = true;
    }

    pub fn close(&mut self) {
        if self.phase != Phase::Open {
            return;
        }
        self.phase = Phase::Closing;
        self.w.tune(self.motion.collapse.0, self.motion.collapse.1);
        self.h.tune(self.motion.collapse.0, self.motion.collapse.1);
        self.w.to(PEEK.0);
        self.h.to(PEEK.1);
        self.content.to(0.0);
        self.swap = false;
        self.pressed = None;
        self.drag_active = false;
        self.dirty = true;
    }

    /// Size the given view wants, in logical units.
    pub fn size_of(&self, v: &View) -> (f32, f32) {
        let m = &self.model;
        match v {
            View::Page(Page::Home) => {
                // Top 16, [status 48 + 14], [player 44 + 14], navigation 44, bottom 18.
                let mut h = 16.0 + 44.0 + 18.0;
                if self.cfg.modules.status {
                    h += 62.0;
                }
                if self.cfg.modules.player && self.media_line().is_some() {
                    h += 58.0;
                }
                (400.0, h)
            }
            View::Page(Page::Player) => (420.0, 164.0),
            View::Page(Page::Files) => (404.0, 140.0 + 40.0 * m.xfers.len().min(3) as f32),
            View::Page(Page::Notifs) => (424.0, if m.notifs.is_empty() { 150.0 } else { 62.0 + 54.0 * m.notifs.len().min(4) as f32 }),
            View::Page(Page::Clipboard) => (404.0, 116.0 + 38.0 * m.clips.len().min(3) as f32),
            View::Page(Page::Controls) => {
                let n = control_keys(&self.cfg.controls, m.target_id().is_some_and(|id| m.adb.contains_key(&id))).len();
                (404.0, controls_top(n) + 66.0)
            }
            View::Call => (384.0, 92.0),
            View::Offer => (384.0, 136.0),
            View::Transfer(_) => (384.0, 92.0),
            View::Note => (if self.note.w > 0.0 { self.note.w } else { 372.0 }, 76.0),
            View::Drop => (364.0, 128.0),
        }
    }

    /// Is the pointer on the island (or in the trigger zone, which is where it came from)?
    fn pointer_near(&self) -> bool {
        if self.hot {
            return true;
        }
        let Some((x, y)) = self.pointer else { return false };
        let r = self.pill().inflate(10.0);
        r.contains(x, y) || R::new(r.x, 0.0, r.w, r.y + 1.0).contains(x, y)
    }

    fn pill(&self) -> R {
        let (w, h) = (self.w.value.max(8.0), self.h.value.max(8.0));
        R::new((CANVAS_W - w) / 2.0, 0.0, w, h)
    }

    fn use_pc(&self) -> bool {
        pick_pc(&self.model, self.player_pc)
    }

    /// The media shown by the player screen and by the home screen's mini player.
    fn media_line(&self) -> Option<(&super::model::Media, bool)> {
        pick_media(&self.model, self.player_pc)
    }

    // ------------------------------------------------------------------------------------------------ time

    pub fn update(&mut self, dt: f32) -> Status {
        self.clock += dt as f64;
        let dt = dt.min(0.1);
        if let Some((i, left)) = self.copied {
            if left - dt <= 0.0 {
                self.copied = None;
            } else {
                self.copied = Some((i, left - dt));
            }
            self.dirty = true;
        }
        self.watch_media();
        if self.phase == Phase::Closed {
            if !self.cfg.enabled || !self.rest {
                return Status { visible: false, animating: false };
            }
            // Under the pointer the notch swells a little: the place that opens it answers.
            let live = self.live();
            let (tw, th) = match (live.is_some(), self.hot) {
                (true, hot) => (LIVE.0 + if hot { 14.0 } else { 0.0 }, LIVE.1 + if hot { 2.0 } else { 0.0 }),
                (false, true) => (PEEK.0 + 20.0, PEEK.1 + 4.0),
                (false, false) => PEEK,
            };
            self.w.to(tw);
            self.h.to(th);
            self.w.step(dt);
            self.h.step(dt);
            let moving = !self.w.settled(0.05) || !self.h.settled(0.05);
            // The equalizer moves at 15 frames a second: alive, and cheap while the island is closed.
            if live == Some(Live::Media) && (self.clock * 15.0).floor() != ((self.clock - dt as f64) * 15.0).floor() {
                self.dirty = true;
            }
            return Status { visible: true, animating: moving || self.dirty };
        }
        if !self.cfg.enabled {
            self.snap_closed();
            return Status { visible: false, animating: false };
        }
        self.model.tidy(Instant::now());
        // The screen that was showing something that no longer exists gives way.
        self.validate();
        // Closing rules.
        if self.phase == Phase::Open {
            let near = self.pointer_near();
            match self.reason {
                Reason::Hover | Reason::Key => {
                    if near {
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
                        if matches!(self.shown, View::Page(_) | View::Note) {
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
                        if self.life <= 0.0 && self.shown == View::Drop && self.want == View::Drop {
                            self.close();
                        }
                    }
                    if self.drag_over || near {
                        self.life = self.life.max(0.6);
                    }
                }
            }
        }
        // Content swap.
        if self.swap && self.content.value < 0.12 {
            self.shown = self.want.clone();
            self.swap = false;
            self.content_wait = self.motion.content_delay * 0.4;
            if self.shown == View::Page(Page::Notifs) {
                self.seen_notifs = Instant::now();
            }
        }
        if self.phase == Phase::Open && !self.swap {
            if self.content_wait > 0.0 {
                self.content_wait -= dt;
            } else {
                self.content.to(1.0);
            }
        }
        // The size follows what is shown (lists grow and shrink while the island is open).
        if self.phase == Phase::Open && !self.swap {
            let (tw, th) = self.size_of(&self.shown);
            if (tw - self.w.target).abs() > 0.5 || (th - self.h.target).abs() > 0.5 {
                self.w.to(tw);
                self.h.to(th);
            }
        }
        self.w.step(dt);
        self.h.step(dt);
        self.content.step(dt);
        let moving = !self.w.settled(0.05) || !self.h.settled(0.05) || !self.content.settled(0.002);
        if moving {
            self.dirty = true;
        }
        if self.phase == Phase::Closing && !moving {
            self.snap_closed();
            // The resting notch stays: this frame draws it (hiding here left the window empty until the next event).
            self.dirty = true;
            return Status { visible: self.rest, animating: true };
        }
        // The clock of the player and the progress bars.
        if self.phase == Phase::Open && matches!(self.shown, View::Page(Page::Player) | View::Page(Page::Home) | View::Transfer(_)) && self.clock.fract() < dt as f64 {
            self.dirty = true;
        }
        Status { visible: true, animating: moving || self.dirty }
    }

    fn validate(&mut self) {
        // The call that held back a file offer is over: show the offer now.
        if self.phase == Phase::Open && self.want == View::Call && self.model.call().is_none() && !self.model.offers.is_empty() && self.cfg.modules.incoming {
            self.go(View::Offer);
            self.reason = Reason::Event(None);
            self.life = 0.0;
        }
        // A transfer that ended while another view was on screen leaves the card without an end: let it go.
        if let (Phase::Open, View::Transfer(id), Reason::Event(None)) = (self.phase, &self.shown, self.reason) {
            let x = self.model.xfers.iter().find(|x| &x.id == id);
            if !x.is_some_and(|x| x.state == XState::Running) {
                self.life = if x.is_some_and(|x| matches!(x.state, XState::Failed(_))) { 4.0 } else { 2.4 };
                self.reason = Reason::Event(Some(self.life));
            }
        }
        let gone = match self.shown {
            View::Call => self.want == View::Call && self.model.call().is_none() && self.life <= 0.0 && self.reason == Reason::Event(None),
            View::Offer => self.model.offers.is_empty() && self.phase == Phase::Open && self.reason == Reason::Event(None),
            _ => false,
        };
        if gone && self.phase == Phase::Open {
            self.close();
        }
        // An offer that was answered elsewhere, or a call that ended, must not leave a dead card.
        if self.phase == Phase::Open && self.shown == View::Offer && self.model.offers.is_empty() && !self.swap {
            self.close();
        }
        if self.phase == Phase::Open && self.shown == View::Call && self.want == View::Call && self.model.call().is_none() && !matches!(self.reason, Reason::Event(Some(_))) {
            self.reason = Reason::Event(Some(0.8));
            self.life = 0.8;
        }
    }

    pub fn mark_dirty(&mut self) {
        self.dirty = true;
    }

    /// Gives back the memory of the drawing layer (the island has been closed for a while).
    pub fn release_buffers(&mut self) {
        self.layer = None;
        self.shadow = None;
    }

    /// A short message from the executor (a file that could not be sent, say).
    pub fn flash(&mut self, good: bool, title: String, text: String) {
        let note = Note { icon: Some(if good { Icon::Check } else { Icon::Close }), title, text, good, w: 0.0, img: None };
        // Even with automatic opening off, the answer to something the user just did is shown.
        let keep = self.cfg.auto_expand;
        self.cfg.auto_expand = true;
        self.show_note_for(note, if good { 2.5 } else { 4.5 });
        self.cfg.auto_expand = keep;
    }

    /// True once after something changed, so the host draws only when needed.
    pub fn take_dirty(&mut self) -> bool {
        std::mem::take(&mut self.dirty)
    }

    // ------------------------------------------------------------------------------------------------ drawing

    fn palette(&self) -> Pal {
        let bg = self.cfg.background();
        let light = luma(bg) > 0.55;
        let fg: Rgb = if light { [24, 24, 28] } else { [255, 255, 255] };
        let accent = self.cfg.accent_rgb();
        // Text on the accent colour: dark on light accents, white on dark ones.
        let on_accent: Rgb = if luma(accent) > 0.6 { [10, 10, 12] } else { [255, 255, 255] };
        Pal { bg, fg, accent, on_accent, chip: mix(bg, fg, 0.11), chip_hi: mix(bg, fg, 0.20), light }
    }

    #[cfg(test)]
    pub fn new_canvas(&self, k: f32) -> Canvas {
        Canvas::new(CANVAS_W, CANVAS_H, k)
    }

    /// Draws the current frame into `cv` (cleared first).
    pub fn render(&mut self, cv: &mut Canvas) {
        cv.clear();
        self.hits.clear();
        if self.phase == Phase::Closed && !self.rest {
            return;
        }
        let pal = self.palette();
        let pill = self.pill();
        // Bottom corners grow with the island (14 on a slim bar, 32 on a full card); the ears follow them.
        let radius = (pill.h / 2.0).min(10.0 + pill.h * 0.16).min(MAX_RADIUS);
        let shape = super::gfx::notch(pill, radius, radius * 0.68);
        let mut layer = match self.layer.take() {
            Some(l) if l.width_px() == cv.width_px() && l.height_px() == cv.height_px() => l,
            _ => Canvas { pm: Pixmap::new(cv.width_px(), cv.height_px()).expect("layer"), k: cv.k },
        };
        // Shadow: a blurred copy of the shape, a little lower than the island. Made at 1/4 scale (16x fewer pixels to
        // blur, and a soft shadow loses nothing) and stretched back.
        let sk = cv.k / SHADOW_DIV;
        let mut shadow = match self.shadow.take() {
            Some(s) if (s.k - sk).abs() < 1e-4 => s,
            _ => Canvas::new(CANVAS_W, CANVAS_H, sk),
        };
        shadow.clear();
        shadow.squircle(R::new(pill.x + 2.0, pill.y + 7.0, pill.w - 4.0, pill.h - 2.0), radius, color([0, 0, 0], if pal.light { 0.30 } else { 0.55 }), None);
        shadow.blur(pill.inflate(26.0), 16.0);
        cv.shadow_from(&shadow.pm, SHADOW_DIV, pill.inflate(26.0));
        self.shadow = Some(shadow);
        // While a file is being carried, the pixels above and around the island are made (all but) invisible but
        // solid for hit testing, so the system's drag-and-drop reaches the window even at the very edge of the screen.
        if matches!(self.want, View::Drop) {
            cv.squircle(R::new(pill.x - 40.0, 0.0, pill.w + 80.0, pill.bottom() + 18.0), 20.0, color([0, 0, 0], 0.012), None);
        }
        // Body, hanging from the top edge, and a hairline rim so the black does not melt into a dark window.
        if let Some(p) = &shape {
            cv.fill_path(p, color(pal.bg, 1.0), None);
            cv.stroke_path(p, color(pal.fg, 0.10), 0.9, None);
        }
        if self.phase == Phase::Closed {
            // The compact island's content appears as the notch reaches its width.
            if let Some(l) = self.live() {
                let a = ((pill.w - PEEK.0) / (LIVE.0 - PEEK.0)).clamp(0.0, 1.0).powi(2);
                if a > 0.02 {
                    let mut d = Draw { cv, fonts: &mut self.fonts, hits: &mut self.hits, pal: &pal, pointer: None, pressed: None };
                    draw_live(&mut d, &self.model, self.player_pc, l, pill, a, self.clock);
                }
            }
            self.layer = Some(layer);
            return;
        }
        // Content, laid out at the final size and revealed by the clip.
        let p = self.content.value.clamp(0.0, 1.0);
        let view = self.shown.clone();
        let (vw, vh) = self.size_of(&view);
        if p >= 0.999 && (pill.w - vw).abs() < 0.5 && (pill.h - vh).abs() < 0.5 {
            // At rest (hover, a clock tick) the content is drawn straight in: no layer to clear, mask and copy.
            self.draw_view(cv, &pal, &view, ((CANVAS_W - vw) / 2.0, 0.0));
        } else if p > 0.004 {
            layer.clear();
            let origin = ((CANVAS_W - vw) / 2.0, 0.0);
            self.draw_view(&mut layer, &pal, &view, origin);
            let scale = self.motion.content_scale + (1.0 - self.motion.content_scale) * p;
            let mask = shape.as_ref().and_then(|p| cv.mask_path(p));
            // The content reaches full opacity before the island finishes growing.
            let alpha = (p * 1.35 - 0.1).clamp(0.0, 1.0);
            cv.blit(&layer.pm, alpha, scale, pill.cx(), origin.1 + vh / 2.0, mask.as_ref());
        }
        self.layer = Some(layer);
    }

    fn draw_view(&mut self, cv: &mut Canvas, pal: &Pal, view: &View, o: (f32, f32)) {
        let (vw, vh) = self.size_of(view);
        let body = R::new(o.0, o.1, vw, vh);
        let media = pick_media(&self.model, self.player_pc);
        let sources = (self.model.pc_media.as_ref().is_some_and(|m| !m.is_empty()), self.model.phone_media.as_ref().is_some_and(|m| !m.is_empty()));
        let mut d = Draw { cv, fonts: &mut self.fonts, hits: &mut self.hits, pal, pointer: self.pointer, pressed: self.pressed };
        match view {
            View::Page(Page::Home) => draw_home(&mut d, &self.model, &self.cfg, body, media, self.seen_notifs),
            View::Page(Page::Player) => draw_player(&mut d, body, media, sources),
            View::Page(Page::Files) => draw_files(&mut d, &self.model, body),
            View::Page(Page::Notifs) => draw_notifs(&mut d, &self.model, body),
            View::Page(Page::Clipboard) => draw_clipboard(&mut d, &self.model, body, self.copied),
            View::Page(Page::Controls) => draw_controls(&mut d, &self.model, &self.cfg.controls, body, self.clock < self.wifi_confirm),
            View::Call => draw_call(&mut d, &self.model, body),
            View::Offer => draw_offer(&mut d, &self.model, body),
            View::Transfer(id) => draw_transfer(&mut d, &self.model, body, id),
            View::Note => draw_note(&mut d, &self.note, body),
            View::Drop => draw_drop(&mut d, &self.model, body, self.drag_over),
        }
    }
}

/// Whether the computer's player (rather than the phone's) is the one to show.
fn pick_pc(m: &Model, pref: Option<bool>) -> bool {
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

fn pick_media(m: &Model, pref: Option<bool>) -> Option<(&super::model::Media, bool)> {
    let pc = m.pc_media.as_ref().filter(|x| !x.is_empty());
    let ph = m.phone_media.as_ref().filter(|x| !x.is_empty());
    if pick_pc(m, pref) {
        pc.map(|x| (x, true)).or(ph.map(|x| (x, false)))
    } else {
        ph.map(|x| (x, false)).or(pc.map(|x| (x, true)))
    }
}

// ---------------------------------------------------------------------------------------------------------
// Drawing helpers

struct Pal {
    bg: Rgb,
    fg: Rgb,
    accent: Rgb,
    on_accent: Rgb,
    chip: Rgb,
    chip_hi: Rgb,
    light: bool,
}

struct Draw<'a> {
    cv: &'a mut Canvas,
    fonts: &'a mut Fonts,
    hits: &'a mut Vec<Hit>,
    pal: &'a Pal,
    pointer: Option<(f32, f32)>,
    pressed: Option<usize>,
}

impl Draw<'_> {
    fn text(&mut self, s: &str, x: f32, y: f32, size: f32, w: Weight, alpha: f32) -> f32 {
        let fg = self.pal.fg;
        self.cv.text(self.fonts, s, x, y, size, w, fg, alpha)
    }

    fn text_in(&mut self, s: &str, x: f32, y: f32, max: f32, size: f32, w: Weight, alpha: f32) {
        let fit = self.fonts.fit(s, size, w, max);
        self.text(&fit, x, y, size, w, alpha);
    }

    fn hot(&self, r: R) -> bool {
        self.pointer.is_some_and(|(x, y)| r.contains(x, y))
    }

    fn is_down(&self, r: R) -> bool {
        self.pressed.and_then(|i| self.hits.get(i)).is_some_and(|h| h.r == r)
    }

    fn add(&mut self, r: R, act: Act) {
        self.hits.push(Hit { r, act });
    }

    /// A round icon button.
    fn round(&mut self, c: (f32, f32), size: f32, ic: Icon, act: Act, bg: Option<Rgb>, fg: Rgb) {
        let r = R::new(c.0 - size / 2.0, c.1 - size / 2.0, size, size);
        let down = self.is_down(r);
        let base = bg.unwrap_or(self.pal.chip);
        let fill = if down { mix(base, self.pal.fg, 0.30) } else if self.hot(r) { mix(base, self.pal.fg, if bg.is_some() { 0.18 } else { 0.10 }) } else { base };
        if bg.is_some() || self.hot(r) || down {
            self.cv.circle(c.0, c.1, size / 2.0 - if down { 1.0 } else { 0.0 }, color(fill, 1.0), None);
        } else {
            self.cv.circle(c.0, c.1, size / 2.0, color(fill, 1.0), None);
        }
        icon(self.cv, ic, c.0, c.1, size * 0.5, color(fg, 1.0), None);
        self.add(r, act);
    }

    /// A text button (pill).
    fn pill(&mut self, r: R, label: &str, act: Act, bg: Rgb, fg: Rgb) {
        let down = self.is_down(r);
        let fill = if down { mix(bg, self.pal.fg, 0.28) } else if self.hot(r) { mix(bg, self.pal.fg, 0.16) } else { bg };
        self.cv.squircle(r, r.h / 2.0, color(fill, 1.0), None);
        let label = self.fonts.fit(label, 13.0, Weight::Medium, r.w - 14.0);
        let w = self.fonts.measure(&label, 13.0, Weight::Medium);
        self.cv.text(self.fonts, &label, r.cx() - w / 2.0, r.cy() + 4.6, 13.0, Weight::Medium, fg, 1.0);
        self.add(r, act);
    }

    fn bar(&mut self, r: R, f: f32, c: Rgb) {
        self.cv.squircle(r, r.h / 2.0, color(self.pal.fg, 0.16), None);
        let w = (r.w * f.clamp(0.0, 1.0)).max(if f > 0.0 { r.h } else { 0.0 });
        if w > 0.0 {
            self.cv.squircle(R::new(r.x, r.y, w, r.h), r.h / 2.0, color(c, 1.0), None);
        }
    }

    fn avatar(&mut self, c: (f32, f32), size: f32, label: &str) {
        self.cv.circle(c.0, c.1, size / 2.0, color(self.pal.chip_hi, 1.0), None);
        let ch = label.chars().next().map(|c| c.to_uppercase().to_string()).unwrap_or_else(|| "?".into());
        let w = self.fonts.measure(&ch, size * 0.42, Weight::Bold);
        self.text(&ch, c.0 - w / 2.0, c.1 + size * 0.15, size * 0.42, Weight::Bold, 1.0);
    }
}

fn header(d: &mut Draw, body: R, title: &str) {
    d.text(title, body.x + PAD, body.y + 31.0, 15.5, Weight::Bold, 1.0);
}

fn back(d: &mut Draw, body: R) {
    d.round((body.right() - PAD - 15.0, body.y + 27.0), 30.0, Icon::Back, Act::Go(Page::Home), None, d.pal.fg);
}

fn draw_home(d: &mut Draw, m: &Model, cfg: &IslandConfig, body: R, media: Option<(&super::model::Media, bool)>, seen: Instant) {
    let mut y = body.y + 16.0;
    if cfg.modules.status {
        // Row of 48: the phone, its name and state, the battery; everything on the row's centre line.
        let mid = y + 24.0;
        let c = (body.x + PAD + 22.0, mid);
        match m.target().and_then(|p| m.devices.get(&p.id)) {
            // The phone itself, whole (no crop), as tall as the row.
            Some(img) => {
                let w = (48.0 * img.w as f32 / img.h as f32).min(44.0);
                let h = w * img.h as f32 / img.w as f32;
                d.cv.image(img, R::new(c.0 - w / 2.0, c.1 - h / 2.0, w, h), 6.0, 1.0, None);
            }
            None => {
                d.cv.circle(c.0, c.1, 22.0, color(d.pal.chip, 1.0), None);
                icon(d.cv, Icon::Phone, c.0, c.1, 22.0, color(d.pal.fg, 1.0), None);
            }
        }
        d.add(R::new(body.x + PAD, y, body.w - 2.0 * PAD - 84.0, 48.0), Act::Device);
        let tx = body.x + PAD + 58.0;
        match m.target() {
            Some(p) => {
                d.text_in(&p.name, tx, mid - 3.0, body.w - 2.0 * PAD - 58.0 - 92.0, 15.5, Weight::Bold, 1.0);
                let multi = m.phones().len() > 1;
                let sub = if multi { t("Conectado · toca para cambiar", "Connected · tap to switch") } else { t("Conectado", "Connected") };
                d.text(sub, tx, mid + 15.0, 12.5, Weight::Regular, 0.6);
                if let Some(i) = m.info.get(&p.id).filter(|i| i.battery >= 0) {
                    let bx = body.right() - PAD - 74.0;
                    let level = i.battery.clamp(0, 100) as f32 / 100.0;
                    icon(d.cv, Icon::Battery, bx + 12.0, mid, 24.0, color(d.pal.fg, 0.9), None);
                    let col = if i.charging { SUCCESS } else if level < 0.2 { DANGER } else { d.pal.fg };
                    d.cv.squircle(R::new(bx + 4.1, mid - 3.1, 10.8 * level.max(0.04), 6.4), 1.6, color(col, 1.0), None);
                    if i.charging {
                        icon(d.cv, Icon::Bolt, bx + 10.7, mid, 10.0, color(d.pal.bg, 1.0), None);
                    }
                    d.text(&format!("{}%", i.battery), bx + 30.0, mid + 5.0, 13.5, Weight::Medium, 1.0);
                }
            }
            None => {
                d.text(t("Sin teléfono conectado", "No phone connected"), tx, mid - 3.0, 15.5, Weight::Bold, 1.0);
                d.text(t("Abre Alero para vincular uno", "Open Alero to pair one"), tx, mid + 15.0, 12.5, Weight::Regular, 0.6);
            }
        }
        y += 62.0;
    }
    if let (true, Some((md, pc))) = (cfg.modules.player, media) {
        let r = R::new(body.x + PAD, y, body.w - 2.0 * PAD, 44.0);
        d.cv.squircle(r, 22.0, color(d.pal.chip, 1.0), None);
        d.add(r.inset(0.0, 0.0, 48.0, 0.0), Act::Go(Page::Player));
        match &md.art {
            Some(img) => d.cv.image(img, R::new(r.x + 7.0, r.y + 7.0, 30.0, 30.0), 8.0, 1.0, None),
            None => icon(d.cv, Icon::Music, r.x + 22.0, r.cy(), 18.0, color(d.pal.accent, 1.0), None),
        }
        let label = if md.artist.is_empty() { md.title.clone() } else { format!("{} — {}", md.title, md.artist) };
        d.text_in(&label, r.x + 47.0, r.cy() + 4.8, r.w - 47.0 - 54.0, 13.5, Weight::Medium, 1.0);
        let toggle = if pc { Act::PcMedia("toggle") } else { Act::PhoneMedia("toggle") };
        d.round((r.right() - 24.0, r.cy()), 34.0, if md.playing { Icon::Pause } else { Icon::Play }, toggle, None, d.pal.fg);
    }
    // Navigation.
    let mut items: Vec<(Icon, Page, usize)> = Vec::new();
    if cfg.modules.player {
        items.push((Icon::Music, Page::Player, 0));
    }
    if cfg.modules.send || cfg.modules.incoming {
        items.push((Icon::Send, Page::Files, 0));
    }
    if cfg.modules.notifications {
        items.push((Icon::Bell, Page::Notifs, m.unread(seen)));
    }
    if cfg.modules.clipboard {
        items.push((Icon::Clipboard, Page::Clipboard, 0));
    }
    if cfg.modules.controls {
        items.push((Icon::Sliders, Page::Controls, 0));
    }
    let n = items.len() + 1;
    let slot = (body.w - 2.0 * PAD) / n as f32;
    let cy = body.bottom() - 18.0 - 22.0;
    for (i, (ic, page, badge)) in items.into_iter().enumerate() {
        let cx = body.x + PAD + slot * (i as f32 + 0.5);
        d.round((cx, cy), 44.0, ic, Act::Go(page), None, d.pal.fg);
        if badge > 0 {
            d.cv.circle(cx + 14.0, cy - 14.0, 8.0, color(d.pal.accent, 1.0), None);
            let s = badge.min(9).to_string();
            let w = d.fonts.measure(&s, 10.5, Weight::Bold);
            let oa = d.pal.on_accent;
            d.cv.text(d.fonts, &s, cx + 14.0 - w / 2.0, cy - 10.4, 10.5, Weight::Bold, oa, 1.0);
        }
    }
    let cx = body.x + PAD + slot * (n as f32 - 0.5);
    let accent = d.pal.accent;
    let on = d.pal.on_accent;
    d.round((cx, cy), 44.0, Icon::Phone, Act::OpenApp, Some(accent), on);
}

fn draw_player(d: &mut Draw, body: R, media: Option<(&super::model::Media, bool)>, (has_pc, has_phone): (bool, bool)) {
    back(d, body);
    let Some((md, is_pc)) = media else {
        d.text(t("Reproductor", "Player"), body.x + PAD, body.y + 31.0, 15.5, Weight::Bold, 1.0);
        icon(d.cv, Icon::Music, body.cx(), body.y + 78.0, 34.0, color(d.pal.fg, 0.35), None);
        d.cv.text_centered(d.fonts, t("Nada se está reproduciendo", "Nothing is playing"), body.cx(), body.y + 122.0, 13.5, Weight::Medium, d.pal.fg, 0.7);
        return;
    };
    let art = R::new(body.x + PAD, body.y + 18.0, 76.0, 76.0);
    match &md.art {
        Some(img) => d.cv.image(img, art, 16.0, 1.0, None),
        None => {
            d.cv.squircle(art, 16.0, color(d.pal.chip_hi, 1.0), None);
            icon(d.cv, Icon::Music, art.cx(), art.cy(), 30.0, color(d.pal.fg, 0.6), None);
        }
    }
    let tx = art.right() + 14.0;
    let tw = body.right() - PAD - 40.0 - tx;
    d.text_in(&md.title, tx, body.y + 40.0, tw, 15.5, Weight::Bold, 1.0);
    if !md.artist.is_empty() {
        d.text_in(&md.artist, tx, body.y + 59.0, tw, 13.0, Weight::Regular, 0.62);
    }
    // Which player: this computer or the phone. The other one can be picked when it has something.
    let mut x = tx;
    for (pc, label, has) in [(true, t("Este equipo", "This computer"), has_pc), (false, t("Teléfono", "Phone"), has_phone)] {
        let r = R::new(x, body.y + 68.0, d.fonts.measure(label, 12.0, Weight::Medium) + 20.0, 22.0);
        let on = pc == is_pc;
        let (bg, fg) = if on { (d.pal.accent, d.pal.on_accent) } else { (if d.hot(r) && has { d.pal.chip_hi } else { d.pal.chip }, d.pal.fg) };
        d.cv.squircle(r, 11.0, color(bg, 1.0), None);
        d.cv.text(d.fonts, label, r.x + 10.0, r.y + 15.4, 12.0, Weight::Medium, fg, if on || has { 1.0 } else { 0.4 });
        if !on && has {
            d.add(r, Act::Source);
        }
        x = r.right() + 6.0;
    }
    // Progress.
    let bar = R::new(body.x + PAD, body.y + 106.0, body.w - 2.0 * PAD, 4.0);
    let pos = md.position_now();
    let f = if md.duration_ms > 0 { pos as f32 / md.duration_ms as f32 } else { 0.0 };
    let accent = d.pal.accent;
    d.bar(bar, f, accent);
    if md.duration_ms > 0 {
        d.text(&fmt_time(pos), bar.x, bar.y + 20.0, 12.5, Weight::Regular, 0.55);
        let end = fmt_time(md.duration_ms);
        let w = d.fonts.measure(&end, 12.5, Weight::Regular);
        d.text(&end, bar.right() - w, bar.y + 20.0, 12.5, Weight::Regular, 0.55);
    }
    // Controls, centred.
    let cy = body.y + 136.0;
    let (prev, toggle, next) = if is_pc { (Act::PcMedia("prev"), Act::PcMedia("toggle"), Act::PcMedia("next")) } else { (Act::PhoneMedia("prev"), Act::PhoneMedia("toggle"), Act::PhoneMedia("next")) };
    let fg = d.pal.fg;
    let bg = d.pal.bg;
    d.round((body.cx() - 62.0, cy), 30.0, Icon::Prev, prev, Some(bg), fg);
    d.round((body.cx(), cy), 36.0, if md.playing { Icon::Pause } else { Icon::Play }, toggle, Some(fg), bg);
    d.round((body.cx() + 62.0, cy), 30.0, Icon::Next, next, Some(bg), fg);
}

fn draw_files(d: &mut Draw, m: &Model, body: R) {
    back(d, body);
    header(d, body, t("Enviar archivos", "Send files"));
    let zone = R::new(body.x + PAD, body.y + 48.0, body.w - 2.0 * PAD, 70.0);
    dashed(d, zone, d.pal.fg, 0.28);
    icon(d.cv, Icon::Send, zone.x + 34.0, zone.cy(), 26.0, color(d.pal.accent, 1.0), None);
    match m.target() {
        Some(p) => {
            d.text(t("Arrastra archivos hasta aquí", "Drag files here"), zone.x + 62.0, zone.cy() - 2.0, 13.5, Weight::Medium, 1.0);
            let sub = format!("{} {}", t("Se envían a", "Sent to"), p.name);
            d.text_in(&sub, zone.x + 62.0, zone.cy() + 16.0, zone.w - 76.0, 12.5, Weight::Regular, 0.6);
        }
        None => {
            d.text(t("Conecta un teléfono para enviar", "Connect a phone to send"), zone.x + 62.0, zone.cy() + 4.6, 13.5, Weight::Medium, 0.8);
        }
    }
    let mut y = zone.bottom() + 12.0;
    for x in m.xfers.iter().take(3) {
        draw_xfer_row(d, x, R::new(body.x + PAD, y, body.w - 2.0 * PAD, 34.0));
        y += 40.0;
    }
}

fn draw_xfer_row(d: &mut Draw, x: &super::model::Xfer, r: R) {
    let ic = match (&x.state, x.incoming) {
        (XState::Done, _) => Icon::Check,
        (XState::Failed(_), _) => Icon::Close,
        (_, true) => Icon::Download,
        _ => Icon::Send,
    };
    let col = match &x.state {
        XState::Done => SUCCESS,
        XState::Failed(_) => DANGER,
        _ => d.pal.fg,
    };
    icon(d.cv, ic, r.x + 11.0, r.cy(), 18.0, color(col, 1.0), None);
    d.text_in(&x.name, r.x + 30.0, r.y + 13.0, r.w - 30.0 - 74.0, 13.0, Weight::Medium, 1.0);
    let right = match &x.state {
        XState::Running => format!("{}%", (x.fraction() * 100.0) as u32),
        XState::Done => t("Listo", "Done").to_string(),
        XState::Failed(_) => t("Falló", "Failed").to_string(),
    };
    let w = d.fonts.measure(&right, 12.0, Weight::Medium);
    d.text(&right, r.right() - w, r.y + 13.0, 12.0, Weight::Medium, 0.7);
    let accent = d.pal.accent;
    d.bar(R::new(r.x + 30.0, r.y + 22.0, r.w - 30.0, 4.0), x.fraction(), accent);
}

fn dashed(d: &mut Draw, r: R, c: Rgb, alpha: f32) {
    if let Some(p) = super::gfx::squircle(r, 18.0, 3.6) {
        let mut stroke = tiny_skia::Stroke { width: 1.4, line_cap: tiny_skia::LineCap::Round, ..tiny_skia::Stroke::default() };
        stroke.dash = tiny_skia::StrokeDash::new(vec![5.0, 5.0], 0.0);
        let tf = tiny_skia::Transform::from_scale(d.cv.k, d.cv.k);
        let mut paint = tiny_skia::Paint::default();
        paint.set_color(color(c, alpha));
        paint.anti_alias = true;
        d.cv.pm.stroke_path(&p, &paint, &stroke, tf, None);
    }
}

fn draw_notifs(d: &mut Draw, m: &Model, body: R) {
    back(d, body);
    header(d, body, t("Notificaciones", "Notifications"));
    if m.notifs.is_empty() {
        // Centred in the space under the header (48 .. bottom).
        let mid = body.y + 48.0 + (body.h - 48.0) / 2.0;
        icon(d.cv, Icon::Bell, body.cx(), mid - 14.0, 28.0, color(d.pal.fg, 0.3), None);
        d.cv.text_centered(d.fonts, t("Sin notificaciones", "No notifications"), body.cx(), mid + 22.0, 13.5, Weight::Medium, d.pal.fg, 0.6);
        return;
    }
    for (i, n) in m.notifs.iter().take(4).enumerate() {
        let r = R::new(body.x + 10.0, body.y + 52.0 + i as f32 * 54.0, body.w - 20.0, 50.0);
        let hot = d.hot(r);
        if hot {
            d.cv.squircle(r, 16.0, color(d.pal.chip, 1.0), None);
        }
        d.add(r.inset(0.0, 0.0, 40.0, 0.0), Act::OpenApp);
        let c = (r.x + 25.0, r.cy());
        match m.icon(&n.pkg) {
            Some(img) => d.cv.image(img, R::new(c.0 - 16.0, c.1 - 16.0, 32.0, 32.0), 9.0, 1.0, None),
            None => d.avatar(c, 32.0, &n.app),
        }
        let title = if n.title.is_empty() { n.app.clone() } else { n.title.clone() };
        d.text_in(&title, r.x + 50.0, r.y + 21.0, r.w - 50.0 - 44.0, 13.5, Weight::Bold, 1.0);
        d.text_in(&n.text, r.x + 50.0, r.y + 38.0, r.w - 50.0 - 44.0, 12.5, Weight::Regular, 0.65);
        if hot {
            let dismiss = R::new(r.right() - 36.0, r.cy() - 14.0, 28.0, 28.0);
            d.cv.circle(dismiss.cx(), dismiss.cy(), 14.0, color(d.pal.chip_hi, 1.0), None);
            icon(d.cv, Icon::Close, dismiss.cx(), dismiss.cy(), 12.0, color(d.pal.fg, 0.9), None);
            d.add(dismiss, Act::Dismiss(n.key.clone()));
        }
    }
}

fn draw_clipboard(d: &mut Draw, m: &Model, body: R, copied: Option<(usize, f32)>) {
    back(d, body);
    header(d, body, t("Portapapeles", "Clipboard"));
    let r = R::new(body.x + PAD, body.y + 48.0, body.w - 2.0 * PAD, 36.0);
    let sent = copied.is_some_and(|(i, _)| i == usize::MAX);
    let label = if sent { t("Enviado al teléfono", "Sent to the phone") } else { t("Enviar mi portapapeles al teléfono", "Send my clipboard to the phone") };
    let (accent, on) = (d.pal.accent, d.pal.on_accent);
    if m.target().is_some() {
        d.pill(r, label, Act::SendClip, accent, on);
    } else {
        d.pill(r, t("Sin teléfono conectado", "No phone connected"), Act::OpenApp, d.pal.chip, d.pal.fg);
    }
    for (i, c) in m.clips.iter().take(3).enumerate() {
        let row = R::new(body.x + PAD, body.y + 96.0 + i as f32 * 38.0, body.w - 2.0 * PAD, 34.0);
        let hot = d.hot(row);
        d.cv.squircle(row, 17.0, color(if hot { d.pal.chip_hi } else { d.pal.chip }, 1.0), None);
        let done = copied.is_some_and(|(k, _)| k == i);
        icon(d.cv, if done { Icon::Check } else { Icon::Copy }, row.x + 20.0, row.cy(), 16.0, color(if done { SUCCESS } else { d.pal.fg }, 1.0), None);
        d.text_in(&c.text,row.x + 38.0, row.cy() + 4.6, row.w - 52.0, 13.0, Weight::Regular, 0.95);
        d.add(row, Act::CopyClip(i));
    }
    if m.clips.is_empty() {
        d.cv.text_centered(d.fonts, t("Lo que copies en el teléfono aparece aquí", "What you copy on the phone shows up here"), body.cx(), body.bottom() - 22.0, 12.5, Weight::Regular, d.pal.fg, 0.5);
    }
}

fn tile(d: &mut Draw, r: R, ic: Icon, label: &str, on: bool, act: Act) {
    let (bg, fg) = if on { (d.pal.accent, d.pal.on_accent) } else { (d.pal.chip, d.pal.fg) };
    let down = d.is_down(r);
    let fill = if down { mix(bg, d.pal.fg, 0.25) } else if d.hot(r) { mix(bg, d.pal.fg, 0.14) } else { bg };
    d.cv.squircle(r, 20.0, color(fill, 1.0), None);
    icon(d.cv, ic, r.cx(), r.y + 22.0, 22.0, color(fg, 1.0), None);
    let label = d.fonts.fit(label, 12.0, Weight::Medium, r.w - 8.0);
    let w = d.fonts.measure(&label, 12.0, Weight::Medium);
    d.cv.text(d.fonts, &label, r.cx() - w / 2.0, r.y + 49.0, 12.0, Weight::Medium, fg, 1.0);
    d.add(r, act);
}

/// The controls the user chose (Ajustes), in their order; the adb ones only when adb reaches the phone.
fn control_keys(list: &str, adb: bool) -> Vec<&'static str> {
    list.split(',')
        .filter_map(|k| ["dnd", "torch", "find", "ringer", "wifi", "bt", "rotate", "lock"].into_iter().find(|x| *x == k.trim()))
        .filter(|k| adb || !matches!(*k, "wifi" | "bt" | "rotate" | "lock"))
        .collect()
}

/// Where the tiles end: rows of four 62-high tiles, 8 apart, under the 48 of the header.
fn controls_top(n: usize) -> f32 {
    let rows = n.div_ceil(4);
    if rows == 0 { 40.0 } else { 48.0 + rows as f32 * 70.0 - 8.0 }
}

fn draw_controls(d: &mut Draw, m: &Model, list: &str, body: R, wifi_confirm: bool) {
    back(d, body);
    header(d, body, t("Controles del teléfono", "Phone controls"));
    let Some(id) = m.target_id() else {
        d.cv.text_centered(d.fonts, t("Sin teléfono conectado", "No phone connected"), body.cx(), body.cy() + 14.0, 13.5, Weight::Medium, d.pal.fg, 0.6);
        return;
    };
    let st = m.phone.get(&id).cloned().unwrap_or_default();
    let radios = m.adb.get(&id).copied();
    let r = radios.unwrap_or_default();
    let keys = control_keys(list, radios.is_some());
    let tile_w = (body.w - 2.0 * PAD - 3.0 * 8.0) / 4.0;
    for (i, k) in keys.iter().enumerate() {
        let (ic, label, on, act) = match *k {
            "dnd" => (Icon::Moon, t("No molestar", "Do not disturb"), st.dnd, Act::Toggle("dnd")),
            "torch" => (Icon::Torch, t("Linterna", "Flashlight"), st.torch, Act::Toggle("torch")),
            "find" => (Icon::Find, t("Buscar", "Find"), st.finding, Act::Toggle("find")),
            "ringer" => {
                let label = match st.ringer.as_str() {
                    "silent" => t("Silencio", "Silent"),
                    "vibrate" => t("Vibrar", "Vibrate"),
                    _ => t("Sonido", "Sound"),
                };
                (Icon::Volume, label, st.ringer == "silent" || st.ringer == "vibrate", Act::Ringer)
            }
            "wifi" => (Icon::Wifi, if wifi_confirm { t("¿Apagar?", "Turn off?") } else { "Wi-Fi" }, r.wifi, Act::Adb("wifi")),
            "bt" => (Icon::Bluetooth, "Bluetooth", r.bt, Act::Adb("bt")),
            "rotate" => (Icon::Rotate, t("Rotación", "Rotation"), r.rotate, Act::Adb("rotate")),
            _ => (Icon::Lock, t("Bloquear", "Lock"), false, Act::Adb("lock")),
        };
        let (col, row) = (i % 4, i / 4);
        tile(d, R::new(body.x + PAD + col as f32 * (tile_w + 8.0), body.y + 48.0 + row as f32 * 70.0, tile_w, 62.0), ic, label, on, act);
    }
    let y = body.y + controls_top(keys.len()) + 22.0;
    // Media volume.
    let track = R::new(body.x + PAD + 30.0, y, body.w - 2.0 * PAD - 30.0, 10.0);
    icon(d.cv, Icon::Volume, body.x + PAD + 10.0, track.cy(), 20.0, color(d.pal.fg, 0.85), None);
    let f = st.media as f32 / st.media_max.max(1) as f32;
    let accent = d.pal.accent;
    d.bar(track, f, accent);
    d.cv.circle(track.x + (track.w * f.clamp(0.0, 1.0)).clamp(5.0, track.w - 5.0), track.cy(), 7.0, color(d.pal.fg, 1.0), None);
    d.add(track.inflate(8.0), Act::Volume);
    d.text(t("Volumen multimedia", "Media volume"), body.x + PAD + 30.0, track.bottom() + 17.0, 12.5, Weight::Regular, 0.5);
}

/// The closed island while something lives in it: left, what it is; right, its state. `a`: how much is shown.
fn draw_live(d: &mut Draw, m: &Model, pref: Option<bool>, l: Live, pill: R, a: f32, clock: f64) {
    let cy = pill.cy();
    match l {
        Live::Media => {
            let left = R::new(pill.x + 9.0, cy - 11.0, 22.0, 22.0);
            match pick_media(m, pref).and_then(|(md, _)| md.art.as_ref()) {
                Some(img) => d.cv.image(img, left, 6.0, a, None),
                None => icon(d.cv, Icon::Music, left.cx(), left.cy(), 16.0, color(d.pal.fg, a), None),
            }
            // Four bars that dance, each at its own pace.
            for i in 0..4 {
                let ph = clock as f32 * (5.0 + i as f32 * 1.3) + i as f32 * 1.7;
                let h = 5.0 + 11.0 * (0.5 + 0.5 * ph.sin()).powf(1.4);
                let x = pill.right() - 14.0 - (3 - i) as f32 * 5.5;
                d.cv.squircle(R::new(x - 1.5, cy - h / 2.0, 3.0, h), 1.5, color(d.pal.accent, a), None);
            }
        }
        Live::Charging(level) => {
            icon(d.cv, Icon::Bolt, pill.x + 20.0, cy, 18.0, color(SUCCESS, a), None);
            d.cv.text(d.fonts, t("Cargando", "Charging"), pill.x + 34.0, cy + 4.6, 13.0, Weight::Medium, d.pal.fg, a);
            if level >= 0 {
                let s = format!("{level}%");
                let w = d.fonts.measure(&s, 13.0, Weight::Bold);
                d.cv.text(d.fonts, &s, pill.right() - 14.0 - w, cy + 4.6, 13.0, Weight::Bold, SUCCESS, a);
            }
        }
    }
}

fn draw_call(d: &mut Draw, m: &Model, body: R) {
    let Some((_, c)) = m.call() else { return };
    let name = if c.name.is_empty() { t("Número desconocido", "Unknown number").to_string() } else { c.name.clone() };
    d.avatar((body.x + PAD + 24.0, body.cy()), 48.0, &name);
    let status = if c.ringing { t("Llamada entrante…", "Incoming call…") } else { t("En llamada", "On a call") };
    d.text_in(&name, body.x + PAD + 62.0, body.cy() - 2.0, body.w - 2.0 * PAD - 62.0 - 118.0, 15.5, Weight::Bold, 1.0);
    d.text(status, body.x + PAD + 62.0, body.cy() + 16.0, 12.5, Weight::Regular, 0.65);
    let y = body.cy();
    if c.ringing {
        d.round((body.right() - PAD - 76.0, y), 46.0, Icon::CallEnd, Act::Call("decline"), Some(DANGER), [255, 255, 255]);
        if c.can_answer {
            d.round((body.right() - PAD - 22.0, y), 46.0, Icon::Call, Act::Call("answer"), Some(SUCCESS), [255, 255, 255]);
        }
    } else {
        d.round((body.right() - PAD - 22.0, y), 46.0, Icon::CallEnd, Act::Call("hangup"), Some(DANGER), [255, 255, 255]);
    }
}

fn draw_offer(d: &mut Draw, m: &Model, body: R) {
    let Some(o) = m.offers.last() else { return };
    icon(d.cv, Icon::File, body.x + PAD + 14.0, body.y + 38.0, 28.0, color(d.pal.accent, 1.0), None);
    let sub = format!("{} {}", o.peer_name, t("quiere enviarte un archivo", "wants to send you a file"));
    d.text_in(&sub, body.x + PAD + 40.0, body.y + 31.0, body.w - 2.0 * PAD - 40.0, 12.5, Weight::Regular, 0.62);
    d.text_in(&o.name, body.x + PAD + 40.0, body.y + 50.0, body.w - 2.0 * PAD - 40.0, 15.0, Weight::Bold, 1.0);
    d.text(&fmt_size(o.size), body.x + PAD + 40.0, body.y + 66.0, 12.5, Weight::Regular, 0.6);
    let y = body.bottom() - 16.0 - 34.0;
    let half = (body.w - 2.0 * PAD - 10.0) / 2.0;
    let (chip, fg, accent, on) = (d.pal.chip, d.pal.fg, d.pal.accent, d.pal.on_accent);
    d.pill(R::new(body.x + PAD, y, half, 34.0), t("Rechazar", "Decline"), Act::Decline(o.id.clone()), chip, fg);
    d.pill(R::new(body.x + PAD + half + 10.0, y, half, 34.0), t("Aceptar", "Accept"), Act::Accept(o.id.clone()), accent, on);
}

fn draw_transfer(d: &mut Draw, m: &Model, body: R, id: &str) {
    let Some(x) = m.xfers.iter().find(|x| x.id == id) else { return };
    let ic = match (&x.state, x.incoming) {
        (XState::Done, _) => Icon::Check,
        (XState::Failed(_), _) => Icon::Close,
        (_, true) => Icon::Download,
        _ => Icon::Send,
    };
    let col = match &x.state {
        XState::Done => SUCCESS,
        XState::Failed(_) => DANGER,
        _ => d.pal.accent,
    };
    d.cv.circle(body.x + PAD + 20.0, body.cy(), 20.0, color(d.pal.chip, 1.0), None);
    icon(d.cv, ic, body.x + PAD + 20.0, body.cy(), 20.0, color(col, 1.0), None);
    let tx = body.x + PAD + 52.0;
    let tw = body.w - 2.0 * PAD - 52.0 - 38.0;
    d.text_in(&x.name, tx, body.y + 32.0, tw, 14.5, Weight::Bold, 1.0);
    let line = match &x.state {
        XState::Running => {
            let verb = if x.incoming { t("Recibiendo", "Receiving") } else { t("Enviando", "Sending") };
            if x.rate > 0 { format!("{verb} · {}/s", fmt_size(x.rate)) } else { verb.to_string() }
        }
        XState::Done => if x.incoming { t("Archivo recibido", "File received").into() } else { t("Enviado al teléfono", "Sent to the phone").into() },
        XState::Failed(msg) => if msg.is_empty() { t("No se pudo completar", "Could not finish").to_string() } else { msg.clone() },
    };
    d.text_in(&line, tx, body.y + 50.0, tw, 12.5, Weight::Regular, 0.62);
    let accent = col;
    d.bar(R::new(tx, body.y + 62.0, tw, 5.0), x.fraction(), accent);
    if x.state == XState::Running {
        d.round((body.right() - PAD - 15.0, body.cy()), 30.0, Icon::Close, Act::Cancel(x.id.clone()), None, d.pal.fg);
    }
}

fn draw_note(d: &mut Draw, n: &Note, body: R) {
    match &n.img {
        Some(img) => d.cv.image(img, R::new(body.x + PAD, body.cy() - 20.0, 40.0, 40.0), 11.0, 1.0, None),
        None => {
            d.cv.circle(body.x + PAD + 20.0, body.cy(), 20.0, color(d.pal.chip, 1.0), None);
            if let Some(ic) = n.icon {
                icon(d.cv, ic, body.x + PAD + 20.0, body.cy(), 20.0, color(if n.good { SUCCESS } else { d.pal.fg }, 1.0), None);
            }
        }
    }
    let tx = body.x + PAD + 52.0;
    let tw = body.w - PAD - tx + body.x;
    // Baselines that put the two lines (cap height to descender) on the icon's centre line.
    if n.text.is_empty() {
        d.text_in(&n.title, tx, body.cy() + 5.0, tw, 14.0, Weight::Bold, 1.0);
    } else {
        d.text_in(&n.title, tx, body.cy() - 4.5, tw, 14.0, Weight::Bold, 1.0);
        d.text_in(&n.text, tx, body.cy() + 13.5, tw, 12.5, Weight::Regular, 0.65);
    }
}

fn draw_drop(d: &mut Draw, m: &Model, body: R, over: bool) {
    let zone = body.inset(12.0, 12.0, 12.0, 12.0);
    let accent = d.pal.accent;
    if over {
        d.cv.squircle(zone, 24.0, color(accent, 0.16), None);
    }
    dashed(d, zone, if over { accent } else { d.pal.fg }, if over { 1.0 } else { 0.32 });
    let c = (zone.cx(), zone.y + 40.0);
    icon(d.cv, Icon::Send, c.0, c.1, if over { 34.0 } else { 30.0 }, color(if over { accent } else { d.pal.fg }, 1.0), None);
    let msg = match m.target() {
        Some(p) => format!("{} {}", t("Suelta para enviar a", "Drop to send to"), p.name),
        None => t("Conecta un teléfono para enviar archivos", "Connect a phone to send files").to_string(),
    };
    let fit = d.fonts.fit(&msg, 13.5, Weight::Medium, zone.w - 24.0);
    let w = d.fonts.measure(&fit, 13.5, Weight::Medium);
    d.text(&fit, zone.cx() - w / 2.0, zone.bottom() - 26.0, 13.5, Weight::Medium, 1.0);
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

    #[test]
    fn it_opens_after_the_delay_and_not_before() {
        let mut i = island();
        i.set_zone(true, false, 0.05);
        assert!(!i.is_open());
        i.set_zone(true, false, 0.10);
        assert!(i.is_open());
        assert_eq!(i.shown, View::Page(Page::Home));
    }

    #[test]
    fn passing_by_quickly_does_nothing() {
        let mut i = island();
        i.set_zone(true, false, 0.06);
        i.set_zone(false, false, 0.06);
        i.set_zone(true, false, 0.06);
        assert!(!i.is_open());
    }

    #[test]
    fn a_dropped_file_shows_its_progress_card() {
        let mut i = island();
        i.cfg.auto_expand = false;
        with_phone(&mut i);
        i.set_zone(true, true, 0.3);
        assert_eq!(i.want, View::Drop);
        i.dropped(vec![PathBuf::from("a.txt")]);
        assert!(matches!(i.take_cmds().as_slice(), [Cmd::SendFiles(_)]));
        let n = i.model.feed(&Event::TransferStarted { id: "s".into(), peer_id: "p".into(), peer_name: "Pixel 9a".into(), name: "a.txt".into(), size: 10, incoming: false });
        i.notices(n);
        assert_eq!(i.want, View::Transfer("s".into()));
        assert!(i.is_open());
    }

    #[test]
    fn adb_controls_show_with_adb_and_wifi_off_needs_a_second_tap() {
        let mut i = island();
        with_phone(&mut i);
        assert_eq!(i.size_of(&View::Page(Page::Controls)).1, 176.0);
        i.model.adb.insert("p".into(), super::super::adb::Radios { wifi: true, bt: false, rotate: false });
        assert!(i.size_of(&View::Page(Page::Controls)).1 > 176.0);
        i.act(Act::Adb("wifi"));
        assert!(i.take_cmds().is_empty());
        i.act(Act::Adb("wifi"));
        assert_eq!(i.take_cmds(), vec![Cmd::Adb { what: "wifi", on: false }]);
        i.act(Act::Adb("bt"));
        assert_eq!(i.take_cmds(), vec![Cmd::Adb { what: "bt", on: true }]);
    }

    #[test]
    fn music_and_charging_live_in_the_closed_island() {
        let mut i = island();
        with_phone(&mut i);
        run(&mut i, 0.5);
        assert!((i.w.value - PEEK.0).abs() < 1.0);
        i.model.pc_media = Some(super::super::model::Media { title: "T".into(), playing: true, speed: 1.0, ..Default::default() });
        run(&mut i, 1.0);
        assert_eq!(i.live(), Some(Live::Media));
        assert!((i.w.value - LIVE.0).abs() < 1.0);
        let n = i.model.feed(&Event::Message { peer_id: "p".into(), kind: "pb.x.info".into(), body: json!({"kind":"phone","battery":{"level":50,"charging":true}}) });
        i.notices(n);
        assert_eq!(i.live(), Some(Live::Charging(50)));
        run(&mut i, 4.5);
        // Both moments have passed: back to the slim notch while the music goes on.
        assert_eq!(i.live(), None);
        run(&mut i, 1.0);
        assert!((i.w.value - PEEK.0).abs() < 1.0);
        i.model.pc_media.as_mut().unwrap().title = "Next".into();
        run(&mut i, 0.1);
        assert_eq!(i.live(), Some(Live::Media));
        assert!(!i.is_open());
    }

    #[test]
    fn the_controls_are_the_ones_chosen_and_adb_ones_need_adb() {
        assert_eq!(control_keys("torch, wifi,nope,dnd", false), vec!["torch", "dnd"]);
        assert_eq!(control_keys("torch,wifi", true), vec!["torch", "wifi"]);
        assert_eq!(controls_top(0), 40.0);
        assert_eq!(controls_top(4), 110.0);
        assert_eq!(controls_top(5), 180.0);
    }

    #[test]
    fn it_closes_when_the_pointer_leaves() {
        let mut i = island();
        i.set_zone(true, false, 0.2);
        run(&mut i, 0.4);
        i.set_zone(false, false, 0.0);
        i.set_pointer(Some((10.0, 250.0)));
        run(&mut i, 1.0);
        assert!(!i.is_open());
        // Closed, only the resting notch is left; over a full-screen app not even that.
        assert!(i.update(0.01).visible);
        assert!((i.h.value - PEEK.1).abs() < 0.5);
        i.set_rest(false);
        assert!(!i.update(0.01).visible);
    }

    #[test]
    fn it_stays_while_the_pointer_is_on_it() {
        let mut i = island();
        i.set_zone(true, false, 0.2);
        run(&mut i, 0.5);
        let p = i.pill();
        i.set_zone(false, false, 0.0);
        i.set_pointer(Some((p.cx(), p.cy())));
        run(&mut i, 3.0);
        assert!(i.is_open());
    }

    #[test]
    fn a_ringing_call_opens_it_and_stays_until_answered() {
        let mut i = island();
        with_phone(&mut i);
        let n = i.model.feed(&Event::Message { peer_id: "p".into(), kind: "pb.x.call".into(), body: json!({"active":true,"ringing":true,"canAnswer":true,"name":"Mamá"}) });
        i.notices(n);
        assert!(i.is_open());
        assert_eq!(i.want, View::Call);
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
        // Draw once so the buttons exist, then press "Aceptar".
        let mut cv = i.new_canvas(1.0);
        i.render(&mut cv);
        let accept = i.hits.iter().find(|h| matches!(&h.act, Act::Accept(id) if id == "t1")).expect("accept button").r;
        i.set_pointer(Some((accept.cx(), accept.cy())));
        i.press();
        i.release();
        let cmds: Vec<Cmd> = i.take_cmds().into_iter().filter(|c| *c != Cmd::AskMedia).collect();
        assert_eq!(cmds, vec![Cmd::Respond { id: "t1".into(), accept: true }]);
    }

    #[test]
    fn a_notification_toast_goes_away_by_itself() {
        let mut i = island();
        with_phone(&mut i);
        let n = i.model.feed(&Event::Message { peer_id: "p".into(), kind: "pb.x.notif.posted".into(), body: json!({"key":"k","app":"WhatsApp","title":"Ana","text":"¿Vienes?"}) });
        i.notices(n);
        assert!(i.is_open());
        run(&mut i, 7.0);
        assert!(!i.is_open());
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
        assert!(!i.is_open());
    }

    #[test]
    fn disabled_means_it_never_opens() {
        let mut i = island();
        i.cfg.enabled = false;
        i.set_zone(true, false, 5.0);
        i.hotkey();
        assert!(!i.is_open());
    }

    #[test]
    fn holding_the_button_in_the_zone_shows_the_drop_target_and_a_drop_sends() {
        let mut i = island();
        with_phone(&mut i);
        i.set_zone(true, true, 0.3);
        assert!(i.is_open());
        assert_eq!(i.want, View::Drop);
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
        // No file ever arrives and the button is released.
        i.set_zone(false, false, 0.0);
        i.set_pointer(Some((10.0, 290.0)));
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
        i.set_pointer(Some((CANVAS_W / 2.0, 40.0)));
        run(&mut i, 0.5);
        let mut cv = i.new_canvas(1.0);
        i.render(&mut cv);
        let slider = i.hits.iter().find(|h| h.act == Act::Volume).unwrap().r;
        let inner = slider.inflate(-8.0);
        i.set_pointer(Some((inner.x + inner.w * 0.5, inner.cy())));
        i.press();
        let cmds = i.take_cmds();
        match &cmds[0] {
            Cmd::Phone { what: "volume", body } => assert!((6..=9).contains(&body["value"].as_i64().unwrap()), "{body}"),
            c => panic!("{c:?}"),
        }
    }

    #[test]
    fn a_transfer_card_that_missed_its_end_still_goes_away() {
        let mut i = island();
        with_phone(&mut i);
        i.open(View::Transfer("t".into()), Reason::Event(None));
        i.model.feed(&Event::TransferStarted { id: "t".into(), peer_id: "p".into(), peer_name: "Pixel 9a".into(), name: "a.zip".into(), size: 10, incoming: true });
        i.model.feed(&Event::TransferFinished { id: "t".into(), ok: true, code: String::new(), message: String::new(), path: "x".into() });
        run(&mut i, 4.0);
        assert!(!i.is_open());
    }

    #[test]
    fn a_file_offer_held_back_by_a_call_shows_when_the_call_ends() {
        let mut i = island();
        with_phone(&mut i);
        let n = i.model.feed(&Event::Message { peer_id: "p".into(), kind: "pb.x.call".into(), body: json!({"active":true,"ringing":true,"canAnswer":true,"name":"Mamá"}) });
        i.notices(n);
        let n = i.model.feed(&Event::TransferOffer { id: "t1".into(), peer_id: "p".into(), peer_name: "Pixel 9a".into(), name: "foto.jpg".into(), size: 3_000_000 });
        i.notices(n);
        assert_eq!(i.want, View::Call);
        let n = i.model.feed(&Event::Message { peer_id: "p".into(), kind: "pb.x.call".into(), body: json!({"active":false}) });
        i.notices(n);
        run(&mut i, 5.0);
        assert!(i.is_open());
        assert_eq!(i.shown, View::Offer);
    }

    #[test]
    fn the_last_slider_value_is_sent_on_release_and_small_wheel_steps_add_up() {
        let mut i = island();
        with_phone(&mut i);
        i.open(View::Page(Page::Controls), Reason::Hover);
        i.set_pointer(Some((CANVAS_W / 2.0, 40.0)));
        run(&mut i, 0.5);
        let mut cv = i.new_canvas(1.0);
        i.render(&mut cv);
        let slider = i.hits.iter().find(|h| h.act == Act::Volume).unwrap().r;
        i.set_pointer(Some((slider.x + slider.w * 0.2, slider.cy())));
        i.press();
        i.take_cmds();
        i.set_pointer(Some((slider.x + slider.w * 0.9, slider.cy())));
        i.moved();
        assert!(i.take_cmds().is_empty(), "throttled");
        i.release();
        assert!(matches!(i.take_cmds().as_slice(), [Cmd::Phone { what: "volume", .. }]));
        for _ in 0..9 {
            i.wheel(0.1);
        }
        assert!(i.take_cmds().is_empty());
        i.wheel(0.2);
        assert_eq!(i.take_cmds().len(), 1);
    }

    #[test]
    fn sizes_are_inside_the_canvas_with_room_for_the_bounce() {
        let mut i = island();
        with_phone(&mut i);
        for n in 0..12 {
            i.model.feed(&Event::Message { peer_id: "p".into(), kind: "pb.x.notif.posted".into(), body: json!({"key": format!("{n}"), "app":"A","title":"B","text":"C"}) });
            i.model.feed(&Event::Message { peer_id: "p".into(), kind: "pb.x.clip".into(), body: json!({"text": format!("c{n}")}) });
        }
        for v in [View::Page(Page::Home), View::Page(Page::Player), View::Page(Page::Files), View::Page(Page::Notifs), View::Page(Page::Clipboard), View::Page(Page::Controls), View::Call, View::Offer, View::Note, View::Drop] {
            let (w, h) = i.size_of(&v);
            assert!(w * 1.08 <= CANVAS_W && h * 1.08 + 10.0 + 20.0 <= CANVAS_H, "{v:?} {w}x{h}");
        }
    }

    /// Draws every screen to PNG files for a visual check: `ISLAND_PNG_DIR=/tmp/x cargo test gallery`.
    #[test]
    fn gallery() {
        let Ok(dir) = std::env::var("ISLAND_PNG_DIR") else { return };
        let k = 2.0;
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
            for (name, view) in &views {
                let mut cfg = IslandConfig::default();
                cfg.animation = "off".into();
                cfg.color = colour.into();
                let mut i = Island::new(cfg);
                with_phone(&mut i);
                for (n, (app, title, text)) in [("WhatsApp", "Ana", "¿Vienes a cenar hoy? Te guardé un lugar"), ("Gmail", "Banco", "Tu estado de cuenta está listo"), ("Telegram", "Edwin", "ya lo subí al repo 👍")].iter().enumerate() {
                    i.model.feed(&Event::Message { peer_id: "p".into(), kind: "pb.x.notif.posted".into(), body: json!({"key": format!("k{n}"), "app": app, "title": title, "text": text}) });
                }
                for c in ["https://github.com/Alero-Team/Alero", "Reunión mañana 10:00"] {
                    i.model.feed(&Event::Message { peer_id: "p".into(), kind: "pb.x.clip".into(), body: json!({"text": c}) });
                }
                i.model.pc_media = Some(super::super::model::Media { title: "Un Verano Sin Ti".into(), artist: "Bad Bunny".into(), playing: true, position_ms: 83_000, duration_ms: 212_000, speed: 1.0, at: Some(Instant::now()), art: Some(art.clone()), ..Default::default() });
                i.model.feed(&Event::Message { peer_id: "p".into(), kind: "pb.x.call".into(), body: json!({"active":true,"ringing":true,"canAnswer":true,"name":"Mamá"}) });
                i.model.feed(&Event::TransferOffer { id: "o1".into(), peer_id: "p".into(), peer_name: "Pixel 9a".into(), name: "Vacaciones-2026.mp4".into(), size: 482_000_000 });
                i.model.feed(&Event::TransferStarted { id: "x1".into(), peer_id: "p".into(), peer_name: "Pixel 9a".into(), name: "informe-final.pdf".into(), size: 8_000_000, incoming: false });
                i.model.feed(&Event::TransferProgress { id: "x1".into(), done: 5_200_000, total: 8_000_000, bytes_per_sec: 3_400_000 });
                i.model.adb.insert("p".into(), super::super::adb::Radios { wifi: true, bt: true, rotate: false });
                i.note = Note { icon: Some(Icon::Bell), title: "WhatsApp · Ana".into(), text: "¿Vienes a cenar hoy?".into(), good: false, w: 0.0, img: None };
                i.open(view.clone(), Reason::Hover);
                i.set_pointer(Some((CANVAS_W / 2.0, 40.0)));
                run(&mut i, 0.8);
                if *name == "drop" {
                    i.drag_over = true;
                }
                let mut cv = i.new_canvas(k);
                i.render(&mut cv);
                // Over a mid-grey "desktop" so the shadow and rim are visible.
                let mut out = Canvas::new(CANVAS_W, CANVAS_H, k);
                out.pm.fill(tiny_skia::Color::from_rgba8(70, 78, 92, 255));
                out.blit(&cv.pm, 1.0, 1.0, 0.0, 0.0, None);
                let mut rgba = out.pm.data().to_vec();
                for px in rgba.chunks_exact_mut(4) {
                    px[3] = 255;
                }
                let file = std::fs::File::create(format!("{dir}/{tag}-{name}.png")).unwrap();
                let mut enc = png::Encoder::new(file, out.width_px(), out.height_px());
                enc.set_color(png::ColorType::Rgba);
                enc.set_depth(png::BitDepth::Eight);
                enc.write_header().unwrap().write_image_data(&rgba).unwrap();
            }
        }
    }

    /// Frames of the opening and of a page change: `ISLAND_PNG_DIR=/tmp/x cargo test frames`.
    #[test]
    fn frames() {
        let Ok(dir) = std::env::var("ISLAND_PNG_DIR") else { return };
        let k = 1.0;
        let mut cfg = IslandConfig::default();
        cfg.animation = "normal".into();
        let mut i = Island::new(cfg);
        with_phone(&mut i);
        i.model.pc_media = Some(super::super::model::Media { title: "Un Verano Sin Ti".into(), artist: "Bad Bunny".into(), playing: true, duration_ms: 212_000, speed: 1.0, at: Some(Instant::now()), ..Default::default() });
        i.set_zone(true, false, 0.2);
        i.set_pointer(Some((CANVAS_W / 2.0, 40.0)));
        let mut shots: Vec<(String, f32)> = [0, 30, 60, 90, 120, 160, 220, 320, 450].iter().map(|ms| (format!("open-{ms:03}"), *ms as f32 / 1000.0)).collect();
        let mut t = 0.0f32;
        let dt = 1.0 / 240.0;
        let mut phase2 = false;
        while !shots.is_empty() {
            i.update(dt);
            t += dt;
            if shots[0].1 <= t {
                let (name, _) = shots.remove(0);
                let mut cv = i.new_canvas(k);
                i.render(&mut cv);
                let mut out = Canvas::new(CANVAS_W, CANVAS_H, k);
                out.pm.fill(tiny_skia::Color::from_rgba8(70, 78, 92, 255));
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
            if shots.is_empty() && !phase2 {
                phase2 = true;
                run(&mut i, 0.6);
                i.act(Act::Go(Page::Controls));
                t = 0.0;
                shots = [0, 40, 80, 120, 180, 260, 400].iter().map(|ms| (format!("page-{ms:03}"), *ms as f32 / 1000.0)).collect();
            }
        }
    }
}

