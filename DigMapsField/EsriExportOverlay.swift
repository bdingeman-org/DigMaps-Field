//
//  EsriExportOverlay.swift
//  Tile overlay for ArcGIS image/map services that have NO tile cache (export
//  only) — the LiDAR hillshade. Each MapKit tile request becomes an export call
//  with the tile's EPSG:3857 bbox, mirroring esri-leaflet's dynamicMapLayer on
//  the web side.
//
//  Supports more than one backing service, chosen per tile by geography: e.g.
//  New Jersey's statewide 10 ft LiDAR (an ImageServer) for tiles over NJ, and
//  NYS Statewide Hillshade (a MapServer) everywhere else. Selection happens in
//  url(forTilePath:), which MapKit calls per tile, so panning across a state
//  line just works — no overlay rebuild needed.
//

import Foundation
import MapKit

final class EsriExportOverlay: MKTileOverlay {
    /// A lat/lon rectangle used to decide which service serves a given tile.
    struct Region {
        let minLat, minLon, maxLat, maxLon: Double
        func contains(lat: Double, lon: Double) -> Bool {
            lat >= minLat && lat <= maxLat && lon >= minLon && lon <= maxLon
        }
    }

    /// One backing service. `op` is the ArcGIS operation: "export" for a
    /// MapServer, "exportImage" for an ImageServer. `region == nil` means this
    /// service is the fallback used wherever no region-bound service matches.
    /// `renderingRule` is an optional ArcGIS raster-function JSON string (e.g.
    /// `{"rasterFunction":"Hillshade Gray"}`) for ImageServers that serve raw
    /// elevation and render on request.
    struct Service {
        let base: String
        let op: String
        let region: Region?
        var renderingRule: String? = nil
        /// Extra query items (e.g. `layers=show:0` to isolate one year of a
        /// multi-year MapServer). Appended verbatim.
        var extra: [URLQueryItem] = []
    }

    private let services: [Service]

    init(services: [Service], maxZ: Int = 19) {
        self.services = services
        super.init(urlTemplate: nil)
        tileSize = CGSize(width: 256, height: 256)
        canReplaceMapContent = false
        maximumZ = maxZ
    }

    /// Back-compat convenience for a single MapServer (/export) service.
    convenience init(exportBase: String, maxZ: Int = 19) {
        self.init(services: [Service(base: exportBase, op: "export", region: nil)], maxZ: maxZ)
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        let n = Double(1 << path.z)
        let world = 20037508.342789244 * 2
        let minX = -20037508.342789244 + Double(path.x) / n * world
        let maxX = -20037508.342789244 + Double(path.x + 1) / n * world
        let maxY = 20037508.342789244 - Double(path.y) / n * world
        let minY = 20037508.342789244 - Double(path.y + 1) / n * world

        // Tile center back to lat/lon (Web Mercator inverse) to pick a service.
        let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
        let lon = cx / 20037508.342789244 * 180
        let lat = atan(sinh(cy / 6378137.0)) * 180 / .pi
        let svc = services.first { $0.region?.contains(lat: lat, lon: lon) ?? false }
            ?? services.first { $0.region == nil }
            ?? services[0]

        var c = URLComponents(string: svc.base + "/" + svc.op)!
        var items: [URLQueryItem] = [
            .init(name: "bbox", value: "\(minX),\(minY),\(maxX),\(maxY)"),
            .init(name: "bboxSR", value: "3857"),
            .init(name: "imageSR", value: "3857"),
            .init(name: "size", value: "256,256"),
            .init(name: "format", value: "png32"),
            .init(name: "transparent", value: "true"),
            .init(name: "f", value: "image")
        ]
        if let rule = svc.renderingRule {
            items.append(.init(name: "renderingRule", value: rule))
        }
        items.append(contentsOf: svc.extra)
        c.queryItems = items
        return c.url!
    }
}
