#!/usr/bin/env python3
"""Create Midas's architecture-specific Sparkle feed from an already signed archive."""
import argparse
import pathlib
import re
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("archive", type=pathlib.Path)
parser.add_argument("--version", required=True)
parser.add_argument("--build", required=True, type=int)
parser.add_argument("--tag", required=True)
parser.add_argument("--signature", required=True)
parser.add_argument("--output", required=True, type=pathlib.Path)
parser.add_argument("--description", default="A new signed Midas update is available.")
args = parser.parse_args()
if not re.fullmatch(r"\d+\.\d+\.\d+", args.version) or args.build <= 0:
    parser.error("Expected a stable numeric version and positive build")
if not re.fullmatch(r"v" + re.escape(args.version) + r"-midas\.\d+", args.tag):
    parser.error("Tag must match this Midas version")
if args.archive.name != f"Midas-{args.version}-macos-arm64.zip":
    parser.error("Expected the Apple Silicon Midas app archive, not debug symbols")
if not re.fullmatch(r"[A-Za-z0-9+/]{86}==", args.signature):
    parser.error("Expected an Ed25519 archive signature")
if args.output.exists():
    parser.error("Refusing to overwrite an existing feed")
rss = ET.Element("rss", {"version": "2.0"})
channel = ET.SubElement(rss, "channel")
ET.SubElement(channel, "title").text = "Midas Updates"
item = ET.SubElement(channel, "item")
ET.SubElement(item, "title").text = f"Midas {args.version}"
ET.SubElement(item, f"{{{SPARKLE}}}version").text = str(args.build)
ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = args.version
ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = "14.0"
ET.SubElement(item, "description").text = args.description
ET.SubElement(item, "enclosure", {
    "url": f"https://github.com/enzo-prism/midas/releases/download/{args.tag}/{args.archive.name}",
    "length": str(args.archive.stat().st_size),
    "type": "application/octet-stream",
    f"{{{SPARKLE}}}edSignature": args.signature,
})
ET.indent(rss)
ET.ElementTree(rss).write(args.output, encoding="utf-8", xml_declaration=True)
