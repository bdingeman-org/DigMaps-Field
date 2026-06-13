//
//  PlaceSearch.swift
//  Place / address / coordinate search — the iOS counterpart of the web app's
//  "Jump to place" (src/search.ts). Live suggestions come from Apple's
//  MKLocalSearchCompleter (the native equivalent of the web's debounced
//  Nominatim autocomplete), biased toward the current map view; selecting a
//  suggestion resolves it to a coordinate via MKLocalSearch. A "lat, lng"
//  string is detected first and jumped to directly, exactly like the web.
//

import Foundation
import MapKit
import Combine

struct SearchHit: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let subtitle: String
    let coordinate: CLLocationCoordinate2D

    static func == (a: SearchHit, b: SearchHit) -> Bool { a.id == b.id }
}

@MainActor
final class PlaceSearch: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var query = ""
    @Published var completions: [MKLocalSearchCompletion] = []
    @Published var coordinateJump: CLLocationCoordinate2D?   // "lat, lng" typed directly
    @Published var status: String?

    private let completer = MKLocalSearchCompleter()
    private var region: MKCoordinateRegion?
    /// True between a pick/jump and the next keystroke — late async completer
    /// results that arrive after selection must NOT reopen the suggestion list.
    private var suppressed = false

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    /// Keep suggestions biased to wherever the user is looking (web parity).
    func updateRegion(_ r: MKCoordinateRegion) {
        region = r
        completer.region = r
    }

    /// Called as the user types. Mirrors the web's 3-char threshold + coord guard.
    func update(_ text: String) {
        suppressed = false
        query = text
        coordinateJump = nil
        let q = text.trimmingCharacters(in: .whitespaces)
        if let c = Self.parseLatLng(q) {
            completions = []
            coordinateJump = c
            status = String(format: "Jump to %.5f, %.5f", c.latitude, c.longitude)
            return
        }
        guard q.count >= 3 else {
            completions = []
            status = nil
            completer.queryFragment = ""
            return
        }
        completer.queryFragment = q
    }

    func clear() {
        suppressed = true
        query = ""
        completions = []
        coordinateJump = nil
        status = nil
        completer.queryFragment = ""
    }

    /// Called the instant a suggestion is tapped: collapse the list now and
    /// silence the completer so its in-flight result can't reopen it.
    func dismissSuggestions() {
        suppressed = true
        completions = []
        completer.queryFragment = ""
    }

    /// Resolve a chosen suggestion (or the raw query) to a coordinate + label.
    func resolve(_ completion: MKLocalSearchCompletion?, completionHandler: @escaping (SearchHit?) -> Void) {
        let request: MKLocalSearch.Request
        if let completion {
            request = MKLocalSearch.Request(completion: completion)
        } else {
            request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
        }
        if let region { request.region = region }
        MKLocalSearch(request: request).start { resp, _ in
            guard let item = resp?.mapItems.first else {
                Task { @MainActor in self.status = "No match — try a fuller name." }
                completionHandler(nil)
                return
            }
            let c = item.placemark.coordinate
            let title = completion?.title ?? item.name ?? "Result"
            let sub = completion?.subtitle ?? item.placemark.title ?? ""
            completionHandler(SearchHit(title: title, subtitle: sub, coordinate: c))
        }
    }

    // MARK: MKLocalSearchCompleterDelegate

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        Task { @MainActor in
            guard !self.suppressed else { return }
            self.completions = results
        }
    }
    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.completions = [] }
    }

    /// "lat, lng" / "lat lng" → coordinate, else nil (matches src/search.ts).
    static func parseLatLng(_ s: String) -> CLLocationCoordinate2D? {
        let m = s.range(of: #"^\s*(-?\d+(?:\.\d+)?)\s*[, ]\s*(-?\d+(?:\.\d+)?)\s*$"#,
                        options: .regularExpression)
        guard m != nil else { return nil }
        let parts = s.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Double($0) }
        guard parts.count == 2, abs(parts[0]) <= 90, abs(parts[1]) <= 180 else { return nil }
        return CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1])
    }
}
