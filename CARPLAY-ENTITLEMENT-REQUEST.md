# CarPlay Entitlement Request — DigMaps Field

CarPlay code is built and compile-verified on branch `dev/v0.8-routes` (route-following on
top of the `dev/v0.7-carplay` scene), but the app **cannot run on the car screen until Apple
grants the navigation entitlement** `com.apple.developer.carplay-maps`. Apple grants this
manually (days–weeks) and it must be in the provisioning profile before a signed build.
**Do not merge to `main` or run the TestFlight build until the entitlement is granted** — a
signed build that declares the CarPlay scene without the entitlement in the profile will fail
or be rejected.

## How to request

1. Go to https://developer.apple.com/contact/carplay/ (signed in to the developer account).
2. Category: **Navigation** (`com.apple.developer.carplay-maps`) — the only CarPlay category
   that lets an app draw its own map. Request this ONE category only (mixing categories is a
   common rejection reason).
3. App name: **DigMaps Field**.  Bundle ID: **org.digmaps.<TEAMID>.field**.
4. Paste the justification below.
5. Accept the CarPlay Entitlement Agreement.

## Justification text to paste

> DigMaps Field is an offline route-following navigation app for backcountry and
> unmaintained/historic roads. The driver loads a route they recorded or planned (a GPX or
> GeoJSON track), and the app guides them along it — drawing the route line on the map,
> following their live GPS position, and showing distance remaining to the end of the route —
> all rendered over georeferenced 18th–19th-century maps and historic aerial imagery that
> show the old roads, farm lanes, and abandoned routes modern basemaps omit. The CarPlay
> interface is glanceable and template-only: a follow-me recenter button, a route show/hide
> button, an overlay-source toggle, an overlay show/hide button, and a distance-remaining
> readout in the navigation bar — no custom-drawn UI, no text entry, no distracting elements.
> This is the same category of map-centric outdoor navigation app as Gaia GPS and onX
> Offroad, which hold the CarPlay navigation entitlement. The companion iPhone app is already
> live on TestFlight and substantively built (map import, route import + following, GPS
> positioning, overlay catalog, place search), not a placeholder.

## Honest notes for the reviewer / for us

- DigMaps Field does **route following**, not synthesized turn-by-turn voice guidance. It
  guides along a track the user supplies and shows distance-remaining — the right model for
  trackless/historic terrain, where inventing "turn left in 200 ft" instructions would be
  meaningless. This is the same posture as backcountry navigation apps that hold the
  entitlement. (Earlier draft of this request was purely positional, "you are here"; route
  following was added on `dev/v0.8-routes` specifically to put it firmly in the navigation
  use case. Kept here as the record of why.)
- Safety posture: all CarPlay controls are large CPMapButtons / a single nav-bar readout;
  nothing requires reading dense text or typing while moving. Overlay tiles are pre-cached
  (offline MBTiles) or streamed; the map and the route line are the only content.

## What's already done (branch `dev/v0.8-routes`)

- `CarPlaySceneDelegate.swift` — `CPTemplateApplicationSceneDelegate`; on connect builds an
  `MKMapView` in the CarPlay `carWindow` (showsUserLocation = the GPS dot, follow tracking),
  draws the active route polyline, presents a `CPMapTemplate` with four map buttons
  (recenter / cycle source / overlay toggle / route toggle), and updates a leading nav-bar
  button with live distance-remaining as GPS fixes arrive.
- `Route.swift` / `RouteStore.swift` — GPX + GeoJSON parsing, route library in
  `Documents/Routes`, active-route selection persisted in `UserDefaults` so the CarPlay scene
  and the phone UI follow the same route without a shared object. Progress-along-track math
  (nearest-segment projection → traveled / remaining / off-route distance).
- `OverlayFactory.swift` — shared overlay + route-line construction used by BOTH the phone UI
  and CarPlay so they render identically (offline MBTiles / NYS hillshade / NYS aerial year /
  historic, plus the gold route polyline).
- `MapHomeView.swift` — phone-side route import, picker, show/hide, fit-to-route, and a
  progress readout (distance left · % complete, with an off-route warning).
- `Info.plist` — `UIApplicationSceneManifest` declaring the CarPlay scene (SwiftUI keeps the
  phone window scene implicitly); GPX/GeoJSON document types for "Open in DigMaps Field".
- `DigMapsField.entitlements` — `com.apple.developer.carplay-maps`, referenced from
  `project.yml` (`CODE_SIGN_ENTITLEMENTS`) on the CarPlay branch line only.
- Compile-verified via the signing-free CI lane (no entitlement needed to compile).

## After Apple grants it

1. Enable the entitlement on the App ID in the developer portal; regenerate the provisioning
   profile (fastlane `match` will pick it up).
2. Merge `dev/v0.8-routes` → `main`, run the TestFlight build.
3. Test in the CarPlay Simulator (needs a Mac + Xcode) or directly in the car via TestFlight.
   Load a GPX track on the phone first; confirm the route line + distance-remaining appear on
   the car screen.
