"use strict";
// UI only: every rule (trust, pairing, transfer) lives in the Rust engine. Names and messages come from the
// network, so the DOM is built with textContent, never innerHTML.

const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;
const dialog = window.__TAURI__.dialog;

const S = { tab: "devices", id: "", name: "", port: 0, peers: [], history: [], diagnostics: [], downloads: "", active: new Map(), pair: null, offer: null, auto: true };

const h = (tag, props = {}, ...kids) => {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(props)) {
    if (k === "class") e.className = v;
    else if (k.startsWith("on")) e.addEventListener(k.slice(2), v);
    else if (v !== false && v != null) e.setAttribute(k, v === true ? "" : v);
  }
  for (const c of kids.flat()) if (c != null && c !== false) e.append(c.nodeType ? c : document.createTextNode(String(c)));
  return e;
};

const bytes = (n) => (n >= 2 ** 30 ? (n / 2 ** 30).toFixed(2) + " GB" : n >= 2 ** 20 ? (n / 2 ** 20).toFixed(1) + " MB" : n >= 1024 ? Math.round(n / 1024) + " KB" : n + " B");

const EXPLAIN = {
  NETWORK: "se perdió la conexión. Se reintenta sola; comprueba que ambos estén en la misma red Wi-Fi",
  INTEGRITY: "el archivo llegó dañado. Vuelve a enviarlo",
  REJECTED: "el otro dispositivo no lo aceptó",
  PROTOCOL: "versiones incompatibles. Actualiza la app en ambos dispositivos",
  INVALID_NAME: "el nombre del archivo no es válido",
  CANCELLED: "cancelado",
};
const explain = (code, msg) => EXPLAIN[code] || msg || code;

let toastTimer;
const toast = (t) => {
  const el = document.getElementById("toast");
  el.textContent = t;
  el.classList.add("show");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.remove("show"), 4500);
};

const call = async (cmd, args) => {
  try {
    return await invoke(cmd, args);
  } catch (e) {
    toast(String(e));
  }
};

const refresh = async () => {
  const s = await invoke("state");
  Object.assign(S, { id: s.id, name: S.name || s.name, port: s.port, peers: s.peers, history: s.history, diagnostics: s.diagnostics, downloads: s.downloads });
  render();
};

const stateText = (p) =>
  ({ Connected: "Conectado", Connecting: "Conectando…", Rejected: "Rechazado: el otro dispositivo ya no confía en este", Disconnected: p.detail ? "Desconectado · " + p.detail : "Desconectado" })[p.state];

// ---- screens -----------------------------------------------------------------------------------------------

const sendTo = async (peer) => {
  const picked = await dialog.open({ multiple: true });
  if (picked && picked.length) await sendPaths(peer, picked);
};

const sendPaths = async (peer, paths) => {
  const errors = await call("send_paths", { peer, paths });
  if (errors && errors.length) toast("No se pudo enviar: " + errors[0]);
};

const devices = () => {
  const paired = S.peers.filter((p) => p.trusted);
  const nearby = S.peers.filter((p) => !p.trusted);
  return [
    h("div", { class: "card" }, h("div", { class: "name" }, S.name || "Este ordenador"), h("div", { class: "sub" }, "Este ordenador · ID " + S.id.slice(0, 8) + " · puerto " + S.port)),
    h("h2", {}, "Emparejados"),
    paired.length ? paired.map(pairedCard) : h("div", { class: "empty" }, "Aún no hay ninguno. Abre Phonebridge en el teléfono, en la misma red Wi-Fi, y empareja desde «Cerca»."),
    h("h2", {}, "Cerca"),
    nearby.length ? nearby.map(nearbyCard) : h("div", { class: "empty" }, "No se ve ningún dispositivo nuevo. Si tu red aísla los dispositivos, añade el teléfono por su IP."),
    h("div", { class: "row", style: "margin-top:12px" }, h("button", { class: "btn", onclick: addByIp }, "Añadir por IP")),
  ];
};

