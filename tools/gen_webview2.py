# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 AstraLibernis

"""Generates src/os/webview2.zig from Microsoft's WebView2.h.

The WebView2 SDK (Microsoft.Web.WebView2 on NuGet, BSD-3-Clause) ships
WebView2.h with C vtable layouts for every COM interface. This script copies
the slot order from those layouts, so the Zig bindings can't drift from the
real ABI. Methods whose parameter types it doesn't know become opaque slots:
they keep their place in the vtable but can't be called.

Usage: python tools/gen_webview2.py <path to WebView2.h> > src/os/webview2.zig
       zig fmt src/os/webview2.zig
"""

import re
import sys

# Interfaces zmural calls into (their full vtables, inherited methods included).
CALLED = [
    "ICoreWebView2Environment",
    "ICoreWebView2Controller",
    "ICoreWebView2Controller2",
    "ICoreWebView2",
    "ICoreWebView2_3",
    "ICoreWebView2_4",
    "ICoreWebView2_8",
    "ICoreWebView2Settings",
    "ICoreWebView2WebMessageReceivedEventArgs",
    "ICoreWebView2NavigationCompletedEventArgs",
    "ICoreWebView2NavigationStartingEventArgs",
    "ICoreWebView2ProcessFailedEventArgs",
    "ICoreWebView2NewWindowRequestedEventArgs",
    "ICoreWebView2PermissionRequestedEventArgs",
    "ICoreWebView2DownloadStartingEventArgs",
]

# Interfaces zmural implements (callbacks): only their IIDs are needed.
IMPLEMENTED = [
    "ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler",
    "ICoreWebView2CreateCoreWebView2ControllerCompletedHandler",
    "ICoreWebView2WebMessageReceivedEventHandler",
    "ICoreWebView2NavigationCompletedEventHandler",
    "ICoreWebView2NavigationStartingEventHandler",
    "ICoreWebView2ProcessFailedEventHandler",
    "ICoreWebView2NewWindowRequestedEventHandler",
    "ICoreWebView2PermissionRequestedEventHandler",
    "ICoreWebView2DownloadStartingEventHandler",
    "ICoreWebView2TrySuspendCompletedHandler",
    "ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler",
]

VALUE_TYPES = {
    "HRESULT": "HRESULT",
    "BOOL": "BOOL",
    "UINT32": "u32",
    "INT32": "i32",
    "UINT64": "u64",
    "INT64": "i64",
    "UINT": "u32",
    "ULONG": "u32",
    "double": "f64",
    "HWND": "?HWND",
    "RECT": "RECT",
    "POINT": "POINT",
    "LPCWSTR": "?[*:0]const u16",
    "PCWSTR": "?[*:0]const u16",
    "EventRegistrationToken": "i64",
    "COREWEBVIEW2_COLOR": "Color",
}


def zig_type(ctype, known):
    """Maps one C parameter type to Zig, or None if unknown."""
    t = ctype.replace("const ", "").strip()
    stars = t.count("*")
    base = t.replace("*", "").strip()
    if base == "REFIID" and stars == 0:
        return "*const GUID"
    if base == "void" and stars == 2:
        return "*?*anyopaque"
    if base == "LPWSTR" and stars == 1:
        return "*?[*:0]u16"
    if base in known:
        if stars == 1:
            return "?*" + base
        if stars == 2:
            return "*?*" + base
        return None
    if base.startswith("COREWEBVIEW2_") and base != "COREWEBVIEW2_COLOR":
        # Enums are 32-bit ([v1_enum]).
        return {0: "i32", 1: "*i32"}.get(stars)
    if base.startswith("ICoreWebView2") or base == "IStream":
        # Another interface: passed through untyped.
        return {1: "?*anyopaque", 2: "*?*anyopaque"}.get(stars)
    if base in VALUE_TYPES:
        z = VALUE_TYPES[base]
        if stars == 0:
            return z
        if stars == 1:
            return "*" + z.lstrip("?")
    return None


