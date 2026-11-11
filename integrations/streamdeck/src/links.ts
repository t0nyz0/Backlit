const behaviors = new Set(["steady", "breathe", "battery", "music", "agents", "trackpad", "typing"]);

/** Only the fixed Backlit vocabulary can reach /usr/bin/open. */
export function linkFor(kind: unknown, value: unknown = {}): string {
    if (value === null || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid settings");
    const settings = value as Record<string, unknown>;
    if (Object.keys(settings).some(key => key !== "percentage" && key !== "mode")) throw new Error("Unknown setting");
    const percentage = settings.percentage === undefined ? 50 : settings.percentage;
    const mode = settings.mode === undefined ? "steady" : settings.mode;
    if (typeof percentage !== "number" || !Number.isFinite(percentage) || percentage < 0 || percentage > 100) throw new Error("Invalid brightness");
    if (typeof mode !== "string" || !behaviors.has(mode)) throw new Error("Invalid behavior");
    switch (kind) {
        case "toggle": return "backlit://toggle";
        case "on": return "backlit://power?state=on";
        case "off": return "backlit://power?state=off";
        case "brightness": return `backlit://brightness?value=${percentage}`;
        case "mode": return `backlit://mode?name=${mode}`;
        default: throw new Error("Unknown action");
    }
}
