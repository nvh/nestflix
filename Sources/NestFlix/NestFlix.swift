import ArgumentParser
import Photos
import AVFoundation
import Foundation

@main
struct NestFlix: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Export videos from a Photos album and stitch them into one video"
    )

    @Argument(help: "Name of the Photos album")
    var albumName: String?

    @Option(name: .shortAndLong, help: "Output file path")
    var output: String = "output.mp4"

    @Flag(name: .shortAndLong, help: "List albums and exit")
    var listAlbums: Bool = false

    @Flag(name: .shortAndLong, help: "Include all videos, not just favorites")
    var all: Bool = false

    @Flag(name: .long, help: "Show YAVG debug values during trim detection")
    var debug: Bool = false

    @Flag(name: .long, help: "Keep empty birdhouse segments (skip entropy filtering)")
    var keepEmpty: Bool = false

    func run() async throws {
        let status = await requestPhotoAccess()
        guard status == .authorized || status == .limited else {
            print("Error: Photos access denied. Grant access in System Settings > Privacy > Photos.")
            throw ExitCode.failure
        }

        if listAlbums {
            listAllAlbums()
            return
        }

        guard let albumName else {
            print("Error: album name required. Use --list-albums to see available albums.")
            throw ExitCode.failure
        }

        guard let album = findAlbum(named: albumName) else {
            print("Error: Album '\(albumName)' not found.")
            print("Available albums:")
            listAllAlbums()
            throw ExitCode.failure
        }

        let videos = fetchVideos(from: album, favoritesOnly: !all)
        guard !videos.isEmpty else {
            print("No videos found in album '\(albumName)'.")
            throw ExitCode.failure
        }
        print("Found \(videos.count) videos in '\(albumName)'")

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NestFlix-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        print("Exporting and analyzing videos...")
        var allSegments: [(url: URL, duration: Double, entropy: Double)] = []
        for (i, asset) in videos.enumerated() {
            let url = try await exportVideo(asset: asset, to: tempDir, index: i)
            let stableRanges = findStableSegments(in: url, debug: debug)
            if stableRanges.isEmpty {
                print("  [\(i + 1)/\(videos.count)] \(url.lastPathComponent) — no stable segments, skipped")
                continue
            }
            let extracted = try extractSegments(
                from: url, ranges: stableRanges, tempDir: tempDir, prefix: String(format: "%04d", i)
            )
            let trimmedDuration = stableRanges.reduce(0.0) { $0 + ($1.1 - $1.0) }
            let removedDuration = asset.duration - trimmedDuration

            // Measure entropy per segment
            let videoSegments = extracted.enumerated().map { (j, segURL) in
                (url: segURL, duration: stableRanges[j].1 - stableRanges[j].0, entropy: analyzeEntropy(in: segURL))
            }

            // Per-video entropy filtering
            if !keepEmpty && videoSegments.count >= 2 {
                let sorted = videoSegments.map(\.entropy).sorted()
                let median = sorted[sorted.count / 2]
                var kept = 0
                for seg in videoSegments {
                    if seg.entropy >= median {
                        allSegments.append(seg)
                        kept += 1
                    } else if debug {
                        print("    \(seg.url.lastPathComponent) entropy=\(String(format: "%.4f", seg.entropy)) (empty, skipped)")
                    }
                }
                if debug {
                    for seg in videoSegments where seg.entropy >= median {
                        print("    \(seg.url.lastPathComponent) entropy=\(String(format: "%.4f", seg.entropy))")
                    }
                    print("    threshold=\(String(format: "%.4f", median)), kept \(kept)/\(videoSegments.count)")
                }
            } else {
                allSegments.append(contentsOf: videoSegments)
            }

            if removedDuration > 0.2 {
                print("  [\(i + 1)/\(videos.count)] \(url.lastPathComponent) → \(extracted.count) segments (removed \(String(format: "%.1f", removedDuration))s of flashes)")
            } else {
                print("  [\(i + 1)/\(videos.count)] \(url.lastPathComponent)")
            }
        }

        guard !allSegments.isEmpty else {
            print("No usable video segments found.")
            throw ExitCode.failure
        }

        let totalDuration = allSegments.reduce(0.0) { $0 + $1.duration }
        let segmentPaths = allSegments.map(\.url)
        print("Stitching \(segmentPaths.count) segments (\(formatDuration(totalDuration)) total)...")
        try stitchVideos(paths: segmentPaths, output: output, totalDuration: totalDuration)
        print("Done! Output: \(output)")
    }

    func requestPhotoAccess() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    func listAllAlbums() {
        let albums = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .any, options: nil
        )
        albums.enumerateObjects { collection, _, _ in
            let count = PHAsset.fetchAssets(in: collection, options: nil).count
            print("  \(collection.localizedTitle ?? "(untitled)") (\(count) items)")
        }
    }

    func findAlbum(named name: String) -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title == %@", name)
        let results = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .any, options: options
        )
        // If multiple albums share the same name, pick the one with the most assets
        var best: PHAssetCollection?
        var bestCount = -1
        results.enumerateObjects { collection, _, _ in
            let count = PHAsset.fetchAssets(in: collection, options: nil).count
            if count > bestCount {
                best = collection
                bestCount = count
            }
        }
        return best
    }

    func fetchVideos(from album: PHAssetCollection, favoritesOnly: Bool) -> [PHAsset] {
        let options = PHFetchOptions()
        if favoritesOnly {
            options.predicate = NSPredicate(
                format: "mediaType == %d AND favorite == YES",
                PHAssetMediaType.video.rawValue
            )
        } else {
            options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        }
        // No sort — respect the album's manual ordering
        let result = PHAsset.fetchAssets(in: album, options: options)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        return assets
    }

    func exportVideo(asset: PHAsset, to directory: URL, index: Int) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat

            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                guard let urlAsset = avAsset as? AVURLAsset else {
                    // Fall back to export session for non-URL assets (e.g. iCloud)
                    guard let avAsset = avAsset else {
                        continuation.resume(throwing: NSError(
                            domain: "NestFlix", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Failed to load video asset"]
                        ))
                        return
                    }
                    let destURL = directory.appendingPathComponent(
                        String(format: "%04d.mp4", index)
                    )
                    guard let session = AVAssetExportSession(
                        asset: avAsset, presetName: AVAssetExportPresetHighestQuality
                    ) else {
                        continuation.resume(throwing: NSError(
                            domain: "NestFlix", code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "Cannot create export session"]
                        ))
                        return
                    }
                    session.outputURL = destURL
                    session.outputFileType = .mp4
                    session.exportAsynchronously {
                        if session.status == .completed {
                            continuation.resume(returning: destURL)
                        } else {
                            continuation.resume(throwing: session.error ?? NSError(
                                domain: "NestFlix", code: 3,
                                userInfo: [NSLocalizedDescriptionKey: "Export failed"]
                            ))
                        }
                    }
                    return
                }

                // Copy the file for URL-based assets
                let destURL = directory.appendingPathComponent(
                    String(format: "%04d.mp4", index)
                )
                do {
                    try FileManager.default.copyItem(at: urlAsset.url, to: destURL)
                    continuation.resume(returning: destURL)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Analyze the full video and return time ranges of stable segments.
    /// Unstable regions (IR flash transitions) are excluded.
    func findStableSegments(in url: URL, debug: Bool = false) -> [(Double, Double)] {
        let samples = analyzeLuminance(in: url, debug: debug)
        guard samples.count > 10 else {
            // Too short to analyze, return the whole thing
            if let last = samples.last {
                return [(0, last.0)]
            }
            return []
        }

        // Mark each frame as stable or unstable based on local rate of change.
        // A frame is "unstable" if the YAVG delta from the previous frame exceeds threshold.
        let stabilityThreshold = 3.0
        var isStable = [Bool](repeating: true, count: samples.count)
        for i in 1..<samples.count {
            let delta = abs(samples[i].1 - samples[i - 1].1)
            if delta > stabilityThreshold {
                isStable[i] = false
            }
        }
        // First frame inherits from second
        if samples.count > 1 { isStable[0] = isStable[1] }

        // Expand unstable regions: mark frames near unstable ones as unstable too.
        // This catches the ramp-up/down on both sides of a flash.
        let expandFrames = 5
        var expanded = isStable
        for i in 0..<samples.count {
            if !isStable[i] {
                for j in max(0, i - expandFrames)...min(samples.count - 1, i + expandFrames) {
                    expanded[j] = false
                }
            }
        }

        // Build stable time ranges from consecutive stable frames
        var ranges: [(Double, Double)] = []
        var rangeStart: Double? = nil
        for i in 0..<samples.count {
            if expanded[i] {
                if rangeStart == nil {
                    rangeStart = samples[i].0
                }
            } else {
                if let start = rangeStart {
                    let end = samples[i].0
                    if end - start > 0.3 { // Only keep segments longer than 0.3s
                        ranges.append((start, end))
                    }
                    rangeStart = nil
                }
            }
        }
        // Close final range
        if let start = rangeStart, let last = samples.last {
            let end = last.0
            if end - start > 0.3 {
                ranges.append((start, end))
            }
        }

        if debug {
            for (start, end) in ranges {
                print("    → Stable: \(String(format: "%.2f", start))s–\(String(format: "%.2f", end))s")
            }
        }

        return ranges
    }

    /// Run ffmpeg signalstats on the full video, return (timestamp, yavg) pairs.
    func analyzeLuminance(in url: URL, debug: Bool = false) -> [(Double, Double)] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        process.arguments = [
            "-nostdin",
            "-i", url.path,
            "-vf", "signalstats,metadata=print:key=lavfi.signalstats.YAVG",
            "-f", "null", "-",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardError = pipe

        do { try process.run() } catch { return [] }

        // Read incrementally to avoid pipe buffer deadlock
        var samples: [(Double, Double)] = []
        var currentPTS: Double = 0
        var leftover = ""
        let handle = pipe.fileHandleForReading

        while true {
            let data = handle.availableData
            if data.isEmpty { break }
            let chunk = leftover + (String(data: data, encoding: .utf8) ?? "")
            let lines = chunk.components(separatedBy: "\n")
            // Last element may be incomplete, save for next iteration
            leftover = lines.last ?? ""

            for line in lines.dropLast() {
                if line.contains("pts_time:") {
                    if let range = line.range(of: "pts_time:") {
                        let rest = line[range.upperBound...]
                        let numStr = rest.prefix(while: { $0.isNumber || $0 == "." })
                        if let pts = Double(numStr) {
                            currentPTS = pts
                        }
                    }
                }
                if line.contains("lavfi.signalstats.YAVG=") {
                    if let range = line.range(of: "lavfi.signalstats.YAVG=") {
                        let rest = line[range.upperBound...]
                        let numStr = rest.prefix(while: { $0.isNumber || $0 == "." })
                        if let yavg = Double(numStr) {
                            if debug {
                                print("    t=\(String(format: "%.3f", currentPTS)) YAVG=\(String(format: "%.1f", yavg))")
                            }
                            samples.append((currentPTS, yavg))
                        }
                    }
                }
            }
        }

        process.waitUntilExit()
        return samples
    }

    /// Run ffmpeg entropy filter on an extracted segment, return mean normalized entropy.
    func analyzeEntropy(in url: URL) -> Double {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        process.arguments = [
            "-nostdin",
            "-i", url.path,
            "-vf", "entropy,metadata=print:key=lavfi.entropy.normalized_entropy.normal.Y",
            "-f", "null", "-",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardError = pipe

        do { try process.run() } catch { return 0 }

        var values: [Double] = []
        var leftover = ""
        let handle = pipe.fileHandleForReading

        while true {
            let data = handle.availableData
            if data.isEmpty { break }
            let chunk = leftover + (String(data: data, encoding: .utf8) ?? "")
            let lines = chunk.components(separatedBy: "\n")
            leftover = lines.last ?? ""

            for line in lines.dropLast() {
                if line.contains("lavfi.entropy.normalized_entropy.normal.Y=") {
                    if let range = line.range(of: "lavfi.entropy.normalized_entropy.normal.Y=") {
                        let rest = line[range.upperBound...]
                        let numStr = rest.prefix(while: { $0.isNumber || $0 == "." })
                        if let val = Double(numStr) {
                            values.append(val)
                        }
                    }
                }
            }
        }

        process.waitUntilExit()
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Extract specific time ranges from a video into separate files.
    func extractSegments(from url: URL, ranges: [(Double, Double)], tempDir: URL, prefix: String) throws -> [URL] {
        var paths: [URL] = []
        for (j, range) in ranges.enumerated() {
            let segURL = tempDir.appendingPathComponent("\(prefix)_seg\(String(format: "%03d", j)).mp4")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
            process.arguments = [
                "-nostdin",
                "-ss", String(format: "%.3f", range.0),
                "-to", String(format: "%.3f", range.1),
                "-i", url.path,
                "-c", "copy",
                "-y", segURL.path,
            ]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                paths.append(segURL)
            }
        }
        return paths
    }

    func formatDuration(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    func stitchVideos(paths: [URL], output: String, totalDuration: Double) throws {
        let listFile = paths.first!.deletingLastPathComponent()
            .appendingPathComponent("filelist.txt")
        let content = paths.map { "file '\($0.path)'" }.joined(separator: "\n")
        try content.write(to: listFile, atomically: true, encoding: .utf8)

        // Try stream copy first (fast)
        let copyResult = try runFFmpeg(args: [
            "-nostdin",
            "-f", "concat", "-safe", "0",
            "-i", listFile.path,
            "-c", "copy", "-y", output,
        ], totalDuration: totalDuration)

        if !copyResult {
            // Fall back to re-encoding
            print("\rStream copy failed, re-encoding...")
            let encodeResult = try runFFmpeg(args: [
                "-nostdin",
                "-f", "concat", "-safe", "0",
                "-i", listFile.path,
                "-c:v", "h264", "-c:a", "aac", "-y", output,
            ], totalDuration: totalDuration)
            guard encodeResult else {
                throw NSError(
                    domain: "NestFlix", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "ffmpeg failed"]
                )
            }
        }
        // Clear the progress line
        print()
    }

    /// Runs ffmpeg with progress output. Returns true on success.
    func runFFmpeg(args: [String], totalDuration: Double) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardError = pipe

        try process.run()

        let handle = pipe.fileHandleForReading
        var buffer = Data()

        while process.isRunning {
            let data = handle.availableData
            if data.isEmpty { break }
            buffer.append(data)

            // Parse ffmpeg stderr for time= progress lines
            if let str = String(data: buffer, encoding: .utf8) {
                let lines = str.components(separatedBy: "\r")
                for line in lines {
                    if let range = line.range(of: "time=") {
                        let timeStr = String(line[range.upperBound...]).prefix(11)
                        if let seconds = parseFFmpegTime(String(timeStr)), totalDuration > 0 {
                            let pct = min(100, Int(seconds / totalDuration * 100))
                            print("\r  Progress: \(pct)% (\(formatDuration(seconds)) / \(formatDuration(totalDuration)))", terminator: "")
                            fflush(stdout)
                        }
                    }
                }
                // Keep only the last incomplete line in the buffer
                if let lastR = str.lastIndex(of: "\r") {
                    let remaining = str[str.index(after: lastR)...]
                    buffer = Data(remaining.utf8)
                }
            }
        }

        // Read remaining data
        let remaining = handle.readDataToEndOfFile()
        if !remaining.isEmpty, let str = String(data: remaining, encoding: .utf8) {
            for line in str.components(separatedBy: "\r") {
                if let range = line.range(of: "time=") {
                    let timeStr = String(line[range.upperBound...]).prefix(11)
                    if let seconds = parseFFmpegTime(String(timeStr)), totalDuration > 0 {
                        let pct = min(100, Int(seconds / totalDuration * 100))
                        print("\r  Progress: \(pct)% (\(formatDuration(seconds)) / \(formatDuration(totalDuration)))", terminator: "")
                        fflush(stdout)
                    }
                }
            }
        }

        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Parse "HH:MM:SS.ms" time string from ffmpeg output
    func parseFFmpegTime(_ str: String) -> Double? {
        let parts = str.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 3,
              let h = Double(parts[0]),
              let m = Double(parts[1]),
              let s = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }
}
