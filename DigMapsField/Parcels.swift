//
//  Parcels.swift
//  Parcel-owner lookup — port of the web app's parcels.ts + regions.ts.
//
//  Tap the map in parcel mode → point-intersects query against the parcel
//  layer covering that spot → owner + tax/deed details + outline. Region is
//  chosen by the tap location (smallest matching bbox), not a manual picker,
//  since the field app is location-driven. All endpoints verified CORS-open /
//  no key on web; native has no CORS constraint anyway.
//

import Foundation
import MapKit
import CoreLocation

// MARK: - config (mirrors regions.ts ParcelConfig)

struct ParcelRow {
    let label: String
    /// display string, or nil to hide the row (web used '' to hide)
    let value: ([String: Any]) -> String?
}

struct ParcelConfig {
    let url: String              // ArcGIS MapServer layer — polygon, intersects query
    let outFields: String
    let ownerField: String
    let coverage: String        // shown when a click misses
    let rows: [ParcelRow]
    /// optional centroid point-layer fallback (opted-out NY counties)
    let fallbackURL: String?
}

private struct ParcelRegion {
    let south, west, north, east: Double
    let parcel: ParcelConfig
    var area: Double { (north - south) * (east - west) }
    func contains(_ c: CLLocationCoordinate2D) -> Bool {
        c.latitude >= south && c.latitude <= north && c.longitude >= west && c.longitude <= east
    }
}

// MARK: - field formatters (mirrors regions.ts s/opt/money/acres)

private func clean(_ v: Any?) -> String {
    guard let v, !(v is NSNull) else { return "" }
    let s = "\(v)"
    return s == "<null>" ? "" : s
}
private func num(_ v: Any?) -> Double? {
    if let n = v as? NSNumber { return n.doubleValue }
    if let s = v as? String { return Double(s) }
    return nil
}
private func S(_ v: Any?) -> String { let x = clean(v); return x.isEmpty ? "—" : x }
private func OPT(_ v: Any?) -> String? { let x = clean(v); return x.isEmpty ? nil : x }
private func MONEY(_ v: Any?) -> String {
    guard let d = num(v), d != 0 else { return "—" }
    let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 0
    return "$" + (f.string(from: NSNumber(value: d)) ?? "\(Int(d))")
}
private func ACRES(_ v: Any?) -> String {
    guard let d = num(v) else { return "—" }
    return String(format: "%.1f", d)
}

// MARK: - region table (mirrors REGIONS; NY counties that share NYS_PARCEL collapse to statewide)

private let NYS_PARCEL = ParcelConfig(
    url: "https://gisservices.its.ny.gov/arcgis/rest/services/NYS_Tax_Parcels_Public/MapServer/1",
    outFields: "PRIMARY_OWNER,ADD_OWNER,PARCEL_ADDR,PRINT_KEY,SBL,ACRES,CALC_ACRES,PROP_CLASS,TOTAL_AV,BOOK,PAGE,COUNTY_NAME",
    ownerField: "PRIMARY_OWNER",
    coverage: "New York State",
    rows: [
        ParcelRow(label: "also")    { OPT($0["ADD_OWNER"]) },
        ParcelRow(label: "county")  { S($0["COUNTY_NAME"]) },
        ParcelRow(label: "address") { S($0["PARCEL_ADDR"]) },
        ParcelRow(label: "tax map") { S($0["PRINT_KEY"]) },
        ParcelRow(label: "SBL")     { S($0["SBL"]) },
        ParcelRow(label: "acres")   { ACRES($0["ACRES"] ?? $0["CALC_ACRES"]) },
        ParcelRow(label: "class")   { S($0["PROP_CLASS"]) },
        ParcelRow(label: "assessed"){ MONEY($0["TOTAL_AV"]) },
        ParcelRow(label: "deed")    { OPT($0["BOOK"]) != nil ? "\(S($0["BOOK"])) / \(S($0["PAGE"]))" : "—" }
    ],
    fallbackURL: "https://gisservices.its.ny.gov/arcgis/rest/services/NYS_Tax_Parcel_Centroid_Points/MapServer/0"
)

