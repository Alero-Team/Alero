//! Windows version info for alero_daemon.exe, so Task Manager and file properties say "Alero" instead of the
//! bare file name. Compiled with the Windows SDK's rc.exe (already on any MSVC machine): no extra crate.
use std::{env, fs, path::PathBuf, process::Command};

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=../app/pubspec.yaml");
    if env::var("CARGO_CFG_TARGET_ENV").as_deref() != Ok("msvc") {
        return;
    }
    let Some(rc) = find_rc() else {
        println!("cargo:warning=rc.exe not found: alero_daemon.exe is built without version info");
        return;
    };
    let pubspec = fs::read_to_string("../app/pubspec.yaml").unwrap_or_default();
    let v = pubspec
        .lines()
        .find_map(|l| l.strip_prefix("version:"))
        .and_then(|v| v.trim().split('+').next().map(str::to_string))
        .unwrap_or_else(|| "0.0.0".into());
    let n: Vec<u16> = v.split('.').filter_map(|p| p.parse().ok()).chain([0; 4]).take(4).collect();
    let (a, b, c, d) = (n[0], n[1], n[2], n[3]);
    let out = PathBuf::from(env::var("OUT_DIR").unwrap());
    let src = out.join("daemon.rc");
    let res = out.join("daemon.res");
    fs::write(
        &src,
        format!(
            r#"1 VERSIONINFO
FILEVERSION {a},{b},{c},{d}
PRODUCTVERSION {a},{b},{c},{d}
FILEOS 0x40004
FILETYPE 0x1
BEGIN
  BLOCK "StringFileInfo"
  BEGIN
    BLOCK "040904b0"
    BEGIN
      VALUE "CompanyName", "Alero"
      VALUE "FileDescription", "Alero (segundo plano)"
      VALUE "FileVersion", "{v}"
      VALUE "InternalName", "alero_daemon"
      VALUE "LegalCopyright", "Copyright (C) 2026 the Alero authors. GPL-3.0-or-later."
      VALUE "OriginalFilename", "alero_daemon.exe"
      VALUE "ProductName", "Alero"
      VALUE "ProductVersion", "{v}"
    END
  END
  BLOCK "VarFileInfo"
  BEGIN
    VALUE "Translation", 0x409, 1200
  END
END
"#
        ),
    )
    .unwrap();
    let ok = Command::new(&rc).arg("/nologo").arg("/fo").arg(&res).arg(&src).status().is_ok_and(|s| s.success());
    if ok {
        // link.exe takes a compiled .res as a plain input.
        println!("cargo:rustc-link-arg-bins={}", res.display());
    } else {
        println!("cargo:warning=rc.exe failed: alero_daemon.exe is built without version info");
    }
}

/// rc.exe from PATH (a VS developer shell), else the newest Windows 10/11 SDK.
fn find_rc() -> Option<PathBuf> {
    if Command::new("rc.exe").arg("/?").output().is_ok() {
        return Some("rc.exe".into());
    }
    let host = if cfg!(target_arch = "aarch64") { "arm64" } else { "x64" };
    let kits = PathBuf::from(env::var("ProgramFiles(x86)").ok()?).join(r"Windows Kits\10\bin");
    let mut found: Vec<PathBuf> =
        fs::read_dir(kits).ok()?.flatten().map(|e| e.path().join(host).join("rc.exe")).filter(|p| p.exists()).collect();
    found.sort();
    found.pop()
}
