//
//  StateHillshade.swift
//  "State LiDAR" hillshade — stitches multiple states' LiDAR hillshade services
//  into one overlay that's clean at every zoom.
//
//  Each state publishes its own service. Most self-clip to their border (return
//  transparent outside, verified), so they're simply layered. Two exceptions are
//  handled per tile:
//    • NJ (NJ_10ft_HSD) paints opaque gray past its land — over the Hudson, NY
//      Harbor and bays — so its imagery is clipped to NJ's coastline outline.
//    • MA uses MassGIS LiDAR_ShadedRelief (already pure grey LiDAR hillshade).
//      (The old LiDAR_Elevation_Hillshade service became a colored elevation blend.)
//
//  Sources (all verified live 2026-06-17):
//    NY  NYS_Statewide_Hillshade  MapServer /export        ~1m   dynamic
//    NJ  NJ_10ft_HSD              ImageServer /exportImage  ~3m   dynamic, clip
//    VT  VCGI LIDARHILLSHD cache  ImageServer /tile         0.7m  cached
//    NH  GRANIT NW bare-earth     ImageServer /exportImage  0.76m dynamic
//    MA  MassGIS LiDAR_ShadedRelief MapServer /tile          ~1m   cached, grey
//    PA  PASDA PAMAP_Hillshade    MapServer /export         ~1m   dynamic
//    CT  CT ECO Hillshade (3857)  ImageServer /exportImage  0.61m dynamic
//
//  USGS 3DEP stays selectable as the national fallback (OverlayFactory).
//

import Foundation
import MapKit
import UIKit
import CoreImage

private let kMercR = 20037508.342789244

private func mercator(_ lat: Double, _ lon: Double) -> (x: Double, y: Double) {
    (lon / 180 * kMercR, log(tan((90 + lat) * .pi / 360)) * kMercR / .pi)
}

private struct MBox {
    var minX, minY, maxX, maxY: Double
    func intersects(_ o: MBox) -> Bool {
        minX <= o.maxX && maxX >= o.minX && minY <= o.maxY && maxY >= o.minY
    }
    static func latLon(_ s: Double, _ w: Double, _ n: Double, _ e: Double) -> MBox {
        let a = mercator(s, w), b = mercator(n, e)
        return MBox(minX: a.x, minY: a.y, maxX: b.x, maxY: b.y)
    }
}

private enum HSKind {
    case tiled(base: String)                       // 3857 cache, /tile/{z}/{y}/{x}
    case export(base: String, op: String, rule: String?)  // /export or /exportImage
}

private struct HSLayer {
    let name: String
    let kind: HSKind
    let bbox: MBox        // gates whether this service is fetched for a tile
    let clip: String?     // land-outline polygon to clip to (services that bleed); nil = self-clipping
    let desaturate: Bool  // grayscale the tile (MA's colored cache only)
}

final class StateHillshadeOverlay: MKTileOverlay {
    private let session: URLSession
    private static let ci = CIContext()

