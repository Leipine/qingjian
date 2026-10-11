//! 可选后台守护，仅监看本用户、本会话和本安装目录的 Server。
#define WIN32_LEAN_AND_MEAN
// Windows 子头依赖 windows.h；保持它先于其他平台头。
#include <windows.h>
#include <algorithm>
#include <sddl.h>
#include <shellapi.h>
#include <string>
#include <tlhelp32.h>
#include <vector>
static std::wstring root, userSid, logPath, scope, pausePath;
static DWORD sessionId;
static const wchar_t *installerName =
#ifdef WATCHDOG_TEST
    L"Local\\QingjianWatchdogTestInstaller";
#else
    L"Global\\QingjianInstaller";
#endif
static bool exists(const std::wstring &p) {
  DWORD a = GetFileAttributesW(p.c_str());
  return a != INVALID_FILE_ATTRIBUTES && !(a & FILE_ATTRIBUTE_DIRECTORY);
}
static std::wstring join(const std::wstring &a, const std::wstring &b) {
  return a + L"\\" + b;
}
static bool same(const std::wstring &a, const std::wstring &b) {
  return _wcsicmp(a.c_str(), b.c_str()) == 0;
}
static std::wstring sidOf(HANDLE p) {
  HANDLE token = nullptr;
  if (!OpenProcessToken(p, TOKEN_QUERY, &token))
    return L"";
  DWORD size = 0;
  GetTokenInformation(token, TokenUser, nullptr, 0, &size);
  std::vector<BYTE> data(size);
  std::wstring sid;
  if (size && GetTokenInformation(token, TokenUser, data.data(), size, &size)) {
    LPWSTR value = nullptr;
    if (ConvertSidToStringSidW(
            reinterpret_cast<TOKEN_USER *>(data.data())->User.Sid, &value)) {
      sid = value;
      LocalFree(value);
    }
  }
  CloseHandle(token);
  return sid;
}
static bool installerActive() {
  HANDLE m = OpenMutexW(SYNCHRONIZE, FALSE, installerName);
  if (m) {
    CloseHandle(m);
    return true;
  }
  return GetLastError() == ERROR_ACCESS_DENIED;
}
static bool userPaused() {
  HANDLE f = CreateFileW(pausePath.c_str(), GENERIC_READ,
                         FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                         nullptr, OPEN_EXISTING, 0, nullptr);
  if (f == INVALID_HANDLE_VALUE)
    return false;
  char bytes[8192];
  DWORD count = 0;
  BOOL ok = ReadFile(f, bytes, sizeof(bytes), &count, nullptr);
  CloseHandle(f);
  if (!ok || !count || count == sizeof(bytes))
    return false;
  int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, bytes, count,
                                 nullptr, 0);
  if (!size)
    return false;
  std::wstring value(size, L'\0');
  if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, bytes, count,
                           value.data(), size))
    return false;
  value.erase(std::remove(value.begin(), value.end(), L'\r'), value.end());
  return value == userSid + L"\n" + root + L"\n" ||
         value == userSid + L"\n" + root;
}
static void log(const std::wstring &event, const std::wstring &detail = L"") {
  if (logPath.empty())
    return;
  WIN32_FILE_ATTRIBUTE_DATA a{};
  if (GetFileAttributesExW(logPath.c_str(), GetFileExInfoStandard, &a) &&
      (a.nFileSizeHigh || a.nFileSizeLow > 1024 * 1024)) {
    std::wstring old = logPath + L".1";
    DeleteFileW(old.c_str());
    MoveFileW(logPath.c_str(), old.c_str());
  }
  SYSTEMTIME t{};
  GetLocalTime(&t);
  wchar_t stamp[80];
  swprintf_s(stamp, L"%04u-%02u-%02u %02u:%02u:%02u.%03u ", t.wYear, t.wMonth,
             t.wDay, t.wHour, t.wMinute, t.wSecond, t.wMilliseconds);
  std::wstring line = stamp + event + L" " + detail + L"\r\n";
  int count = WideCharToMultiByte(CP_UTF8, 0, line.c_str(), -1, nullptr, 0,
                                  nullptr, nullptr);
  std::vector<char> bytes(count);
  WideCharToMultiByte(CP_UTF8, 0, line.c_str(), -1, bytes.data(), count,
                      nullptr, nullptr);
  HANDLE f = CreateFileW(logPath.c_str(), FILE_APPEND_DATA,
                         FILE_SHARE_READ | FILE_SHARE_DELETE, nullptr,
                         OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (f != INVALID_HANDLE_VALUE) {
    DWORD written;
    WriteFile(f, bytes.data(), count - 1, &written, nullptr);
    CloseHandle(f);
  }
}
#ifndef WATCHDOG_TEST
static bool registrationMatches(REGSAM view) {
  HKEY key = nullptr;
  if (RegOpenKeyExW(
          HKEY_CLASSES_ROOT,
          L"CLSID\\{4FDCA82D-E923-49BF-9E75-BB906B93B8BB}\\InprocServer32", 0,
          KEY_READ | view, &key) != ERROR_SUCCESS)
    return false;
  wchar_t value[32768] = {};
  DWORD size = sizeof(value), type = 0;
  LONG status = RegQueryValueExW(key, nullptr, nullptr, &type,
                                 reinterpret_cast<BYTE *>(value), &size);
  RegCloseKey(key);
  if (status != ERROR_SUCCESS || type != REG_SZ || size < sizeof(wchar_t) ||
      size > sizeof(value))
    return false;
  value[32767] = 0;
  std::wstring path(value), prefix = root + L"\\";
  if (path.size() <= prefix.size() ||
      _wcsnicmp(path.c_str(), prefix.c_str(), prefix.size()) != 0)
    return false;
  std::wstring name = path.substr(prefix.size());
  return name.find_first_of(L"\\/") == std::wstring::npos &&
         name.rfind(L"qingjian_tsf-", 0) == 0 && name.size() > 4 &&
         same(name.substr(name.size() - 4), L".dll") && exists(path);
}
#endif
static bool activeInstall() {
#ifdef WATCHDOG_TEST
  return exists(join(root, L"test-active.flag"));
#else
  return registrationMatches(KEY_WOW64_64KEY) &&
         registrationMatches(KEY_WOW64_32KEY);
#endif
}
struct Component {
  std::wstring label, name, path, directory, arguments;
  HANDLE process = nullptr;
  DWORD pid = 0;
  ULONGLONG attachedAt = 0, due = 0;
  unsigned failures = 0;
};
static DWORD backoff(Component &c) {
  c.failures = std::min(c.failures + 1, 6u);
  return std::min(1000u << (c.failures - 1), 30000u);
}
// 身份或路径无法确认时，保守拒绝启动另一份引擎。
static HANDLE findOwned(Component &c, bool &conflict) {
  conflict = false;
  HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot == INVALID_HANDLE_VALUE) {
    conflict = true;
    return nullptr;
  }
  PROCESSENTRY32W entry{};
  entry.dwSize = sizeof(entry);
  HANDLE found = nullptr;
  if (Process32FirstW(snapshot, &entry))
    do {
      if (!same(entry.szExeFile, c.name))
        continue;
      DWORD session = 0;
      if (!ProcessIdToSessionId(entry.th32ProcessID, &session)) {
        conflict = true;
        break;
      }
      if (session != sessionId)
        continue;
      HANDLE p = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION,
                             FALSE, entry.th32ProcessID);
      if (!p) {
        conflict = true;
        break;
      }
      wchar_t image[32768];
      DWORD length = 32768;
      if (!QueryFullProcessImageNameW(p, 0, image, &length) ||
          !same(image, c.path) || sidOf(p) != userSid || found) {
        CloseHandle(p);
        conflict = true;
        break;
      }
      found = p;
      c.pid = entry.th32ProcessID;
    } while (Process32NextW(snapshot, &entry));
  CloseHandle(snapshot);
  if (conflict && found) {
    CloseHandle(found);
    found = nullptr;
  }
  return found;
}
static void recover(Component &c) {
  if (c.process || GetTickCount64() < c.due)
    return;
  bool conflict = false;
  HANDLE found = findOwned(c, conflict);
  if (found) {
    c.process = found;
    c.attachedAt = GetTickCount64();
    log(L"已监看", c.label + L" pid=" + std::to_wstring(c.pid));
    return;
  }
  if (conflict) {
    c.due = GetTickCount64() + 30000;
    log(L"身份或路径冲突，暂停恢复", c.label);
    return;
  }
  if (!exists(c.path)) {
    DWORD delay = backoff(c);
    c.due = GetTickCount64() + delay;
    log(L"程序文件缺失", c.label + L" retry_ms=" + std::to_wstring(delay));
    return;
  }
  // 与 TSF 共用启动锁，避免同时拉起两份服务。
  HANDLE lock = CreateMutexW(nullptr, FALSE, L"Local\\QingjianServerLaunch");
  DWORD acquired = lock ? WaitForSingleObject(lock, 0) : WAIT_FAILED;
  if (acquired != WAIT_OBJECT_0 && acquired != WAIT_ABANDONED) {
    if (lock)
      CloseHandle(lock);
    c.due = GetTickCount64() + 1000;
    return;
  }
  if (userPaused() || installerActive() || !activeInstall()) {
    ReleaseMutex(lock);
    CloseHandle(lock);
    return;
  }
  found = findOwned(c, conflict);
  if (found) {
    c.process = found;
    c.attachedAt = GetTickCount64();
  } else if (!conflict) {
    SHELLEXECUTEINFOW s{};
    s.cbSize = sizeof(s);
    s.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_FLAG_NO_UI;
    s.lpVerb = L"open";
    s.lpFile = c.path.c_str();
    s.lpParameters = c.arguments.empty() ? nullptr : c.arguments.c_str();
    s.lpDirectory = c.directory.c_str();
    s.nShow = SW_HIDE;
    if (ShellExecuteExW(&s) && s.hProcess) {
      c.process = s.hProcess;
      c.pid = GetProcessId(c.process);
      c.attachedAt = GetTickCount64();
      log(L"已恢复", c.label + L" pid=" + std::to_wstring(c.pid));
    } else {
      DWORD error = GetLastError(), delay = backoff(c);
      if (s.hProcess)
        CloseHandle(s.hProcess);
      c.due = GetTickCount64() + delay;
      log(L"启动失败", c.label + L" win32=" + std::to_wstring(error) +
                           L" retry_ms=" + std::to_wstring(delay));
    }
  } else
    c.due = GetTickCount64() + 30000;
  ReleaseMutex(lock);
  CloseHandle(lock);
}
// 任务注册只在显式启用/暂停时运行；常驻守护不加载 PowerShell 或词库。
[[maybe_unused]] static int manageTask(const std::wstring &action) {
  wchar_t system[32768];
  UINT length = GetSystemDirectoryW(system, 32768);
  if (!length || length >= 32768)
    return 1;
  std::wstring exe = join(system, L"WindowsPowerShell\\v1.0\\powershell.exe");
  std::wstring script = join(root, L"watchdog-task.ps1");
  if (!exists(script))
    return 1;
  std::wstring arguments =
      L"-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + script +
      L"\" -Action " + action;
  SHELLEXECUTEINFOW run{};
  run.cbSize = sizeof(run);
  run.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_FLAG_NO_UI;
  run.lpVerb = L"open";
  run.lpFile = exe.c_str();
  run.lpParameters = arguments.c_str();
  run.lpDirectory = root.c_str();
  run.nShow = SW_HIDE;
  if (!ShellExecuteExW(&run) || !run.hProcess)
    return 1;
  DWORD code = 1;
  if (WaitForSingleObject(run.hProcess, 30000) == WAIT_OBJECT_0)
    GetExitCodeProcess(run.hProcess, &code);
  CloseHandle(run.hProcess);
  return static_cast<int>(code);
}
static bool interactiveUser() {
  if (sessionId == 0 || userSid == L"S-1-5-18" || userSid == L"S-1-5-19" ||
      userSid == L"S-1-5-20")
    return false;
  wchar_t name[256];
  DWORD needed = 0;
  HWINSTA station = GetProcessWindowStation();
  HDESK desktop = GetThreadDesktop(GetCurrentThreadId());
  if (!station || !desktop ||
      !GetUserObjectInformationW(station, UOI_NAME, name, sizeof(name),
                                 &needed) ||
      !same(name, L"WinSta0"))
    return false;
  return GetUserObjectInformationW(desktop, UOI_NAME, name, sizeof(name),
                                   &needed) &&
         same(name, L"Default");
}
int WINAPI wWinMain(HINSTANCE, HINSTANCE, LPWSTR, int) {
  wchar_t module[32768];
  DWORD length = GetModuleFileNameW(nullptr, module, 32768);
  if (!length || length >= 32768)
    return 1;
  root = std::wstring(module, length);
  root.resize(root.find_last_of(L"\\/"));
  userSid = sidOf(GetCurrentProcess());
  if (userSid.empty() ||
      !ProcessIdToSessionId(GetCurrentProcessId(), &sessionId))
    return 1;
  if (!interactiveUser())
    return 1;
#ifndef WATCHDOG_TEST
  int argc = 0;
  LPWSTR *argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  std::wstring mode = (argv && argc == 2) ? argv[1] : L"";
  if (argv)
    LocalFree(argv);
  if (argc > 2)
    return 1;
  if (!mode.empty()) {
    if (mode == L"--resume")
      return manageTask(L"Resume");
    if (mode == L"--pause")
      return manageTask(L"Pause");
    if (mode == L"--remove-task")
      return manageTask(L"Remove");
    if (mode == L"--maintenance-stop")
      return manageTask(L"MaintenanceStop");
    if (mode == L"--maintenance-resume")
      return manageTask(L"MaintenanceResume");
    return 1;
  }
#endif
  scope = userSid + L"-" + std::to_wstring(sessionId);
#ifdef WATCHDOG_TEST
  scope += L"-test-" + root.substr(root.find_last_of(L"\\/") + 1);
  logPath = join(root, L"watchdog.log");
  pausePath = join(root, L"watchdog-paused.flag");
#else
  wchar_t local[32768];
  DWORD count = GetEnvironmentVariableW(L"LOCALAPPDATA", local, 32768);
  if (!count || count >= 32768)
    return 1;
  std::wstring base = join(local, L"Qingjian");
  CreateDirectoryW(base.c_str(), nullptr);
  pausePath = join(base, L"watchdog-paused.flag");
  base = join(base, L"logs");
  CreateDirectoryW(base.c_str(), nullptr);
  logPath = join(base, L"server-watchdog.log");
#endif
  HANDLE singleton = CreateMutexW(
      nullptr, TRUE, (L"Local\\QingjianServerWatchdog-" + scope).c_str());
  DWORD error = GetLastError();
  if (!singleton || error == ERROR_ALREADY_EXISTS) {
    if (singleton)
      CloseHandle(singleton);
    return 0;
  }
  HANDLE stop =
      CreateEventW(nullptr, TRUE, FALSE,
                   (L"Local\\QingjianServerWatchdogStop-" + scope).c_str());
  if (!stop) {
    CloseHandle(singleton);
    return 1;
  }
  ResetEvent(stop);
  Component components[1];
#ifdef WATCHDOG_TEST

  components[0] = {L"服务", L"test-server.exe", join(root, L"test-server.exe"),
                   root, L""};
#else

  components[0] = {L"服务", L"qingjian-server.exe",
                   join(root, L"qingjian-server.exe"), root, L""};
#endif
  BOOL inJob = FALSE;
  IsProcessInJob(GetCurrentProcess(), nullptr, &inJob);
  log(L"守护启动", L"session=" + std::to_wstring(sessionId) + L" pid=" +
                       std::to_wstring(GetCurrentProcessId()) + L" in_job=" +
                       std::to_wstring(inJob));
  bool running = true;
  while (running) {
    if (WaitForSingleObject(stop, 0) == WAIT_OBJECT_0) {
      log(L"守护停止", L"用户主动停止");
      break;
    }
    if (userPaused()) {
      log(L"守护停止", L"用户暂停标记");
      break;
    }
    if (GetSystemMetrics(SM_SHUTTINGDOWN)) {
      log(L"守护停止", L"系统关机或注销");
      break;
    }
    if (installerActive()) {
      log(L"守护停止", L"安装维护");
      break;
    }
    if (!activeInstall()) {
      log(L"守护停止", L"输入法注册已变化");
      break;
    }
    for (auto &c : components)
      if (c.process && WaitForSingleObject(c.process, 0) == WAIT_OBJECT_0) {
        DWORD code = 0;
        GetExitCodeProcess(c.process, &code);
        ULONGLONG lifetime = GetTickCount64() - c.attachedAt;
        log(L"进程退出", c.label + L" pid=" + std::to_wstring(c.pid) +
                             L" exit_code=" + std::to_wstring(code) +
                             L" observed_ms=" + std::to_wstring(lifetime));
        CloseHandle(c.process);
        c.process = nullptr;
        // 主动停止由命名事件表示；普通零退出也可能来自重复启动，不能据此关闭守护。
        if (lifetime >= 30000)
          c.failures = 0;
        DWORD delay = backoff(c);
        c.due = GetTickCount64() + delay;
        log(L"等待恢复", c.label + L" retry_ms=" + std::to_wstring(delay));
      }
    if (!running)
      break;
    recover(components[0]);
    HANDLE waits[3] = {stop};
    DWORD n = 1;
    for (auto &c : components)
      if (c.process)
        waits[n++] = c.process;
    WaitForMultipleObjects(n, waits, FALSE, 1000);
  }
  for (auto &c : components)
    if (c.process)
      CloseHandle(c.process);
  CloseHandle(stop);
  ReleaseMutex(singleton);
  CloseHandle(singleton);
  return 0;
}
