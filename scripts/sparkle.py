#!/usr/bin/env python3
"""Sparkle の配布設定と生成済み appcast を検証する。署名鍵は出力しない。"""
import argparse
import base64
import os
from pathlib import Path
import plistlib
import re
import subprocess
import xml.etree.ElementTree as ET

REPOSITORY_URL = "https://github.com/sowaretokyo/dev-switcher"
FEED_URL = f"{REPOSITORY_URL}/releases/latest/download/appcast.xml"
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def public_key():
    value = os.environ.get("SPARKLE_PUBLIC_ED_KEY")
    if not value or len(base64.b64decode(value, validate=True)) != 32:
        raise ValueError("SPARKLE_PUBLIC_ED_KEY must be a base64-encoded 32-byte public key")
    return value


def configure(plist_path, release):
    with plist_path.open("rb") as file:
        info = plistlib.load(file)
    if info.get("SUFeedURL") != FEED_URL:
        raise ValueError("SUFeedURL does not match the distribution repository")
    info["DevSwitcherUpdatesEnabled"] = release
    if release:
        info["SUPublicEDKey"] = public_key()
    else:
        info.pop("SUPublicEDKey", None)
    with plist_path.open("wb") as file:
        plistlib.dump(info, file, sort_keys=False)


def validate_feed(feed_path, archive, version, build, previous=None, public_key=None):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("Version must be X.Y.Z")
    if not re.fullmatch(r"[0-9]+", build):
        raise ValueError("Build must be an integer")
    if previous:
        previous_items = ET.parse(previous).findall("./channel/item")
        if not previous_items:
            raise ValueError("Previous appcast has no updates")
        previous_builds = [item.findtext(f"{SPARKLE}version") for item in previous_items]
        if any(not value or not re.fullmatch(r"[0-9]+", value) for value in previous_builds):
            raise ValueError("Previous appcast contains an invalid build number")
        if int(build) <= max(map(int, previous_builds)):
            raise ValueError("Build number must be greater than every build in the previous appcast")
    items = ET.parse(feed_path).findall("./channel/item")
    if len(items) != 1:
        raise ValueError("Expected exactly one update in the release appcast")
    item = items[0]
    if item.findtext(f"{SPARKLE}version") != build:
        raise ValueError("Appcast build does not match APP_BUILD")
    if item.findtext(f"{SPARKLE}shortVersionString") != version:
        raise ValueError("Appcast version does not match APP_VERSION")
    minimum_os = item.findtext(f"{SPARKLE}minimumSystemVersion")
    if minimum_os not in ("15.0", "15.0.0"):
        raise ValueError("Appcast minimum OS must match macOS 15")
    enclosures = item.findall("enclosure")
    if len(enclosures) != 1:
        raise ValueError("Expected exactly one update archive")
    enclosure = enclosures[0]
    expected_url = f"{REPOSITORY_URL}/releases/download/v{version}/{archive.name}"
    if enclosure.get("url") != expected_url:
        raise ValueError("Appcast must point to the immutable versioned release asset")
    if enclosure.get("length") != str(archive.stat().st_size):
        raise ValueError("Appcast archive size is incorrect")
    signature = enclosure.get(f"{SPARKLE}edSignature")
    if not signature or len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("Appcast has no valid EdDSA signature; check the signing key pair")
    if public_key is not None:
        verifier = Path(__file__).with_name("verify-sparkle-update.swift")
        result = subprocess.run(
            ["swift", str(verifier), str(archive), public_key, signature],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            raise ValueError("Archive signature does not match SPARKLE_PUBLIC_ED_KEY: "
                             + result.stderr.strip())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    config = commands.add_parser("configure")
    config.add_argument("plist", type=Path)
    config.add_argument("--release", action="store_true")
    commands.add_parser("check-key")
    check = commands.add_parser("validate-feed")
    check.add_argument("feed", type=Path)
    check.add_argument("archive", type=Path)
    check.add_argument("--version", required=True)
    check.add_argument("--build", required=True)
    check.add_argument("--previous", type=Path)
    check.add_argument("--public-key", required=True)
    args = parser.parse_args()
    if args.command == "check-key":
        public_key()
    elif args.command == "configure":
        configure(args.plist, args.release)
    else:
        validate_feed(args.feed, args.archive, args.version, args.build,
                      args.previous, args.public_key)


if __name__ == "__main__":
    main()
