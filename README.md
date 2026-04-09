# NetworkMonitor

NetworkMonitor is a native macOS menu bar app that shows the processes currently using network bandwidth. The packaged `.app` is the default workflow for this repo; `swift run` is no longer the primary launch path.

## Requirements

- macOS 14 or later
- Xcode 26.4 or later
- Command Line Tools for Xcode

## Default Workflow

Build the app bundle:

```bash
./scripts/build_app.sh
```

Build and open the app:

```bash
./scripts/build_app.sh --open
```

Create a local archive artifact:

```bash
./scripts/archive_app.sh
```

Run the Swift package tests for the core capture and store logic:

```bash
swift test
```

## Output Paths

- Debug app bundle: `.build/xcode/Build/Products/Debug/NetworkMonitor.app`
- Release app bundle: `.build/xcode/Build/Products/Release/NetworkMonitor.app`
- Archive: `.build/archives/NetworkMonitor.xcarchive`

## Manual Smoke Checklist

- Launch the packaged app with `./scripts/build_app.sh --open`.
- Confirm the app appears in the macOS menu bar without a Dock icon.
- Confirm the menu bar label stays compact and shows only `↓ <rate> ↑ <rate>`.
- Hover the menu bar item and confirm the fixed five-row preview panel opens below the menu bar.
- Move the pointer from the status item into the preview panel and confirm it stays open.
- Keep the preview open for at least 20 seconds and confirm it does not jitter or drift under the notch.
- Click the status item and confirm the dashboard window opens or focuses.
- Right-click the status item and confirm `Open`, `Restart Capture`, and `Quit` are available.
- Trigger visible traffic and confirm the ranking changes within a few seconds.
- Use `Restart Capture` and confirm the app recovers while retaining the last good snapshot.

## Notes

- This milestone targets a locally runnable `.app`, not notarized distribution.
- Signing and notarization are intentionally left for a later release pass.
