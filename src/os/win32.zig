// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! The Win32 surface zmural uses, declared by hand: only what we call, with
//! our own plain types, and no binding package or std internals.

const std = @import("std");

pub const L = std.unicode.utf8ToUtf16LeStringLiteral;

pub const BOOL = c_int;
pub const UINT = c_uint;
pub const DWORD = u32;
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const LRESULT = isize;
pub const LONG_PTR = isize;
pub const ATOM = u16;
pub const COLORREF = DWORD;

pub const HWND = *opaque {};
pub const HINSTANCE = *opaque {};
pub const HMONITOR = *opaque {};
pub const HDC = *opaque {};
pub const HBRUSH = *opaque {};
pub const HICON = *opaque {};
pub const HCURSOR = *opaque {};
pub const HMENU = *opaque {};
pub const HWINEVENTHOOK = *opaque {};

pub const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
pub const POINT = extern struct { x: i32, y: i32 };

pub const MSG = extern struct {
    hwnd: ?HWND,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: POINT,
};

pub const PAINTSTRUCT = extern struct {
    hdc: ?HDC,
    fErase: BOOL,
    rcPaint: RECT,
    fRestore: BOOL,
    fIncUpdate: BOOL,
    rgbReserved: [32]u8,
};

pub const MONITORINFOEXW = extern struct {
    cbSize: DWORD,
    rcMonitor: RECT,
    rcWork: RECT,
    dwFlags: DWORD,
    szDevice: [32]u16,
};

pub const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;
pub const WNDENUMPROC = *const fn (HWND, LPARAM) callconv(.winapi) BOOL;
pub const MONITORENUMPROC = *const fn (HMONITOR, ?HDC, *RECT, LPARAM) callconv(.winapi) BOOL;
pub const WINEVENTPROC = *const fn (HWINEVENTHOOK, DWORD, ?HWND, i32, i32, DWORD, DWORD) callconv(.winapi) void;
pub const HANDLER_ROUTINE = *const fn (DWORD) callconv(.winapi) BOOL;

pub const WNDCLASSEXW = extern struct {
    cbSize: UINT = @sizeOf(WNDCLASSEXW),
    style: UINT = 0,
    lpfnWndProc: WNDPROC,
    cbClsExtra: c_int = 0,
    cbWndExtra: c_int = 0,
    hInstance: ?HINSTANCE,
    hIcon: ?HICON = null,
    hCursor: ?HCURSOR = null,
    hbrBackground: ?HBRUSH = null,
    lpszMenuName: ?[*:0]const u16 = null,
    lpszClassName: [*:0]const u16,
    hIconSm: ?HICON = null,
};

// Window styles
pub const WS_POPUP: DWORD = 0x80000000;
pub const WS_CHILD: DWORD = 0x40000000;
pub const WS_CLIPSIBLINGS: DWORD = 0x04000000;
pub const WS_OVERLAPPEDWINDOW: DWORD = 0x00CF0000;
pub const WS_EX_TOOLWINDOW: DWORD = 0x00000080;
pub const WS_EX_APPWINDOW: DWORD = 0x00040000;
pub const WS_EX_LAYERED: DWORD = 0x00080000;
pub const WS_EX_NOREDIRECTIONBITMAP: DWORD = 0x00200000;
pub const WS_EX_NOACTIVATE: DWORD = 0x08000000;
pub const GWL_STYLE: c_int = -16;
pub const GWL_EXSTYLE: c_int = -20;
pub const GA_PARENT: UINT = 1;

// SetWindowPos
pub const HWND_BOTTOM: HWND = @ptrFromInt(1);
pub const SWP_NOSIZE: UINT = 0x0001;
pub const SWP_NOMOVE: UINT = 0x0002;
pub const SWP_NOZORDER: UINT = 0x0004;
pub const SWP_NOACTIVATE: UINT = 0x0010;
pub const SWP_FRAMECHANGED: UINT = 0x0020;

pub const SW_SHOWNA: c_int = 8;
pub const LWA_ALPHA: DWORD = 0x2;
pub const SMTO_NORMAL: UINT = 0x0;
pub const MONITORINFOF_PRIMARY: DWORD = 0x1;

// Messages
pub const WM_DESTROY: UINT = 0x0002;
pub const WM_PAINT: UINT = 0x000F;
pub const WM_CLOSE: UINT = 0x0010;
pub const WM_QUERYENDSESSION: UINT = 0x0011;
pub const WM_ENDSESSION: UINT = 0x0016;
pub const WM_ERASEBKGND: UINT = 0x0014;
pub const WM_QUIT: UINT = 0x0012;
pub const WM_DISPLAYCHANGE: UINT = 0x007E;
pub const WM_TIMER: UINT = 0x0113;
pub const WM_APP: UINT = 0x8000;

// WinEvents
pub const EVENT_OBJECT_DESTROY: DWORD = 0x8001;
pub const WINEVENT_OUTOFCONTEXT: DWORD = 0x0000;
pub const OBJID_WINDOW: i32 = 0;

pub const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: isize = -4;

