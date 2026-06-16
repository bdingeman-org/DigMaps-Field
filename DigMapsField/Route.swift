//
//  Route.swift
//  A saved route to follow on the historic map: a recorded GPX track or a
//  GeoJSON LineString the user dropped in. We don't invent turn-by-turn for
//  trackless terrain — we draw the line you already recorded and show how far
//  along it you are. That's the navigation story for old/abandoned roads.
//
//  Pure value types + static math so BOTH the phone UI (MapHomeView) and the
//  CarPlay scene use the exact same parsing and progress logic.
//

import Foundation
import MapKit
import CoreLocation

// MARK: - Parsed route geometry

struct Route {
    let name: String
    let coordinates: [CLLocationCoordinate2D]
    /// Cumulative ground distance (meters) at each coordinate; [0] == 0.
    let cumulative: [CLLocationDistance]

    init(name: String, coordinates: [CLLocationCoordinate2D]) {
        self.name = name
        self.coordinates = coordinates
        self.cumulative = RouteMath.cumulative(coordinates)
    }

    var totalMeters: CLLocationDistance { cumulative.last ?? 0 }

    var polyline: MKPolyline { MKPolyline(coordinates: coordinates, count: coordinates.count) }

    /// Region that frames the whole track (with a little margin).
    var boundsRegion: MKCoordinateRegion? {
        guard let first = coordinates.first else { return nil }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for c in coordinates {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                            longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.25, 0.005),
                                    longitudeDelta: max((maxLon - minLon) * 1.25, 0.005))
        return MKCoordinateRegion(center: center, span: span)
    }

    func progress(at loc: CLLocationCoordinate2D) -> RouteProgress? {
        RouteMath.progress(of: loc, along: coordinates, cum: cumulative)
    }

    // MARK: load from a file (extension-dispatched, sniff fallback)

    static func load(from url: URL) -> Route? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let fallback = url.deletingPathExtension().lastPathComponent
        switch url.pathExtension.lowercased() {
        case "gpx":              return GPXParser.parse(data, fallbackName: fallback)
        case "geojson", "json":  return parseGeoJSON(data, fallbackName: fallback)
        default:
            return GPXParser.parse(data, fallbackName: fallback)
                ?? parseGeoJSON(data, fallbackName: fallback)
        }
    }

    // MARK: GeoJSON (LineString / MultiLineString, raw / Feature / FeatureCollection)

    static func parseGeoJSON(_ data: Data, fallbackName: String) -> Route? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var coords: [CLLocationCoordinate2D] = []

        func pt(_ a: [Double]) -> CLLocationCoordinate2D? {
            a.count >= 2 ? .init(latitude: a[1], longitude: a[0]) : nil
        }
        func handle(_ g: [String: Any]) {
            guard let type = g["type"] as? String else { return }
            switch type {
            case "LineString":
                if let cs = g["coordinates"] as? [[Double]] { coords += cs.compactMap(pt) }
            case "MultiLineString":
                if let mls = g["coordinates"] as? [[[Double]]] { for line in mls { coords += line.compactMap(pt) } }
            case "GeometryCollection":
                if let gs = g["geometries"] as? [[String: Any]] { gs.forEach(handle) }
            default:
                break
            }
        }

        let type = obj["type"] as? String
        if type == "FeatureCollection", let feats = obj["features"] as? [[String: Any]] {
            for f in feats { if let g = f["geometry"] as? [String: Any] { handle(g) } }
        } else if type == "Feature", let g = obj["geometry"] as? [String: Any] {
            handle(g)
        } else {
            handle(obj)
        }

        guard coords.count >= 2 else { return nil }
        let name = ((obj["features"] as? [[String: Any]])?.first?["properties"] as? [String: Any])?["name"] as? String
        return Route(name: name ?? fallbackName, coordinates: coords)
    }
}

// MARK: - GPX parser (track / route / waypoint, in that preference order)

