//
//  OverlayFactory.swift
//  Single source of truth for building the map overlays, shared by the phone
//  UI (MapHomeView) and the CarPlay scene (CarPlaySceneDelegate) so both render
//  identically. Previously these were inline in MapHomeView.buildOverlay().
//

import Foundation
import MapKit
import UIKit

/// Which LiDAR hillshade backing to use. Surfaced as a source picker in the UI.
enum HillshadeSource: String, CaseIterable, Identifiable {
    case state = "State LiDAR"
    case usgs  = "USGS 3DEP"
    var id: String { rawValue }
}

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

    /// USGS 3DEP national elevation ImageServer (rendered "Hillshade Gray"). The
    /// national fallback source: covers everywhere with no seams, but lower
    /// detail and slower than the state LiDAR services.
    static let usgs3DEP =
        "https://elevation.nationalmap.gov/arcgis/rest/services/3DEPElevation/ImageServer"

    static func mbtiles(_ file: MapFile) -> MKTileOverlay? {
        MBTilesOverlay(fileURL: file.url)
    }

    /// LiDAR hillshade source. State LiDAR (NY + NJ, stitched and land-clipped)
    /// is the high-detail default; USGS 3DEP is the national fallback.
    static func hillshade(_ source: HillshadeSource = .state) -> MKTileOverlay {
        switch source {
        case .state:
            return StateHillshadeOverlay()
        case .usgs:
            return EsriExportOverlay(services: [
                .init(base: usgs3DEP, op: "exportImage", region: nil,
                      renderingRule: #"{"rasterFunction":"Hillshade Gray"}"#),
            ])
        }
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
