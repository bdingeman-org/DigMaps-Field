//
//  CarPlaySceneDelegate.swift
//  DigMaps Field on the car screen: your live GPS dot on a georeferenced
//  historic map (or NYS aerial / hillshade) while you drive an old road —
//  following a route you recorded, with distance-remaining in the nav bar.
//
//  CarPlay navigation apps draw their own map into the scene's `carWindow`
//  (an MKMapView here) and overlay Apple-provided template controls
//  (CPMapTemplate map buttons + nav-bar buttons) on top — no custom-drawn UI.
//
//  NOTE: this scene only does anything once Apple grants the
//  `com.apple.developer.carplay-maps` entitlement (see
//  CARPLAY-ENTITLEMENT-REQUEST.md). Until then it compiles but never connects.
//

import CarPlay
import MapKit
import CoreLocation

final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var mapController: CarPlayMapController?

    func templateApplicationScene(
        _ scene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController,
        to window: CPWindow
    ) {
        self.interfaceController = interfaceController

        let vc = CarPlayMapController()
        window.rootViewController = vc
        _ = vc.view   // force viewDidLoad now so the active route is loaded before we build buttons
        self.mapController = vc

        let mapTemplate = CPMapTemplate()
        vc.mapTemplate = mapTemplate
        mapTemplate.mapButtons = vc.makeMapButtons()
        mapTemplate.automaticallyHidesNavigationBar = false
        interfaceController.setRootTemplate(mapTemplate, animated: true, completion: nil)
    }

    func templateApplicationScene(
        _ scene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        self.interfaceController = nil
        self.mapController = nil
    }
}

/// The UIViewController whose MKMapView fills the CarPlay screen.
final class CarPlayMapController: UIViewController, CLLocationManagerDelegate {
    private let mapView = MKMapView()
    private let locationManager = CLLocationManager()
    private lazy var store = MapStore()        // lazy: init on first (main-thread) access
    private lazy var routeStore = RouteStore()

    /// Set by the scene delegate so we can update the nav-bar distance readout.
    weak var mapTemplate: CPMapTemplate?

    /// Overlay sources the car can cycle through, in order.
    private enum CarSource: CaseIterable {
        case mbtiles, aerial, hillshade
        var label: String {
            switch self {
            case .mbtiles: return "Old map"
            case .aerial: return "Aerial"
            case .hillshade: return "Hillshade"
            }
        }
    }
    private var sourceIndex = 0
    private var overlayOn = true
    private var currentOverlay: MKTileOverlay?
    private var renderer: MKTileOverlayRenderer?

    // route following
    private var activeRoute: Route?
    private var routePolyline: MKPolyline?
    private var routeOn = true
    private let distanceFmt: MKDistanceFormatter = {
        let f = MKDistanceFormatter(); f.unitStyle = .abbreviated; return f
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        mapView.frame = view.bounds
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.delegate = self
        mapView.mapType = .mutedStandard
        mapView.showsUserLocation = true
        mapView.pointOfInterestFilter = .excludingAll
        mapView.userTrackingMode = .follow
        view.addSubview(mapView)

        locationManager.delegate = self
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()   // raw fixes drive the route progress readout

        store.refresh()
        routeStore.refresh()
        activeRoute = routeStore.activeRoute()
        applyOverlay()
        applyRoute()
    }

    // MARK: overlay handling

    private func applyOverlay() {
        if let old = currentOverlay { mapView.removeOverlay(old); currentOverlay = nil; renderer = nil }
        if overlayOn, let o = buildOverlay() {
            currentOverlay = o
            mapView.addOverlay(o, level: .aboveLabels)
        }
        // keep the route line drawn above the (re-added) tiles
        if let pl = routePolyline {
            mapView.removeOverlay(pl)
            mapView.addOverlay(pl, level: .aboveLabels)
        }
    }

    private func buildOverlay() -> MKTileOverlay? {
        switch CarSource.allCases[sourceIndex] {
        case .mbtiles:
            guard let f = store.maps.first else { return nil }
            return OverlayFactory.mbtiles(f)
        case .aerial:
            guard let a = OverlayCatalog.shared?.aerials["NYS orthos"]?.last else { return nil }
            return OverlayFactory.aerial(a)
        case .hillshade:
            return OverlayFactory.hillshade()
        }
    }

    /// Cycle to the next source that actually produces an overlay.
    private func cycleSource() {
        for _ in 0..<CarSource.allCases.count {
            sourceIndex = (sourceIndex + 1) % CarSource.allCases.count
            overlayOn = true
            if buildOverlay() != nil { break }
        }
        applyOverlay()
    }

    // MARK: route handling

    private func applyRoute() {
        if let old = routePolyline { mapView.removeOverlay(old); routePolyline = nil }
        guard routeOn, let r = activeRoute, r.coordinates.count >= 2 else {
            updateProgressButton(nil)
            return
        }
        let pl = r.polyline
        routePolyline = pl
        mapView.addOverlay(pl, level: .aboveLabels)
    }

    private func updateProgressButton(_ p: RouteProgress?) {
        guard let mapTemplate else { return }
        guard routeOn, activeRoute != nil, let p else {
            mapTemplate.leadingNavigationBarButtons = []
            return
        }
        let title = "\(distanceFmt.string(fromDistance: p.remaining)) left"
        let btn = CPBarButton(title: title) { [weak self] _ in
            self?.mapView.setUserTrackingMode(.follow, animated: true)
        }
        mapTemplate.leadingNavigationBarButtons = [btn]
    }

    // MARK: CarPlay map buttons (large, glanceable, driver-safe)

    func makeMapButtons() -> [CPMapButton] {
        let recenter = CPMapButton { [weak self] _ in
            self?.mapView.setUserTrackingMode(.follow, animated: true)
        }
        recenter.image = UIImage(systemName: "location.fill")

        let cycle = CPMapButton { [weak self] _ in
            self?.cycleSource()
        }
        cycle.image = UIImage(systemName: "square.3.layers.3d")

        let toggle = CPMapButton { [weak self] _ in
            guard let self else { return }
            self.overlayOn.toggle()
            self.applyOverlay()
        }
        toggle.image = UIImage(systemName: "eye")

        // route visibility — only meaningful when a route is loaded on the phone
        let route = CPMapButton { [weak self] _ in
            guard let self else { return }
            self.routeOn.toggle()
            self.applyRoute()
        }
        route.image = UIImage(systemName: "point.topleft.down.curvedto.point.bottomright.up")
        route.isHidden = (activeRoute == nil)

        return [recenter, cycle, toggle, route]
    }

    // MARK: CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last, let r = activeRoute else { return }
        updateProgressButton(r.progress(at: loc.coordinate))
    }

    // MARK: MKMapViewDelegate

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        if let line = overlay as? MKPolyline {
            return OverlayFactory.routeRenderer(for: line)
        }
        if let tiles = overlay as? MKTileOverlay {
            let r = MKTileOverlayRenderer(tileOverlay: tiles)
            r.alpha = 0.8
            renderer = r
            return r
        }
        return MKOverlayRenderer(overlay: overlay)
    }
}

extension CarPlayMapController: MKMapViewDelegate {}
