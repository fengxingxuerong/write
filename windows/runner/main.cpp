#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <wincrypt.h>
#include <string>
#include <vector>

#include "flutter_window.h"
#include "utils.h"

bool ProtectText(const flutter::EncodableValue* arguments,
                 std::vector<uint8_t>* protected_bytes,
                 std::string* error) {
  const auto* map = std::get_if<flutter::EncodableMap>(arguments);
  if (map == nullptr) {
    *error = "protect 参数必须是 Map";
    return false;
  }
  const auto it = map->find(flutter::EncodableValue("plaintext"));
  if (it == map->end()) {
    *error = "protect 缺少 plaintext";
    return false;
  }
  const auto* plaintext = std::get_if<std::string>(&it->second);
  if (plaintext == nullptr) {
    *error = "plaintext 必须是字符串";
    return false;
  }
  DATA_BLOB input{};
  input.pbData = reinterpret_cast<BYTE*>(const_cast<char*>(plaintext->data()));
  input.cbData = static_cast<DWORD>(plaintext->size());
  DATA_BLOB output{};
  if (!CryptProtectData(&input, L"InkSmith API Key", nullptr, nullptr, nullptr,
                         CRYPTPROTECT_UI_FORBIDDEN, &output)) {
    *error = "CryptProtectData failed";
    return false;
  }
  protected_bytes->assign(output.pbData, output.pbData + output.cbData);
  SecureZeroMemory(output.pbData, output.cbData);
  LocalFree(output.pbData);
  return true;
}

bool UnprotectBytes(const flutter::EncodableValue* arguments,
                    std::string* plaintext,
                    std::string* error) {
  const auto* map = std::get_if<flutter::EncodableMap>(arguments);
  if (map == nullptr) {
    *error = "unprotect 参数必须是 Map";
    return false;
  }
  const auto it = map->find(flutter::EncodableValue("data"));
  if (it == map->end()) {
    *error = "unprotect 缺少 data";
    return false;
  }
  const auto* bytes = std::get_if<std::vector<uint8_t>>(&it->second);
  if (bytes == nullptr || bytes->empty()) {
    *error = "data 必须是非空 Uint8List";
    return false;
  }
  DATA_BLOB input{};
  input.pbData = const_cast<BYTE*>(bytes->data());
  input.cbData = static_cast<DWORD>(bytes->size());
  DATA_BLOB output{};
  if (!CryptUnprotectData(&input, nullptr, nullptr, nullptr, nullptr,
                          CRYPTPROTECT_UI_FORBIDDEN, &output)) {
    *error = "CryptUnprotectData failed";
    return false;
  }
  plaintext->assign(reinterpret_cast<const char*>(output.pbData), output.cbData);
  SecureZeroMemory(output.pbData, output.cbData);
  LocalFree(output.pbData);
  return true;
}

void RegisterSecureStorageChannel(flutter::BinaryMessenger* messenger) {
  flutter::MethodChannel<flutter::EncodableValue> channel(
      messenger, "novel_writer/secure_storage",
      &flutter::StandardMethodCodec::GetInstance());
  channel.SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        std::string error;
        if (call.method_name() == "protect") {
          std::vector<uint8_t> bytes;
          if (!ProtectText(call.arguments(), &bytes, &error)) {
            result->Error("protect_failed", error);
            return;
          }
          result->Success(flutter::EncodableValue(std::move(bytes)));
          return;
        }
        if (call.method_name() == "unprotect") {
          std::string plaintext;
          if (!UnprotectBytes(call.arguments(), &plaintext, &error)) {
            result->Error("unprotect_failed", error);
            return;
          }
          result->Success(flutter::EncodableValue(plaintext));
          return;
        }
        result->NotImplemented();
      });
}


int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // 同一 Windows 用户会话只允许一个运行实例，避免两个进程同时改写项目 JSON。
  // Local\ 命名空间不会阻止另一个登录会话使用自己的数据目录。
  HANDLE single_instance = ::CreateMutexW(
      nullptr, TRUE, L"Local\\MoJiangInkSmith_SingleInstance");
  if (single_instance != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    ::CloseHandle(single_instance);
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  // Title uses \u escapes instead of a raw non-ASCII literal: this source file
  // is UTF-8 without BOM, so MSVC would otherwise decode the literal with the
  // system code page and show a mojibake title bar (real bug: it rendered as
  // garbage instead of the brand name). \u58A8\u5320 is the two-character
  // Chinese brand name; keep this line ASCII-only.
  if (!window.Create(L"\u58A8\u5320 InkSmith", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (single_instance != nullptr) {
    ::CloseHandle(single_instance);
  }
  return EXIT_SUCCESS;
}
