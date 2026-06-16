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

    /// NYS Statewide Hillshade MapServer (no tile cache — served via /export).
    static let nysHillshade =
        "https://elevation.its.ny.gov/arcgis/rest/services/NYS_Statewide_Hillshade/MapServer"

    static func mbtiles(_ file: MapFile) -> MKTileOverlay? {
        MBTilesOverlay(fileURL: file.url)
    }

    static func hillshade() -> MKTileOverlay {
        EsriExportOverlay(exportBase: nysHillshade)
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