private let SARATOGA_PARCEL = ParcelConfig(
    url: "https://spatialags.vhb.com/arcgis/rest/services/29820_Saratoga/NY_County_Saratoga/MapServer/57",
    outFields: "OWNER,PROP_ADDR,PRINT_KEY,SBL,ACRES,DEED_BOOK,DEED_PAGE,MUNI,PROP_CLASS,TOTAL_AV",
    ownerField: "OWNER",
    coverage: "Saratoga County",
    rows: [
        ParcelRow(label: "address") { S($0["PROP_ADDR"]) },
        ParcelRow(label: "tax map") { S($0["PRINT_KEY"]) },
        ParcelRow(label: "SBL")     { S($0["SBL"]) },
        ParcelRow(label: "acres")   { ACRES($0["ACRES"]) },
        ParcelRow(label: "class")   { S($0["PROP_CLASS"]) },
        ParcelRow(label: "assessed"){ MONEY($0["TOTAL_AV"]) },
        ParcelRow(label: "deed")    { OPT($0["DEED_BOOK"]) != nil ? "\(S($0["DEED_BOOK"])) / \(S($0["DEED_PAGE"]))" : "—" },
        ParcelRow(label: "town")    { S($0["MUNI"]) }
    ],
    fallbackURL: nil
)

private let BERGEN_PARCEL = ParcelConfig(
    url: "https://bchapeweb.co.bergen.nj.us/arcgis/rest/services/parcelviewer_MIL1/MapServer/1",
    outFields: "OWNER_NAME,OWNER_ADDR,OWNER_CITY_ST,STREET,BLOCK,LOT,PAMS_PIN,CLASS,TOTL_VALUE,SALE_DATE,SALE_VAL",
    ownerField: "OWNER_NAME",
    coverage: "Bergen County",
    rows: [
        ParcelRow(label: "situs") { S($0["STREET"]) },
        ParcelRow(label: "owner addr") {
            let parts = [S($0["OWNER_ADDR"]), S($0["OWNER_CITY_ST"])].filter { $0 != "—" }
            return parts.isEmpty ? "—" : parts.joined(separator: ", ")
        },
        ParcelRow(label: "block/lot") { "\(S($0["BLOCK"])) / \(S($0["LOT"]))" },
        ParcelRow(label: "PAMS PIN")  { S($0["PAMS_PIN"]) },
        ParcelRow(label: "class")     { S($0["CLASS"]) },
        ParcelRow(label: "assessed")  { MONEY($0["TOTL_VALUE"]) },
        ParcelRow(label: "last sale") { OPT($0["SALE_DATE"]) != nil ? "\(S($0["SALE_DATE"])) · \(MONEY($0["SALE_VAL"]))" : "—" }
    ],
    fallbackURL: nil
)

private let PARCEL_REGIONS: [ParcelRegion] = [
    // most-specific first by area; other NY counties (Dutchess/Westchester/…) fall through to NYS statewide
    ParcelRegion(south: 42.73, west: -74.06, north: 43.32, east: -73.50, parcel: SARATOGA_PARCEL),
    ParcelRegion(south: 40.84, west: -74.27, north: 41.16, east: -73.88, parcel: BERGEN_PARCEL),
    ParcelRegion(south: 40.40, west: -79.90, north: 45.10, east: -71.80, parcel: NYS_PARCEL)
]

func parcelConfig(for c: CLLocationCoordinate2D) -> ParcelConfig? {
    PARCEL_REGIONS.filter { $0.contains(c) }.min { $0.area < $1.area }?.parcel
}

// MARK: - result + lookup

struct ParcelResult {
    let owner: String
    let rows: [(label: String, value: String)]
    let coverage: String
    let rings: [[CLLocationCoordinate2D]]?   // polygon outline(s)
    let point: CLLocationCoordinate2D?        // centroid fallback (no polygon)
}

enum ParcelLookup {
    case noCoverage
    case notFound(coverage: String)
    case found(ParcelResult)
    case failed(String)
}

enum ParcelService {

