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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                // AirDrop / Files "Open with DigMaps Field" lands here
                .onOpenURL { url in
                    store.importMap(from: url)
                }
        }
    }
}
