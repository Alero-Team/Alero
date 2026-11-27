//! The island itself: what it shows, how it opens and closes, and how it moves.
//!
//! Nothing here touches the operating system. A host (Windows or X11) feeds it the pointer, the engine's events and
//! the passing of time, asks for a frame, and executes the commands it returns. That keeps the whole behaviour
//! testable and the platform code small.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::time::Instant;

use serde_json::{json, Value};
use tiny_skia::Pixmap;

use super::config::{luma, IslandConfig};
use super::airdrop::{self, AirDrop};
use super::link::{Alert, LinkAlerts};
use super::gfx::{color, icon, icon_filled, mix, Canvas, Fonts, Icon, Image, Rgb, Weight, R};
use super::model::{Model, Notice, XState};
use super::motion::{Motion, Spring, Style};
use super::pc::{Agent, Work};
use crate::lang::t;

/// Logical size of the drawing surface (the window is this big times the scale). The largest screen plus the
/// room the spring overshoots into.
/// Wide enough for the player with lyrics (660) and its spring; the window is cut to the island while it is drawn,
/// so the width costs nothing when the island is smaller.
pub const CANVAS_W: f32 = 720.0;
pub const CANVAS_H: f32 = 376.0;
const PAD: f32 = 18.0;
/// The notch at rest: a slim tab on the top edge that says where the island is.
const PEEK: (f32, f32) = (132.0, 6.0);
const MAX_RADIUS: f32 = 32.0;
/// How long a device alert stays open, in seconds.
const LINK_SECS: f32 = 2.8;
/// `note_age` once the entrance of a device alert has finished.
const NOTE_AGE_DONE: f32 = 1.5;
/// The notch while something lives in it (music, charging): the iPhone's compact island.
const LIVE: (f32, f32) = (320.0, 40.0);
/// The notch when an agent has been at work a while: just its creature and dots, out of the way.
const MINI: (f32, f32) = (84.0, 34.0);
/// How long the agent's full line shows when it starts, and after the pointer leaves it, in seconds.
const AGENT_FULL: f64 = 6.0;
const AGENT_PEEK: f64 = 2.0;
/// Logical size of the window while the island is closed: the widest closed notch (LIVE swollen under the pointer),
/// its ears and room for the spring's overshoot. See `rest_box`.
const REST_BOX: (f32, f32) = (620.0, 84.0);

