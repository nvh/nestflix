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

    @Flag(name: .shortAndLong, help: "Only include favorited videos")
    var favorites: Bool = false

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

        let videos = fetchVideos(from: album, favoritesOnly: favorites)
        guard !videos.isEmpty else {
            print("No videos found in album '\(albumName)'.")
            throw ExitCode.failure
        }
        print("Found \(videos.count) videos in '\(albumName)'")

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NestFlix-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        print("Exporting videos...")
        var exportedPaths: [URL] = []
        for (i, asset) in videos.enumerated() {
            let url = try await exportVideo(asset: asset, to: tempDir, index: i)
            exportedPaths.append(url)
            print("  [\(i + 1)/\(videos.count)] Exported \(url.lastPathComponent)")
        }

        print("Stitching \(exportedPaths.count) videos...")
        try stitchVideos(paths: exportedPaths, output: output)
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
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
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

    func stitchVideos(paths: [URL], output: String) throws {
        let listFile = paths.first!.deletingLastPathComponent()
            .appendingPathComponent("filelist.txt")
        let content = paths.map { "file '\($0.path)'" }.joined(separator: "\n")
        try content.write(to: listFile, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        process.arguments = [
            "-f", "concat",
            "-safe", "0",
            "-i", listFile.path,
            "-c", "copy",
            "-y",
            output,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            // Retry with re-encoding if stream copy fails
            print("Stream copy failed, re-encoding...")
            let process2 = Process()
            process2.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
            process2.arguments = [
                "-f", "concat",
                "-safe", "0",
                "-i", listFile.path,
                "-c:v", "h264",
                "-c:a", "aac",
                "-y",
                output,
            ]
            try process2.run()
            process2.waitUntilExit()
            guard process2.terminationStatus == 0 else {
                throw NSError(
                    domain: "NestFlix", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "ffmpeg failed"]
                )
            }
            return
        }
    }
}
