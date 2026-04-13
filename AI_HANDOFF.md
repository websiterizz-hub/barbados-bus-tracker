# AI handoff — Barbados Bus Tracker (`bus app`)

**Convention:** When you make user-visible or build-affecting changes in this repo, **append a short entry to the “Change log” section below** so the next session can continue without re-discovering paths, duplicate folders, or branding locations.

---

## Critical: which folder to build

The user launches the app with a **`.bat` on the Desktop**. That script must run Flutter from **this workspace**:

`c:\Users\adam\Desktop\bus app\flutter_app`

Older build artifacts under paths like `bus-app-desktop-shadow\flutter_app` will **not** include edits from this repo. If the UI never updates, **check the `.bat` working directory** and rebuild here.

---

## Where “Barbados Bus Tracker” must be updated

| What the user sees | File(s) |
|--------------------|---------|
| **Windows title bar** (was `barbados_bus_demo`) | `flutter_app\windows\runner\main.cpp` — first argument to `window.Create(L"...")` |
| In-app top bar (home) | `flutter_app\lib\features\home\home_page.dart` — `AppBar` `title` |
| Task switcher / web tab title | `flutter_app\lib\app.dart` — `MaterialApp.router` `title` |
| Android launcher name | `flutter_app\android\app\src\main\AndroidManifest.xml` — `android:label` |
| Windows “Product name” in file properties | `flutter_app\windows\runner\Runner.rc` — `ProductName`, `FileDescription` |
| Executable **filename** on disk | `flutter_app\windows\CMakeLists.txt` — `BINARY_NAME` (still `barbados_bus_demo` unless intentionally renamed; changing it breaks shortcuts/bats that point at the old `.exe`) |

**Dart package name** remains `barbados_bus_demo` in `pubspec.yaml` (`name:`). That is normal; it does not have to match the marketing title.

---

## Quick verify (after `flutter build windows` or `flutter run -d windows`)

From `flutter_app`:

```powershell
Select-String -Path "windows\runner\main.cpp" -Pattern "Barbados Bus Tracker"
Select-String -Path "lib\features\home\home_page.dart" -Pattern "Barbados Bus Tracker"
```

You should see matches in both files. If `main.cpp` still says `barbados_bus_demo` in `Create()`, the window title will stay wrong.

---

## Recent UX / logic notes

- **“No all bus”** on the map overlay was bad grammar: empty-map copy is `_emptyNearbyMapMessage` in `home_page.dart` (filter-specific sentences).
- **“Duplicate” school routes** (e.g. SCH 115 vs SCH 125B to the same destination): usually **different timetabled services** sharing one corridor name. The routes list explains this and each row shows **Service {number} · Scheduled …** (or ETA when live).
- **Area alerts** dedupe same-vehicle events across multiple watched stops in `_dedupeAreaAlerts` in `home_page.dart`.
- **Route radar** dedupes by `route.id` when building focus matches.

---

## Windows desktop build failures (C1083 / LNK1104)

**C1083 — missing `cpp_client_wrapper\*.cc` under `windows\flutter\ephemeral\`**

- Those sources are **generated/copied by Flutter** during `flutter build windows`, not committed to git. A broken or partial build can leave CMake pointing at an empty `ephemeral` folder.
- **Fix:** Close the running app, then from `flutter_app`: `flutter clean`, `flutter pub get`, `flutter build windows --release`.
- **Do not** open the `.vcxproj` in Visual Studio and build without going through `flutter build` first, or `ephemeral` may stay incomplete.

**LNK1104 — cannot open `barbados_bus_demo.exe` for writing**

- The linker cannot overwrite the exe while **the app is still running**, or while another process locks the file (Explorer, antivirus scan).
- **Fix:** Quit Barbados Bus Tracker, end `barbados_bus_demo.exe` in Task Manager if needed, then build again.

**Shipped launchers (repo `scripts/` folder)**

- `scripts\Run-BarbadosBusTracker.bat` — kills a running instance, then starts the Release exe; **builds automatically** if the exe does not exist yet.
- `scripts\Build-BarbadosBusTracker.bat` — kills running instance, then `flutter pub get` + `flutter build windows --release`.
- Copy a shortcut to **Desktop** pointing at `Run-BarbadosBusTracker.bat` (keep the `scripts` folder next to `flutter_app` so paths work).

---

## Change log (newest first)

- **2026-04-13 (b)** — Documented Windows `ephemeral` / linker lock issues; added `scripts/Run-BarbadosBusTracker.bat` and `scripts/Build-BarbadosBusTracker.bat` (taskkill before build). Verified `flutter build windows --release` after closing the running exe.
- **2026-04-13** — Windows title bar: set `window.Create` title to `Barbados Bus Tracker` in `windows/runner/main.cpp` (this was why the title still showed `barbados_bus_demo` after Dart/Rc changes). Fixed map overlay empty-state copy (“No all bus” → proper filter messages). Clarified “same corridor, different route number” in Routes Around You + per-row **Service · Scheduled/ETA** line. Added this `AI_HANDOFF.md` and the standing rule to update it.
