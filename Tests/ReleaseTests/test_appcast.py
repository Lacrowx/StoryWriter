import base64
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("release", Path(__file__).parents[2] / "scripts/package-release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class AppcastTests(unittest.TestCase):
    def test_archive_is_bound_to_version_signature_size_and_system_requirement(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "StoryWriter-0.2.4.zip"
            archive.write_bytes(b"example archive")
            signature = base64.b64encode(bytes(64)).decode()
            tree = release.create_appcast(archive, "0.2.4", "1004", "example/StoryWriter", signature)
            item = tree.find("channel/item")
            self.assertEqual(item.find(f"{{{release.SPARKLE}}}version").text, "1004")
            self.assertEqual(item.find(f"{{{release.SPARKLE}}}minimumSystemVersion").text, "14.0.0")
            enclosure = item.find("enclosure")
            self.assertEqual(enclosure.attrib["length"], str(archive.stat().st_size))
            self.assertEqual(enclosure.attrib[f"{{{release.SPARKLE}}}edSignature"], signature)
            self.assertEqual(enclosure.attrib["url"], "https://github.com/example/StoryWriter/releases/download/v0.2.4/StoryWriter-0.2.4.zip")

    def test_invalid_signature_or_version_cannot_generate_feed(self):
        for signature, version, build in [("bad", "0.2.4", "1004"), (base64.b64encode(bytes(64)).decode(), "bad", "1004"), (base64.b64encode(bytes(64)).decode(), "0.2.4", "0")]:
            with self.assertRaises(ValueError):
                release.create_appcast(Path("missing.zip"), version, build, "example/StoryWriter", signature)
