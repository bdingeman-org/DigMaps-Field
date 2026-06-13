//
//  CarPlaySceneDelegate.swift
//  DigMaps Field on the car screen: your live GPS dot on a georeferenced
//  historic map (or NYS aerial / hillshade) while you drive an old road.
//
//  CarPlay navigation apps draw their own map into the scene's `carWindow`
//  (an MKMapView here) and overlay Apple-provided template controls
//  (CPMapTemplate map buttons) on top — no custom-drawn UI is permitted.
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
        self.mapController = vc

        let mapTemplate = CPMapTemplate()
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
    private lazy var store = MapStore()  // lazy: init on first (main-thread) access in viewDidLoad

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

        store.refresh()
        applyOverlay()
    }

    // MARK: overlay handling

    private func applyOverlay() {
        if let old = currentOverlay { mapView.removeOverlay(old); currentOverlay = nil; renderer = nil }
        guard overlayOn, let o = buildOverlay() else { return }
        currentOverlay = o
        mapView.addOverlay(o, level: .aboveLabels)
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

    /// Cycle to the next source that actually produces an overlay (skip e.g.
    /// "Old map" when nothing has been imported).
    private func cycleSource() {
        for _ in 0..<CarSource.allCases.count {
            sourceIndex = (sourceIndex + 1) % CarSource.allCases.count
            overlayOn = true
            if buildOverlay() != nil { break }
        }
        applyOverlay()
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

        return [recenter, cycle, toggle]
    }

    // MARK: MKMapViewDelegate

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
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
