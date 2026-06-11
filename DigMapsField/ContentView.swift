//
//  ContentView.swift
//  Map library: list of imported MBTiles, import button, empty state.
//

import SwiftUI
import UniformTypeIdentifiers

private let mbtilesType = UTType(importedAs: "org.digmaps.mbtiles")

struct ContentView: View {
    @EnvironmentObject private var store: MapStore
    @State private var showImporter = false

    var body: some View {
        NavigationStack {
            Group {
                if store.maps.isEmpty {
                    emptyState
                } else {
                    mapList
                }
            }
            .navigationTitle("DigMaps Field")
            .toolbar {
                Button {
                    showImporter = true
                } label: {
                    Label("Import map", systemImage: "plus")
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [mbtilesType, .data],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    for url in urls { store.importMap(from: url) }
                }
            }
            .alert(
                "Import failed",
                isPresented: Binding(
                    get: { store.lastError != nil },
                    set: { if !$0 { store.lastError = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(store.lastError ?? "")
            }
        }
    }

    private var mapList: some View {
        List {
            ForEach(store.maps) { map in
                NavigationLink(value: map.id) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(map.name).font(.headline)
                        Text(String(format: "%.1f MB", map.sizeMB))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { idx in
                // snapshot first — delete() mutates maps mid-iteration
                let doomed = idx.map { store.maps[$0] }
                for map in doomed { store.delete(map) }
            }
        }
        .navigationDestination(for: String.self) { id in
            if let map = store.maps.first(where: { $0.id == id }) {
                MapScreen(map: map)
            }
        }
        // @Sendable closure doesn't inherit MainActor — the await is required
        .refreshable { await store.refresh() }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No maps yet", systemImage: "map")
        } description: {
            Text("""
            Bake a map in DigMaps on the desktop, use **Export MBTiles (phone)**, \
            then AirDrop the file here — or tap + to pick one from Files/iCloud Drive.
            """)
        } actions: {
            Button("Import a map") { showImporter = true }
                .buttonStyle(.borderedProminent)
        }
    }
}
