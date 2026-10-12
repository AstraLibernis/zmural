import GLib from 'gi://GLib';

export class WindowExclusions {
    constructor(config) {
        this.generation = config.generation;
        this._applicationIds = new Set(config.applicationIds);
        this._titles = new Set(config.titles);
        this._applicationPatterns = (config.applicationIdPatterns ?? []).map(pattern => new GLib.PatternSpec(pattern));
        this._titlePatterns = (config.titlePatterns ?? []).map(pattern => new GLib.PatternSpec(pattern));
    }

    matches(applicationId, title) {
        return Boolean(
            (applicationId && (this._applicationIds.has(applicationId) ||
                this._applicationPatterns.some(pattern => pattern.match_string(applicationId)))) ||
            (title && (this._titles.has(title) ||
                this._titlePatterns.some(pattern => pattern.match_string(title)))));
    }
}
