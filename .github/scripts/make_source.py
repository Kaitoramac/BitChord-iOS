#!/usr/bin/env python3
"""Writes the SideStore / AltStore source (apps.json format) for one build.

SideStore reads it from the "latest" release, so adding the source once is
enough: every new build on main shows up as an update.
"""
import argparse
import datetime
import json
import os

parser = argparse.ArgumentParser()
parser.add_argument("--repo", required=True, help="owner/name")
parser.add_argument("--tag", required=True)
parser.add_argument("--build", required=True, help="CFBundleVersion, increases every build")
parser.add_argument("--version", required=True, help="CFBundleShortVersionString")
parser.add_argument("--ipa", required=True)
parser.add_argument("--notes", default="")
args = parser.parse_args()

owner = args.repo.split("/")[0]
raw = f"https://raw.githubusercontent.com/{args.repo}/main"
releases = f"https://github.com/{args.repo}/releases"

source = {
    "name": "BitChord iOS",
    "identifier": f"io.github.{owner.lower()}.bitchord-ios",
    "sourceURL": f"{releases}/latest/download/source.json",
    "subtitle": "Nightly builds from main",
    "iconURL": f"{raw}/iosApp/BitChord/Assets.xcassets/AppIcon.appiconset/AppIcon.png",
    "tintColor": "#FA2D48",
    "apps": [
        {
            "name": "BitChord",
            "bundleIdentifier": "com.music.bitchord.ios",
            "developerName": owner,
            "subtitle": "YouTube Music, Apple Music style",
            "localizedDescription": "iOS client for BitChord (GPL-3.0). Not affiliated with YouTube, Google or Apple.",
            "iconURL": f"{raw}/iosApp/BitChord/Assets.xcassets/AppIcon.appiconset/AppIcon.png",
            "tintColor": "#FA2D48",
            "category": "entertainment",
            "versions": [
                {
                    "version": args.version,
                    "buildVersion": args.build,
                    "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                    "localizedDescription": args.notes or f"Build {args.build}",
                    "downloadURL": f"{releases}/download/{args.tag}/BitChord.ipa",
                    "size": os.path.getsize(args.ipa),
                    "minOSVersion": "18.0",
                }
            ],
            "appPermissions": {
                "entitlements": [],
                "privacy": {},
            },
        }
    ],
    "news": [],
}

print(json.dumps(source, indent=2))
