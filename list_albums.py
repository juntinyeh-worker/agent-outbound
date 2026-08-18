#!/usr/bin/env python3
"""
List all user albums in the macOS Photos library, with a photo/video count each.

Usage:
    python3 list_albums.py

Tested target: macOS 10.13 (High Sierra), Photos 3, system python3.
"""

import subprocess
import sys


def main() -> None:
    # AppleScript: emit "<album name>\t<item count>" per line.
    script = '''
    set output to ""
    tell application "Photos"
        repeat with a in albums
            set albumName to name of a
            set itemCount to count of media items of a
            set output to output & albumName & tab & itemCount & linefeed
        end repeat
    end tell
    return output
    '''

    result = subprocess.run(
        ["osascript", "-e", script],
        capture_output=True,
        text=True,
    )

    if result.returncode != 0:
        print("Error talking to Photos:", file=sys.stderr)
        print(result.stderr.strip(), file=sys.stderr)
        sys.exit(1)

    lines = [ln for ln in result.stdout.splitlines() if ln.strip()]

    print(f"Found {len(lines)} album(s):\n")
    print(f"{'COUNT':>7}  ALBUM")
    print(f"{'-----':>7}  -----")

    total = 0
    for line in lines:
        name, _, count = line.partition("\t")
        count = count.strip() or "0"
        total += int(count) if count.isdigit() else 0
        print(f"{count:>7}  {name}")

    print(f"\nTotal items across albums: {total}")


if __name__ == "__main__":
    main()
