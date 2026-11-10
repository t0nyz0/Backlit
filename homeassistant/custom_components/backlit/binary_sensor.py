"""Distinguish reachable preview from actual logo ownership."""
from homeassistant.components.binary_sensor import BinarySensorEntity
from .const import DOMAIN
from .entity import BacklitEntity


async def async_setup_entry(hass, entry, async_add_entities):
    coordinator = hass.data[DOMAIN][entry.entry_id]
    async_add_entities([BacklitBinarySensor(coordinator, key, name) for key, name in [("controlling", "Logo control active"), ("charging", "Plugged in")]])


class BacklitBinarySensor(BacklitEntity, BinarySensorEntity):
    def __init__(self, coordinator, key, name):
        super().__init__(coordinator, key)
        self.key = key
        self._attr_name = name

    @property
    def is_on(self):
        return self.coordinator.data.get(self.key, False)
