// Run with: node --test extensions/gnome/tests/wallpaper.test.mjs
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

class Actor {
    handlers = new Map();
    children = new Set();
    nextId = 1;
    disposed = false;
    constructor(...args) { this._init(...args); }
    _init(props) { Object.assign(this, props); }
    connect(name, callback) {
        assert.ok(!this.disposed);
        const id = this.nextId++;
        this.handlers.set(id, {name, callback});
        return id;
    }
    disconnect(id) { assert.ok(this.handlers.delete(id)); }
    add_child(child) { this.children.add(child); child.parent = this; }
    set_style() {}
    ease(props) { assert.ok(!this.disposed); this.opacity = props.opacity; }
    remove_all_transitions() { assert.ok(!this.disposed); }
    destroy() {
        assert.ok(!this.disposed, 'actor destroyed twice');
        this.destroying = true;
        for (const [id, handler] of [...this.handlers]) {
            if (this.handlers.has(id) && handler.name === 'destroy')
                handler.callback(this);
        }
        // A class closure override replaces Clutter's default child destruction.
        if (this.on_destroy)
            this.on_destroy();
        else
            for (const child of [...this.children]) child.destroy();
        this.parent?.children.delete(this);
        this.handlers.clear();
        this.disposed = true;
    }
}

function setup() {
    const timers = new Map();
    let nextTimer = 1;
    const windows = [];
    const actors = new Set();
    const GLib = {
        PRIORITY_DEFAULT: 0, SOURCE_REMOVE: false,
        timeout_add(_priority, _delay, callback) {
            const id = nextTimer++;
            timers.set(id, callback);
            return id;
        },
        source_remove(id) { assert.ok(timers.delete(id)); },
    };
    const source = readFileSync(new URL('../extension/wallpaper.js', import.meta.url), 'utf8')
        .replace(/^import .*;\n/gm, '')
        .replace(/^export /gm, '');
    const Wallpaper = vm.runInNewContext(`${source}\n({LiveWallpaper, WallpaperRole, APPLICATION_ID})`, {
        St: {Widget: Actor}, GObject: {registerClass: klass => klass}, GLib,
        Clutter: {Clone: Actor, FixedLayout: class {}, BinLayout: class {}, AnimationMode: {}},
        BlurController: class { setState() {} destroy() {} },
        PauseEffectKind: {BLUR: 'blur'},
        global: {get_window_actors: () => windows.filter(w => !w.disposed),
            display: {get_n_monitors: () => 1}},
    });
    function renderer() {
        const actor = new Actor({meta_window: {
            title: `@${Wallpaper.APPLICATION_ID}!{"presentationReady":true}`,
            get_monitor: () => 0,
        }});
        windows.push(actor);
        return {actor, launcher: {ownsWindow: window => window === actor.meta_window}};
    }
    function wallpaper(launcher, available = true, role = Wallpaper.WallpaperRole.Desktop) {
        const background = new Actor({monitor: 0});
        const content = {brightness: 0.5, vignette: false};
        Object.defineProperty(background, 'content', {get() {
            assert.ok(!background.destroying && !background.disposed, 'read disposing background');
            return content;
        }});
        const actor = new Wallpaper.LiveWallpaper(background, role, available, launcher,
            destroyed => actors.delete(destroyed));
        actors.add(actor);
        return {actor, background, content};
    }
    return {renderer, wallpaper, timers, actors, flush() {
        for (const [id, callback] of [...timers]) {
            timers.delete(id);
            assert.equal(callback(), false);
        }
    }};
}

test('parent destruction unregisters wallpaper and preserves default child destruction', () => {
    const s = setup();
    const r = s.renderer();
    const {actor, background} = s.wallpaper(r.launcher);
    const clone = actor._cloneActor;
    const extraChild = new Actor();
    actor.add_child(extraChild);
    background.destroy();
    assert.equal(s.actors.size, 0);
    assert.ok(actor.disposed && clone.disposed && extraChild.disposed);
    assert.equal(r.actor.handlers.size, 0);
    assert.equal(s.timers.size, 0);
    actor.setRendererAvailable(true);
    actor.setRendererLauncher(null);
    actor.setPresentation(null);
    r.actor.destroy();
});

test('explicit destruction restores backdrop and disconnects background and polling', () => {
    const s = setup();
    const {actor, background, content} = s.wallpaper(null, false);
    assert.equal(content.brightness, 0);
    actor.setRendererAvailable(true);
    assert.equal(s.timers.size, 1);
    const pending = [...s.timers.values()][0];
    actor.destroy();
    assert.equal(s.actors.size, 0);
    assert.equal(s.timers.size, 0);
    assert.equal(background.handlers.size, 0);
    assert.deepEqual(content, {brightness: 0.5, vignette: false});
    pending();
    assert.equal(s.timers.size, 0);
    background.destroy();
});

test('daemon restart attaches only the new renderer even while the old window survives', () => {
    const s = setup();
    let r = s.renderer();
    const {actor, background} = s.wallpaper(r.launcher);
    for (let i = 0; i < 3; i++) {
        const old = r;
        const clone = actor._cloneActor;
        actor.setRendererAvailable(false);
        actor.setRendererLauncher(null);
        assert.ok(clone.disposed);
        assert.equal(old.actor.handlers.size, 0);
        r = s.renderer();
        actor.setRendererLauncher(r.launcher);
        actor.setRendererAvailable(true);
        assert.equal(actor._cloneActor.source, r.actor);
        old.actor.destroy();
        assert.equal(actor._cloneActor.source, r.actor);
    }
    background.destroy();
});

test('source destruction polls for replacement, and parent destruction cancels polling', () => {
    const s = setup();
    const r = s.renderer();
    const {actor, background} = s.wallpaper(r.launcher);
    r.actor.destroy();
    assert.equal(actor._cloneActor, null);
    assert.equal(s.timers.size, 1);
    s.flush();
    assert.equal(s.timers.size, 1);
    background.destroy();
    assert.equal(s.timers.size, 0);
    assert.equal(s.actors.size, 0);
});

test('overview reset restores the backdrop and reconnect dims it again', () => {
    const s = setup();
    const r = s.renderer();
    const {actor, background, content} = s.wallpaper(r.launcher, true, 'other');
    assert.deepEqual(content, {brightness: 0, vignette: true});
    actor.setRendererAvailable(false);
    assert.deepEqual(content, {brightness: 0.5, vignette: false});
    actor.setRendererAvailable(true);
    assert.equal(actor._cloneActor.source, r.actor);
    assert.deepEqual(content, {brightness: 0, vignette: true});
    background.destroy();
});

test('unexpected clone destruction disconnects source before attaching again', () => {
    const s = setup();
    const r = s.renderer();
    const {actor, background} = s.wallpaper(r.launcher);
    actor._cloneActor.destroy();
    assert.equal(r.actor.handlers.size, 0);
    assert.equal(actor._cloneActor, null);
    s.flush();
    assert.equal(actor._cloneActor.source, r.actor);
    assert.equal(r.actor.handlers.size, 1);
    background.destroy();
});

test('launcher replacement cannot retain the previous renderer clone', () => {
    const s = setup();
    const old = s.renderer();
    const {actor, background} = s.wallpaper(old.launcher);
    const clone = actor._cloneActor;
    const next = s.renderer();
    actor.setRendererLauncher(next.launcher);
    assert.ok(clone.disposed);
    assert.equal(old.actor.handlers.size, 0);
    assert.equal(actor._cloneActor.source, next.actor);
    background.destroy();
});