/// What the closed island shows, like the iPhone's Dynamic Island.
#[derive(Clone, Copy, PartialEq, Debug)]
enum Live {
    /// The phone was just plugged in (for a few seconds): its battery level.
    Charging(i32),
    /// Something started playing, or the song changed (for a few seconds).
    Media,
    /// Lyrics are on: the line being sung, for as long as it plays.
    Lyric,
    /// A call on the phone: who, and how long it has lasted (the card folds into this once answered).
    Call,
    /// The call just ended (for a moment): how long it lasted in seconds, -1 if it was never answered.
    CallEnded(i64),
    /// Claude Code or Codex is working on this computer.
    Agent(Agent),
    /// It just stopped (for a moment).
    AgentDone(Agent),
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
    /// A control that needs adb: "wifi", "bt", "rotate", "lock" or "hotspot".
    Adb(&'static str),
    /// Ringer silent, or back to normal.
    Mute,
    /// A phone control only the app can run (camera, screen, screenshot): it does it as its own button does.
    App(&'static str),
    /// The player's progress bar: drag to move through the song.
    Seek,
    /// The player's volume: the speaker button stretches into a slider.
    VolButton,
    PlayerVolume,
    /// Lyrics on or off (music apps only).
    Lyrics,
    /// A notification row: tap marks it read, a drag to the right dismisses it.
    NotifRow(String),
    NotifRead(String),
    NotifReply(String),
    QuickReply(String, usize),
    SendReply(String),
    /// A received photo (transfer id): open, show in its folder, discard.
    OpenFile(String),
    ShowFile(String),
    Discard(String),
    /// A control of this computer: "mic" or "mute" (toggles), "lock", "sleep", "shot".
    Pc(&'static str),
    /// The computer's volume slider on the controls page.
    PcVol,
    /// The controls page's "This computer | Phone" switch.
    ControlsSource,
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
    /// Runs one of the app's phone controls ("camBack", "camFront", "screen", "shot") on the target phone.
    App(&'static str),
    PcSeek(i64),
    PhoneSeek(i64),
    PcVolume(f32),
    /// Reads the computer's volume (answered with [`Island::set_pc_volume`]).
    AskPcVolume,
    /// Synced lyrics for a song (answered with [`Island::set_lyrics`]).
    Lyrics { key: String, title: String, artist: String, duration_ms: i64 },
    /// Remembers lyrics on or off.
    SaveLyrics(bool),
    NotifRead(String),
    NotifReply { key: String, text: String },
    /// The window takes the keyboard (a reply is being written) or gives it back.
    Keyboard(bool),
    /// Decode a received photo's preview (answered with [`Island::set_thumb`]).
    Thumb { id: String, path: PathBuf },
    /// A received file: open it with its app, show it in its folder, or delete the computer's copy.
    OpenFile(PathBuf),
    ShowFile(PathBuf),
    Discard(PathBuf),
    /// Mutes or unmutes this computer's microphone (`mic`) or output.
    PcMute { mic: bool, on: bool },
    /// "lock" or "sleep" this computer.
    PcPower(&'static str),
    /// A full-screen capture of this computer into Downloads/Alero.
    PcShot,
}

/// Quick answers offered under a chat notification.
const QUICK: [(&str, &str); 3] = [("Ok", "Ok"), ("Ahora no puedo", "Can't talk now"), ("Te escribo luego", "I'll text you later")];

/// Keys the reply field understands (characters come as text).
#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Key {
    Back,
    Enter,
    Escape,
}

/// A control tile switching on or off: its colour grows from (or shrinks to) the point that was touched.
#[derive(Clone, Copy)]
struct TileFx {
    v: Spring,
    o: (f32, f32),
    /// Seconds since the switch (the icon's small jump).
    age: f32,
}

/// Animation and interaction state the drawing reads. Kept apart from the model: none of it is data.
struct Ui {
    lyrics_on: bool,
    /// Song key and its lines (None: none found). Absent while asking.
    lyrics: Option<(String, Option<crate::lyrics::Lines>)>,
    lyrics_asked: String,
    /// The line shown, the one before it, and how far the change has gone (0..1).
    lyric_idx: Option<usize>,
    lyric_prev: String,
    lyric_t: f32,
    /// The lyrics list scrolls to the current line, in lines.
    lyric_scroll: Spring,
    /// How much of the cover's colours the island wears (0: the settings' colours).
    theme_t: f32,
    theme: Option<(String, [Rgb; 3])>,
    vol: Spring,
    vol_until: f64,
    pc_volume: Option<f32>,
    /// The controls page shows this computer's controls (when a phone is connected too; without one it always does).
    controls_pc: bool,
    /// Whether this computer's output / microphone is muted (None: not known yet).
    pc_out_muted: Option<bool>,
    pc_mic_muted: Option<bool>,
    /// The computer's audio state was asked for this visit to its controls.
    pc_asked: bool,
    seek: Option<f32>,
    tiles: HashMap<&'static str, TileFx>,
    read: HashSet<String>,
    /// Notifications on their way out (0..1), and where each row is (they glide when one leaves).
    gone: HashMap<String, f32>,
    rows: HashMap<String, Spring>,
    replying: Option<String>,
    reply_text: String,
    replied: HashMap<String, String>,
    /// A row being dragged: its key, where the drag started and how far it went.
    swipe: Option<(String, f32, f32)>,
    swipe_back: HashMap<String, Spring>,
    /// A file carried towards the island (0..1, from the distance), and the landing after a drop.
    near: Spring,
    land: Option<f32>,
    /// Seconds the landing has held its last frame, waiting for the card.
    land_held: f32,
    after_land: Option<(View, Option<f32>)>,
    squash: Spring,
    air: AirDrop,
    air_thumb: Option<Image>,
    /// File names waiting for TransferStarted, and the progress of each transfer in this drop.
    air_pending: Vec<String>,
    air_files: HashMap<String, f32>,
    /// Seconds since a device alert was shown (the stagger of its icon, badge and text); NOTE_AGE_DONE: finished.
    note_age: f32,
    /// How much of the compact island's content shows (0..1), and the last thing it showed: it fades out with it.
    live_a: f32,
    live_last: Option<Live>,
    /// 0 = the agent's full line, 1 = the minimal notch (eased).
    agent_min: f32,
}

impl Ui {
    fn new() -> Self {
        Self {
            lyrics_on: false,
            lyrics: None,
            lyrics_asked: String::new(),
            lyric_idx: None,
            lyric_prev: String::new(),
            lyric_t: 1.0,
            lyric_scroll: Spring::new(0.0, 0.55, 1.0),
            theme_t: 0.0,
            theme: None,
            vol: Spring::new(0.0, 0.5, 0.72),
            vol_until: 0.0,
            pc_volume: None,
            controls_pc: false,
            pc_out_muted: None,
            pc_mic_muted: None,
            pc_asked: false,
            seek: None,
            tiles: HashMap::new(),
            read: HashSet::new(),
            gone: HashMap::new(),
            rows: HashMap::new(),
            replying: None,
            reply_text: String::new(),
            replied: HashMap::new(),
            swipe: None,
            swipe_back: HashMap::new(),
            near: Spring::new(0.0, 0.35, 1.0),
            land: None,
            land_held: 0.0,
            after_land: None,
            squash: Spring::new(1.0, 0.40, 0.42),
            air: AirDrop::new(),
            air_thumb: None,
            air_pending: Vec::new(),
            air_files: HashMap::new(),
            note_age: NOTE_AGE_DONE,
            live_a: 0.0,
            live_last: None,
            agent_min: 0.0,
        }
    }
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
    /// A device alert: Some(true) connected, Some(false) disconnected. Draws the status badge and the staggered entrance.
    pub badge: Option<bool>,
    /// The sender's picture (a chat): drawn round, with `img` (the app) on its corner.
    pub avatar: Option<Image>,
    /// A phone notification: going to it opens the island on the notifications at once.
    pub notif: bool,
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
    #[cfg(test)]
    profile: [f64; 4],
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
    /// Clock time the player stopped playing (None while it plays).
    media_off: Option<f64>,
    /// Until when the closed island says the call ended, and how long it lasted (see `Live::CallEnded`).
    call_end: (f64, i64),
    /// What each coding agent on this computer is doing (indexed by `Agent`), and which one just finished until when.
    agents: [Work; 2],
    agent_done: Option<(Agent, f64)>,
    /// Clock time the current work began (the creature's entrance) and until when its full line shows.
    agent_t0: f64,
    agent_full_until: f64,
    /// An answered call's card folds into the compact island at this clock time.
    collapse_at: Option<f64>,
    /// The phone already asked for its media (an island started after the phone connected missed its first state).
    asked_media: Option<String>,
    ui: Ui,
    /// Connect / disconnect alerts waiting to be shown (debounced, see `link`).
    links: LinkAlerts,
    /// The rectangle of the last button activated and where in it the pointer was.
    last_hit: Option<(R, (f32, f32))>,
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
            media_off: None,
            call_end: (0.0, -1),
            collapse_at: None,
            asked_media: None,
            slide_unsent: None,
            wheel_acc: 0.0,
            copied: None,
            player_pc: None,
            seen_notifs: Instant::now(),
            cmds: Vec::new(),
            dirty: true,
            layer: None,
            #[cfg(test)]
            profile: [0.0; 4],
            clock: 0.0,
            reduce_motion: false,
            agents: [Work::Gone; 2],
            agent_done: None,
            agent_t0: 0.0,
            agent_full_until: 0.0,
            ui: Ui::new(),
            links: LinkAlerts::default(),
            last_hit: None,
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
        if !self.link_on() {
            self.links.drop_pending();
        }
        self.dirty = true;
    }

    fn link_on(&self) -> bool {
        self.cfg.enabled && self.cfg.modules.link
    }

    /// The devices connected when the island starts: their state is not news.
    pub fn seed_links(&mut self) {
        for p in self.model.peers.iter().filter(|p| p.trusted) {
            self.links.seed(&p.id, p.state == pb_core::engine::PeerState::Connected);
        }
    }

    /// A made-up connection or disconnection (`ALERO_ISLAND_SIM`), through the same debounce as a real one.
    pub fn simulate_link(&mut self, a: Alert) {
        self.links.push_now(self.clock, a);
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
        self.phase == Phase::Open && self.shown == View::Page(Page::Controls) && !self.controls_pc()
    }

    /// The controls page is this computer's: always without a phone, else the one the switch picked. Needs `modules.pc`.
    fn controls_pc(&self) -> bool {
        self.cfg.modules.pc && (self.model.target().is_none() || self.ui.controls_pc)
    }

    /// Also while closed: the compact island shows what is playing.
    pub fn wants_media(&self) -> bool {
        self.cfg.enabled && self.cfg.modules.player
    }

    fn live(&self) -> Option<Live> {
        if self.cfg.modules.call {
            if self.model.call().is_some() {
                return Some(Live::Call);
            }
            if self.clock < self.call_end.0 {
                return Some(Live::CallEnded(self.call_end.1));
            }
        }
        if self.lyric_live() {
            return Some(Live::Lyric);
        }
        if self.clock < self.charge_until {
            if let Some(i) = self.model.target().and_then(|p| self.model.info.get(&p.id)) {
                return Some(Live::Charging(i.battery));
            }
        }
        if self.cfg.modules.player && self.clock < self.media_until && self.media_line().is_some_and(|(m, _)| m.playing) {
            return Some(Live::Media);
        }
        // The computer's own agents come last: a call, the lyrics or a song that just changed are about the user now.
        if self.cfg.modules.agents {
            if let Some((a, _)) = self.agent_done.filter(|(_, until)| self.clock < *until) {
                return Some(Live::AgentDone(a));
            }
            return [Agent::Claude, Agent::Codex].into_iter().find(|a| self.agents[*a as usize] == Work::Working).map(Live::Agent);
        }
        None
    }

    /// Claude Code or Codex changed state (see `pc`). When one that was working stops, the closed island says so.
    pub fn set_agent(&mut self, a: Agent, w: Work) {
        let was = std::mem::replace(&mut self.agents[a as usize], w);
        // Closed mid-turn (Gone) is not "finished".
        if was == Work::Working && w == Work::Idle {
            self.agent_done = Some((a, self.clock + 4.0));
        }
        if was != Work::Working && w == Work::Working {
            self.agent_t0 = self.clock;
            self.agent_full_until = self.clock + AGENT_FULL;
        }
        self.dirty = true;
    }

    /// The agent has been at work a while and nobody is looking: only its creature shows.
    fn agent_mini(&self) -> bool {
        matches!(self.live(), Some(Live::Agent(_))) && self.clock >= self.agent_full_until
    }

    /// What `draw_live` needs for the agent: seconds since its creature appeared (or since it finished), how far
    /// the line has folded into the minimal notch, and how far the creature has gone back into the notch (0..1).
    fn agent_look(&self) -> (f32, f32, f32) {
        let t0 = match self.agent_done.filter(|(_, until)| self.clock < *until) {
            Some((_, until)) => until - 4.0,
            None => self.agent_t0,
        };
        let out = if self.live().is_none() { 1.0 - self.ui.live_a } else { 0.0 };
        ((self.clock - t0) as f32, self.ui.agent_min, out)
    }

    /// Playing started or the song changed: the closed island shows it for a moment, then steps back.
    fn watch_media(&mut self) {
        let now = self.media_line().filter(|(m, _)| m.playing).map(|(m, _)| format!("{} | {}", m.title, m.artist));
        let Some(k) = now else {
            self.media_off.get_or_insert(self.clock);
            return;
        };
        // A player that blinks off and on with the same song (Spotify re-announces itself) is not news, or the
        // compact island would be re-armed forever: a new song is, and so is playing again after a real pause.
        let back = self.media_off.take().is_some_and(|t| self.clock - t > 3.0);
        if self.media_seen.as_ref() != Some(&k) || back {
            self.media_until = self.clock + 4.0;
            self.dirty = true;
        }
        self.media_seen = Some(k);
    }

    // ------------------------------------------------------------------------------------------------ player

    /// Key of the song on screen ("title|artist").
    fn song_key(&self) -> Option<String> {
        self.media_line().filter(|(m, _)| !m.is_empty()).map(|(m, _)| format!("{}|{}", m.title, m.artist))
    }

    /// The player is a music service (Spotify, YouTube Music, Tidal, Apple Music, Deezer): lyrics can be offered.
    fn lyrics_app(&self) -> bool {
        self.media_line().is_some_and(|(m, _)| crate::lyrics::music_app(&m.app) || crate::lyrics::music_app(&m.pkg))
    }

    /// Lyrics are on and the player has them to offer.
    fn lyrics_now(&self) -> bool {
        self.ui.lyrics_on && self.lyrics_app()
    }

    /// The current song's lines, once found.
    fn lines(&self) -> Option<&crate::lyrics::Lines> {
        let key = self.song_key()?;
        self.ui.lyrics.as_ref().filter(|(k, _)| *k == key).and_then(|(_, l)| l.as_ref())
    }

    /// The closed island shows the sung line (lyrics on, playing, and lines found).
    fn lyric_live(&self) -> bool {
        self.cfg.modules.player && self.lyrics_now() && self.media_line().is_some_and(|(m, _)| m.playing) && self.lines().is_some_and(|l| !l.is_empty())
    }

    /// The line being sung now (empty before the first one).
    fn lyric_text(&self) -> String {
        match (self.lines(), self.ui.lyric_idx) {
            (Some(l), Some(i)) => l.get(i).map(|x| if x.1.is_empty() { "♪".to_string() } else { x.1.clone() }).unwrap_or_default(),
            _ => self.media_line().map(|(m, _)| m.title.clone()).unwrap_or_default(),
        }
    }

    pub fn set_lyrics_pref(&mut self, on: bool) {
        self.ui.lyrics_on = on;
        self.dirty = true;
    }

    /// The answer to [`Cmd::Lyrics`]: None when the song has none.
    pub fn set_lyrics(&mut self, key: String, lines: Option<crate::lyrics::Lines>) {
        self.ui.lyrics = Some((key, lines));
        self.ui.lyric_idx = None;
        self.dirty = true;
    }

    /// The answer to [`Cmd::Thumb`]. The card of that photo stays long enough to decide what to do with it.
    pub fn set_thumb(&mut self, id: &str, img: Option<Image>) {
        let Some(x) = self.model.xfers.iter_mut().find(|x| x.id == id) else { return };
        x.thumb = img;
        if x.thumb.is_some() && self.phase == Phase::Open && self.want == View::Transfer(id.to_string()) {
            self.life = self.life.max(self.cfg.event_secs as f32);
            self.reason = Reason::Event(Some(self.life));
        }
        self.dirty = true;
    }

    /// The answer to [`Cmd::AskPcVolume`].
    pub fn set_pc_volume(&mut self, v: Option<f32>) {
        self.ui.pc_volume = v;
        self.dirty = true;
    }

    /// The answer to [`Cmd::AskPcVolume`], second part: output and microphone mute.
    pub fn set_pc_mutes(&mut self, out: Option<bool>, mic: Option<bool>) {
        (self.ui.pc_out_muted, self.ui.pc_mic_muted) = (out, mic);
        self.dirty = true;
    }

    /// The controls page's volume slider: at most ~15 changes a second while dragging, the last one on release.
    fn set_pc_vol(&mut self, v: f32, first: bool) {
        let v = v.clamp(0.0, 1.0);
        self.ui.pc_volume = Some(v);
        if first || self.clock - self.last_slider >= 0.066 {
            self.last_slider = self.clock;
            self.cmds.push(Cmd::PcVolume(v));
        }
        self.dirty = true;
    }

    /// The player's volume, 0..1 (the computer's output, or the phone's media volume).
    fn player_volume(&self) -> Option<f32> {
        if self.media_line().is_some_and(|(_, pc)| pc) {
            self.ui.pc_volume
        } else {
            self.model.target_id().and_then(|id| self.model.phone.get(&id)).map(|p| p.media as f32 / p.media_max.max(1) as f32)
        }
    }

    fn set_player_volume(&mut self, v: f32, first: bool) {
        let v = v.clamp(0.0, 1.0);
        self.ui.vol_until = self.clock + 2.5;
        if self.media_line().is_some_and(|(_, pc)| pc) {
            self.ui.pc_volume = Some(v);
            // At most ~15 changes a second while dragging, the last one on release.
            if first || self.clock - self.last_slider >= 0.066 {
                self.last_slider = self.clock;
                self.cmds.push(Cmd::PcVolume(v));
            }
        } else {
            let max = self.model.target_id().and_then(|id| self.model.phone.get(&id)).map_or(15, |p| p.media_max);
            let value = (v * max as f32).round() as i32;
            if first || self.clock - self.last_slider >= 0.066 {
                self.last_slider = self.clock;
                self.set_volume(value);
            } else {
                self.slide_unsent = Some(value);
            }
        }
        self.dirty = true;
    }

    fn open_volume(&mut self) {
        self.ui.vol_until = self.clock + 2.5;
        self.ui.vol.tune(0.5, 0.72);
        self.ui.vol.to(1.0);
        if self.media_line().is_some_and(|(_, pc)| pc) {
            self.cmds.push(Cmd::AskPcVolume);
        }
    }

    /// Animation state that runs whatever the island shows.
    fn update_ui(&mut self, dt: f32) {
        let mut busy = false;
        // This computer's volume and mutes: asked once per visit to its controls.
        let on_pc = self.phase == Phase::Open && self.shown == View::Page(Page::Controls) && self.controls_pc();
        if on_pc && !self.ui.pc_asked {
            self.ui.pc_asked = true;
            self.cmds.push(Cmd::AskPcVolume);
        } else if !on_pc {
            self.ui.pc_asked = false;
        }
        // Lyrics: asked once per song while they are on.
        if self.lyrics_now() {
            if let (Some(key), Some((m, _))) = (self.song_key(), self.media_line()) {
                if key != self.ui.lyrics_asked {
                    self.cmds.push(Cmd::Lyrics { key: key.clone(), title: m.title.clone(), artist: m.artist.clone(), duration_ms: m.duration_ms });
                    self.ui.lyrics_asked = key;
                }
            }
        }
        // The sung line (a little ahead: the eye is slower than the ear).
        let idx = match (self.lines(), self.media_line()) {
            (Some(l), Some((m, _))) => {
                let pos = m.position_now() + 150;
                l.iter().rposition(|x| x.0 <= pos)
            }
            _ => None,
        };
        if idx != self.ui.lyric_idx {
            self.ui.lyric_prev = self.lyric_text();
            self.ui.lyric_idx = idx;
            self.ui.lyric_t = 0.0;
            self.ui.lyric_scroll.to(idx.unwrap_or(0) as f32);
        }
        if self.ui.lyric_t < 1.0 {
            self.ui.lyric_t = (self.ui.lyric_t + dt / 0.45).min(1.0);
            busy = true;
        }
        self.ui.lyric_scroll.step(dt);
        busy |= !self.ui.lyric_scroll.settled(0.002) && self.shown == View::Page(Page::Player);
        // The cover's colours, worked out once per song.
        if let Some((key, Some(art))) = self.media_line().map(|(m, _)| (format!("{}|{}", m.title, m.artist), m.art.as_ref())) {
            if self.ui.theme.as_ref().is_none_or(|(k, _)| *k != key) {
                self.ui.theme = Some((key, cover_palette(art)));
            }
        }
        let themed = self.lyrics_now() && self.ui.theme.is_some() && self.want != View::Drop && self.ui.land.is_none();
        let goal = if themed { 1.0 } else { 0.0 };
        if (goal - self.ui.theme_t).abs() > 0.002 {
            // About 0.7 s from one palette to the other.
            self.ui.theme_t += (goal - self.ui.theme_t) * (dt * 5.0).min(1.0);
            busy = true;
        } else {
            self.ui.theme_t = goal;
        }
        // The volume slider folds back into its button after 2.5 s untouched (not while the pointer is on it).
        let on_volume = self.pointer.is_some_and(|(x, y)| self.hits.iter().any(|h| matches!(h.act, Act::PlayerVolume | Act::VolButton) && h.r.inflate(6.0).contains(x, y)));
        if on_volume || self.pressed.is_some_and(|i| self.hits.get(i).is_some_and(|h| h.act == Act::PlayerVolume)) {
            self.ui.vol_until = self.ui.vol_until.max(self.clock + 0.8);
        }
        if self.ui.vol.target > 0.5 && self.clock > self.ui.vol_until {
            self.ui.vol.tune(0.3, 1.0);
            self.ui.vol.to(0.0);
        }
        self.ui.vol.step(dt);
        busy |= !self.ui.vol.settled(0.002);
        if self.ui.note_age < NOTE_AGE_DONE {
            self.ui.note_age += dt;
            busy = true;
        }
        // Control tiles switching.
        for f in self.ui.tiles.values_mut() {
            f.v.step(dt);
            f.age += dt;
        }
        self.ui.tiles.retain(|_, f| f.age < 0.6 || !f.v.settled(0.002));
        busy |= !self.ui.tiles.is_empty();
        // Notifications leaving, and the rows gliding into the gap.
        if !self.ui.gone.is_empty() {
            let mut done = Vec::new();
            for (k, p) in self.ui.gone.iter_mut() {
                *p += dt / 0.32;
                if *p >= 1.0 {
                    done.push(k.clone());
                }
            }
            for k in done {
                self.ui.gone.remove(&k);
                self.ui.rows.remove(&k);
                self.ui.swipe_back.remove(&k);
                self.model.dismiss_notif(&k);
            }
            busy = true;
        }
        let mut y = 52.0;
        for n in self.model.notifs.iter().take(4) {
            let s = self.ui.rows.entry(n.key.clone()).or_insert_with(|| Spring::new(y, 0.45, 1.0));
            s.to(y);
            s.step(dt);
            busy |= !s.settled(0.05);
            y += if self.ui.replying.as_deref() == Some(n.key.as_str()) { 132.0 } else { 50.0 } + 4.0;
        }
        for s in self.ui.swipe_back.values_mut() {
            s.step(dt);
            busy |= !s.settled(0.1);
        }
        self.ui.swipe_back.retain(|_, s| !s.settled(0.1));
        // A file carried towards the island, and the landing.
        self.ui.near.step(dt);
        self.ui.squash.step(dt);
        busy |= !self.ui.near.settled(0.002) || !self.ui.squash.settled(0.0005);
        let land_speed = if self.motion.style == Style::Off { 1.8 } else { 1.0 };
        if let Some(t) = self.ui.land.as_mut() {
            // A hitch must not skip the pop. At the end it holds ("Got it, sending…") until the card takes over.
            *t = (*t + dt.min(0.05) * land_speed).min(1.0);
            let t = *t;
            if t >= 0.65 {
                if let Some((v, secs)) = self.ui.after_land.take() {
                    self.open_event(v, secs);
                }
            }
            if t >= 1.0 {
                self.ui.land_held += dt;
                // The send never started (it failed, or the phone left): the idle text comes back.
                if !(self.phase == Phase::Open && self.want == View::Drop) || self.ui.land_held > 2.5 {
                    self.ui.land = None;
                    self.ui.land_held = 0.0;
                }
            }
            busy |= t < 1.0;
        }
        self.ui.air.set_reduced(self.motion.style == Style::Off);
        if self.ui.air.active() {
            for (id, progress) in &mut self.ui.air_files {
                if let Some(x) = self.model.xfers.iter().find(|x| &x.id == id) {
                    // All bytes sent still needs the receiver's integrity check and acknowledgement.
                    *progress = if x.state == XState::Done { 1.0 } else { x.fraction().min(0.999) };
                    if let XState::Failed(msg) = &x.state {
                        self.ui.air.set_failure(&mut self.fonts, msg);
                        self.ui.air.finish(false);
                    }
                }
            }
            let count = self.ui.air_pending.len() + self.ui.air_files.len();
            if count > 0 {
                self.ui.air.progress(self.ui.air_files.values().sum::<f32>() / count as f32);
                if self.ui.air_pending.is_empty() && self.ui.air_files.values().all(|f| *f >= 1.0) {
                    self.ui.air.finish(true);
                }
            }
        }
        busy |= self.ui.air.update(dt);
        if let Some(age) = self.ui.air.done_for() {
            let hold = if self.ui.air.stage == airdrop::Stage::Failed { 4.0 } else { 1.2 };
            if age > hold && self.phase == Phase::Open && self.shown == View::Drop {
                self.close();
            }
            if age > hold + 0.6 {
                self.ui.air.reset();
                self.ui.air_thumb = None;
                self.ui.air_files.clear();
                self.ui.air_pending.clear();
            }
        }
        if self.ui.replying.is_some() {
            // The caret blinks.
            if (self.clock * 2.0).floor() != ((self.clock - dt as f64) * 2.0).floor() {
                busy = true;
            }
        }
        if busy {
            self.dirty = true;
        }
    }

    // ------------------------------------------------------------------------------------------------ input

    pub fn set_drop_thumb(&mut self, name: &str, img: Option<Image>) {
        if self.ui.air_pending.first().is_some_and(|f| f == name)
            || self.ui.air_files.keys().any(|id| self.model.xfers.iter().any(|x| &x.id == id && x.name == name)) {
            self.ui.air_thumb = img;
            self.dirty = true;
        }
    }

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
                self.open(self.home_view(), Reason::Hover);
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
                // A send under way keeps its labels and landing; this drag only joins it if dropped.
                let sending = self.ui.air.active();
                if !self.drag_over && !sending {
                    let phone = self.model.target().map(|p| p.name.clone());
                    self.ui.air.set_labels(&mut self.fonts, phone.as_deref(), "");
                }
                self.ui.air.hover(true);
                if !sending {
                    self.ui.land = None;
                }
                self.drag_active = true;
                self.drag_over = true;
                self.life = 1.6;
                if self.phase != Phase::Open || self.shown != View::Drop {
                    self.open(View::Drop, Reason::Drag);
                }
            }
            Drag::Leave => {
                self.ui.air.hover(false);
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
            self.show_note(Note { icon: Some(Icon::Phone), title: t("Sin teléfono conectado", "No phone connected").into(), text: t("Conecta un teléfono para enviar archivos.", "Connect a phone to send files.").into(), good: false, w: 0.0, img: None, badge: None, avatar: None, notif: false });
            return;
        }
        let names: Vec<String> = files.iter().map(|p| p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()).collect();
        // Dropped during a send: it joins that send (the card waits for these too) instead of forgetting the first.
        if self.ui.air.active() && !matches!(self.ui.air.stage, airdrop::Stage::Done | airdrop::Stage::Failed) {
            self.ui.air_pending.extend(names);
            self.cmds.push(Cmd::SendFiles(files));
            self.life = self.life.max(2.0);
            return;
        }
        self.ui.air_pending = names;
        self.ui.air_files.clear();
        self.ui.air_thumb = None;
        let name = self.ui.air_pending[0].clone();
        let label = if files.len() > 1 { format!("{} (+{})", name, files.len() - 1) } else { name };
        let phone = self.model.target().map(|p| p.name.clone());
        self.ui.air.set_labels(&mut self.fonts, phone.as_deref(), &label);
        self.ui.air.set_reduced(self.motion.style == Style::Off);
        self.ui.air.dropped();
        self.cmds.push(Cmd::SendFiles(files));
        self.life = 2.0;
        // The landing: the island takes the hit (flattens, then rebounds twice), the circle pops, rings spread.
        // It is the confirmation that the drop worked, so it plays under reduced motion too (quicker, no squash).
        self.ui.land = Some(0.0);
        self.ui.land_held = 0.0;
        if !matches!(self.motion.style, Style::Off) {
            self.ui.squash.snap(1.0);
            self.ui.squash.vel = 0.0;
            self.ui.squash.value = 1.07;
            self.h.vel -= 320.0;
        }
        self.dirty = true;
    }

    pub fn hotkey(&mut self) {
        if self.phase == Phase::Open {
            self.close();
        } else if self.cfg.enabled {
            self.open(self.home_view(), Reason::Key);
        }
    }

    pub fn press(&mut self) {
        let Some((x, y)) = self.pointer else { return };
        self.pressed = self.hits.iter().position(|h| h.r.contains(x, y));
        if let Some(i) = self.pressed {
            let (r, act) = (self.hits[i].r, self.hits[i].act.clone());
            match act {
                Act::Volume => self.slide(i, x, true),
                Act::Seek => self.ui.seek = Some(((x - r.x) / r.w).clamp(0.0, 1.0)),
                Act::PlayerVolume => self.set_player_volume((x - r.x) / r.w, true),
                Act::PcVol => self.set_pc_vol((x - r.x) / r.w, true),
                Act::NotifRow(key) => self.ui.swipe = Some((key, x, 0.0)),
                _ => {},
            }
        }
        self.dirty = true;
    }

    pub fn moved(&mut self) {
        if let (Some(i), Some((x, _))) = (self.pressed, self.pointer) {
            let Some((r, act)) = self.hits.get(i).map(|h| (h.r, h.act.clone())) else { return };
            match act {
                Act::Volume => self.slide(i, x, false),
                Act::Seek => {
                    self.ui.seek = Some(((x - r.x) / r.w).clamp(0.0, 1.0));
                    self.dirty = true;
                }
                Act::PlayerVolume => self.set_player_volume((x - r.x) / r.w, false),
                Act::PcVol => self.set_pc_vol((x - r.x) / r.w, false),
                _ => {}
            }
        }
        if let (Some((_, start, off)), Some((x, _))) = (self.ui.swipe.as_mut(), self.pointer) {
            *off = (x - *start).max(0.0);
            self.dirty = true;
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
        // The progress bar: the song moves to where the button was let go.
        if let Some(f) = self.ui.seek.take() {
            if let Some((m, pc)) = self.media_line().map(|(m, pc)| (m.duration_ms, pc)).filter(|(d, _)| *d > 0) {
                let ms = (f as f64 * m as f64) as i64;
                self.cmds.push(if pc { Cmd::PcSeek(ms) } else { Cmd::PhoneSeek(ms) });
                let media = if pc { self.model.pc_media.as_mut() } else { self.model.phone_media.as_mut() };
                if let Some(md) = media {
                    md.position_ms = ms;
                    md.at = Some(Instant::now());
                }
                self.ui.lyric_scroll.snap(self.lines().and_then(|l| l.iter().rposition(|x| x.0 <= ms + 150)).unwrap_or(0) as f32);
            }
            self.dirty = true;
            return;
        }
        // The pc volume's last value while dragging.
        if down.is_some_and(|i| self.hits.get(i).is_some_and(|h| h.act == Act::PlayerVolume)) {
            if let Some(v) = self.ui.pc_volume.filter(|_| self.media_line().is_some_and(|(_, pc)| pc)) {
                self.cmds.push(Cmd::PcVolume(v));
            }
            self.dirty = true;
            return;
        }
        if down.is_some_and(|i| self.hits.get(i).is_some_and(|h| h.act == Act::PcVol)) {
            if let Some(v) = self.ui.pc_volume {
                self.cmds.push(Cmd::PcVolume(v));
            }
            self.dirty = true;
            return;
        }
        // A notification row: dragged far enough to the right it goes; a tap marks it read; else it slides back.
        if let Some((key, _, off)) = self.ui.swipe.take() {
            if off > 90.0 {
                self.ui.gone.insert(key.clone(), 0.0);
                self.ui.swipe_back.insert(key, Spring::new(off, 0.3, 1.0));
            } else if off < 4.0 {
                self.ui.read.insert(key);
            } else {
                let mut s = Spring::new(off, 0.38, 0.86);
                s.to(0.0);
                self.ui.swipe_back.insert(key, s);
            }
            self.dirty = true;
            return;
        }
        let Some((x, y)) = self.pointer else { return };
        let Some(i) = down else { return };
        if self.hits.get(i).is_some_and(|h| h.r.contains(x, y)) {
            let (r, act) = (self.hits[i].r, self.hits[i].act.clone());
            self.last_hit = Some((r, (x - r.x, y - r.y)));
            self.act(act);
        }
        self.dirty = true;
    }

    /// Text typed into the reply field.
    pub fn text(&mut self, s: &str) {
        if self.ui.replying.is_none() {
            return;
        }
        for ch in s.chars().filter(|c| !c.is_control()) {
            if self.ui.reply_text.chars().count() < 1000 {
                self.ui.reply_text.push(ch);
            }
        }
        self.dirty = true;
    }

    pub fn key(&mut self, k: Key) {
        let Some(key) = self.ui.replying.clone() else { return };
        match k {
            Key::Back => {
                self.ui.reply_text.pop();
            }
            Key::Enter => self.act(Act::SendReply(key)),
            Key::Escape => self.stop_reply(),
        }
        self.dirty = true;
    }

    fn stop_reply(&mut self) {
        if self.ui.replying.take().is_some() {
            self.ui.reply_text.clear();
            self.cmds.push(Cmd::Keyboard(false));
            self.dirty = true;
        }
    }

    fn send_reply(&mut self, key: String, text: String) {
        let text = text.trim().to_string();
        if text.is_empty() {
            return;
        }
        self.cmds.push(Cmd::NotifReply { key: key.clone(), text: text.clone() });
        self.ui.replied.insert(key.clone(), text);
        self.ui.read.insert(key);
        self.stop_reply();
    }

    /// How close a file being carried is to the island, 0 (far, or nothing carried) to 1 (on it).
    pub fn set_carry(&mut self, near: f32) {
        let near = if self.cfg.enabled && self.cfg.modules.send && self.phase == Phase::Closed { near.clamp(0.0, 1.0) } else { 0.0 };
        if (near - self.ui.near.target).abs() > 0.001 {
            self.ui.near.to(near);
            self.dirty = true;
        }
    }

    /// A control tile was switched: its colour grows from where it was touched (or shrinks back to it).
    fn flip_tile(&mut self, key: &'static str, on: bool) {
        let (r, o) = self.last_hit.unwrap_or((R::new(0.0, 0.0, 80.0, 62.0), (40.0, 31.0)));
        let _ = r;
        let mut v = Spring::new(if on { 0.0 } else { 1.0 }, if on { 0.42 } else { 0.30 }, 1.0);
        v.to(if on { 1.0 } else { 0.0 });
        self.ui.tiles.insert(key, TileFx { v, o, age: 0.0 });
    }

    pub fn wheel(&mut self, notches: f32) {
        // On the player the wheel moves its volume (and shows the slider).
        if self.phase == Phase::Open && self.shown == View::Page(Page::Player) && self.pointer.is_some_and(|(x, y)| self.pill().contains(x, y)) {
            if self.ui.vol.target < 0.5 {
                self.open_volume();
            }
            if let Some(v) = self.player_volume() {
                self.set_player_volume(v + notches * 0.04, true);
            }
            return;
        }
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

    /// How long a finished transfer's card stays: a received file waits for a choice, a failure for a read.
    fn xfer_life(&self, id: &str) -> f32 {
        match self.model.xfers.iter().find(|x| x.id == id) {
            Some(x) if x.saved().is_some() => self.cfg.event_secs as f32,
            Some(x) if matches!(x.state, XState::Failed(_)) => 4.0,
            _ => 2.4,
        }
    }

    /// A choice on a received file: the command with its saved path, then the card goes.
    fn file_cmd(&mut self, id: &str, make: fn(PathBuf) -> Cmd) {
        if let Some(p) = self.model.xfers.iter().find(|x| x.id == id).and_then(|x| x.path.clone()) {
            self.cmds.push(make(p));
        }
        self.close();
    }

    /// What hovering the top edge (or the hotkey) opens: the call card while there is a call, else Inicio.
    fn home_view(&self) -> View {
        if self.cfg.modules.call && self.model.call().is_some() { View::Call } else { View::Page(Page::Home) }
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
            Act::Call(k) => {
                // Mute shows its new state at once; the phone's next call state confirms it.
                if let (Some(c), "mute" | "unmute") = (self.model.calls.values_mut().next(), k) {
                    c.muted = k == "mute";
                }
                self.cmds.push(Cmd::CallAction(k));
            }
            Act::Toggle(what) => {
                let id = self.model.target_id().unwrap_or_default();
                let cur = self.model.phone.get(&id).map(|p| match what {
                    "dnd" => p.dnd,
                    "torch" => p.torch,
                    _ => p.finding,
                });
                let on = !cur.unwrap_or(false);
                self.flip_tile(what, on);
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
                self.flip_tile("ringer", next != "normal");
                self.cmds.push(Cmd::Phone { what: "ringer", body: json!({"mode": next}) });
                if let Some(p) = self.model.phone.get_mut(&id) {
                    p.ringer = next.into();
                }
            }
            Act::Mute => {
                let id = self.model.target_id().unwrap_or_default();
                let silent = self.model.phone.get(&id).is_some_and(|p| p.ringer == "silent");
                let next = if silent { "normal" } else { "silent" };
                self.flip_tile("mute", !silent);
                self.cmds.push(Cmd::Phone { what: "ringer", body: json!({"mode": next}) });
                if let Some(p) = self.model.phone.get_mut(&id) {
                    p.ringer = next.into();
                }
            }
            Act::App(what) => self.cmds.push(Cmd::App(what)),
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
            Act::Dismiss(key) => {
                self.ui.gone.insert(key.clone(), 0.0);
                if self.ui.replying.as_deref() == Some(key.as_str()) {
                    self.stop_reply();
                }
            }
            Act::Pc(what) => match what {
                "mic" | "mute" => {
                    let mic = what == "mic";
                    let on = !(if mic { self.ui.pc_mic_muted } else { self.ui.pc_out_muted }).unwrap_or(false);
                    if mic {
                        self.ui.pc_mic_muted = Some(on);
                        self.flip_tile("pcmic", on);
                    } else {
                        self.ui.pc_out_muted = Some(on);
                    }
                    self.cmds.push(Cmd::PcMute { mic, on });
                }
                "lock" | "sleep" => self.cmds.push(Cmd::PcPower(what)),
                _ => {
                    self.cmds.push(Cmd::PcShot);
                    self.close();
                }
            },
            Act::ControlsSource => self.ui.controls_pc = !self.controls_pc(),
            Act::Seek | Act::PlayerVolume | Act::PcVol => {}
            Act::VolButton => {
                if self.ui.vol.target > 0.5 {
                    self.ui.vol_until = 0.0;
                } else {
                    self.open_volume();
                }
            }
            Act::Lyrics => {
                self.ui.lyrics_on = !self.ui.lyrics_on;
                self.cmds.push(Cmd::SaveLyrics(self.ui.lyrics_on));
            }
            Act::NotifRow(key) => {
                self.ui.read.insert(key);
            }
            Act::NotifRead(key) => {
                if self.model.notifs.iter().any(|n| n.key == key && n.markable) {
                    self.cmds.push(Cmd::NotifRead(key.clone()));
                }
                self.ui.read.insert(key);
            }
            Act::NotifReply(key) => {
                if self.ui.replying.as_deref() == Some(key.as_str()) {
                    self.stop_reply();
                } else {
                    self.ui.replying = Some(key);
                    self.ui.reply_text.clear();
                    self.cmds.push(Cmd::Keyboard(true));
                }
            }
            Act::QuickReply(key, i) => {
                let text = QUICK.get(i).map(|q| t(q.0, q.1).to_string()).unwrap_or_default();
                self.send_reply(key, text);
            }
            Act::SendReply(key) => {
                let text = self.ui.reply_text.clone();
                self.send_reply(key, text);
            }
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
                // "lock" and "hotspot" are one-shot actions: they only ripple.
                if matches!(what, "wifi" | "bt" | "rotate") {
                    self.flip_tile(what, !cur);
                }
                self.cmds.push(Cmd::Adb { what, on: !cur });
            }
            Act::Device => self.model.cycle_target(),
            Act::OpenFile(id) => self.file_cmd(&id, Cmd::OpenFile),
            Act::ShowFile(id) => self.file_cmd(&id, Cmd::ShowFile),
            Act::Discard(id) => {
                // A browser download is the user's own file: never deleted from here, whatever drew the button.
                if self.model.xfers.iter().any(|x| x.id == id && x.local()) {
                    return;
                }
                self.file_cmd(&id, Cmd::Discard);
                self.model.xfers.retain(|x| x.id != id);
            }
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
                // Like the iPhone: a ringing call opens the card; once answered it folds into the compact island
                // (green phone and timer) and hovering opens it again; hanging up shows "ended" there for a moment.
                Notice::Call if m.call => match self.model.call().map(|(_, c)| c.ringing) {
                    Some(true) => {
                        self.open_event(View::Call, None);
                        if self.cfg.sound {
                            self.cmds.push(Cmd::Beep);
                        }
                    }
                    Some(false) => {
                        if self.phase == Phase::Open && self.want == View::Call {
                            self.collapse_at = Some(self.clock + 0.9);
                        }
                    }
                    None => {
                        let secs = self.model.ended.take().and_then(|c| c.since).map_or(-1, |s| s.elapsed().as_secs() as i64);
                        self.call_end = (self.clock + 2.4, secs);
                        self.collapse_at = None;
                        // An offer held back by the call takes its place (see `validate`); else the card folds away.
                        if self.phase == Phase::Open && self.want == View::Call && (self.model.offers.is_empty() || !self.cfg.modules.incoming) {
                            self.close();
                        }
                    }
                },
                Notice::Offer(_) if m.incoming => {
                    self.open_event(View::Offer, None);
                    if self.cfg.sound {
                        self.cmds.push(Cmd::Beep);
                    }
                }
                // A download of this computer can last minutes: its card says so for a moment and goes (the Files
                // page keeps it), then comes back with the result.
                // It never jumps over a page the user is using.
                Notice::XferStarted(id) if m.pc && id.starts_with(super::pc::PC_ID) => {
                    if self.phase != Phase::Open {
                        self.open_event(View::Transfer(id), Some(self.cfg.event_secs as f32));
                    }
                }
                Notice::XferStarted(id) if m.send || m.incoming => self.open_event(View::Transfer(id), None),
                Notice::XferDone(id, ok) => {
                    if let Some(progress) = self.ui.air_files.get_mut(&id) {
                        if ok { *progress = 1.0; } else { self.ui.air.finish(false); }
                    }
                    let local = self.model.xfers.iter().find(|x| x.id == id).is_some_and(|x| x.local());
                    // A saved file gets a preview: made off this thread, the card shows it when ready.
                    if let Some(p) = self.model.xfers.iter().find(|x| x.id == id).and_then(|x| x.saved()) {
                        self.cmds.push(Cmd::Thumb { id: id.clone(), path: p.to_path_buf() });
                    }
                    let on_card = self.phase == Phase::Open && self.shown == View::Transfer(id.clone());
                    if local && ok && m.pc && self.phase != Phase::Open {
                        let secs = self.xfer_life(&id);
                        self.open_event(View::Transfer(id.clone()), Some(secs));
                    } else if on_card {
                        self.life = self.xfer_life(&id);
                        self.reason = Reason::Event(Some(self.life));
                    }
                }
                Notice::Notif(key) if m.notifications => {
                    if let Some(n) = self.model.notifs.iter().find(|n| n.key == key) {
                        let note = Note { icon: Some(Icon::Bell), title: [n.app.as_str(), n.title.as_str()].iter().filter(|p| !p.is_empty()).copied().collect::<Vec<_>>().join(" · "), text: n.text.clone(), good: false, w: 0.0, img: self.model.icon(&n.pkg).cloned(), badge: None, avatar: n.avatar.clone(), notif: true };
                        self.show_note_for(note, self.cfg.event_secs as f32);
                    }
                }
                Notice::Link(id, name, up) => self.links.push(self.clock, Alert { id, name, up }),
                Notice::Replied(false) => self.flash(false, t("No se pudo enviar la respuesta", "Could not send the reply").into(), t("Responde desde el teléfono.", "Reply from the phone.").into()),
                Notice::Clip if m.clipboard => {
                    let from = self.model.clips.front().map(|c| c.from.clone()).unwrap_or_default();
                    self.show_note(Note { icon: Some(Icon::Clipboard), title: t("Portapapeles recibido", "Clipboard received").into(), text: from, good: true, w: 0.0, img: None, badge: None, avatar: None, notif: false });
                }
                _ => {}
            }
        }
        if !self.link_on() {
            self.links.drop_pending();
        }
        self.dirty = true;
    }

