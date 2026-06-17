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
    case oldmap = "Old map", lidar = "LIDAR", aerial = "Aerial", hist = "Historic"
    var id: String { rawValue }
}


struct MapHomeView: View {
    @EnvironmentObject private var store: MapStore
    @EnvironmentObject private var routes: RouteStore
    @StateObject private var location = LocationManager()
    @StateObject private var search = PlaceSearch()

    @State private var src: SrcKind = .oldmap
    @State private var overlayOn = false          // eye — off by default, like web
    @State private var opacity = 0.8
    @State private var basemapSat = false         // ◑ basemap toggle
    @State private var fitToken = 0
    @State private var trackMode = 0

    @State private var selectedFile: MapFile?
    @State private var aerialPick: AerialPick?
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
                onRegionChange: { viewRegion = $0; search.updateRegion($0) }
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

    private var panel: some View {
        VStack(spacing: 10) {
            routeBar
            // source switch — the web's .srcswitch
            HStack(spacing: 4) {
                ForEach(SrcKind.allCases) { k in
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
                Button { fitToken += 1; trackMode = 0 } label: {
                    Image(systemName: "map").foregroundStyle(Workshop.creamDim)
                }
                .accessibilityLabel("Fit overlay")
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
                    if let years = catalog?.aerials["NYS orthos"] {
                        ForEach(years) { a in
                            Button(a.name) { aerialPick = .modern(a); overlayOn = true }
                        }
                    }
                    if let c = viewRegion?.center ?? location.here {
                        let hist = HistoricAerial.forCenter(c)
                        if !hist.isEmpty {
                            Divider()
                            ForEach(hist) { h in
                                Button(h.label) { aerialPick = .historic(h); overlayOn = true }
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
        var routeOverlay: MKPolyline?
        var routeKey = "none"
        var lastRouteFitToken = 0
        var didInitialFit = false

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
