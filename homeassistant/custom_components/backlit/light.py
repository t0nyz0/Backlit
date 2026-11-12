"""A real brightness-only light with the effects the Mac reports, never RGB."""
from homeassistant.components.light import ATTR_BRIGHTNESS, ATTR_EFFECT, ColorMode, LightEntity, LightEntityFeature
from homeassistant.exceptions import HomeAssistantError
from .entity import BacklitEntity
from .const import DOMAIN


async def async_setup_entry(hass, entry, async_add_entities):
    async_add_entities([BacklitLight(hass.data[DOMAIN][entry.entry_id])])


class BacklitLight(BacklitEntity, LightEntity):
    _attr_name = "Logo"
    _attr_color_mode = ColorMode.BRIGHTNESS
    _attr_supported_color_modes = {ColorMode.BRIGHTNESS}
    _attr_supported_features = LightEntityFeature.EFFECT

    def __init__(self, coordinator):
        super().__init__(coordinator, "logo")

    @property
    def available(self):
        return super().available and self.coordinator.data.get("controlling", False) and not self.coordinator.data.get("paused")

    @property
    def is_on(self):
        return self.coordinator.data["enabled"]

    @property
    def brightness(self):
        return self.coordinator.data["brightness"]

    @property
    def effect(self):
        return self.coordinator.data["effect"]

    @property
    def effect_list(self):
        return self.coordinator.data["effects"]

    async def async_turn_on(self, **kwargs):
        command = {"enabled": True}
        if ATTR_BRIGHTNESS in kwargs:
            command["brightness"] = kwargs[ATTR_BRIGHTNESS]
        if ATTR_EFFECT in kwargs:
            command["effect"] = kwargs[ATTR_EFFECT]
        await self._send(command)

    async def async_turn_off(self, **kwargs):
        await self._send({"enabled": False})

    async def _send(self, command):
        try:
            data = await self.coordinator.client.control(**command)
            self.coordinator.async_set_updated_data(data)
        except Exception as error:
            raise HomeAssistantError("Backlit could not apply the command. Check the app's connection and logo control.") from error
