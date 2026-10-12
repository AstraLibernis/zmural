// Run with: node --test extensions/gnome/tests/pointer.test.mjs
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
    disconnect(id) { assert.ok(this.handlers.delete(id)); }
    emit(name, ...args) {
        for (const handler of this.handlers.values()) {
            if (handler.name === name)
                handler.callback(this, ...args);
        }
    }
}

function setup() {
    const timers = new Map();
    let nextTimer = 1;
    let timestamp = 0;
    let position = [-1800, 100];
    const stage = new Signals();
    const layoutManager = new Signals();
    const Main = {layoutManager, overview: {visible: false}};
    const GLib = {
        PRIORITY_DEFAULT: 0,
        SOURCE_CONTINUE: true,
        timeout_add(_priority, _delay, callback) {
            const id = nextTimer++;
            timers.set(id, callback);
            return id;
        },
        source_remove(id) { assert.ok(timers.delete(id)); },
        get_monotonic_time() { return ++timestamp; },
    };
    const Clutter = {
        EVENT_PROPAGATE: 'propagate',
        EventType: {MOTION: 'motion', BUTTON_PRESS: 'press', BUTTON_RELEASE: 'release', SCROLL: 'scroll'},
        ScrollDirection: {UP: 0, DOWN: 1, LEFT: 2, RIGHT: 3, SMOOTH: 4},
    };
    const forwarderSource = readFileSync(new URL('../extension/pointerForwarder.js', import.meta.url), 'utf8')
        .replace(/^import .*;\n/gm, '')
        .replace('export class PointerForwarder', 'class PointerForwarder');
    const Forwarder = vm.runInNewContext(`${forwarderSource}\nPointerForwarder`, {
        Main, GLib, Clutter, global: {stage, get_pointer: () => position},
    });

    // Exercise the GJS renderer's actual input routing and motion methods
    // without creating GTK windows or starting the application.
    const rendererSource = readFileSync(new URL('../renderer/renderer.js', import.meta.url), 'utf8');
    const classSource = rendererSource.slice(rendererSource.indexOf('class MonitorRenderer'), rendererSource.indexOf('\nconst opts ='));
    const dispatchSource = rendererSource.slice(rendererSource.indexOf('function dispatchInput('), rendererSource.indexOf('function readInputStdin('));
    const renderers = [];
    const {MonitorRenderer, dispatchInput} = vm.runInNewContext(
        `${classSource}\n${dispatchSource}\n({MonitorRenderer, dispatchInput})`,
        {renderers, monitorKey: (_monitor, index) => String(index), logIndexed() {}});
    const writes = [[], []];
    for (const [index, x, scale] of [[0, -1920, 2], [1, 0, 1]]) {
        const monitor = {get_geometry: () => ({x, y: 0, width: 1920, height: 1080})};
        const renderer = new MonitorRenderer(monitor, index, {instanceId: 'test', displayName: 'test'});
        renderer._scale = scale;
        renderer._display = {send_pointer_motion: (px, py) => writes[index].push([px, py])};
        renderers.push(renderer);
    }
    const lines = [];
    const launcher = {running: true, writeStdin(line) {
        lines.push(line);
        dispatchInput(line.trim());
    }};
    const forwarder = new Forwarder();
    forwarder.enable();
    forwarder.setLauncher(launcher);
    return {
        forwarder, launcher, renderers, writes, lines, timers, stage, Main,
        move(x, y) { position = [x, y]; },
        tick() { for (const callback of timers.values()) assert.equal(callback(), true); },
    };
}

test('global sampling tracks client-window motion and monitor leave/re-entry', () => {
    const s = setup();
    assert.deepEqual(s.writes, [[[240, 200]], [[-1, -1]]]);
    s.tick();
    assert.equal(s.lines.length, 1, 'stationary pointer is not repeatedly forwarded');

    // No captured-event is delivered while an application owns the pointer.
    s.move(100, 150);
    s.tick();
    assert.deepEqual(s.writes[0].at(-1), [-1, -1]);
    assert.deepEqual(s.writes[1].at(-1), [100, 150]);
    s.move(110, 150);
    s.tick();
    assert.equal(s.writes[0].length, 2, 'an absent output receives one leave');
    assert.deepEqual(s.writes[1].at(-1), [110, 150]);

    s.move(-1800, 100);
    s.tick();
    assert.deepEqual(s.writes[0].at(-1), [240, 200]);
    assert.deepEqual(s.writes[1].at(-1), [-1, -1]);
    s.move(4000, 100);
    s.tick();
    assert.deepEqual(s.writes[0].at(-1), [-1, -1]);
    s.forwarder.disable();
});

test('binding changes replay pointer presence while stationary', () => {
    const s = setup();
    for (const renderer of s.renderers)
        renderer._onBindingReady(3, 1920, 1080, 0, 0);
    assert.deepEqual(s.writes[0], [[240, 200], [240, 200]]);
    assert.deepEqual(s.writes[1], [[-1, -1], [-1, -1]]);
    for (const renderer of s.renderers)
        renderer._onCompositionConfig();
    assert.equal(s.writes[0].length, 3);
    assert.equal(s.writes[1].length, 3);
    s.forwarder.setLauncher(s.launcher);
    assert.equal(s.lines.length, 2, 'a new launcher receives the current position');
    s.forwarder.disable();
});

test('overview still tracks output crossings and disable cleans up polling', () => {
    const s = setup();
    s.Main.overview.visible = true;
    s.move(0, 100);
    s.tick();
    assert.deepEqual(s.writes[0].at(-1), [-1, -1]);
    assert.deepEqual(s.writes[1].at(-1), [0, 100]);
    s.Main.layoutManager.emit('monitors-changed');
    assert.equal(s.lines.length, 3);
    s.forwarder.disable();
    assert.equal(s.timers.size, 0);
    assert.equal(s.stage.handlers.size, 0);
    assert.equal(s.Main.layoutManager.handlers.size, 0);
});
