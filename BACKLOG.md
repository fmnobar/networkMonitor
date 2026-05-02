# Backlog

Priorities are ordered by user impact, implementation risk, and how much each item unlocks later UI work.

## Completed

### Make preview/dashboard smoke testing deterministic

**Completed:** Added `./scripts/build_app.sh --smoke-ui`, debug launch flags for dashboard and preview, launch-option tests, and README smoke instructions.

**Verified:**
- `swift test`
- `./scripts/build_app.sh --smoke-ui`
- Manual screenshot confirmed the menu-bar label, preview panel, and dashboard window are visible.

### 1. Add a visible dashboard restart action

**Completed:** Added a native dashboard toolbar action for `Restart Capture`, backed by the existing restart callback, with restart disabled while capture is starting or retrying.

**Verified:**
- `swift test`
- `./scripts/build_app.sh --smoke-ui`
- Manual smoke confirmed the dashboard toolbar action, preview panel, menu-bar label, and clean quit behavior.

## P0

### 2. Make the process table more glanceable

**Why:** The current dashboard is accurate but visually flat. Users need to identify the top network consumers quickly.

**Scope:**
- Add app/process icons where available.
- Add share bars or compact visual magnitude indicators.
- Improve download/upload direction scanning without adding clutter.
- Preserve sortable columns and search.

**Acceptance:**
- Top consumers are visually obvious at a glance.
- Long process names and small windows do not break layout.
- Table sorting/search behavior remains intact.

## P1

### 3. Improve preview empty and low-traffic states

**Why:** The preview filters rows below `1_024 B/s`, so it can look empty even while the menu-bar label still shows traffic.

**Scope:**
- Add clear copy when traffic exists but is below the preview threshold.
- Consider showing the highest low-traffic rows dimmed, or make the threshold configurable.
- Keep the fixed five-row preview layout stable.

**Acceptance:**
- Empty preview states explain whether capture is starting, idle, filtered, or failed.
- The menu-bar label and preview no longer appear contradictory.

## P2

### 4. Expose capture history with lightweight trends

**Why:** The store already keeps raw history for averages, but the UI only surfaces current/average numbers. Small trends would make the dashboard more useful without changing capture plumbing.

**Scope:**
- Add sparklines for total download/upload.
- Add more average windows such as 1 minute and 5 minutes if memory/runtime impact stays low.
- Consider a "top process over time" detail area.

**Acceptance:**
- Users can see whether traffic is rising, falling, or spiking.
- Existing live and average behavior remains correct.

### 5. Add preferences for common behavior

**Why:** Capture interval, average windows, launch behavior, process filtering, display units, and preview threshold are currently hardcoded.

**Scope:**
- Add a native settings window.
- Store preferences with `@AppStorage` or a small preferences store.
- Support launch at login only if it can be implemented cleanly and verified.

**Acceptance:**
- Preferences persist across launches.
- Defaults preserve current behavior.
- Settings do not require opening the dashboard.

### 6. Split large UI/support files

**Why:** `Views.swift` and `AppSupport.swift` each mix multiple responsibilities. Splitting them will reduce risk as UI behavior grows.

**Scope:**
- Move preview view, dashboard view, status item controller, preview panel controller, positioning, and interaction model into focused files.
- Keep behavior unchanged during the split.
- Avoid broad architecture changes until tests are added around the surfaces being moved.

**Acceptance:**
- No behavior change.
- Tests and app build pass.
- File ownership is clearer for future work.

## Recommended Next Planning

Plan **P0: Make the process table more glanceable** next.

After that, plan **P1: Improve preview empty and low-traffic states**. The first item is now the highest-value dashboard UI improvement; the second addresses the remaining preview/dashboard mismatch.
