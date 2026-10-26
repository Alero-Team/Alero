// Hide the console window in release builds on Windows.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

//! Thin shell: the engine (pb-core) owns every rule; this file forwards commands and events to the web UI.
//! Closing the window hides it to the tray and the engine keeps running, so the next open is instant.

use std::path::PathBuf;
use std::sync::Arc;

use pb_core::engine::{Config, Engine, Event, EventSink, DEFAULT_PORT};
use tauri::menu::{Menu, MenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Manager, RunEvent, State};

struct Sink(AppHandle);

impl EventSink for Sink {
    fn on_event(&self, e: Event) {
        // Something needs the user's answer: bring the window up.
        if matches!(e, Event::PairRequest { .. } | Event::TransferOffer { .. }) {
            show(&self.0);
        }
        let _ = self.0.emit("pb-event", &e);
    }
}

/// Brings the window up, creating it if it was closed. Closing destroys the webview (the heavy part) while the
/// engine keeps running in the tray.
fn show(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.show();
        let _ = w.unminimize();
        let _ = w.set_focus();
    } else if let Some(cfg) = app.config().app.windows.first() {
        if let Ok(b) = tauri::WebviewWindowBuilder::from_config(app, cfg) {
            let _ = b.build();
        }
    }
}

struct App {
    engine: Engine,
    downloads: PathBuf,
}

type St<'a> = State<'a, App>;

#[tauri::command]
fn state(s: St) -> serde_json::Value {
    serde_json::json!({
        "id": s.engine.device_id(),
        "name": s.engine.name(),
        "port": s.engine.port(),
        "peers": s.engine.peers(),
        "history": s.engine.history(),
        "diagnostics": s.engine.diagnostics(),
        "downloads": s.downloads.to_string_lossy(),
    })
}

#[tauri::command]
fn pair_peer(s: St, id: String) -> Result<(), String> {
    s.engine.pair_with_peer(&id)
}

#[tauri::command]
fn pair_addr(s: St, addr: String) -> Result<(), String> {
    s.engine.pair_with_addr(addr.trim())
}

#[tauri::command]
fn respond_pair(s: St, id: String, accept: bool) {
    s.engine.respond_pair(&id, accept)
}

#[tauri::command]
fn respond_transfer(s: St, id: String, accept: bool) {
    s.engine.respond_transfer(&id, accept)
}

#[tauri::command]
fn forget(s: St, id: String) -> Result<(), String> {
    s.engine.revoke(&id)
}

/// Returns one error per file that could not be queued.
#[tauri::command]
fn send_paths(s: St, peer: String, paths: Vec<String>) -> Vec<String> {
    paths
        .iter()
        .filter_map(|p| s.engine.send_file(&peer, std::path::Path::new(p), None).err().map(|e| format!("{p}: {e}")))
        .collect()
}

#[tauri::command]
fn cancel(s: St, id: String) {
    s.engine.cancel_transfer(&id)
}

#[tauri::command]
fn retry(s: St, id: String) -> Result<(), String> {
    s.engine.retry(&id).map(|_| ())
}

#[tauri::command]
fn clear_history(s: St) -> Result<(), String> {
    s.engine.clear_history()
}

#[tauri::command]
fn set_name(s: St, name: String) {
    s.engine.set_name(&name)
}

#[tauri::command]
fn set_auto_accept(s: St, on: bool) {
    s.engine.set_auto_accept(on)
}

#[tauri::command]
fn open_downloads(s: St) {
    #[cfg(windows)]
    let _ = std::process::Command::new("explorer").arg(&s.downloads).spawn();
    #[cfg(not(windows))]
    let _ = std::process::Command::new("xdg-open").arg(&s.downloads).spawn();
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _, _| show(app)))
        .plugin(tauri_plugin_dialog::init())
        .setup(|app| {
            let data = app.path().app_data_dir()?.join("pb");
            let downloads = app.path().download_dir()?.join("Phonebridge");
            let name = std::env::var("COMPUTERNAME").or_else(|_| std::env::var("HOSTNAME")).unwrap_or_else(|_| "Ordenador".into());
            let engine = Engine::start(
                Config { data_dir: data, download_dir: downloads.clone(), name, port: DEFAULT_PORT, discovery_port: DEFAULT_PORT, auto_accept: true },
                Arc::new(Sink(app.handle().clone())),
            )?;
            app.manage(App { engine, downloads });

            let open = MenuItem::with_id(app, "open", "Abrir Phonebridge", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "Salir", true, None::<&str>)?;
            TrayIconBuilder::new()
                .icon(app.default_window_icon().cloned().ok_or("no icon")?)
                .tooltip("Phonebridge")
                .menu(&Menu::with_items(app, &[&open, &quit])?)
                .on_menu_event(|app, ev| match ev.id.as_ref() {
                    "open" => show(app),
                    "quit" => {
                        app.state::<App>().engine.shutdown();
                        app.exit(0);
                    }
                    _ => {}
                })
                .on_tray_icon_event(|t, ev| {
                    if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } = ev {
                        show(t.app_handle());
                    }
                })
                .build(app)?;
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            state, pair_peer, pair_addr, respond_pair, respond_transfer, forget, send_paths, cancel, retry, clear_history,
            set_name, set_auto_accept, open_downloads
        ])
        .build(tauri::generate_context!())
        .expect("error while building Phonebridge")
        .run(|_app, event| {
            // Closing the last window must not quit: the engine lives on in the tray. `Salir` exits with a code.
            if let RunEvent::ExitRequested { api, code, .. } = event {
                if code.is_none() {
                    api.prevent_exit();
                }
            }
        });
}
