//
//  MBTilesOverlay.swift
//  MKTileOverlay subclass that serves tiles straight out of an MBTiles
//  SQLite file using the system SQLite3 C library — zero dependencies.
//
//  MBTiles stores rows in TMS order (y flipped, increasing northward);
//  MapKit asks in XYZ — hence the (2^z - 1 - y) flip in loadTile.
//  DigMaps (web) bakes EPSG:3857 tiles with a full zoom pyramid, which is
//  exactly MapKit's native tiling, so alignment is 1:1.
//

import Foundation
import MapKit
import SQLite3

final class MBTilesOverlay: MKTileOverlay {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "org.digmaps.field.mbtiles")
    /// Geographic bounds from the metadata table (w, s, e, n) — used to frame the map.
    private(set) var boundsRegion: MKCoordinateRegion?
    private var boundsMapRect: MKMapRect = .world

    init?(fileURL: URL) {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(fileURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let handle else {
            return nil
        }
        db = handle
        super.init(urlTemplate: nil)
        tileSize = CGSize(width: 256, height: 256)
        canReplaceMapContent = false
        guard readMetadata() else {
            sqlite3_close(handle)
            db = nil
            return nil
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    override var boundingMapRect: MKMapRect { boundsMapRect }

    /// Pull minzoom/maxzoom/bounds from the metadata table. Returns false if
    /// the file has no tiles table (i.e. isn't a usable MBTiles).
    private func readMetadata() -> Bool {
        guard scalarInt("SELECT COUNT(*) FROM tiles") != nil else { return false }

        if let mn = scalarText("SELECT value FROM metadata WHERE name = 'minzoom'"),
           let z = Int(mn) { minimumZ = z }
        if let mx = scalarText("SELECT value FROM metadata WHERE name = 'maxzoom'"),
           let z = Int(mx) { maximumZ = z }

        if let b = scalarText("SELECT value FROM metadata WHERE name = 'bounds'") {
            let p = b.split(separator: ",").compactMap { Double($0) }
            if p.count == 4 {
                let sw = CLLocationCoordinate2D(latitude: p[1], longitude: p[0])
                let ne = CLLocationCoordinate2D(latitude: p[3], longitude: p[2])
                boundsRegion = MKCoordinateRegion(
                    center: CLLocationCoordinate2D(
                        latitude: (p[1] + p[3]) / 2, longitude: (p[0] + p[2]) / 2),
                    span: MKCoordinateSpan(
                        latitudeDelta: (p[3] - p[1]) * 1.2, longitudeDelta: (p[2] - p[0]) * 1.2)
                )
                let pSW = MKMapPoint(sw), pNE = MKMapPoint(ne)
                boundsMapRect = MKMapRect(
                    x: min(pSW.x, pNE.x), y: min(pSW.y, pNE.y),
                    width: abs(pNE.x - pSW.x), height: abs(pNE.y - pSW.y))
            }
        }
        return true
    }

    override func loadTile(at path: MKTileOverlayPath,
                           result: @escaping (Data?, Error?) -> Void) {
        queue.async { [weak self] in
            guard let self, let db = self.db else {
                result(nil, nil)
                return
            }
            let tmsY = (1 << path.z) - 1 - path.y
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(
                db,
                "SELECT tile_data FROM tiles WHERE zoom_level = ? AND tile_column = ? AND tile_row = ?",
                -1, &stmt, nil) == SQLITE_OK else {
                result(nil, nil)
                return
            }
            sqlite3_bind_int(stmt, 1, Int32(path.z))
            sqlite3_bind_int(stmt, 2, Int32(path.x))
            sqlite3_bind_int(stmt, 3, Int32(tmsY))
            if sqlite3_step(stmt) == SQLITE_ROW,
               let blob = sqlite3_column_blob(stmt, 0) {
                let len = Int(sqlite3_column_bytes(stmt, 0))
                result(Data(bytes: blob, count: len), nil)
            } else {
                result(nil, nil) // no tile here — MapKit shows what's underneath
            }
        }
    }

    // MARK: - tiny SQLite helpers

    private func scalarText(_ sql: String) -> String? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW,
              let c = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: c)
    }

    private func scalarInt(_ sql: String) -> Int? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(stmt, 0))
    }
}
