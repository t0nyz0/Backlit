"""The ICNS container must retain the native PNGs and alpha bytes exactly."""
from pathlib import Path
import runpy
import struct
import tempfile
import unittest
import zlib

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "package-icons.py"
MODULE = runpy.run_path(str(SCRIPT))


def png(size):
    def chunk(kind, payload):
        return (struct.pack(">I", len(payload)) + kind + payload
                + struct.pack(">I", zlib.crc32(kind + payload) & 0xffffffff))
    # Partially transparent color catches alpha-association conversion.
    rows = (b"\x00" + bytes((40, 50, 60, 128)) * size) * size
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


class IconPackageTests(unittest.TestCase):
    def test_all_ten_representations_preserve_native_png_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            expected = {}
            for kind, name, size in MODULE["ENTRIES"]:
                payload = png(size)
                root.joinpath(name).write_bytes(payload)
                expected[kind] = payload
            packaged = MODULE["package_icon"](root)
            magic, length = struct.unpack(">4sI", packaged[:8])
            self.assertEqual(magic, b"icns")
            self.assertEqual(length, len(packaged))
            actual, offset = {}, 8
            while offset < len(packaged):
                kind, length = struct.unpack(">4sI", packaged[offset:offset + 8])
                self.assertNotIn(kind, actual)
                actual[kind] = packaged[offset + 8:offset + length]
                offset += length
            self.assertEqual(offset, len(packaged))
            self.assertEqual(actual, expected)
            self.assertEqual(len(actual), 10)

    def test_wrong_size_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            root.joinpath("icon_16x16.png").write_bytes(png(32))
            with self.assertRaisesRegex(ValueError, "16-pixel"):
                MODULE["package_icon"](root)


if __name__ == "__main__":
    unittest.main()
