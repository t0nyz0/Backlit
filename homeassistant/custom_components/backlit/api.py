"""Small authenticated local client; no tokens are included in errors."""
from typing import Any
from urllib.parse import urlsplit

import aiohttp


class BacklitAuthError(Exception):
    """Pairing key was rejected."""


class BacklitClient:
    def __init__(self, session: aiohttp.ClientSession, host: str, token: str) -> None:
        parsed = urlsplit(host)
        if parsed.scheme not in ("http", "https") or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment or parsed.path not in ("", "/"):
            raise ValueError("Use the Mac's http://hostname:48261 address, without a path or credentials")
        if not token or any(char in token for char in "\r\n"):
            raise ValueError("A valid pairing key is required")
        self.session = session
        self.host = host.rstrip("/")
        self.token = token

    async def request(self, method: str, endpoint: str, payload: dict[str, Any] | None = None) -> dict[str, Any]:
        async with self.session.request(method, self.host + endpoint, headers={"Authorization": "Bearer " + self.token}, json=payload, timeout=aiohttp.ClientTimeout(total=5), allow_redirects=False) as response:
            if response.status in (401, 403):
                raise BacklitAuthError("The Backlit pairing key was rejected")
            if response.status != 200:
                raise ValueError(f"Backlit returned HTTP {response.status}")
            data = await response.json()
            if not isinstance(data, dict) or not isinstance(data.get("id"), str) or not isinstance(data.get("controlling"), bool):
                raise ValueError("The endpoint did not return a valid Backlit state")
            return data

    async def state(self) -> dict[str, Any]:
        return await self.request("GET", "/v1/state")

    async def control(self, **values: Any) -> dict[str, Any]:
        data = await self.request("POST", "/v1/light", values)
        if not data["controlling"]:
            raise ValueError("Backlit is in preview. Enable Control This Mac in the app first")
        return data
