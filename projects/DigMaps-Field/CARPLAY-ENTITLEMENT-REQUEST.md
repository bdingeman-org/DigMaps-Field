# CarPlay Entitlement Request — DigMaps Field

CarPlay code is built and compile-verified on branch `dev/v0.7-carplay`, but the app
**cannot run on the car screen until Apple grants the navigation entitlement**
`com.apple.developer.carplay-maps`. Apple grants this manually (days–weeks) and it must
be in the provisioning profile before a signed build. **Do not merge `dev/v0.7-carplay`
to `main` or run the TestFlight build until the entitlement is granted** — a signed build
that declares the CarPlay scene without the entitlement in the profile will fail or be rejected.

## How to request

1. Go to https://developer.apple.com/contact/carplay/ (signed in to the developer account).
2. Category: **Navigation** (`com.apple.developer.carplay-maps`) — the only CarPlay category
   that lets an app draw its own map. Request this ONE category only (mixing categories is a
   common rejection reason).
3. App name: **DigMaps Field**.  Bundle ID: **org.digmaps.<TEAMID>.field**.
4. Paste the justification below.
5. Accept the CarPlay Entitlement Agreement.

## Justification text to paste

> DigMaps Field is an offline navigation app for backcountry and unmaintained/historic
> roads. It shows the driver's live GPS position on georeferenced 18th–19th-century maps
> and historic aerial imagery — the kind of old roads, farm lanes, and abandoned routes
> that modern basemaps don't show. The driver sees where they are on the historic map while
> driving the actual road, with a glanceable, template-only CarPlay interface: a follow-me
> recenter button, an overlay-source toggle, and an overlay show/hide button — no custom
> UI, no text entry, no distracting elements. This is the same category of map-centric
> outdoor navigation app as Gaia GPS and onX Offroad, which hold the CarPlay navigation
> entitlement. The companion iPhone app is already live on TestFlight and substantively
> built (map import, GPS positioning, overlay catalog, place search), not a placeholder.

## Honest notes for the reviewer / for us

- There is **no turn-by-turn guidance yet** — DigMaps Field is positional ("you are here on
  the old map"), not route-guided. Some reviewers expect turn-by-turn for the navigation
  category. If rejected on that basis, the fallback is to add **saved-route following**
  (load a GeoJSON/GPX track the user recorded, draw it, and show progress along it) and
  reapply — that brings it firmly into the navigation use case without inventing turn
  instructions for trackless terrain.
- Safety posture: all CarPlay controls are large CPMapButtons; nothing requires reading or
  typing while moving. Overlay tiles are pre-cached (offline MBTiles) or streamed; the map
  itself is the only content.

## What's already done (branch `dev/v0.7-carplay`)

- `CarPlaySceneDelegate.swift` — `CPTemplateApplicationSceneDelegate`; on connect builds an
  `MKMapView` in the CarPlay `carWindow` (showsUserLocation = the GPS dot, follow tracking)
  and presents a `CPMapTemplate` with three map buttons.
- `OverlayFactory.swift` — shared overlay construction used by BOTH the phone UI and CarPlay
  so they render identically (offline MBTiles / NYS hillshade / NYS aerial year / historic).
- `Info.plist` — `UIApplicationSceneManifest` declaring the CarPlay scene (SwiftUI keeps the
  phone window scene implicitly).
- `DigMapsField.entitlements` — `com.apple.developer.carplay-maps`, referenced from
  `project.yml` (`CODE_SIGN_ENTITLEMENTS`) on this branch only.
- Compile-verified via the signing-free CI lane (no entitlement needed to compile).

## After Apple grants it

1. Enable the entitlement on the App ID in the developer portal; regenerate the provisioning
   profile (fastlane `match` will pick it up).
2. Merge `dev/v0.7-carplay` → `main`, run the TestFlight build.
3. Test in the CarPlay Simulator (needs a Mac + Xcode) or directly in the car via TestFlight.
