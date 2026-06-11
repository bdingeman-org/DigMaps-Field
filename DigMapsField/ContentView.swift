//
//  ContentView.swift
//  Library: imported MBTiles (offline) + the bundled online overlay catalog.
//

import SwiftUI
import MapKit
import UniformTypeIdentifiers

private let mbtilesType = UTType(importedAs: "org.digmaps.mbtiles")

struct ContentView: View {
    @EnvironmentObject private var store: MapStore
    @StateObject private var location = LocationManager()
    @State private var showImporter = false

    private var catalog: OverlayCatalog? { OverlayCatalog.shared }

    var body: some View {
        NavigationStack {
            List {
                myMapsSection
                onlineHistoricSection
                aerialSection
            }
            .navigationTitle("DigMaps Field")
            .toolbar {
                Button {
                    showImporter = true
                } label: {
                    Label("Import map", systemImage: "plus")
                }
            }
            .navigationDestination(for: OverlaySource.self) { source in
                MapScreen(source: source, fitRegion: fitRegion(for: source))
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
            .refreshable { store.refresh() }
        }
    }

    // MARK: sections

    private var myMapsSection: some View {
        Section("My maps — offline") {
            if store.maps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No imported maps yet.")
                    Text("Bake one in DigMaps on the desktop → **Export MBTiles (phone)** → AirDrop it here, or tap **+**.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(store.maps) { map in
                NavigationLink(value: OverlaySource.mbtiles(map)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(map.name).font(.headline)
                        Text(String(format: "%.1f MB · offline", map.sizeMB))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { idx in
                let doomed = idx.map { store.maps[$0] }
                for map in doomed { store.delete(map) }
            }
        }
    }

    @ViewBuilder
    private var onlineHistoricSection: some View {
        if let catalog {
            Section {
                if let here = location.here {
                    let maps = catalog.historic(at: here)
                    if maps.isEmpty {
                        Text("No catalogued historic maps cover this spot.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(maps) { m in
                        NavigationLink(value: OverlaySource.xyz(
                            name: "\(m.yearLabel) · \(m.atlas)",
                            template: catalog.template(for: m),
                            attribution: "Allmaps / \(m.src)",
                            maxZ: 16
                        )) {
                            HStack {
                                Text(m.yearLabel).font(.headline).monospacedDigit()
                                VStack(alignment: .leading) {
                                    Text(m.atlas).lineLimit(1)
                                    Text(m.src).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } else {
                    Label("Waiting for location…", systemImage: "location")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Historic maps near me — online")
            } footer: {
                Text("Streamed from the Allmaps tile server — needs cell signal. Same curated set as DigMaps desktop.")
            }
        }
    }

    @ViewBuilder
    private var aerialSection: some View {
        if let catalog, let years = catalog.aerials["NYS orthos"] {
            Section {
                ForEach(years) { a in
                    NavigationLink(value: OverlaySource.xyz(
                        name: "Aerial · \(a.name)",
                        template: a.template,
                        attribution: a.attribution,
                        maxZ: a.maxZ
                    )) {
                        Label(a.name, systemImage: "airplane")
                    }
                }
            } header: {
                Text("NYS aerial years — online")
            } footer: {
                Text("NYS ITS Geospatial Services. Coverage varies by year — blank means that year wasn't flown here.")
            }
        }
    }

    /// Online historic maps fly to their footprint; aerials open at your location.
    private func fitRegion(for source: OverlaySource) -> MKCoordinateRegion? {
        guard case .xyz(let name, _, _, _) = source else { return nil }
        if let catalog, let m = catalog.maps.first(where: { name.contains($0.atlas) && name.contains($0.yearLabel) }), m.b.count == 4 {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: (m.b[1]+m.b[3])/2, longitude: (m.b[0]+m.b[2])/2),
                span: MKCoordinateSpan(latitudeDelta: (m.b[3]-m.b[1])*1.2, longitudeDelta: (m.b[2]-m.b[0])*1.2))
        }
        if let here = location.here {
            return MKCoordinateRegion(
                center: here,
                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02))
        }
        return nil
    }
}
