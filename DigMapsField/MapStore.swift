//
//  MapStore.swift
//  Manages the library of imported .mbtiles files in the app sandbox.
//  No accounts, no cloud — a map is a file you own.
//

import Foundation

struct MapFile: Identifiable, Equatable {
    let url: URL
    var id: String { url.lastPathComponent }
    var name: String { url.deletingPathExtension().lastPathComponent }
    var sizeMB: Double {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return Double(bytes) / 1_048_576
    }
}

@MainActor
final class MapStore: ObservableObject {
    @Published private(set) var maps: [MapFile] = []
    @Published var lastError: String?

    /// Documents/Maps — visible in the Files app (file sharing enabled),
    /// so maps can also be dragged in via Finder/iCloud Drive.
    let mapsDir: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Maps", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init() { refresh() }

    func refresh() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: mapsDir, includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        maps = urls
            .filter { $0.pathExtension.lowercased() == "mbtiles" }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .map(MapFile.init)
    }

    /// Copy an incoming file (fileImporter, AirDrop inbox, share sheet) into Maps/.
    func importMap(from url: URL) {
        lastError = nil
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            guard url.pathExtension.lowercased() == "mbtiles" else {
                throw CocoaError(.fileReadCorruptFile)
            }
            var dest = mapsDir.appendingPathComponent(url.lastPathComponent)
            // dedupe: name.mbtiles -> name-2.mbtiles, name-3.mbtiles …
            var n = 2
            let base = url.deletingPathExtension().lastPathComponent
            while FileManager.default.fileExists(atPath: dest.path) {
                dest = mapsDir.appendingPathComponent("\(base)-\(n).mbtiles")
                n += 1
            }
            try FileManager.default.copyItem(at: url, to: dest)
            // sanity-check it actually opens as MBTiles; remove if not
            if MBTilesOverlay(fileURL: dest) == nil {
                try? FileManager.default.removeItem(at: dest)
                throw CocoaError(.fileReadCorruptFile)
            }
            refresh()
        } catch {
            lastError = "Couldn't import \(url.lastPathComponent) — is it an MBTiles file exported from DigMaps?"
        }
    }

    func delete(_ map: MapFile) {
        try? FileManager.default.removeItem(at: map.url)
        refresh()
    }
}
