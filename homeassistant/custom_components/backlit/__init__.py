"""Expose Backlit as a local Home Assistant light."""
from datetime import timedelta
import aiohttp

from homeassistant.config_entries import ConfigEntry
from homeassistant.const import Platform
from homeassistant.core import HomeAssistant
from homeassistant.exceptions import ConfigEntryAuthFailed
from homeassistant.helpers.aiohttp_client import async_get_clientsession
from homeassistant.helpers.update_coordinator import DataUpdateCoordinator, UpdateFailed

from .api import BacklitAuthError, BacklitClient
from .const import DOMAIN

PLATFORMS = [Platform.LIGHT, Platform.SENSOR, Platform.BINARY_SENSOR]


class BacklitCoordinator(DataUpdateCoordinator):
    def __init__(self, hass: HomeAssistant, entry: ConfigEntry) -> None:
        import logging
        super().__init__(hass, logging.getLogger(__name__), name="Backlit", update_interval=timedelta(seconds=3), config_entry=entry)
        self.client = BacklitClient(async_get_clientsession(hass), entry.data["host"], entry.data["token"])

    async def _async_update_data(self):
        try:
            return await self.client.state()
        except BacklitAuthError as error:
            raise ConfigEntryAuthFailed("Update the pairing key in the Backlit integration") from error
        except (aiohttp.ClientError, TimeoutError, ValueError) as error:
            raise UpdateFailed("Cannot reach Backlit on the Mac") from error


async def async_setup_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    coordinator = BacklitCoordinator(hass, entry)
    await coordinator.async_config_entry_first_refresh()
    hass.data.setdefault(DOMAIN, {})[entry.entry_id] = coordinator
    await hass.config_entries.async_forward_entry_setups(entry, PLATFORMS)
    return True


async def async_unload_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    if unloaded := await hass.config_entries.async_unload_platforms(entry, PLATFORMS):
        hass.data[DOMAIN].pop(entry.entry_id)
    return unloaded