pub extern "user32" fn FindWindowW(class: ?[*:0]const u16, name: ?[*:0]const u16) callconv(.winapi) ?HWND;
pub extern "user32" fn FindWindowExW(parent: ?HWND, after: ?HWND, class: ?[*:0]const u16, name: ?[*:0]const u16) callconv(.winapi) ?HWND;
pub extern "user32" fn SendMessageTimeoutW(hwnd: HWND, msg: UINT, w: WPARAM, l: LPARAM, flags: UINT, timeout_ms: UINT, result: ?*usize) callconv(.winapi) LRESULT;
pub extern "user32" fn EnumWindows(cb: WNDENUMPROC, l: LPARAM) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindowLongPtrW(hwnd: HWND, index: c_int) callconv(.winapi) LONG_PTR;
pub extern "user32" fn SetWindowLongPtrW(hwnd: HWND, index: c_int, value: LONG_PTR) callconv(.winapi) LONG_PTR;
pub extern "user32" fn SetParent(child: HWND, parent: ?HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn GetAncestor(hwnd: HWND, flags: UINT) callconv(.winapi) ?HWND;
pub extern "user32" fn SetWindowPos(hwnd: HWND, after: ?HWND, x: c_int, y: c_int, cx: c_int, cy: c_int, flags: UINT) callconv(.winapi) BOOL;
pub extern "user32" fn MapWindowPoints(from: ?HWND, to: ?HWND, points: [*]POINT, count: UINT) callconv(.winapi) c_int;
pub extern "user32" fn SetLayeredWindowAttributes(hwnd: HWND, key: COLORREF, alpha: u8, flags: DWORD) callconv(.winapi) BOOL;
pub extern "user32" fn EnumDisplayMonitors(hdc: ?HDC, clip: ?*const RECT, cb: MONITORENUMPROC, l: LPARAM) callconv(.winapi) BOOL;
pub extern "user32" fn GetMonitorInfoW(monitor: HMONITOR, info: *MONITORINFOEXW) callconv(.winapi) BOOL;
pub extern "user32" fn RegisterClassExW(class: *const WNDCLASSEXW) callconv(.winapi) ATOM;
pub extern "user32" fn CreateWindowExW(ex_style: DWORD, class: [*:0]const u16, name: ?[*:0]const u16, style: DWORD, x: c_int, y: c_int, w: c_int, h: c_int, parent: ?HWND, menu: ?HMENU, instance: ?HINSTANCE, param: ?*anyopaque) callconv(.winapi) ?HWND;
pub extern "user32" fn DefWindowProcW(hwnd: HWND, msg: UINT, w: WPARAM, l: LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn DestroyWindow(hwnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn IsWindow(hwnd: ?HWND) callconv(.winapi) BOOL;
pub extern "user32" fn ShowWindow(hwnd: HWND, cmd: c_int) callconv(.winapi) BOOL;
pub const PM_REMOVE: UINT = 0x0001;
pub extern "user32" fn PeekMessageW(msg: *MSG, hwnd: ?HWND, min: UINT, max: UINT, remove: UINT) callconv(.winapi) BOOL;
pub extern "user32" fn GetMessageW(msg: *MSG, hwnd: ?HWND, min: UINT, max: UINT) callconv(.winapi) BOOL;
pub extern "user32" fn TranslateMessage(msg: *const MSG) callconv(.winapi) BOOL;
pub extern "user32" fn DispatchMessageW(msg: *const MSG) callconv(.winapi) LRESULT;
pub extern "user32" fn PostQuitMessage(code: c_int) callconv(.winapi) void;
pub extern "user32" fn PostMessageW(hwnd: ?HWND, msg: UINT, w: WPARAM, l: LPARAM) callconv(.winapi) BOOL;
pub extern "user32" fn PostThreadMessageW(thread: DWORD, msg: UINT, w: WPARAM, l: LPARAM) callconv(.winapi) BOOL;
pub extern "user32" fn SetTimer(hwnd: ?HWND, id: usize, ms: UINT, func: ?*const anyopaque) callconv(.winapi) usize;
pub extern "user32" fn KillTimer(hwnd: ?HWND, id: usize) callconv(.winapi) BOOL;
pub const RDW_INVALIDATE: UINT = 0x0001;
pub const RDW_ERASE: UINT = 0x0004;
pub const RDW_ALLCHILDREN: UINT = 0x0080;
pub const RDW_UPDATENOW: UINT = 0x0100;
pub extern "user32" fn RedrawWindow(hwnd: ?HWND, rect: ?*const RECT, region: ?*anyopaque, flags: UINT) callconv(.winapi) BOOL;
pub extern "user32" fn InvalidateRect(hwnd: ?HWND, rect: ?*const RECT, erase: BOOL) callconv(.winapi) BOOL;
pub extern "user32" fn BeginPaint(hwnd: HWND, ps: *PAINTSTRUCT) callconv(.winapi) ?HDC;
pub extern "user32" fn EndPaint(hwnd: HWND, ps: *const PAINTSTRUCT) callconv(.winapi) BOOL;
pub extern "user32" fn GetClientRect(hwnd: HWND, rect: *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn FillRect(hdc: HDC, rect: *const RECT, brush: HBRUSH) callconv(.winapi) c_int;
pub extern "user32" fn RegisterWindowMessageW(name: [*:0]const u16) callconv(.winapi) UINT;
pub extern "user32" fn GetWindowThreadProcessId(hwnd: HWND, pid: ?*DWORD) callconv(.winapi) DWORD;
pub extern "user32" fn SetWinEventHook(min: DWORD, max: DWORD, module: ?HINSTANCE, cb: WINEVENTPROC, pid: DWORD, tid: DWORD, flags: DWORD) callconv(.winapi) ?HWINEVENTHOOK;
pub extern "user32" fn UnhookWinEvent(hook: HWINEVENTHOOK) callconv(.winapi) BOOL;
pub extern "user32" fn SetProcessDpiAwarenessContext(ctx: isize) callconv(.winapi) BOOL;

pub extern "gdi32" fn CreateSolidBrush(color: COLORREF) callconv(.winapi) ?HBRUSH;
pub extern "gdi32" fn DeleteObject(obj: *anyopaque) callconv(.winapi) BOOL;

pub extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) callconv(.winapi) ?HINSTANCE;
pub extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) DWORD;
pub extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
pub extern "kernel32" fn Sleep(ms: DWORD) callconv(.winapi) void;
pub extern "user32" fn MessageBoxW(hwnd: ?HWND, text: [*:0]const u16, caption: [*:0]const u16, kind: UINT) callconv(.winapi) c_int;
pub extern "kernel32" fn SetConsoleCtrlHandler(handler: ?HANDLER_ROUTINE, add: BOOL) callconv(.winapi) BOOL;

// ---- kernel objects: pipes, processes, threads, jobs --------------------------

pub const HANDLE = *anyopaque;
pub const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));

