//! 守护隔离测试的进程，不连接实际输入服务。
#define WIN32_LEAN_AND_MEAN
#include <cstdlib>
#include <string>
#include <windows.h>
int WINAPI wWinMain(HINSTANCE, HINSTANCE, LPWSTR, int) {
  wchar_t module[32768];
  GetModuleFileNameW(nullptr, module, 32768);
  std::wstring path(module),
      directory = path.substr(0, path.find_last_of(L"\\/"));
  std::wstring name = path.substr(path.find_last_of(L"\\/") + 1);
  std::wstring control = directory + L"\\" + name + L".exit",
               startup = directory + L"\\" + name + L".startup-exit";
  for (;;) {
    bool atStart =
        GetFileAttributesW(startup.c_str()) != INVALID_FILE_ATTRIBUTES;
    std::wstring chosen = atStart ? startup : control;
    HANDLE f = CreateFileW(chosen.c_str(), GENERIC_READ, FILE_SHARE_READ,
                           nullptr, OPEN_EXISTING, 0, nullptr);
    if (f != INVALID_HANDLE_VALUE) {
      char value[32] = {};
      DWORD count;
      ReadFile(f, value, 31, &count, nullptr);
      CloseHandle(f);
      if (!atStart)
        DeleteFileW(chosen.c_str());
      ExitProcess(static_cast<DWORD>(atoi(value)));
    }
    Sleep(100);
  }
}