    static func lookup(at c: CLLocationCoordinate2D) async -> ParcelLookup {
        guard let cfg = parcelConfig(for: c) else { return .noCoverage }
        do {
            // 1) primary: polygon intersects-point query
            if let f = try await queryFirst(url: cfg.url, point: c, fields: cfg.outFields) {
                return .found(makeResult(cfg, props: f.props, geometry: f.geometry, isPoint: false))
            }
            // 2) fallback: centroid-points envelope, nearest to the tap
            if let fb = cfg.fallbackURL {
                let feats = try await queryEnvelope(url: fb, point: c, fields: cfg.outFields)
                if let nearest = nearestPoint(feats, to: c) {
                    return .found(makeResult(cfg, props: nearest.props, geometry: nearest.geometry, isPoint: true))
                }
            }
            return .notFound(coverage: cfg.coverage)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: ArcGIS queries

    private struct Feat { let props: [String: Any]; let geometry: [String: Any]? }

    private static func queryFirst(url: String, point c: CLLocationCoordinate2D, fields: String) async throws -> Feat? {
        let q = "\(url)/query?geometry=\(c.longitude),\(c.latitude)"
            + "&geometryType=esriGeometryPoint&inSR=4326&spatialRel=esriSpatialRelIntersects"
            + "&outFields=\(encode(fields))&returnGeometry=true&outSR=4326&f=geojson"
        return try await features(q).first
    }

    private static func queryEnvelope(url: String, point c: CLLocationCoordinate2D, fields: String) async throws -> [Feat] {
        let d = 0.0016 // ~150 m box
        let env = "\(c.longitude - d),\(c.latitude - d),\(c.longitude + d),\(c.latitude + d)"
        let q = "\(url)/query?geometry=\(env)"
            + "&geometryType=esriGeometryEnvelope&inSR=4326&spatialRel=esriSpatialRelIntersects"
            + "&outFields=\(encode(fields))&returnGeometry=true&outSR=4326&f=geojson"
        return try await features(q)
    }

    private static func features(_ urlString: String) async throws -> [Feat] {
        guard let url = URL(string: urlString) else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw NSError(domain: "parcel", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "parcel service \(http.statusCode)"])
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let feats = json?["features"] as? [[String: Any]] ?? []
        return feats.map { Feat(props: $0["properties"] as? [String: Any] ?? [:],
                                geometry: $0["geometry"] as? [String: Any]) }
    }

    // MARK: build result

    private static func makeResult(_ cfg: ParcelConfig, props: [String: Any], geometry: [String: Any]?, isPoint: Bool) -> ParcelResult {
        let owner = clean(props[cfg.ownerField]).isEmpty ? "Unknown owner" : clean(props[cfg.ownerField])
        let rows = cfg.rows.compactMap { r -> (String, String)? in
            guard let v = r.value(props), !v.isEmpty else { return nil }
            return (r.label, v)
        }
        var rings: [[CLLocationCoordinate2D]]? = nil
        var point: CLLocationCoordinate2D? = nil
        if let g = geometry {
            if isPoint { point = pointCoord(g) } else {
                let rr = ringCoords(g); rings = rr.isEmpty ? nil : rr
            }
        }
        return ParcelResult(owner: owner, rows: rows, coverage: cfg.coverage, rings: rings, point: point)
    }

    // MARK: GeoJSON geometry parsing

    private static func dbl(_ v: Any) -> Double? { (v as? NSNumber)?.doubleValue ?? Double("\(v)") }

    private static func ringCoords(_ g: [String: Any]) -> [[CLLocationCoordinate2D]] {
        guard let type = g["type"] as? String, let coords = g["coordinates"] as? [Any] else { return [] }
        func ring(_ a: [Any]) -> [CLLocationCoordinate2D] {
            a.compactMap { pt in
                guard let p = pt as? [Any], p.count >= 2, let lng = dbl(p[0]), let lat = dbl(p[1]) else { return nil }
                return CLLocationCoordinate2D(latitude: lat, longitude: lng)
            }
        }
        switch type {
        case "Polygon":
            return coords.compactMap { ($0 as? [Any]).map(ring) }
        case "MultiPolygon":
            var out: [[CLLocationCoordinate2D]] = []
            for poly in coords {
                guard let p = poly as? [Any] else { continue }
                for r in p { if let rr = r as? [Any] { out.append(ring(rr)) } }
            }
            return out
        default:
            return []
        }
    }

    private static func pointCoord(_ g: [String: Any]) -> CLLocationCoordinate2D? {
        guard g["type"] as? String == "Point", let c = g["coordinates"] as? [Any],
              c.count >= 2, let lng = dbl(c[0]), let lat = dbl(c[1]) else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    private static func nearestPoint(_ feats: [Feat], to c: CLLocationCoordinate2D) -> Feat? {
        var best: Feat?; var bd = Double.infinity
        for f in feats {
            guard let g = f.geometry, let p = pointCoord(g) else { continue }
            let dx = p.longitude - c.longitude, dy = p.latitude - c.latitude
            let d = dx * dx + dy * dy
            if d < bd { bd = d; best = f }
        }
        return best
    }

    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }
}
