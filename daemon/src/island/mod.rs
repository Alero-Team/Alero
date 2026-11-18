//! Alero Island: the overlay that drops from the top edge of the screen when the pointer goes there.
//!
//! `ui` is the whole behaviour and look, with no operating system in it; `run` is the loop; `win` and `x11` are the
//! platform windows. Settings come from `island.json` (written by the app's Ajustes), see `config`.

pub mod adb;
pub mod config;
pub mod gfx;
pub mod model;
pub mod motion;
pub mod run;
pub mod ui;

#[cfg(windows)]
mod win;
#[cfg(target_os = "linux")]
mod x11;

use std::path::PathBuf;
use std::sync::mpsc::{Receiver, Sender};
use std::sync::Arc;

use pb_core::engine::{Engine, PeerView};
use serde_json::{json, Value};

pub use run::Handle;
use run::{Ctx, Exec, Msg};
use ui::Cmd;

use crate::lang::t;

/// The engine side of the island's buttons.
struct EngineExec {
    engine: Arc<Engine>,
    show: Box<dyn Fn() + Send + Sync>,
}

impl EngineExec {
    fn send(&self, peer: &Option<String>, kind: &str, body: Value) -> Option<(bool, String, String)> {
        let Some(p) = peer else {
            return Some((false, t("Sin teléfono conectado", "No phone connected").into(), t("Conecta un teléfono para usar esto.", "Connect a phone to use this.").into()));
        };
        self.engine.send_message(p, kind, body).err().map(|e| (false, t("No se pudo enviar", "Could not send").into(), e))
    }
}

impl Exec for EngineExec {
    fn peers(&self) -> Vec<PeerView> {
        self.engine.peers()
    }

    fn run(&self, cmd: Cmd, ctx: &Ctx) -> Option<(bool, String, String)> {
        match cmd {
            Cmd::OpenApp => (self.show)(),
            Cmd::PcMedia(k) => {
                crate::sys::media_key(k);
            }
            Cmd::PhoneMedia(k) => return self.send(&ctx.target, "pb.x.media.cmd", json!({"action": k})),
            Cmd::Respond { id, accept } => self.engine.respond_transfer(&id, accept),
            Cmd::Cancel(id) => self.engine.cancel_transfer(&id),
            Cmd::CallAction(a) => return self.send(&ctx.call_peer, "pb.x.call.cmd", json!({"action": a})),
            Cmd::Phone { what, body } => return self.send(&ctx.target, &format!("pb.x.phone.{what}"), body),
            Cmd::CopyText(text) => crate::platform::set_clipboard(&text),
            Cmd::SendClipboard => {
                let text = crate::platform::get_clipboard();
                if text.is_empty() {
                    return Some((false, t("El portapapeles está vacío", "The clipboard is empty").into(), String::new()));
                }
                let text: String = text.chars().take(60000).collect();
                return self.send(&ctx.target, "pb.x.clip", json!({"text": text}));
            }
            Cmd::SendFiles(paths) => {
                let Some(peer) = &ctx.target else { return None };
                let mut failed: Option<(String, String)> = None;
                for p in paths {
                    if let Err(e) = self.engine.send_file(peer, &p, None) {
                        let name = p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
                        let why = if p.is_dir() { t("Las carpetas no se pueden enviar todavía.", "Folders cannot be sent yet.").to_string() } else { e };
                        failed.get_or_insert((name, why));
                    }
                }
                return failed.map(|(name, why)| (false, name, why));
            }
            // A background question: if it fails, the phone's next change brings the state anyway.
            Cmd::AskMedia => {
                let _ = self.send(&ctx.target, "pb.x.media.request", json!({}));
            }
            Cmd::Beep | Cmd::Adb { .. } => {} // run.rs carries these out itself
        }
        None
    }
}

/// The channel the engine's events travel by. Make it before the engine starts, so nothing is lost.
pub fn channel() -> (Handle, Receiver<Msg>, Sender<Msg>) {
    run::channel()
}

/// Starts the island's thread. It idles (and costs next to nothing) while the island is turned off.
pub fn spawn(rx: Receiver<Msg>, tx: Sender<Msg>, data: PathBuf, engine: Arc<Engine>, show: Box<dyn Fn() + Send + Sync>) {
    let exec = Box::new(EngineExec { engine, show });
    let _ = std::thread::Builder::new().name("island".into()).spawn(move || {
        let host: Option<Box<dyn run::Host>> = make_host();
        match host {
            Some(h) => run::run(h, rx, tx, data, exec),
            None => eprintln!("alero island: sin ventana disponible en este sistema"),
        }
    });
}

#[cfg(windows)]
fn make_host() -> Option<Box<dyn run::Host>> {
    win::WinHost::new().map(|h| Box::new(h) as Box<dyn run::Host>)
}

#[cfg(target_os = "linux")]
fn make_host() -> Option<Box<dyn run::Host>> {
    x11::X11Host::new().map(|h| Box::new(h) as Box<dyn run::Host>)
}

#[cfg(not(any(windows, target_os = "linux")))]
fn make_host() -> Option<Box<dyn run::Host>> {
    None
}
