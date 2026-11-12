// No console window in release builds on Windows.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

//! Desktop tray daemon: runs the engine and the tray icon, and serves the Flutter window over `pb_core::ipc`.
//! The window is started on demand and exits when closed, so idle cost is this process only (N2).
//! Started by the window as `alero_daemon <Launch JSON>`.

use std::path::PathBuf;
use std::process::Command;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use pb_core::engine::{Engine, Event, EventSink};
use pb_core::ipc::{self, Launch, Push, Subscribers};
use tao::event_loop::{ControlFlow, EventLoopBuilder};
use tray_icon::menu::{Menu, MenuEvent, MenuItem};
use tray_icon::{Icon, MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};

mod pc_files;
mod remote;
mod sys;
#[cfg(target_os = "linux")]
mod linux;
#[cfg(windows)]
mod win;
// The platform's toasts, clipboard and file helpers, behind one name.
#[cfg(target_os = "linux")]
use linux as platform;
#[cfg(windows)]
use win as platform;

use remote::Remote;

struct Ui {
    exe: PathBuf,
    subs: Arc<Subscribers>,
    last_launch: Mutex<Option<Instant>>,
    engine: OnceLock<Arc<Engine>>,
    remote: Arc<Remote>,
    /// Transfers whose progress card is on screen (id -> file name, which the card's updates repeat).
    cards: Mutex<std::collections::HashMap<String, String>>,
}

impl Ui {
    /// Focuses an open window, or starts one.
    fn show(&self) {
        if !self.subs.push(&Push::Show) {
            self.launch();
        }
    }

    fn launch(&self) {
        // The window needs ~2 s to connect; don't start several for a burst of events.
        let mut last = self.last_launch.lock().unwrap();
        if last.is_some_and(|t| t.elapsed() < Duration::from_secs(10)) {
            return;
        }
        *last = Some(Instant::now());
        let _ = Command::new(&self.exe).spawn();
    }
}

struct Sink(Arc<Ui>);

impl EventSink for Sink {
    fn on_event(&self, e: Event) {
        // Remote control, screen sharing and this computer's own info are answered here, window or not.
        if let Some(engine) = self.0.engine.get() {
            match &e {
                Event::Message { peer_id, kind, body } if self.0.remote.handle(engine, peer_id, kind, body) => return,
                Event::PeerChanged { peer } if peer.trusted && peer.state == pb_core::engine::PeerState::Connected => {
                    self.0.remote.push_info(engine, Some(&peer.id));
                }
                _ => {}
            }
        }
        let needs_user = matches!(e, Event::PairRequest { .. } | Event::TransferOffer { .. });
        // Undelivered requests are replayed by `Subscribers` to the window we start here.
        let delivered = self.0.subs.push(&Push::Event { event: e.clone() });
        if delivered {
            // The window took over mid-transfer: its own UI shows the result, so the card must not linger.
            #[cfg(any(windows, target_os = "linux"))]
            if let Event::TransferFinished { id, .. } = &e {
                if self.0.cards.lock().unwrap().remove(id).is_some() {
                    platform::transfer_clear(id);
                }
            }
            return;
        }
        if needs_user {
            self.0.launch();
        } else {
            self.0.alone(e);
        }
    }
}

impl Ui {
    /// No window open: what the phone sends still reaches the user (toast, clipboard), and the phone still
    /// learns what this computer is. With a window open, the Flutter side does all of this.
    fn alone(&self, e: Event) {
        let Some(engine) = self.engine.get() else { return };
        match e {
            Event::Message { peer_id, kind, body } => {
                let s = |k: &str| body[k].as_str().unwrap_or("").to_string();
                match kind.as_str() {
                    #[cfg(any(windows, target_os = "linux"))]
                    "pb.x.notif.posted" => {
                        let title = if s("title").is_empty() { s("app") } else { format!("{} · {}", s("app"), s("title")) };
                        platform::toast_icon(&title, &s("text"), &s("pkg"), &s("icon"));
                    }
                    #[cfg(any(windows, target_os = "linux"))]
                    "pb.x.clip" if !s("text").is_empty() => {
                        platform::set_clipboard(&s("text"));
                        let from = engine.peers().into_iter().find(|p| p.id == peer_id).map(|p| p.name).unwrap_or_default();
                        platform::toast("Portapapeles copiado", &format!("Recibido de {from}"));
                    }
                    _ => {}
                }
            }
            // A file waits for consent: answer from the toast. Nothing is downloaded until Aceptar.
            #[cfg(any(windows, target_os = "linux"))]
            Event::TransferOffer { id, peer_name, name, size, .. } => {
                let engine = engine.clone();
                let mb = size as f64 / (1024.0 * 1024.0);
                platform::toast_buttons(
                    &format!("{peer_name} quiere enviarte un archivo"),
                    &format!("{name} · {mb:.1} MB"),
                    &[platform::Button::Call("Rechazar".into(), format!("decline:{id}")), platform::Button::Call("Aceptar".into(), format!("accept:{id}"))],
                    // The engine ignores a second answer, so repeated clicks cannot start two downloads.
                    move |arg| match arg.split_once(':') {
                        Some(("accept", id)) => engine.respond_transfer(id, true),
                        Some(("decline", id)) => engine.respond_transfer(id, false),
                        _ => {}
                    },
                );
            }
            #[cfg(any(windows, target_os = "linux"))]
            Event::TransferStarted { id, peer_name, name, size, incoming, .. } => {
                self.cards.lock().unwrap().insert(id.clone(), name.clone());
                let engine = engine.clone();
                platform::transfer_start(&id, incoming, &peer_name, &name, size, move |arg| {
                    if let Some(("cancel", id)) = arg.split_once(':') {
                        engine.cancel_transfer(id);
                    }
                });
            }
            #[cfg(any(windows, target_os = "linux"))]
            Event::TransferProgress { id, done, total, bytes_per_sec } => {
                let name = self.cards.lock().unwrap().get(&id).cloned();
                if let Some(name) = name {
                    platform::transfer_progress(&id, &name, done, total, bytes_per_sec);
                }
            }
            #[cfg(any(windows, target_os = "linux"))]
            Event::TransferFinished { id, ok, path, .. } => {
                let had_card = self.cards.lock().unwrap().remove(&id).is_some();
                if ok && !path.is_empty() {
                    // Opening an executable would run it: transfer_done offers only its folder.
                    platform::transfer_done(&id, std::path::Path::new(&path));
                } else if had_card {
                    platform::transfer_clear(&id);
                }
            }
            _ => {}
        }
    }
}