const pairedCard = (p) =>
  h("div", { class: "card", "data-peer": p.id },
    h("div", { class: "name" }, p.name || p.id.slice(0, 8)),
    h("div", { class: "sub " + (p.state === "Rejected" ? "err" : "") }, stateText(p)),
    h("div", { class: "row", style: "margin-top:8px" },
      h("button", { class: "btn primary", disabled: p.state !== "Connected", onclick: () => sendTo(p.id) }, "Enviar archivos"),
      h("button", { class: "link", onclick: () => confirmForget(p) }, "Olvidar")),
    p.state === "Connected" ? h("div", { class: "sub hint" }, "También puedes soltar archivos aquí.") : null);

const nearbyCard = (p) =>
  h("div", { class: "card" }, h("div", { class: "name" }, p.name || p.id.slice(0, 8)), h("div", { class: "sub" }, p.addr),
    h("div", { class: "row", style: "margin-top:8px" }, h("button", { class: "btn", onclick: () => call("pair_peer", { id: p.id }) }, "Emparejar")));

const transfers = () => {
  const act = [...S.active.values()];
  const out = [];
  if (!act.length && !S.history.length) out.push(h("div", { class: "empty" }, "Nada todavía. Envía un archivo desde «Dispositivos» o suéltalo sobre un dispositivo."));
  for (const x of act) {
    out.push(h("div", { class: "card" },
      h("div", { class: "name" }, (x.incoming ? "↓ " : "↑ ") + x.name), h("div", { class: "sub" }, x.peer_name),
      h("progress", { id: "p-" + x.id, max: Math.max(x.size, 1), value: x.done || 0 }),
      h("div", { class: "sub", id: "t-" + x.id }, progressText(x)),
      h("button", { class: "link", onclick: () => call("cancel", { id: x.id }) }, "Cancelar")));
  }
  if (S.history.length) {
    out.push(h("div", { class: "row" }, h("h2", { class: "grow" }, "Historial"),
      h("button", { class: "link", onclick: () => call("clear_history").then(refresh) }, "Borrar"),
      h("button", { class: "link", onclick: () => call("open_downloads") }, "Abrir carpeta")));
    for (const e of S.history) {
      const st = e.status === "done" ? "Completado" : e.status === "cancelled" ? "Cancelado" : "Falló: " + explain(e.code, e.message);
      out.push(h("div", { class: "card" },
        h("div", { class: "name" }, (e.incoming ? "↓ " : "↑ ") + e.name),
        h("div", { class: "sub " + (e.status === "failed" ? "err" : "") }, st + " · " + bytes(e.size) + " · " + e.peer_name),
        h("div", { class: "sub" }, new Date(e.time * 1000).toLocaleString()),
        e.status !== "done" && !e.incoming && e.path ? h("button", { class: "link", onclick: () => call("retry", { id: e.id }) }, "Reintentar") : null));
    }
  }
  return out;
};

const progressText = (x) => {
  if (x.note) return x.note;
  const eta = x.rate > 0 ? " · " + Math.ceil((x.size - x.done) / x.rate) + " s" : "";
  return bytes(x.done || 0) + " de " + bytes(x.size) + " · " + bytes(x.rate || 0) + "/s" + eta;
};

const settings = () => {
  const name = h("input", { type: "text", value: S.name, "aria-label": "Nombre de este dispositivo", maxlength: "64" });
  return [
    h("h2", {}, "Este dispositivo"),
    h("div", { class: "card" }, name, h("div", { class: "row", style: "margin-top:8px" }, h("button", { class: "btn", onclick: () => { S.name = name.value.trim() || S.name; localStorage.setItem("name", S.name); call("set_name", { name: S.name }); toast("Nombre guardado"); } }, "Guardar nombre"))),
    h("div", { class: "card switch" },
      h("div", { class: "grow" }, h("div", { class: "name" }, "Aceptar archivos automáticamente"), h("div", { class: "sub" }, "Solo de dispositivos emparejados. Si lo apagas, se te pregunta cada vez.")),
      h("input", { type: "checkbox", checked: S.auto, "aria-label": "Aceptar archivos automáticamente", onchange: (e) => { S.auto = e.target.checked; localStorage.setItem("auto", S.auto); call("set_auto_accept", { on: S.auto }); } })),
    h("h2", {}, "Diagnóstico de red"),
    h("div", { class: "card" }, S.diagnostics.map((l) => h("div", { class: "mono" }, l)),
      h("div", { class: "sub hint" }, "Si no ves el teléfono: ambos deben estar en la misma red Wi-Fi, sin «aislamiento de clientes», y el cortafuegos debe permitir Phonebridge (TCP y UDP " + S.port + ")."),
      h("button", { class: "link", onclick: refresh }, "Actualizar")),
    h("h2", {}, "Acerca de"),
    h("div", { class: "card" }, h("div", {}, "Phonebridge 0.1.0-alpha · protocolo 1"), h("div", { class: "sub" }, "Licencia GPL-3.0-or-later. Versión de pruebas.")),
  ];
};

