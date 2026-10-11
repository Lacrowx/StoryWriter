#!/usr/bin/env python3
"""Adapt pinned swift-transformers' resource lookup to a signed macOS app.

SwiftPM's native accessor looks for bundles at the .app root, which codesign
rejects. Prefer Contents/Resources, retaining Bundle.module for CLI/XCTest.
This only changes the build checkout; the checked-in dependency stays pinned.
"""
import pathlib
import stat
import sys

source = pathlib.Path(sys.argv[1]) / "checkouts/swift-transformers/Sources/Hub/Hub.swift"
original = '        guard let url = Bundle.module.url(forResource: fallbackTokenizerConfigBaseName, withExtension: "json") else {'
replacement = '''        // StoryWriter: signed macOS app resource layout.
        let resources = Bundle.main.resourceURL.flatMap {
            Bundle(url: $0.appendingPathComponent("swift-transformers_Hub.bundle"))
        } ?? Bundle.module
        guard let url = resources.url(forResource: fallbackTokenizerConfigBaseName, withExtension: "json") else {'''
text = source.read_text()
if replacement not in text:
    if text.count(original) != 1:
        raise SystemExit("The pinned tokenizer resource lookup changed; review the app packaging adapter.")
    source.chmod(source.stat().st_mode | stat.S_IWUSR)
    source.write_text(text.replace(original, replacement))
