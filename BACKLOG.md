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

### 4. Expose capture history with lightweight trends

**Completed:** Added compact dashboard sparklines for total download/upload, retained one minute of raw history, and exposed a `1 min` average window without changing capture plumbing.

**Verified:**
- `swift test`
- `./scripts/build_app.sh --smoke-ui`
- Manual smoke confirmed dashboard sparklines, the `1 min` average option, preview panel, menu-bar label, and clean quit behavior.

### 5. Add preferences for common behavior

**Completed:** Added a native Settings window for presentation preferences, persisted defaults for mode/window, preview threshold, rate units, and dashboard row visibility, and exposed Settings from the status menu and `Command-,`.

**Verified:**
- `swift test`
- `./scripts/build_app.sh --smoke-ui`
- Manual smoke confirmed Settings opens from the status menu and `Command-,`, preferences update dashboard/preview presentation, the menu-bar label remains compact, the app has no Dock icon, and clean quit behavior.

## P2

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

Plan **P2: Split large UI/support files** next.

After that, plan launch-at-login support as a focused follow-up if it can be implemented and verified cleanly.
