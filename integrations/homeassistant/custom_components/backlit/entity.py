"""Shared device identity."""
from homeassistant.helpers.entity import DeviceInfo
from homeassistant.helpers.update_coordinator import CoordinatorEntity
from .const import DOMAIN


class BacklitEntity(CoordinatorEntity):
    _attr_has_entity_name = True

    def __init__(self, coordinator, key):
        super().__init__(coordinator)
        self._attr_unique_id = coordinator.data["id"] + "_" + key
        self._attr_device_info = DeviceInfo(identifiers={(DOMAIN, coordinator.data["id"])}, name="Backlit", manufacturer="t0nyz", model="MacBook Logo Control", sw_version=coordinator.data.get("version"))
