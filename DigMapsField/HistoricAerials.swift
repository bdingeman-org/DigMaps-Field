//
//  HistoricAerials.swift
//  Already-georeferenced historic aerial imagery, surfaced as extra entries in
//  the Aerial year menu (filtered to where each set has coverage). Mirrors the
//  web app's histaerials.ts. All endpoints verified live 2026-06-17
//  (see memory/historic-aerial-services).
//
//  Kinds: xyz (cached tiles), wms (GetMap per tile), mapserver (/export),
//  imageserver (/exportImage). State-Plane services reproject to 3857 on export.
//

import Foundation
import MapKit

/// Minimal WMS overlay: one GetMap request per tile, in Web Mercator.
final class WMSTileOverlay: MKTileOverlay {
    private let base: String
    private let layerName: String
    init(base: String, layer: String) {
        self.base = base
        self.layerName = layer
        super.init(urlTemplate: nil)
        tileSize = CGSize(width: 256, height: 256)
        canReplaceMapContent = false
        maximumZ = 19
    }
    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        let r = 20037508.342789244, n = Double(1 << path.z), world = r * 2
        let minX = -r + Double(path.x) / n * world
        let maxX = -r + Double(path.x + 1) / n * world
        let maxY = r - Double(path.y) / n * world
        let minY = r - Double(path.y + 1) / n * world
        var c = URLComponents(string: base)!
        c.queryItems = [
            .init(name: "SERVICE", value: "WMS"),
            .init(name: "VERSION", value: "1.1.1"),
            .init(name: "REQUEST", value: "GetMap"),
            .init(name: "LAYERS", value: layerName),
            .init(name: "SRS", value: "EPSG:3857"),
            .init(name: "BBOX", value: "\(minX),\(minY),\(maxX),\(maxY)"),
            .init(name: "WIDTH", value: "256"),
            .init(name: "HEIGHT", value: "256"),
            .init(name: "FORMAT", value: "image/png"),
            .init(name: "TRANSPARENT", value: "true"),
            .init(name: "STYLES", value: "")
        ]
        return c.url!
    }
}

struct HistoricAerial: Identifiable, Equatable {
    enum Kind { case xyz, wms, mapserver, imageserver }
    let id: String
    let label: String
    let kind: Kind
    let url: String
    var layer: String? = nil   // WMS layer name
    var sublayer: Int? = nil   // MapServer sublayer id (layers=show:N)
    let bbox: (s: Double, w: Double, n: Double, e: Double)

    static func == (a: HistoricAerial, b: HistoricAerial) -> Bool { a.id == b.id }

    func covers(_ c: CLLocationCoordinate2D) -> Bool {
        c.latitude >= bbox.s && c.latitude <= bbox.n && c.longitude >= bbox.w && c.longitude <= bbox.e
    }

    func makeOverlay() -> MKTileOverlay {
        switch kind {
        case .xyz:
            let o = MKTileOverlay(urlTemplate: url)
            o.canReplaceMapContent = false
            o.maximumZ = 19
            return o
        case .wms:
            return WMSTileOverlay(base: url, layer: layer ?? "")
        case .mapserver:
            var svc = EsriExportOverlay.Service(base: url, op: "export", region: nil)
            if let n = sublayer { svc.extra = [URLQueryItem(name: "layers", value: "show:\(n)")] }
            return EsriExportOverlay(services: [svc])
        case .imageserver:
            return EsriExportOverlay(services: [.init(base: url, op: "exportImage", region: nil)])
        }
    }
}

private let NJ_WMS = "https://img.nj.gov/imagerywms/"
private let PA_CENTRE = "https://imagery.pasda.psu.edu/arcgis/rest/services/pasda/CentreCountyHistoricAerials/MapServer"

