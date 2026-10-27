// No console window in release builds on Windows.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

//! Desktop tray daemon: runs the engine and the tray icon, and serves the Flutter window over `pb_core::ipc`.
//! The window is started on demand and exits when closed, so idle cost is this process only (N2).
//! Started by the window as `pb_daemon <Launch JSON>`.

use std::path::PathBuf;
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use pb_core::engine::{Engine, Event, EventSink};
use pb_core::ipc::{self, Launch, Push, Subscribers};
use tao::event_loop::{ControlFlow, EventLoopBuilder};
use tray_icon::menu::{Menu, MenuEvent, MenuItem};
use tray_icon::{Icon, MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};

struct Ui {
    exe: PathBuf,
    subs: Arc<Subscribers>,
    last_launch: Mutex<Option<Instant>>,
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
        let needs_user = matches!(e, Event::PairRequest { .. } | Event::TransferOffer { .. });
        // Undelivered requests are replayed by `Subscribers` to the window we start here.
        if !self.0.subs.push(&Push::Event { event: e }) && needs_user {
            self.0.launch();
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
            eprintln!("uso: pb_daemon <Launch JSON> (lo lanza la app)");
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
    let ui = Arc::new(Ui { exe: launch.ui, subs: subs.clone(), last_launch: Mutex::new(None) });
    let engine = match Engine::start(launch.config, Arc::new(Sink(ui.clone()))) {
        Ok(e) => Arc::new(e),
        Err(e) => fail(e),
    };
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

    let open = MenuItem::new("Abrir Phonebridge", true, None);
    let quit = MenuItem::new("Salir", true, None);
    let menu = Menu::new();
    menu.append_items(&[&open, &quit]).expect("tray menu");
    let (open_id, quit_id) = (open.id().clone(), quit.id().clone());
    let _tray = TrayIconBuilder::new()
        .with_menu(Box::new(menu))
        .with_menu_on_left_click(false)
        .with_tooltip("Phonebridge")
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
