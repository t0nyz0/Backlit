"""Load our real integration into isolated Home Assistant 2026.11.1 Core."""
import asyncio
from pathlib import Path
import shutil
import tempfile
import unittest

from aiohttp import web
from homeassistant.core import HomeAssistant
from homeassistant import loader, config_entries
from homeassistant.bootstrap import async_load_base_functionality
from homeassistant.config_entries import ConfigEntry
from homeassistant.setup import async_setup_component


class CoreIntegrationTests(unittest.IsolatedAsyncioTestCase):
    async def test_entities_light_service_and_preview_unavailability(self):
        state = {"id": "backlit-core-fixture", "version": "0.1.0", "enabled": True, "brightness": 170,
                 "effect": "Steady", "effects": ["Steady", "Breathe", "Battery", "Music", "Agents"],
                 "battery": 82, "charging": False, "agent_state": "waiting", "agent_sessions": 0,
                 "controlling": True, "preview": False, "paused": ""}
        commands = []

        async def endpoint(request):
            if request.headers.get("Authorization") != "Bearer core-fixture-key":
                return web.json_response({}, status=401)
            if request.method == "POST":
                values = await request.json()
                commands.append(values)
                state.update(values)
            return web.json_response(state)

        backend = web.Application()
        backend.router.add_get("/v1/state", endpoint)
        backend.router.add_post("/v1/light", endpoint)
        runner = web.AppRunner(backend)
        await runner.setup()
        site = web.TCPSite(runner, "127.0.0.1", 0)
        await site.start()
        port = site._server.sockets[0].getsockname()[1]
        with tempfile.TemporaryDirectory(prefix="backlit-ha-") as config:
            source = Path(__file__).parents[2] / "homeassistant/custom_components/backlit"
            shutil.copytree(source, Path(config) / "custom_components/backlit")
            hass = HomeAssistant(config)
            loader.async_setup(hass)
            hass.config_entries = config_entries.ConfigEntries(hass, {})
            await async_load_base_functionality(hass)
            try:
                for domain in ["network", "persistent_notification", "light", "sensor", "binary_sensor", "backlit"]:
                    self.assertTrue(await async_setup_component(hass, domain, {}), domain)
                bad = await hass.config_entries.flow.async_init("backlit", context={"source": "user"}, data={"host": f"http://127.0.0.1:{port}", "token": "wrong-key"})
                self.assertEqual(bad["type"], "form")
                self.assertEqual(bad["errors"]["base"], "invalid_auth")
                created = await hass.config_entries.flow.async_init("backlit", context={"source": "user"}, data={"host": f"http://127.0.0.1:{port}", "token": "core-fixture-key"})
                self.assertEqual(created["type"], "create_entry")
                entry = created["result"]
                await hass.async_block_till_done()
                self.assertEqual(entry.state.value, "loaded")
                duplicate = await hass.config_entries.flow.async_init("backlit", context={"source": "user"}, data={"host": f"http://127.0.0.1:{port}", "token": "core-fixture-key"})
                self.assertEqual(duplicate["reason"], "already_configured")
                await hass.async_block_till_done()
                lights = hass.states.async_all("light")
                self.assertEqual(len(lights), 1)
                entity = lights[0].entity_id
                self.assertEqual(hass.states.get(entity).state, "on")
                self.assertEqual(hass.states.get(entity).attributes["brightness"], 170)
                await hass.services.async_call("light", "turn_on", {"entity_id": entity, "brightness": 100, "effect": "Breathe"}, blocking=True)
                self.assertEqual(commands[-1], {"enabled": True, "brightness": 100, "effect": "Breathe"})
                self.assertEqual(len(hass.states.async_all("sensor")), 3)
                self.assertEqual(len(hass.states.async_all("binary_sensor")), 2)
                state["controlling"] = False
                state["preview"] = True
                coordinator = hass.data["backlit"][entry.entry_id]
                await coordinator.async_request_refresh()
                await hass.async_block_till_done()
                self.assertEqual(hass.states.get(entity).state, "unavailable")
                self.assertTrue(await hass.config_entries.async_unload(entry.entry_id))
            finally:
                await hass.async_stop(force=True)
        await runner.cleanup()
