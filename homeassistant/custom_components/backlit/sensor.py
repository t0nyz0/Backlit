"""Battery, agent status and session count."""
from homeassistant.components.sensor import SensorEntity, SensorDeviceClass, SensorStateClass
from homeassistant.const import PERCENTAGE
from .const import DOMAIN
from .entity import BacklitEntity


async def async_setup_entry(hass, entry, async_add_entities):
    coordinator = hass.data[DOMAIN][entry.entry_id]
    async_add_entities([BacklitSensor(coordinator, key, name) for key, name in [("battery", "Battery"), ("agent_state", "Agent status"), ("agent_sessions", "Agent sessions")]])


class BacklitSensor(BacklitEntity, SensorEntity):
    def __init__(self, coordinator, key, name):
        super().__init__(coordinator, key)
        self.key = key
        self._attr_name = name
        if key == "battery":
            self._attr_device_class = SensorDeviceClass.BATTERY
            self._attr_native_unit_of_measurement = PERCENTAGE
            self._attr_state_class = SensorStateClass.MEASUREMENT

    @property
    def native_value(self):
        return self.coordinator.data.get(self.key)
