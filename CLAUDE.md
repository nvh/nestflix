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

Pipeline: PhotoKit album lookup → video export (handles local + iCloud) → YAVG luminance analysis (flash removal) → segment extraction → entropy analysis (empty birdhouse filtering) → concatenate with ffmpeg (stream copy, re-encode fallback).

**Flash detection**: YAVG deltas between frames via ffmpeg signalstats. Threshold=3.0, ±5 frame expansion around unstable regions. Designed for IR night-vision camera flash artifacts.

**Empty birdhouse filtering**: Per-segment entropy via ffmpeg `entropy` filter (`normalized_entropy.normal.Y`). Per-video median threshold — segments below their video's median are filtered. Runs on already-extracted segments so flash frames don't skew measurements.

All ffmpeg Process calls must use `-nostdin` and `standardInput = FileHandle.nullDevice` to prevent stdin blocking in terminal environments.