// ---- dialogs -----------------------------------------------------------------------------------------------

const showModal = (node) => {
  const m = document.getElementById("modal");
  m.replaceChildren(node);
  m.hidden = false;
  node.querySelector("button.primary, button")?.focus();
};
const hideModal = () => { document.getElementById("modal").hidden = true; };

const addByIp = () => {
  const ip = h("input", { type: "text", placeholder: "IP o IP:puerto", "aria-label": "IP del dispositivo" });
  showModal(h("div", { class: "dialog", role: "dialog", "aria-modal": "true" }, h("h3", {}, "Añadir por IP"), ip,
    h("div", { class: "actions" }, h("button", { class: "btn", onclick: hideModal }, "Cancelar"), h("button", { class: "btn primary", onclick: () => { hideModal(); if (ip.value.trim()) call("pair_addr", { addr: ip.value }); } }, "Emparejar"))));
  ip.focus();
};

const confirmForget = (p) =>
  showModal(h("div", { class: "dialog", role: "dialog", "aria-modal": "true" }, h("h3", {}, "¿Olvidar " + (p.name || "este dispositivo") + "?"), h("div", {}, "Dejará de poder conectarse. Para volver a usarlo habrá que emparejar otra vez."),
    h("div", { class: "actions" }, h("button", { class: "btn", onclick: hideModal }, "Cancelar"), h("button", { class: "btn primary", onclick: () => { hideModal(); call("forget", { id: p.id }).then(refresh); } }, "Olvidar"))));

const syncDialogs = () => {
  if (S.pair) {
    const p = S.pair;
    showModal(h("div", { class: "dialog", role: "alertdialog", "aria-modal": "true" }, h("h3", {}, "Emparejar con " + p.name),
      h("div", {}, "Comprueba que en " + p.name + " aparece este mismo código. Si no coincide, cancela: alguien podría estar interceptando la conexión."),
      h("div", { class: "code" }, p.code.slice(0, 3) + " " + p.code.slice(3)),
      h("div", { class: "actions" }, h("button", { class: "btn", onclick: () => { S.pair = null; hideModal(); call("respond_pair", { id: p.peer_id, accept: false }); } }, "Cancelar"), h("button", { class: "btn primary", onclick: () => { call("respond_pair", { id: p.peer_id, accept: true }); showModal(h("div", { class: "dialog" }, "Esperando al otro dispositivo…")); } }, "Coincide"))));
  } else if (S.offer) {
    const o = S.offer;
    showModal(h("div", { class: "dialog", role: "alertdialog", "aria-modal": "true" }, h("h3", {}, "Archivo entrante"), h("div", {}, o.peer_name + " quiere enviarte «" + o.name + "» (" + bytes(o.size) + ")."),
      h("div", { class: "actions" }, h("button", { class: "btn", onclick: () => { S.offer = null; hideModal(); call("respond_transfer", { id: o.id, accept: false }); } }, "Rechazar"), h("button", { class: "btn primary", onclick: () => { S.offer = null; hideModal(); call("respond_transfer", { id: o.id, accept: true }); } }, "Aceptar"))));
  }
};

// ---- rendering and events ----------------------------------------------------------------------------------

const TABS = [["devices", "Dispositivos"], ["transfers", "Transferencias"], ["settings", "Ajustes"]];