final class GPXParser: NSObject, XMLParserDelegate {
    private var trk: [CLLocationCoordinate2D] = []
    private var rte: [CLLocationCoordinate2D] = []
    private var wpt: [CLLocationCoordinate2D] = []
    private var name: String?
    private var capturingName = false
    private var nameBuf = ""

    static func parse(_ data: Data, fallbackName: String) -> Route? {
        let d = GPXParser()
        let parser = XMLParser(data: data)
        parser.delegate = d
        guard parser.parse() else { return nil }
        let coords = !d.trk.isEmpty ? d.trk : (!d.rte.isEmpty ? d.rte : d.wpt)
        guard coords.count >= 2 else { return nil }
        return Route(name: d.name ?? fallbackName, coordinates: coords)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "trkpt", "rtept", "wpt":
            if let la = Double(attributeDict["lat"] ?? ""), let lo = Double(attributeDict["lon"] ?? "") {
                let c = CLLocationCoordinate2D(latitude: la, longitude: lo)
                switch elementName {
                case "trkpt": trk.append(c)
                case "rtept": rte.append(c)
                default:      wpt.append(c)
                }
            }
        case "name":
            if name == nil { capturingName = true; nameBuf = "" }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturingName { nameBuf += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "name", capturingName {
            let t = nameBuf.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { name = t }
            capturingName = false
        }
    }
}

// MARK: - Progress along the track

struct RouteProgress {
    let traveled: CLLocationDistance
    let remaining: CLLocationDistance
    let total: CLLocationDistance
    /// Perpendicular distance from the user to the nearest point on the track.
    let offRoute: CLLocationDistance
    var fraction: Double { total > 0 ? min(1, max(0, traveled / total)) : 0 }
}

enum RouteMath {
    static func cumulative(_ pts: [CLLocationCoordinate2D]) -> [CLLocationDistance] {
        guard !pts.isEmpty else { return [] }
        var acc: [CLLocationDistance] = [0]
        acc.reserveCapacity(pts.count)
        for i in 1..<pts.count {
            let d = CLLocation(latitude: pts[i-1].latitude, longitude: pts[i-1].longitude)
                .distance(from: CLLocation(latitude: pts[i].latitude, longitude: pts[i].longitude))
            acc.append(acc[i-1] + d)
        }
        return acc
    }

    /// Project the user onto the nearest segment in a local equirectangular plane
    /// (accurate to well under a meter at the few-km scale of a recorded track).
    static func progress(of loc: CLLocationCoordinate2D,
                         along pts: [CLLocationCoordinate2D],
                         cum: [CLLocationDistance]) -> RouteProgress? {
        guard pts.count >= 2, cum.count == pts.count else { return nil }
        let mPerDegLat = 111_320.0
        let mPerDegLon = 111_320.0 * cos(loc.latitude * .pi / 180)
        func xy(_ c: CLLocationCoordinate2D) -> (Double, Double) {
            ((c.longitude - loc.longitude) * mPerDegLon, (c.latitude - loc.latitude) * mPerDegLat)
        }

        var bestDist = Double.greatestFiniteMagnitude
        var bestTraveled = 0.0
        for i in 1..<pts.count {
            let a = xy(pts[i-1]), b = xy(pts[i])
            let abx = b.0 - a.0, aby = b.1 - a.1
            let len2 = abx*abx + aby*aby
            // user is at the origin; project origin onto segment a→b
            let t = len2 > 0 ? max(0, min(1, -(a.0*abx + a.1*aby) / len2)) : 0
            let px = a.0 + t*abx, py = a.1 + t*aby
            let dist = (px*px + py*py).squareRoot()
            if dist < bestDist {
                bestDist = dist
                bestTraveled = cum[i-1] + t * (cum[i] - cum[i-1])
            }
        }

        let total = cum.last ?? 0
        return RouteProgress(traveled: bestTraveled,
                             remaining: max(0, total - bestTraveled),
                             total: total,
                             offRoute: bestDist)
    }
}
