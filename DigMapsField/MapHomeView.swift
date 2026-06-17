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
import UIKit
import UniformTypeIdentifiers

/// Asks for when-in-use authorization; MKMapView draws the blue dot itself.
final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    @Published var denied = false
    @Published var here: CLLocationCoordinate2D?

    override init() {
        super.init()
        manager.delegate = self
        manager.distanceFilter = 10   // meters — enough to keep route progress live without churn
        manager.requestWhenInUseAuthorization()
        manager.requestLocation()
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        denied = manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted
        if manager.authorizationStatus == .authorizedWhenInUse {
            manager.requestLocation()
            manager.startUpdatingLocation()   // stream fixes so "distance left" updates while moving
        }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        here = locs.last?.coordinate
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

enum SrcKind: String, CaseIterable, Identifiable {
    case oldmap = "Old map", lidar = "LIDAR", aerial = "Aerial", hist = "Old maps"
    var id: String { rawValue }
    /// Sources shown as primary tabs. `oldmap` (import-your-own MBTiles) is a
    /// power feature reached from the header menu, not a main tab.
    static var tabs: [SrcKind] { [.lidar, .aerial, .hist] }
}


struct MapHomeView: View {
    @EnvironmentObject private var store: MapStore
    @EnvironmentObject private var routes: RouteStore
    @StateObject private var location = LocationManager()
    @StateObject private var search = PlaceSearch()

    @State private var src: SrcKind = .hist
    @State private var overlayOn = false          // eye — off by default, like web
    @State private var opacity = 0.8
    @State private var basemapSat = false         // ◑ basemap toggle
    @State private var fitToken = 0
    @State private var trackMode = 0

    @State private var selectedFile: MapFile?
    @State private var aerialPick: AerialPick?
    @State private var aerialHistInView: [HistoricAerial] = []  // historic aerials covering the current map center
    @State private var histInView: [CatalogHistoricMap] = []    // catalogued old maps covering the current map viewport
    @State private var lidarSource: HillshadeSource = .state
    @State private var selectedHist: CatalogHistoricMap?

    @State private var viewRegion: MKCoordinateRegion?
    @State private var searchPin: CLLocationCoordinate2D?
    @State private var searchToken = 0
    @FocusState private var searchFieldFocused: Bool
    @State private var showHistSheet = false
    @State private var showFileSheet = false
    @State private var showImporter = false

    // route following
    @State private var routeOn = true
    @State private var activeRoute: Route?
    @State private var routeProgress: RouteProgress?
    @State private var routeFitToken = 0
    @State private var showRouteSheet = false
    @State private var showRouteImporter = false

    // parcel-owner lookup (tap-to-query, web parity)
    @State private var parcelMode = false
    @State private var parcelLookup: ParcelLookup?
    @State private var parcelLoading = false
    @State private var showParcelSheet = false
    @State private var parcelRings: [[CLLocationCoordinate2D]]?
    @State private var parcelPoint: CLLocationCoordinate2D?
    @State private var parcelToken = 0

    private var catalog: OverlayCatalog? { OverlayCatalog.shared }

    private var routeTypes: [UTType] {
        var t: [UTType] = [.json, .xml]
        if let gpx = UTType(filenameExtension: "gpx") { t.append(gpx) }
        if let geo = UTType(filenameExtension: "geojson") { t.append(geo) }
        return t
    }

    private var routeKey: String {
        (routeOn && activeRoute != nil) ? "route-" + (routes.activeRouteID ?? "none") : "none"
    }
    private var routeCoords: [CLLocationCoordinate2D]? {
        (routeOn ? activeRoute : nil)?.coordinates
    }
    private func reloadActiveRoute() {
        activeRoute = routes.activeRoute()
        if let h = location.here, let r = activeRoute { routeProgress = r.progress(at: h) }
        else { routeProgress = nil }
    }
    private func fmt(_ m: CLLocationDistance) -> String {
        let f = MKDistanceFormatter(); f.unitStyle = .abbreviated
        return f.string(fromDistance: m)
    }

    // MARK: current overlay

    private var overlayKey: String {
        guard overlayOn else { return "none" }
        switch src {
        case .oldmap: return "file-" + (selectedFile?.id ?? "none")
        case .lidar:  return "lidar-" + lidarSource.rawValue
        case .aerial: return "aerial-" + (aerialPick?.id ?? "none")
        case .hist:   return "hist-" + (selectedHist?.id ?? "none")
        }
    }

    private func buildOverlay() -> MKTileOverlay? {
        guard overlayOn else { return nil }
        switch src {
        case .oldmap:
            guard let f = selectedFile ?? store.maps.first else { return nil }
            return OverlayFactory.mbtiles(f)
        case .lidar:
            return OverlayFactory.hillshade(lidarSource)
        case .aerial:
            guard let pick = aerialPick ?? (catalog?.aerials["NYS orthos"]?.last).map(AerialPick.modern) else { return nil }
            switch pick {
            case .modern(let a): return OverlayFactory.aerial(a)
            case .historic(let h): return h.makeOverlay()
            }
        case .hist:
            guard let m = selectedHist, let catalog else { return nil }
            return OverlayFactory.historic(m, catalog: catalog)
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
                routeCoords: routeCoords, routeKey: routeKey, routeFitToken: routeFitToken,
                parcelMode: parcelMode, onMapTap: parcelTap,
                parcelRings: parcelRings, parcelPoint: parcelPoint, parcelToken: parcelToken,
                onRegionChange: {
                    viewRegion = $0
                    aerialHistInView = HistoricAerial.forCenter($0.center)
                    histInView = OverlayCatalog.shared?.historic(in: $0) ?? []
                    search.updateRegion($0)
                }
            )
            .ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Spacer()
                panel
            }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                for url in urls { store.importMap(from: url) }
                if selectedFile == nil { selectedFile = store.maps.first }
                if selectedFile != nil { src = .oldmap; overlayOn = true; fitToken += 1 }
            }
        }
        .fileImporter(isPresented: $showRouteImporter,
                      allowedContentTypes: routeTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                for url in urls { routes.importRoute(from: url) }
                reloadActiveRoute()
            }
        }
        .sheet(isPresented: $showHistSheet) { histSheet }
        .sheet(isPresented: $showFileSheet) { fileSheet }
        .sheet(isPresented: $showRouteSheet) { routeSheet }
        .sheet(isPresented: $showParcelSheet) { parcelSheet }
        .alert("Import failed", isPresented: Binding(
            get: { store.lastError != nil || routes.lastError != nil },
            set: { if !$0 { store.lastError = nil; routes.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(store.lastError ?? routes.lastError ?? "") }
        .preferredColorScheme(.dark)
        .onAppear(perform: reloadActiveRoute)
        .onChange(of: routes.activeRouteID) { _, _ in reloadActiveRoute() }
        .onReceive(location.$here.compactMap { $0 }) { h in
            if let r = activeRoute { routeProgress = r.progress(at: h) }
        }
    }

    // MARK: chrome

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                CoilMark(size: 21)
                Wordmark(size: 15)
                Spacer()
                Menu {
                    Button {
                        showImporter = true
                    } label: { Label("Import MBTiles…", systemImage: "square.and.arrow.down") }
                    if !store.maps.isEmpty {
                        Button {
                            src = .oldmap; overlayOn = true
                            if selectedFile == nil { selectedFile = store.maps.first }
                            fitToken += 1
                            if store.maps.count > 1 { showFileSheet = true }
                        } label: { Label("My imported maps", systemImage: "map") }
                    }
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .foregroundStyle(Workshop.gold)
                }
                .accessibilityLabel("Import map tiles")
                Button { basemapSat.toggle() } label: {
                    Image(systemName: basemapSat ? "globe.americas.fill" : "circle.lefthalf.filled")
                        .foregroundStyle(Workshop.gold)
                }
                .accessibilityLabel("Toggle satellite basemap")
                Button(action: toggleParcelMode) {
                    Image(systemName: "square.dashed.inset.filled")
                        .foregroundStyle(parcelMode ? Workshop.glow : Workshop.gold)
                }
                .accessibilityLabel("Parcel owner lookup")
            }
            .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 6)
            searchBar
            if parcelMode {
                Text("Parcel lookup on — tap any parcel on the map")
                    .font(Workshop.mono(10)).foregroundStyle(Workshop.bg)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(Workshop.gold)
            }
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
        search.dismissSuggestions()
        dismissKeyboard()
        if let c = search.coordinateJump {
            jump(to: c, label: String(format: "%.5f, %.5f", c.latitude, c.longitude))
            return
        }
        search.resolve(nil) { hit in if let hit { jump(to: hit.coordinate, label: hit.title) } }
    }
    private func pick(_ c: MKLocalSearchCompletion) {
        // collapse the suggestion list and keyboard the instant the row is tapped,
        // before the async resolve returns (otherwise the list lingers / reopens)
        search.dismissSuggestions()
        dismissKeyboard()
        search.resolve(c) { hit in if let hit { jump(to: hit.coordinate, label: hit.title) } }
    }
    private func dismissKeyboard() {
        searchFieldFocused = false
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
    private func jump(to c: CLLocationCoordinate2D, label: String) {
        search.dismissSuggestions()   // suppress any late completer result + clear list
        searchPin = c
        searchToken += 1
        trackMode = 0
        search.status = "Found: " + label
        dismissKeyboard()
    }

    // MARK: parcel lookup

    /// Tap on the map while parcel mode is on → query the covering parcel layer.
    private func parcelTap(_ c: CLLocationCoordinate2D) {
        parcelLoading = true
        parcelLookup = nil
        showParcelSheet = true
        Task {
            let result = await ParcelService.lookup(at: c)
            await MainActor.run {
                parcelLoading = false
                parcelLookup = result
                if case .found(let r) = result {
                    parcelRings = r.rings
                    parcelPoint = r.point
                } else {
                    parcelRings = nil; parcelPoint = nil
                }
                parcelToken += 1
            }
        }
    }

    private func toggleParcelMode() {
        parcelMode.toggle()
        if !parcelMode {                       // leaving the mode clears the drawn parcel
            parcelRings = nil; parcelPoint = nil; parcelToken += 1
        }
    }

    private var parcelSheet: some View {
        NavigationStack {
            Group {
                if parcelLoading {
                    VStack(spacing: 10) {
                        ProgressView().tint(Workshop.gold)
                        Text("Looking up parcel…").font(Workshop.mono(12)).foregroundStyle(Workshop.creamDim)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    switch parcelLookup {
                    case .found(let r):       parcelDetail(r)
                    case .notFound(let cov):  parcelMessage("No parcel here — lookup covers \(cov).")
                    case .noCoverage:         parcelMessage("No parcel data for this spot yet. Covered: Saratoga County & other NY counties, plus Bergen County NJ.")
                    case .failed(let msg):    parcelMessage("Parcel lookup failed — \(msg). The county server may be busy; try again.")
                    case nil:                 parcelMessage("—")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Workshop.bg)
            .navigationTitle("Parcel owner")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }

    private func parcelMessage(_ text: String) -> some View {
        Text(text)
            .font(Workshop.mono(13)).foregroundStyle(Workshop.creamDim)
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func parcelDetail(_ r: ParcelResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(r.owner)
                    .font(Workshop.monoBold(20)).foregroundStyle(Workshop.gold)
                    .padding(.bottom, 12)
                ForEach(r.rows.indices, id: \.self) { i in
                    HStack(alignment: .top) {
                        Text(r.rows[i].label)
                            .font(Workshop.mono(12)).foregroundStyle(Workshop.creamDim)
                            .frame(width: 90, alignment: .leading)
                        Text(r.rows[i].value)
                            .font(Workshop.mono(12)).foregroundStyle(Workshop.cream)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 5)
                    Divider().overlay(Workshop.panel)
                }
                Text("Coverage: \(r.coverage)\(r.point != nil ? " · approximate (centroid)" : "")")
                    .font(Workshop.mono(10)).foregroundStyle(Workshop.creamDim)
                    .padding(.top, 12)
            }
            .padding(18)
        }
    }

    private var panel: some View {
        VStack(spacing: 10) {
            routeBar
            // source switch — the web's .srcswitch
            HStack(spacing: 4) {
                ForEach(SrcKind.tabs) { k in
                    Button {
                        src = k
                        switch k {
                        case .oldmap: if store.maps.isEmpty { showImporter = true } else { overlayOn = true; if selectedFile == nil { selectedFile = store.maps.first }; if store.maps.count > 1 { showFileSheet = true } }
                        case .hist:   showHistSheet = true
                        case .aerial: overlayOn = true; if aerialPick == nil { aerialPick = (catalog?.aerials["NYS orthos"]?.last).map(AerialPick.modern) }
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
                Button { trackMode = trackMode == 1 ? 2 : 1 } label: {
                    Image(systemName: trackMode == 2 ? "location.north.line.fill" : "location.fill")
                        .foregroundStyle(trackMode > 0 ? Workshop.glow : Workshop.creamDim)
                }
                .accessibilityLabel("Follow my location")
                Button { showRouteSheet = true } label: {
                    Image(systemName: "point.topleft.down.curvedto.point.bottomright.up\(activeRoute != nil ? ".fill" : "")")
                        .foregroundStyle(activeRoute != nil && routeOn ? Workshop.glow : Workshop.creamDim)
                }
                .accessibilityLabel("Routes")
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
                Menu {
                    ForEach(HillshadeSource.allCases) { s in
                        Button(s.rawValue) { lidarSource = s; overlayOn = true }
                    }
                } label: {
                    chipLabel("Source: " + lidarSource.rawValue)
                }
                Text("· online").font(Workshop.mono(11)).foregroundStyle(Workshop.creamDim)
            case .aerial:
                Menu {
                    if !aerialHistInView.isEmpty {
                        Section("Historic aerials here") {
                            ForEach(aerialHistInView) { h in
                                Button(h.label) { aerialPick = .historic(h); overlayOn = true }
                            }
                        }
                    }
                    if let years = catalog?.aerials["NYS orthos"] {
                        Section("NYS orthoimagery") {
                            ForEach(years) { a in
                                Button(a.name) { aerialPick = .modern(a); overlayOn = true }
                            }
                        }
                    }
                } label: {
                    chipLabel("Year: " + (aerialPick?.label ?? catalog?.aerials["NYS orthos"]?.last?.name ?? "—"))
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

    // MARK: route bar (shown only when a route is loaded)

    @ViewBuilder
    private var routeBar: some View {
        if let r = activeRoute {
            HStack(spacing: 8) {
                Button { routeOn.toggle() } label: {
                    Image(systemName: routeOn ? "point.topleft.down.curvedto.point.bottomright.up.fill"
                                              : "point.topleft.down.curvedto.point.bottomright.up")
                        .foregroundStyle(routeOn ? Workshop.glow : Workshop.creamDim)
                }
                .accessibilityLabel("Toggle route")
                Text(r.name).font(Workshop.monoBold(12)).foregroundStyle(Workshop.cream).lineLimit(1)
                Spacer(minLength: 6)
                if let p = routeProgress, routeOn {
                    if p.offRoute > 60 {
                        Text("⚠︎ \(fmt(p.offRoute)) off")
                            .font(Workshop.mono(10)).foregroundStyle(Workshop.gold)
                    } else {
                        Text("\(fmt(p.remaining)) left · \(Int(p.fraction * 100))%")
                            .font(Workshop.mono(10)).foregroundStyle(Workshop.creamDim)
                    }
                } else {
                    Text(fmt(r.totalMeters))
                        .font(Workshop.mono(10)).foregroundStyle(Workshop.creamDim)
                }
                Button { routeFitToken += 1; trackMode = 0 } label: {
                    Image(systemName: "scope").foregroundStyle(Workshop.creamDim)
                }
                .accessibilityLabel("Fit route")
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: sheets

    private var histSheet: some View {
        NavigationStack {
            List {
                // Driven only by the current map viewport (recomputed on every pan),
                // never by GPS — so entries never appear that aren't in view.
                if histInView.isEmpty {
                    Text("No catalogued maps cover this view — pan the map.").foregroundStyle(.secondary)
                }
                ForEach(histInView) { m in
                    Button {
                        selectedHist = m; overlayOn = true; fitToken += 1; showHistSheet = false
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
                        selectedFile = f; overlayOn = true; fitToken += 1; showFileSheet = false
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

    private var routeSheet: some View {
        NavigationStack {
            List {
                if routes.routes.isEmpty {
                    Text("No routes yet. Import a GPX or GeoJSON track you recorded — DigMaps Field draws it and shows how far along it you are.")
                        .foregroundStyle(.secondary)
                }
                ForEach(routes.routes) { f in
                    Button {
                        routes.activeRouteID = f.id
                        routeOn = true
                        reloadActiveRoute()
                        routeFitToken += 1
                        showRouteSheet = false
                    } label: {
                        HStack {
                            Image(systemName: routes.activeRouteID == f.id ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(routes.activeRouteID == f.id ? Workshop.gold : Workshop.creamDim)
                            Text(f.name).foregroundStyle(Workshop.cream)
                        }
                    }
                }
                .onDelete { idx in
                    for f in idx.map({ routes.routes[$0] }) { routes.delete(f) }
                    reloadActiveRoute()
                }
                if routes.activeRouteID != nil {
                    Button(role: .destructive) {
                        routes.activeRouteID = nil
                        reloadActiveRoute()
                    } label: {
                        Label("Stop following", systemImage: "xmark.circle")
                    }
                }
                Button { showRouteSheet = false; showRouteImporter = true } label: {
                    Label("Import a track…", systemImage: "plus")
                }
            }
            .navigationTitle("Routes")
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
    var routeCoords: [CLLocationCoordinate2D]? = nil
    var routeKey: String = "none"
    var routeFitToken: Int = 0
    var parcelMode: Bool = false
    var onMapTap: ((CLLocationCoordinate2D) -> Void)? = nil
    var parcelRings: [[CLLocationCoordinate2D]]? = nil
    var parcelPoint: CLLocationCoordinate2D? = nil
    var parcelToken: Int = 0
    var onRegionChange: ((MKCoordinateRegion) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let view = MKMapView()
        view.delegate = context.coordinator
        context.coordinator.onRegionChange = onRegionChange
        context.coordinator.mapView = view
        view.mapType = .mutedStandard
        view.showsUserLocation = true
        view.showsCompass = true
        view.showsScale = true
        view.pointOfInterestFilter = .excludingAll
        // tap-to-query for parcel mode (no-op unless parcelMode is on); set to
        // recognize alongside the map's own gestures so pan/zoom still work
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: MKMapView, context: Context) {
        let co = context.coordinator
        co.parcelMode = parcelMode
        co.onMapTap = onMapTap
        view.mapType = satellite ? .hybrid : .mutedStandard
        if overlayKey != co.currentKey {
            co.currentKey = overlayKey
            if let old = co.currentOverlay { view.removeOverlay(old) }
            co.renderer = nil
            co.currentOverlay = buildOverlay()
            if let o = co.currentOverlay { view.addOverlay(o, level: .aboveLabels) }
            // keep the route line above freshly re-added tiles
            if let pl = co.routeOverlay { view.removeOverlay(pl); view.addOverlay(pl, level: .aboveLabels) }
        }
        co.renderer?.alpha = CGFloat(opacity)
        co.pendingAlpha = CGFloat(opacity)
        if routeKey != co.routeKey {
            co.routeKey = routeKey
            if let old = co.routeOverlay { view.removeOverlay(old); co.routeOverlay = nil }
            if let cs = routeCoords, cs.count >= 2 {
                let pl = MKPolyline(coordinates: cs, count: cs.count)
                co.routeOverlay = pl
                view.addOverlay(pl, level: .aboveLabels)
            }
        }
        if routeFitToken != co.lastRouteFitToken {
            co.lastRouteFitToken = routeFitToken
            if let pl = co.routeOverlay {
                view.setUserTrackingMode(.none, animated: false)
                view.setVisibleMapRect(pl.boundingMapRect,
                    edgePadding: UIEdgeInsets(top: 80, left: 40, bottom: 220, right: 40),
                    animated: true)
            }
        }
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
        if parcelToken != co.lastParcelToken {
            co.lastParcelToken = parcelToken
            for o in co.parcelOverlays { view.removeOverlay(o) }
            co.parcelOverlays = []
            if let rings = parcelRings {
                for r in rings where r.count >= 3 {
                    let poly = MKPolygon(coordinates: r, count: r.count)
                    co.parcelOverlays.append(poly)
                    view.addOverlay(poly, level: .aboveLabels)
                }
            }
            if let p = parcelPoint {
                let circ = MKCircle(center: p, radius: 25)
                co.parcelOverlays.append(circ)
                view.addOverlay(circ, level: .aboveLabels)
            }
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

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
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
        var routeOverlay: MKPolyline?
        var routeKey = "none"
        var lastRouteFitToken = 0
        var didInitialFit = false
        weak var mapView: MKMapView?
        var parcelMode = false
        var onMapTap: ((CLLocationCoordinate2D) -> Void)?
        var parcelOverlays: [MKOverlay] = []
        var lastParcelToken = 0

        private static let gold = UIColor(red: 0xf0/255.0, green: 0xc0/255.0, blue: 0x62/255.0, alpha: 1)
        private static let goldFill = UIColor(red: 0xb8/255.0, green: 0x86/255.0, blue: 0x2c/255.0, alpha: 1)

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard parcelMode, let mv = mapView else { return }
            let pt = g.location(in: mv)
            onMapTap?(mv.convert(pt, toCoordinateFrom: mv))
        }
        // let our tap coexist with MapKit's built-in gestures
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            // Short debounce: just coalesce rapid momentum fires. Kept brief so the
            // in-view lists reflect where you panned before you can open a picker
            // (longer delays let the old viewport's entries linger).
            let region = mapView.region
            debounce?.invalidate()
            debounce = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
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

        /// On the first real GPS fix, center on the user at a neighborhood zoom so the
        /// app opens usefully instead of at MapKit's default wide region. One-shot — later
        /// fit/follow/search actions still take over normally.
        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            guard !didInitialFit else { return }
            let c = userLocation.coordinate
            guard CLLocationCoordinate2DIsValid(c), c.latitude != 0 || c.longitude != 0 else { return }
            didInitialFit = true
            // Tunable default zoom: ~4.0° ≈ regional view (state + neighbors), matching the
            // open-app screenshot. MapKit fits this to the portrait aspect, so latitude drives it.
            let span = MKCoordinateSpan(latitudeDelta: 4.0, longitudeDelta: 4.0)
            mapView.setRegion(MKCoordinateRegion(center: c, span: span), animated: false)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let line = overlay as? MKPolyline {
                return OverlayFactory.routeRenderer(for: line)
            }
            if let poly = overlay as? MKPolygon {
                let r = MKPolygonRenderer(polygon: poly)
                r.strokeColor = Coordinator.gold
                r.lineWidth = 2
                r.fillColor = Coordinator.goldFill.withAlphaComponent(0.12)
                return r
            }
            if let circ = overlay as? MKCircle {
                let r = MKCircleRenderer(circle: circ)
                r.strokeColor = Coordinator.gold
                r.lineWidth = 2
                r.fillColor = Coordinator.goldFill.withAlphaComponent(0.3)
                return r
            }
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