function render() {
  const tabs = document.getElementById("tabs");
  tabs.replaceChildren(...TABS.map(([k, label]) => h("button", { role: "tab", "aria-selected": String(S.tab === k), onclick: () => { S.tab = k; render(); } }, label)));
  if (document.activeElement && document.activeElement.tagName === "INPUT" && S.tab === "settings") return; // do not eat typing
  document.getElementById("view").replaceChildren(...[S.tab === "devices" ? devices() : S.tab === "transfers" ? transfers() : settings()].flat(Infinity));
}

const upsert = (p) => { S.peers = [...S.peers.filter((x) => x.id !== p.id), p].sort((a, b) => Number(b.trusted) - Number(a.trusted) || (a.name || "").localeCompare(b.name || "")); };

function onEvent(e) {
  switch (e.type) {
    case "PeerChanged": upsert(e.peer); render(); break;
    case "PeerGone": S.peers = S.peers.filter((p) => p.id !== e.id); render(); break;
    case "PairRequest": S.pair = e; syncDialogs(); break;
    case "PairFinished":
      S.pair = null; hideModal();
      toast(e.ok ? "Emparejado con " + e.name : e.code === "DECLINED" ? "Emparejamiento cancelado" : e.code === "DECLINED_BY_PEER" ? "El otro dispositivo no aceptó el emparejamiento" : "No se pudo emparejar: " + e.message + ". Comprueba que ambos estén en la misma red.");
      refresh(); break;
    case "TransferOffer": S.offer = e; syncDialogs(); break;
    case "TransferStarted": S.active.set(e.id, { id: e.id, peer_name: e.peer_name, name: e.name, size: e.size, incoming: e.incoming, done: 0, rate: 0, note: "" }); S.tab = "transfers"; render(); break;
    case "TransferProgress": {
      const x = S.active.get(e.id); if (!x) break;
      x.done = e.done; x.rate = e.bytes_per_sec; x.note = "";
      const p = document.getElementById("p-" + e.id), t = document.getElementById("t-" + e.id);
      if (p) p.value = e.done; if (t) t.textContent = progressText(x);
      break;
    }
    case "TransferNote": { const x = S.active.get(e.id); if (x) { x.note = e.message; const t = document.getElementById("t-" + e.id); if (t) t.textContent = e.message; } break; }
    case "TransferFinished": {
      const x = S.active.get(e.id); S.active.delete(e.id);
      const n = x ? x.name : "archivo";
      toast(e.ok ? (x && x.incoming ? "Recibido: " + n : "Enviado: " + n) : e.code === "CANCELLED" ? "Cancelado: " + n : "Falló " + n + ": " + explain(e.code, e.message));
      refresh(); break;
    }
    default: break;
  }
}

async function main() {
  S.name = localStorage.getItem("name") || "";
  const a = localStorage.getItem("auto");
  if (a !== null) S.auto = a === "true";
  await listen("pb-event", (ev) => onEvent(ev.payload));
  if (S.name) call("set_name", { name: S.name });
  call("set_auto_accept", { on: S.auto });
  await refresh();
  setInterval(() => { if (S.tab === "devices" && !S.pair && !S.offer) refresh(); }, 5000);
  // Drop files on a paired device's card (or anywhere if exactly one is connected).
  window.__TAURI__.webview.getCurrentWebview().onDragDropEvent((ev) => {
    const pl = ev.payload;
    const card = pl.position ? document.elementFromPoint(pl.position.x / devicePixelRatio, pl.position.y / devicePixelRatio)?.closest("[data-peer]") : null;
    document.querySelectorAll(".dropping").forEach((c) => c.classList.remove("dropping"));
    if (pl.type === "over" && card) card.classList.add("dropping");
    if (pl.type === "drop") {
      const ready = S.peers.filter((p) => p.trusted && p.state === "Connected");
      const target = card ? card.dataset.peer : ready.length === 1 ? ready[0].id : null;
      if (target) sendPaths(target, pl.paths); else toast("Suelta los archivos sobre un dispositivo conectado.");
    }
  });
}

main();