    /// Announces a device connecting or disconnecting. Decision: it is shown only when the island is closed and
    /// nothing is about to open it (pointer in the zone, a file being carried). An island the user opened, or one
    /// busy with a call, an offer, a transfer or a notification, is never cut or replaced: the alert waits (its turn
    /// comes when the island closes, and it is dropped after `link::TTL` seconds, because Inicio already shows the
    /// state). So there is nothing to restore afterwards. Obeys "open by itself" (`auto_expand`).
    fn show_links(&mut self) {
        let free = self.link_on() && self.cfg.auto_expand && self.rest && self.phase == Phase::Closed && !self.hot && self.ui.near.value < 0.05 && self.ui.land.is_none();
        let Some(a) = self.links.poll(self.clock, free) else { return };
        let title = if a.name.is_empty() { t("Dispositivo", "Device").to_string() } else { a.name };
        let text = if a.up { t("Conectado", "Connected") } else { t("Desconectado", "Disconnected") };
        let note = Note { icon: Some(Icon::Phone), title, text: text.into(), good: a.up, w: 0.0, img: None, badge: Some(a.up), avatar: None, notif: false };
        self.show_note_for(note, LINK_SECS);
        self.ui.note_age = if self.motion.style == Style::Off { NOTE_AGE_DONE } else { 0.0 };
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
        if let View::Transfer(id) = &v {
            if let Some(x) = self.model.xfers.iter().find(|x| &x.id == id && !x.incoming && !x.local()) {
                if let Some(n) = self.ui.air_pending.iter().position(|f| f == &x.name) {
                    self.ui.air_pending.remove(n);
                    self.ui.air_files.insert(id.clone(), x.fraction());
                    return;
                }
            }
        }
        if self.ui.land.is_some_and(|t| t < 0.65) && matches!(v, View::Transfer(_)) {
            self.ui.after_land = Some((v, secs));
            return;
        }
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

    /// The closed notch's size: what lives in it, swollen a little under the pointer (the place that opens it
    /// answers), reaching out to a file on its way.
    fn rest_size(&mut self) -> (f32, f32) {
        let swell = |hot: bool, w: f32| (w + if hot { 14.0 } else { 0.0 }, LIVE.1 + if hot { 2.0 } else { 0.0 });
        let live = if self.ui.air.active() && !matches!(self.live(), Some(Live::Call | Live::CallEnded(_))) { Some(Live::Media) } else { self.live() };
        let (mut tw, mut th) = match (live, self.hot) {
            // The sung line: the notch hugs it.
            (Some(Live::Lyric), hot) => {
                let line = self.lyric_text();
                swell(hot, (self.fonts.measure(&line, 15.0, Weight::Medium) + 74.0).clamp(200.0, 560.0))
            }
            (Some(Live::Agent(_)), _) if self.agent_mini() => MINI,
            // The agent's creature is on its way back into the notch: the notch waits for it, then closes.
            (None, _) if matches!(self.ui.live_last, Some(Live::Agent(_) | Live::AgentDone(_))) && self.ui.live_a > 0.0 => MINI,
            (Some(_), hot) => swell(hot, LIVE.0),
            (None, true) => (PEEK.0 + 20.0, PEEK.1 + 4.0),
            (None, false) => PEEK,
        };
        let n = self.ui.near.value.clamp(0.0, 1.0);
        if n > 0.001 {
            tw = tw.max(tw + (340.0 - tw) * n);
            th = th.max(th + (44.0 - th) * n);
        }
        (tw, th)
    }

    fn snap_closed(&mut self) {
        self.phase = Phase::Closed;
        // Where closing took it (the compact island, or the bare notch): no jump.
        let (w, h) = self.rest_size();
        self.w.snap(w);
        self.h.snap(h);
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
            // It grows from the resting notch, wherever its swell left it; the compact content fades under it.
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
        self.stop_reply();
        self.ui.vol.snap(0.0);
        self.phase = Phase::Closing;
        self.w.tune(self.motion.collapse.0, self.motion.collapse.1);
        self.h.tune(self.motion.collapse.0, self.motion.collapse.1);
        // Straight into the compact island when something lives in it (a call that was answered), like the iPhone.
        let (tw, th) = self.rest_size();
        self.w.to(tw);
        self.h.to(th);
        // Nothing to come back to: the compact content that was there when it opened must not flash on the way down.
        if self.live().is_none() {
            self.ui.live_a = 0.0;
        }
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
            // With lyrics, a second column holds them.
            View::Page(Page::Player) => if self.lyrics_now() { (660.0, 200.0) } else { (480.0, 200.0) },
            View::Page(Page::Files) => (404.0, 140.0 + 40.0 * m.xfers.len().min(3) as f32),
            View::Page(Page::Notifs) => (
                424.0,
                if m.notifs.is_empty() {
                    150.0
                } else {
                    // Rows of 50 (132 while answering one) and 4 between them.
                    58.0 + m.notifs.iter().take(4).map(|n| if self.ui.replying.as_deref() == Some(n.key.as_str()) { 136.0 } else { 54.0 }).sum::<f32>()
                },
            ),
            View::Page(Page::Clipboard) => (404.0, if m.clips.is_empty() { 140.0 } else { 116.0 + 38.0 * m.clips.len().min(3) as f32 }),
            View::Page(Page::Controls) if self.controls_pc() => (404.0, controls_top(4) + 66.0),
            View::Page(Page::Controls) => {
                let n = control_keys(&self.cfg.controls, m.target_id().is_some_and(|id| m.adb.contains_key(&id))).len();
                (404.0, controls_top(n) + 66.0)
            }
            View::Call => (384.0, 92.0),
            View::Offer => (384.0, 136.0),
            View::Transfer(id) => match m.xfers.iter().find(|x| &x.id == id) {
                Some(x) if x.saved().is_some() => (440.0, 156.0),
                _ => (384.0, 92.0),
            },
            View::Note => (if self.note.w > 0.0 { self.note.w } else { 372.0 }, 76.0),
            // A file over it: the target swells to meet it.
            View::Drop => airdrop::SIZE,
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
        // A landing file squashes it: wider and shorter, then back with two soft rebounds.
        let sq = self.ui.squash.value;
        let (w, h) = ((self.w.value * sq).max(8.0), (self.h.value * (2.0 - sq)).max(8.0));
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
        self.show_links();
        self.update_ui(dt);
        if self.phase == Phase::Closed {
            if !self.cfg.enabled || !self.rest {
                return Status { visible: false, animating: false };
            }
            let live = self.live();
            // Looking at the minimal notch brings the line back for a moment.
            if matches!(live, Some(Live::Agent(_))) && self.pointer_near() {
                self.agent_full_until = self.agent_full_until.max(self.clock + AGENT_PEEK);
            }
            let goal = if self.agent_mini() { 1.0 } else { 0.0 };
            if self.ui.agent_min != goal {
                let step = if self.motion.style == Style::Off { 1.0 } else { dt / 0.3 };
                self.ui.agent_min = if goal > self.ui.agent_min { (self.ui.agent_min + step).min(1.0) } else { (self.ui.agent_min - step).max(0.0) };
                self.dirty = true;
            }
            let (tw, th) = self.rest_size();
            self.w.to(tw);
            self.h.to(th);
            self.w.step(dt);
            self.h.step(dt);
            let moving = !self.w.settled(0.05) || !self.h.settled(0.05);
            // The compact content fades in, and out with the last thing it showed while the notch shrinks.
            if live.is_some() {
                self.ui.live_last = live;
            }
            let goal = if live.is_some() { 1.0 } else { 0.0 };
            if self.ui.live_a != goal {
                // The agent's creature takes a little longer to leave: it hops back into the notch.
                let span = if goal == 0.0 && matches!(self.ui.live_last, Some(Live::Agent(_) | Live::AgentDone(_))) { 0.5 } else { 0.28 };
                let step = if self.motion.style == Style::Off { 1.0 } else { dt / span };
                self.ui.live_a = if goal > self.ui.live_a { (self.ui.live_a + step).min(1.0) } else { (self.ui.live_a - step).max(0.0) };
                self.dirty = true;
            }
            // The equalizer and a call's pulse run every frame: skipping frames lets the loop sleep 100 ms between
            // them (measured: ~9 fps). About 2 % of a core while they show.
            if matches!(live, Some(Live::Media | Live::Call)) {
                self.dirty = true;
            }
            // The agent's pixel creature moves about 12 times a second: frames only at those ticks.
            if matches!(live, Some(Live::Agent(_) | Live::AgentDone(_))) && (self.clock * 12.0).floor() != ((self.clock - dt as f64) * 12.0).floor() {
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
        // Answered: the card folds into the compact island, even under the pointer (hovering brings it back).
        // Not while a button is held.
        if self.collapse_at.is_some_and(|t| self.clock >= t) {
            self.collapse_at = None;
            if self.phase == Phase::Open && self.want == View::Call && self.pressed.is_none() {
                self.close();
            }
        }
        // Closing rules. Writing a reply keeps it open wherever the pointer goes.
        if self.phase == Phase::Open {
            let near = self.pointer_near() || self.ui.replying.is_some() || self.ui.seek.is_some();
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
                        // Looking at it: it stays, and from now on it behaves like a hover. A notification opens the
                        // island on the notifications straight away (its reply and the rest are there), not after it.
                        self.away_for = 0.0;
                        if matches!(self.shown, View::Page(_) | View::Note) {
                            self.reason = Reason::Hover;
                        }
                        if self.want == View::Note && self.note.notif && self.cfg.modules.notifications {
                            self.go(View::Page(Page::Notifs));
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
        // A download of unknown size draws a gliding bar: every frame while its card is up.
        if self.phase == Phase::Open && matches!(&self.shown, View::Transfer(id) if self.model.xfers.iter().any(|x| &x.id == id && x.no_total())) {
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
            if !self.model.xfers.iter().any(|x| &x.id == id && x.state == XState::Running) {
                self.life = self.xfer_life(id);
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
    /// While closed, the only part of the canvas that can hold pixels (the notch and its ears, with room
    /// for the spring's overshoot): the window shrinks to it, so the compositor carries ~85 % fewer pixels over
    /// whatever is below. One fixed size for every closed state, so the window is not remade while the notch swells.
    /// None while open, or if the notch ever outgrows it (then the whole canvas is shown, as before).
    pub fn rest_box(&self) -> Option<R> {
        if self.phase != Phase::Closed {
            return None;
        }
        let b = R::new((CANVAS_W - REST_BOX.0) / 2.0, 0.0, REST_BOX.0, REST_BOX.1);
        let need = self.pill().inflate(28.0);
        (need.x >= b.x && need.right() <= b.right() && need.bottom() <= b.bottom()).then_some(b)
    }

    /// The part of the canvas the window carries: closed, the fixed notch box; open, the island with its ears and
    /// the margin a carried file is caught in. Everything else is transparent, so it never goes to the compositor.
    pub fn crop_box(&self) -> Option<R> {
        if self.phase == Phase::Closed {
            return self.rest_box();
        }
        let p = self.pill();
        let x0 = (p.x - 46.0).max(0.0);
        let x1 = (p.right() + 46.0).min(CANVAS_W);
        Some(R::new(x0, 0.0, x1 - x0, (p.bottom() + 40.0).min(CANVAS_H)))
    }

    pub fn release_buffers(&mut self) {
        self.layer = None;
    }

    /// A short message from the executor (a file that could not be sent, say).
    pub fn flash(&mut self, good: bool, title: String, text: String) {
        if !good && self.ui.air.active() {
            self.ui.air.set_failure(&mut self.fonts, &text);
            self.ui.air.finish(false);
            self.ui.air_pending.clear();
        }
        let note = Note { icon: Some(if good { Icon::Check } else { Icon::Close }), title, text, good, w: 0.0, img: None, badge: None, avatar: None, notif: false };
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
        let mut bg = self.cfg.background();
        let mut bg2 = bg;
        let mut accent = self.cfg.accent_rgb();
        // With lyrics on, the island wears the cover's colours (eased in and out over ~0.7 s).
        let e = smooth(self.ui.theme_t);
        if e > 0.001 {
            if let Some((_, [tb, tb2, ta])) = &self.ui.theme {
                bg = mix(bg, *tb, e);
                bg2 = mix(bg2, *tb2, e);
                accent = mix(accent, *ta, e);
            }
        }
        let light = luma(bg) > 0.55;
        let fg: Rgb = if light { [24, 24, 28] } else { [255, 255, 255] };
        // Text on the accent colour: dark on light accents, white on dark ones.
        let on_accent: Rgb = if luma(accent) > 0.6 { [10, 10, 12] } else { [255, 255, 255] };
        Pal { bg, bg2, fg, accent, on_accent, chip: mix(bg, fg, 0.11), chip_hi: mix(bg, fg, 0.20) }
    }

    #[cfg(test)]
    pub fn new_canvas(&self, k: f32) -> Canvas {
        Canvas::new(CANVAS_W, CANVAS_H, k)
    }

    /// Draws the current frame into `cv` (cleared first).
    pub fn render(&mut self, cv: &mut Canvas) {
        #[cfg(test)]
        let mut profile_at = Instant::now();
        #[cfg(test)]
        { self.profile = [0.0; 4]; }
        cv.clear();
        let pressed = self.pressed.and_then(|i| self.hits.get(i)).map(|h| h.r);
        self.hits.clear();
        if self.phase == Phase::Closed && !self.rest {
            return;
        }
        let pal = self.palette();
        let pill = self.pill();
        // Bottom corners grow with the island (14 on a slim bar, 32 on a full card); the ears follow them.
        let radius = (pill.h / 2.0).min(10.0 + pill.h * 0.16).min(MAX_RADIUS);
        let shape = super::gfx::notch(pill, radius, radius * 0.68);
        #[cfg(test)]
        { self.profile[0] = profile_at.elapsed().as_secs_f64() * 1000.0; profile_at = Instant::now(); }
        // While a file is being carried, the pixels above and around the island are made (all but) invisible but
        // solid for hit testing, so the system's drag-and-drop reaches the window even at the very edge of the screen.
        if matches!(self.want, View::Drop) {
            cv.squircle(R::new(pill.x - 40.0, 0.0, pill.w + 80.0, pill.bottom() + 18.0), 20.0, color([0, 0, 0], 0.012), None);
        }
        // Body, hanging from the top edge, and a hairline rim so the black does not melt into a dark window.
        if let Some(p) = &shape {
            if pal.bg2 != pal.bg {
                // Dark at the top, glowing with the cover's colour towards the bottom.
                cv.fill_path_vgradient(p, color(pal.bg, 1.0), color(pal.bg2, 1.0), pill.y + pill.h * 0.35, pill.y + pill.h * 1.3, None);
            } else {
                cv.fill_path(p, color(pal.bg, 1.0), None);
            }
            cv.stroke_path(p, color(pal.fg, 0.10), 0.9, None);
        }
        #[cfg(test)]
        { self.profile[1] = profile_at.elapsed().as_secs_f64() * 1000.0; profile_at = Instant::now(); }
        let look = self.agent_look();
        if self.phase == Phase::Closed {
            // The compact island's content appears as the notch reaches its width.
            let n = self.ui.near.value.clamp(0.0, 1.0);
            if n > 0.25 {
                // A file on its way: only the send card's phone, small, so a button held for something else says nothing more.
                AirDrop::draw_hint(cv, (pill.cx(), pill.cy()), pal.fg, pal.accent, ((n - 0.25) / 0.5).clamp(0.0, 1.0));
            } else if self.ui.air.active() && !matches!(self.live(), Some(Live::Call | Live::CallEnded(_))) {
                let a = ((pill.w - PEEK.0) / (LIVE.0 - PEEK.0)).clamp(0.0, 1.0).powi(2);
                self.ui.air.draw_pill(cv, pill, self.ui.air_thumb.as_ref(), pal.fg, pal.accent, a);
            } else if let Some(l) = self.live().or(self.ui.live_last).filter(|_| self.ui.live_a > 0.0) {
                let full = if l == Live::Lyric { 200.0 } else { LIVE.0 };
                // The agent's notch can be narrower than the resting one: it appears with its height.
                // Leaving, the creature does its own exit (see `agent_look`) instead of fading with the height.
                let grown = if matches!(l, Live::Agent(_) | Live::AgentDone(_)) { if look.2 > 0.0 { 1.0 } else { (pill.h - PEEK.1) / (MINI.1 - PEEK.1) } } else { (pill.w - PEEK.0) / (full - PEEK.0) };
                // A leaving creature stays solid: its exit is its shrink, not a fade.
                let fade = if look.2 > 0.0 && matches!(l, Live::Agent(_) | Live::AgentDone(_)) { 1.0 } else { smooth(self.ui.live_a) };
                let a = grown.clamp(0.0, 1.0).powi(2) * (1.0 - n * 4.0).clamp(0.0, 1.0) * fade;
                if a > 0.02 {
                    let lyric = (self.lyric_text(), self.ui.lyric_prev.clone(), smooth(self.ui.lyric_t));
                    let mut d = Draw { cv, fonts: &mut self.fonts, hits: &mut self.hits, pal: &pal, pointer: None, pressed: None };
                    draw_live(&mut d, &self.model, self.player_pc, l, pill, a, self.clock, &lyric, look);
                }
            }
            return;
        }
        // Content, laid out at the final size and revealed by the clip.
        let p = self.content.value.clamp(0.0, 1.0);
        // The compact content does not vanish when a card opens over it (an empty black pill for a few frames): it
        // fades as the card grows, and back in under a closing card when it is still live.
        let under = if self.phase == Phase::Open { self.ui.live_last } else { self.live() };
        if let Some(l) = under.filter(|_| self.ui.live_a > 0.0) {
            let a = smooth(self.ui.live_a) * (1.0 - p * 3.0).clamp(0.0, 1.0);
            if a > 0.02 {
                let lyric = (self.lyric_text(), self.ui.lyric_prev.clone(), smooth(self.ui.lyric_t));
                let mut d = Draw { cv, fonts: &mut self.fonts, hits: &mut self.hits, pal: &pal, pointer: None, pressed: None };
                draw_live(&mut d, &self.model, self.player_pc, l, pill, a, self.clock, &lyric, look);
                self.hits.clear();
            }
        }
        let view = self.shown.clone();
        let (vw, vh) = self.size_of(&view);
        if p >= 0.999 && (pill.w - vw).abs() < 0.5 && (pill.h - vh).abs() < 0.5 {
            // At rest (hover, a clock tick) the content is drawn straight in: no layer to clear, mask and copy.
            self.draw_view(cv, &pal, &view, ((CANVAS_W - vw) / 2.0, 0.0), pressed);
            #[cfg(test)]
            { self.profile[2] = profile_at.elapsed().as_secs_f64() * 1000.0; }
        } else if p > 0.004 {
            let mut layer = match self.layer.take() {
                Some(l) if l.width_px() == cv.width_px() && l.height_px() == cv.height_px() => l,
                _ => Canvas { pm: Pixmap::new(cv.width_px(), cv.height_px()).expect("layer"), k: cv.k },
            };
            layer.clear();
            let origin = ((CANVAS_W - vw) / 2.0, 0.0);
            self.draw_view(&mut layer, &pal, &view, origin, pressed);
            #[cfg(test)]
            { self.profile[2] = profile_at.elapsed().as_secs_f64() * 1000.0; profile_at = Instant::now(); }
            let mask = shape.as_ref().and_then(|p| cv.mask_path(p));
            // The content reaches full opacity before the island finishes growing.
            let alpha = (p * 1.35 - 0.1).clamp(0.0, 1.0);
            let scale = self.motion.content_scale + (1.0 - self.motion.content_scale) * p;
            cv.blit_area(&layer.pm, R::new(origin.0, origin.1, vw, vh).inflate(2.0), alpha, scale, pill.cx(), origin.1 + vh / 2.0, mask.as_ref());
            self.layer = Some(layer);
            #[cfg(test)]
            { self.profile[3] = profile_at.elapsed().as_secs_f64() * 1000.0; }
        }
    }

    fn draw_view(&mut self, cv: &mut Canvas, pal: &Pal, view: &View, o: (f32, f32), pressed: Option<R>) {
        let (vw, vh) = self.size_of(view);
        let body = R::new(o.0, o.1, vw, vh);
        let media = pick_media(&self.model, self.player_pc);
        let sources = (self.model.pc_media.as_ref().is_some_and(|m| m.island_allowed()), self.model.phone_media.as_ref().is_some_and(|m| m.island_allowed()));
        let key = self.song_key();
        let pv = PlayerView {
            ui: &self.ui,
            lyrics_app: self.lyrics_app(),
            with_lyrics: self.lyrics_now(),
            lines: self.ui.lyrics.as_ref().filter(|(k, _)| Some(k) == key.as_ref()).map(|(_, l)| l.as_ref()),
            volume: self.player_volume(),
        };
        let pc_ctl = (self.controls_pc(), self.cfg.modules.pc && self.model.target().is_some());
        let mut d = Draw { cv, fonts: &mut self.fonts, hits: &mut self.hits, pal, pointer: self.pointer, pressed };
        match view {
            View::Page(Page::Home) => draw_home(&mut d, &self.model, &self.cfg, body, media, self.seen_notifs, if self.cfg.modules.agents { self.agents } else { [Work::Gone; 2] }),
            View::Page(Page::Player) => draw_player(&mut d, body, media, sources, &pv),
            View::Page(Page::Files) => draw_files(&mut d, &self.model, body),
            View::Page(Page::Notifs) => draw_notifs(&mut d, &self.model, body, &self.ui, self.clock),
            View::Page(Page::Clipboard) => draw_clipboard(&mut d, &self.model, body, self.copied),
            View::Page(Page::Controls) => draw_controls(&mut d, &self.model, &self.cfg.controls, body, self.clock < self.wifi_confirm, &self.ui, pc_ctl),
            View::Call => draw_call(&mut d, &self.model, body),
            View::Offer => draw_offer(&mut d, &self.model, body),
            View::Transfer(id) => draw_transfer(&mut d, &self.model, body, id, self.clock),
            View::Note => draw_note(&mut d, &self.note, body, self.ui.note_age),
            View::Drop => {
                let look = airdrop::Look { fg: pal.fg, accent: pal.accent, on: pal.on_accent, thumb: self.ui.air_thumb.as_ref() };
                self.ui.air.draw(d.cv, d.fonts, body, &look);
            }
        }

    }
}

/// Whether the computer's player (rather than the phone's) is the one to show.
fn pick_pc(m: &Model, pref: Option<bool>) -> bool {
    if let Some(v) = pref {
        return v;
    }
    let pc = m.pc_media.as_ref().filter(|x| x.island_allowed());
    let ph = m.phone_media.as_ref().filter(|x| x.island_allowed());
    match (pc, ph) {
        (Some(p), Some(f)) => p.playing || !f.playing,
        (Some(_), None) => true,
        _ => false,
    }
}

fn pick_media(m: &Model, pref: Option<bool>) -> Option<(&super::model::Media, bool)> {
    let pc = m.pc_media.as_ref().filter(|x| x.island_allowed());
    let ph = m.phone_media.as_ref().filter(|x| x.island_allowed());
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
    /// The glow at the bottom of the island (the cover's most vivid colour while lyrics are on; else `bg`).
    bg2: Rgb,
    fg: Rgb,
    accent: Rgb,
    on_accent: Rgb,
    chip: Rgb,
    chip_hi: Rgb,
}

struct Draw<'a> {
    cv: &'a mut Canvas,
    fonts: &'a mut Fonts,
    hits: &'a mut Vec<Hit>,
    pal: &'a Pal,
    pointer: Option<(f32, f32)>,
    pressed: Option<R>,
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
        self.pressed == Some(r)
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

/// Smoothstep: eases in and out.
fn smooth(x: f32) -> f32 {
    let x = x.clamp(0.0, 1.0);
    x * x * (3.0 - 2.0 * x)
}

/// Back-out ease: overshoots a little and settles (a pop).
fn back_out(x: f32) -> f32 {
    let x = x.clamp(0.0, 1.0) - 1.0;
    1.0 + x * x * (2.7 * x + 1.7)
}

fn hsl(c: Rgb) -> (f32, f32, f32) {
    let [r, g, b] = c.map(|v| v as f32 / 255.0);
    let (mx, mn) = (r.max(g).max(b), r.min(g).min(b));
    let l = (mx + mn) / 2.0;
    if mx == mn {
        return (0.0, 0.0, l);
    }
    let d = mx - mn;
    let s = if l > 0.5 { d / (2.0 - mx - mn) } else { d / (mx + mn) };
    let h = if mx == r { (g - b) / d + if g < b { 6.0 } else { 0.0 } } else if mx == g { (b - r) / d + 2.0 } else { (r - g) / d + 4.0 };
    (h * 60.0, s, l)
}

fn rgb_of(h: f32, s: f32, l: f32) -> Rgb {
    let a = s * l.min(1.0 - l);
    let f = |n: f32| {
        let k = (n + h / 30.0) % 12.0;
        ((l - a * (k - 3.0).min(9.0 - k).clamp(-1.0, 1.0)) * 255.0).round().clamp(0.0, 255.0) as u8
    };
    [f(0.0), f(8.0), f(4.0)]
}

/// The island's colours from a cover: a near-black in the cover's own hue (the most common colour), a glow and an
/// accent from its most vivid colour that is common enough. Sampled on a 32×32 grid in 4-bit buckets.
fn cover_palette(img: &Image) -> [Rgb; 3] {
    let mut buckets: HashMap<u16, (u32, [u32; 3])> = HashMap::new();
    let (w, h) = (img.w.max(1), img.h.max(1));
    for gy in 0..32u32 {
        for gx in 0..32u32 {
            let (x, y) = (gx * w / 32, gy * h / 32);
            let i = ((y * w + x) * 4) as usize;
            let Some(p) = img.data.get(i..i + 4) else { continue };
            if p[3] < 128 {
                continue;
            }
            let key = ((p[0] as u16 >> 4) << 8) | ((p[1] as u16 >> 4) << 4) | (p[2] as u16 >> 4);
            let e = buckets.entry(key).or_insert((0, [0; 3]));
            e.0 += 1;
            for k in 0..3 {
                e.1[k] += p[k] as u32;
            }
        }
    }
    let list: Vec<(u32, Rgb)> = buckets.into_values().map(|(n, s)| (n, s.map(|v| (v / n) as u8))).collect();
    let Some(&(_, base)) = list.iter().max_by_key(|x| x.0) else { return [[0, 0, 0], [0, 0, 0], [255, 255, 255]] };
    let score = |(n, c): &(u32, Rgb)| {
        let (_, s, l) = hsl(*c);
        s * (1.0 - (l - 0.55).abs()) * (*n as f32).sqrt()
    };
    let vivid = list.iter().filter(|x| x.0 >= 8).max_by(|a, b| score(a).total_cmp(&score(b))).map_or(base, |x| x.1);
    let ((bh, bs, _), (vh, vs, _)) = (hsl(base), hsl(vivid));
    [rgb_of(bh, bs.min(0.5), 0.10), rgb_of(vh, vs.min(0.6), 0.32), rgb_of(vh, vs.clamp(0.45, 0.85), 0.70)]
}

fn header(d: &mut Draw, body: R, title: &str) {
    d.text(title, body.x + PAD, body.y + 31.0, 15.5, Weight::Bold, 1.0);
}

fn back(d: &mut Draw, body: R) {
    d.round((body.right() - PAD - 15.0, body.y + 27.0), 30.0, Icon::Back, Act::Go(Page::Home), None, d.pal.fg);
}

fn draw_home(d: &mut Draw, m: &Model, cfg: &IslandConfig, body: R, media: Option<(&super::model::Media, bool)>, seen: Instant, agents: [Work; 2]) {
    let mut y = body.y + 16.0;
    if cfg.modules.status {
        // Without a phone the row is this computer (see `modules.pc`), with what it is doing.
        let pc_mode = cfg.modules.pc && m.target().is_none();
        let downloads = m.xfers.iter().filter(|x| x.local() && x.state == XState::Running).count();
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
                icon(d.cv, if pc_mode { Icon::Cast } else { Icon::Phone }, c.0, c.1, 22.0, color(d.pal.fg, 1.0), None);
            }
        }
        d.add(R::new(body.x + PAD, y, body.w - 2.0 * PAD - 84.0, 48.0), if pc_mode && downloads > 0 { Act::Go(Page::Files) } else { Act::Device });
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
                    d.cv.squircle(R::new(bx + 4.5, mid - 3.5, 13.0 * level.max(0.04), 7.0), 1.5, color(col, 1.0), None);
                    if i.charging {
                        icon(d.cv, Icon::Bolt, bx + 11.0, mid, 10.0, color(d.pal.bg, 1.0), None);
                    }
                    d.text(&format!("{}%", i.battery), bx + 30.0, mid + 5.0, 13.5, Weight::Medium, 1.0);
                }
            }
            None if pc_mode => {
                let mut parts: Vec<String> = Vec::new();
                for a in [Agent::Claude, Agent::Codex] {
                    if agents[a as usize] == Work::Working {
                        parts.push(format!("{} {}", a.name(), t("trabajando", "working")));
                    }
                }
                if downloads > 0 {
                    parts.push(format!("{downloads} {}", if downloads == 1 { t("descarga", "download") } else { t("descargas", "downloads") }));
                }
                let sub = if parts.is_empty() { t("Conecta un teléfono para más funciones", "Connect a phone for more").to_string() } else { parts.join(" · ") };
                d.text(t("Este equipo", "This computer"), tx, mid - 3.0, 15.5, Weight::Bold, 1.0);
                d.text_in(&sub, tx, mid + 15.0, body.w - 2.0 * PAD - 58.0, 12.5, Weight::Regular, 0.6);
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

/// What the player screen needs beyond the media itself.
struct PlayerView<'a> {
    ui: &'a Ui,
    lyrics_app: bool,
    /// Lyrics on for this player: the second column is shown.
    with_lyrics: bool,
    /// The song's lines: None while asking, Some(None) when there are none.
    lines: Option<Option<&'a crate::lyrics::Lines>>,
    volume: Option<f32>,
}

fn draw_player(d: &mut Draw, body: R, media: Option<(&super::model::Media, bool)>, (has_pc, has_phone): (bool, bool), pv: &PlayerView) {
    back(d, body);
    let Some((md, is_pc)) = media else {
        d.text(t("Reproductor", "Player"), body.x + PAD, body.y + 31.0, 15.5, Weight::Bold, 1.0);
        icon(d.cv, Icon::Music, body.cx(), body.y + 78.0, 34.0, color(d.pal.fg, 0.35), None);
        d.cv.text_centered(d.fonts, t("Nada se está reproduciendo", "Nothing is playing"), body.cx(), body.y + 122.0, 13.5, Weight::Medium, d.pal.fg, 0.7);
        return;
    };
    let ly = pv.with_lyrics;
    let x0 = body.x + 20.0;
    // The player's column: the whole card, or its left part when the lyrics take the right.
    let col_w = if ly { 272.0 } else { body.w - 40.0 };
    let right = x0 + col_w;
    let art = if ly { R::new(x0, body.y + 20.0, 64.0, 64.0) } else { R::new(x0, body.y + 22.0, 84.0, 84.0) };
    let radius = if ly { 12.0 } else { 16.0 };
    match &md.art {
        Some(img) => d.cv.image(img, art, radius, 1.0, None),
        None => {
            d.cv.squircle(art, radius, color(d.pal.chip_hi, 1.0), None);
            icon(d.cv, Icon::Music, art.cx(), art.cy(), art.w * 0.36, color(d.pal.fg, 0.6), None);
        }
    }
    let tx = art.right() + if ly { 14.0 } else { 16.0 };
    let tw = (if ly { right } else { body.right() - PAD - 40.0 }) - tx;
    let (chip_y, title_y, artist_y) = if ly { (art.y + 44.0, art.y + 17.0, art.y + 35.0) } else { (body.y + 24.0, body.y + 68.0, body.y + 88.0) };
    d.text_in(&md.title, tx, title_y, tw, if ly { 16.0 } else { 17.5 }, Weight::Bold, 1.0);
    if !md.artist.is_empty() {
        d.text_in(&md.artist, tx, artist_y, tw, 13.0, Weight::Regular, 0.62);
    }
    // Which player: this computer or the phone. The other one can be picked when it has something.
    let mut x = tx;
    for (pc, label, has) in [(true, t("Este equipo", "This computer"), has_pc), (false, t("Teléfono", "Phone"), has_phone)] {
        let h = if ly { 20.0 } else { 22.0 };
        let r = R::new(x, chip_y, d.fonts.measure(label, 12.0, Weight::Medium) + 20.0, h);
        if r.right() > tx + tw + 30.0 {
            break;
        }
        let on = pc == is_pc;
        let (bg, fg) = if on { (d.pal.accent, d.pal.on_accent) } else { (if d.hot(r) && has { d.pal.chip_hi } else { d.pal.chip }, d.pal.fg) };
        d.cv.squircle(r, h / 2.0, color(bg, 1.0), None);
        d.cv.text(d.fonts, label, r.x + 10.0, r.y + h / 2.0 + 4.4, 12.0, Weight::Medium, fg, if on || has { 1.0 } else { 0.4 });
        if !on && has {
            d.add(r, Act::Source);
        }
        x = r.right() + 6.0;
    }
    // Progress: drag it to move through the song. Grows and shows its knob under the pointer.
    let py = if ly { body.y + 104.0 } else { body.y + 128.0 };
    let dur = md.duration_ms;
    let pos = md.position_now();
    let f = pv.ui.seek.unwrap_or(if dur > 0 { pos as f32 / dur as f32 } else { 0.0 }).clamp(0.0, 1.0);
    let shown_pos = if pv.ui.seek.is_some() { (f as f64 * dur as f64) as i64 } else { pos };
    let track = R::new(x0 + 44.0, py - 2.0, col_w - 88.0, 4.0);
    let grab = track.inflate(9.0);
    let active = d.hot(grab) || pv.ui.seek.is_some();
    let bar = if active { R::new(track.x, track.y - 1.0, track.w, 6.0) } else { track };
    d.cv.squircle(bar, bar.h / 2.0, color(d.pal.fg, 0.18), None);
    if f > 0.0 {
        d.cv.squircle(R::new(bar.x, bar.y, (bar.w * f).max(bar.h), bar.h), bar.h / 2.0, color(d.pal.accent, 1.0), None);
    }
    if active && dur > 0 {
        d.cv.circle(bar.x + bar.w * f, bar.cy(), 6.0, color(d.pal.accent, 1.0), None);
    }
    if dur > 0 {
        d.text(&fmt_time(shown_pos), x0, py + 4.5, 12.5, Weight::Regular, 0.6);
        let left = format!("−{}", fmt_time(dur - shown_pos));
        let w = d.fonts.measure(&left, 12.5, Weight::Regular);
        d.text(&left, right - w, py + 4.5, 12.5, Weight::Regular, 0.6);
        d.add(grab, Act::Seek);
    }
    // Controls: lyrics on the left, the transport in the middle, the volume on the right.
    // Keep the transport and volume above the rounded bottom corners in both layouts.
    let cy = body.bottom() - 36.0;
    let v = pv.ui.vol.value.clamp(0.0, 1.2);
    if pv.lyrics_app {
        let bg = if pv.ui.lyrics_on { mix(d.pal.chip_hi, d.pal.accent, 0.35) } else { d.pal.chip };
        let fg = d.pal.fg;
        d.round((x0 + 16.0, cy), 32.0, Icon::Lyrics, Act::Lyrics, Some(bg), fg);
    }
    // The speaker button stretches to the left into a slider; the transport steps aside for it.
    let open_w = if ly { 96.0 } else { 140.0 };
    let pw = 32.0 + (open_w - 32.0) * v;
    let pill = R::new(right - pw, cy - 16.0, pw, 32.0);
    if v > 0.01 {
        d.cv.squircle(pill, 16.0, color(d.pal.chip_hi, (v * 1.6).min(1.0)), None);
        let a = ((v - 0.2) / 0.5).clamp(0.0, 1.0);
        let vt = R::new(pill.x + 14.0, cy - 2.0, (pill.w - 14.0 - 36.0).max(0.0), 4.0);
        if vt.w > 2.0 && a > 0.0 {
            let val = pv.volume.unwrap_or(0.0).clamp(0.0, 1.0);
            d.cv.squircle(vt, 2.0, color(d.pal.fg, 0.20 * a), None);
            d.cv.squircle(R::new(vt.x, vt.y, (vt.w * val).max(4.0), 4.0), 2.0, color(d.pal.accent, a), None);
            if v > 0.9 {
                d.cv.circle(vt.x + vt.w * val, vt.cy(), 6.0, color(d.pal.accent, a), None);
            }
            if v > 0.6 {
                d.add(R::new(vt.x - 6.0, cy - 12.0, vt.w + 12.0, 24.0), Act::PlayerVolume);
            }
        }
    }
    let low = pv.volume.is_some_and(|x| x < 0.34);
    let (sbg, sfg) = (if v > 0.05 { d.pal.chip_hi } else { d.pal.chip }, d.pal.fg);
    d.round((right - 16.0, cy), 32.0, if low { Icon::SpeakerLow } else { Icon::Volume }, Act::VolButton, Some(sbg), sfg);
    let shift = -(if ly { 40.0 } else { 16.0 }) * v.min(1.1);
    let mid = (if ly { x0 + col_w / 2.0 } else { body.cx() }) + shift;
    let gap = if ly { 46.0 } else { 62.0 };
    let (prev, toggle, next) = if is_pc { (Act::PcMedia("prev"), Act::PcMedia("toggle"), Act::PcMedia("next")) } else { (Act::PhoneMedia("prev"), Act::PhoneMedia("toggle"), Act::PhoneMedia("next")) };
    let fg = d.pal.fg;
    let bg = d.pal.bg;
    d.round((mid - gap, cy), 30.0, Icon::Prev, prev, Some(bg), fg);
    d.round((mid, cy), 36.0, if md.playing { Icon::Pause } else { Icon::Play }, toggle, Some(fg), bg);
    d.round((mid + gap, cy), 30.0, Icon::Next, next, Some(bg), fg);
    if ly {
        d.cv.squircle(R::new(body.x + 312.0, body.y + 22.0, 1.0, body.h - 44.0), 0.5, color(d.pal.fg, 0.14), None);
        draw_lyrics(d, R::new(body.x + 334.0, body.y + 14.0, body.w - 334.0 - 56.0, body.h - 28.0), pv);
    }
}

/// Splits `s` into rows no wider than `max`, at most `rows` of them (the last one cut with an ellipsis).
fn wrap(fonts: &mut Fonts, s: &str, size: f32, w: Weight, max: f32, rows: usize) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut cur = String::new();
    for word in s.split_whitespace() {
        let next = if cur.is_empty() { word.to_string() } else { format!("{cur} {word}") };
        if fonts.measure(&next, size, w) <= max || cur.is_empty() {
            cur = next;
        } else {
            out.push(std::mem::replace(&mut cur, word.to_string()));
        }
    }
    if !cur.is_empty() || out.is_empty() {
        out.push(cur);
    }
    if out.len() > rows {
        let rest = out[rows - 1..].join(" ");
        out.truncate(rows - 1);
        out.push(fonts.fit(&rest, size, w, max));
    }
    out
}

/// The lyrics column: the sung line bright, the rest dimmed, scrolling so the sung line stays near the top.
fn draw_lyrics(d: &mut Draw, area: R, pv: &PlayerView) {
    let status = |d: &mut Draw, msg: &str| {
        let fit = d.fonts.fit(msg, 14.0, Weight::Medium, area.w);
        d.text(&fit, area.x, area.y + 30.0, 14.0, Weight::Medium, 0.62);
    };
    let lines = match pv.lines {
        None => return status(d, t("Buscando la letra…", "Looking for the lyrics…")),
        Some(None) => return status(d, t("No hay letra para esta canción", "No lyrics for this song")),
        Some(Some(l)) if l.is_empty() => return status(d, t("Instrumental ♪", "Instrumental ♪")),
        Some(Some(l)) => l,
    };
    const SIZE: f32 = 18.0;
    const ROW: f32 = 23.0;
    const GAP: f32 = 9.0;
    let cur = pv.ui.lyric_idx;
    let s = pv.ui.lyric_scroll.value.max(0.0);
    let base = s.floor() as usize;
    // Only the lines near the sung one are laid out: the list is placed relative to it.
    let from = base.saturating_sub(2);
    let to = (base + 9).min(lines.len());
    let mut blocks: Vec<(usize, Vec<String>)> = Vec::new();
    for (i, line) in lines.iter().enumerate().take(to).skip(from) {
        let text = if line.1.is_empty() { "♪".to_string() } else { line.1.clone() };
        blocks.push((i, wrap(d.fonts, &text, SIZE, Weight::Bold, area.w, 3)));
    }
    let height = |rows: usize| rows as f32 * ROW + GAP;
    // y of the base line's top, then the fraction of the way to the next one.
    let mut top = area.y + 8.0;
    for (i, rows) in &blocks {
        if *i < base {
            top -= height(rows.len());
        }
    }
    let base_h = blocks.iter().find(|(i, _)| *i == base).map_or(ROW + GAP, |(_, r)| height(r.len()));
    let mut y = top - s.fract() * base_h;
    for (i, rows) in &blocks {
        let bright = Some(*i) == cur;
        for row in rows {
            let baseline = y + 17.0;
            // Faded towards the edges of the column, so lines come and go softly.
            let fade = ((y - area.y + 4.0) / 22.0).clamp(0.0, 1.0) * ((area.bottom() - (y + ROW)) / 30.0).clamp(0.0, 1.0);
            if fade > 0.01 {
                d.text(row, area.x, baseline, SIZE, Weight::Bold, if bright { 1.0 } else { 0.32 } * fade);
            }
            y += ROW;
        }
        y += GAP;
        if y > area.bottom() + 10.0 {
            break;
        }
    }
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
        XState::Running if x.no_total() => fmt_size(x.done),
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

fn draw_notifs(d: &mut Draw, m: &Model, body: R, ui: &Ui, clock: f64) {
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
        let key = n.key.as_str();
        let replying = ui.replying.as_deref() == Some(key);
        let h = if replying { 132.0 } else { 50.0 };
        let y = body.y + ui.rows.get(key).map_or(52.0 + 54.0 * i as f32, |s| s.value);
        // Sideways: a drag, a drag sliding back, or the row leaving.
        let mut off = ui.swipe.as_ref().filter(|(k, _, _)| k == key).map_or(0.0, |(_, _, o)| *o);
        if let Some(s) = ui.swipe_back.get(key) {
            off = s.value;
        }
        let mut a = (1.0 - off / 300.0).clamp(0.25, 1.0);
        let gone = ui.gone.get(key).copied();
        if let Some(p) = gone {
            // Out to the right, accelerating, and fading.
            off += (body.w - off) * p * p;
            a *= 1.0 - p;
        }
        if a < 0.01 {
            continue;
        }
        let r = R::new(body.x + 10.0 + off, y, body.w - 20.0, h);
        let hot = d.hot(r) && ui.swipe.is_none() && gone.is_none();
        if hot || replying {
            d.cv.squircle(r, 16.0, color(d.pal.chip, a), None);
        }
        let read = ui.read.contains(key);
        if !read {
            d.cv.circle(r.x + 7.0, r.y + 25.0, 3.5, color(d.pal.accent, a), None);
        }
        let c = (r.x + 30.0, r.y + 25.0);
        match (&n.avatar, m.icon(&n.pkg)) {
            (Some(av), app) => badged(d, av, 16.0, app, R::new(c.0 - 16.0, c.1 - 16.0, 32.0, 32.0), a),
            (None, Some(img)) => d.cv.image(img, R::new(c.0 - 16.0, c.1 - 16.0, 32.0, 32.0), 9.0, a, None),
            (None, None) => d.avatar(c, 32.0, &n.app),
        }
        // Actions on hover, right to left: dismiss, mark as read, reply.
        let mut right = r.right() - 8.0;
        if hot || replying {
            let (bg, fg) = (d.pal.chip_hi, d.pal.fg);
            d.round((right - 14.0, r.y + 25.0), 28.0, Icon::Close, Act::Dismiss(n.key.clone()), Some(bg), fg);
            right -= 34.0;
            if !read {
                d.round((right - 14.0, r.y + 25.0), 28.0, Icon::MailRead, Act::NotifRead(n.key.clone()), Some(bg), fg);
                right -= 34.0;
            }
            if n.replyable {
                let rbg = if replying { mix(bg, d.pal.accent, 0.35) } else { bg };
                d.round((right - 14.0, r.y + 25.0), 28.0, Icon::Reply, Act::NotifReply(n.key.clone()), Some(rbg), fg);
                right -= 34.0;
            }
        }
        let tx = r.x + 54.0;
        let tw = right - tx - 4.0;
        let ta = if read { 0.62 } else { 1.0 } * a;
        let title = if n.title.is_empty() { n.app.clone() } else { n.title.clone() };
        let title = d.fonts.fit(&title, 13.5, Weight::Bold, tw);
        let used = d.text(&title, tx, r.y + 21.0, 13.5, Weight::Bold, ta);
        if !n.title.is_empty() && !n.app.is_empty() && used + 30.0 < tw {
            d.text_in(&format!(" · {}", n.app), tx + used, r.y + 21.0, tw - used, 11.5, Weight::Medium, 0.55 * a);
        }
        match ui.replied.get(key) {
            Some(sent) => {
                icon(d.cv, Icon::Check, tx + 6.0, r.y + 34.0, 13.0, color(SUCCESS, a), None);
                let label = t("Respondiste: ", "You replied: ");
                let lw = d.cv.text(d.fonts, label, tx + 15.0, r.y + 38.0, 12.5, Weight::Bold, SUCCESS, a);
                d.text_in(sent, tx + 15.0 + lw, r.y + 38.0, tw - 15.0 - lw, 12.5, Weight::Regular, 0.65 * a);
            }
            None => d.text_in(&n.text, tx, r.y + 38.0, tw, 12.5, Weight::Regular, 0.65 * a),
        }
        if replying {
            draw_reply(d, r, n, ui, clock);
        }
        if gone.is_none() {
            d.add(R::new(r.x, r.y, r.w, 50.0), Act::NotifRow(n.key.clone()));
        }
    }
}

/// Quick answers and a field to write one, under a chat notification.
fn draw_reply(d: &mut Draw, r: R, n: &super::model::Notif, ui: &Ui, clock: f64) {
    let mut x = r.x + 54.0;
    for (i, q) in QUICK.iter().enumerate() {
        let label = t(q.0, q.1);
        let chip = R::new(x, r.y + 58.0, d.fonts.measure(label, 12.5, Weight::Medium) + 22.0, 26.0);
        if chip.right() > r.right() - 10.0 {
            break;
        }
        let bg = if d.is_down(chip) { mix(d.pal.chip_hi, d.pal.fg, 0.18) } else if d.hot(chip) { mix(d.pal.chip_hi, d.pal.fg, 0.08) } else { d.pal.chip_hi };
        d.cv.squircle(chip, 13.0, color(bg, 1.0), None);
        let fg = d.pal.fg;
        d.cv.text(d.fonts, label, chip.x + 11.0, chip.y + 17.5, 12.5, Weight::Medium, fg, 1.0);
        d.add(chip, Act::QuickReply(n.key.clone(), i));
        x = chip.right() + 6.0;
    }
    let field = R::new(r.x + 54.0, r.y + 92.0, r.w - 54.0 - 10.0, 32.0);
    d.cv.squircle(field, 16.0, color(d.pal.chip_hi, 1.0), None);
    let accent = d.pal.accent;
    if let Some(p) = super::gfx::squircle(field, 16.0, super::gfx::squircle_n(16.0, field.h)) {
        d.cv.stroke_path(&p, color(accent, 0.9), 1.4, None);
    }
    let max = field.w - 12.0 - 40.0;
    if ui.reply_text.is_empty() {
        let hint = format!("{} {}…", t("Responder a", "Reply to"), if n.title.is_empty() { &n.app } else { &n.title });
        d.text_in(&hint, field.x + 12.0, field.cy() + 4.6, max, 13.0, Weight::Regular, 0.5);
    }
    // The end of what is written, so the caret is always in view.
    let mut shown: &str = &ui.reply_text;
    while !shown.is_empty() && d.fonts.measure(shown, 13.0, Weight::Regular) > max {
        let mut it = shown.char_indices();
        it.next();
        shown = it.next().map_or("", |(i, _)| &shown[i..]);
    }
    let w = d.text(shown, field.x + 12.0, field.cy() + 4.6, 13.0, Weight::Regular, 1.0);
    if (clock * 2.0).floor() as i64 % 2 == 0 {
        d.cv.squircle(R::new(field.x + 13.0 + w, field.cy() - 8.0, 1.6, 16.0), 0.8, color(accent, 1.0), None);
    }
    let on = d.pal.on_accent;
    d.round((field.right() - 18.0, field.cy()), 26.0, Icon::Send, Act::SendReply(n.key.clone()), Some(accent), on);
}

fn draw_clipboard(d: &mut Draw, m: &Model, body: R, copied: Option<(usize, f32)>) {
    back(d, body);
    header(d, body, t("Portapapeles", "Clipboard"));
    let r = R::new(body.x + PAD, body.y + 48.0, body.w - 2.0 * PAD, 36.0);
    // Seconds since the last copy or send (the "copied" state lasts 1.3 s).
    let since = copied.map(|(i, left)| (i, 1.3 - left, left));
    let (accent, on) = (d.pal.accent, d.pal.on_accent);
    if m.target().is_some() {
        // "Send" and "Sent" swap places: the old label leaves upwards, the new one rises.
        let e = since.filter(|s| s.0 == usize::MAX).map_or(0.0, |(_, t0, left)| smooth((t0 / 0.38).min(left / 0.38).min(1.0)));
        let down = d.is_down(r);
        let rr = if down { r.inflate(-1.5) } else { r };
        let fill = if down { mix(accent, d.pal.fg, 0.28) } else if d.hot(r) { mix(accent, d.pal.fg, 0.16) } else { accent };
        d.cv.squircle(rr, rr.h / 2.0, color(fill, 1.0), None);
        let send = t("Enviar mi portapapeles al teléfono", "Send my clipboard to the phone");
        let sent = t("Enviado al teléfono", "Sent to the phone");
        if e < 0.999 {
            let w = d.fonts.measure(send, 13.0, Weight::Medium);
            d.cv.text(d.fonts, send, r.cx() - w / 2.0, r.cy() + 4.6 - 12.0 * e, 13.0, Weight::Medium, on, 1.0 - e);
        }
        if e > 0.001 {
            let w = d.fonts.measure(sent, 13.0, Weight::Medium) + 20.0;
            let y = r.cy() + 12.0 * (1.0 - e);
            icon(d.cv, Icon::Check, r.cx() - w / 2.0 + 7.0, y, 15.0, color(on, e), None);
            d.cv.text(d.fonts, sent, r.cx() - w / 2.0 + 20.0, y + 4.6, 13.0, Weight::Medium, on, e);
        }
        d.add(r, Act::SendClip);
    } else {
        d.pill(r, t("Sin teléfono conectado", "No phone connected"), Act::OpenApp, d.pal.chip, d.pal.fg);
    }
    for (i, c) in m.clips.iter().take(3).enumerate() {
        let row = R::new(body.x + PAD, body.y + 96.0 + i as f32 * 38.0, body.w - 2.0 * PAD, 34.0);
        let hot = d.hot(row);
        let down = d.is_down(row);
        // Copied: the copy icon turns into a check, the row warms green and "Copied" slides in; then back.
        let (k_in, k_out) = since.filter(|s| s.0 == i).map_or((0.0, 0.0), |(_, t0, left)| ((t0 / 0.38).min(1.0), (left / 0.3).min(1.0)));
        let base = if hot { d.pal.chip_hi } else { d.pal.chip };
        let bg = mix(base, SUCCESS, 0.16 * k_in.min(k_out));
        let rr = if down { row.inflate(-1.2) } else { row };
        d.cv.squircle(rr, 17.0, color(bg, 1.0), None);
        let (ix, iy) = (row.x + 20.0, row.cy());
        let out = smooth(k_in) * k_out;
        if out < 0.999 {
            icon(d.cv, Icon::Copy, ix, iy, 16.0 * (1.0 - out), color(d.pal.fg, 1.0), None);
        }
        if out > 0.001 {
            icon(d.cv, Icon::Check, ix, iy, 16.0 * back_out(k_in) * k_out, color(SUCCESS, 1.0), None);
        }
        let tag = t("Copiado", "Copied");
        let tag_w = d.fonts.measure(tag, 12.0, Weight::Bold);
        let shown = smooth(k_in) * k_out;
        d.text_in(&c.text, row.x + 38.0, row.cy() + 4.6, row.w - 52.0 - if shown > 0.0 { tag_w + 10.0 } else { 0.0 }, 13.0, Weight::Regular, 0.95);
        if shown > 0.001 {
            d.cv.text(d.fonts, tag, row.right() - 14.0 - tag_w + 10.0 * (1.0 - shown), row.cy() + 4.4, 12.0, Weight::Bold, SUCCESS, shown);
        }
        d.add(row, Act::CopyClip(i));
    }
    if m.clips.is_empty() {
        d.cv.text_centered(d.fonts, t("Lo que copies en el teléfono aparece aquí", "What you copy on the phone shows up here"), body.cx(), (r.bottom() + body.bottom()) / 2.0 + 4.4, 12.5, Weight::Regular, d.pal.fg, 0.5);
    }
}

fn tile(d: &mut Draw, r: R, ic: Icon, label: &str, on: bool, act: Act, fx: Option<&TileFx>, warm: bool) {
    let down = d.is_down(r);
    // Pressed, it sinks a little.
    let rr = if down { r.inflate(-2.0) } else { r };
    let v = fx.map_or(if on { 1.0 } else { 0.0 }, |f| f.v.value.clamp(0.0, 1.0));
    let tint = |c: Rgb, d: &Draw| if down { mix(c, d.pal.fg, 0.25) } else if d.hot(r) { mix(c, d.pal.fg, 0.14) } else { c };
    let base = tint(d.pal.chip, d);
    let accent = tint(d.pal.accent, d);
    let path = super::gfx::squircle(rr, 20.0, super::gfx::squircle_n(20.0, rr.h));
    if v >= 0.999 {
        d.cv.squircle(rr, 20.0, color(accent, 1.0), None);
    } else {
        d.cv.squircle(rr, 20.0, color(base, 1.0), None);
        if v > 0.001 {
            // The colour grows from where the tile was touched (and shrinks back to it).
            let o = fx.map_or((r.w / 2.0, r.h / 2.0), |f| f.o);
            let (cx, cy) = (r.x + o.0.clamp(0.0, r.w), r.y + o.1.clamp(0.0, r.h));
            let far = [(r.x, r.y), (r.right(), r.y), (r.x, r.bottom()), (r.right(), r.bottom())].iter().map(|(x, y)| ((x - cx).powi(2) + (y - cy).powi(2)).sqrt()).fold(0.0f32, f32::max);
            let mask = path.as_ref().and_then(|p| d.cv.mask_path(p));
            d.cv.circle(cx, cy, far * v, color(accent, 1.0), mask.as_ref());
        }
    }
    // The torch lights up: a warm glow round the inside, once.
    if warm {
        if let (Some(f), Some(p)) = (fx, path.as_ref()) {
            if f.v.target > 0.5 && f.age < 0.9 {
                let g = (f.age / 0.3).min(1.0) * (1.0 - f.age / 0.9);
                d.cv.stroke_path(p, color([255, 228, 160], 0.85 * g), 3.0, None);
            }
        }
    }
    let fg = mix(d.pal.fg, d.pal.on_accent, smooth(v));
    // The icon jumps when it switches on, and dips when it switches off.
    let pop = match fx {
        Some(f) if f.v.target > 0.5 && f.age < 0.45 => {
            let k = f.age / 0.45;
            if k < 0.35 { 1.0 + 0.28 * (k / 0.35) } else if k < 0.7 { 1.28 - 0.34 * ((k - 0.35) / 0.35) } else { 0.94 + 0.06 * ((k - 0.7) / 0.3) }
        }
        Some(f) if f.v.target <= 0.5 && f.age < 0.35 => {
            let k = f.age / 0.35;
            if k < 0.4 { 1.0 - 0.18 * (k / 0.4) } else { 0.82 + 0.18 * ((k - 0.4) / 0.6) }
        }
        _ => 1.0,
    };
    let draw = if v > 0.5 { icon_filled } else { icon };
    draw(d.cv, ic, r.cx(), r.y + 22.0, 22.0 * pop, color(fg, 1.0), None);
    let label = d.fonts.fit(label, 12.0, Weight::Medium, r.w - 8.0);
    let w = d.fonts.measure(&label, 12.0, Weight::Medium);
    d.cv.text(d.fonts, &label, r.cx() - w / 2.0, r.y + 49.0, 12.0, Weight::Medium, fg, 1.0);
    d.add(r, act);
}

/// Every control the island can show: the app's phone controls (same keys as `controlNames` in controls.dart)
/// plus "ringer", which cycles sound, vibrate and silent.
pub const CONTROLS: [&str; 15] = ["dnd", "torch", "find", "ringer", "wifi", "bt", "rotate", "lock", "hotspot", "camBack", "camFront", "screen", "shot", "mute", "clip"];

/// Three rows of four: what fits the island's canvas.
pub const MAX_CONTROLS: usize = 12;

/// The controls the user chose (Ajustes), in their order; the adb ones only when adb reaches the phone.
fn control_keys(list: &str, adb: bool) -> Vec<&'static str> {
    list.split(',')
        .filter_map(|k| CONTROLS.into_iter().find(|x| *x == k.trim()))
        .filter(|k| adb || !matches!(*k, "wifi" | "bt" | "rotate" | "lock" | "hotspot" | "camBack" | "camFront" | "shot"))
        .take(MAX_CONTROLS)
        .collect()
}

/// Where the tiles end: rows of four 62-high tiles, 8 apart, under the 48 of the header.
fn controls_top(n: usize) -> f32 {
    let rows = n.div_ceil(4);
    if rows == 0 { 40.0 } else { 48.0 + rows as f32 * 70.0 - 8.0 }
}

/// The "This computer | Phone" switch (like the player's): `pc` is the side shown, `act` flips it.
fn source_switch(d: &mut Draw, x: f32, y: f32, pc: bool, act: Act) {
    let mut x = x;
    for (is_pc, label) in [(true, t("Este equipo", "This computer")), (false, t("Teléfono", "Phone"))] {
        let r = R::new(x, y, d.fonts.measure(label, 12.0, Weight::Medium) + 20.0, 22.0);
        let on = is_pc == pc;
        let (bg, fg) = if on { (d.pal.accent, d.pal.on_accent) } else { (if d.hot(r) { d.pal.chip_hi } else { d.pal.chip }, d.pal.fg) };
        d.cv.squircle(r, 11.0, color(bg, 1.0), None);
        d.cv.text(d.fonts, label, r.x + 10.0, r.y + 15.4, 12.0, Weight::Medium, fg, 1.0);
        if !on {
            d.add(r, act.clone());
        }
        x = r.right() + 6.0;
    }
}

/// This computer's controls: microphone, lock, sleep, screenshot, and the output volume with its mute.
fn draw_pc_controls(d: &mut Draw, body: R, ui: &Ui) {
    let mic = ui.pc_mic_muted.unwrap_or(false);
    let tiles = [
        ("pcmic", Icon::MicOff, if mic { t("Mic apagado", "Mic off") } else { t("Micrófono", "Microphone") }, mic, Act::Pc("mic")),
        ("pclock", Icon::Lock, t("Bloquear", "Lock"), false, Act::Pc("lock")),
        ("pcsleep", Icon::Moon, t("Suspender", "Sleep"), false, Act::Pc("sleep")),
        ("pcshot", Icon::Screenshot, t("Captura", "Screenshot"), false, Act::Pc("shot")),
    ];
    let tile_w = (body.w - 2.0 * PAD - 3.0 * 8.0) / 4.0;
    for (i, (k, ic, label, on, act)) in tiles.into_iter().enumerate() {
        tile(d, R::new(body.x + PAD + i as f32 * (tile_w + 8.0), body.y + 48.0, tile_w, 62.0), ic, label, on, act, ui.tiles.get(k), false);
    }
    let track = R::new(body.x + PAD + 30.0, body.y + controls_top(4) + 22.0, body.w - 2.0 * PAD - 30.0, 10.0);
    let fg = d.pal.fg;
    d.round((body.x + PAD + 10.0, track.cy()), 26.0, if ui.pc_out_muted == Some(true) { Icon::Mute } else { Icon::Volume }, Act::Pc("mute"), None, fg);
    let f = ui.pc_volume.unwrap_or(0.0).clamp(0.0, 1.0);
    let accent = d.pal.accent;
    d.bar(track, f, accent);
    d.cv.circle(track.x + (track.w * f).clamp(5.0, track.w - 5.0), track.cy(), 7.0, color(fg, 1.0), None);
    d.add(R::new(track.x, track.y - 10.0, track.w, track.h + 20.0), Act::PcVol);
    d.text(t("Volumen del equipo", "Computer volume"), track.x, track.bottom() + 17.0, 12.5, Weight::Regular, 0.5);
}

fn draw_controls(d: &mut Draw, m: &Model, list: &str, body: R, wifi_confirm: bool, ui: &Ui, (pc, switch): (bool, bool)) {
    back(d, body);
    if switch {
        source_switch(d, body.x + PAD, body.y + 16.0, pc, Act::ControlsSource);
    } else {
        header(d, body, if pc { t("Controles de este equipo", "This computer's controls") } else { t("Controles del teléfono", "Phone controls") });
    }
    if pc {
        draw_pc_controls(d, body, ui);
        return;
    }
    let fx = &ui.tiles;
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
            "lock" => (Icon::Lock, t("Bloquear", "Lock"), false, Act::Adb("lock")),
            "hotspot" => (Icon::Router, t("Zona Wi-Fi", "Hotspot"), false, Act::Adb("hotspot")),
            "camBack" => (Icon::Camera, t("Trasera", "Rear"), false, Act::App("camBack")),
            "camFront" => (Icon::CameraSwitch, t("Frontal", "Front"), false, Act::App("camFront")),
            "screen" => (Icon::Cast, t("Ver pantalla", "View screen"), false, Act::App("screen")),
            "shot" => (Icon::Screenshot, t("Captura", "Screenshot"), false, Act::App("shot")),
            "mute" => (Icon::Mute, t("Silenciar", "Mute"), st.ringer == "silent", Act::Mute),
            _ => (Icon::ClipSend, t("Portapapeles", "Clipboard"), false, Act::SendClip),
        };
        let (col, row) = (i % 4, i / 4);
        tile(d, R::new(body.x + PAD + col as f32 * (tile_w + 8.0), body.y + 48.0 + row as f32 * 70.0, tile_w, 62.0), ic, label, on, act, fx.get(k), *k == "torch");
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
/// The closed island's picture of what plays: the cover (decoded once per song, see `run.rs`) with the source app's
/// icon on its corner; no cover: the app's icon alone; neither: a music note.
fn draw_cover(d: &mut Draw, md: Option<&super::model::Media>, left: R, a: f32) {
    match (md.and_then(|x| x.art.as_ref()), md.and_then(|x| x.icon.as_ref())) {
        (Some(art), app) => badged(d, art, 7.0, app, left, a),
        (None, Some(app)) => d.cv.image(app, left, 6.0, a, None),
        (None, None) => icon(d.cv, Icon::Music, left.cx(), left.cy(), 18.0, color(d.pal.fg, a), None),
    }
}

/// A picture (a cover, a contact's photo) with the app's icon on its bottom-right corner, ringed in the island's colour.
fn badged(d: &mut Draw, pic: &Image, radius: f32, app: Option<&Image>, r: R, a: f32) {
    d.cv.image(pic, r, radius, a, None);
    if let Some(app) = app {
        let s = (r.w * 0.5).round().max(14.0);
        let b = R::new(r.right() - s + 4.0, r.bottom() - s + 4.0, s, s);
        d.cv.squircle(b.inflate(1.5), s * 0.32, color(d.pal.bg, a), None);
        d.cv.image(app, b, s * 0.21, a, None);
    }
}

fn draw_live(d: &mut Draw, m: &Model, pref: Option<bool>, l: Live, pill: R, a: f32, clock: f64, lyric: &(String, String, f32), look: (f32, f32, f32)) {
    let cy = pill.cy();
    match l {
        Live::Lyric => {
            draw_cover(d, pick_media(m, pref).map(|(md, _)| md), R::new(pill.x + 10.0, cy - 13.0, 26.0, 26.0), a);
            let (now, before, e) = (&lyric.0, &lyric.1, lyric.2);
            let (x, max) = (pill.x + 48.0, pill.w - 48.0 - 18.0);
            // The old line leaves upwards while the new one rises into place.
            if e < 1.0 && !before.is_empty() {
                let old = d.fonts.fit(before, 15.0, Weight::Medium, max);
                d.cv.text(d.fonts, &old, x, cy + 5.2 - 14.0 * e, 15.0, Weight::Medium, d.pal.fg, a * (1.0 - e).powi(2));
            }
            let line = d.fonts.fit(now, 15.0, Weight::Medium, max);
            d.cv.text(d.fonts, &line, x, cy + 5.2 + 14.0 * (1.0 - e), 15.0, Weight::Medium, d.pal.fg, a * e * e);
        }
        Live::Media => {
            let left = R::new(pill.x + 10.0, cy - 13.0, 26.0, 26.0);
            let md = pick_media(m, pref).map(|(md, _)| md);
            draw_cover(d, md, left, a);
            if let Some(md) = md {
                let title = if md.title.is_empty() { &md.artist } else { &md.title };
                let x = left.right() + 12.0;
                let max = pill.right() - 14.0 - 4.0 * 5.5 - 12.0 - x;
                let line = d.fonts.fit(title, 15.0, Weight::Medium, max);
                d.cv.text(d.fonts, &line, x, cy + 5.2, 15.0, Weight::Medium, d.pal.fg, a);
            }
            // Four bars that dance, each at its own pace: two waves per bar so they never look like a loop.
            // On whole device pixels: a 3 px bar on a half pixel blurs thinner than its neighbours and shimmers.
            let px = d.cv.k;
            let snap = |v: f32| (v * px).round() / px;
            let w = snap(3.0).max(1.0 / px);
            for i in 0..4 {
                let k = i as f32;
                let t = clock as f32;
                let wave = 0.5 + 0.3 * (t * (6.1 + k * 1.3) + k * 1.7).sin() + 0.2 * (t * (9.7 - k * 0.9) + k * 2.9).sin();
                let h = snap(4.0 + 12.0 * wave.clamp(0.0, 1.0));
                let x = snap(pill.right() - 14.0 - (3 - i) as f32 * 5.5 - 1.5);
                d.cv.squircle(R::new(x, snap(cy - h / 2.0), w, h), w / 2.0, color(d.pal.accent, a), None);
            }
        }
        Live::Call => {
            let Some((_, c)) = m.call() else { return };
            // The phone in a green dot with a ring that keeps spreading from it: the call goes on.
            let (cx, k) = (pill.x + 24.0, (clock * 0.8).fract() as f32);
            d.cv.ring(cx, cy, 11.0 + 6.5 * k, color(SUCCESS, a * 0.7 * (1.0 - k)), 2.0, None);
            d.cv.circle(cx, cy, 11.0, color(SUCCESS, a), None);
            icon(d.cv, Icon::Call, cx, cy, 13.0, color([255, 255, 255], a), None);
            let right = match c.since {
                Some(s) => fmt_time(s.elapsed().as_millis() as i64),
                None => t("Entrante", "Incoming").to_string(),
            };
            let rw = d.fonts.measure(&right, 15.0, Weight::Bold);
            d.cv.text(d.fonts, &right, pill.right() - 16.0 - rw, cy + 5.2, 15.0, Weight::Bold, SUCCESS, a);
            let mut end = pill.right() - 16.0 - rw - 10.0;
            if c.muted {
                icon(d.cv, Icon::MicOff, end - 8.0, cy, 15.0, color(DANGER, a), None);
                end -= 22.0;
            }
            let name = if c.name.is_empty() { t("Llamada", "Call").to_string() } else { c.name.clone() };
            let line = d.fonts.fit(&name, 15.0, Weight::Medium, end - (pill.x + 44.0));
            d.cv.text(d.fonts, &line, pill.x + 44.0, cy + 5.2, 15.0, Weight::Medium, d.pal.fg, a);
        }
        Live::CallEnded(secs) => {
            let cx = pill.x + 24.0;
            d.cv.circle(cx, cy, 11.0, color(DANGER, a), None);
            icon(d.cv, Icon::CallEnd, cx, cy, 13.0, color([255, 255, 255], a), None);
            d.cv.text(d.fonts, t("Llamada finalizada", "Call ended"), pill.x + 44.0, cy + 5.2, 15.0, Weight::Medium, d.pal.fg, a);
            if secs >= 0 {
                let s = fmt_time(secs * 1000);
                let w = d.fonts.measure(&s, 15.0, Weight::Bold);
                d.cv.text(d.fonts, &s, pill.right() - 16.0 - w, cy + 5.2, 15.0, Weight::Bold, d.pal.fg, a * 0.6);
            }
        }
        Live::Charging(level) => {
            icon(d.cv, Icon::Bolt, pill.x + 22.0, cy, 20.0, color(SUCCESS, a), None);
            d.cv.text(d.fonts, t("Cargando", "Charging"), pill.x + 38.0, cy + 5.2, 15.0, Weight::Medium, d.pal.fg, a);
            if level >= 0 {
                let s = format!("{level}%");
                let w = d.fonts.measure(&s, 15.0, Weight::Bold);
                d.cv.text(d.fonts, &s, pill.right() - 16.0 - w, cy + 5.2, 15.0, Weight::Bold, SUCCESS, a);
            }
        }
        Live::Agent(ag) | Live::AgentDone(ag) => {
            let done = matches!(l, Live::AgentDone(_));
            let (age, mini, out) = look;
            let left = R::new(pill.x + 11.0, cy - 11.0, 26.0, 22.0);
            match ag {
                Agent::Claude => claude_mascot(d, left, age, done, out, a),
                Agent::Codex => codex_glyph(d, left, age, done, out, a),
            }
            // The words go first when it leaves.
            let a = a * (1.0 - out * 3.0).clamp(0.0, 1.0);
            // The line fades as the notch folds into the creature and its dots.
            let ta = a * (1.0 - mini);
            let x = left.right() + 11.0;
            if ta > 0.02 {
                let msg = format!("{} {}", ag.name(), if done { t("terminó", "finished") } else { t("trabajando…", "working…") });
                let line = d.fonts.fit(&msg, 15.0, Weight::Medium, pill.right() - 44.0 - x);
                d.cv.text(d.fonts, &line, x, cy + 5.2, 15.0, Weight::Medium, d.pal.fg, ta);
            }
            if done {
                icon(d.cv, Icon::Check, pill.right() - 24.0, cy, 18.0, color(SUCCESS, a * (1.0 - mini)), None);
            } else {
                // Three dots take turns at being lit.
                let tint = if ag == Agent::Claude { CLAUDE } else { d.pal.fg };
                let tick = (clock * 3.0) as u32;
                // Never over the creature while the notch folds.
                let x0 = (pill.right() - 38.0).max(left.right() + 8.0);
                for i in 0..3u32 {
                    d.cv.circle(x0 + 8.0 * i as f32, cy, 2.2, color(tint, a * if (tick + i) % 3 == 0 { 1.0 } else { 0.3 }), None);
                }
            }
        }
    }
}

/// Claude Code's orange.
const CLAUDE: Rgb = [217, 119, 87];

/// Squash-and-stretch of an entrance: (x scale, y scale) for `t` seconds after appearing.
fn pop(t: f32) -> (f32, f32) {
    let p = (t / 0.4).clamp(0.0, 1.0);
    let (s, w) = (back_out(p), (p * std::f32::consts::PI).sin() * 0.14);
    (s * (1.0 + w), s * (1.0 - w))
}

/// The way out, `o` 0..1: a quick squash and stretch, then it shrinks to nothing.
fn gone(o: f32) -> (f32, f32) {
    let s = 1.0 - smooth(((o - 0.15) / 0.85).clamp(0.0, 1.0));
    let w = (o * std::f32::consts::PI * 2.0).sin() * 0.18 * (1.0 - o);
    (s * (1.0 + w), s * (1.0 - w))
}

/// How high it has hopped on its way out, in logical pixels: up toward the notch.
fn leap(o: f32) -> f32 {
    10.0 * (o * std::f32::consts::PI * 0.75).sin().max(0.0) + 6.0 * o
}

/// Height of the two hops of a celebration, in rows, `t` seconds after finishing.
fn hop(t: f32) -> f32 {
    if !(0.0..1.2).contains(&t) {
        return 0.0;
    }
    (t * 2.0 * std::f32::consts::PI / 0.6).sin().abs() * 3.0 * (1.0 - t / 1.2)
}

/// A little blocky creature in Claude's orange, drawn on whole device pixels. Working: it bobs, its legs and arms
/// alternate like typing, it blinks and now and then glances sideways as if thinking. Done: it hops with its arms up
/// and sparkles. `t`: seconds since it appeared (or finished). `out` (0..1): it hops up and shrinks back into the
/// notch as the island lets it go.
fn claude_mascot(d: &mut Draw, r: R, t: f32, done: bool, out: f32, a: f32) {
    let k = d.cv.k;
    let snap = |v: f32| (v * k).round() / k;
    let u = snap(2.0).max(1.0 / k);
    let (x0, y0) = (snap(r.cx() - 6.5 * u), snap(r.cy() - 4.5 * u));
    let (sx, sy) = if out > 0.0 { gone(out) } else if done { (1.0, 1.0) } else { pop(t) };
    let (fx, fy) = (x0 + 6.5 * u, y0 + 9.0 * u);
    let step = (t * 6.0) as i32 & 1;
    let blink = t % 3.7 < 0.14;
    // A glance every 7 s: left, right, back.
    let g = t % 7.0 - 5.6;
    let look = if done || !(0.0..1.4).contains(&g) { 0.0 } else if g < 0.5 { -1.0 } else if g < 1.0 { 1.0 } else { 0.0 };
    let jump = if out > 0.0 { leap(out) } else if done { snap(hop(t) * u) } else { 0.0 };
    let bob = if done || step == 0 { 0.0 } else { 1.0 / k };
    let up = done && t < 1.6;
    // Blocks scale around the feet while it pops in; at rest the scale is 1 and they land on whole pixels.
    let mut block = |c: f32, row: f32, w: f32, h: f32, col: Rgb| {
        let (bx, by) = (x0 + c * u, y0 + row * u - jump - bob);
        d.cv.squircle(R::new(fx + (bx - fx) * sx, fy + (by - fy) * sy, w * u * sx, h * u * sy), 0.0, color(col, a), None);
    };
    block(2.0, 0.0, 9.0, 7.0, CLAUDE);
    // Arms: typing alternately, or raised.
    let (la, ra) = if up { (0.0, 0.0) } else { (step as f32, 1.0 - step as f32) };
    block(0.0, if up { 1.0 } else { 3.0 + la }, 2.0, 2.0, CLAUDE);
    block(11.0, if up { 1.0 } else { 3.0 + ra }, 2.0, 2.0, CLAUDE);
    let ink = [28, 20, 18];
    for c in [3.0, 9.0] {
        let c = c + look;
        if up {
            // Happy eyes: a thin arch.
            block(c, 2.5, 1.0, 1.0, ink);
        } else if blink {
            block(c, 3.0, 1.0, 1.0, ink);
        } else {
            block(c, 2.0, 1.0, 2.0, ink);
        }
    }
    // Legs: when working one pair lifts on each beat.
    for (n, c) in [2.0, 4.0, 8.0, 10.0].into_iter().enumerate() {
        let lift = if done || (n as i32 & 1) as i32 != step { 0.0 } else { 1.0 };
        let (bx, by) = (x0 + c * u, y0 + (7.0 + lift) * u);
        d.cv.squircle(R::new(fx + (bx - fx) * sx, fy + (by - fy) * sy, u * sx, (2.0 - lift) * u * sy), 0.0, color(CLAUDE, a), None);
    }
    if done && t < 1.8 {
        // Sparkles: small crosses that twinkle around its head.
        let spark = [255, 232, 200];
        for (n, (cx, cy, ph)) in [(-2.0, -1.0, 0.0), (14.5, -2.0, 0.3), (13.0, 5.0, 0.6)].into_iter().enumerate() {
            let s = ((t - ph * 0.5) * 7.0 + n as f32).sin() * 0.5 + 0.5;
            if t > ph * 0.5 && s > 0.25 {
                let (px, py) = (x0 + cx * u, y0 + cy * u - jump);
                d.cv.squircle(R::new(px - u, py, u * 3.0, u), 0.0, color(spark, a * s), None);
                d.cv.squircle(R::new(px, py - u, u, u * 3.0), 0.0, color(spark, a * s), None);
            }
        }
    }
}

/// Codex: a light chip with a terminal prompt whose cursor blinks; it pops in and hops when it finishes.
fn codex_glyph(d: &mut Draw, r: R, t: f32, done: bool, out: f32, a: f32) {
    let (sx, sy) = if out > 0.0 { gone(out) } else if done { (1.0, 1.0) } else { pop(t) };
    let rise = if out > 0.0 { leap(out) } else { hop(if done { t } else { -1.0 }) * 2.0 };
    let c = R::new(r.cx() - 11.0 * sx, r.cy() - 11.0 * sy - rise, 22.0 * sx, 22.0 * sy);
    d.cv.squircle(c, 6.0, color([240, 240, 245], a), None);
    let ink = color([20, 20, 28], a);
    let mut pb = tiny_skia::PathBuilder::new();
    pb.move_to(c.x + 6.5 * sx, c.y + 6.5 * sy);
    pb.line_to(c.x + 11.5 * sx, c.y + 11.0 * sy);
    pb.line_to(c.x + 6.5 * sx, c.y + 15.5 * sy);
    if let Some(p) = pb.finish() {
        d.cv.stroke_path(&p, ink, 2.0, None);
    }
    if done || (t * 3.0) as u32 & 1 == 0 {
        d.cv.squircle(R::new(c.x + 12.5 * sx, c.y + 14.5 * sy, 5.0 * sx, 2.0 * sy), 1.0, ink, None);
    }
}

fn draw_call(d: &mut Draw, m: &Model, body: R) {
    let Some((_, c)) = m.call() else { return };
    let name = if c.name.is_empty() { t("Número desconocido", "Unknown number").to_string() } else { c.name.clone() };
    d.avatar((body.x + PAD + 24.0, body.cy()), 48.0, &name);
    let status = match (c.ringing, c.since) {
        (true, _) => t("Llamada entrante…", "Incoming call…").to_string(),
        (false, Some(s)) => format!("{} · {}", t("En llamada", "On a call"), fmt_time(s.elapsed().as_millis() as i64)),
        (false, None) => t("En llamada", "On a call").to_string(),
    };
    d.text_in(&name, body.x + PAD + 62.0, body.cy() - 2.0, body.w - 2.0 * PAD - 62.0 - 118.0, 15.5, Weight::Bold, 1.0);
    d.text_in(&status, body.x + PAD + 62.0, body.cy() + 16.0, body.w - 2.0 * PAD - 62.0 - 118.0, 12.5, Weight::Regular, 0.65);
    let y = body.cy();
    if c.ringing {
        d.round((body.right() - PAD - 76.0, y), 46.0, Icon::CallEnd, Act::Call("decline"), Some(DANGER), [255, 255, 255]);
        if c.can_answer {
            d.round((body.right() - PAD - 22.0, y), 46.0, Icon::Call, Act::Call("answer"), Some(SUCCESS), [255, 255, 255]);
        }
    } else {
        // Muted: the button lights up (the island's text colour), as the phone's own in-call button does.
        let (bg, fg) = if c.muted { (d.pal.fg, d.pal.bg) } else { (d.pal.chip, d.pal.fg) };
        d.round((body.right() - PAD - 76.0, y), 46.0, Icon::MicOff, Act::Call(if c.muted { "unmute" } else { "mute" }), Some(bg), fg);
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

fn draw_transfer(d: &mut Draw, m: &Model, body: R, id: &str, clock: f64) {
    let Some(x) = m.xfers.iter().find(|x| x.id == id) else { return };
    // A saved file: its preview (or a placeholder with its type) and what to do with it.
    if x.saved().is_some() {
        let pic = R::new(body.x + PAD, body.y + 18.0, 120.0, 120.0);
        if let Some(img) = &x.thumb {
            d.cv.image(img, pic, 14.0, 1.0, None);
        } else {
            d.cv.squircle(pic, 14.0, color(d.pal.chip, 1.0), None);
            icon(d.cv, Icon::File, pic.cx(), pic.cy() - 8.0, 40.0, color(d.pal.fg, 0.55), None);
            let ext = x.ext().to_uppercase();
            if !ext.is_empty() && ext.chars().count() <= 5 {
                d.cv.text_centered(d.fonts, &ext, pic.cx(), pic.cy() + 38.0, 13.0, Weight::Bold, d.pal.fg, 0.6);
            }
        }
        let tx = pic.right() + 14.0;
        let tw = body.right() - PAD - tx;
        let what = match x.ext().as_str() {
            _ if x.local() => t("Descarga completa", "Download complete"),
            "jpg" | "jpeg" | "png" | "webp" | "heic" | "heif" | "gif" | "bmp" | "avif" => t("Foto recibida", "Photo received"),
            "mp4" | "mkv" | "mov" | "avi" | "webm" | "3gp" | "m4v" => t("Vídeo recibido", "Video received"),
            "pdf" | "doc" | "docx" | "odt" | "xls" | "xlsx" | "ods" | "ppt" | "pptx" | "odp" | "txt" | "rtf" | "csv" => t("Documento recibido", "Document received"),
            _ => t("Archivo recibido", "File received"),
        };
        d.text_in(what, tx, body.y + 36.0, tw, 12.5, Weight::Regular, 0.62);
        d.text_in(&x.name, tx, body.y + 56.0, tw, 14.5, Weight::Bold, 1.0);
        // A download never knew its total: what was written is its size.
        d.text(&fmt_size(x.total.max(x.done)), tx, body.y + 74.0, 12.5, Weight::Regular, 0.6);
        let y = pic.bottom() - 34.0;
        let tw = body.right() - PAD - tx;
        // Discarding deletes only the computer's copy: the phone keeps the original. A download is the user's own file:
        // no button here deletes it.
        let n = if x.local() { 2.0 } else { 3.0 };
        let w = (tw - 8.0 * (n - 1.0)) / n;
        let (chip, fg, accent, on) = (d.pal.chip, d.pal.fg, d.pal.accent, d.pal.on_accent);
        d.pill(R::new(tx, y, w, 34.0), t("Abrir", "Open"), Act::OpenFile(x.id.clone()), accent, on);
        d.pill(R::new(tx + w + 8.0, y, w, 34.0), t("Carpeta", "Folder"), Act::ShowFile(x.id.clone()), chip, fg);
        if !x.local() {
            d.pill(R::new(tx + 2.0 * (w + 8.0), y, w, 34.0), t("Descartar", "Discard"), Act::Discard(x.id.clone()), chip, DANGER);
        }
        return;
    }
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
            let verb = if x.local() { t("Descargando", "Downloading") } else if x.incoming { t("Recibiendo", "Receiving") } else { t("Enviando", "Sending") };
            match (x.rate > 0, x.no_total()) {
                (true, true) => format!("{verb} · {} · {}/s", fmt_size(x.done), fmt_size(x.rate)),
                (true, false) => format!("{verb} · {}/s", fmt_size(x.rate)),
                (false, true) => format!("{verb} · {}", fmt_size(x.done)),
                (false, false) => verb.to_string(),
            }
        }
        XState::Done => if x.incoming { t("Archivo recibido", "File received").into() } else { t("Enviado al teléfono", "Sent to the phone").into() },
        XState::Failed(msg) => if msg.is_empty() { t("No se pudo completar", "Could not finish").to_string() } else { msg.clone() },
    };
    d.text_in(&line, tx, body.y + 50.0, tw, 12.5, Weight::Regular, 0.62);
    let accent = col;
    let bar = R::new(tx, body.y + 62.0, tw, 5.0);
    if x.no_total() {
        // No total to measure against: a stretch of the bar glides back and forth (a smooth triangle wave).
        d.cv.squircle(bar, bar.h / 2.0, color(d.pal.fg, 0.16), None);
        let (len, phase) = (bar.w * 0.28, (clock as f32 * 0.7).fract());
        let e = smooth(if phase < 0.5 { phase * 2.0 } else { 2.0 - phase * 2.0 });
        d.cv.squircle(R::new(bar.x + (bar.w - len) * e, bar.y, len, bar.h), bar.h / 2.0, color(accent, 1.0), None);
    } else {
        d.bar(bar, x.fraction(), accent);
    }
    if x.state == XState::Running && !x.local() {
        d.round((body.right() - PAD - 15.0, body.cy()), 30.0, Icon::Close, Act::Cancel(x.id.clone()), None, d.pal.fg);
    }
}

fn draw_note(d: &mut Draw, n: &Note, body: R, age: f32) {
    // A device alert comes in by parts (the island's own content fade already runs over all of it): the phone pops,
    // the text slides in a beat later, the status badge pops last. Monochrome: white on the island's black.
    let alert = n.badge.is_some();
    let step = |from: f32, len: f32| if alert { ((age - from) / len).clamp(0.0, 1.0) } else { 1.0 };
    let (pop, text_in, badge_in) = (back_out(step(0.06, 0.34)).max(0.0), smooth(step(0.16, 0.30)), back_out(step(0.34, 0.30)).max(0.0));
    match (&n.avatar, &n.img) {
        // A chat: the sender's photo, round, with the app's logo on its corner.
        (Some(av), app) => badged(d, av, 20.0, app.as_ref(), R::new(body.x + PAD, body.cy() - 20.0, 40.0, 40.0), 1.0),
        (None, Some(img)) => d.cv.image(img, R::new(body.x + PAD, body.cy() - 20.0, 40.0, 40.0), 11.0, 1.0, None),
        (None, None) => {
            let (cx, cy) = (body.x + PAD + 20.0, body.cy());
            d.cv.circle(cx, cy, 20.0 * pop, color(d.pal.chip, 1.0), None);
            if let Some(ic) = n.icon {
                let (fg, a) = match n.badge {
                    Some(up) => (d.pal.fg, if up { 1.0 } else { 0.55 }),
                    None => (if n.good { SUCCESS } else { d.pal.fg }, 1.0),
                };
                icon(d.cv, ic, cx, cy, 20.0 * pop, color(fg, a), None);
            }
            if let Some(up) = n.badge {
                // Ringed in the island's colour so it reads over the chip.
                let (bx, by, r) = (cx + 14.0, cy + 14.0, 9.0 * badge_in);
                d.cv.circle(bx, by, r + 2.0, color(d.pal.bg, 1.0), None);
                d.cv.circle(bx, by, r, color(if up { d.pal.fg } else { d.pal.chip_hi }, 1.0), None);
                icon(d.cv, if up { Icon::Check } else { Icon::Close }, bx, by, 11.0 * badge_in, color(if up { d.pal.bg } else { d.pal.fg }, 1.0), None);
            }
        }
    }
    let (tx_alpha, slide) = (text_in, (1.0 - text_in) * 10.0);
    let tx = body.x + PAD + 52.0 + slide;
    let tw = body.w - PAD - tx + body.x;
    // Baselines that put the two lines (cap height to descender) on the icon's centre line.
    if n.text.is_empty() {
        d.text_in(&n.title, tx, body.cy() + 5.0, tw, 14.0, Weight::Bold, tx_alpha);
    } else {
        d.text_in(&n.title, tx, body.cy() - 4.5, tw, 14.0, Weight::Bold, tx_alpha);
        d.text_in(&n.text, tx, body.cy() + 13.5, tw, 12.5, Weight::Regular, 0.65 * tx_alpha);
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

    #[test]
    fn a_button_answers_only_while_held_and_leaves_no_click_afterimage() {
        let mut i = island();
        i.model.pc_media = Some(super::super::model::Media {
            app: "Spotify".into(), title: "Test".into(), playing: true, ..Default::default()
        });
        i.open(View::Page(Page::Player), Reason::Key);
        run(&mut i, 1.0);
        let mut cv = i.new_canvas(1.0);
        i.render(&mut cv);
        let button = i.hits.iter().find(|h| matches!(h.act, Act::PcMedia(_))).unwrap().r;
        i.set_pointer(Some((button.cx(), button.cy())));
        i.render(&mut cv);
        let before = cv.pm.data().to_vec();
        i.press();
        i.render(&mut cv);
        assert_ne!(before, cv.pm.data(), "a held button has immediate feedback");
        i.release();
        i.render(&mut cv);
        assert_eq!(before, cv.pm.data(), "release removes the press feedback in the same frame");
        assert!(i.take_cmds().iter().any(|c| matches!(c, Cmd::PcMedia(_))));
        i.take_dirty();
        assert!(!i.update(1.0 / 60.0).animating, "a click must not schedule decorative frames");
    }

    #[test]
    fn cached_frames_survive_buffer_release_and_dpi_changes() {
        let mut i = island();
        for k in [1.0, 2.0] {
            let mut cv = i.new_canvas(k);
            i.render(&mut cv);
            assert!(i.layer.is_none(), "a closed notch needs no content layer");
            let first = cv.pm.data().to_vec();
            i.render(&mut cv);
            assert_eq!(first, cv.pm.data(), "repeated frames preserve the pixels");
            i.release_buffers();
            i.render(&mut cv);
            assert_eq!(first, cv.pm.data(), "released buffers are rebuilt correctly");
        }
    }

    #[test]
    fn opening_and_closing_leave_no_shadow_below_the_body() {
        for k in [1.0, 1.5, 2.0] {
            let mut i = Island::new(IslandConfig::default());
            let mut cv = i.new_canvas(k);
            i.open(View::Page(Page::Home), Reason::Key);
            for frame in 0..90 {
                if frame == 45 { i.close(); }
                i.update(1.0 / 60.0);
                i.render(&mut cv);
                // Leave two logical pixels for the antialiased rim.
                let y = ((i.pill().bottom() + 2.0) * k).ceil() as usize;
                let start = (y * cv.width_px() as usize * 4).min(cv.pm.data().len());
                assert!(cv.pm.data()[start..].chunks_exact(4).all(|p| p[3] == 0), "shadow below the body: frame={frame} scale={k}");
            }
        }
    }

    #[test]
    fn player_controls_keep_a_bottom_margin() {
        for lyrics in [false, true] {
            let mut i = island();
            i.model.pc_media = Some(super::super::model::Media {
                title: "WhatsApp".into(), app: "Spotify".into(), duration_ms: 8000,
                ..Default::default()
            });
            i.set_lyrics_pref(lyrics);
            i.open(View::Page(Page::Player), Reason::Key);
            run(&mut i, 1.0);
            for k in [1.0, 1.5, 2.0] {
                let mut cv = i.new_canvas(k);
                i.render(&mut cv);
                let bottom = i.pill().bottom() - 18.0;
                let controls: Vec<_> = i.hits.iter().filter(|h| matches!(h.act, Act::PcMedia(_) | Act::VolButton | Act::Lyrics)).collect();
                assert!(controls.len() >= 4);
                for h in controls {
                    assert!(h.r.bottom() <= bottom + 0.1, "control {:?}: {:?}, bottom {bottom}, lyrics {lyrics}", h.act, h.r);
                }
            }
        }
    }

    /// Uses the real compositor without moving the pointer or taking keyboard focus.
    #[cfg(windows)]
    #[test]
    #[ignore]
    fn transition_profile() {
        use super::super::run::Host;
        let load: usize = std::env::var("ISLAND_PROFILE_LOAD").ok().and_then(|n| n.parse().ok()).unwrap_or(0);
        let running = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(true));
        let workers: Vec<_> = (0..load).map(|_| {
            let running = running.clone();
            std::thread::spawn(move || {
                while running.load(std::sync::atomic::Ordering::Relaxed) {
                    std::hint::black_box((0..1000).fold(1.0f64, |a, n| (a + n as f64).sqrt()));
                }
            })
        }).collect();
        println!("cpu_load_workers={load}");
        let mut host = super::super::win::WinHost::new().expect("desktop window");
        let mon = host.monitors()[0];
        let dpi = host.dpi(mon);
        let k = dpi * ((mon.3 - mon.1) as f32 / dpi / 950.0).clamp(1.0, 1.2);
        println!("monitor={mon:?} dpi={dpi} render_scale={k}");
        let mut cfg = IslandConfig::default();
        cfg.animation = "soft".into();
        let mut i = Island::new(cfg);
        i.model.pc_media = Some(super::super::model::Media {
            app: "Spotify".into(), title: "Transition profile".into(), artist: "Alero".into(),
            playing: true, duration_ms: 180000, at: Some(Instant::now()), ..Default::default()
        });
        let scene = std::env::var("ISLAND_PROFILE_VIEW").unwrap_or_else(|_| "player".into());
        let view = match scene.as_str() {
            "home" => View::Page(Page::Home),
            "notifs" => View::Page(Page::Notifs),
            "lyrics" => View::Page(Page::Player),
            "drop" => View::Drop,
            _ => View::Page(Page::Player),
        };
        if scene == "notifs" {
            with_phone(&mut i);
            for n in 0..3 {
                i.model.feed(&Event::Message { peer_id: "p".into(), kind: "pb.x.notif.posted".into(), body: json!({"key": format!("{n}"), "app": "WhatsApp", "title": "Ana", "text": "¿Vienes hoy? 🎧", "replyable": true}) });
            }
        }
        if scene == "lyrics" {
            i.model.pc_media.as_mut().unwrap().art = Some(super::super::gfx::Image::from_rgba(32, 32, [180, 70, 120, 255].repeat(32 * 32)).unwrap());
            i.set_lyrics_pref(true);
            i.set_lyrics("Transition profile|Alero".into(), Some(crate::lyrics::parse_lrc("[00:00.00]Una línea para comprobar el movimiento\n[00:01.50]La siguiente línea se desplaza suavemente")));
        }
        if scene == "drop" {
            with_phone(&mut i);
            i.drag(Drag::Enter);
        }
        println!("scene={scene}");
        let mut cv = i.new_canvas(k);
        let mut pixels = Vec::new();
        let mut render = Vec::new();
        let mut present = Vec::new();
        let mut intervals = Vec::new();
        let mut stages = [Vec::new(), Vec::new(), Vec::new(), Vec::new()];
        let mut last = Instant::now();
        for frame in 0..180 {
            let now = Instant::now();
            let dt = now.duration_since(last).as_secs_f32();
            last = now;
            if frame > 0 { intervals.push(dt as f64 * 1000.0); }
            if frame == 0 || frame == 100 { i.open(view.clone(), Reason::Key); }
            if frame == 65 { i.close(); }
            if scene == "drop" {
                if frame == 35 {
                    i.dropped(vec![PathBuf::from("alero-share-qa.png")]);
                    i.take_cmds();
                    let n = i.model.feed(&Event::TransferStarted { id: "qa".into(), peer_id: "p".into(), peer_name: "Pixel 9a".into(), name: "alero-share-qa.png".into(), size: 105, incoming: false });
                    i.notices(n);
                }
                if (35..140).contains(&frame) {
                    i.model.feed(&Event::TransferProgress { id: "qa".into(), done: (frame - 35) as u64, total: 105, bytes_per_sec: 60 });
                }
                if frame == 140 {
                    let n = i.model.feed(&Event::TransferFinished { id: "qa".into(), ok: true, code: String::new(), message: String::new(), path: String::new() });
                    i.notices(n);
                }
            }
            i.update(dt);
            let start = Instant::now();
            i.render(&mut cv);
            render.push(start.elapsed().as_secs_f64() * 1000.0);
            for (stage, ms) in stages.iter_mut().zip(i.profile) { stage.push(ms); }
            let b = i.crop_box().unwrap();
            let x0 = (b.x * k).floor().max(0.0) as u32;
            let x1 = (b.right() * k).ceil().min(cv.width_px() as f32) as u32;
            let h = (b.bottom() * k).ceil().min(cv.height_px() as f32) as u32;
            pixels.clear();
            for row in 0..h as usize {
                let at = (row * cv.width_px() as usize + x0 as usize) * 4;
                pixels.extend_from_slice(&cv.pm.data()[at..at + (x1 - x0) as usize * 4]);
            }
            let start = Instant::now();
            host.present(Some((&pixels, x1 - x0, h, (mon.0 + mon.2) / 2 - (CANVAS_W * k / 2.0) as i32 + x0 as i32, mon.1)));
            present.push(start.elapsed().as_secs_f64() * 1000.0);
            host.pump(0);
            host.vsync();
        }
        host.present(None);
        running.store(false, std::sync::atomic::Ordering::Relaxed);
        for worker in workers { worker.join().unwrap(); }
        for (name, mut samples) in ["setup", "background", "content", "composite"].into_iter().zip(stages) {
            samples.sort_by(f64::total_cmp);
            println!("{name}: p95={:.3} max={:.3} ms", samples[samples.len()*95/100], samples.last().unwrap());
        }
        for (name, mut samples) in [("render", render), ("present", present), ("frame interval", intervals)] {
            samples.sort_by(f64::total_cmp);
            println!("{name}: p50={:.3} p95={:.3} max={:.3} ms", samples[samples.len()/2], samples[samples.len()*95/100], samples.last().unwrap());
        }
    }

    /// Run explicitly on the same machine/build to compare CPU rendering; no timing threshold in CI.
    #[test]
    #[ignore]
    fn render_benchmark() {
        let mut i = island();
        i.model.pc_media = Some(super::super::model::Media {
            title: "Test track".into(), app: "Spotify".into(), duration_ms: 8000, ..Default::default()
        });
        i.open(View::Page(Page::Player), Reason::Key);
        run(&mut i, 1.0);
        for k in [1.0, 1.5, 2.0] {
            let mut cv = i.new_canvas(k);
            i.render(&mut cv);
            let start = Instant::now();
            for _ in 0..60 { i.render(&mut cv); }
            println!("player scale={k}: {:.3} ms/frame", start.elapsed().as_secs_f64() * 1000.0 / 60.0);
        }
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
    fn a_dropped_file_keeps_the_airdrop_card_until_it_finishes() {
        let mut i = island();
        i.cfg.auto_expand = false;
        with_phone(&mut i);
        i.set_zone(true, true, 0.3);
        assert_eq!(i.want, View::Drop);
        i.dropped(vec![PathBuf::from("a.txt")]);
        assert!(matches!(i.take_cmds().as_slice(), [Cmd::SendFiles(_)]));
        let n = i.model.feed(&Event::TransferStarted { id: "s".into(), peer_id: "p".into(), peer_name: "Pixel 9a".into(), name: "a.txt".into(), size: 10, incoming: false });
        i.notices(n);
        run(&mut i, 0.6);
        assert_eq!(i.want, View::Drop);
        assert!(i.ui.air_files.contains_key("s"));
        assert!(i.is_open());
        i.model.feed(&Event::TransferProgress { id: "s".into(), done: 10, total: 10, bytes_per_sec: 10 });
        run(&mut i, 0.6);
        assert_eq!(i.ui.air.stage, airdrop::Stage::Send, "wait for the receiver, even with all bytes sent");
        let n = i.model.feed(&Event::TransferFinished { id: "s".into(), ok: true, code: String::new(), message: String::new(), path: String::new() });
        i.notices(n);
        run(&mut i, 0.5);
        assert_eq!(i.ui.air.stage, airdrop::Stage::Done);
        run(&mut i, 3.0);
        assert!(!i.ui.air.active());
    }

    #[test]
    fn airdrop_waits_for_every_file_and_leaves_incoming_previews_alone() {
        let mut i = island();
        with_phone(&mut i);
        i.set_agent(Agent::Claude, Work::Working);
        i.drag(Drag::Enter);
        i.dropped(vec![PathBuf::from("a.txt"), PathBuf::from("b.txt")]);
        for (id, name) in [("a", "a.txt"), ("b", "b.txt")] {
            let n = i.model.feed(&Event::TransferStarted { id: id.into(), peer_id: "p".into(), peer_name: "Pixel 9a".into(), name: name.into(), size: 10, incoming: false });
            i.notices(n);
        }
        let n = i.model.feed(&Event::TransferFinished { id: "a".into(), ok: true, code: String::new(), message: String::new(), path: String::new() });
        i.notices(n);
        run(&mut i, 1.0);
        assert_eq!(i.ui.air.stage, airdrop::Stage::Send, "the second file is still sending");
        i.close();
        run(&mut i, 1.0);
        assert!(i.rest_size().0 >= LIVE.0, "the agent's mini notch must not clip the transfer ring");
        let n = i.model.feed(&Event::TransferStarted { id: "in".into(), peer_id: "p".into(), peer_name: "Pixel 9a".into(), name: "photo.jpg".into(), size: 10, incoming: true });
        i.notices(n);
        run(&mut i, 0.6);
        assert_eq!(i.want, View::Transfer("in".into()));
        assert_eq!(i.ui.air_files.len(), 2);
    }

    #[test]
    fn a_drag_or_drop_during_a_send_joins_it_instead_of_resetting_it() {
        let mut i = island();
        with_phone(&mut i);
        i.drag(Drag::Enter);
        i.dropped(vec![PathBuf::from("a.txt")]);
        let n = i.model.feed(&Event::TransferStarted { id: "a".into(), peer_id: "p".into(), peer_name: "Pixel 9a".into(), name: "a.txt".into(), size: 10, incoming: false });
        i.notices(n);
        run(&mut i, 0.6);
        let land = i.ui.land;
        i.drag(Drag::Enter);
        assert_eq!(i.ui.land, land, "a drag over a send keeps its landing");
        i.dropped(vec![PathBuf::from("b.txt")]);
        assert_eq!(i.ui.air_files.len(), 1, "the first file is still followed");
        let n = i.model.feed(&Event::TransferStarted { id: "b".into(), peer_id: "p".into(), peer_name: "Pixel 9a".into(), name: "b.txt".into(), size: 10, incoming: false });
        i.notices(n);
        let n = i.model.feed(&Event::TransferFinished { id: "a".into(), ok: true, code: String::new(), message: String::new(), path: String::new() });
        i.notices(n);
        run(&mut i, 1.0);
        assert_eq!(i.ui.air.stage, airdrop::Stage::Send, "waits for the joined file");
    }

    #[test]
    fn a_failed_drop_does_not_leave_a_permanent_progress_pill() {
        let mut i = island();
        with_phone(&mut i);
        i.drag(Drag::Enter);
        i.dropped(vec![PathBuf::from("missing.txt")]);
        i.flash(false, "missing.txt".into(), "File not found".into());
        run(&mut i, 6.0);
        assert!(!i.ui.air.active());
        assert!(i.ui.air_pending.is_empty());
    }

    #[test]
    fn a_working_agent_lives_in_the_closed_island_yields_to_a_call_and_says_when_it_finishes() {
        let mut i = island();
        with_phone(&mut i);
        i.set_agent(Agent::Claude, Work::Working);
        assert_eq!(i.live(), Some(Live::Agent(Agent::Claude)));
        let n = i.model.feed(&Event::Message { peer_id: "p".into(), kind: "pb.x.call".into(), body: json!({"active":true,"ringing":false,"name":"Ana"}) });
        i.notices(n);
        assert_eq!(i.live(), Some(Live::Call), "a call outranks the agent");
        let n = i.model.feed(&Event::Message { peer_id: "p".into(), kind: "pb.x.call".into(), body: json!({"active":false}) });
        i.notices(n);
        run(&mut i, 3.0);
        assert_eq!(i.live(), Some(Live::Agent(Agent::Claude)));
        i.set_agent(Agent::Claude, Work::Idle);
        assert_eq!(i.live(), Some(Live::AgentDone(Agent::Claude)));
        run(&mut i, 4.5);
        assert_eq!(i.live(), None);
        // Drawn without panicking, closed (the creature and the Codex chip).
        i.set_rest(true);
        for a in [Agent::Claude, Agent::Codex] {
            i.set_agent(a, Work::Working);
            run(&mut i, 0.5);
            let mut cv = i.new_canvas(1.5);
            i.render(&mut cv);
        }
        i.cfg.modules.agents = false;
        assert_eq!(i.live(), None);
    }

    #[test]
    fn the_agent_line_steps_back_to_a_notch_hover_brings_it_back_and_the_switch_hides_it() {
        let mut i = island();
        i.set_rest(true);
        i.set_agent(Agent::Claude, Work::Working);
        run(&mut i, 2.0);
        assert!(!i.agent_mini());
        assert_eq!((i.w.value.round(), i.h.value.round()), (LIVE.0, LIVE.1), "the full line first");
        run(&mut i, 5.0);
        assert!(i.agent_mini());
        assert_eq!((i.w.value.round(), i.h.value.round()), (MINI.0, MINI.1), "then just the creature");
        // The pointer on the notch: the line comes back, and goes again a moment after it leaves.
        i.set_pointer(Some((CANVAS_W / 2.0, 10.0)));
        run(&mut i, 0.1);
        assert!(!i.agent_mini());
        i.set_pointer(None);
        run(&mut i, 3.0);
        assert!(i.agent_mini());
        // Finished: the full line with the celebration, then nothing.
        i.set_agent(Agent::Claude, Work::Idle);
        assert_eq!(i.live(), Some(Live::AgentDone(Agent::Claude)));
        assert!(!i.agent_mini());
        assert!(i.agent_look().0 < 0.1, "the celebration starts now");
        // Its own switch: off, nothing shows; the computer's downloads still work.
        i.set_agent(Agent::Claude, Work::Working);
        i.cfg.modules.agents = false;
        assert_eq!(i.live(), None);
        i.cfg.modules.pc = true;
        let id = "pc:/dl/c.zip.crdownload".to_string();
        let n = i.model.feed(&Event::TransferStarted { id: id.clone(), peer_id: String::new(), peer_name: String::new(), name: "c.zip".into(), size: 0, incoming: true });
        i.notices(n);
        assert_eq!(i.want, View::Transfer(id));
    }

    /// Frames of the closed island with the agent, for looking at: `cargo test -- --ignored agent_frames`.
    #[test]
    #[ignore]
    fn agent_frames() {
        let dir = std::path::PathBuf::from(std::env::var("FRAMES_DIR").expect("FRAMES_DIR"));
        std::fs::create_dir_all(&dir).unwrap();
        // With the animation on, so the fold into the minimal notch and the way out can be looked at.
        let mut i = Island::new(IslandConfig::default());
        i.set_rest(true);
        let mut shots: Vec<(String, Canvas)> = Vec::new();
        let mut snap = |i: &mut Island, name: &str| {
            let mut cv = i.new_canvas(2.0);
            i.render(&mut cv);
            shots.push((name.to_string(), cv));
        };
        i.set_agent(Agent::Claude, Work::Working);
        for (n, secs) in [("pop0", 0.08), ("pop1", 0.1), ("pop2", 0.12)] {
            run(&mut i, secs);
            snap(&mut i, n);
        }
        for n in 0..4 {
            run(&mut i, 0.17);
            snap(&mut i, &format!("work{n}"));
        }
        // t = 3.7 s: the blink; 5.6 s: the glance.
        let t = i.agent_look().0;
        run(&mut i, 3.72 - t);
        snap(&mut i, "blink");
        let t = i.agent_look().0;
        run(&mut i, 5.7 - t);
        snap(&mut i, "glance");
        let t = i.agent_look().0;
        run(&mut i, 5.98 - t);
        for n in 0..6 {
            run(&mut i, 0.07);
            snap(&mut i, &format!("fold{n}"));
        }
        run(&mut i, 1.0);
        snap(&mut i, "mini");
        i.set_agent(Agent::Claude, Work::Idle);
        for (n, secs) in [("done0", 0.15), ("done1", 0.15), ("done2", 0.3), ("done3", 0.4)] {
            run(&mut i, secs);
            snap(&mut i, n);
        }
        // The celebration ends and the notch shrinks back to rest.
        run(&mut i, 2.9);
        for n in 0..6 {
            run(&mut i, 0.07);
            snap(&mut i, &format!("away{n}"));
        }
        i.set_agent(Agent::Codex, Work::Working);
        run(&mut i, 0.5);
        snap(&mut i, "codex");
        for (name, cv) in &shots {
            save_crop(cv, &dir.join(format!("{name}.png")), 340.0, 56.0);
        }
    }

    /// The top-centre `w` x `h` logical units of a 2x canvas, over a grey desktop, doubled again, as a PNG.
    fn save_crop(cv: &Canvas, path: &std::path::Path, w: f32, h: f32) {
        let (z, x0, w, h) = (2usize, (CANVAS_W / 2.0 - w / 2.0) as usize * 2, w as usize * 2, h as usize * 2);
        let mut out = vec![0u8; w * z * h * z * 3];
        for y in 0..h * z {
            for x in 0..w * z {
                let o = ((y / z) * cv.width_px() as usize + x0 + x / z) * 4;
                let p = &cv.pm.data()[o..o + 4];
                for c in 0..3 {
                    out[(y * w * z + x) * 3 + c] = (p[c] as u32 + 90 * (255 - p[3] as u32) / 255) as u8;
                }
            }
        }
        let mut enc = png::Encoder::new(std::fs::File::create(path).unwrap(), (w * z) as u32, (h * z) as u32);
        enc.set_color(png::ColorType::Rgb);
        enc.set_depth(png::BitDepth::Eight);
        enc.write_header().unwrap().write_image_data(&out).unwrap();
    }

    /// Received-file cards for looking at: `cargo test -- --ignored card_frames`.
    #[test]
    #[ignore]
    fn card_frames() {
        let dir = std::path::PathBuf::from(std::env::var("FRAMES_DIR").expect("FRAMES_DIR"));
        std::fs::create_dir_all(&dir).unwrap();
        // A synthetic picture: a diagonal gradient with a bright disc.
        let img = {
            let (w, h) = (160u32, 90u32);
            let mut px = Vec::new();
            for y in 0..h {
                for x in 0..w {
                    let d = ((x as f32 - 80.0).powi(2) + (y as f32 - 45.0).powi(2)).sqrt();
                    px.extend(if d < 22.0 { [250, 220, 90, 255] } else { [(x * 255 / w) as u8, 80, (y * 255 / h) as u8, 255] });
                }
            }
            Image::from_rgba(w, h, px).unwrap()
        };
        for (name, id, file, thumb) in [
            ("card_photo", "a", "C:/Descargas/PXL_1.jpg", true),
            ("card_video", "b", "C:/Descargas/clip.mp4", true),
            ("card_placeholder", "c", "C:/Descargas/informe.pdf", false),
            ("card_unknown", "e", "C:/Descargas/datos.bin", false),
            ("card_download", "pc:/dl/setup.exe", "C:/Descargas/setup.exe", false),
        ] {
            let mut i = island();
            with_phone(&mut i);
            let file_name = file.rsplit('/').next().unwrap();
            let n = i.model.feed(&Event::TransferStarted { id: id.into(), peer_id: "p".into(), peer_name: "Pixel".into(), name: file_name.into(), size: 3_000_000, incoming: true });
            i.notices(n);
            let n = i.model.feed(&Event::TransferFinished { id: id.into(), ok: true, code: String::new(), message: String::new(), path: file.into() });
            i.notices(n);
            if thumb {
                i.set_thumb(id, Some(img.clone()));
            }
            run(&mut i, 1.0);
            let mut cv = i.new_canvas(2.0);
            i.render(&mut cv);
            save_crop(&cv, &dir.join(format!("{name}.png")), 470.0, 170.0);
        }
    }

    /// The send animation for looking at: `cargo test -- --ignored drop_frames`.
    #[test]
    #[ignore]
    fn drop_frames() {
        let dir = std::path::PathBuf::from(std::env::var("FRAMES_DIR").expect("FRAMES_DIR"));
        std::fs::create_dir_all(&dir).unwrap();
        // With the animation on (the tests' island has it off).
        let mut i = Island::new(IslandConfig::default());
        with_phone(&mut i);
        let snap = |i: &mut Island, name: &str| {
            let mut cv = i.new_canvas(2.0);
            i.render(&mut cv);
            save_crop(&cv, &dir.join(format!("drop_{name}.png")), 470.0, 190.0);
        };
        i.drag(Drag::Enter);
        for (n, s) in [("hover0", 0.6), ("hover1", 0.5)] {
            run(&mut i, s);
            snap(&mut i, n);
        }
        i.dropped(vec![PathBuf::from("foto.jpg")]);
        run(&mut i, 0.2);
        snap(&mut i, "fly");
        let n = i.model.feed(&Event::TransferStarted { id: "q".into(), peer_id: "p".into(), peer_name: "Pixel 9a".into(), name: "foto.jpg".into(), size: 100, incoming: false });
        i.notices(n);
        let n = i.model.feed(&Event::TransferProgress { id: "q".into(), done: 40, total: 100, bytes_per_sec: 1 });
        i.notices(n);
        run(&mut i, 1.0);
        snap(&mut i, "send40");
        let n = i.model.feed(&Event::TransferFinished { id: "q".into(), ok: true, code: String::new(), message: String::new(), path: String::new() });
        i.notices(n);
        run(&mut i, 0.5);
        snap(&mut i, "done");
    }

    #[test]
    fn a_pc_download_shows_its_card_without_a_size_and_then_its_result() {
        let mut i = island();
        let id = "pc:/dl/a.zip.crdownload".to_string();
        let n = i.model.feed(&Event::TransferStarted { id: id.clone(), peer_id: String::new(), peer_name: String::new(), name: "a.zip".into(), size: 0, incoming: true });
        i.notices(n);
        assert_eq!(i.want, View::Transfer(id.clone()));
        let n = i.model.feed(&Event::TransferProgress { id: id.clone(), done: 5_000_000, total: 0, bytes_per_sec: 1_000_000 });
        i.notices(n);
        let mut cv = i.new_canvas(1.0);
        run(&mut i, 0.6);
        i.render(&mut cv);
        // The card goes after a few seconds (a long download must not hold the island), the result brings it back.
        run(&mut i, 8.0);
        assert!(!i.is_open());
        let n = i.model.feed(&Event::TransferFinished { id: id.clone(), ok: true, code: String::new(), message: String::new(), path: "/dl/a.zip".into() });
        i.notices(n);
        // The card had closed (its view is still the last one): only a real reopening counts.
        assert!(i.is_open(), "the result brings the island back");
        assert_eq!(i.want, View::Transfer(id.clone()));
        run(&mut i, 0.6);
        i.render(&mut cv);
        assert!(i.hits.iter().any(|h| matches!(h.act, Act::OpenFile(_))));
        assert!(!i.hits.iter().any(|h| matches!(h.act, Act::Discard(_))), "a download is never deleted from the island");
        assert!(i.take_cmds().contains(&Cmd::Thumb { id, path: "/dl/a.zip".into() }), "a finished download gets a preview too");
    }

    #[test]
    fn a_new_download_does_not_jump_over_the_page_in_use() {
        let mut i = island();
        i.open(View::Page(Page::Home), Reason::Hover);
        run(&mut i, 0.2);
        let id = "pc:/dl/b.zip.crdownload".to_string();
        let n = i.model.feed(&Event::TransferStarted { id, peer_id: String::new(), peer_name: String::new(), name: "b.zip".into(), size: 0, incoming: true });
        i.notices(n);
        assert_eq!(i.want, View::Page(Page::Home));
    }

    #[test]
    fn without_a_phone_the_controls_are_this_computers_and_a_switch_picks_with_one() {
        let mut i = island();
        assert!(i.controls_pc());
        i.act(Act::Pc("mic"));
        i.act(Act::Pc("mic"));
        i.act(Act::Pc("lock"));
        i.act(Act::Pc("shot"));
        assert_eq!(i.take_cmds(), vec![Cmd::PcMute { mic: true, on: true }, Cmd::PcMute { mic: true, on: false }, Cmd::PcPower("lock"), Cmd::PcShot]);
        i.open(View::Page(Page::Controls), Reason::Key);
        run(&mut i, 0.8);
        let mut cv = i.new_canvas(1.0);
        i.render(&mut cv);
        assert!(i.hits.iter().any(|h| h.act == Act::Pc("sleep")) && i.hits.iter().any(|h| h.act == Act::PcVol));
        assert_eq!(i.take_cmds().iter().filter(|c| **c == Cmd::AskPcVolume).count(), 1, "asked once per visit");
        with_phone(&mut i);
        assert!(!i.controls_pc(), "a phone connected: its controls, unless the switch says otherwise");
        i.act(Act::ControlsSource);
        assert!(i.controls_pc());
        i.cfg.modules.pc = false;
        assert!(!i.controls_pc(), "module off: as before");
    }

    #[test]
    fn the_landing_plays_with_animations_off_and_holds_until_the_card_arrives() {
        let mut i = island();
        with_phone(&mut i);
        i.set_zone(true, true, 0.3);
        i.dropped(vec![PathBuf::from("a.txt")]);
        run(&mut i, 0.2);
        assert!(i.ui.land.is_some_and(|t| t > 0.0 && t < 1.0));
        // No transfer yet: it holds its last frame instead of snapping back to "Drop to send".
        run(&mut i, 1.0);
        assert_eq!(i.ui.land, Some(1.0));
        // The send never started: it does not say "sending" forever.
        run(&mut i, 3.0);
        assert!(i.ui.land.is_none());
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
    fn every_app_control_can_be_chosen_in_order_up_to_three_rows() {
        let all = CONTROLS.join(",");
        let with_adb = control_keys(&all, true);
        assert_eq!(with_adb.len(), MAX_CONTROLS);
        assert_eq!(with_adb[..3], ["dnd", "torch", "find"]);
        assert_eq!(control_keys("clip,screen,mute,camBack,nope", false), ["clip", "screen", "mute"]);
        assert_eq!(control_keys("shot,lock", true), ["shot", "lock"]);
        let mut i = island();
        with_phone(&mut i);
        i.cfg.controls = all;
        i.model.adb.insert("p".into(), super::super::adb::Radios::default());
        let (w, h) = i.size_of(&View::Page(Page::Controls));
        assert!(w * 1.08 <= CANVAS_W && h * 1.08 + 30.0 <= CANVAS_H, "{w}x{h}");
        i.act(Act::Mute);
        assert_eq!(i.take_cmds(), vec![Cmd::Phone { what: "ringer", body: json!({"mode": "silent"}) }]);
        i.act(Act::Mute);
        assert_eq!(i.take_cmds(), vec![Cmd::Phone { what: "ringer", body: json!({"mode": "normal"}) }]);
        i.act(Act::App("camFront"));
        assert_eq!(i.take_cmds(), vec![Cmd::App("camFront")]);
    }

    #[test]
    fn incidental_audio_never_wakes_the_island_and_clears_a_previous_track() {
        let mut i = island();
        for app in ["WhatsApp.exe", "TikTok", "Chrome", "unknown"] {
            i.model.pc_media = Some(super::super::model::Media {
                app: app.into(), title: "YouTube Spotify voice note".into(), playing: true, ..Default::default()
            });
            run(&mut i, 0.1);
            assert_eq!(i.live(), None, "{app}");
            assert!(i.media_line().is_none(), "{app}");
        }
        i.model.pc_media.as_mut().unwrap().app = "Spotify".into();
        run(&mut i, 0.1);
        assert_eq!(i.live(), Some(Live::Media));
        i.model.pc_media.as_mut().unwrap().app = "WhatsApp".into();
        run(&mut i, 0.1);
        assert_eq!(i.live(), None, "the previous four-second activity must disappear immediately");
    }

    #[test]
    fn an_excluded_source_does_not_hide_streaming_on_the_other_device() {
        let mut i = island();
        with_phone(&mut i);
        i.model.pc_media = Some(super::super::model::Media {
            app: "WhatsApp.exe".into(), title: "Voice note".into(), playing: true, ..Default::default()
        });
        i.model.phone_media = Some(super::super::model::Media {
            app: "Spotify".into(), pkg: "com.spotify.music".into(), title: "Track".into(), playing: true, ..Default::default()
        });
        run(&mut i, 0.1);
        assert_eq!(i.live(), Some(Live::Media));
        assert!(!i.media_line().unwrap().1, "show the phone, not WhatsApp on the PC");
        i.model.phone_media.as_mut().unwrap().pkg = "com.zhiliaoapp.musically".into();
        run(&mut i, 0.1);
        assert_eq!(i.live(), None, "the package takes precedence over a display name");
        assert!(i.media_line().is_none());
    }

    #[test]
    fn music_and_charging_live_in_the_closed_island() {
        let mut i = island();
        with_phone(&mut i);
        run(&mut i, 0.5);
        assert!((i.w.value - PEEK.0).abs() < 1.0);
        i.model.pc_media = Some(super::super::model::Media { title: "T".into(), app: "Spotify".into(), playing: true, speed: 1.0, ..Default::default() });
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

    /// The closed window is cut to `rest_box`: nothing may ever be drawn outside it, in any closed state and on any
    /// frame of the springs (normal animation, with its overshoot), or the notch would be clipped.
    #[test]
    fn the_closed_island_never_draws_outside_its_box() {
        let mut i = Island::new(IslandConfig::default());
        with_phone(&mut i);
        let k = 1.5;
        let mut cv = Canvas::new(CANVAS_W, CANVAS_H, k);
        let mut checked = 0;
        let mut frame = |i: &mut Island, hot: bool, secs: f32| {
            let mut t = 0.0;
            while t < secs {
                i.set_zone(hot, false, 0.0);
                i.update(1.0 / 60.0);
                t += 1.0 / 60.0;
                if i.is_open() {
                    continue;
                }
                let b = i.rest_box().expect("a closed notch fits its box");
                i.render(&mut cv);
                let (w, h) = (cv.width_px() as usize, cv.height_px() as usize);
                let (x0, x1, y1) = ((b.x * k).floor() as usize, ((b.right() * k).ceil() as usize).min(w), ((b.bottom() * k).ceil() as usize).min(h));
                let px = cv.pm.data();
                for y in 0..h {
                    for x in 0..w {
                        if !(x >= x0 && x < x1 && y < y1) {
                            assert_eq!(px[(y * w + x) * 4 + 3], 0, "pixel ({x}, {y}) outside the box at w={} h={}", i.w.value, i.h.value);
                        }
                    }
                }
                checked += 1;
            }
        };
        frame(&mut i, false, 0.6);
        // Swelling under the pointer (open_delay keeps it closed for a while).
        i.cfg.open_delay_ms = 100_000;
        frame(&mut i, true, 0.8);
        frame(&mut i, false, 0.8);
        // Music: the compact island, then swollen under the pointer.
        i.model.pc_media = Some(super::super::model::Media { title: "T".into(), artist: "A".into(), app: "Spotify".into(), playing: true, speed: 1.0, ..Default::default() });
        frame(&mut i, false, 0.8);
        frame(&mut i, true, 0.8);
        frame(&mut i, false, 4.5);
        // Charging.
        let n = i.model.feed(&Event::Message { peer_id: "p".into(), kind: "pb.x.info".into(), body: json!({"kind":"phone","battery":{"level":50,"charging":true}}) });
        i.notices(n);
        frame(&mut i, true, 1.0);
        frame(&mut i, false, 4.5);
        // Opened and closed again: the frames after it is closed.
        i.cfg.open_delay_ms = 0;
        frame(&mut i, true, 0.5);
        assert!(i.is_open());
        i.cfg.open_delay_ms = 100_000;
        frame(&mut i, false, 3.0);
        assert!(!i.is_open());
        assert!(checked > 600, "{checked}");
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
    fn an_answered_call_folds_into_the_compact_island_and_hanging_up_says_so() {
        let mut i = island();
        with_phone(&mut i);
        let call = |i: &mut Island, body: Value| {
            let n = i.model.feed(&Event::Message { peer_id: "p".into(), kind: "pb.x.call".into(), body });
            i.notices(n);
        };
        call(&mut i, json!({"active":true,"ringing":true,"canAnswer":true,"name":"\u{2068}Tamarindo\u{2069}"}));
        assert_eq!(i.model.call().unwrap().1.name, "Tamarindo", "bidi isolates are not drawn as boxes");
        // Answered with the pointer still on the card: it folds anyway.
        i.set_pointer(Some((CANVAS_W / 2.0, 40.0)));
        call(&mut i, json!({"active":true,"ringing":false,"name":"Tamarindo","muted":true}));
        run(&mut i, 1.5);
        assert!(!i.is_open());
        assert_eq!(i.live(), Some(Live::Call));
        assert_eq!(i.pill().w, LIVE.0, "the compact island, not the bare notch");
        assert!(i.ui.live_a > 0.99);
        // Hovering the top edge brings the call card back, with its controls.
        i.set_zone(true, false, 1.0);
        assert_eq!(i.want, View::Call);
        i.set_zone(false, false, 0.1);
        i.set_pointer(None);
        run(&mut i, 3.0);
        assert!(!i.is_open());
        call(&mut i, json!({"active":false}));
        assert!(matches!(i.live(), Some(Live::CallEnded(s)) if s >= 0));
        run(&mut i, 3.0);
        assert_eq!(i.live(), None);
        assert_eq!(i.ui.live_a, 0.0);
        // A phone connecting says "no call": nothing ended.
        call(&mut i, json!({"active":false}));
        assert_eq!(i.live(), None);
    }

    #[test]
    fn mute_shows_at_once_beside_hang_up() {
        let mut i = island();
        with_phone(&mut i);
        let n = i.model.feed(&Event::Message { peer_id: "p".into(), kind: "pb.x.call".into(), body: json!({"active":true,"ringing":false,"name":"Ana"}) });
        i.notices(n);
        i.take_cmds();
        i.act(Act::Call("mute"));
        assert!(i.model.call().unwrap().1.muted);
        assert_eq!(i.take_cmds(), vec![Cmd::CallAction("mute")]);
        let mut cv = i.new_canvas(1.0);
        i.open(View::Call, Reason::Hover);
        i.set_pointer(Some((CANVAS_W / 2.0, 40.0)));
        run(&mut i, 0.5);
        i.render(&mut cv);
        assert!(i.hits.iter().any(|h| h.act == Act::Call("unmute")), "mute shows as on");
        assert!(i.hits.iter().any(|h| h.act == Act::Call("hangup")));
    }

    #[test]
    fn the_compact_player_leaves_after_a_while_and_a_blinking_source_does_not_rearm_it() {
        let mut i = island();
        let md = |playing: bool| super::super::model::Media { title: "T".into(), artist: "A".into(), app: "Spotify".into(), playing, speed: 1.0, at: Some(Instant::now()), ..Default::default() };
        i.model.pc_media = Some(md(true));
        run(&mut i, 1.0);
        assert_eq!(i.live(), Some(Live::Media));
        // Spotify blinking (a stop of a frame or two) every second: it still goes after its four seconds.
        for _ in 0..5 {
            i.model.pc_media = Some(md(false));
            run(&mut i, 0.05);
            i.model.pc_media = Some(md(true));
            run(&mut i, 0.95);
        }
        assert_eq!(i.live(), None);
        assert_eq!(i.ui.live_a, 0.0);
        assert_eq!(i.ui.live_last, Some(Live::Media), "drawn while it fades out");
        // A real pause, then playing again: shown again.
        i.model.pc_media = Some(md(false));
        run(&mut i, 4.0);
        i.model.pc_media = Some(md(true));
        run(&mut i, 0.1);
        assert_eq!(i.live(), Some(Live::Media));
    }

    #[test]
    fn a_card_opening_over_the_compact_player_fades_it_instead_of_blanking_it() {
        let mut i = island();
        let md = |playing: bool| super::super::model::Media { title: "T".into(), artist: "A".into(), app: "Spotify".into(), playing, speed: 1.0, at: Some(Instant::now()), ..Default::default() };
        i.model.pc_media = Some(md(true));
        run(&mut i, 1.0);
        assert!(i.ui.live_a > 0.99);
        i.open(View::Note, Reason::Event(Some(1.0)));
        assert!(i.ui.live_a > 0.99, "still drawn under the growing card");
        let mut cv = i.new_canvas(1.0);
        i.render(&mut cv);
        // The song ends while the card is up: on the way down nothing old flashes back.
        i.model.pc_media = Some(md(false));
        run(&mut i, 3.0);
        assert!(!i.is_open());
        assert_eq!(i.ui.live_a, 0.0);
    }

    #[test]
    fn a_received_photo_shows_its_preview_and_can_be_discarded() {
        let mut i = island();
        with_phone(&mut i);
        let started = i.model.feed(&Event::TransferStarted { id: "x".into(), peer_id: "p".into(), peer_name: "Pixel".into(), name: "PXL_1.jpg".into(), size: 3_000_000, incoming: true });
        i.notices(started);
        let done = i.model.feed(&Event::TransferFinished { id: "x".into(), ok: true, code: String::new(), message: String::new(), path: "C:/Descargas/PXL_1.jpg".into() });
        i.notices(done);
        assert!(i.take_cmds().contains(&Cmd::Thumb { id: "x".into(), path: "C:/Descargas/PXL_1.jpg".into() }));
        i.set_thumb("x", Some(Image { w: 4, h: 3, data: vec![255; 48] }));
        let (w, h) = i.size_of(&View::Transfer("x".into()));
        assert!(w * 1.08 <= CANVAS_W && h * 1.08 + 30.0 <= CANVAS_H && h > 92.0);
        run(&mut i, 2.5);
        assert!(i.is_open(), "it waits for a decision longer than a plain file");
        i.act(Act::Discard("x".into()));
        assert_eq!(i.take_cmds(), vec![Cmd::Discard("C:/Descargas/PXL_1.jpg".into())]);
        assert!(i.model.xfers.is_empty());
        assert_ne!(i.phase, Phase::Open, "the card goes once decided");
    }

    #[test]
    fn any_received_file_asks_what_to_do_with_it() {
        let mut i = island();
        with_phone(&mut i);
        let started = i.model.feed(&Event::TransferStarted { id: "d".into(), peer_id: "p".into(), peer_name: "Pixel".into(), name: "informe.pdf".into(), size: 80_000, incoming: true });
        i.notices(started);
        let done = i.model.feed(&Event::TransferFinished { id: "d".into(), ok: true, code: String::new(), message: String::new(), path: "C:/Descargas/informe.pdf".into() });
        i.notices(done);
        assert!(i.take_cmds().contains(&Cmd::Thumb { id: "d".into(), path: "C:/Descargas/informe.pdf".into() }), "every file asks for a preview");
        assert_eq!(i.size_of(&View::Transfer("d".into())), (440.0, 156.0), "the same card with or without a preview");
        run(&mut i, 0.6);
        let mut cv = i.new_canvas(1.0);
        i.render(&mut cv);
        let acts: Vec<_> = i.hits.iter().map(|h| h.act.clone()).collect();
        assert!(acts.contains(&Act::OpenFile("d".into())) && acts.contains(&Act::ShowFile("d".into())) && acts.contains(&Act::Discard("d".into())), "the placeholder card keeps its three buttons");
        run(&mut i, 2.5);
        assert!(i.is_open(), "it waits for a decision");
        i.act(Act::OpenFile("d".into()));
        assert_eq!(i.take_cmds(), vec![Cmd::OpenFile("C:/Descargas/informe.pdf".into())]);
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
    fn going_to_a_notification_opens_the_island_on_the_notifications_at_once() {
        let mut i = island();
        with_phone(&mut i);
        let n = i.model.feed(&Event::Message { peer_id: "p".into(), kind: "pb.x.notif.posted".into(), body: json!({"key":"k","app":"WhatsApp","title":"Ana","text":"¿Vienes?"}) });
        i.notices(n);
        run(&mut i, 0.5);
        assert_eq!(i.want, View::Note);
        let card = i.pill();
        i.set_pointer(Some((card.cx(), card.cy())));
        run(&mut i, 0.05);
        assert_eq!(i.want, View::Page(Page::Notifs), "not after the toast's six seconds");
        assert!(i.is_open());
    }

    #[test]
    fn a_status_note_under_the_pointer_stays_a_note() {
        let mut i = island();
        i.show_note(Note { icon: Some(Icon::Check), title: "Archivo descartado".into(), text: String::new(), good: true, w: 0.0, img: None, badge: None, avatar: None, notif: false });
        run(&mut i, 0.5);
        let card = i.pill();
        i.set_pointer(Some((card.cx(), card.cy())));
        run(&mut i, 0.5);
        assert_eq!(i.want, View::Note, "the pointer was already there: it clicked what led to it");
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

    fn peer_event(id: &str, up: bool) -> Event {
        Event::PeerChanged { peer: PeerView { id: id.into(), name: format!("Phone {id}"), addr: String::new(), state: if up { PeerState::Connected } else { PeerState::Disconnected }, trusted: true, detail: String::new() } }
    }

    fn feed(i: &mut Island, e: Event) {
        let n = i.model.feed(&e);
        i.notices(n);
    }

    #[test]
    fn a_connection_after_start_opens_a_note_that_closes_by_itself() {
        let mut i = island();
        run(&mut i, 7.0);
        feed(&mut i, peer_event("a", true));
        run(&mut i, 0.5);
        assert!(!i.is_open(), "it settles first");
        run(&mut i, 1.0);
        assert!(i.is_open() && i.shown == View::Note);
        assert_eq!((i.note.title.as_str(), i.note.badge), ("Phone a", Some(true)));
        run(&mut i, LINK_SECS + 2.0);
        assert!(!i.is_open());
        feed(&mut i, peer_event("a", false));
        run(&mut i, 1.6);
        assert_eq!(i.note.badge, Some(false));
        assert!(i.is_open());
    }

    #[test]
    fn nothing_opens_at_start_with_a_device_already_there_or_with_the_alerts_off() {
        let mut i = island();
        i.model.set_peers(vec![PeerView { id: "a".into(), name: "A".into(), addr: String::new(), state: PeerState::Connected, trusted: true, detail: String::new() }]);
        i.seed_links();
        // The engine's handshake finishing right after start, and a refresh later.
        feed(&mut i, peer_event("a", true));
        run(&mut i, 2.0);
        feed(&mut i, peer_event("a", true));
        run(&mut i, 4.0);
        assert!(!i.is_open());
        let mut cfg = i.cfg.clone();
        cfg.modules.link = false;
        i.set_config(cfg);
        run(&mut i, 7.0);
        feed(&mut i, peer_event("a", false));
        run(&mut i, 3.0);
        assert!(!i.is_open(), "alerts off");
    }

    #[test]
    fn an_open_island_is_not_interrupted_and_the_alert_waits_its_turn() {
        let mut i = island();
        run(&mut i, 7.0);
        i.hotkey();
        run(&mut i, 1.0);
        assert!(i.is_open() && i.shown == View::Page(Page::Home));
        feed(&mut i, peer_event("a", true));
        run(&mut i, 3.0);
        assert!(i.shown == View::Page(Page::Home), "the page the user opened stays");
        i.close();
        run(&mut i, 1.5);
        assert!(i.is_open() && i.shown == View::Note, "its turn comes when the island is free");
    }

    /// The cover with the app's icon on its corner; without a cover the app's icon; with neither, the note.
    #[test]
    fn the_closed_pills_picture_falls_back_from_cover_to_app_icon_to_note() {
        use super::super::model::Media;
        let mut i = island();
        let pal = i.palette();
        let img = |c: u8| Image::from_rgba(8, 8, vec![c; 8 * 8 * 4]).unwrap();
        let mut draw = |md: Option<&Media>| {
            let mut cv = Canvas::new(CANVAS_W, CANVAS_H, 1.0);
            let mut hits = Vec::new();
            let mut d = Draw { cv: &mut cv, fonts: &mut i.fonts, hits: &mut hits, pal: &pal, pointer: None, pressed: None };
            draw_cover(&mut d, md, R::new(10.0, 10.0, 26.0, 26.0), 1.0);
            cv.pm.data().to_vec()
        };
        let m = |art: bool, app: bool| Media { art: art.then(|| img(200)), icon: app.then(|| img(90)), ..Default::default() };
        let note = draw(None);
        let (cover, both, app_only) = (draw(Some(&m(true, false))), draw(Some(&m(true, true))), draw(Some(&m(false, true))));
        assert_eq!(note, draw(Some(&m(false, false))), "nothing to show: the note");
        assert!(note != cover && cover != both && app_only != note && app_only != cover);
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
        // A received file waits for a choice, then goes all the same.
        let wait = i.cfg.event_secs as f32 + 1.5;
        run(&mut i, wait);
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
            ("controls-all", View::Page(Page::Controls)),
            ("call", View::Call),
            ("call-active", View::Call),
            ("live-call", View::Call),
            ("live-ended", View::Call),
            ("live-media", View::Call),
            ("note-chat", View::Note),
            ("offer", View::Offer),
            ("transfer", View::Transfer("x1".into())),
            ("photo", View::Transfer("x2".into())),
            ("file", View::Transfer("x3".into())),
            ("note", View::Note),
            ("drop", View::Drop),
        ];
        for (colour, tag) in [("#000000", "oled"), ("#f2efe9", "light")] {
            for (name, view) in &views {
                let mut cfg = IslandConfig::default();
                cfg.animation = "off".into();
                cfg.color = colour.into();
                if *name == "controls-all" {
                    cfg.controls = CONTROLS.join(",");
                }
                let mut i = Island::new(cfg);
                with_phone(&mut i);
                for (n, (app, title, text)) in [("WhatsApp", "Ana", "¿Vienes a cenar hoy? Te guardé un lugar"), ("Gmail", "Banco", "Tu estado de cuenta está listo"), ("Telegram", "Edwin", "ya lo subí al repo 👍")].iter().enumerate() {
                    i.model.feed(&Event::Message { peer_id: "p".into(), kind: "pb.x.notif.posted".into(), body: json!({"key": format!("k{n}"), "app": app, "title": title, "text": text}) });
                }
                for c in ["https://github.com/k0op4/Alero", "Reunión mañana 10:00"] {
                    i.model.feed(&Event::Message { peer_id: "p".into(), kind: "pb.x.clip".into(), body: json!({"text": c}) });
                }
                i.model.pc_media = Some(super::super::model::Media { title: "Un Verano Sin Ti".into(), artist: "Bad Bunny".into(), app: "Spotify".into(), playing: true, position_ms: 83_000, duration_ms: 212_000, speed: 1.0, at: Some(Instant::now()), art: Some(art.clone()), ..Default::default() });
                i.model.feed(&Event::Message { peer_id: "p".into(), kind: "pb.x.call".into(), body: json!({"active":true,"ringing":true,"canAnswer":true,"name":"Mamá"}) });
                i.model.feed(&Event::TransferOffer { id: "o1".into(), peer_id: "p".into(), peer_name: "Pixel 9a".into(), name: "Vacaciones-2026.mp4".into(), size: 482_000_000 });
                i.model.feed(&Event::TransferStarted { id: "x1".into(), peer_id: "p".into(), peer_name: "Pixel 9a".into(), name: "informe-final.pdf".into(), size: 8_000_000, incoming: false });
                i.model.feed(&Event::TransferProgress { id: "x1".into(), done: 5_200_000, total: 8_000_000, bytes_per_sec: 3_400_000 });
                i.model.feed(&Event::TransferStarted { id: "x2".into(), peer_id: "p".into(), peer_name: "Pixel 9a".into(), name: "PXL_20261125_211502.jpg".into(), size: 3_400_000, incoming: true });
                i.model.feed(&Event::TransferFinished { id: "x2".into(), ok: true, code: String::new(), message: String::new(), path: "C:/Descargas/PXL_20261125_211502.jpg".into() });
                i.set_thumb("x2", Some(art.clone()));
                i.model.feed(&Event::TransferStarted { id: "x3".into(), peer_id: "p".into(), peer_name: "Pixel 9a".into(), name: "Contrato-alquiler-2026.pdf".into(), size: 1_250_000, incoming: true });
                i.model.feed(&Event::TransferFinished { id: "x3".into(), ok: true, code: String::new(), message: String::new(), path: "C:/Descargas/Contrato-alquiler-2026.pdf".into() });
                i.model.adb.insert("p".into(), super::super::adb::Radios { wifi: true, bt: true, rotate: false });
                i.note = Note { icon: Some(Icon::Bell), title: "WhatsApp · Ana".into(), text: "¿Vienes a cenar hoy?".into(), good: false, w: 0.0, img: None, badge: None, avatar: None, notif: false };
                let logo = super::super::gfx::Image { w: 8, h: 8, data: [37u8, 211, 102, 255].repeat(64) };
                for n in i.model.notifs.iter_mut().take(2) {
                    n.avatar = Some(art.clone());
                }
                if *name == "note-chat" {
                    i.note.avatar = Some(art.clone());
                    i.note.img = Some(logo);
                }
                if name.starts_with("call-") || name.starts_with("live-") {
                    let n = i.model.feed(&Event::Message { peer_id: "p".into(), kind: "pb.x.call".into(), body: json!({"active":true,"ringing":false,"name":"\u{2068}Tamarindo 🌰\u{2069}","muted":true}) });
                    i.notices(n);
                    if let Some(c) = i.model.calls.get_mut("p") {
                        c.since = Instant::now().checked_sub(std::time::Duration::from_secs(83));
                    }
                }
                if matches!(*name, "live-ended" | "live-media") {
                    let n = i.model.feed(&Event::Message { peer_id: "p".into(), kind: "pb.x.call".into(), body: json!({"active":false}) });
                    i.notices(n);
                    if *name == "live-media" {
                        i.call_end.0 = 0.0;
                    }
                }
                if !name.starts_with("live-") {
                    i.open(view.clone(), Reason::Hover);
                }
                i.set_pointer(Some((CANVAS_W / 2.0, 40.0)));
                run(&mut i, 0.8);
                if *name == "drop" {
                    i.drag_over = true;
                }
                let mut cv = i.new_canvas(k);
                i.render(&mut cv);
                // Over a mid-grey "desktop" so the silhouette and rim are visible.
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

    /// The new player, lyrics, theme and touch states: `ISLAND_PNG_DIR=/tmp/x cargo test gallery_motion`.
    #[test]
    fn gallery_motion() {
        let Ok(dir) = std::env::var("ISLAND_PNG_DIR") else { return };
        let k = 2.0;
        let art = {
            let (w, h) = (64u32, 64u32);
            let mut data = Vec::new();
            for y in 0..h {
                for _x in 0..w {
                    let t = y as f32 / h as f32;
                    data.extend_from_slice(&[(246.0 - 160.0 * t) as u8, (176.0 - 120.0 * t) as u8, (122.0 + 4.0 * t) as u8, 255]);
                }
            }
            super::super::gfx::Image { w, h, data }
        };
        let save = |i: &mut Island, name: &str| {
            let mut cv = i.new_canvas(k);
            i.render(&mut cv);
            let mut out = Canvas::new(CANVAS_W, CANVAS_H, k);
            out.pm.fill(tiny_skia::Color::from_rgba8(70, 78, 92, 255));
            out.blit(&cv.pm, 1.0, 1.0, 0.0, 0.0, None);
            let mut rgba = out.pm.data().to_vec();
            for px in rgba.chunks_exact_mut(4) {
                px[3] = 255;
            }
            let file = std::fs::File::create(format!("{dir}/m-{name}.png")).unwrap();
            let mut enc = png::Encoder::new(file, out.width_px(), out.height_px());
            enc.set_color(png::ColorType::Rgba);
            enc.set_depth(png::BitDepth::Eight);
            enc.write_header().unwrap().write_image_data(&rgba).unwrap();
        };
        let fresh = |lyrics: bool| {
            let mut cfg = IslandConfig::default();
            cfg.animation = "normal".into();
            let mut i = Island::new(cfg);
            with_phone(&mut i);
            i.model.pc_media = Some(super::super::model::Media { title: "Atardecer en la costa".into(), artist: "Los Demo".into(), app: "Spotify.exe".into(), playing: true, position_ms: 17_000, duration_ms: 214_000, speed: 1.0, at: Some(Instant::now()), art: Some(art.clone()), ..Default::default() });
            i.set_lyrics_pref(lyrics);
            i.set_lyrics("Atardecer en la costa|Los Demo".into(), Some(crate::lyrics::parse_lrc("[00:06.00]Las olas borran lo que fui\n[00:11.00]y el sol se apaga sin decir\n[00:16.00]que el viento guarda tu canción entre la arena y el carbón\n[00:21.00]Camino lento hacia el final\n[00:26.00]de un día largo junto al mar")));
            for (n, (app, title, text, reply)) in [("WhatsApp", "Lucía", "¿Me pasas las fotos de ayer?", true), ("Gmail", "Banco Andino", "Tu estado de cuenta está listo", false)].iter().enumerate() {
                i.model.feed(&Event::Message { peer_id: "p".into(), kind: "pb.x.notif.posted".into(), body: json!({"key": format!("k{n}"), "app": app, "title": title, "text": text, "replyable": reply, "markable": true}) });
            }
            for c in ["https://github.com/k0op4/Alero", "Reunión mañana 10:00"] {
                i.model.feed(&Event::Message { peer_id: "p".into(), kind: "pb.x.clip".into(), body: json!({"text": c}) });
            }
            i
        };
        // Closed with lyrics: the sung line, themed.
        let mut i = fresh(true);
        run(&mut i, 1.5);
        save(&mut i, "closed-lyric");
        // The player, without and with lyrics; then with the volume open and the pointer on the progress bar.
        let mut i = fresh(false);
        i.open(View::Page(Page::Player), Reason::Hover);
        i.set_pointer(Some((CANVAS_W / 2.0, 40.0)));
        run(&mut i, 1.0);
        save(&mut i, "player");
        let mut i = fresh(true);
        i.open(View::Page(Page::Player), Reason::Hover);
        i.set_pointer(Some((CANVAS_W / 2.0, 40.0)));
        run(&mut i, 1.5);
        save(&mut i, "player-lyrics");
        i.act(Act::VolButton);
        i.set_pointer(Some((CANVAS_W / 2.0 - 200.0, 104.0)));
        run(&mut i, 0.8);
        save(&mut i, "player-lyrics-volume");
        // Controls: a tile caught half-way through switching on.
        let mut i = fresh(false);
        i.open(View::Page(Page::Controls), Reason::Hover);
        i.set_pointer(Some((CANVAS_W / 2.0, 40.0)));
        run(&mut i, 1.0);
        let mut cv = i.new_canvas(1.0);
        i.render(&mut cv);
        let dnd = i.hits.iter().find(|h| h.act == Act::Toggle("dnd")).map(|h| h.r).unwrap();
        i.set_pointer(Some((dnd.x + 12.0, dnd.y + 12.0)));
        i.render(&mut cv);
        i.press();
        i.release();
        run(&mut i, 0.12);
        save(&mut i, "controls-switching");
        run(&mut i, 0.8);
        save(&mut i, "controls-on");
        // Clipboard: just copied.
        let mut i = fresh(false);
        i.open(View::Page(Page::Clipboard), Reason::Hover);
        i.set_pointer(Some((CANVAS_W / 2.0, 40.0)));
        run(&mut i, 1.0);
        i.act(Act::CopyClip(0));
        run(&mut i, 0.5);
        save(&mut i, "clipboard-copied");
        // Notifications: answering one, one read.
        let mut i = fresh(false);
        i.open(View::Page(Page::Notifs), Reason::Hover);
        i.set_pointer(Some((CANVAS_W / 2.0, 80.0)));
        run(&mut i, 0.6);
        i.act(Act::NotifRead("k1".into()));
        i.act(Act::NotifReply("k0".into()));
        i.text("Claro, en un rato");
        i.set_pointer(Some((CANVAS_W / 2.0, 80.0)));
        run(&mut i, 1.0);
        save(&mut i, "notifs-reply");
        i.act(Act::Dismiss("k1".into()));
        run(&mut i, 0.14);
        save(&mut i, "notifs-dismissing");
        // A file over the target, and its landing.
        let mut i = fresh(false);
        i.drag(Drag::Enter);
        run(&mut i, 0.8);
        save(&mut i, "drop-over");
        i.dropped(vec![PathBuf::from("/tmp/informe.pdf")]);
        run(&mut i, 0.18);
        save(&mut i, "drop-landing");
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
        i.model.pc_media = Some(super::super::model::Media { title: "Un Verano Sin Ti".into(), artist: "Bad Bunny".into(), app: "Spotify".into(), playing: true, duration_ms: 212_000, speed: 1.0, at: Some(Instant::now()), ..Default::default() });
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

