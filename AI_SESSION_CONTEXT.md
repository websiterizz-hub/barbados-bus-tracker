# AI session context — Barbados bus app (`bus-app-desktop-shadow`)

Use this file to resume work without re-discovering state.

## Primary codebase

- **Flutter app:** `flutter_app/` (Barbados Bus Demo).
- **API:** `src/` (Node/Express). Run locally for live data; Flutter defaults to `API_BASE_URL` (`http://127.0.0.1:3000`).

## Recent feature work (home / map / alerts)

### ETA + “passed you” on live bus cards

- **Issue:** Vehicles from **tracked routes** (`/api/tracked`) often have **no `distance_m`**; only `/api/nearby` vehicles include it. Cards showed distance to **stop** but **no ETA** and **no red “passed”** state.
- **Fix (Flutter):** `home_page.dart` computes **crow-flight user→bus** meters via `latlong2` `Distance` when `vehicle.distanceMeters` is null (`_userToVehicleMeters`, `_effectiveDistanceUserToVehicle`). Distance line uses **`NNN m from you`** (space before `m`) so it is not confused with minutes.
- **Direction (pass vs approaching):** Prefer **motion vector** (previous GPS → current) dotted with **bus → you** in a local ENU plane. Negative dot ⇒ **passed / moving away**; positive ⇒ **approaching**. Telemetry **heading** is only a fallback (often wrong vs true motion). ETA **`Reach you in ~H M S`** is shown **only** when state is **approaching** — never for unknown or passed (avoids bogus multi‑minute ETAs when the bus is receding).
- **Time/distance UI:** Shared helpers in `lib/core/time_format.dart` — `formatDurationHms` (always `H/M/S` style) and `formatArrivalEtaForDisplay` (tracking uses seconds → HMS; else API labels). Countdowns to stop use HMS too. Distances use a **space** before **`m`** (e.g. `184 m`) so they are not read as minutes.
- **Map focus:** Card tap / **Fit you + bus** runs `fitCamera` on **bus + user** (when GPS known). **Follow bus only** locks the camera on the bus until the user uses **Fit you + bus** again.

### Proximity radius alerts

- **Inner alert radius:** `~45%` of the scan radius, clamped **200–650 m** (`_proximityAlertRadiusMeters`).
- **In-app:** `MaterialBanner` (orange) lists buses inside that radius until **DISMISS**; clears when none in range.
- **Sound:** `SystemSound.alert` throttled ~**28s** while buses stay inside radius.
- **Android:** `showStickyLocalAlert` + `showWatchEvent` pass `sticky: true` for near-stop / pass / proximity; `MainActivity` uses `setOngoing(true)` when sticky.
- **Snackbars:** Near-stop / observed pass arrivals use **longer** duration (~2 min) + close icon.

### Earlier session (same repo)

- Stop API: optional `?lat=&lng=` for walk + watch labels; derived ETA when feed ETA is 0.
- `AppBarBackAction` on search / stop / route pages.

## Verify changes in UI

1. **Rebuild** the Flutter app (hot restart is not always enough after Kotlin/Dart API changes):  
   `cd flutter_app && flutter run -d windows` (or your device).
2. Ensure **location** is on and **API** is running if you expect live vehicles.

## Duplicate tree

A copy may exist under `Desktop\🟢 Projects\bus app\` — if behavior diverges, merge from this `bus-app-desktop-shadow` tree.
