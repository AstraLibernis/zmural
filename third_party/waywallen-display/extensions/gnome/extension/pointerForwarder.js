// Snoops pointer events off the stage and pipes them (in global
// compositor pixel coords) to the renderer subprocess's stdin. The
// renderer window is hidden + input-disabled, so it never receives real
// events — the wallpaper would otherwise be inert to the cursor. Events
// are observed non-consuming: the desktop/apps still get them.

import Clutter from 'gi://Clutter';
import GLib from 'gi://GLib';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

const POINTER_POLL_MS = 16;

// Clutter button number → Linux input event code.
const BUTTON_CODE = {
    1: 0x110,  // BTN_LEFT
    2: 0x112,  // BTN_MIDDLE
    3: 0x111,  // BTN_RIGHT
    8: 0x113,  // BTN_SIDE
    9: 0x114,  // BTN_EXTRA
};

export class PointerForwarder {
    constructor() {
        this._launcher = null;
        this._capturedId = 0;
        this._pollId = 0;
        this._monitorsId = 0;
        this._lastPointer = null;
    }

    setLauncher(launcher) {
        this._launcher = launcher;
        this._lastPointer = null;
        this._syncPointer();
    }

    enable() {
        this._capturedId = global.stage.connect('captured-event',
            (_actor, event) => this._onEvent(event));
        // Shell can sample the compositor's pointer even when client windows
        // own input focus and their motion events bypass captured-event.
        this._pollId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, POINTER_POLL_MS, () => {
            this._syncPointer();
            return GLib.SOURCE_CONTINUE;
        });
        this._monitorsId = Main.layoutManager.connect('monitors-changed', () => {
            this._lastPointer = null;
            this._syncPointer();
        });
    }

    disable() {
        if (this._capturedId) {
            global.stage.disconnect(this._capturedId);
            this._capturedId = 0;
        }
        if (this._pollId) {
            GLib.source_remove(this._pollId);
            this._pollId = 0;
        }
        if (this._monitorsId) {
            Main.layoutManager.disconnect(this._monitorsId);
            this._monitorsId = 0;
        }
        this._launcher = null;
        this._lastPointer = null;
    }

    _syncPointer() {
        if (!this._launcher?.running)
            return;
        const [gx, gy] = global.get_pointer();
        const x = gx | 0;
        const y = gy | 0;
        if (this._lastPointer?.[0] === x && this._lastPointer?.[1] === y)
            return;
        this._lastPointer = [x, y];
        this._launcher.writeStdin(`M ${x} ${y} ${GLib.get_monotonic_time()}\n`);
    }

    _onEvent(event) {
        const PROPAGATE = Clutter.EVENT_PROPAGATE;
        if (event.type() === Clutter.EventType.MOTION) {
            this._syncPointer();
            return PROPAGATE;
        }
        if (!this._launcher?.running || Main.overview.visible)
            return PROPAGATE;

        const ts = GLib.get_monotonic_time();
        let line = null;
        switch (event.type()) {
        case Clutter.EventType.BUTTON_PRESS:
        case Clutter.EventType.BUTTON_RELEASE: {
            const code = BUTTON_CODE[event.get_button()];
            if (!code)
                return PROPAGATE;
            const [x, y] = event.get_coords();
            const pressed = event.type() === Clutter.EventType.BUTTON_PRESS ? 1 : 0;
            line = `B ${x | 0} ${y | 0} ${code} ${pressed} ${ts}\n`;
            break;
        }
        case Clutter.EventType.SCROLL: {
            const [dx, dy] = this._scrollDelta(event);
            if (dx === 0 && dy === 0)
                return PROPAGATE;
            const [x, y] = event.get_coords();
            line = `A ${x | 0} ${y | 0} ${dx} ${dy} ${ts}\n`;
            break;
        }
        }
        if (line)
            this._launcher.writeStdin(line);
        return PROPAGATE;
    }

    // Returns [dx, dy] in wheel notches; up = +dy, right = +dx.
    _scrollDelta(event) {
        switch (event.get_scroll_direction()) {
        case Clutter.ScrollDirection.UP:    return [0, 1];
        case Clutter.ScrollDirection.DOWN:  return [0, -1];
        case Clutter.ScrollDirection.LEFT:  return [-1, 0];
        case Clutter.ScrollDirection.RIGHT: return [1, 0];
        case Clutter.ScrollDirection.SMOOTH: {
            const [sx, sy] = event.get_scroll_delta();
            return [sx, -sy];
        }
        default:
            return [0, 0];
        }
    }
}
