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

### 2. Make the process table more glanceable

**Completed:** Kept the native sortable dashboard table and added per-process icons, direction-accented rate cells, and compact share bars for faster scanning.

**Verified:**
- `swift test`
- `./scripts/build_app.sh --smoke-ui`
- Manual smoke confirmed table icons, share bars, direction cells, preview, and clean quit behavior.

### 3. Improve preview empty and low-traffic states

**Completed:** Added fixed five-row preview presentation with active rows first, dimmed low-traffic rows filling open slots, and filtering copy when low-traffic rows explain menu-bar totals.

**Verified:**
- `swift test`
- `./scripts/build_app.sh --smoke-ui`
- Manual smoke confirmed the preview panel, dashboard, menu-bar label, and clean quit behavior.

## P0

### 4. Expose capture history with lightweight trends

**Why:** The store already keeps raw history for averages, but the UI only surfaces current/average numbers. Small trends would make the dashboard more useful without changing capture plumbing.

**Scope:**
- Add sparklines for total download/upload.
- Add more average windows such as 1 minute and 5 minutes if memory/runtime impact stays low.
- Consider a "top process over time" detail area.

**Acceptance:**
- Users can see whether traffic is rising, falling, or spiking.
- Existing live and average behavior remains correct.

## P2

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

Plan **P0: Expose capture history with lightweight trends** next.

After that, plan **P2: Add preferences for common behavior**. Trends are now the highest-impact visible improvement before moving threshold and display choices into settings.
