"use strict";
let socket, context, actionType;
const actions = new Set(["toggle", "on", "off", "brightness", "mode"].map(name => "com.t0nyz.backlit." + name));
const brightness = document.getElementById("brightness"), mode = document.getElementById("mode");
const behaviors = new Set(["steady", "breathe", "battery", "music", "agents", "trackpad", "typing"]);
window.connectElgatoStreamDeckSocket = (port, uuid, event, info, actionInfo) => {
    if (!/^\d{1,5}$/.test(String(port)) || Number(port) < 1 || Number(port) > 65535 || event !== "registerPropertyInspector") return;
    let action;
    try { action = JSON.parse(actionInfo); } catch { return; }
    if (!action || typeof action !== "object" || Array.isArray(action)) return;
    if (!actions.has(action.action) || typeof action.context !== "string" || !action.context || action.context.length > 128) return;
    socket?.close();
    context = action.context; actionType = action.action;
    document.getElementById("brightness-row").hidden = action.action !== "com.t0nyz.backlit.brightness";
    document.getElementById("mode-row").hidden = action.action !== "com.t0nyz.backlit.mode";
    show(action.payload?.settings);
    const connection = new WebSocket("ws://127.0.0.1:" + port);
    socket = connection;
    brightness.disabled = mode.disabled = true;
    connection.onopen = () => {
        if (socket !== connection) return;
        connection.send(JSON.stringify({ event, uuid }));
        brightness.disabled = mode.disabled = false;
    };
    connection.onmessage = message => {
        if (socket !== connection) return;
        try {
            const value = JSON.parse(message.data);
            if (value.event === "didReceiveSettings" && value.context === context && value.action === actionType) show(value.payload?.settings);
        } catch { /* Ignore malformed application messages. */ }
    };
};
function show(value) {
    brightness.value = value && typeof value.percentage === "number" && Number.isFinite(value.percentage) && value.percentage >= 0 && value.percentage <= 100 ? value.percentage : 50;
    mode.value = value && behaviors.has(value.mode) ? value.mode : "steady";
}
function save() {
    const percentage = brightness.valueAsNumber;
    if (!Number.isFinite(percentage) || percentage < 0 || percentage > 100 || !behaviors.has(mode.value)) {
        document.getElementById("status").textContent = "Choose brightness from 0 to 100."; return;
    }
    document.getElementById("status").textContent = "";
    if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify({ event: "setSettings", action: actionType, context, payload: { percentage, mode: mode.value } }));
}
brightness.addEventListener("change", save);mode.addEventListener("change", save);
