//
//  DigMapsFieldApp.swift
//  DigMaps Field — your live GPS dot on a map DigMaps (web) baked.
//
//  Companion to the DigMaps browser georeferencer. The desktop does the
//  georeferencing; this app does the half a phone is good at: stand in a
//  field, see where you are on the 1866 Beers. Fully offline once a map
//  is imported.
//

import SwiftUI

@main
struct DigMapsFieldApp: App {
    @StateObject private var store = MapStore()
    @StateObject private var routes = RouteStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(routes)
                // AirDrop / Files "Open with DigMaps Field" lands here —
                // GPX/GeoJSON tracks go to the route library, everything else
                // (MBTiles) to the map library.
                .onOpenURL { url in
                    if ["gpx", "geojson", "json"].contains(url.pathExtension.lowercased()) {
                        routes.importRoute(from: url)
                    } else {
                        store.importMap(from: url)
                    }
                }
        }
    }
}
