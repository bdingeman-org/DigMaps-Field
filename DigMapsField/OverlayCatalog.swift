//
//  OverlayCatalog.swift
//  Bundled catalog of ONLINE overlays — the same curated, footprint-verified
//  historic maps DigMaps (web) offers, plus NYS orthoimagery years.
//  These stream tiles over the network (unlike imported MBTiles, which are
//  fully offline) — expect blanks without cell signal in the field.
//

import Foundation
import CoreLocation
import MapKit

struct CatalogHistoricMap: Decodable, Identifiable {
    let id: String
    let y: Int            // publication year
    let e: Int            // 1 = year estimated
    let atlas: String
    let src: String       // Rumsey / NYPL / …
    let b: [Double]       // bbox [w,s,e,n]
    let p: [[Double]]?    // geoMask footprint ring [[lng,lat],…]

    var yearLabel: String { (e == 1 ? "~" : "") + String(y) }

    /// True footprint test (bbox envelopes of rotated sheets lie — see DigMaps build 28).
    func covers(_ c: CLLocationCoordinate2D) -> Bool {
        guard b.count == 4, b[0] <= c.longitude, c.longitude <= b[2],
              b[1] <= c.latitude, c.latitude <= b[3] else { return false }
        guard let ring = p, ring.count > 2 else { return true }
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let (xi, yi) = (ring[i][0], ring[i][1])
            let (xj, yj) = (ring[j][0], ring[j][1])
            if (yi > c.latitude) != (yj > c.latitude),
               c.longitude < (xj - xi) * (c.latitude - yi) / (yj - yi) + xi {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}

struct CatalogAerial: Decodable, Identifiable {
    let name: String
    let template: String
    let attribution: String
    let maxZ: Int
    var id: String { name }
}

struct OverlayCatalog: Decodable {
    let historicTileTemplate: String
    let maps: [CatalogHistoricMap]
    let aerials: [String: [CatalogAerial]]

    static let shared: OverlayCatalog? = {
        guard let url = Bundle.main.url(forResource: "overlay-catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(OverlayCatalog.self, from: data)
    }()

    /// Dated maps whose inked footprint covers the coordinate, oldest first.
    func historic(at c: CLLocationCoordinate2D) -> [CatalogHistoricMap] {
        maps.filter { $0.covers(c) }.sorted { ($0.y, $0.atlas) < ($1.y, $1.atlas) }
    }

    func template(for map: CatalogHistoricMap) -> String {
        historicTileTemplate.replacingOccurrences(of: "{id}", with: map.id)
    }
}

/// What MapScreen renders: an offline file or an online tile template.
enum OverlaySource: Identifiable, Hashable {
    case mbtiles(MapFile)
    case xyz(name: String, template: String, attribution: String, maxZ: Int)

    var id: String {
        switch self {
        case .mbtiles(let f): return "file-" + f.id
        case .xyz(_, let t, _, _): return "xyz-" + t
        }
    }
    var name: String {
        switch self {
        case .mbtiles(let f): return f.name
        case .xyz(let n, _, _, _): return n
        }
    }
    var isOnline: Bool { if case .xyz = self { return true }; return false }
}
