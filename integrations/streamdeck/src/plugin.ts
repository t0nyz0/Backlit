import streamDeck, { action, SingletonAction, type KeyDownEvent } from "@elgato/streamdeck";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { linkFor } from "./links.js";

type Settings = { percentage?: number; mode?: string };
const open = promisify(execFile);
let opening = false;

abstract class BacklightAction extends SingletonAction<Settings> {
    abstract readonly command: string;
    override async onKeyDown(event: KeyDownEvent<Settings>): Promise<void> {
        if (opening) { await event.action.showAlert(); return; }
        opening = true;
        try {
            const link = linkFor(this.command, event.payload.settings);
            // No shell, browser, user-supplied executable, pairing token or API listener.
            await open("/usr/bin/open", ["-g", link], { timeout: 2000, maxBuffer: 1024 });
            await event.action.showOk();
        } catch {
            await event.action.showAlert();
        } finally { opening = false; }
    }
}

@action({ UUID: "com.t0nyz.backlit.toggle" })
class ToggleAction extends BacklightAction { override readonly command = "toggle"; }
@action({ UUID: "com.t0nyz.backlit.on" })
class OnAction extends BacklightAction { override readonly command = "on"; }
@action({ UUID: "com.t0nyz.backlit.off" })
class OffAction extends BacklightAction { override readonly command = "off"; }
@action({ UUID: "com.t0nyz.backlit.brightness" })
class BrightnessAction extends BacklightAction { override readonly command = "brightness"; }
@action({ UUID: "com.t0nyz.backlit.mode" })
class ModeAction extends BacklightAction { override readonly command = "mode"; }

streamDeck.actions.registerAction(new ToggleAction());
streamDeck.actions.registerAction(new OnAction());
streamDeck.actions.registerAction(new OffAction());
streamDeck.actions.registerAction(new BrightnessAction());
streamDeck.actions.registerAction(new ModeAction());
streamDeck.connect();