def vtable(header, name):
    m = re.search(r"typedef struct %sVtbl\s*\{(.*?)\}\s*%sVtbl;" % (name, name), header, re.S)
    if not m:
        sys.exit("no vtable for " + name)
    body = m.group(1)
    methods = []
    for mm in re.finditer(r"\(\s*STDMETHODCALLTYPE\s*\*(\w+)\s*\)\s*\((.*?)\);", body, re.S):
        method, params = mm.group(1), mm.group(2)
        params = re.sub(r"/\*.*?\*/", "", params)
        # SAL annotations (_In_, _COM_Outptr_, ...), not parts of type names.
        params = re.sub(r"(?<![A-Za-z0-9])_[A-Za-z_]+?_(?![A-Za-z0-9])(\([^)]*\))?", "", params)
        parts = [p.strip() for p in params.split(",") if p.strip()]
        methods.append((method, parts[1:]))  # drop `This`
    return methods


def iid(header, name):
    m = re.search(r"IID_%s = \{(0x\w+),(0x\w+),(0x\w+),\{([^}]*)\}\};" % name, header)
    if not m:
        sys.exit("no IID for " + name)
    tail = ", ".join(x.strip() for x in m.group(4).split(","))
    return "GUID{ .Data1 = %s, .Data2 = %s, .Data3 = %s, .Data4 = .{ %s } }" % (
        m.group(1), m.group(2), m.group(3), tail)


def param_name(p):
    name = re.split(r"[\s*]+", p.strip())[-1]
    name = re.sub(r"\W", "", name)
    return "@\"%s\"" % name if name in ("type", "error", "resume", "suspend") else name


def param_type(p):
    name = re.split(r"[\s*]+", p.strip())[-1]
    return p.strip()[: len(p.strip()) - len(name)].strip()


def main():
    header = open(sys.argv[1], encoding="utf-8", errors="replace").read()
    known = set(CALLED)
    out = []
    w = out.append
    w("//! WebView2 COM bindings, generated by tools/gen_webview2.py from")
    w("//! WebView2.h in the Microsoft.Web.WebView2 SDK (Copyright (C) Microsoft")
    w("//! Corporation, BSD-3-Clause; see THIRD_PARTY_NOTICES.md). Do not edit by")
    w("//! hand: regenerate instead. Vtable slot order is copied from the header;")
    w("//! methods with parameter types the generator doesn't know are opaque slots.")
    w("")
    w("const w = @import(\"win32.zig\");")
    w("pub const GUID = w.GUID;")
    w("pub const HRESULT = w.HRESULT;")
    w("pub const BOOL = w.BOOL;")
    w("pub const HWND = w.HWND;")
    w("pub const RECT = w.RECT;")
    w("pub const POINT = w.POINT;")
    w("")
    w("pub const Color = extern struct { A: u8, R: u8, G: u8, B: u8 };")
    w("")
    w("/// `CreateCoreWebView2EnvironmentWithOptions` in WebView2Loader.dll.")
    w("pub const CreateEnvironmentFn = *const fn (browser_folder: ?[*:0]const u16, user_data_folder: ?[*:0]const u16, options: ?*anyopaque, handler: *anyopaque) callconv(.winapi) HRESULT;")
    w("")
    for name in CALLED:
        w("pub const %s = extern struct {" % name)
        w("    vtbl: *const Vtbl,")
        w("")
        w("    pub const iid = %s;" % iid(header, name))
        w("")
        w("    pub const Vtbl = extern struct {")
        for method, params in vtable(header, name):
            types = [zig_type(param_type(p), known) for p in params]
            if any(t is None for t in types):
                w("        %s: ?*const anyopaque, // opaque: %s" % (method, ", ".join(param_type(p) for p in params)))
                continue
            args = "".join(", %s: %s" % (param_name(p), t) for p, t in zip(params, types))
            ret = "u32" if method in ("AddRef", "Release") else "HRESULT"
            w("        %s: *const fn (this: *%s%s) callconv(.winapi) %s," % (method, name, args, ret))
        w("    };")
        w("};")
        w("")
    w("/// IIDs of the callback interfaces zmural implements.")
    w("pub const handler_iid = struct {")
    for name in IMPLEMENTED:
        short = name.replace("ICoreWebView2", "")
        w("    pub const %s = %s;" % (short, iid(header, name)))
    w("};")
    print("\n".join(out))


if __name__ == "__main__":
    main()
