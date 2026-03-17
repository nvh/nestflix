# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
swift build
swift run NestFlix "AlbumName" --output out.mp4
swift run NestFlix --list-albums
```

No tests configured. Requires ffmpeg at `/opt/homebrew/bin/ffmpeg`.

## Architecture

Single-file CLI (`Sources/NestFlix/NestFlix.swift`) using Swift ArgumentParser. macOS 13+, Swift 6.2.

Pipeline: PhotoKit album lookup → video export (handles local + iCloud) → luminance analysis via ffmpeg signalstats → trim unstable/flash segments → extract stable segments with ffmpeg → concatenate with ffmpeg (stream copy, re-encode fallback).

The flash detection uses YAVG (average luminance) deltas between frames — designed for IR night-vision camera flash artifacts.