pub const OVERLAPPED = extern struct {
    Internal: usize = 0,
    InternalHigh: usize = 0,
    Offset: DWORD = 0,
    OffsetHigh: DWORD = 0,
    hEvent: ?HANDLE = null,
};

pub const SECURITY_ATTRIBUTES = extern struct {
    nLength: DWORD = @sizeOf(SECURITY_ATTRIBUTES),
    lpSecurityDescriptor: ?*anyopaque = null,
    bInheritHandle: BOOL = 0,
};

pub const STARTUPINFOW = extern struct {
    cb: DWORD = @sizeOf(STARTUPINFOW),
    lpReserved: ?[*:0]u16 = null,
    lpDesktop: ?[*:0]u16 = null,
    lpTitle: ?[*:0]u16 = null,
    dwX: DWORD = 0,
    dwY: DWORD = 0,
    dwXSize: DWORD = 0,
    dwYSize: DWORD = 0,
    dwXCountChars: DWORD = 0,
    dwYCountChars: DWORD = 0,
    dwFillAttribute: DWORD = 0,
    dwFlags: DWORD = 0,
    wShowWindow: u16 = 0,
    cbReserved2: u16 = 0,
    lpReserved2: ?*u8 = null,
    hStdInput: ?HANDLE = null,
    hStdOutput: ?HANDLE = null,
    hStdError: ?HANDLE = null,
};

pub const PROCESS_INFORMATION = extern struct {
    hProcess: HANDLE,
    hThread: HANDLE,
    dwProcessId: DWORD,
    dwThreadId: DWORD,
};

pub const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
    PerProcessUserTimeLimit: i64 = 0,
    PerJobUserTimeLimit: i64 = 0,
    LimitFlags: DWORD = 0,
    MinimumWorkingSetSize: usize = 0,
    MaximumWorkingSetSize: usize = 0,
    ActiveProcessLimit: DWORD = 0,
    Affinity: usize = 0,
    PriorityClass: DWORD = 0,
    SchedulingClass: DWORD = 0,
};

pub const IO_COUNTERS = extern struct {
    ReadOperationCount: u64 = 0,
    WriteOperationCount: u64 = 0,
    OtherOperationCount: u64 = 0,
    ReadTransferCount: u64 = 0,
    WriteTransferCount: u64 = 0,
    OtherTransferCount: u64 = 0,
};

pub const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
    BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION = .{},
    IoInfo: IO_COUNTERS = .{},
    ProcessMemoryLimit: usize = 0,
    JobMemoryLimit: usize = 0,
    PeakProcessMemoryUsed: usize = 0,
    PeakJobMemoryUsed: usize = 0,
};

pub const THREAD_START_ROUTINE = *const fn (?*anyopaque) callconv(.winapi) DWORD;

