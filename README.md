# DigMaps Field

Your live GPS dot on a historic map — the phone half of [DigMaps](https://digrallies.com).
The desktop web app georeferences the old map and exports an `.mbtiles`; this app
shows where you're standing on it, fully offline. No accounts, no server: a map is
a file you own.

Built the **Trio/Loop "browser build"** way — GitHub's macOS runners compile it and
push to TestFlight. No Mac or Xcode needed.

## One-time setup (~10 minutes, mostly waiting on Actions)

1. **Fork or push this repo** to your GitHub account.
2. **Secrets** — the same six secrets every DIY browser-built app uses
   (you already have these from Trio; if they're org-level, you're done):
   `TEAMID`, `FASTLANE_ISSUER_ID`, `FASTLANE_KEY_ID`, `FASTLANE_KEY`,
   `GH_PAT`, `MATCH_PASSWORD`
   → repo Settings → Secrets and variables → Actions (skip if set at org level).
   The `GH_PAT` needs `repo` and `workflow` scope (it creates/reads your private
   `Match-Secrets` repo).
3. **Actions tab → enable workflows**, then run in order:
   1. **Validate Secrets** — checks all six and creates `Match-Secrets` if missing.
   2. **Add Identifiers** — registers `org.digmaps.<TEAMID>.field` with Apple.
   3. **Build DigMaps Field** — ~15 min; the build lands in App Store Connect.
4. **App Store Connect** → My Apps → *(create the app record the first time:
   New App, bundle id `org.digmaps.<TEAMID>.field`, any SKU)* → TestFlight →
   add yourself to Internal Testing.
5. **On the phone**: install via TestFlight.

A scheduled monthly build keeps TestFlight from expiring (90-day limit), same as Trio.

## Getting a map onto the phone

In DigMaps (web): load scan → anchor → **Export MBTiles (phone)**. Then either:

- **AirDrop** the `.mbtiles` to the phone → share sheet → DigMaps Field, or
- save it to **iCloud Drive/Files** and tap **+** inside the app, or
- drop it in the app's **Documents/Maps** folder (visible in Files — file sharing is on).

Open the map, swing away. Slider sets old-map opacity over the muted Apple base;
`map` button re-frames the map, `location` button follows you.

## Repo layout

```
project.yml                  XcodeGen spec — CI generates the .xcodeproj (none committed)
Config.xcconfig              bundle id / versions; TEAMID injected by CI
DigMapsField/                SwiftUI app (zero third-party dependencies)
  DigMapsFieldApp.swift      entry; onOpenURL import
  ContentView.swift          map library list + fileImporter + empty state
  MapScreen.swift            MKMapView wrapper, GPS dot, opacity slider, fit/follow
  MBTilesOverlay.swift       MKTileOverlay reading tiles from MBTiles via system SQLite3
  MapStore.swift             Documents/Maps file management
fastlane/                    match + gym + pilot lanes (Trio conventions)
.github/workflows/           1 validate → 2 identifiers → 3 build
```

## Roadmap

- **v0.2** — heading arrow, multiple-map quick switcher polish
- **v0.3** — drop a pin where you're standing, export finds as GeoJSON back to DigMaps desktop
- **later** — Apple Watch glance, offline base layer
