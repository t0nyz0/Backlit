"use strict";
let socket, context;
const brightness = document.getElementById("brightness"), mode = document.getElementById("mode");
const behaviors = new Set(["steady", "breathe", "battery", "music", "agents", "trackpad", "signals"]);
window.connectElgatoStreamDeckSocket = (port, uuid, event, info, actionInfo) => {
    if (!/^\d{1,5}$/.test(String(port)) || Number(port) < 1 || Number(port) > 65535 || event !== "registerPropertyInspector") return;
    let action;
    try { action = JSON.parse(actionInfo); } catch { return; }
    if (typeof action.action !== "string" || !action.action.startsWith("com.t0nyz.backlit.")) return;
    context = uuid;
    document.getElementById("brightness-row").hidden = action.action !== "com.t0nyz.backlit.brightness";
    document.getElementById("mode-row").hidden = action.action !== "com.t0nyz.backlit.mode";
    show(action.payload?.settings);
    socket = new WebSocket("ws://127.0.0.1:" + port);
    socket.onopen = () => socket.send(JSON.stringify({ event, uuid }));
    socket.onmessage = message => {
        try {
            const value = JSON.parse(message.data);
            if (value.event === "didReceiveSettings" && value.context === context) show(value.payload?.settings);
        } catch { /* Ignore malformed application messages. */ }
    };
};
function show(value) {
    if (value && typeof value.percentage === "number" && Number.isFinite(value.percentage) && value.percentage >= 0 && value.percentage <= 100) brightness.value = value.percentage;
    if (value && behaviors.has(value.mode)) mode.value = value.mode;
}
function save() {
    const percentage = brightness.valueAsNumber;
    if (!Number.isFinite(percentage) || percentage < 0 || percentage > 100 || !behaviors.has(mode.value)) {
        document.getElementById("status").textContent = "Choose brightness from 0 to 100."; return;
    }
    document.getElementById("status").textContent = "";
    if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify({ event: "setSettings", context, payload: { percentage, mode: mode.value } }));
}
brightness.addEventListener("change", save);mode.addEventListener("change", save);
