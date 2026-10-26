# phonebridge (working name)

Open-source Android ↔ desktop (Windows, Linux) file transfer and phone companion. Direct device-to-device, no account, no cloud.

**Status: pre-alpha, no UI yet.** The Rust core (`core/`) and a test CLI (`cli/`) exist; the app does not.

What works today (see `docs/`):
- Framed control messages with shared test vectors (`protocol/vectors/`).
- Mutual TLS 1.3 with pinning by device id (SHA-256 of the public key), tested PC ↔ Pixel 9a.
- Resumable, integrity-checked file transfer (tested at 1 GiB, including a killed process).

## Develop
```
cargo test                                   # core tests + protocol vectors
py -3 -I protocol/vectors/generate_framing.py   # regenerate vectors (independent of Rust)
```
Android builds need the NDK and `rustup target add aarch64-linux-android`; see `docs/product/Roadmap.md`.

## Docs
Start at `docs/Home.md` (an Obsidian vault). Rules for contributors using Claude Code: `CLAUDE.md`.

## License
Copyright (C) 2026 the phonebridge authors.

Licensed under the GNU General Public License, version 3 or (at your option) any later version. See [`LICENSE`](LICENSE). Rationale: `docs/decisions/ADR-0005-licencia.md`.