enum UserEvent {
    Menu(MenuEvent),
    Tray(TrayIconEvent),
}

fn main() {
    let launch: Launch = match std::env::args().nth(1).map(|a| serde_json::from_str(&a)) {
        Some(Ok(l)) => l,
        _ => {
            eprintln!("uso: alero_daemon <Launch JSON> (lo lanza la app)");
            std::process::exit(2);
        }
    };
    let data = launch.config.data_dir.clone();
    let fail = |msg: String| -> ! {
        // The window reads this to explain why it could not connect.
        let _ = std::fs::create_dir_all(&data);
        let _ = std::fs::write(data.join("daemon-error.txt"), &msg);
        std::process::exit(1);
    };
    let subs = Arc::new(Subscribers::default());
    let ui = Arc::new(Ui {
        exe: launch.ui,
        subs: subs.clone(),
        last_launch: Mutex::new(None),
        engine: OnceLock::new(),
        remote: Remote::new(data.clone()),
        cards: Mutex::new(Default::default()),
    });
    #[cfg(any(windows, target_os = "linux"))]
    platform::register_app();
    sys::keep_com_alive();
    let engine = match Engine::start(launch.config, Arc::new(Sink(ui.clone()))) {
        Ok(e) => Arc::new(e),
        Err(e) => fail(e),
    };
    let _ = ui.engine.set(engine.clone());
    ui.remote.spawn_status(engine.clone());
    if let Err(e) = ipc::listen(&data, engine.clone(), subs.clone()) {
        fail(format!("canal local: {e}"));
    }
    let _ = std::fs::remove_file(data.join("daemon-error.txt"));

    let event_loop = EventLoopBuilder::<UserEvent>::with_user_event().build();
    let proxy = event_loop.create_proxy();
    MenuEvent::set_event_handler(Some(move |e| {
        let _ = proxy.send_event(UserEvent::Menu(e));
    }));
    let proxy = event_loop.create_proxy();
    TrayIconEvent::set_event_handler(Some(move |e| {
        let _ = proxy.send_event(UserEvent::Tray(e));
    }));

    let open = MenuItem::new("Abrir Alero", true, None);
    let quit = MenuItem::new("Salir", true, None);
    let menu = Menu::new();
    menu.append_items(&[&open, &quit]).expect("tray menu");
    let (open_id, quit_id) = (open.id().clone(), quit.id().clone());
    let _tray = TrayIconBuilder::new()
        .with_menu(Box::new(menu))
        .with_menu_on_left_click(false)
        .with_tooltip("Alero")
        .with_icon(icon())
        .build()
        .unwrap_or_else(|e| fail(format!("icono de bandeja: {e}")));

    event_loop.run(move |event, _, flow| {
        *flow = ControlFlow::Wait;
        match event {
            tao::event::Event::UserEvent(UserEvent::Tray(TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            })) => ui.show(),
            tao::event::Event::UserEvent(UserEvent::Menu(m)) if m.id == open_id => ui.show(),
            tao::event::Event::UserEvent(UserEvent::Menu(m)) if m.id == quit_id => {
                subs.push(&Push::Quit);
                engine.shutdown();
                let _ = std::fs::remove_file(data.join(ipc::IPC_FILE));
                *flow = ControlFlow::Exit;
            }
            _ => {}
        }
    });
}

fn icon() -> Icon {
    let mut r = png::Decoder::new(std::io::Cursor::new(&include_bytes!("../icon.png")[..])).read_info().expect("icon.png");
    let mut buf = vec![0; r.output_buffer_size().expect("icon size")];
    let info = r.next_frame(&mut buf).expect("icon.png");
    assert_eq!(info.color_type, png::ColorType::Rgba, "icon.png must be RGBA");
    buf.truncate(info.buffer_size());
    Icon::from_rgba(buf, info.width, info.height).expect("icon")
}
