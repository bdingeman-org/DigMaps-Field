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
    let county: String?   // "Saratoga, NY" — derived from center at build time; nil if unresolved
    let t: String?        // explicit tile template (e.g. mapwarper.net) — overrides the Allmaps/Worker path
    let nz: Int?          // native max zoom — overlay upscales past this instead of requesting un-rendered tiles
    let g: Int?           // control-point count — more = better-anchored/more precise warp; prefer high-g copies

    /// Anchor quality for ranking: a mapwarper (t) map is its own georeference
    /// (trusted); otherwise the GCP count (more = more precise).
    var anchors: Int { t != nil ? 12 : (g ?? 0) }

    var yearLabel: String { y == 0 ? "n.d." : (e == 1 ? "~" : "") + String(y) }   // y==0 = undated

    /// center of the footprint bbox, for distance/grouping
    var center: CLLocationCoordinate2D? {
        guard b.count == 4 else { return nil }
        return CLLocationCoordinate2D(latitude: (b[1] + b[3]) / 2, longitude: (b[0] + b[2]) / 2)
    }

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

    /// Footprint area in deg² (smaller = more local/detailed). Safe if bbox missing.
    private func footprint(_ m: CatalogHistoricMap) -> Double {
        guard m.b.count == 4 else { return .greatestFiniteMagnitude }
        return (m.b[2] - m.b[0]) * (m.b[3] - m.b[1])
    }

    /// Collapse multi-plate atlases to the plate that best covers `center`, then
    /// rank: plates covering the center first, then smaller (more local) footprint,
    /// then newer. Stops one atlas (e.g. a 26-plate Beers county atlas) from filling
    /// the list with identical-looking rows, and surfaces the map under your view.
    private func collapseAndRank(_ candidates: [CatalogHistoricMap],
                                 center: CLLocationCoordinate2D) -> [CatalogHistoricMap] {
        // Among copies of the same plate, prefer one that covers the spot, then a
        // TPS-precise copy (≥6 control points) over an affine one, then the most
        // local footprint. Fixes auto-picking a sparse 3-GCP copy over a 20-GCP one.
        func better(_ a: CatalogHistoricMap, _ b: CatalogHistoricMap) -> Bool {
            let ac = a.covers(center), bc = b.covers(center)
            if ac != bc { return ac }
            let ap = a.anchors >= 6, bp = b.anchors >= 6
            if ap != bp { return ap }
            return footprint(a) < footprint(b)
        }
        var best: [String: CatalogHistoricMap] = [:]
        for m in candidates {
            let key = "\(m.y)|\(m.atlas)"
            if let cur = best[key] { if better(m, cur) { best[key] = m } }
            else { best[key] = m }
        }
        return best.values.sorted { a, b in
            let ac = a.covers(center), bc = b.covers(center)
            if ac != bc { return ac }
            let ap = a.anchors >= 6, bp = b.anchors >= 6
            if ap != bp { return ap }
            let fa = footprint(a), fb = footprint(b)
            if fa != fb { return fa < fb }
            return a.y > b.y
        }
    }

    /// One row per atlas — the plate that best covers the coordinate — most-local first.
    func historic(at c: CLLocationCoordinate2D) -> [CatalogHistoricMap] {
        collapseAndRank(maps.filter { $0.covers(c) }, center: c)
    }

    /// Web-parity (DigMaps build 28): maps that would VISIBLY cover the current
    /// viewport — ≥25% of the view inside the inked footprint, or the whole
    /// sheet sitting inside the view. Recomputed as the map pans.
    func historic(in region: MKCoordinateRegion) -> [CatalogHistoricMap] {
        let w = region.center.longitude - region.span.longitudeDelta / 2
        let e = region.center.longitude + region.span.longitudeDelta / 2
        let s = region.center.latitude - region.span.latitudeDelta / 2
        let n = region.center.latitude + region.span.latitudeDelta / 2
        let viewArea = (e - w) * (n - s)

        func visible(_ m: CatalogHistoricMap) -> Bool {
            guard m.b.count == 4 else { return false }
            let iw = min(m.b[2], e) - max(m.b[0], w)
            let ih = min(m.b[3], n) - max(m.b[1], s)
            guard iw > 0, ih > 0 else { return false }
            let mapArea = (m.b[2] - m.b[0]) * (m.b[3] - m.b[1])
            let ofView = iw * ih / max(viewArea, 1e-12)
            let ofMap = iw * ih / max(mapArea, 1e-12)
            guard ofView >= 0.25 || ofMap >= 0.9 else { return false }
            if ofMap >= 0.9 { return true } // whole sheet inside the view
            var hit = 0
            for gy in 0..<5 {
                for gx in 0..<5 {
                    let lng = w + (Double(gx) + 0.5) / 5 * (e - w)
                    let lat = s + (Double(gy) + 0.5) / 5 * (n - s)
                    if m.covers(CLLocationCoordinate2D(latitude: lat, longitude: lng)) { hit += 1 }
                }
            }
            return Double(hit) / 25 >= 0.25
        }
        return collapseAndRank(maps.filter(visible), center: region.center)
    }

    func template(for map: CatalogHistoricMap) -> String {
        historicTileTemplate.replacingOccurrences(of: "{id}", with: map.id)
    }

    /// The best plate of a given atlas+year covering a point — for "follow the
    /// atlas as you pan town to town" without re-picking from the list.
    func plate(atlas: String, year: Int, covering c: CLLocationCoordinate2D) -> CatalogHistoricMap? {
        collapseAndRank(maps.filter { $0.atlas == atlas && $0.y == year && $0.covers(c) }, center: c).first
    }

    /// In-view maps grouped by county: the county under your view leads (sections
    /// ordered by nearness to the viewport center), each county sorted OLDEST→NEWEST.
    /// Maps with no county fall into a trailing "Other maps" group.
    func historicGroups(in region: MKCoordinateRegion) -> [HistoricCountyGroup] {
        let center = region.center
        func dist(_ m: CatalogHistoricMap) -> Double {
            guard let c = m.center else { return .greatestFiniteMagnitude }
            let dx = c.longitude - center.longitude, dy = c.latitude - center.latitude
            return dx * dx + dy * dy
        }
        var buckets: [String: [CatalogHistoricMap]] = [:]
        for m in historic(in: region) { buckets[m.county ?? "—", default: []].append(m) }
        return buckets.map { (key, maps) in
            let sorted = maps.sorted { a, b in
                let ay = a.y == 0 ? Int.max : a.y           // undated sink to the bottom
                let by = b.y == 0 ? Int.max : b.y
                if ay != by { return ay < by }              // dated oldest → newest
                return footprint(a) < footprint(b)           // then most-local
            }
            let isOther = (key == "—")
            let near = isOther ? .greatestFiniteMagnitude : (sorted.map(dist).min() ?? .greatestFiniteMagnitude)
            return HistoricCountyGroup(county: isOther ? "Other maps" : key, maps: sorted, nearness: near)
        }
        .sorted { $0.nearness < $1.nearness }                 // county under the view first
    }
}

struct HistoricCountyGroup: Identifiable {
    let county: String
    let maps: [CatalogHistoricMap]
    let nearness: Double
    var id: String { county }
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
