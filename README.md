# NestFlix

A macOS CLI tool that exports videos from a Photos album and stitches them into a single video using ffmpeg. Built for birdhouse cameras, works with any album.

## Requirements

- macOS 13+
- [ffmpeg](https://formulae.brew.sh/formula/ffmpeg) (`brew install ffmpeg`)

## Usage

```bash
# List all albums
swift run NestFlix --list-albums

# Stitch all videos from an album
swift run NestFlix "Vogelhuisje" --output birdhouse.mp4

# Only favorited videos
swift run NestFlix "Vogelhuisje" --favorites --output birdhouse.mp4
```

## How it works

1. Reads videos from a named Photos album using PhotoKit (sorted by creation date)
2. Exports each video to a temp directory (handles both local and iCloud videos)
3. Concatenates them with ffmpeg (stream copy, falls back to re-encoding if formats differ)

## Photos access

On first run, macOS will prompt you to grant Photos access to Terminal (or whichever terminal app you use). You can manage this in **System Settings > Privacy & Security > Photos**.
