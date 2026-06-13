//
//  MapHomeView.swift
//  Web-parity home: the MAP is the app. Navigate the basemap, pick an overlay
//  source (Old map | LIDAR | Aerial | Historic) exactly like DigMaps web's
//  Overlay section, fade it with the eye + slider. "Near me" lists live in
//  picker sheets. Workshop theme throughout.
//

import SwiftUI
import MapKit
import CoreLocation

/// Asks for when-in-use authorization; MKMapView draws the blue dot itself.
final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    @Published var denied = false
    @Published var here: CLLocationCoordinate2D?

    override init() {
        super.init()
        manager.delegate = self
        manager.requestWhenInUseAuthorization()
        manager.requestLocation()
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        denied = manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted
        if manager.authorizationStatus == .authorizedWhenInUse { manager.requestLocation() }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        here = locs.last?.coordinate
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

enum SrcKind: String, CaseIterable, Identifiable {
    case oldmap = "Old map", lidar = "LIDAR", aerial = "Aerial", hist = "Historic"
    var id: String { rawValue }
}

private let NYS_HILLSHADE = "https://elevation.its.ny.gov/arcgis/rest/services/NYS_Statewide_Hillshade/MapServer"

struct MapHomeView: View {
    @EnvironmentObject private var store: MapStore
    @StateObject private var location = LocationManager()
    @StateObject private var search = PlaceSearch()

    @State private var src: SrcKind = .oldmap
    @State private var overlayOn = false          // eye — off by default, like web
    @State private var opacity = 0.8
    @State private var basemapSat = false         // ◑ basemap toggle
    @State private var fitToken = 0
    @State private var trackMode = 0

    @State private var selectedFile: MapFile?
    @State private var aerialYear: CatalogAerial?
    @State private var selectedHist: CatalogHistoricMap?

    @State private var viewRegion: MKCoordinateRegion?
    @State private var searchPin: CLLocationCoordinate2D?
    @State private var searchToken = 0
    @FocusState private var searchFieldFocused: Bool
    @State private var showHistSheet = false
    @State private var showFileSheet = false
    @State private var showImporter = false

    private var catalog: OverlayCatalog? { OverlayCatalog.shared }

    // MARK: current overlay

    private var overlayKey: String {
        guard overlayOn else { return "none" }
        switch src {
        case .oldmap: return "file-" + (selectedFile?.id ?? "none")
        case .lidar:  return "lidar"
        case .aerial: return "aerial-" + (aerialYear?.id ?? "none")
        case .hist:   return "hist-" + (selectedHist?.id ?? "none")
        }
    }

    private func buildOverlay() -> MKTileOverlay? {
        guard overlayOn else { return nil }
        switch src {
        case .oldmap:
            guard let f = selectedFile ?? store.maps.first else { return nil }
            return MBTilesOverlay(fileURL: f.url)
        case .lidar:
            return EsriExportOverlay(exportBase: NYS_HILLSHADE)
        case .aerial:
            guard let a = aerialYear ?? catalog?.aerials["NYS orthos"]?.last else { return nil }
            let o = MKTileOverlay(urlTemplate: a.template)
            o.canReplaceMapContent = false
            o.maximumZ = a.maxZ
            return o
        case .hist:
            guard let m = selectedHist, let catalog else { return nil }
            let o = MKTileOverlay(urlTemplate: catalog.template(for: m))
            o.canReplaceMapContent = false
            o.maximumZ = 16
            return o
        }
    }

    private var fitRegion: MKCoordinateRegion? {
        if overlayOn, src == .oldmap,
           let f = selectedFile ?? store.maps.first,
           let mb = MBTilesOverlay(fileURL: f.url) {
            return mb.boundsRegion
        }
        if overlayOn, src == .hist, let m = selectedHist, m.b.count == 4 {
            return MKCoordinateRegion(
                center: .init(latitude: (m.b[1]+m.b[3])/2, longitude: (m.b[0]+m.b[2])/2),
                span: .init(latitudeDelta: (m.b[3]-m.b[1])*1.2, longitudeDelta: (m.b[2]-m.b[0])*1.2))
        }
        if let here = location.here {
            return MKCoordinateRegion(center: here, span: .init(latitudeDelta: 0.02, longitudeDelta: 0.02))
        }
        return nil
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            BaseMapView(
                overlayKey: overlayKey, buildOverlay: buildOverlay,
                opacity: opacity, satellite: basemapSat,
                fitRegion: fitRegion, fitToken: fitToken, trackMode: trackMode,
                searchPin: searchPin, searchToken: searchToken,
                onRegionChange: { viewRegion = $0; search.updateRegion($0) }
            )
            .ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Spacer()
                panel
            }
        }
        .onOpenURL { store.importMap(from: $0) }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                for url in urls { store.importMap(from: url) }
                if selectedFile == nil { selectedFile = store.maps.first }
            }
        }
        .sheet(isPresented: $showHistSheet) { histSheet }
        .sheet(isPresented: $showFileSheet) { fileSheet }
        .alert("Import failed", isPresented: Binding(
            get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(store.lastError ?? "") }
        .preferredColorScheme(.dark)
    }

    // MARK: chrome

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                CoilMark(size: 21)
                Wordmark(size: 15)
                Spacer()
                Button { basemapSat.toggle() } label: {
                    Image(systemName: basemapSat ? "globe.americas.fill" : "circle.lefthalf.filled")
                        .foregroundStyle(Workshop.gold)
                }
                .accessibilityLabel("Toggle satellite basemap")
            }
            .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 6)
            searchBar
        }
        .background(Workshop.band.opacity(0.92))
    }

    // MARK: search (web "Jump to place" parity)

    private var searchBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Workshop.creamDim)
                TextField("Jump to place or lat, lng", text: $search.query)
                    .font(Workshop.mono(13)).foregroundStyle(Workshop.cream)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($searchFieldFocused)
                    .onChange(of: search.query) { _, v in search.update(v) }
                    .onSubmit(runSearch)
                if !search.query.isEmpty {
                    Button { search.clear(); searchPin = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Workshop.creamDim)
                    }
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Workshop.panel, in: RoundedRectangle(cornerRadius: 9))
            .padding(.horizontal, 12).padding(.bottom, 8)

            if let st = search.status, search.completions.isEmpty {
                Text(st).font(Workshop.mono(10)).foregroundStyle(Workshop.creamDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.bottom, 6)
            }
            if !search.completions.isEmpty {
                suggestList
            }
        }
    }

    private var suggestList: some View {
        VStack(spacing: 0) {
            ForEach(search.completions.prefix(6), id: \.self) { c in
                Button { pick(c) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.title).font(Workshop.monoBold(12)).foregroundStyle(Workshop.cream)
                        if !c.subtitle.isEmpty {
                            Text(c.subtitle).font(Workshop.mono(10)).foregroundStyle(Workshop.creamDim)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 7)
                }
                Divider().overlay(Workshop.panel)
            }
        }
        .background(Workshop.band)
        .padding(.bottom, 6)
    }

    private func runSearch() {
        if let c = search.coordinateJump {
            jump(to: c, label: String(format: "%.5f, %.5f", c.latitude, c.longitude))
            return
        }
        search.resolve(nil) { hit in if let hit { jump(to: hit.coordinate, label: hit.title) } }
    }
    private func pick(_ c: MKLocalSearchCompletion) {
        search.resolve(c) { hit in if let hit { jump(to: hit.coordinate, label: hit.title) } }
    }
    private func jump(to c: CLLocationCoordinate2D, label: String) {
        searchPin = c
        searchToken += 1
        trackMode = 0
        search.completions = []
        search.status = "Found: " + label
        searchFieldFocused = false
    }

    private var panel: some View {
        VStack(spacing: 10) {
            // source switch — the web's .srcswitch
            HStack(spacing: 4) {
                ForEach(SrcKind.allCases) { k in
                    Button {
                        src = k
                        switch k {
                        case .oldmap: if store.maps.isEmpty { showImporter = true } else { overlayOn = true; if selectedFile == nil { selectedFile = store.maps.first }; if store.maps.count > 1 { showFileSheet = true } }
                        case .hist:   showHistSheet = true
                        case .aerial: overlayOn = true; if aerialYear == nil { aerialYear = catalog?.aerials["NYS orthos"]?.last }
                        case .lidar:  overlayOn = true
                        }
                    } label: {
                        Text(k.rawValue)
                            .font(Workshop.monoBold(12))
                            .padding(.vertical, 7).frame(maxWidth: .infinity)
                            .background(src == k ? Workshop.gold : Workshop.panel)
                            .foregroundStyle(src == k ? Workshop.bg : Workshop.creamDim)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            // context line: what's selected in this source
            contextLine
            // eye + opacity + fit/follow
            HStack(spacing: 12) {
                Button { overlayOn.toggle() } label: {
                    Image(systemName: overlayOn ? "eye.fill" : "eye.slash")
                        .foregroundStyle(overlayOn ? Workshop.glow : Workshop.creamDim)
                }
                .accessibilityLabel("Toggle overlay")
                Slider(value: $opacity, in: 0...1).tint(Workshop.gold)
                Text("\(Int(opacity * 100))%")
                    .font(Workshop.mono(11)).foregroundStyle(Workshop.creamDim)
                    .frame(width: 38, alignment: .trailing)
                Divider().frame(height: 20).overlay(Workshop.panel)
                Button { fitToken += 1; trackMode = 0 } label: {
                    Image(systemName: "map").foregroundStyle(Workshop.creamDim)
                }
                .accessibilityLabel("Fit overlay")
                Button { trackMode = trackMode == 1 ? 2 : 1 } label: {
                    Image(systemName: trackMode == 2 ? "location.north.line.fill" : "location.fill")
                        .foregroundStyle(trackMode > 0 ? Workshop.glow : Workshop.creamDim)
                }
                .accessibilityLabel("Follow my location")
            }
        }
        .padding(12)
        .background(Workshop.band.opacity(0.94), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 10).padding(.bottom, 8)
    }

    @ViewBuilder
    private var contextLine: some View {
        HStack(spacing: 6) {
            switch src {
            case .oldmap:
                if let f = selectedFile ?? store.maps.first {
                    chip(f.name + " · offline") { showFileSheet = true }
                } else {
                    chip("Import an MBTiles…") { showImporter = true }
                }
            case .lidar:
                Text("NYS statewide hillshade · online")
                    .font(Workshop.mono(11)).foregroundStyle(Workshop.creamDim)
            case .aerial:
                if let years = catalog?.aerials["NYS orthos"] {
                    Menu {
                        ForEach(years) { a in
                            Button(a.name) { aerialYear = a; overlayOn = true }
                        }
                    } label: {
                        chipLabel("Year: " + (aerialYear?.name ?? years.last!.name))
                    }
                }
            case .hist:
                chip(selectedHist.map { "\($0.yearLabel) · \($0.atlas)" } ?? "Pick a map in view…") {
                    showHistSheet = true
                }
            }
            Spacer()
        }
    }

    private func chip(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { chipLabel(text) }
    }
    private func chipLabel(_ text: String) -> some View {
        Text(text)
            .font(Workshop.mono(11)).lineLimit(1)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Workshop.panel, in: Capsule())
            .foregroundStyle(Workshop.cream)
    }

    // MARK: sheets

    private var histSheet: some View {
        NavigationStack {
            List {
                if let catalog, viewRegion != nil || location.here != nil {
                    let maps = viewRegion.map { catalog.historic(in: $0) }
                        ?? catalog.historic(at: location.here!)
                    if maps.isEmpty {
                        Text("No catalogued maps cover this view — pan the map.").foregroundStyle(.secondary)
                    }
                    ForEach(maps) { m in
                        Button {
                            selectedHist = m; overlayOn = true; showHistSheet = false
                        } label: {
                            HStack {
                                Text(m.yearLabel).font(Workshop.monoBold(14)).foregroundStyle(Workshop.gold)
                                VStack(alignment: .leading) {
                                    Text(m.atlas).foregroundStyle(Workshop.cream).lineLimit(1)
                                    Text("\(m.src) · online").font(.caption).foregroundStyle(Workshop.creamDim)
                                }
                            }
                        }
                    }
                } else {
                    Label("Waiting for location…", systemImage: "location")
                }
            }
            .navigationTitle("Historic maps in view")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private var fileSheet: some View {
        NavigationStack {
            List {
                ForEach(store.maps) { f in
                    Button {
                        selectedFile = f; overlayOn = true; showFileSheet = false
                    } label: {
                        VStack(alignment: .leading) {
                            Text(f.name).foregroundStyle(Workshop.cream)
                            Text(String(format: "%.1f MB · offline", f.sizeMB))
                                .font(.caption).foregroundStyle(Workshop.creamDim)
                        }
                    }
                }
                .onDelete { idx in
                    let doomed = idx.map { store.maps[$0] }
                    for f in doomed { store.delete(f) }
                    if let sel = selectedFile, !store.maps.contains(sel) { selectedFile = store.maps.first }
                }
                Button { showFileSheet = false; showImporter = true } label: {
                    Label("Import another…", systemImage: "plus")
                }
            }
            .navigationTitle("My maps")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }
}

// MARK: - MKMapView wrapper (overlay swapping + basemap)

struct BaseMapView: UIViewRepresentable {
    let overlayKey: String
    let buildOverlay: () -> MKTileOverlay?
    let opacity: Double
    let satellite: Bool
    let fitRegion: MKCoordinateRegion?
    let fitToken: Int
    let trackMode: Int
    var searchPin: CLLocationCoordinate2D? = nil
    var searchToken: Int = 0
    var onRegionChange: ((MKCoordinateRegion) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let view = MKMapView()
        view.delegate = context.coordinator
        context.coordinator.onRegionChange = onRegionChange
        view.mapType = .mutedStandard
        view.showsUserLocation = true
        view.showsCompass = true
        view.showsScale = true
        view.pointOfInterestFilter = .excludingAll
        return view
    }

    func updateUIView(_ view: MKMapView, context: Context) {
        let co = context.coordinator
        view.mapType = satellite ? .hybrid : .mutedStandard
        if overlayKey != co.currentKey {
            co.currentKey = overlayKey
            if let old = co.currentOverlay { view.removeOverlay(old) }
            co.renderer = nil
            co.currentOverlay = buildOverlay()
            if let o = co.currentOverlay { view.addOverlay(o, level: .aboveLabels) }
        }
        co.renderer?.alpha = CGFloat(opacity)
        co.pendingAlpha = CGFloat(opacity)
        if fitToken != co.lastFitToken {
            co.lastFitToken = fitToken
            view.setUserTrackingMode(.none, animated: false)
            if let region = fitRegion { view.setRegion(region, animated: true) }
        }
        if trackMode != co.lastTrackMode {
            co.lastTrackMode = trackMode
            let mode: MKUserTrackingMode = trackMode == 2 ? .followWithHeading
                : trackMode == 1 ? .follow : .none
            view.setUserTrackingMode(mode, animated: true)
        }
        if searchToken != co.lastSearchToken {
            co.lastSearchToken = searchToken
            if let c = searchPin {
                if let old = co.searchAnnotation { view.removeAnnotation(old) }
                let a = MKPointAnnotation(); a.coordinate = c
                co.searchAnnotation = a
                view.addAnnotation(a)
                view.setRegion(MKCoordinateRegion(center: c,
                    span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)), animated: true)
            } else if let old = co.searchAnnotation {
                view.removeAnnotation(old); co.searchAnnotation = nil
            }
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var onRegionChange: ((MKCoordinateRegion) -> Void)?
        private var debounce: Timer?
        var currentKey = "none"
        var currentOverlay: MKTileOverlay?
        var renderer: MKTileOverlayRenderer?
        var pendingAlpha: CGFloat = 0.8
        var lastFitToken = 0
        var lastTrackMode = 0
        var lastSearchToken = 0
        var searchAnnotation: MKPointAnnotation?

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            // debounced like the web (400ms) so the list doesn't churn mid-pan
            let region = mapView.region
            debounce?.invalidate()
            debounce = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
                self?.onRegionChange?(region)
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }
            let id = "searchPin"
            let v = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
            v.markerTintColor = UIColor(red: 0xb8/255.0, green: 0x86/255.0, blue: 0x2c/255.0, alpha: 1) // Workshop.gold
            v.glyphImage = UIImage(systemName: "mappin")
            v.annotation = annotation
            return v
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tiles = overlay as? MKTileOverlay {
                let r = MKTileOverlayRenderer(tileOverlay: tiles)
                r.alpha = pendingAlpha
                renderer = r
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}
