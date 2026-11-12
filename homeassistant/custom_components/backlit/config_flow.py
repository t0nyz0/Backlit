"""Pair a Mac using its locally generated key."""
import aiohttp
import voluptuous as vol
from homeassistant import config_entries
from homeassistant.helpers.aiohttp_client import async_get_clientsession
from homeassistant.helpers import selector

from .api import BacklitAuthError, BacklitClient
from .const import DOMAIN


class BacklitConfigFlow(config_entries.ConfigFlow, domain=DOMAIN):
    VERSION = 1

    async def async_step_user(self, user_input=None):
        errors = {}
        if user_input is not None:
            # Only the address check may report an invalid host. A reachable
            # server that answers badly is a connection problem, not a typo.
            client = None
            try:
                client = BacklitClient(async_get_clientsession(self.hass), user_input["host"], user_input["token"])
            except ValueError:
                errors["base"] = "invalid_host"
            if client is not None:
                try:
                    data = await client.state()
                except BacklitAuthError:
                    errors["base"] = "invalid_auth"
                except (aiohttp.ClientError, TimeoutError, ValueError):
                    errors["base"] = "cannot_connect"
                else:
                    await self.async_set_unique_id(data["id"])
                    self._abort_if_unique_id_configured()
                    return self.async_create_entry(title="Backlit · " + client.host, data=user_input)
        return self.async_show_form(step_id="user", data_schema=vol.Schema({
            vol.Required("host", default=(user_input or {}).get("host", "http://your-mac.local:48261")): str,
            vol.Required("token"): selector.TextSelector(selector.TextSelectorConfig(type=selector.TextSelectorType.PASSWORD)),
        }), errors=errors)

    async def async_step_reauth(self, entry_data):
        return await self.async_step_reauth_confirm()

    async def async_step_reauth_confirm(self, user_input=None):
        errors = {}
        if user_input is not None:
            entry = self._get_reauth_entry()
            try:
                client = BacklitClient(async_get_clientsession(self.hass), entry.data["host"], user_input["token"])
                data = await client.state()
                if data["id"] != entry.unique_id:
                    errors["base"] = "wrong_device"
                else:
                    return self.async_update_reload_and_abort(entry, data_updates=user_input)
            except BacklitAuthError:
                errors["base"] = "invalid_auth"
            except (aiohttp.ClientError, TimeoutError, ValueError):
                errors["base"] = "cannot_connect"
        return self.async_show_form(step_id="reauth_confirm", data_schema=vol.Schema({vol.Required("token"): selector.TextSelector(selector.TextSelectorConfig(type=selector.TextSelectorType.PASSWORD))}), errors=errors)
