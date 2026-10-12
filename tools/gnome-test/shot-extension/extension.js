// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

// Test-only: GNOME lets only privileged callers take screenshots, and code
// inside the Shell is privileged. Writes gnome-<n>.png every 3 s.
import GLib from 'gi://GLib';
import Gio from 'gi://Gio';
import Shell from 'gi://Shell';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

export default class TestShot extends Extension {
    enable() {
        this._n = 0;
        this._dir = GLib.getenv('ZMURAL_SHOT_DIR') ?? '/tmp';
        this._id = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 3, () => {
            this._shot();
            return GLib.SOURCE_CONTINUE;
        });
    }

    _shot() {
        const file = Gio.File.new_for_path(`${this._dir}/gnome-${this._n++}.png`);
        const shooter = new Shell.Screenshot();
        // The route GNOME's own screenshot UI takes: the stage as a texture,
        // then encoded to PNG.
        shooter.screenshot_stage_to_content((_o, res) => {
            try {
                const [content, scale] = shooter.screenshot_stage_to_content_finish(res);
                const texture = content.get_texture();
                const stream = file.replace(null, false, Gio.FileCreateFlags.NONE, null);
                Shell.Screenshot.composite_to_stream(texture, 0, 0, -1, -1, scale, null, 0, 0, 1, stream, (_o2, res2) => {
                    try {
                        Shell.Screenshot.composite_to_stream_finish(res2);
                        console.log(`zmural-test-shot: wrote ${file.get_path()} (${texture.get_width()}x${texture.get_height()})`);
                    } catch (e) {
                        console.log(`zmural-test-shot: encode failed: ${e}`);
                    }
                    stream.close(null);
                });
            } catch (e) {
                console.log(`zmural-test-shot: capture failed: ${e}`);
            }
        });
        global.stage.queue_redraw();
    }

    disable() {
        GLib.source_remove(this._id);
    }
}
