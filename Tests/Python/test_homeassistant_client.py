"""Exercise the shipped HA HTTP client against a real local HTTP fixture."""
import importlib.util
from pathlib import Path
import unittest

import aiohttp
from aiohttp import web

spec = importlib.util.spec_from_file_location("backlit_api", Path(__file__).parents[2] / "homeassistant/custom_components/backlit/api.py")
api = importlib.util.module_from_spec(spec)
spec.loader.exec_module(api)


class ClientTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.calls = []
        self.state = {"id": "fixture", "controlling": True, "brightness": 120, "effect": "Steady", "enabled": True}

        async def endpoint(request):
            if request.headers.get("Authorization") != "Bearer fixture-key":
                return web.json_response({"error": "unauthorized"}, status=401)
            if request.method == "POST":
                values = await request.json()
                self.calls.append(values)
                self.state.update(values)
            return web.json_response(self.state)

        app = web.Application()
        app.router.add_get("/v1/state", endpoint)
        app.router.add_post("/v1/light", endpoint)
        self.runner = web.AppRunner(app)
        await self.runner.setup()
        site = web.TCPSite(self.runner, "127.0.0.1", 0)
        await site.start()
        self.host = f"http://127.0.0.1:{site._server.sockets[0].getsockname()[1]}"
        self.session = aiohttp.ClientSession()

    async def asyncTearDown(self):
        await self.session.close()
        await self.runner.cleanup()

    async def test_state_and_combined_light_command(self):
        client = api.BacklitClient(self.session, self.host, "fixture-key")
        self.assertEqual((await client.state())["id"], "fixture")
        data = await client.control(enabled=False, brightness=80, effect="Breathe")
        self.assertFalse(data["enabled"])
        self.assertEqual(self.calls, [{"enabled": False, "brightness": 80, "effect": "Breathe"}])

    async def test_bad_key_has_no_control_side_effect(self):
        client = api.BacklitClient(self.session, self.host, "incorrect-key")
        with self.assertRaises(api.BacklitAuthError):
            await client.control(enabled=False)
        self.assertEqual(self.calls, [])

    async def test_preview_is_not_reported_as_physical_control(self):
        self.state["controlling"] = False
        client = api.BacklitClient(self.session, self.host, "fixture-key")
        with self.assertRaisesRegex(ValueError, "preview"):
            await client.control(enabled=False)

    async def test_reject_urls_that_could_disclose_pairing_credentials(self):
        for host in ["http://user:password@localhost:48261", "https://localhost/path", "http://localhost?query=1", "file:///tmp/file", "http://localhost#fragment"]:
            with self.assertRaises(ValueError):
                api.BacklitClient(self.session, host, "fixture-key")