extension HistoricAerial {
    static let all: [HistoricAerial] = [
        // New Jersey (WMS, native 3857)
        .init(id: "nj1920", label: "1920 · NJ shore", kind: .wms, url: NJ_WMS, layer: "Coastal1920", bbox: (38.92, -74.62, 40.5, -73.96)),
        .init(id: "nj1930", label: "1930 · NJ statewide", kind: .wms, url: NJ_WMS, layer: "BlackWhite1930", bbox: (38.92, -75.58, 41.36, -73.89)),
        .init(id: "nj1970", label: "1970 · NJ wetlands", kind: .wms, url: NJ_WMS, layer: "Wetlands1970", bbox: (38.92, -75.58, 40.6, -73.89)),
        .init(id: "nj1977", label: "1977 · NJ tidelands", kind: .wms, url: NJ_WMS, layer: "Tidelands1977", bbox: (38.92, -75.58, 40.6, -73.89)),
        .init(id: "nj1980", label: "1980s · NJ infrared", kind: .wms, url: NJ_WMS, layer: "Infrared1980-1987", bbox: (38.92, -75.58, 41.36, -73.89)),
        // Connecticut (ImageServer, native 3857)
        .init(id: "ct1934", label: "1934 · CT statewide", kind: .imageserver, url: "https://cteco.uconn.edu/ctraster/rest/services/images/Mosaic_1934_MAGIC/ImageServer", bbox: (40.98, -73.73, 42.05, -71.78)),
        .init(id: "ct1990", label: "1990 · CT statewide", kind: .imageserver, url: "https://cteco.uconn.edu/ctraster/rest/services/images/Ortho_1990/ImageServer", bbox: (40.98, -73.73, 42.05, -71.78)),
        // Vermont (ImageServer, State Plane → reprojects)
        .init(id: "vt1974", label: "1974–92 · VT statewide", kind: .imageserver, url: "https://maps.vcgi.vermont.gov/arcgis/rest/services/EGC_services/IMG_VCGI_BW1974_1992_SP_NOCACHE/ImageServer", bbox: (42.72, -73.44, 45.02, -71.46)),
        .init(id: "vt1994", label: "1994–2000 · VT statewide", kind: .imageserver, url: "https://maps.vcgi.vermont.gov/arcgis/rest/services/EGC_services/IMG_VCGI_BW1994_2000_SP_NOCACHE/ImageServer", bbox: (42.72, -73.44, 45.02, -71.46)),
        // New Hampshire (ImageServer) — 1962/1974 seacoast only
        .init(id: "nh1962", label: "1962 · NH seacoast", kind: .imageserver, url: "https://nhgeodata.unh.edu/image/rest/services/ImageServices/Regional1962Pan/ImageServer", bbox: (42.7, -71.3, 43.35, -70.6)),
        .init(id: "nh1974", label: "1974 · NH seacoast", kind: .imageserver, url: "https://nhgeodata.unh.edu/image/rest/services/ImageServices/Regional1974Pan/ImageServer", bbox: (42.7, -71.3, 43.35, -70.6)),
        .init(id: "nh1992", label: "1992–98 · NH statewide", kind: .imageserver, url: "https://nhgeodata.unh.edu/image/rest/services/ImageServices/NH_DOQs_92_98/ImageServer", bbox: (42.69, -72.56, 45.31, -70.70)),
        // Massachusetts (cached XYZ, native 3857)
        .init(id: "ma1990", label: "1990s · MA statewide", kind: .xyz, url: "https://tiles.arcgis.com/tiles/hGdibHYSPO59RG1h/arcgis/rest/services/BW_Orthos_Tile_Package/MapServer/tile/{z}/{y}/{x}", bbox: (41.23, -73.51, 42.89, -69.86)),
        // Pennsylvania (MapServer /export, State Plane → reprojects)
        .init(id: "pa1938", label: "1938 · PA Centre Co.", kind: .mapserver, url: PA_CENTRE, sublayer: 0, bbox: (40.7, -78.1, 41.2, -77.5)),
        .init(id: "pa1957", label: "1957 · PA Centre Co.", kind: .mapserver, url: PA_CENTRE, sublayer: 1, bbox: (40.7, -78.1, 41.2, -77.5)),
        .init(id: "pa1971", label: "1971 · PA Centre Co.", kind: .mapserver, url: PA_CENTRE, sublayer: 2, bbox: (40.7, -78.1, 41.2, -77.5)),
        .init(id: "pa1949", label: "1949 · PA State College", kind: .mapserver, url: "https://imagery.pasda.psu.edu/arcgis/rest/services/pasda/StateCollege_UniversityPark_historic/MapServer", sublayer: 0, bbox: (40.75, -77.95, 40.85, -77.78)),
        .init(id: "pa1980", label: "1980s · PA statewide IR", kind: .mapserver, url: "https://imagery.pasda.psu.edu/arcgis/rest/services/pasda/PA_NHAP80s/MapServer", bbox: (39.71, -80.52, 42.27, -74.69))
    ]

    /// Historic sets covering a coordinate (for filtering the Aerial menu).
    static func forCenter(_ c: CLLocationCoordinate2D) -> [HistoricAerial] {
        all.filter { $0.covers(c) }
    }
}

/// Aerial year selection: a modern catalog year or a historic set.
enum AerialPick: Equatable {
    case modern(CatalogAerial)
    case historic(HistoricAerial)

    var id: String {
        switch self {
        case .modern(let a): return "m-" + a.id
        case .historic(let h): return "h-" + h.id
        }
    }
    var label: String {
        switch self {
        case .modern(let a): return a.name
        case .historic(let h): return h.label
        }
    }
    static func == (a: AerialPick, b: AerialPick) -> Bool { a.id == b.id }
}
