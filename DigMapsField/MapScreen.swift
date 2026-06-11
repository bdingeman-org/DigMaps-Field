//
//  MapScreen.swift
//  The whole point: an MKMapView (UIKit, because SwiftUI's Map can't do
//  tile overlays) showing the baked historic map over a muted base, with
//  the live GPS dot, an opacity slider, and follow/fit buttons.
//

import SwiftUI
import MapKit
import CoreLocation

/// Asks for when-in-use authorization; MKMapView draws the blue dot itself.
final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    @Published var denied = false

    override init() {
        super.init()
        manager.delegate = self
        manager.requestWhenInUseAuthorization()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        denied = manager.authorizationStatus == .denied
            || manager.authorizationStatus == .restricted
    }
}

struct MapScreen: View {
    let map: MapFile
    @StateObject private var location = LocationManager()
    @State private var opacity = 0.8
    @State private var overlay: MBTilesOverlay?
    @State private var failed = false
    /// Bumped to ask the representable to re-frame on the overlay bounds.
    @State private var fitToken = 0
    /// 0 = free pan, 1 = follow, 2 = follow + heading arrow (v0.2)
    @State private var trackMode = 0

    var body: some View {
        Group {
            if let overlay {
                ZStack(alignment: .bottom) {
                    HistoricMapView(
                        overlay: overlay, opacity: opacity,
                        fitToken: fitToken, trackMode: trackMode
                    )
                    .ignoresSafeArea(edges: .bottom)
                    controls
                }
            } else if failed {
                ContentUnavailableView(
                    "Couldn't open this map",
                    systemImage: "exclamationmark.triangle",
                    description: Text("The file doesn't look like an MBTiles export. Re-export it from DigMaps on the desktop.")
                )
            } else {
                ProgressView()
            }
        }
        .navigationTitle(map.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            overlay = MBTilesOverlay(fileURL: map.url)
            failed = overlay == nil
        }
        .alert("Location is off", isPresented: $location.denied) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Enable location for DigMaps Field in Settings to see your dot on the old map.")
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Image(systemName: "circle.dashed")
            Slider(value: $opacity, in: 0...1)
            Image(systemName: "circle.fill")
            Divider().frame(height: 24)
            Button {
                fitToken += 1
                trackMode = 0
            } label: {
                Image(systemName: "map")
            }
            .accessibilityLabel("Fit the old map on screen")
            Button {
                trackMode = trackMode == 1 ? 2 : 1 // tap again for heading arrow
            } label: {
                Image(systemName: trackMode == 2 ? "location.north.line.fill" : "location.fill")
            }
            .foregroundStyle(trackMode > 0 ? Color.accentColor : Color.primary)
            .accessibilityLabel(trackMode == 1 ? "Follow with heading" : "Follow my location")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: Capsule())
        .padding(.bottom, 12)
        .padding(.horizontal, 16)
    }
}

// MARK: - MKMapView wrapper

struct HistoricMapView: UIViewRepresentable {
    let overlay: MBTilesOverlay
    let opacity: Double
    let fitToken: Int
    let trackMode: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let view = MKMapView()
        view.delegate = context.coordinator
        view.mapType = .mutedStandard
        view.showsUserLocation = true
        view.showsCompass = true
        view.showsScale = true
        view.pointOfInterestFilter = .excludingAll
        view.addOverlay(overlay, level: .aboveLabels)
        if let region = overlay.boundsRegion {
            view.setRegion(region, animated: false)
        }
        return view
    }

    func updateUIView(_ view: MKMapView, context: Context) {
        let co = context.coordinator
        co.renderer?.alpha = CGFloat(opacity)
        co.pendingAlpha = CGFloat(opacity)
        if fitToken != co.lastFitToken {
            co.lastFitToken = fitToken
            view.setUserTrackingMode(.none, animated: false)
            if let region = overlay.boundsRegion {
                view.setRegion(region, animated: true)
            }
        }
        if trackMode != co.lastTrackMode {
            co.lastTrackMode = trackMode
            let mode: MKUserTrackingMode = trackMode == 2 ? .followWithHeading
                : trackMode == 1 ? .follow : .none
            view.setUserTrackingMode(mode, animated: true)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var renderer: MKTileOverlayRenderer?
        /// Alpha to apply when the renderer is first created (slider moved
        /// before MapKit asked for the renderer).
        var pendingAlpha: CGFloat = 0.8
        var lastFitToken = 0
        var lastTrackMode = 0

        func mapView(_ mapView: MKMapView,
                     rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
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