pub const PIPE_ACCESS_DUPLEX: DWORD = 0x00000003;
pub const FILE_FLAG_FIRST_PIPE_INSTANCE: DWORD = 0x00080000;
pub const FILE_FLAG_OVERLAPPED: DWORD = 0x40000000;
pub const PIPE_TYPE_BYTE: DWORD = 0x0;
pub const PIPE_READMODE_BYTE: DWORD = 0x0;
pub const PIPE_WAIT: DWORD = 0x0;
pub const PIPE_REJECT_REMOTE_CLIENTS: DWORD = 0x8;
pub const GENERIC_READ: DWORD = 0x80000000;
pub const GENERIC_WRITE: DWORD = 0x40000000;
pub const OPEN_EXISTING: DWORD = 3;
/// Client side of a pipe: the server may identify, but not impersonate, us.
pub const SECURITY_SQOS_PRESENT: DWORD = 0x00100000;
pub const SECURITY_IDENTIFICATION: DWORD = 0x00010000;
pub const SDDL_REVISION_1: DWORD = 1;

pub const ERROR_FILE_NOT_FOUND: DWORD = 2;
pub const ERROR_ACCESS_DENIED: DWORD = 5;
pub const ERROR_PIPE_BUSY: DWORD = 231;
pub const PIPE_UNLIMITED_INSTANCES: DWORD = 255;
pub const ERROR_PIPE_CONNECTED: DWORD = 535;
pub const ERROR_IO_PENDING: DWORD = 997;
pub const WAIT_OBJECT_0: DWORD = 0;
pub const WAIT_TIMEOUT: DWORD = 258;
pub const INFINITE: DWORD = 0xFFFFFFFF;

pub const CREATE_SUSPENDED: DWORD = 0x00000004;
pub const CREATE_UNICODE_ENVIRONMENT: DWORD = 0x00000400;
pub const CREATE_NO_WINDOW: DWORD = 0x08000000;
pub const STD_ERROR_HANDLE: DWORD = @bitCast(@as(i32, -12));
pub const STD_OUTPUT_HANDLE: DWORD = @bitCast(@as(i32, -11));
pub const SYNCHRONIZE: DWORD = 0x00100000;
pub const PROCESS_QUERY_LIMITED_INFORMATION: DWORD = 0x1000;
pub const JobObjectExtendedLimitInformation: c_int = 9;
pub const JobObjectBasicUIRestrictions: c_int = 4;
pub const JOBOBJECT_BASIC_UI_RESTRICTIONS = extern struct { UIRestrictionsClass: DWORD = 0 };
pub const JOB_OBJECT_UILIMIT_READCLIPBOARD: DWORD = 0x0002;
pub const JOB_OBJECT_UILIMIT_WRITECLIPBOARD: DWORD = 0x0004;
pub const JOB_OBJECT_UILIMIT_SYSTEMPARAMETERS: DWORD = 0x0008;
pub const JOB_OBJECT_UILIMIT_DISPLAYSETTINGS: DWORD = 0x0010;
pub const JOB_OBJECT_UILIMIT_GLOBALATOMS: DWORD = 0x0020;
pub const JOB_OBJECT_UILIMIT_DESKTOP: DWORD = 0x0040;
pub const JOB_OBJECT_UILIMIT_EXITWINDOWS: DWORD = 0x0080;
pub const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: DWORD = 0x00002000;

