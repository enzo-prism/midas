#!/usr/bin/env python3
"""Create Midas's architecture-specific Sparkle feeds.

Two feeds are published with every latest stable release:

* ``Midas-appcast-arm64-v2.xml`` — the real feed, read by builds with the Midas bundle identifier
  (0.37.0 and later). Requires the signed archive and its Ed25519 signature.
* ``Midas-appcast-arm64.xml`` — the legacy feed still read by 0.33.3–0.36.0 builds, which ran under
  CodexBar's bundle identifier. Sparkle refuses to install an update whose bundle identifier
  differs from the running app, so this feed carries an *informational* item that points those
  users at the manual download (``--informational``).
"""
import argparse
import pathlib
import re
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
FEED_NAME = "Midas-appcast-arm64-v2.xml"
LEGACY_FEED_NAME = "Midas-appcast-arm64.xml"
ET.register_namespace("sparkle", SPARKLE)
parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("archive", type=pathlib.Path, nargs="?")
parser.add_argument("--version", required=True)
parser.add_argument("--build", required=True, type=int)
parser.add_argument("--tag", required=True)
parser.add_argument("--signature")
parser.add_argument("--output", required=True, type=pathlib.Path)
parser.add_argument("--description", default="A new signed Midas update is available.")
parser.add_argument(
    "--informational",
    action="store_true",
    help="Write the legacy feed: no enclosure, just a link to the release for a one-time manual install.")
args = parser.parse_args()
if not re.fullmatch(r"\d+\.\d+\.\d+", args.version) or args.build <= 0:
    parser.error("Expected a stable numeric version and positive build")
if not re.fullmatch(r"v" + re.escape(args.version) + r"-midas\.\d+", args.tag):
    parser.error("Tag must match this Midas version")
if args.output.exists():
    parser.error("Refusing to overwrite an existing feed")
release_url = f"https://github.com/enzo-prism/midas/releases/tag/{args.tag}"

if args.informational:
    if args.output.name != LEGACY_FEED_NAME:
        parser.error(f"The informational feed must be named {LEGACY_FEED_NAME}")
    if args.archive is not None or args.signature:
        parser.error("The informational feed takes no archive or signature")
else:
    if args.output.name != FEED_NAME:
        parser.error(f"The update feed must be named {FEED_NAME}")
    if args.archive is None or args.archive.name != f"Midas-{args.version}-macos-arm64.zip":
        parser.error("Expected the Apple Silicon Midas app archive, not debug symbols")
    if not args.signature or not re.fullmatch(r"[A-Za-z0-9+/]{86}==", args.signature):
        parser.error("Expected an Ed25519 archive signature")

rss = ET.Element("rss", {"version": "2.0"})
channel = ET.SubElement(rss, "channel")
ET.SubElement(channel, "title").text = "Midas Updates"
item = ET.SubElement(channel, "item")
ET.SubElement(item, "title").text = f"Midas {args.version}"
ET.SubElement(item, f"{{{SPARKLE}}}version").text = str(args.build)
ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = args.version
ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = "14.0"
if args.informational:
    ET.SubElement(item, f"{{{SPARKLE}}}informationalUpdate")
    ET.SubElement(item, "link").text = release_url
    ET.SubElement(item, "description").text = (
        f"Midas {args.version} moved to its own app identity. Download it once from GitHub and "
        "replace your current copy; Midas keeps your settings and updates itself afterwards.")
else:
    ET.SubElement(item, "description").text = args.description
    ET.SubElement(item, "enclosure", {
        "url": f"https://github.com/enzo-prism/midas/releases/download/{args.tag}/{args.archive.name}",
        "length": str(args.archive.stat().st_size),
        "type": "application/octet-stream",
        f"{{{SPARKLE}}}edSignature": args.signature,
    })
ET.indent(rss)
ET.ElementTree(rss).write(args.output, encoding="utf-8", xml_declaration=True)
