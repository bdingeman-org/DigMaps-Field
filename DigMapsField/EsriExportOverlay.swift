//
//  EsriExportOverlay.swift
//  Tile overlay for ArcGIS MapServers that have NO tile cache (export only) —
//  the NYS Statewide Hillshade. Each MapKit tile request becomes an /export
//  call with the tile's EPSG:3857 bbox, mirroring what esri-leaflet's
//  dynamicMapLayer does on the web side.
//

import Foundation
import MapKit

final class EsriExportOverlay: MKTileOverlay {
    private let exportBase: String

    init(exportBase: String, maxZ: Int = 19) {
        self.exportBase = exportBase
        super.init(urlTemplate: nil)
        tileSize = CGSize(width: 256, height: 256)
        canReplaceMapContent = false
        maximumZ = maxZ
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        let n = Double(1 << path.z)
        let world = 20037508.342789244 * 2
        let minX = -20037508.342789244 + Double(path.x) / n * world
        let maxX = -20037508.342789244 + Double(path.x + 1) / n * world
        let maxY = 20037508.342789244 - Double(path.y) / n * world
        let minY = 20037508.342789244 - Double(path.y + 1) / n * world
        var c = URLComponents(string: exportBase + "/export")!
        c.queryItems = [
            .init(name: "bbox", value: "\(minX),\(minY),\(maxX),\(maxY)"),
            .init(name: "bboxSR", value: "3857"),
            .init(name: "imageSR", value: "3857"),
            .init(name: "size", value: "256,256"),
            .init(name: "format", value: "png32"),
            .init(name: "transparent", value: "true"),
            .init(name: "f", value: "image")
        ]
        return c.url!
    }
}