pub extern "kernel32" fn CreateNamedPipeW(name: [*:0]const u16, open_mode: DWORD, pipe_mode: DWORD, max_instances: DWORD, out_buffer: DWORD, in_buffer: DWORD, default_timeout_ms: DWORD, sa: ?*SECURITY_ATTRIBUTES) callconv(.winapi) HANDLE;
pub extern "kernel32" fn DisconnectNamedPipe(pipe: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetNamedPipeClientProcessId(pipe: HANDLE, pid: *DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetNamedPipeServerProcessId(pipe: HANDLE, pid: *DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn WaitNamedPipeW(name: [*:0]const u16, timeout_ms: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn ConnectNamedPipe(pipe: HANDLE, ov: ?*OVERLAPPED) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: DWORD, share: DWORD, sa: ?*SECURITY_ATTRIBUTES, disposition: DWORD, flags: DWORD, template: ?HANDLE) callconv(.winapi) HANDLE;
pub extern "kernel32" fn ReadFile(file: HANDLE, buf: [*]u8, len: DWORD, read: ?*DWORD, ov: ?*OVERLAPPED) callconv(.winapi) BOOL;
pub extern "kernel32" fn WriteFile(file: HANDLE, buf: [*]const u8, len: DWORD, written: ?*DWORD, ov: ?*OVERLAPPED) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetOverlappedResult(file: HANDLE, ov: *OVERLAPPED, transferred: *DWORD, wait: BOOL) callconv(.winapi) BOOL;
pub extern "kernel32" fn CancelIoEx(file: HANDLE, ov: ?*OVERLAPPED) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateEventW(sa: ?*SECURITY_ATTRIBUTES, manual_reset: BOOL, initial: BOOL, name: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn CloseHandle(handle: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn WaitForSingleObject(handle: HANDLE, ms: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn WaitForMultipleObjects(count: DWORD, handles: [*]const HANDLE, wait_all: BOOL, ms: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn CreateProcessW(app: ?[*:0]const u16, cmd_line: ?[*:0]u16, psa: ?*SECURITY_ATTRIBUTES, tsa: ?*SECURITY_ATTRIBUTES, inherit: BOOL, flags: DWORD, env: ?*anyopaque, cwd: ?[*:0]const u16, si: *STARTUPINFOW, pi: *PROCESS_INFORMATION) callconv(.winapi) BOOL;
pub extern "kernel32" fn TerminateProcess(process: HANDLE, code: UINT) callconv(.winapi) BOOL;
pub extern "kernel32" fn OpenProcess(access: DWORD, inherit: BOOL, pid: DWORD) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn ResumeThread(thread: HANDLE) callconv(.winapi) DWORD;
pub extern "kernel32" fn CreateThread(sa: ?*SECURITY_ATTRIBUTES, stack: usize, start: THREAD_START_ROUTINE, param: ?*anyopaque, flags: DWORD, tid: ?*DWORD) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn CreateJobObjectW(sa: ?*SECURITY_ATTRIBUTES, name: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn SetInformationJobObject(job: HANDLE, class: c_int, info: *anyopaque, len: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn AssignProcessToJobObject(job: HANDLE, process: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn TerminateJobObject(job: HANDLE, code: UINT) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetModuleFileNameW(module: ?HINSTANCE, buf: [*]u16, len: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn GetStdHandle(which: DWORD) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn GetConsoleWindow() callconv(.winapi) ?HWND;
pub extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;
pub extern "kernel32" fn GetSystemTimeAsFileTime(out: *FILETIME) callconv(.winapi) void;
pub extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
pub const INVALID_FILE_ATTRIBUTES: DWORD = 0xFFFFFFFF;
pub const FILE_ATTRIBUTE_DIRECTORY: DWORD = 0x10;
pub extern "kernel32" fn GetFullPathNameW(name: [*:0]const u16, len: DWORD, buf: [*]u16, file_part: ?*?[*:0]u16) callconv(.winapi) DWORD;
pub extern "kernel32" fn GetFileAttributesW(name: [*:0]const u16) callconv(.winapi) DWORD;
pub extern "kernel32" fn LoadLibraryW(name: [*:0]const u16) callconv(.winapi) ?HINSTANCE;
pub extern "kernel32" fn FreeLibrary(module: HINSTANCE) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetProcAddress(module: HINSTANCE, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
pub extern "kernel32" fn LocalFree(mem: ?*anyopaque) callconv(.winapi) ?*anyopaque;

pub extern "advapi32" fn ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl: [*:0]const u16, revision: DWORD, sd: *?*anyopaque, size: ?*u32) callconv(.winapi) BOOL;

// ---- window facts, power and session (M4) ------------------------------------

pub const SYSTEM_POWER_STATUS = extern struct {
    /// 0 = on battery, 1 = on AC, 255 = unknown.
    ACLineStatus: u8,
    BatteryFlag: u8,
    BatteryLifePercent: u8,
    /// 1 = battery saver on.
    SystemStatusFlag: u8,
    BatteryLifeTime: DWORD,
    BatteryFullLifeTime: DWORD,
};

pub const GA_ROOT: UINT = 2;
pub const WS_EX_TRANSPARENT: DWORD = 0x00000020;
pub const DWMWA_EXTENDED_FRAME_BOUNDS: DWORD = 9;
pub const DWMWA_CLOAKED: DWORD = 14;
pub const SM_REMOTESESSION: c_int = 0x1000;
pub const WM_POWERBROADCAST: UINT = 0x0218;
pub const WM_WTSSESSION_CHANGE: UINT = 0x02B1;
pub const WTS_SESSION_LOCK: WPARAM = 0x7;
pub const WTS_SESSION_UNLOCK: WPARAM = 0x8;
pub const NOTIFY_FOR_THIS_SESSION: DWORD = 0;
/// SHQueryUserNotificationState results that mean "something fullscreen owns the screen".
pub const QUNS_BUSY: c_int = 2;
pub const QUNS_RUNNING_D3D_FULL_SCREEN: c_int = 3;
pub const QUNS_PRESENTATION_MODE: c_int = 4;

pub const EVENT_SYSTEM_FOREGROUND: DWORD = 0x0003;
pub const EVENT_SYSTEM_MOVESIZEEND: DWORD = 0x000B;
pub const EVENT_SYSTEM_MINIMIZESTART: DWORD = 0x0016;
pub const EVENT_SYSTEM_MINIMIZEEND: DWORD = 0x0017;
pub const EVENT_OBJECT_SHOW: DWORD = 0x8002;
pub const EVENT_OBJECT_HIDE: DWORD = 0x8003;
pub const EVENT_OBJECT_LOCATIONCHANGE: DWORD = 0x800B;
pub const EVENT_OBJECT_CLOAKED: DWORD = 0x8017;
pub const EVENT_OBJECT_UNCLOAKED: DWORD = 0x8018;
pub const WINEVENT_SKIPOWNPROCESS: DWORD = 0x0002;
pub const CHILDID_SELF: i32 = 0;

pub extern "user32" fn GetForegroundWindow() callconv(.winapi) ?HWND;
pub extern "user32" fn IsWindowVisible(hwnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn IsIconic(hwnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn IsZoomed(hwnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn GetClassNameW(hwnd: HWND, buf: [*]u16, len: c_int) callconv(.winapi) c_int;
pub extern "user32" fn GetWindowRect(hwnd: HWND, rect: *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn GetSystemMetrics(index: c_int) callconv(.winapi) c_int;
pub extern "dwmapi" fn DwmGetWindowAttribute(hwnd: HWND, attr: DWORD, value: *anyopaque, size: DWORD) callconv(.winapi) i32;
pub extern "kernel32" fn GetSystemPowerStatus(status: *SYSTEM_POWER_STATUS) callconv(.winapi) BOOL;
pub extern "kernel32" fn QueryFullProcessImageNameW(process: HANDLE, flags: DWORD, name: [*]u16, len: *DWORD) callconv(.winapi) BOOL;
pub extern "wtsapi32" fn WTSRegisterSessionNotification(hwnd: HWND, flags: DWORD) callconv(.winapi) BOOL;
pub extern "wtsapi32" fn WTSUnRegisterSessionNotification(hwnd: HWND) callconv(.winapi) BOOL;
pub extern "shell32" fn SHQueryUserNotificationState(state: *c_int) callconv(.winapi) i32;

// ---- tray icon and menus (M5) ----------------------------------------------------

pub const GUID = extern struct { Data1: u32 = 0, Data2: u16 = 0, Data3: u16 = 0, Data4: [8]u8 = @splat(0) };

pub const NOTIFYICONDATAW = extern struct {
    cbSize: DWORD = @sizeOf(NOTIFYICONDATAW),
    hWnd: ?HWND = null,
    uID: UINT = 0,
    uFlags: UINT = 0,
    uCallbackMessage: UINT = 0,
    hIcon: ?HICON = null,
    szTip: [128]u16 = @splat(0),
    dwState: DWORD = 0,
    dwStateMask: DWORD = 0,
    szInfo: [256]u16 = @splat(0),
    uVersion: UINT = 0,
    szInfoTitle: [64]u16 = @splat(0),
    dwInfoFlags: DWORD = 0,
    guidItem: GUID = .{},
    hBalloonIcon: ?HICON = null,
};

comptime {
    // The documented size of the full (Vista+) structure on 64-bit Windows.
    if (@sizeOf(usize) == 8) std.debug.assert(@sizeOf(NOTIFYICONDATAW) == 976);
}

pub const NIM_ADD: DWORD = 0;
pub const NIM_MODIFY: DWORD = 1;
pub const NIM_DELETE: DWORD = 2;
pub const NIM_SETVERSION: DWORD = 4;
pub const NIF_MESSAGE: UINT = 0x01;
pub const NIF_ICON: UINT = 0x02;
pub const NIF_TIP: UINT = 0x04;
pub const NIF_SHOWTIP: UINT = 0x80;
pub const NIF_INFO: UINT = 0x10;
pub const NIIF_WARNING: DWORD = 0x02;
pub const NOTIFYICON_VERSION_4: UINT = 4;
pub const WM_NULL: UINT = 0x0000;
pub const WM_CONTEXTMENU: UINT = 0x007B;
pub const WM_LBUTTONUP: UINT = 0x0202;
pub const WM_USER: UINT = 0x0400;
/// NOTIFYICON_VERSION_4: left click or keyboard selection.
pub const NIN_SELECT: UINT = WM_USER + 0;
pub const NIN_KEYSELECT: UINT = WM_USER + 1;
pub const IDI_APPLICATION: usize = 32512;
pub const MF_STRING: UINT = 0x0000;
pub const MF_GRAYED: UINT = 0x0001;
pub const MF_CHECKED: UINT = 0x0008;
pub const MF_SEPARATOR: UINT = 0x0800;
pub const TPM_RIGHTBUTTON: UINT = 0x0002;
pub const TPM_NONOTIFY: UINT = 0x0080;
pub const TPM_RETURNCMD: UINT = 0x0100;
pub const SW_SHOWNORMAL: c_int = 1;

pub extern "shell32" fn Shell_NotifyIconW(message: DWORD, data: *NOTIFYICONDATAW) callconv(.winapi) BOOL;
pub extern "shell32" fn ShellExecuteW(hwnd: ?HWND, op: ?[*:0]const u16, file: [*:0]const u16, params: ?[*:0]const u16, dir: ?[*:0]const u16, show: c_int) callconv(.winapi) ?HINSTANCE;
pub const IMAGE_ICON: UINT = 1;
pub const SM_CXSMICON: c_int = 49;
pub const SM_CYSMICON: c_int = 50;
pub extern "user32" fn LoadImageW(instance: ?HINSTANCE, name: usize, kind: UINT, cx: c_int, cy: c_int, flags: UINT) callconv(.winapi) ?*anyopaque;
pub extern "user32" fn LoadIconW(instance: ?HINSTANCE, name: usize) callconv(.winapi) ?HICON;
pub extern "user32" fn CreatePopupMenu() callconv(.winapi) ?HMENU;
pub extern "user32" fn AppendMenuW(menu: HMENU, flags: UINT, id: usize, text: ?[*:0]const u16) callconv(.winapi) BOOL;
pub extern "user32" fn TrackPopupMenuEx(menu: HMENU, flags: UINT, x: c_int, y: c_int, hwnd: HWND, params: ?*anyopaque) callconv(.winapi) BOOL;
pub extern "user32" fn DestroyMenu(menu: HMENU) callconv(.winapi) BOOL;
pub extern "user32" fn SetForegroundWindow(hwnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn GetCursorPos(point: *POINT) callconv(.winapi) BOOL;

// ---- log file, console and registry (M5) --------------------------------------------

pub const SYSTEMTIME = extern struct {
    wYear: u16,
    wMonth: u16,
    wDayOfWeek: u16,
    wDay: u16,
    wHour: u16,
    wMinute: u16,
    wSecond: u16,
    wMilliseconds: u16,
};

pub const HKEY = *opaque {};
pub const HKEY_CURRENT_USER: HKEY = @ptrFromInt(0x80000001);
pub const KEY_QUERY_VALUE: DWORD = 0x0001;
pub const KEY_SET_VALUE: DWORD = 0x0002;
pub const REG_SZ: DWORD = 1;
pub const REG_BINARY: DWORD = 3;
pub const REG_DWORD: DWORD = 4;
pub const FILE_APPEND_DATA: DWORD = 0x0004;
pub const FILE_SHARE_READ: DWORD = 0x1;
pub const FILE_SHARE_WRITE: DWORD = 0x2;
pub const FILE_SHARE_DELETE: DWORD = 0x4;
pub const OPEN_ALWAYS: DWORD = 4;
pub const CREATE_ALWAYS: DWORD = 2;
pub const FILE_ATTRIBUTE_NORMAL: DWORD = 0x80;
pub const MOVEFILE_REPLACE_EXISTING: DWORD = 0x1;
pub const ATTACH_PARENT_PROCESS: DWORD = 0xFFFFFFFF;

pub const TOKEN_QUERY: DWORD = 0x0008;
/// TOKEN_INFORMATION_CLASS.TokenUser
pub const TokenUser: c_int = 1;
pub const SID_AND_ATTRIBUTES = extern struct { Sid: *anyopaque, Attributes: DWORD };
pub const TOKEN_USER = extern struct { User: SID_AND_ATTRIBUTES };
pub extern "advapi32" fn OpenProcessToken(process: HANDLE, access: DWORD, token: *HANDLE) callconv(.winapi) BOOL;
pub extern "advapi32" fn GetTokenInformation(token: HANDLE, class: c_int, info: ?*anyopaque, len: DWORD, ret_len: *DWORD) callconv(.winapi) BOOL;
pub extern "advapi32" fn GetLengthSid(sid: *anyopaque) callconv(.winapi) DWORD;
pub extern "advapi32" fn ConvertSidToStringSidW(sid: *anyopaque, text: *?[*:0]u16) callconv(.winapi) BOOL;
pub extern "kernel32" fn ProcessIdToSessionId(pid: DWORD, session: *DWORD) callconv(.winapi) BOOL;
/// The pseudo-handle for the current process.
pub fn GetCurrentProcess() HANDLE {
    return @ptrFromInt(std.math.maxInt(usize));
}
pub const FILETIME = extern struct {
    dwLowDateTime: DWORD,
    dwHighDateTime: DWORD,

    pub fn value(t: FILETIME) u64 {
        return (@as(u64, t.dwHighDateTime) << 32) | t.dwLowDateTime;
    }
};
pub extern "kernel32" fn GetProcessTimes(process: HANDLE, creation: *FILETIME, exit: *FILETIME, kernel: *FILETIME, user: *FILETIME) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetLocalTime(time: *SYSTEMTIME) callconv(.winapi) void;
pub extern "kernel32" fn CreateDirectoryW(path: [*:0]const u16, sa: ?*SECURITY_ATTRIBUTES) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetFileSizeEx(file: HANDLE, size: *i64) callconv(.winapi) BOOL;
pub extern "kernel32" fn MoveFileExW(from: [*:0]const u16, to: [*:0]const u16, flags: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn AttachConsole(pid: DWORD) callconv(.winapi) BOOL;
pub extern "advapi32" fn RegOpenKeyExW(key: HKEY, sub_key: [*:0]const u16, options: DWORD, access: DWORD, result: *HKEY) callconv(.winapi) i32;
pub extern "advapi32" fn RegSetValueExW(key: HKEY, name: [*:0]const u16, reserved: DWORD, kind: DWORD, data: [*]const u8, size: DWORD) callconv(.winapi) i32;
pub extern "advapi32" fn RegQueryValueExW(key: HKEY, name: [*:0]const u16, reserved: ?*DWORD, kind: ?*DWORD, data: ?[*]u8, size: ?*DWORD) callconv(.winapi) i32;
pub extern "advapi32" fn RegDeleteValueW(key: HKEY, name: [*:0]const u16) callconv(.winapi) i32;
pub extern "advapi32" fn RegCloseKey(key: HKEY) callconv(.winapi) i32;
pub extern "advapi32" fn RegCreateKeyExW(key: HKEY, sub_key: [*:0]const u16, reserved: DWORD, class: ?[*:0]u16, options: DWORD, access: DWORD, sa: ?*SECURITY_ATTRIBUTES, result: *HKEY, disposition: ?*DWORD) callconv(.winapi) i32;
pub extern "advapi32" fn RegDeleteKeyW(key: HKEY, sub_key: [*:0]const u16) callconv(.winapi) i32;
pub extern "kernel32" fn DeleteFileW(path: [*:0]const u16) callconv(.winapi) BOOL;

pub const HWND_MESSAGE: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -3))));

pub fn getStyle(hwnd: HWND, index: c_int) DWORD {
    return @truncate(@as(usize, @bitCast(GetWindowLongPtrW(hwnd, index))));
}

pub fn setStyle(hwnd: HWND, index: c_int, style: DWORD) void {
    _ = SetWindowLongPtrW(hwnd, index, @bitCast(@as(usize, style)));
}

pub fn rgb(r: u8, g: u8, b: u8) COLORREF {
    return @as(COLORREF, r) | (@as(COLORREF, g) << 8) | (@as(COLORREF, b) << 16);
}

/// Pointer <-> LPARAM for callbacks that carry context.
pub fn toLparam(ptr: anytype) LPARAM {
    return @bitCast(@intFromPtr(ptr));
}

pub fn fromLparam(comptime T: type, l: LPARAM) *T {
    return @ptrFromInt(@as(usize, @bitCast(l)));
}

// ---- COM (web renderer, M7) ------------------------------------------------------

pub const HRESULT = i32;
pub const S_OK: HRESULT = 0;
pub const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));
pub const COINIT_APARTMENTTHREADED: DWORD = 0x2;
pub const WM_SIZE: UINT = 0x0005;
pub const IID_IUnknown: GUID = .{ .Data1 = 0x00000000, .Data2 = 0x0000, .Data3 = 0x0000, .Data4 = .{ 0xC0, 0, 0, 0, 0, 0, 0, 0x46 } };

pub extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, flags: DWORD) callconv(.winapi) HRESULT;
pub extern "ole32" fn CoTaskMemFree(p: ?*anyopaque) callconv(.winapi) void;
pub extern "shell32" fn SHGetKnownFolderPath(id: *const GUID, flags: DWORD, token: ?HANDLE, path: *?[*:0]u16) callconv(.winapi) HRESULT;
pub const FOLDERID_Videos: GUID = .{ .Data1 = 0x18989B1D, .Data2 = 0x99B5, .Data3 = 0x455B, .Data4 = .{ 0x84, 0x1C, 0xAB, 0x7C, 0x74, 0xE4, 0xDD, 0xFC } };
pub const FOLDERID_Pictures: GUID = .{ .Data1 = 0x33E28130, .Data2 = 0x4E1E, .Data3 = 0x4676, .Data4 = .{ 0x83, 0x5A, 0x98, 0x39, 0x5C, 0x3B, 0xC3, 0xBB } };

/// Where the user's Videos or Pictures folder really is: Windows lets it be
/// moved (OneDrive does, often), so `%USERPROFILE%\Videos` can be wrong.
/// Null if Windows can't say. Caller frees.
pub fn knownFolder(gpa: std.mem.Allocator, id: *const GUID) ?[]u8 {
    var p: ?[*:0]u16 = null;
    const hr = SHGetKnownFolderPath(id, 0, null, &p);
    // Freed whether or not the call worked, as Windows asks.
    defer CoTaskMemFree(p);
    if (!succeeded(hr)) return null;
    const wide = p orelse return null;
    return std.unicode.wtf16LeToWtf8Alloc(gpa, std.mem.span(wide)) catch null;
}

test knownFolder {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const videos = knownFolder(std.testing.allocator, &FOLDERID_Videos) orelse return error.NoVideosFolder;
    defer std.testing.allocator.free(videos);
    try std.testing.expect(std.fs.path.isAbsolute(videos));
}
pub extern "ole32" fn CoUninitialize() callconv(.winapi) void;
pub extern "ole32" fn CoCreateInstance(clsid: *const GUID, outer: ?*anyopaque, ctx: DWORD, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT;
pub const CLSCTX_INPROC_SERVER: DWORD = 0x1;
pub extern "kernel32" fn SetEnvironmentVariableW(name: [*:0]const u16, value: ?[*:0]const u16) callconv(.winapi) BOOL;

pub fn succeeded(hr: HRESULT) bool {
    return hr >= 0;
}

pub fn guidEql(a: *const GUID, b: *const GUID) bool {
    return a.Data1 == b.Data1 and a.Data2 == b.Data2 and a.Data3 == b.Data3 and std.mem.eql(u8, &a.Data4, &b.Data4);
}
