#!/usr/bin/env python3
"""Pack native PNG renders into modern ICNS entries without alpha conversion."""
from pathlib import Path
import struct
import sys

# PNG-backed entries are supported well before Backlit's macOS 14 minimum.
# iconutil's legacy 16/32-pixel RGB entries can unpremultiply edge pixels twice.
ENTRIES = (
    (b"icp4", "icon_16x16.png", 16),
    (b"ic11", "icon_16x16@2x.png", 32),
    (b"icp5", "icon_32x32.png", 32),
    (b"ic12", "icon_32x32@2x.png", 64),
    (b"ic07", "icon_128x128.png", 128),
    (b"ic13", "icon_128x128@2x.png", 256),
    (b"ic08", "icon_256x256.png", 256),
    (b"ic14", "icon_256x256@2x.png", 512),
    (b"ic09", "icon_512x512.png", 512),
    (b"ic10", "icon_512x512@2x.png", 1024),
)


def package_icon(source: Path) -> bytes:
    chunks = []
    for kind, name, size in ENTRIES:
        payload = source.joinpath(name).read_bytes()
        if (payload[:8] != b"\x89PNG\r\n\x1a\n" or payload[12:16] != b"IHDR"
                or len(payload) < 33 or struct.unpack(">II", payload[16:24]) != (size, size)):
            raise ValueError(f"Invalid {size}-pixel icon render: {name}")
        chunks.append(struct.pack(">4sI", kind, len(payload) + 8) + payload)
    body = b"".join(chunks)
    return struct.pack(">4sI", b"icns", len(body) + 8) + body


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("Usage: package-icons.py SOURCE.iconset DESTINATION.icns")
    Path(sys.argv[2]).write_bytes(package_icon(Path(sys.argv[1])))
