import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

class Signals {
    handlers = new Map();
    nextId = 1;
    connect(name, callback) {
        const id = this.nextId++;
        this.handlers.set(id, {name, callback});
        return id;
    }
    connect_after(name, callback) { return this.connect(name, callback); }
    disconnect(id) { assert.ok(this.handlers.delete(id)); }
    emit(name) {
        for (const handler of this.handlers.values()) {
            if (handler.name === name)
                handler.callback();
        }
    }
}

function setup() {
    const timers = new Map();
    let nextTimer = 1;
    const windows = [];
    const geometries = [{x: -1920, y: 0}, {x: 0, y: 0}];
    const global = {
        window_manager: new Signals(),
        display: Object.assign(new Signals(), {
            get_n_monitors: () => geometries.length,
            get_monitor_geometry: index => geometries[index],
        }),
        workspace_manager: Object.assign(new Signals(), {
            get_active_workspace: () => ({list_windows: () => windows}),
        }),
    };
    const Main = {overview: Object.assign(new Signals(), {visible: false}), layoutManager: new Signals()};
    const GLib = {
        PRIORITY_DEFAULT: 0, SOURCE_REMOVE: false,
        timeout_add(_priority, _delay, callback) {
            const id = nextTimer++;
            timers.set(id, callback);
            return id;
        },
        source_remove(id) { timers.delete(id); },
    };
    const source = readFileSync(new URL('../extension/windowState.js', import.meta.url), 'utf8')
        .replace(/^import .*;\n/gm, '')
        .replace('export class WindowStateMonitor', 'class WindowStateMonitor');
    const exclusions = readFileSync(new URL('../extension/windowExclusions.js', import.meta.url), 'utf8')
        .replace(/^import .*;\n/gm, '')
        .replace('export class WindowExclusions', 'class WindowExclusions');
    const Monitor = vm.runInNewContext(`${exclusions}\n${source}\nWindowStateMonitor`, {
        Main, GLib, global, Meta: {WindowType: {NORMAL: 0}}, Wallpaper: {APPLICATION_ID: 'wallpaper'},
    });
    const lines = [];
    const monitor = new Monitor();
    monitor.enable();
    monitor.setLauncher({running: true, writeStdin: line => lines.push(line.trim())});
    return {
        monitor, global, Main, windows, geometries, lines, timers,
        flush() {
            for (const [id, callback] of [...timers]) {
                timers.delete(id);
                assert.equal(callback(), false);
            }
            return lines.splice(0);
        },
    };
}

test('maximized windows and monitor transfers only affect their own output', () => {
    const s = setup();
    let output = 0;
    s.windows.push(Object.assign(new Signals(), {
        showing_on_its_workspace: () => true,
        get_window_type: () => 0,
        get_monitor: () => output,
        has_focus: () => true,
        is_maximized: () => true,
    }));
    assert.deepEqual(s.flush(), ['W -1920 0 7', 'W 0 0 0']);
    // Moving a maximized window may change neither its size nor keyboard focus.
    output = 1;
    s.global.display.emit('window-left-monitor');
    s.global.display.emit('window-entered-monitor');
    assert.deepEqual(s.flush(), ['W -1920 0 0', 'W 0 0 7']);

    s.Main.overview.visible = true;
    s.Main.overview.emit('showing');
    assert.deepEqual(s.flush(), ['W 0 0 0']);
    s.Main.overview.visible = false;
    s.Main.overview.emit('hidden');
    assert.deepEqual(s.flush(), ['W 0 0 7']);
    s.monitor.disable();
    assert.equal(s.global.display.handlers.size, 0);
    assert.equal(s.Main.layoutManager.handlers.size, 0);
    assert.equal(s.timers.size, 0);
});

test('monitor layout changes resend unchanged window flags at the new geometry', () => {
    const s = setup();
    assert.deepEqual(s.flush(), ['W -1920 0 0', 'W 0 0 0']);
    s.geometries[0] = {x: 1920, y: 0};
    s.Main.layoutManager.emit('monitors-changed');
    assert.deepEqual(s.flush(), ['W 1920 0 0', 'W 0 0 0']);
    s.monitor.disable();
});

test('desktop and overview visibility preserve exclusion generations and metadata tracking', () => {
    const s = setup();
    let visible = true;
    let applicationId = 'editor';
    const window = Object.assign(new Signals(), {
        showing_on_its_workspace: () => visible,
        get_window_type: () => 0,
        get_monitor: () => 0,
        has_focus: () => true,
        is_maximized: () => true,
        get_gtk_application_id: () => applicationId,
    });
    s.windows.push(window);
    assert.deepEqual(s.flush(), ['W -1920 0 7', 'W 0 0 0']);
    s.monitor.applyConfig(s.geometries[0], {
        generation: 9, applicationIds: ['ignored'], titles: [],
    });
    assert.deepEqual(s.flush(), ['W -1920 0 7 9', 'W 0 0 0']);

    visible = false;
    s.global.workspace_manager.emit('showing-desktop-changed');
    assert.deepEqual(s.flush(), ['W -1920 0 0 9']);
    visible = true;
    s.global.workspace_manager.emit('showing-desktop-changed');
    assert.deepEqual(s.flush(), ['W -1920 0 7 9']);

    s.Main.overview.visible = true;
    s.Main.overview.emit('showing');
    assert.deepEqual(s.flush(), ['W -1920 0 0 9']);
    assert.equal(window.handlers.size, 3);
    applicationId = 'ignored';
    window.emit('notify::gtk-application-id');
    assert.deepEqual(s.flush(), []);
    s.Main.overview.visible = false;
    s.Main.overview.emit('hidden');
    assert.deepEqual(s.flush(), []);
    applicationId = 'editor';
    window.emit('notify::gtk-application-id');
    assert.deepEqual(s.flush(), ['W -1920 0 7 9']);
    s.monitor.disable();
    assert.equal(window.handlers.size, 0);
});
