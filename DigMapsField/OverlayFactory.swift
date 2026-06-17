//
//  OverlayFactory.swift
//  Single source of truth for building the map overlays, shared by the phone
//  UI (MapHomeView) and the CarPlay scene (CarPlaySceneDelegate) so both render
//  identically. Previously these were inline in MapHomeView.buildOverlay().
//

import Foundation
import MapKit
import UIKit

enum OverlayFactory {
    /// Workshop gold — the route line, identical on phone and CarPlay.
    static let routeColor = UIColor(red: 0xb8/255.0, green: 0x86/255.0, blue: 0x2c/255.0, alpha: 0.9)

    static func routeRenderer(for polyline: MKPolyline) -> MKPolylineRenderer {
        let r = MKPolylineRenderer(polyline: polyline)
        r.strokeColor = routeColor
        r.lineWidth = 5
        r.lineCap = .round
        r.lineJoin = .round
        return r
    }

    /// USGS 3DEP national elevation ImageServer. Served via /exportImage with a
    /// "Hillshade Gray" rendering rule. One national source (vs. stitching NY +
    /// NJ state services) means no service seam, no rectangular bleed over water
    /// or across state lines, and transparent oceans — while still resolving to
    /// ~1 m LiDAR detail wherever 3DEP has it (old roads, cellar holes).
    static let usgs3DEP =
        "https://elevation.nationalmap.gov/arcgis/rest/services/3DEPElevation/ImageServer"

    static func mbtiles(_ file: MapFile) -> MKTileOverlay? {
        MBTilesOverlay(fileURL: file.url)
    }

    static func hillshade() -> MKTileOverlay {
        EsriExportOverlay(services: [
            .init(base: usgs3DEP, op: "exportImage", region: nil,
                  renderingRule: #"{"rasterFunction":"Hillshade Gray"}"#),
        ])
    }

    static func aerial(_ a: CatalogAerial) -> MKTileOverlay {
        let o = MKTileOverlay(urlTemplate: a.template)
        o.canReplaceMapContent = false
        o.maximumZ = a.maxZ
        return o
    }

    static func historic(_ m: CatalogHistoricMap, catalog: OverlayCatalog) -> MKTileOverlay {
        let o = MKTileOverlay(urlTemplate: catalog.template(for: m))
        o.canReplaceMapContent = false
        o.maximumZ = 16
        return o
    }
}
