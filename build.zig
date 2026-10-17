// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

const std = @import("std");
const zon = @import("build.zig.zon");

/// The wallpaper zmural ships with and shows when none is set (tools/wallgen.zig).
const starter_wallpaper_name = "Prism.webm";
const starter_wallpaper = "assets/wallpapers/" ++ starter_wallpaper_name;

/// `-Dtsan`: every tested module built with ThreadSanitizer (see `build`).
var tsan = false;

pub fn build(b: *std.Build) void {
    // `zig build test -Dtsan` runs the unit tests under ThreadSanitizer, which reports data races
    // at run time (the daemon, the settings window and the pipes all use threads). It needs LLVM
    // (the self-hosted x86 backend does not instrument), libc, and an explicit linux-gnu target,
    // whose kernel headers ship with Zig; the native target reads /usr/include, which lacks them.
    tsan = b.option(bool, "tsan", "Build the tests with ThreadSanitizer (Linux x86_64 only)") orelse false;
    const std_target = b.standardTargetOptions(.{});
    const target = if (tsan)
        b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu })
    else
        std_target;
    const optimize = b.standardOptimizeOption(.{});
    const os = target.result.os.tag;

    // Shared library module: wire protocols, core logic, renderer SDK. `@import("zmural")`.
    const zmural = b.addModule("zmural", .{
        .root_source_file = b.path("src/zmural.zig"),
        .target = target,
        .optimize = optimize,
    });
    // The version lives in one place: build.zig.zon.
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", zon.version);
    zmural.addOptions("build_options", build_options);

    // Desktop hosts: the in-process Windows WorkerW host and Linux backend selection.
    const hosts = b.createModule(.{
        .root_source_file = b.path("src/hosts/hosts.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zmural", .module = zmural }},
    });

    // `zig build check` compiles everything without running or installing
    // (for editors and zcanon's background compiler).
    _ = b.step("check", "Compile every module and its tests");
    // `zig build test` runs every module's unit tests.
    const test_step = b.step("test", "Run unit tests");
    const lib_only: []const std.Build.Module.Import = &.{.{ .name = "zmural", .module = zmural }};
    addTests(b, test_step, zmural);
    addTests(b, test_step, hosts);

    // The settings window: shared pages and widgets; Direct2D over Mica on
    // Windows, Cairo and Pango on a Wayland window on Linux. It runs on a
    // thread inside zmural (opened from the tray or by `zmural --settings`).
    const settings = b.createModule(.{
        .root_source_file = b.path("src/settings/window.zig"),
        .target = target,
        .optimize = optimize,
        .imports = lib_only,
    });
    // The icon font (a subset of Fluent UI System Icons, MIT).
    if (os == .linux) settings.addAnonymousImport("icons.ttf", .{ .root_source_file = b.path("assets/fonts/zmural-icons.ttf") });
    if (os == .windows or os == .linux) addTests(b, test_step, settings);

    // The daemon: policy, library, playlists, routing.
    const daemon = addExe(b, test_step, "zmural", "src/daemon/main.zig", target, optimize, &.{
        .{ .name = "zmural", .module = zmural },
        .{ .name = "hosts", .module = hosts },
        .{ .name = "settings", .module = settings },
    });
    // Linux: the tray icon's pixmaps (from tools/icongen.zig),
    // and the app icons it installs for the settings window's launcher.
    if (os == .linux) {
        daemon.root_module.addAnonymousImport("tray.argb", .{ .root_source_file = b.path("assets/icons/tray.argb") });
        for ([_]u32{ 16, 24, 32, 48, 64, 128, 256 }) |px| daemon.root_module.addAnonymousImport(
            b.fmt("icon-{d}.png", .{px}),
            .{ .root_source_file = b.path(b.fmt("assets/icons/hicolor/{d}x{d}/apps/org.zmural.Settings.png", .{ px, px })) },
        );
    }
    // zmural is also the renderers (one process per active wallpaper), the
    // Windows watchdog and the Linux layer-shell host: it starts itself
    // again in another mode (`--renderer`, `--watchdog`, `--layer-shell`).
    // Linux renderers dlopen libgbm, libEGL and libmpv, and the settings
    // window Cairo and Pango, which needs libc's loader.
    if (os == .linux) daemon.root_module.link_libc = true;
    // A build ID ties a released, stripped program to the debugging info
    // kept for it (docs/RELEASING.md).
    const add_build_id = os == .linux;
    // The command line.
    const cli = addExe(b, test_step, "zmural-console", "src/cli/main.zig", target, optimize, lib_only);
    if (add_build_id) for ([_]*std.Build.Step.Compile{ daemon, cli }) |exe| {
        exe.build_id = .fast;
    };

    // Everything but `zmural-console` is a GUI-subsystem program on Windows:
    // no console window at login, and no hidden console host per renderer.
    // The daemon logs to a file; renderers log through their pipe.
    if (os == .windows) daemon.subsystem = .windows;

    if (os == .linux) {
        // Test tool: a scripted virtual mouse for UI tests on wlroots compositors.
        _ = addExe(b, test_step, "zmural-test-input", "tools/wl-input.zig", target, optimize, lib_only);
    }

    // libmpv is loaded at runtime from next to the executables. When a local copy
    // exists (third_party/mpv, git-ignored), install it alongside them.
    if (os == .windows) {
        // Likewise WebView2Loader.dll (third_party/webview2) for web wallpapers.
        for ([_][]const u8{ "third_party/mpv/libmpv-2.dll", "third_party/webview2/WebView2Loader.dll" }) |dll| {
            if (b.root.access(b.graph.io, dll, .{})) |_| {
                b.installBinFile(dll, std.fs.path.basename(dll));
            } else |_| {}
        }
    }

    // The wallpaper zmural ships with, where it looks for it: share/zmural
    // next to bin on Linux, a folder beside the programs on Windows.
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(b.path(starter_wallpaper), if (os == .windows)
        .{ .custom = "bin/wallpapers" }
    else
        .{ .custom = "share/zmural/wallpapers" }, starter_wallpaper_name).step);

    // `zig build package -Doptimize=ReleaseFast -Dtarget=x86_64-windows` (Windows): a ready-to-share
    // folder and zip in zig-out/package, with the licences the bundled
    // libmpv (LGPL-2.1) and WebView2 (BSD-3-Clause) require.
    if (os == .windows) {
        const name = b.fmt("zmural-{s}-windows-x86_64", .{zon.version});
        const dir: std.Build.InstallDir = .{ .custom = b.fmt("package/{s}", .{name}) };
        const package = b.step("package", "Build the Windows release folder and zip (use -Doptimize=ReleaseFast -Dtarget=x86_64-windows)");
        // Windows' own bsdtar writes zips; a GNU tar earlier on PATH (Git Bash) can't.
        const system_root = b.graph.environ_map.get("SystemRoot") orelse "C:\\Windows";
        const zip = b.addSystemCommand(&.{ b.pathJoin(&.{ system_root, "System32", "tar.exe" }), "-a", "-c", "-f" });
        zip.addDirectoryArg2(installPrefix("package"), .{ .suffix = b.fmt("/{s}.zip", .{name}) });
        zip.addArg("-C");
        zip.addDirectoryArg2(installPrefix("package"), .{});
        // Each file by name, not the folder: the folder keeps whatever older
        // builds left in it (once, the exes zmural used to have).
        zip.addArgs(&.{ b.fmt("{s}/zmural.exe", .{name}), b.fmt("{s}/zmural-console.exe", .{name}) });
        // The debugging info (PDBs) stays out of the zip but is kept beside
        // it, per release, to read crash reports with (docs/RELEASING.md).
        const debug_dir: std.Build.InstallDir = .{ .custom = b.fmt("package/debug/{s}", .{name}) };
        for ([_]*std.Build.Step.Compile{ daemon, cli }) |exe| {
            const install = b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = dir }, .pdb_dir = .{ .override = debug_dir } });
            zip.step.dependOn(&install.step);
        }
        const files = [_][2][]const u8{
            .{ "LICENSE", "LICENSE.txt" },
            .{ "THIRD_PARTY_NOTICES.md", "THIRD_PARTY_NOTICES.md" },
            .{ "licenses/LGPL-2.1.txt", "licenses/LGPL-2.1.txt" },
            // The FFmpeg inside libmpv-2.dll is LGPL-3.0.
            .{ "licenses/LGPL-3.0.txt", "licenses/LGPL-3.0.txt" },
            .{ "licenses/Zig-LICENSE.txt", "licenses/Zig-LICENSE.txt" },
            .{ "assets/README-windows.txt", "README.txt" },
            .{ "third_party/mpv/libmpv-2.dll", "libmpv-2.dll" },
            .{ "third_party/mpv/SOURCE.txt", "licenses/libmpv-SOURCE.txt" },
            .{ "licenses/libmpv-credits.txt", "licenses/libmpv-credits.txt" },
            .{ "third_party/webview2/WebView2Loader.dll", "WebView2Loader.dll" },
            .{ "third_party/webview2/LICENSE.txt", "licenses/WebView2-LICENSE.txt" },
            .{ "third_party/webview2/NOTICE.txt", "licenses/WebView2-NOTICE.txt" },
            .{ "third_party/webview2/SOURCE.txt", "licenses/WebView2-SOURCE.txt" },
            .{ starter_wallpaper, "wallpapers/" ++ starter_wallpaper_name },
        };
        for (files) |f| {
            const install = b.addInstallFileWithDir(b.path(f[0]), dir, f[1]);
            zip.step.dependOn(&install.step);
            zip.addArg(b.fmt("{s}/{s}", .{ name, f[1] }));
        }
        // Built for this machine's own CPU, the programs could use
        // instructions (AVX-512, say) other PCs don't have, and crash there.
        if (target.query.isNativeCpu() or target.query.cpu_model == .native) {
            package.dependOn(&b.addFail("build the release for every x86-64 PC, not this one's CPU: zig build package -Doptimize=ReleaseFast -Dtarget=x86_64-windows").step);
        } else package.dependOn(&zip.step);
    }

    // `zig build icon` regenerates assets/zmural.ico from tools/icongen.zig
    // (committed, so normal builds don't depend on it) plus a preview PNG.
    const icongen = b.addExecutable(.{ .name = "icongen", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/icongen.zig"),
        .target = b.graph.host,
        .optimize = .fast,
    }) });
    const gen = b.addRunArtifact(icongen);
    gen.addArg(fromRoot(b, "assets/zmural.ico"));
    gen.addArg(fromRoot(b, "zig-out/icon-preview.png"));
    gen.addArg(fromRoot(b, "assets/icons"));
    b.step("icon", "Regenerate assets/zmural.ico (and zig-out/icon-preview.png)").dependOn(&gen.step);
    addTests(b, test_step, icongen.root_module);

    // `zig build crashcode -- "zmural 0.1.0 linux crash: ..."` turns a crash
    // code a user posted into functions and lines (tools/crashcode.zig).
    const crashcode = b.addExecutable(.{ .name = "crashcode", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/crashcode.zig"),
        .target = b.graph.host,
        .optimize = .debug,
    }) });
    const decode = b.addRunArtifact(crashcode);
    decode.addArg(fromRoot(b, "zig-out/package/debug"));
    decode.addPassthruArgs();
    b.step("crashcode", "Turn a crash code into functions and lines (-- \"zmural 0.1.0 linux crash: ...\")").dependOn(&decode.step);
    addTests(b, test_step, crashcode.root_module);

    // `zig build starter-wallpaper` regenerates assets/wallpapers/Prism.webm,
    // the wallpaper zmural ships with, from tools/wallgen.zig (committed, so
    // normal builds need neither the generator run nor ffmpeg).
    const wallgen = b.addExecutable(.{ .name = "wallgen", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/wallgen.zig"),
        .target = b.graph.host,
        .optimize = .fast,
    }) });
    const encode = b.addSystemCommand(&.{
        "bash",    "-c",
        \\set -o pipefail
        \\"$1" frames | ffmpeg -hide_banner -loglevel error -y -f rawvideo -pix_fmt rgb24 -s 1920x1080 -r 30 -i - \
        \\  -c:v libvpx-vp9 -crf 20 -b:v 0 -row-mt 1 -deadline good -cpu-used 2 -pix_fmt yuv420p -an "$2"
        ,
        "wallgen",
    });
    encode.addArtifactArg(wallgen);
    encode.addArg(fromRoot(b, starter_wallpaper));
    encode.has_side_effects = true;
    b.step("starter-wallpaper", "Regenerate " ++ starter_wallpaper ++ " (needs ffmpeg with libvpx-vp9)").dependOn(&encode.step);
    addTests(b, test_step, wallgen.root_module);

    var kde_plugin: ?*std.Build.Step = null;
    var gnome_extension: ?*std.Build.Step = null;
    // A program built against a library runs only on that version of it or
    // newer, so the plugins that ship are built inside the oldest system that
    // meets what they declare (tools/plugin-root.sh: Debian 13), not on
    // whatever machine makes the release.
    const plugin_root = b.option([]const u8, "plugin-root", "Build the KDE plugin and GNOME extension inside this system root (tools/plugin-root.sh)");
    // CMake reads the plugins' version from Cargo.toml only when it
    // configures, and a reused build folder never configures again: after a
    // version bump the plugins would still report the old one.
    const fresh_config =
        \\[ "$src/Cargo.toml" -nt "$work/CMakeCache.txt" ] && rm -rf "$work"
        \\
    ;
    const in_root =
        \\run() { if [ -n "$root" ]; then bwrap --bind "$root" / --dev-bind /dev /dev --proc /proc --tmpfs /tmp --bind "$repo" "$repo" --chdir "$repo" --setenv PATH /usr/bin:/bin --setenv HOME /tmp "$@"; else "$@"; fi; }
        \\
    ;
    // `zig build kde-plugin` (Linux): zmural's KDE Plasma wallpaper plugin,
    // built from the vendored waywallen-display with its CMake (needs cmake,
    // ninja, a C++ compiler and Qt 6 development files), as
    // zig-out/share/zmural/zmural-kde.zip, where zmural looks for it.
    {
        const run = b.addSystemCommand(&.{
            "bash",       "-c",
            "set -e\nsrc=\"$1\"; out=\"$2\"; work=\"$3\"; repo=\"$4\"; root=\"$5\"\n" ++ fresh_config ++ in_root ++
                \\rm -f "$work"/zmural-kde-*-embed.zip # an older version's would match the copy below too
                \\run env BUILD_DIR="$work" bash "$src/scripts/build_kde_embed.sh" > "$work.log" 2>&1 || { tail -20 "$work.log"; exit 1; }
                \\mkdir -p "$(dirname "$out")"
                \\cp "$work"/zmural-kde-*-embed.zip "$out"
            ,
            "kde-plugin",
        });
        run.addArg(fromRoot(b, "third_party/waywallen-display"));
        run.addDirectoryArg2(installPrefix("share/zmural/zmural-kde.zip"), .{});
        // Its own build folder per root: CMake's cache names the compilers it found.
        run.addArg(fromRoot(b, if (plugin_root != null) ".zig-cache/kde-plugin-root" else ".zig-cache/kde-plugin"));
        run.addArg(fromRoot(b, "."));
        run.addArg(plugin_root orelse "");
        run.has_side_effects = true;
        b.step("kde-plugin", "Build zmural's KDE Plasma plugin (zig-out/share/zmural/zmural-kde.zip)").dependOn(&run.step);
        kde_plugin = &run.step;
    }

    // `zig build gnome-extension` (Linux): zmural's GNOME Shell extension,
    // from the vendored waywallen-display (needs cmake, ninja, GTK 4 and
    // GObject introspection development files), as
    // zig-out/share/zmural/zmural-gnome.zip, where zmural looks for it.
    {
        const run = b.addSystemCommand(&.{
            "bash",            "-c",
            "set -e\nsrc=\"$1\"; out=\"$2\"; work=\"$3\"; repo=\"$4\"; root=\"$5\"\n" ++ fresh_config ++ in_root ++
                \\rm -f "$work"/zmural-gnome-*.zip # an older version's would match the copy below too
                \\run env BUILD_DIR="$work" bash "$src/scripts/build_gnome_zip.sh" > "$work.log" 2>&1 || { tail -20 "$work.log"; exit 1; }
                \\mkdir -p "$(dirname "$out")"
                \\cp "$work"/zmural-gnome-*.zip "$out"
            ,
            "gnome-extension",
        });
        run.addArg(fromRoot(b, "third_party/waywallen-display"));
        run.addDirectoryArg2(installPrefix("share/zmural/zmural-gnome.zip"), .{});
        // Its own build folder per root: CMake's cache names the compilers it found.
        run.addArg(fromRoot(b, if (plugin_root != null) ".zig-cache/gnome-extension-root" else ".zig-cache/gnome-extension"));
        run.addArg(fromRoot(b, "."));
        run.addArg(plugin_root orelse "");
        run.has_side_effects = true;
        b.step("gnome-extension", "Build zmural's GNOME Shell extension (zig-out/share/zmural/zmural-gnome.zip)").dependOn(&run.step);
        gnome_extension = &run.step;
    }

    // `zig build package -Doptimize=ReleaseFast -Dtarget=x86_64-linux-gnu.2.36`
    // (Linux): a ready-to-share folder and .tar.gz in zig-out/package, the
    // counterpart of the Windows zip. zmural itself is built against an old
    // glibc (the -Dtarget) so it runs on distros older than this one; the
    // libraries it loads (libmpv, Mesa, Cairo, Pango) are the system's. The
    // KDE plugin and GNOME extension are built inside -Dplugin-root (the
    // oldest system they declare: tools/plugin-root.sh), for the same reason.
    if (os == .linux) {
        const name = b.fmt("zmural-{s}-linux-x86_64", .{zon.version});
        const dir: std.Build.InstallDir = .{ .custom = b.fmt("package/{s}", .{name}) };
        const package = b.step("package", "Build the Linux release folder and .tar.gz (use -Doptimize=ReleaseFast -Dtarget=x86_64-linux-gnu.2.36)");
        if (target.query.glibc_version == null) {
            package.dependOn(&b.addFail("name the oldest glibc the package must run on, so no newer symbol slips in: zig build package -Doptimize=ReleaseFast -Dtarget=x86_64-linux-gnu.2.36 -Dplugin-root=$(tools/plugin-root.sh)").step);
        } else if (plugin_root == null) {
            package.dependOn(&b.addFail("build the KDE plugin and GNOME extension on the oldest system they declare, so they load there and on everything newer: -Dplugin-root=$(tools/plugin-root.sh)").step);
        } else {
            const tar = b.addSystemCommand(&.{ "tar", "--owner=0", "--group=0", "-czf" });
            tar.addDirectoryArg2(installPrefix("package"), .{ .suffix = b.fmt("/{s}.tar.gz", .{name}) });
            // Each file by name, not the folder, which keeps what older builds left.
            tar.addArg("-C");
            tar.addDirectoryArg2(installPrefix("package"), .{});
            tar.addArgs(&.{ b.fmt("{s}/bin/zmural", .{name}), b.fmt("{s}/bin/zmural-console", .{name}) });
            const bin_dir: std.Build.InstallDir = .{ .custom = b.fmt("package/{s}/bin", .{name}) };
            // What ships has no debugging info; it goes to package/debug/<name>
            // instead, matched to its program by build ID, to read crash
            // reports with (docs/RELEASING.md).
            const strip = b.addSystemCommand(&.{
                "bash",  "-c",
                \\set -e
                \\bin="$1"; debug="$2"; mkdir -p "$debug"
                \\for f in zmural zmural-console; do
                \\  objcopy --only-keep-debug "$bin/$f" "$debug/$f.debug"
                \\  objcopy --strip-debug --add-gnu-debuglink="$debug/$f.debug" "$bin/$f"
                \\done
                ,
                "strip",
            });
            strip.addDirectoryArg2(installPrefix(b.fmt("package/{s}/bin", .{name})), .{});
            strip.addDirectoryArg2(installPrefix("package"), .{ .suffix = b.fmt("/debug/{s}", .{name}) });
            strip.has_side_effects = true;
            for ([_]*std.Build.Step.Compile{ daemon, cli }) |exe| {
                const install = b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = bin_dir } });
                strip.step.dependOn(&install.step);
            }
            tar.step.dependOn(&strip.step);
            const files = [_][2][]const u8{
                .{ "LICENSE", "LICENSE.txt" },
                .{ "THIRD_PARTY_NOTICES.md", "THIRD_PARTY_NOTICES.md" },
                .{ "licenses/Zig-LICENSE.txt", "licenses/Zig-LICENSE.txt" },
                // The settings window's icons are embedded in zmural.
                .{ "assets/fonts/FluentSystemIcons-LICENSE.txt", "licenses/FluentSystemIcons-LICENSE.txt" },
                .{ "assets/README-linux.txt", "README.txt" },
                .{ starter_wallpaper, "share/zmural/wallpapers/" ++ starter_wallpaper_name },
            };
            for (files) |f| {
                const install = b.addInstallFileWithDir(b.path(f[0]), dir, f[1]);
                tar.step.dependOn(&install.step);
                tar.addArg(b.fmt("{s}/{s}", .{ name, f[1] }));
            }
            // The plugin and extension, built first into zig-out/share/zmural.
            for ([_]struct { *std.Build.Step, []const u8 }{ .{ kde_plugin.?, "zmural-kde.zip" }, .{ gnome_extension.?, "zmural-gnome.zip" } }) |z| {
                const install = b.addInstallFileWithDir(installPrefix(b.fmt("share/zmural/{s}", .{z[1]})), .{ .custom = b.fmt("package/{s}/share/zmural", .{name}) }, z[1]);
                install.step.dependOn(z[0]);
                tar.step.dependOn(&install.step);
                tar.addArg(b.fmt("{s}/share/zmural/{s}", .{ name, z[1] }));
            }
            package.dependOn(&tar.step);
        }
    }

    // `zig build ww-codec-check -Dwaywallen-display=<checkout>`: compares the
    // Linux display protocol codec with waywallen's own generated C codec.
    if (b.option([]const u8, "waywallen-display", "A waywallen-display checkout, for ww-codec-check")) |ref| {
        const mod = b.createModule(.{
            .root_source_file = b.path("src/protocol/ww_display_check.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ ref, "src/generated" }) });
        mod.addCSourceFile(.{ .file = .{ .cwd_relative = b.pathJoin(&.{ ref, "src/generated/ww_proto.c" }) } });
        const check = b.addTest(.{ .root_module = mod });
        b.step("ww-codec-check", "Cross-check the display codec against waywallen's C codec").dependOn(&b.addRunArtifact(check).step);
    }

    // `zig build run -- <args>` runs the daemon; `zig build cli -- <args>` runs the CLI.
    addRunStep(b, daemon, "run", "Run zmural");
    addRunStep(b, cli, "cli", "Run zmural-console");
}

fn addExe(
    b: *std.Build,
    test_step: *std.Build.Step,
    name: []const u8,
    root: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
    imports: []const std.Build.Module.Import,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    });
    // Every Windows executable carries the icon (resource ID 1), once it exists.
    if (target.result.os.tag == .windows) {
        if (b.root.access(b.graph.io, "assets/zmural.ico", .{})) |_| {
            mod.addWin32ResourceFile(.{ .file = b.path("assets/zmural.rc") });
        } else |_| {}
    }
    const exe = b.addExecutable(.{ .name = name, .root_module = mod });
    b.installArtifact(exe);
    addTests(b, test_step, mod);
    return exe;
}

