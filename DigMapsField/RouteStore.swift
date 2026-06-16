//
//  RouteStore.swift
//  The library of saved routes (GPX / GeoJSON) in the app sandbox, mirroring
//  MapStore. A route is a file you own — drop it in via Files/AirDrop or the
//  in-app importer. The *active* route (the one being followed) is persisted
//  in UserDefaults so the CarPlay scene — a separate process-side store — reads
//  the same selection without any shared object.
//

import Foundation
import MapKit

struct RouteFile: Identifiable, Hashable {
    let url: URL
    var id: String { url.lastPathComponent }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

@MainActor
final class RouteStore: ObservableObject {
    @Published private(set) var routes: [RouteFile] = []
    @Published var activeRouteID: String? {
        didSet { UserDefaults.standard.set(activeRouteID, forKey: Self.activeKey) }
    }
    @Published var lastError: String?

    static let activeKey = "activeRouteID"
    private static let exts: Set<String> = ["gpx", "geojson", "json"]

    /// Documents/Routes — visible in the Files app so tracks can be dragged in.
    let routesDir: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Routes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init() {
        // assigning in init does NOT fire didSet, so this doesn't re-write the default
        activeRouteID = UserDefaults.standard.string(forKey: Self.activeKey)
        refresh()
    }

    func refresh() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: routesDir, includingPropertiesForKeys: nil)) ?? []
        routes = urls
            .filter { Self.exts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .map(RouteFile.init)
        // drop a stale active selection if its file is gone
        if let id = activeRouteID, !routes.contains(where: { $0.id == id }) {
            activeRouteID = nil
        }
    }

    /// Copy an incoming track into Routes/, validating it parses first.
    func importRoute(from url: URL) {
        lastError = nil
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            guard Self.exts.contains(url.pathExtension.lowercased()) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            var dest = routesDir.appendingPathComponent(url.lastPathComponent)
            var n = 2
            let base = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            while FileManager.default.fileExists(atPath: dest.path) {
                dest = routesDir.appendingPathComponent("\(base)-\(n).\(ext)")
                n += 1
            }
            try FileManager.default.copyItem(at: url, to: dest)
            // sanity-check it actually yields a track; remove if not
            guard Route.load(from: dest) != nil else {
                try? FileManager.default.removeItem(at: dest)
                throw CocoaError(.fileReadCorruptFile)
            }
            refresh()
            activeRouteID = dest.lastPathComponent   // newly imported = active
        } catch {
            lastError = "Couldn't import \(url.lastPathComponent) — is it a GPX or GeoJSON track?"
        }
    }

    func delete(_ file: RouteFile) {
        try? FileManager.default.removeItem(at: file.url)
        if activeRouteID == file.id { activeRouteID = nil }
        refresh()
    }

    var activeFile: RouteFile? { routes.first { $0.id == activeRouteID } }

    /// Parse the active route on demand (callers cache the result).
    func activeRoute() -> Route? { activeFile.flatMap { Route.load(from: $0.url) } }
}
