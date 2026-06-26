//
//  OverzoomTileOverlay.swift
//  MKTileOverlay does NOT overzoom: past `maximumZ` the overlay simply stops
//  drawing, so a historic map vanishes the moment you zoom in past its deepest
//  rendered level — useless in the field. This subclass keeps the overlay visible
//  at ANY zoom: tiles up to `nativeMax` are served normally (R2/Worker/mapwarper);
//  for deeper tiles it crops the matching quadrant out of the `nativeMax` ancestor
//  tile and upscales it to 256px (blurrier, but present and correctly placed).
//

import MapKit
import UIKit

final class OverzoomTileOverlay: MKTileOverlay {
    let nativeMax: Int
    private lazy var session = URLSession(configuration: .default)

    init(urlTemplate: String?, nativeMax: Int) {
        self.nativeMax = nativeMax
        super.init(urlTemplate: urlTemplate)
    }

    override func loadTile(at path: MKTileOverlayPath,
                          result: @escaping (Data?, Error?) -> Void) {
        guard path.z > nativeMax else {           // within rendered range — serve directly
            super.loadTile(at: path, result: result)
            return
        }
        let dz = path.z - nativeMax
        let scale = 1 << dz                         // tiles-per-side of the ancestor this covers
        let ancestor = MKTileOverlayPath(x: path.x >> dz, y: path.y >> dz, z: nativeMax,
                                         contentScaleFactor: path.contentScaleFactor)
        let subX = path.x & (scale - 1)
        let subY = path.y & (scale - 1)
        session.dataTask(with: url(forTilePath: ancestor)) { data, _, err in
            guard let data, let img = UIImage(data: data) else { result(nil, err); return }
            let out = Self.crop(img, scale: scale, subX: subX, subY: subY)
            result(out, out == nil ? err : nil)
        }.resume()
    }

    /// Crop the (subX,subY) cell of a `scale`×`scale` grid out of `image` and
    /// upscale that cell to a full 256px tile.
    private static func crop(_ image: UIImage, scale: Int, subX: Int, subY: Int) -> Data? {
        guard let cg = image.cgImage else { return nil }
        let cellW = CGFloat(cg.width) / CGFloat(scale)
        let cellH = CGFloat(cg.height) / CGFloat(scale)
        let rect = CGRect(x: CGFloat(subX) * cellW, y: CGFloat(subY) * cellH, width: cellW, height: cellH)
        guard let sub = cg.cropping(to: rect) else { return nil }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256))
        let scaled = renderer.image { ctx in
            ctx.cgContext.interpolationQuality = .high
            UIImage(cgImage: sub).draw(in: CGRect(x: 0, y: 0, width: 256, height: 256))
        }
        return scaled.pngData()
    }
}
