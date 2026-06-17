//
//  StateHillshade.swift
//  "State LiDAR" hillshade — stitches state elevation services into one overlay
//  that's clean at every zoom.
//
//  NY's NYS_Statewide_Hillshade self-clips to New York (transparent everywhere
//  else, verified), so it's drawn as-is on top. NJ's NJ_10ft_HSD ImageServer,
//  by contrast, paints opaque gray well past NJ's land — over the Hudson, NY
//  Harbor, Raritan/Barnegat bays and into NY — which produced the rectangular
//  bleed artifacts. So each tile's NJ imagery is clipped to NJ's land outline
//  (Natural Earth, coastline-faithful) before NY is composited over it.
//
//  Result: each state's LiDAR shows only over its own land, NY and NJ meet at
//  the real border, and water reads as the basemap instead of gray blocks.
//  USGS 3DEP stays available as the national fallback source (OverlayFactory).
//

import Foundation
import MapKit
import UIKit

private let kMercR = 20037508.342789244

/// lat/lon → Web-Mercator metres.
private func mercator(_ lat: Double, _ lon: Double) -> (x: Double, y: Double) {
    (lon / 180 * kMercR, log(tan((90 + lat) * .pi / 360)) * kMercR / .pi)
}

private struct MBox {
    var minX, minY, maxX, maxY: Double
    func intersects(_ o: MBox) -> Bool {
        minX <= o.maxX && maxX >= o.minX && minY <= o.maxY && maxY >= o.minY
    }
}

final class StateHillshadeOverlay: MKTileOverlay {
    private let nyExport =
        "https://elevation.its.ny.gov/arcgis/rest/services/NYS_Statewide_Hillshade/MapServer/export"
    private let njExport =
        "https://maps.nj.gov/arcgis/rest/services/Elevation/NJ_10ft_HSD/ImageServer/exportImage"
    private let session = URLSession(configuration: .default)

    convenience init() { self.init(urlTemplate: nil) }
    override init(urlTemplate: String?) {
        super.init(urlTemplate: nil)
        tileSize = CGSize(width: 256, height: 256)
        canReplaceMapContent = false
        maximumZ = 19
    }

    // MARK: NJ land polygon (parsed once per overlay)

    private lazy var njRings: [[(x: Double, y: Double)]] =
        njLandRaw.split(separator: ";").map { ring in
            ring.split(separator: " ").compactMap { pair -> (x: Double, y: Double)? in
                let f = pair.split(separator: ",")
                guard f.count == 2, let lat = Double(f[0]), let lon = Double(f[1]) else { return nil }
                return mercator(lat, lon)
            }
        }

    private lazy var njBox: MBox = {
        let pts = njRings.flatMap { $0 }
        return MBox(minX: pts.map(\.x).min() ?? 0, minY: pts.map(\.y).min() ?? 0,
                    maxX: pts.map(\.x).max() ?? 0, maxY: pts.map(\.y).max() ?? 0)
    }()

    // NY state bounding box (generous; only gates whether to fetch NY).
    private let nyBox: MBox = {
        let sw = mercator(40.45, -79.85), ne = mercator(45.05, -71.80)
        return MBox(minX: sw.x, minY: sw.y, maxX: ne.x, maxY: ne.y)
    }()

    // MARK: tile geometry

    private func tileBox(_ p: MKTileOverlayPath) -> MBox {
        let n = Double(1 << p.z), world = kMercR * 2
        return MBox(minX: -kMercR + Double(p.x) / n * world,
                    minY:  kMercR - Double(p.y + 1) / n * world,
                    maxX: -kMercR + Double(p.x + 1) / n * world,
                    maxY:  kMercR - Double(p.y) / n * world)
    }

    private func exportURL(_ base: String, _ b: MBox) -> URL {
        var c = URLComponents(string: base)!
        c.queryItems = [
            .init(name: "bbox", value: "\(b.minX),\(b.minY),\(b.maxX),\(b.maxY)"),
            .init(name: "bboxSR", value: "3857"),
            .init(name: "imageSR", value: "3857"),
            .init(name: "size", value: "256,256"),
            .init(name: "format", value: "png32"),
            .init(name: "transparent", value: "true"),
            .init(name: "f", value: "image")
        ]
        return c.url!
    }

    /// NJ land outline as a clip path in this tile's pixel space (256×256).
    private func njClipPath(_ b: MBox) -> UIBezierPath {
        let path = UIBezierPath()
        let w = b.maxX - b.minX, h = b.maxY - b.minY
        for ring in njRings where ring.count > 2 {
            for (i, p) in ring.enumerated() {
                let pt = CGPoint(x: (p.x - b.minX) / w * 256,
                                 y: (b.maxY - p.y) / h * 256)
                if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
            path.close()
        }
        return path
    }

    // MARK: tile loading

    override func loadTile(at path: MKTileOverlayPath,
                           result: @escaping (Data?, Error?) -> Void) {
        let b = tileBox(path)
        let needNJ = b.intersects(njBox)
        let needNY = b.intersects(nyBox)
        guard needNJ || needNY else { result(nil, nil); return }

        var njData: Data?, nyData: Data?
        let group = DispatchGroup()
        if needNJ {
            group.enter()
            session.dataTask(with: exportURL(njExport, b)) { d, _, _ in
                njData = d; group.leave()
            }.resume()
        }
        if needNY {
            group.enter()
            session.dataTask(with: exportURL(nyExport, b)) { d, _, _ in
                nyData = d; group.leave()
            }.resume()
        }
        group.notify(queue: .global(qos: .userInitiated)) {
            // No NJ involved → NY self-clips, hand its tile back untouched.
            if !needNJ { result(nyData, nil); return }
            result(self.composite(njData: njData, nyData: nyData, box: b), nil)
        }
    }

    /// NJ clipped to its land outline, NY drawn over it.
    private func composite(njData: Data?, nyData: Data?, box b: MBox) -> Data? {
        let size = CGSize(width: 256, height: 256)
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1; fmt.opaque = false
        let rect = CGRect(origin: .zero, size: size)
        let img = UIGraphicsImageRenderer(size: size, format: fmt).image { rctx in
            if let d = njData, let nj = UIImage(data: d) {
                rctx.cgContext.saveGState()
                njClipPath(b).addClip()
                nj.draw(in: rect)
                rctx.cgContext.restoreGState()
            }
            if let d = nyData, let ny = UIImage(data: d) {
                ny.draw(in: rect)
            }
        }
        return img.pngData()
    }
}