fn addTests(b: *std.Build, test_step: *std.Build.Step, mod: *std.Build.Module) void {
    // Only modules on the explicit tsan target: build tools compiled for the native host would
    // build libtsan against /usr/include, which fails here.
    const instrument = tsan and mod.resolved_target != null and mod.resolved_target.?.query.abi == .gnu;
    if (instrument) {
        mod.sanitize_thread = true;
        mod.link_libc = true;
    }
    const tests = b.addTest(.{ .root_module = mod, .use_llvm = if (instrument) true else null });
    test_step.dependOn(&b.addRunArtifact(tests).step);
    b.top_level_steps.get("check").?.step.dependOn(&tests.step);
}

fn addRunStep(b: *std.Build, exe: *std.Build.Step.Compile, step_name: []const u8, desc: []const u8) void {
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step(step_name, desc).dependOn(&run.step);
}

/// An absolute path under the build root, for tools that take plain path strings
/// (what b.pathFromRoot gave before Zig 0.17).
fn fromRoot(b: *std.Build, sub: []const u8) []const u8 {
    return b.root.joinString(b.allocator, sub) catch @panic("OOM");
}

/// A path under the install prefix, resolved at make time (the configure phase no
/// longer knows the prefix in Zig 0.17).
fn installPrefix(sub: []const u8) std.Build.LazyPath {
    return .{ .relative = .{ .base = .install_prefix, .sub_path = sub } };
}
