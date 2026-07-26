#!/usr/bin/env python3
"""Append one release to Simbi's Sparkle appcast.

Sparkle ships `generate_appcast`, which rebuilds the whole feed from a
directory of builds and stamps every item with a single
`--download-url-prefix`. GitHub Releases puts each asset under its own tag
(`.../releases/download/v1.3.0/...`), so one prefix cannot address more than
one release. This appends a single item with the correct per-tag URL instead,
leaving the signing to Sparkle's own `sign_update`.

Tradeoff: no delta updates, which `generate_appcast` computes from the build
directory. See docs/superpowers/specs/2026-07-27-github-auto-update-design.md.
"""

import argparse
import sys
import xml.etree.ElementTree as ET
from email.utils import format_datetime
from datetime import datetime, timezone
from pathlib import Path

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)


def sparkle(tag: str) -> str:
    return f"{{{SPARKLE_NS}}}{tag}"


def load_channel(path: Path) -> tuple[ET.ElementTree, ET.Element]:
    """Return the feed's tree and <channel>, creating an empty feed if absent."""
    if path.exists() and path.stat().st_size > 0:
        tree = ET.parse(path)
        channel = tree.getroot().find("channel")
        if channel is None:
            sys.exit(f"{path}: <rss> has no <channel>")
        return tree, channel

    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "Simbi"
    ET.SubElement(channel, "link").text = "https://github.com/predict-woo/simbi"
    ET.SubElement(channel, "description").text = "Simbi updates"
    ET.SubElement(channel, "language").text = "en"
    return ET.ElementTree(rss), channel


def build_version(item: ET.Element) -> int:
    """Sparkle compares on <sparkle:version>; treat it as the sort key."""
    node = item.find(sparkle("version"))
    try:
        return int((node.text or "0").strip())
    except (AttributeError, ValueError):
        return 0


def make_item(args: argparse.Namespace) -> ET.Element:
    item = ET.Element("item")
    ET.SubElement(item, "title").text = args.version
    ET.SubElement(item, "pubDate").text = format_datetime(
        datetime.now(timezone.utc)
    )
    ET.SubElement(item, sparkle("version")).text = str(args.build)
    ET.SubElement(item, sparkle("shortVersionString")).text = args.version
    ET.SubElement(item, sparkle("minimumSystemVersion")).text = args.minimum_system_version
    # Untagged items are visible to everyone; only the beta stream is named.
    if args.channel != "stable":
        ET.SubElement(item, sparkle("channel")).text = args.channel
    if args.release_notes_url:
        ET.SubElement(item, sparkle("releaseNotesLink")).text = args.release_notes_url
    ET.SubElement(
        item,
        "enclosure",
        {
            "url": args.url,
            "length": str(args.length),
            "type": "application/octet-stream",
            sparkle("edSignature"): args.signature,
        },
    )
    return item


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--appcast", type=Path, required=True,
                        help="feed to update in place; created if missing")
    parser.add_argument("--version", required=True, help="e.g. 1.3.0")
    parser.add_argument("--build", required=True, type=int,
                        help="CFBundleVersion; must increase monotonically")
    parser.add_argument("--url", required=True, help="download URL of the DMG")
    parser.add_argument("--length", required=True, type=int, help="DMG size in bytes")
    parser.add_argument("--signature", required=True, help="EdDSA signature from sign_update")
    parser.add_argument("--channel", default="stable", choices=["stable", "beta"])
    parser.add_argument("--minimum-system-version", default="14.0")
    parser.add_argument("--release-notes-url", default="")
    parser.add_argument("--keep", type=int, default=20,
                        help="how many items to retain, newest first")
    args = parser.parse_args()

    tree, channel = load_channel(args.appcast)

    # Re-running a tag must replace its item, not duplicate it.
    for existing in channel.findall("item"):
        if build_version(existing) == args.build:
            channel.remove(existing)

    channel.append(make_item(args))

    items = sorted(channel.findall("item"), key=build_version, reverse=True)
    for item in channel.findall("item"):
        channel.remove(item)
    for item in items[: args.keep]:
        channel.append(item)

    ET.indent(tree, space="  ")
    args.appcast.parent.mkdir(parents=True, exist_ok=True)
    tree.write(args.appcast, encoding="utf-8", xml_declaration=True)
    print(f"{args.appcast}: {len(items[: args.keep])} item(s), newest {args.version}")


if __name__ == "__main__":
    main()
