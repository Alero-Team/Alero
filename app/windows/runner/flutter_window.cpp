#include "flutter_window.h"

#include <optional>
#include <shellapi.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  file_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "pb/windows", &flutter::StandardMethodCodec::GetInstance());
  file_channel_->SetMethodCallHandler([](const auto& call, auto result) {
    if (call.method_name() == "startupEnabled" || call.method_name() == "setStartup") {
      constexpr auto key = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
      if (call.method_name() == "startupEnabled") {
        DWORD size = 0;
        result->Success(flutter::EncodableValue(RegGetValueW(HKEY_CURRENT_USER, key, L"Alero", RRF_RT_REG_SZ, nullptr, nullptr, &size) == ERROR_SUCCESS));
        return;
      }
      const auto* enabled = std::get_if<bool>(call.arguments());
      if (!enabled) { result->Error("argument", "Valor no válido"); return; }
      HKEY run = nullptr;
      auto status = RegCreateKeyExW(HKEY_CURRENT_USER, key, 0, nullptr, 0, KEY_SET_VALUE, nullptr, &run, nullptr);
      if (status == ERROR_SUCCESS) {
        if (*enabled) {
          wchar_t path[32768];
          const auto length = GetModuleFileNameW(nullptr, path, 32768);
          if (!length || length >= 32768) status = ERROR_INSUFFICIENT_BUFFER;
          else {
            const auto command = L"\"" + std::wstring(path, length) + L"\"";
            status = RegSetValueExW(run, L"Alero", 0, REG_SZ, reinterpret_cast<const BYTE*>(command.c_str()), static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
          }
        } else {
          status = RegDeleteValueW(run, L"Alero");
          if (status == ERROR_FILE_NOT_FOUND) status = ERROR_SUCCESS;
        }
        RegCloseKey(run);
      }
      if (status == ERROR_SUCCESS) result->Success();
      else result->Error("startup", "Windows no permitió cambiar el inicio de Alero");
      return;
    }
    if (call.method_name() != "openFile") { result->NotImplemented(); return; }
    const auto* path = std::get_if<std::string>(call.arguments());
    if (!path || path->empty()) { result->Error("path", "Archivo no disponible"); return; }
    const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path->data(), static_cast<int>(path->size()), nullptr, 0);
    if (!size) { result->Error("path", "Ruta no válida"); return; }
    std::wstring wide(size, L'\0');
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path->data(), static_cast<int>(path->size()), wide.data(), size);
    const auto opened = reinterpret_cast<INT_PTR>(ShellExecuteW(nullptr, L"open", wide.c_str(), nullptr, nullptr, SW_SHOWNORMAL));
    if (opened <= 32) result->Error("open_file", "No se pudo abrir el archivo");
    else result->Success();
  });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  file_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
