#!/usr/bin/env python3
"""Create the update feed from the signed, final release archive."""
import argparse
import base64
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path
import subprocess
import plistlib
import zipfile
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def create_appcast(archive, version, build, repository, signature):
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("The archive must have a valid Ed25519 signature")
    if not all(part.isdigit() for part in version.split(".")) or len(version.split(".")) != 3:
        raise ValueError("Version must contain three numeric components")
    if not build.isdigit() or int(build) < 1:
        raise ValueError("Build number must be a positive integer")
    root = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "StoryWriter updates"
    ET.SubElement(channel, "link").text = f"https://github.com/{repository}/releases"
    ET.SubElement(channel, "language").text = "en"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"StoryWriter {version}"
    ET.SubElement(item, "link").text = f"https://github.com/{repository}/releases/tag/v{version}"
    ET.SubElement(item, "pubDate").text = format_datetime(datetime.now(timezone.utc))
    ET.SubElement(item, f"{{{SPARKLE}}}version").text = build
    ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = version
    ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = "14.0.0"
    ET.SubElement(item, "description").text = "Improvements and fixes. See the GitHub release for the changes in this version."
    ET.SubElement(item, "enclosure", {
        "url": f"https://github.com/{repository}/releases/download/v{version}/{archive.name}",
        "length": str(archive.stat().st_size),
        "type": "application/octet-stream",
        f"{{{SPARKLE}}}edSignature": signature,
    })
    ET.indent(root)
    return ET.ElementTree(root)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--sign-tool", type=Path, required=True)
    parser.add_argument("--key-file", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    with zipfile.ZipFile(args.archive) as archive:
        info = plistlib.loads(archive.read("StoryWriter.app/Contents/Info.plist"))
    if info["CFBundleVersion"] != args.build or info["CFBundleShortVersionString"] != args.version:
        raise ValueError("The archived app's version does not match the release")
    signature = subprocess.check_output([
        str(args.sign_tool), "--ed-key-file", str(args.key_file), "-p", str(args.archive)
    ], text=True).strip()
    subprocess.run([
        str(args.sign_tool), "--ed-key-file", str(args.key_file), "--verify", str(args.archive), signature
    ], check=True)
    subprocess.run([
        "swift", str(Path(__file__).with_name("verify-update.swift")),
        str(args.archive), info["SUPublicEDKey"], signature
    ], check=True)
    tree = create_appcast(args.archive, args.version, args.build, args.repository, signature)
    tree.write(args.output, encoding="utf-8", xml_declaration=True)
    subprocess.run([
        str(args.sign_tool), "--ed-key-file", str(args.key_file), str(args.output)
    ], check=True)
    subprocess.run([
        str(args.sign_tool), "--ed-key-file", str(args.key_file), "--verify", str(args.output)
    ], check=True)


if __name__ == "__main__":
    main()
