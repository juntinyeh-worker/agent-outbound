#!/usr/bin/env python3
"""
Export a single Photos album from macOS Photos:
  - photos  -> full-size JPEG
  - videos  -> MP4 (lossless remux when possible, else high-quality re-encode)

Features:
  - Live per-item progress printed to stdout.
  - Optional export dir: if omitted, a folder named after the album is
    created in the current directory.
  - Resumable: items already present in the target dir are skipped
    (matched by filename stem), so re-running won't duplicate work.

Usage:
    python3 export_album.py "Album Name"                 # -> ./Album Name/
    python3 export_album.py "Album Name" /path/to/dir    # -> /path/to/dir/

Tested target: macOS 10.13 (High Sierra), Photos 3, system python3.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import time

VIDEO_EXTS = {".mov", ".m4v", ".avi", ".mpg", ".mpeg", ".3gp", ".mts", ".mkv"}


def log(msg: str) -> None:
    """Print immediately (unbuffered) so progress shows up live."""
    print(msg, flush=True)


def escape_applescript_string(s: str) -> str:
    """Escape backslashes and double quotes for safe embedding in AppleScript."""
    return s.replace("\\", "\\\\").replace('"', '\\"')


def sanitize_dirname(name: str) -> str:
    """Turn an album name into a safe folder name."""
    # Replace path separators and other awkward characters with underscores.
    cleaned = re.sub(r'[/\\:*?"<>|]+', "_", name).strip()
    return cleaned or "album_export"


def run_osascript(script: str):
    return subprocess.run(["osascript", "-e", script],
                          capture_output=True, text=True)


def get_album_filenames(album_name: str) -> list:
    """
    Return the original filename of every media item in the album, in order.
    The list index + 1 corresponds to the AppleScript media-item index.
    Exits on error (e.g. album not found).
    """
    safe_album = escape_applescript_string(album_name)
    script = f'''
    set output to ""
    tell application "Photos"
        set matches to (every album whose name is "{safe_album}")
        if (count of matches) is 0 then
            error "No album named '{safe_album}' was found."
        end if
        set a to item 1 of matches
        repeat with itm in (get media items of a)
            try
                set fn to filename of itm
            on error
                set fn to ""
            end try
            set output to output & fn & linefeed
        end repeat
    end tell
    return output
    '''
    result = run_osascript(script)
    if result.returncode != 0:
        log(f"ERROR: {result.stderr.strip()}")
        sys.exit(1)
    # Preserve order; keep empty entries so indexes stay aligned.
    return result.stdout.split("\n")[:-1] if result.stdout.endswith("\n") \
        else result.stdout.split("\n")


def existing_stems(export_dir: str) -> set:
    """Set of lowercased filename stems already present in the export dir."""
    stems = set()
    if not os.path.isdir(export_dir):
        return stems
    for f in os.listdir(export_dir):
        if f.startswith("."):
            continue
        if os.path.isfile(os.path.join(export_dir, f)):
            stems.add(os.path.splitext(f)[0].lower())
    return stems


def export_one_item(album_name: str, index: int, export_dir: str) -> bool:
    """Export a single media item (1-based index) from the album. True on success."""
    safe_album = escape_applescript_string(album_name)
    safe_dir = escape_applescript_string(export_dir)
    script = f'''
    tell application "Photos"
        set a to item 1 of (every album whose name is "{safe_album}")
        set theItem to media item {index} of a
        with timeout of 600 seconds
            export {{theItem}} to (POSIX file "{safe_dir}") without using originals
        end timeout
    end tell
    '''
    result = run_osascript(script)
    if result.returncode != 0:
        log(f"    ! failed on item {index}: {result.stderr.strip()}")
        return False
    return True


def export_album(album_name: str, export_dir: str) -> tuple:
    """
    Export the album, skipping items already present.
    Returns (total_items, exported_now, skipped).
    """
    filenames = get_album_filenames(album_name)
    total = len(filenames)
    done_stems = existing_stems(export_dir)

    log(f"Album '{album_name}' has {total} item(s).")
    if done_stems:
        log(f"{len(done_stems)} file(s) already in target dir — will skip matches.")
    log("")

    exported = 0
    skipped = 0
    start = time.time()

    for i, fname in enumerate(filenames, 1):
        stem = os.path.splitext(fname)[0].lower() if fname else ""
        label = fname or f"item {i}"

        if stem and stem in done_stems:
            log(f"[{i}/{total}] skip (already exported): {label}")
            skipped += 1
            continue

        log(f"[{i}/{total}] exporting: {label}")
        if export_one_item(album_name, i, export_dir):
            exported += 1
            if stem:
                done_stems.add(stem)  # avoid re-exporting duplicate names later

    elapsed = time.time() - start
    log("")
    log(f"Export pass finished in {elapsed:.1f}s: "
        f"{exported} exported, {skipped} skipped, {total} total")
    return total, exported, skipped


def convert_videos_to_mp4(export_dir: str) -> None:
    ffmpeg = shutil.which("ffmpeg")
    videos = [f for f in os.listdir(export_dir)
              if os.path.splitext(f)[1].lower() in VIDEO_EXTS
              and os.path.isfile(os.path.join(export_dir, f))]

    if not videos:
        log("\nNo video files to convert.")
        return

    if not ffmpeg:
        log("\n⚠️  ffmpeg not found — leaving videos as-is (.mov etc.).")
        log("    Install ffmpeg (`brew install ffmpeg`) and re-run to get .mp4.")
        return

    log(f"\nConverting {len(videos)} video(s) to MP4...")
    for n, fname in enumerate(videos, 1):
        src = os.path.join(export_dir, fname)
        root, _ = os.path.splitext(fname)
        dst = os.path.join(export_dir, root + ".mp4")
        if os.path.exists(dst):
            dst = os.path.join(export_dir, root + "_converted.mp4")

        log(f"[{n}/{len(videos)}] {fname} -> {os.path.basename(dst)} (remux)")
        remux = subprocess.run(
            [ffmpeg, "-y", "-i", src, "-c", "copy",
             "-movflags", "+faststart", dst],
            capture_output=True, text=True,
        )

        if remux.returncode != 0:
            log(f"    remux not possible, re-encoding at high quality...")
            enc = subprocess.run(
                [ffmpeg, "-y", "-i", src,
                 "-c:v", "libx264", "-crf", "18", "-preset", "slow",
                 "-c:a", "aac", "-b:a", "256k",
                 "-movflags", "+faststart", dst],
                capture_output=True, text=True,
            )
            if enc.returncode != 0:
                log(f"    ! conversion failed for {fname}: {enc.stderr.strip()[:200]}")
                continue

        if os.path.exists(dst):
            os.remove(src)
            log(f"    done, removed intermediate {fname}")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Export a Photos album (JPEGs + MP4 videos) with live progress.")
    parser.add_argument("album", help="Name of the album to export")
    parser.add_argument(
        "export_dir", nargs="?", default=None,
        help="Directory to export into. "
             "If omitted, a folder named after the album is created here.")
    args = parser.parse_args()

    if args.export_dir:
        export_dir = os.path.abspath(os.path.expanduser(args.export_dir))
    else:
        export_dir = os.path.abspath(sanitize_dirname(args.album))

    os.makedirs(export_dir, exist_ok=True)

    log("=" * 60)
    log(f"Exporting album : {args.album}")
    log(f"Destination     : {export_dir}")
    log("=" * 60)

    total, exported, skipped = export_album(args.album, export_dir)
    convert_videos_to_mp4(export_dir)

    present = len([
        f for f in os.listdir(export_dir)
        if os.path.isfile(os.path.join(export_dir, f)) and not f.startswith(".")
    ])

    log("")
    log("=" * 60)
    log(f"Items in album  : {total}")
    log(f"Exported now    : {exported}")
    log(f"Skipped (dupe)  : {skipped}")
    log(f"Files present   : {present}")
    if total == present:
        log("✅ Counts match — safe to review, then delete originals.")
    else:
        log("⚠️  Count mismatch — review before deleting any originals.")
    log("=" * 60)


if __name__ == "__main__":
    main()
