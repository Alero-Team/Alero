//! Android only: the Kotlin service talks to the engine without Dart, so phone features (notifications, media,
//! clipboard, device info) keep working after the UI is closed. Kotlin class: `dev.alero.app.Bridge`.
//! Same rule as the Dart API: only type conversion here.

use std::collections::VecDeque;
use std::sync::{Condvar, Mutex};
use std::time::Duration;

use jni::objects::{JClass, JString};
use jni::sys::{jlong, jstring};
use jni::JNIEnv;
use pb_core::engine as core;
use pb_core::ipc::Cmd;

static QUEUE: Mutex<VecDeque<String>> = Mutex::new(VecDeque::new());
static READY: Condvar = Condvar::new();
const QUEUE_MAX: usize = 256;

/// Called for every engine event; keeps what the service needs as JSON lines.
pub(crate) fn push(e: &core::Event) {
    // Only what the service acts on: remote-screen frames and other large messages are for the Dart side.
    let keep = match e {
        core::Event::Message { kind, .. } => {
            kind.starts_with("pb.x.fs.")
                || matches!(kind.as_str(), "pb.x.info.request" | "pb.x.clip" | "pb.x.media.cmd" | "pb.x.notif.dismiss" | "pb.x.notif.reply" | "pb.x.media.request")
        }
        // PeerChanged/Gone: who is connected. TransferFinished: the service closes the file it opened for a send.
        core::Event::PeerChanged { .. } | core::Event::PeerGone { .. } | core::Event::TransferFinished { .. } => true,
        _ => false,
    };
    if !keep {
        return;
    }
    let Ok(line) = serde_json::to_string(e) else { return };
    let mut q = QUEUE.lock().unwrap();
    if q.len() == QUEUE_MAX {
        q.pop_front(); // nobody is reading: drop the oldest
    }
    q.push_back(line);
    READY.notify_one();
}

fn text(env: &mut JNIEnv, s: &JString) -> String {
    env.get_string(s).map(Into::into).unwrap_or_default()
}

fn out(env: &mut JNIEnv, s: Option<String>) -> jstring {
    match s {
        Some(s) => env.new_string(s).map(|j| j.into_raw()).unwrap_or(std::ptr::null_mut()),
        None => std::ptr::null_mut(),
    }
}

/// Returns null on success, else the error text.
#[no_mangle]
pub extern "system" fn Java_dev_alero_app_Bridge_send(
    mut env: JNIEnv,
    _: JClass,
    peer: JString,
    kind: JString,
    body: JString,
) -> jstring {
    let (peer, kind, body) = (text(&mut env, &peer), text(&mut env, &kind), text(&mut env, &body));
    let r = serde_json::from_str(&body)
        .map_err(|e| e.to_string())
        .and_then(|body| crate::api::engine::call(Cmd::SendMessage { peer, kind, body }));
    out(&mut env, r.err())
}

/// Starts sending a file (`fd:N` for a descriptor the service opened). Returns the transfer id, or `!` + the error.
#[no_mangle]
pub extern "system" fn Java_dev_alero_app_Bridge_sendFile(mut env: JNIEnv, _: JClass, peer: JString, path: JString, name: JString) -> jstring {
    let (peer, path, name) = (text(&mut env, &peer), text(&mut env, &path), text(&mut env, &name));
    let r = crate::api::engine::call(Cmd::SendFile { peer, path, name: Some(name) });
    let s = match r {
        Ok(v) => v.as_str().unwrap_or_default().to_string(),
        Err(e) => format!("!{e}"),
    };
    out(&mut env, Some(s))
}

/// JSON array of peers, or null if the engine is not running.
#[no_mangle]
pub extern "system" fn Java_dev_alero_app_Bridge_peers(mut env: JNIEnv, _: JClass) -> jstring {
    let r = crate::api::engine::call(Cmd::Peers).ok().map(|v| v.to_string());
    out(&mut env, r)
}

/// Next event as JSON (`{"type":"Message",…}` or `PeerChanged`/`PeerGone`), or null after `timeout_ms`.
#[no_mangle]
pub extern "system" fn Java_dev_alero_app_Bridge_next(mut env: JNIEnv, _: JClass, timeout_ms: jlong) -> jstring {
    let q = QUEUE.lock().unwrap();
    let (mut q, _) = READY
        .wait_timeout_while(q, Duration::from_millis(timeout_ms.max(0) as u64), |q| q.is_empty())
        .unwrap();
    let line = q.pop_front();
    drop(q);
    out(&mut env, line)
}