    private static let layers: [HSLayer] = [
        // — Northeast (shipped first) —
        HSLayer(name: "NY", kind: .export(base: "https://elevation.its.ny.gov/arcgis/rest/services/NYS_Statewide_Hillshade/MapServer", op: "export", rule: nil),
                bbox: .latLon(40.48, -79.77, 45.02, -71.85), clip: nil, desaturate: false),
        HSLayer(name: "NJ", kind: .export(base: "https://maps.nj.gov/arcgis/rest/services/Elevation/NJ_10ft_HSD/ImageServer", op: "exportImage", rule: nil),
                bbox: .latLon(38.92, -75.58, 41.36, -73.89), clip: njLandRaw, desaturate: false),
        HSLayer(name: "VT", kind: .tiled(base: "https://maps.vcgi.vermont.gov/arcgis/rest/services/EGC_services/IMG_VCGI_LIDARHILLSHD_WM_CACHE_v1/ImageServer"),
                bbox: .latLon(42.72, -73.44, 45.02, -71.46), clip: nil, desaturate: false),
        HSLayer(name: "NH", kind: .export(base: "https://nhgeodata.unh.edu/image/rest/services/ImageServices/LiDAR_Bare_Earth_NW_HS_NH_2022_img/ImageServer", op: "exportImage", rule: nil),
                bbox: .latLon(42.69, -72.56, 45.31, -70.70), clip: nil, desaturate: false),
        HSLayer(name: "MA", kind: .tiled(base: "https://tiles.arcgis.com/tiles/hGdibHYSPO59RG1h/arcgis/rest/services/LiDAR_ShadedRelief/MapServer"),
                bbox: .latLon(41.23, -73.51, 42.89, -69.86), clip: nil, desaturate: false),
        HSLayer(name: "PA", kind: .export(base: "https://imagery.pasda.psu.edu/arcgis/rest/services/pasda/PAMAP_Hillshade/MapServer", op: "export", rule: nil),
                bbox: .latLon(39.71, -80.52, 42.27, -74.69), clip: nil, desaturate: false),
        HSLayer(name: "CT", kind: .export(base: "https://cteco.uconn.edu/ctraster/rest/services/elevation/Hillshade/ImageServer", op: "exportImage", rule: nil),
                bbox: .latLon(40.98, -73.73, 42.05, -71.78), clip: nil, desaturate: false),
        // — adjacent expansion —
        HSLayer(name: "ME", kind: .export(base: "https://gis.maine.gov/image/rest/services/DEM/Maine_Elevation_DEM_Statewide/ImageServer", op: "exportImage", rule: #"{"rasterFunction":"Hillshade"}"#),
                bbox: .latLon(43.06, -71.08, 47.46, -66.95), clip: nil, desaturate: false),
        HSLayer(name: "RI", kind: .export(base: "https://maps.edc.uri.edu/arcgis/rest/services/Atlas_elevation/TopoBathy/MapServer", op: "export", rule: nil),
                bbox: .latLon(41.15, -71.86, 42.02, -71.12), clip: nil, desaturate: false),
        HSLayer(name: "DE", kind: .export(base: "https://imagery.firstmap.delaware.gov/imagery/rest/services/Elevation_SP/DE_Lidar_DEM/ImageServer", op: "exportImage", rule: #"{"rasterFunction":"Lidar DEM Hillshade"}"#),
                bbox: .latLon(38.45, -75.79, 39.84, -75.05), clip: nil, desaturate: false),
        HSLayer(name: "MD", kind: .export(base: "https://mdgeodata.md.gov/lidar/rest/services/Statewide/MD_statewide_hillshade_m/ImageServer", op: "exportImage", rule: nil),
                bbox: .latLon(37.89, -79.49, 39.72, -75.05), clip: nil, desaturate: false),
        HSLayer(name: "WV", kind: .tiled(base: "https://services.wvgis.wvu.edu/arcgis/rest/services/Elevation/wv_hillshade_1m_mosaic/MapServer"),
                bbox: .latLon(37.20, -82.64, 40.64, -77.72), clip: nil, desaturate: false),
        HSLayer(name: "OH", kind: .export(base: "https://gis.ohiodnr.gov/image/rest/services/OH_DEM_test/ImageServer", op: "exportImage", rule: #"{"rasterFunction":"Hillshade"}"#),
                bbox: .latLon(38.40, -84.82, 41.98, -80.52), clip: nil, desaturate: false),
        HSLayer(name: "KY", kind: .export(base: "https://kyraster.ky.gov/arcgis/rest/services/ElevationServices/Ky_DEM_KYAPED_5FT_Hillshade/ImageServer", op: "exportImage", rule: nil),
                bbox: .latLon(36.50, -89.57, 39.15, -81.96), clip: nil, desaturate: false),
        HSLayer(name: "IN", kind: .export(base: "https://di-ingov.img.arcgis.com/arcgis/rest/services/DynamicWebMercator/Indiana_2016_2020_DEM/ImageServer", op: "exportImage", rule: #"{"rasterFunction":"GrayscaleHillshade"}"#),
                bbox: .latLon(37.77, -88.10, 41.76, -84.78), clip: nil, desaturate: false),
        HSLayer(name: "NC", kind: .export(base: "https://services.nconemap.gov/secure/rest/services/Elevation/DEM20ft_Hillshade/ImageServer", op: "exportImage", rule: nil),
                bbox: .latLon(33.84, -84.32, 36.59, -75.46), clip: nil, desaturate: false),
        // VA has no state hillshade service → USGS 3DEP (national), clipped to VA so it doesn't bleed into neighbors.
        HSLayer(name: "VA", kind: .export(base: "https://elevation.nationalmap.gov/arcgis/rest/services/3DEPElevation/ImageServer", op: "exportImage", rule: #"{"rasterFunction":"Hillshade Gray"}"#),
                bbox: .latLon(36.54, -83.68, 39.47, -75.24), clip: vaLandRaw, desaturate: false),
    ]

    /// Parsed clip polygons (Web-Mercator), keyed by layer name. Built once.
    private static let clipRings: [String: [[(x: Double, y: Double)]]] = {
        var rings: [String: [[(x: Double, y: Double)]]] = [:]
        for layer in StateHillshadeOverlay.layers where layer.clip != nil {
            rings[layer.name] = StateHillshadeOverlay.parseRings(layer.clip!)
        }
        return rings
    }()

    private static func parseRings(_ raw: String) -> [[(x: Double, y: Double)]] {
        raw.split(separator: ";").map { ring in
            ring.split(separator: " ").compactMap { pair -> (x: Double, y: Double)? in
                let f = pair.split(separator: ",")
                guard f.count == 2, let lat = Double(f[0]), let lon = Double(f[1]) else { return nil }
                return mercator(lat, lon)
            }
        }
    }

    convenience init() { self.init(urlTemplate: nil) }
    override init(urlTemplate: String?) {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 25
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: cfg)
        super.init(urlTemplate: nil)
        tileSize = CGSize(width: 256, height: 256)
        canReplaceMapContent = false
        maximumZ = 19
    }

    // MARK: geometry

    private func tileBox(_ p: MKTileOverlayPath) -> MBox {
        let n = Double(1 << p.z), world = kMercR * 2
        return MBox(minX: -kMercR + Double(p.x) / n * world,
                    minY:  kMercR - Double(p.y + 1) / n * world,
                    maxX: -kMercR + Double(p.x + 1) / n * world,
                    maxY:  kMercR - Double(p.y) / n * world)
    }

    private func tileURL(_ layer: HSLayer, _ p: MKTileOverlayPath) -> URL {
        switch layer.kind {
        case .tiled(let base):
            return URL(string: "\(base)/tile/\(p.z)/\(p.y)/\(p.x)")!
        case .export(let base, let op, let rule):
            let b = tileBox(p)
            var c = URLComponents(string: "\(base)/\(op)")!
            var items: [URLQueryItem] = [
                .init(name: "bbox", value: "\(b.minX),\(b.minY),\(b.maxX),\(b.maxY)"),
                .init(name: "bboxSR", value: "3857"),
                .init(name: "imageSR", value: "3857"),
                .init(name: "size", value: "256,256"),
                .init(name: "format", value: "png32"),
                .init(name: "transparent", value: "true"),
                .init(name: "f", value: "image")
            ]
            if let rule { items.append(.init(name: "renderingRule", value: rule)) }
            c.queryItems = items
            return c.url!
        }
    }

    /// A clip layer's land outline as a path in this tile's pixel space (256×256).
    private func clipPath(_ rings: [[(x: Double, y: Double)]], _ b: MBox) -> UIBezierPath {
        let path = UIBezierPath()
        let w = b.maxX - b.minX, h = b.maxY - b.minY
        for ring in rings where ring.count > 2 {
            for (i, p) in ring.enumerated() {
                let pt = CGPoint(x: (p.x - b.minX) / w * 256, y: (b.maxY - p.y) / h * 256)
                if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
            path.close()
        }
        return path
    }

    private func grayscale(_ img: UIImage) -> UIImage {
        guard let cg = img.cgImage else { return img }
        let out = CIImage(cgImage: cg).applyingFilter("CIColorControls",
                                                      parameters: [kCIInputSaturationKey: 0])
        guard let rendered = Self.ci.createCGImage(out, from: out.extent) else { return img }
        return UIImage(cgImage: rendered)
    }

    // MARK: fetching

    /// Retries once on transport error / 5xx (helps zoomed-out large-bbox
    /// exports that occasionally time out). 404 / non-200 → nil (no tile here).
    private func fetch(_ url: URL, retry: Int = 1, done: @escaping (Data?) -> Void) {
        session.dataTask(with: url) { [weak self] d, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (err != nil || code >= 500), retry > 0, let self {
                self.fetch(url, retry: retry - 1, done: done); return
            }
            done(code == 200 ? d : nil)
        }.resume()
    }

    // MARK: tile loading

    override func loadTile(at path: MKTileOverlayPath,
                           result: @escaping (Data?, Error?) -> Void) {
        let b = tileBox(path)
        let active = Self.layers.filter { $0.bbox.intersects(b) }
        guard !active.isEmpty else { result(nil, nil); return }

        // Fast path: a single plain service → hand its tile back untouched.
        if active.count == 1, active[0].clip == nil, !active[0].desaturate {
            fetch(tileURL(active[0], path)) { result($0, nil) }
            return
        }

        var datas: [String: Data] = [:]
        let lock = NSLock()
        let group = DispatchGroup()
        for layer in active {
            group.enter()
            fetch(tileURL(layer, path)) { d in
                if let d { lock.lock(); datas[layer.name] = d; lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .global(qos: .userInitiated)) {
            result(self.composite(active, datas, b), nil)
        }
    }

    private func composite(_ active: [HSLayer], _ datas: [String: Data], _ b: MBox) -> Data? {
        let size = CGSize(width: 256, height: 256)
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1; fmt.opaque = false
        let rect = CGRect(origin: .zero, size: size)
        let img = UIGraphicsImageRenderer(size: size, format: fmt).image { rctx in
            for layer in active {
                guard let d = datas[layer.name], var image = UIImage(data: d) else { continue }
                if layer.desaturate { image = grayscale(image) }
                if layer.clip != nil, let rings = Self.clipRings[layer.name] {
                    rctx.cgContext.saveGState()
                    clipPath(rings, b).addClip()
                    image.draw(in: rect)
                    rctx.cgContext.restoreGState()
                } else {
                    image.draw(in: rect)
                }
            }
        }
        return img.pngData()
    }
}
