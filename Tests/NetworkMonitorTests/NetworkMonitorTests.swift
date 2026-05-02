import Testing
@testable import NetworkMonitor
import AppKit
import CoreGraphics
import Foundation

@Test
func parserFlushesOnRepeatedHeadersAndHandlesDottedNames() {
    var parser = NettopCSVStreamParser(now: { Date(timeIntervalSince1970: 1_000) })

    let header = "\u{04}\u{08}\u{08}time,,interface,state,bytes_in,bytes_out,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,tx_win,tc_class,tc_mgt,cc_algo,P,C,R,W,"
    let lines = [
        header,
        "18:04:43.912151,com.apple.WebKit.Networking.1398,,,1024,2048,0,0,0,,,,,,,,,,,",
        "18:04:43.912385,malformed-row,,,oops,12",
        "18:04:43.912538,Helper.2000,,,0,0,0,0,0,,,,,,,,,,,",
        header
    ]

    let snapshots = lines.flatMap { parser.consume(line: $0) }

    #expect(snapshots.count == 1)
    #expect(snapshots[0].processes.count == 1)
    #expect(snapshots[0].processes[0].name == "com.apple.WebKit.Networking")
    #expect(snapshots[0].processes[0].pid == 1398)
    #expect(snapshots[0].processes[0].downloadBytesPerSecond == 1024)
    #expect(snapshots[0].processes[0].uploadBytesPerSecond == 2048)
    #expect(snapshots[0].processes[0].shareOfTotal == 1)
}

@Test
func parserAggregatesDuplicateProcessesAndComputesShares() {
    var parser = NettopCSVStreamParser(now: { Date(timeIntervalSince1970: 2_000) })

    let header = "time,,interface,state,bytes_in,bytes_out,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,tx_win,tc_class,tc_mgt,cc_algo,P,C,R,W,"
    _ = parser.consume(line: header)
    _ = parser.consume(line: "18:04:43.912151,Safari.1288,,,1000,500,0,0,0,,,,,,,,,,,")
    _ = parser.consume(line: "18:04:43.912385,Safari.1288,,,500,500,0,0,0,,,,,,,,,,,")
    _ = parser.consume(line: "18:04:43.912538,ChatGPT.35185,,,100,100,0,0,0,,,,,,,,,,,")

    let snapshot = parser.finish()

    #expect(snapshot != nil)
    #expect(snapshot?.totalDownloadBytesPerSecond == 1600)
    #expect(snapshot?.totalUploadBytesPerSecond == 1100)
    #expect(snapshot?.processes.count == 2)
    #expect(snapshot?.processes.first?.name == "Safari")
    #expect(snapshot?.processes.first?.totalBytesPerSecond == 2500)
    #expect(snapshot?.processes.first?.shareOfTotal == Double(2500) / Double(2700))
}

@Test
func compactStatusLabelUsesBoundedRateFormatting() {
    let snapshot = LiveSnapshot(
        capturedAt: Date(timeIntervalSince1970: 2_500),
        totalDownloadBytesPerSecond: 125_829_120,
        totalUploadBytesPerSecond: 1_536,
        processes: []
    )

    let label = NetworkFormatting.statusLabel(for: snapshot)

    #expect(label == "↓ 120M ↑ 1.5K")
    #expect(!label.contains("/s"))
    #expect(label.count <= StatusPreviewLayout.statusItemReferenceText.count)
}

@Test
func normalizedShareClampsToRenderableRange() {
    #expect(NetworkFormatting.normalizedShare(-0.25) == 0)
    #expect(NetworkFormatting.normalizedShare(.nan) == 0)
    #expect(NetworkFormatting.normalizedShare(.infinity) == 0)
    #expect(NetworkFormatting.normalizedShare(0.42) == 0.42)
    #expect(NetworkFormatting.normalizedShare(1.4) == 1)
}

@MainActor
@Test
func preferencesDefaultToCurrentPresentationBehavior() {
    let defaults = isolatedUserDefaults()
    let preferences = NetworkMonitorPreferences(userDefaults: defaults)

    #expect(preferences.defaultDisplayMode == .live)
    #expect(preferences.defaultAverageWindow == .fifteenSeconds)
    #expect(preferences.previewThreshold == .oneKilobyte)
    #expect(preferences.previewMinimumBytesPerSecond == 1_024)
    #expect(preferences.rateUnitStyle == .binary)
    #expect(preferences.dashboardProcessVisibility == .allActive)
    #expect(NetworkFormatting.compactRate(1_536, unitStyle: preferences.rateUnitStyle) == "1.5K")
}

@MainActor
@Test
func preferencesPersistPresentationValues() {
    let defaults = isolatedUserDefaults()
    let preferences = NetworkMonitorPreferences(userDefaults: defaults)

    preferences.defaultDisplayMode = .average
    preferences.defaultAverageWindow = .oneMinute
    preferences.previewThreshold = .tenKilobytes
    preferences.rateUnitStyle = .decimal
    preferences.dashboardProcessVisibility = .abovePreviewThreshold

    let reloadedPreferences = NetworkMonitorPreferences(userDefaults: defaults)
    #expect(reloadedPreferences.defaultDisplayMode == .average)
    #expect(reloadedPreferences.defaultAverageWindow == .oneMinute)
    #expect(reloadedPreferences.previewThreshold == .tenKilobytes)
    #expect(reloadedPreferences.previewMinimumBytesPerSecond == 10_240)
    #expect(reloadedPreferences.rateUnitStyle == .decimal)
    #expect(reloadedPreferences.dashboardProcessVisibility == .abovePreviewThreshold)
}

@Test
func trafficTrendSeriesHandlesEmptyHistoryAndInvalidNormalization() {
    let emptySeries = TrafficTrendSeries(snapshots: [], value: \.totalDownloadBytesPerSecond)

    #expect(emptySeries.samples.isEmpty)
    #expect(emptySeries.direction == .flat)
    #expect(TrafficTrendSeries.normalizedValue(-1, maximum: 100) == 0)
    #expect(TrafficTrendSeries.normalizedValue(.nan, maximum: 100) == 0)
    #expect(TrafficTrendSeries.normalizedValue(.infinity, maximum: 100) == 0)
    #expect(TrafficTrendSeries.normalizedValue(100, maximum: .nan) == 0)
    #expect(TrafficTrendSeries.normalizedValue(100, maximum: 0) == 0)
    #expect(TrafficTrendSeries.normalizedValue(150, maximum: 100) == 1)
    #expect(TrafficTrendSeries.normalizedValue(42, maximum: 100) == 0.42)
}

@Test
func trafficTrendSeriesOrdersSamplesInsideOneMinuteWindow() {
    let baseTime = Date(timeIntervalSince1970: 3_000)
    let series = TrafficTrendSeries(
        snapshots: [
            trendSnapshot(capturedAt: baseTime.addingTimeInterval(61), download: 400),
            trendSnapshot(capturedAt: baseTime, download: 100),
            trendSnapshot(capturedAt: baseTime.addingTimeInterval(40), download: 300),
            trendSnapshot(capturedAt: baseTime.addingTimeInterval(10), download: 200)
        ],
        value: \.totalDownloadBytesPerSecond
    )

    #expect(series.samples.map(\.capturedAt) == [
        baseTime.addingTimeInterval(10),
        baseTime.addingTimeInterval(40),
        baseTime.addingTimeInterval(61)
    ])
    #expect(series.samples.map(\.bytesPerSecond) == [200, 300, 400])
}

@Test
func trafficTrendSeriesNormalizesSpikesAndReportsDirection() {
    let baseTime = Date(timeIntervalSince1970: 3_100)
    let series = TrafficTrendSeries(
        snapshots: [
            trendSnapshot(capturedAt: baseTime, download: 10),
            trendSnapshot(capturedAt: baseTime.addingTimeInterval(10), download: 50),
            trendSnapshot(capturedAt: baseTime.addingTimeInterval(20), download: 100)
        ],
        value: \.totalDownloadBytesPerSecond
    )

    #expect(abs(series.samples[0].normalizedValue - 0.1) < 0.0001)
    #expect(series.samples[1].normalizedValue == 0.5)
    #expect(series.samples[2].normalizedValue == 1)
    #expect(series.direction == .rising)
    #expect(TrafficTrendSeries.direction(for: [100, 70, 40]) == .falling)
    #expect(TrafficTrendSeries.direction(for: [100, 104]) == .flat)
    #expect(TrafficTrendSeries.direction(for: [0, 0, 0]) == .flat)
}

@Test
func launchOptionsDefaultToNoDebugUI() {
    let options = NetworkMonitorLaunchOptions(arguments: ["/Applications/NetworkMonitor.app/Contents/MacOS/NetworkMonitor"])

    #expect(!options.showPreviewOnLaunch)
    #expect(!options.openDashboardOnLaunch)
}

@Test
func launchOptionsCanEnablePreviewOnly() {
    let options = NetworkMonitorLaunchOptions(arguments: [
        "NetworkMonitor",
        "--debug-show-preview"
    ])

    #expect(options.showPreviewOnLaunch)
    #expect(!options.openDashboardOnLaunch)
}

@Test
func launchOptionsCanEnableDashboardOnly() {
    let options = NetworkMonitorLaunchOptions(arguments: [
        "NetworkMonitor",
        "--debug-open-dashboard"
    ])

    #expect(!options.showPreviewOnLaunch)
    #expect(options.openDashboardOnLaunch)
}

@Test
func launchOptionsCanEnablePreviewAndDashboard() {
    let options = NetworkMonitorLaunchOptions(arguments: [
        "NetworkMonitor",
        "--debug-open-dashboard",
        "--debug-show-preview"
    ])

    #expect(options.showPreviewOnLaunch)
    #expect(options.openDashboardOnLaunch)
}

@Test
func dashboardManualRestartAvailabilityMatchesCaptureState() {
    let captureTime = Date(timeIntervalSince1970: 2_750)
    let snapshot = LiveSnapshot(
        capturedAt: captureTime,
        totalDownloadBytesPerSecond: 128,
        totalUploadBytesPerSecond: 64,
        processes: []
    )
    let recoveryState = CaptureRecoveryState(
        message: "Restarting capture.",
        attempt: 0,
        nextRetryDate: nil,
        lastSuccessfulCaptureAt: captureTime
    )

    let disabledStates: [DashboardViewState] = [
        .starting,
        .retrying(snapshot: nil, status: recoveryState),
        .retrying(snapshot: snapshot, status: recoveryState)
    ]

    let enabledStates: [DashboardViewState] = [
        .live(snapshot),
        .noTraffic(snapshot),
        .stalled(snapshot: snapshot, message: "No fresh sample."),
        .failed(snapshot: nil, message: "nettop failed."),
        .failed(snapshot: snapshot, message: "nettop failed."),
        .stopped(snapshot: nil),
        .stopped(snapshot: snapshot)
    ]

    #expect(disabledStates.allSatisfy { !$0.allowsManualRestart })
    #expect(enabledStates.allSatisfy { $0.allowsManualRestart })
}

@MainActor
@Test
func storeFiltersAndSortsDisplayedProcesses() {
    let store = TrafficDashboardStore(
        captureService: NettopCaptureService(producer: MockProducer(scripts: [])),
        preferences: testPreferences()
    )
    let snapshot = LiveSnapshot(
        capturedAt: Date(timeIntervalSince1970: 3_000),
        totalDownloadBytesPerSecond: 900,
        totalUploadBytesPerSecond: 600,
        processes: [
            ProcessUsage(pid: 1, name: "Safari", downloadBytesPerSecond: 600, uploadBytesPerSecond: 200, totalBytesPerSecond: 800, shareOfTotal: 0.53, lastSeen: Date(timeIntervalSince1970: 3_000)),
            ProcessUsage(pid: 2, name: "Codex", downloadBytesPerSecond: 300, uploadBytesPerSecond: 400, totalBytesPerSecond: 700, shareOfTotal: 0.47, lastSeen: Date(timeIntervalSince1970: 3_000))
        ]
    )

    store.consume(.snapshot(snapshot))
    #expect(store.displayedProcesses.map(\.name) == ["Safari", "Codex"])

    store.searchText = "2"
    #expect(store.displayedProcesses.map(\.name) == ["Codex"])

    store.searchText = ""
    store.sortOrder = [KeyPathComparator(\ProcessUsage.name, order: .forward)]
    #expect(store.displayedProcesses.map(\.name) == ["Codex", "Safari"])
}

@MainActor
@Test
func storeUsesPreferencePreviewThresholdForPreviewRows() {
    let preferences = NetworkMonitorPreferences(userDefaults: isolatedUserDefaults())
    preferences.previewThreshold = .tenKilobytes
    let store = TrafficDashboardStore(
        captureService: NettopCaptureService(producer: MockProducer(scripts: [])),
        preferences: preferences,
        smoothingFactor: 0
    )
    let captureTime = Date(timeIntervalSince1970: 3_100)

    store.consume(.snapshot(LiveSnapshot(
        capturedAt: captureTime,
        totalDownloadBytesPerSecond: 14_000,
        totalUploadBytesPerSecond: 0,
        processes: [
            ProcessUsage(pid: 1, name: "Safari", downloadBytesPerSecond: 12_000, uploadBytesPerSecond: 0, totalBytesPerSecond: 12_000, shareOfTotal: 0.86, lastSeen: captureTime),
            ProcessUsage(pid: 2, name: "Codex", downloadBytesPerSecond: 2_000, uploadBytesPerSecond: 0, totalBytesPerSecond: 2_000, shareOfTotal: 0.14, lastSeen: captureTime)
        ]
    )))

    #expect(previewRowDescriptions(store.previewRows) == [
        "active:Safari",
        "low:Codex",
        "empty",
        "empty",
        "empty"
    ])
    #expect(store.previewFilteringMessage == "Dimmed rows are below the 10 KB/s preview threshold.")
}

@MainActor
@Test
func storeDashboardVisibilityFilterFollowsPreferences() {
    let preferences = NetworkMonitorPreferences(userDefaults: isolatedUserDefaults())
    preferences.previewThreshold = .tenKilobytes
    let store = TrafficDashboardStore(
        captureService: NettopCaptureService(producer: MockProducer(scripts: [])),
        preferences: preferences,
        smoothingFactor: 0
    )
    let captureTime = Date(timeIntervalSince1970: 3_175)

    store.consume(.snapshot(LiveSnapshot(
        capturedAt: captureTime,
        totalDownloadBytesPerSecond: 14_000,
        totalUploadBytesPerSecond: 0,
        processes: [
            ProcessUsage(pid: 1, name: "Safari", downloadBytesPerSecond: 12_000, uploadBytesPerSecond: 0, totalBytesPerSecond: 12_000, shareOfTotal: 0.86, lastSeen: captureTime),
            ProcessUsage(pid: 2, name: "Codex", downloadBytesPerSecond: 2_000, uploadBytesPerSecond: 0, totalBytesPerSecond: 2_000, shareOfTotal: 0.14, lastSeen: captureTime)
        ]
    )))

    #expect(store.displayedProcesses.map(\.name) == ["Safari", "Codex"])

    preferences.dashboardProcessVisibility = .abovePreviewThreshold
    #expect(store.displayedProcesses.map(\.name) == ["Safari"])
}

@MainActor
@Test
func previewRowsShowActiveThenLowTrafficThenEmptySlots() {
    let store = TrafficDashboardStore(
        captureService: NettopCaptureService(producer: MockProducer(scripts: [])),
        preferences: testPreferences(),
        smoothingFactor: 0,
        previewMinimumBytesPerSecond: 1_024
    )
    let captureTime = Date(timeIntervalSince1970: 3_250)

    store.consume(.snapshot(LiveSnapshot(
        capturedAt: captureTime,
        totalDownloadBytesPerSecond: 4_000,
        totalUploadBytesPerSecond: 200,
        processes: [
            ProcessUsage(pid: 1, name: "Safari", downloadBytesPerSecond: 2_000, uploadBytesPerSecond: 0, totalBytesPerSecond: 2_000, shareOfTotal: 0.48, lastSeen: captureTime),
            ProcessUsage(pid: 2, name: "Codex", downloadBytesPerSecond: 1_500, uploadBytesPerSecond: 0, totalBytesPerSecond: 1_500, shareOfTotal: 0.36, lastSeen: captureTime),
            ProcessUsage(pid: 3, name: "Python", downloadBytesPerSecond: 500, uploadBytesPerSecond: 0, totalBytesPerSecond: 500, shareOfTotal: 0.12, lastSeen: captureTime),
            ProcessUsage(pid: 4, name: "Tailscale", downloadBytesPerSecond: 128, uploadBytesPerSecond: 0, totalBytesPerSecond: 128, shareOfTotal: 0.03, lastSeen: captureTime)
        ]
    )))

    #expect(store.topFive.map(\.name) == ["Safari", "Codex"])
    #expect(previewRowDescriptions(store.previewRows) == [
        "active:Safari",
        "active:Codex",
        "low:Python",
        "low:Tailscale",
        "empty"
    ])
    #expect(store.previewFilteringMessage == "Dimmed rows are below the 1 KB/s preview threshold.")
}

@MainActor
@Test
func previewRowsExplainAllLowTrafficWithoutLosingRows() {
    let store = TrafficDashboardStore(
        captureService: NettopCaptureService(producer: MockProducer(scripts: [])),
        preferences: testPreferences(),
        smoothingFactor: 0,
        previewMinimumBytesPerSecond: 1_024
    )
    let captureTime = Date(timeIntervalSince1970: 3_500)

    store.consume(.snapshot(LiveSnapshot(
        capturedAt: captureTime,
        totalDownloadBytesPerSecond: 700,
        totalUploadBytesPerSecond: 80,
        processes: [
            ProcessUsage(pid: 11, name: "Mail", downloadBytesPerSecond: 512, uploadBytesPerSecond: 0, totalBytesPerSecond: 512, shareOfTotal: 0.66, lastSeen: captureTime),
            ProcessUsage(pid: 12, name: "Calendar", downloadBytesPerSecond: 128, uploadBytesPerSecond: 0, totalBytesPerSecond: 128, shareOfTotal: 0.16, lastSeen: captureTime)
        ]
    )))

    #expect(store.topFive.isEmpty)
    #expect(previewRowDescriptions(store.previewRows) == [
        "low:Mail",
        "low:Calendar",
        "empty",
        "empty",
        "empty"
    ])
    #expect(store.previewRows.count == 5)
    #expect(store.previewFilteringMessage == "All visible traffic is below the 1 KB/s preview threshold.")
}

@MainActor
@Test
func previewRowsStayEmptyForStartingAndNoTrafficStates() {
    let store = TrafficDashboardStore(
        captureService: NettopCaptureService(producer: MockProducer(scripts: [])),
        preferences: testPreferences(),
        previewMinimumBytesPerSecond: 1_024
    )

    #expect(previewRowDescriptions(store.previewRows) == Array(repeating: "empty", count: 5))
    #expect(store.previewFilteringMessage == nil)
    #expect(store.stateMessage == "Launching nettop and waiting for the first sample.")

    store.consume(.snapshot(LiveSnapshot(
        capturedAt: Date(timeIntervalSince1970: 3_750),
        totalDownloadBytesPerSecond: 0,
        totalUploadBytesPerSecond: 0,
        processes: []
    )))

    #expect(previewRowDescriptions(store.previewRows) == Array(repeating: "empty", count: 5))
    #expect(store.previewFilteringMessage == nil)
    #expect(store.stateMessage == "No process reported network activity in the latest interval.")
}

@MainActor
@Test
func storePreservesSnapshotWhileRetryingAndMarksStalled() {
    let store = TrafficDashboardStore(
        captureService: NettopCaptureService(producer: MockProducer(scripts: [])),
        preferences: testPreferences(),
        stallThreshold: 3,
        now: { Date(timeIntervalSince1970: 4_000) }
    )
    let snapshot = LiveSnapshot(
        capturedAt: Date(timeIntervalSince1970: 3_995),
        totalDownloadBytesPerSecond: 900,
        totalUploadBytesPerSecond: 600,
        processes: [
            ProcessUsage(pid: 1, name: "Safari", downloadBytesPerSecond: 600, uploadBytesPerSecond: 200, totalBytesPerSecond: 800, shareOfTotal: 0.53, lastSeen: Date(timeIntervalSince1970: 3_995))
        ]
    )

    store.consume(.snapshot(snapshot))
    store.consume(.retrying(CaptureRecoveryState(
        message: "nettop exited unexpectedly.",
        attempt: 1,
        nextRetryDate: Date(timeIntervalSince1970: 4_001),
        lastSuccessfulCaptureAt: snapshot.capturedAt
    )))

    let stabilizedSnapshot = store.snapshot
    if case let .retrying(retrySnapshot, status) = store.viewState {
        #expect(retrySnapshot == stabilizedSnapshot)
        #expect(status.attempt == 1)
    } else {
        Issue.record("Expected retrying state")
    }
    #expect(store.displayedProcesses.map(\.name) == ["Safari"])

    store.consume(.snapshot(snapshot))
    store.evaluateStaleness(now: Date(timeIntervalSince1970: 4_000))
    if case let .stalled(stalledSnapshot, _) = store.viewState {
        #expect(stalledSnapshot == store.snapshot)
    } else {
        Issue.record("Expected stalled state")
    }
}

@MainActor
@Test
func storeSmoothsBurstTrafficAndRetainsProcessesBriefly() {
    let store = TrafficDashboardStore(
        captureService: NettopCaptureService(producer: MockProducer(scripts: [])),
        preferences: testPreferences(),
        smoothingFactor: 0.5,
        visibilityGracePeriod: 5,
        previewMinimumBytesPerSecond: 1_024
    )
    let firstCaptureTime = Date(timeIntervalSince1970: 5_000)
    let secondCaptureTime = Date(timeIntervalSince1970: 5_001)
    let thirdCaptureTime = Date(timeIntervalSince1970: 5_006)

    store.consume(.snapshot(
        LiveSnapshot(
            capturedAt: firstCaptureTime,
            totalDownloadBytesPerSecond: 2_000,
            totalUploadBytesPerSecond: 0,
            processes: [
                ProcessUsage(pid: 41, name: "Safari", downloadBytesPerSecond: 2_000, uploadBytesPerSecond: 0, totalBytesPerSecond: 2_000, shareOfTotal: 1, lastSeen: firstCaptureTime)
            ]
        )
    ))

    #expect(store.displayedProcesses.map(\.name) == ["Safari"])
    #expect(store.topFive.map(\.name) == ["Safari"])
    #expect(store.displayedProcesses.first?.totalBytesPerSecond == 2_000)

    store.consume(.snapshot(
        LiveSnapshot(
            capturedAt: secondCaptureTime,
            totalDownloadBytesPerSecond: 0,
            totalUploadBytesPerSecond: 0,
            processes: []
        )
    ))

    #expect(store.displayedProcesses.map(\.name) == ["Safari"])
    #expect(store.displayedProcesses.first?.totalBytesPerSecond == 1_000)
    #expect(store.displayedProcesses.first?.lastSeen == firstCaptureTime)
    #expect(store.topFive.isEmpty)

    store.consume(.snapshot(
        LiveSnapshot(
            capturedAt: thirdCaptureTime,
            totalDownloadBytesPerSecond: 0,
            totalUploadBytesPerSecond: 0,
            processes: []
        )
    ))

    #expect(store.displayedProcesses.isEmpty)
}

@MainActor
@Test
func storeSwitchesBetweenLiveAndAveragedModes() {
    let store = TrafficDashboardStore(
        captureService: NettopCaptureService(producer: MockProducer(scripts: [])),
        preferences: testPreferences(),
        smoothingFactor: 0,
        visibilityGracePeriod: 0,
        previewMinimumBytesPerSecond: 0
    )

    let firstCaptureTime = Date(timeIntervalSince1970: 6_000)
    let secondCaptureTime = Date(timeIntervalSince1970: 6_010)
    let thirdCaptureTime = Date(timeIntervalSince1970: 6_020)

    store.consume(.snapshot(
        LiveSnapshot(
            capturedAt: firstCaptureTime,
            totalDownloadBytesPerSecond: 100,
            totalUploadBytesPerSecond: 0,
            processes: [
                ProcessUsage(pid: 11, name: "Safari", downloadBytesPerSecond: 100, uploadBytesPerSecond: 0, totalBytesPerSecond: 100, shareOfTotal: 1, lastSeen: firstCaptureTime)
            ]
        )
    ))

    store.consume(.snapshot(
        LiveSnapshot(
            capturedAt: secondCaptureTime,
            totalDownloadBytesPerSecond: 300,
            totalUploadBytesPerSecond: 60,
            processes: [
                ProcessUsage(pid: 11, name: "Safari", downloadBytesPerSecond: 300, uploadBytesPerSecond: 60, totalBytesPerSecond: 360, shareOfTotal: 1, lastSeen: secondCaptureTime)
            ]
        )
    ))

    store.consume(.snapshot(
        LiveSnapshot(
            capturedAt: thirdCaptureTime,
            totalDownloadBytesPerSecond: 500,
            totalUploadBytesPerSecond: 150,
            processes: [
                ProcessUsage(pid: 11, name: "Safari", downloadBytesPerSecond: 500, uploadBytesPerSecond: 100, totalBytesPerSecond: 600, shareOfTotal: 0.75, lastSeen: thirdCaptureTime),
                ProcessUsage(pid: 22, name: "Codex", downloadBytesPerSecond: 0, uploadBytesPerSecond: 50, totalBytesPerSecond: 50, shareOfTotal: 0.25, lastSeen: thirdCaptureTime)
            ]
        )
    ))

    #expect(store.selectedDisplayMode == .live)
    #expect(store.snapshot?.totalDownloadBytesPerSecond == 500)
    #expect(store.displayedProcesses.map(\.name) == ["Safari", "Codex"])

    store.selectedDisplayMode = .average
    #expect(store.snapshot?.capturedAt == thirdCaptureTime)
    #expect(store.snapshot?.totalDownloadBytesPerSecond == 400)
    #expect(store.snapshot?.totalUploadBytesPerSecond == 105)
    #expect(store.displayedProcesses.map(\.name) == ["Safari", "Codex"])
    #expect(store.displayedProcesses.first?.downloadBytesPerSecond == 400)
    #expect(store.displayedProcesses.first?.uploadBytesPerSecond == 80)
    #expect(store.displayedProcesses.last?.uploadBytesPerSecond == 25)

    store.selectedAverageWindow = .thirtySeconds
    #expect(store.snapshot?.totalDownloadBytesPerSecond == 300)
    #expect(store.snapshot?.totalUploadBytesPerSecond == 70)
    #expect(store.displayedProcesses.first?.downloadBytesPerSecond == 300)
    #expect(store.displayedProcesses.first?.uploadBytesPerSecond == 53)
    #expect(store.displayedProcesses.last?.uploadBytesPerSecond == 17)
}

@MainActor
@Test
func storeAveragesOneMinuteWindowAndTrimsTrendHistory() {
    let store = TrafficDashboardStore(
        captureService: NettopCaptureService(producer: MockProducer(scripts: [])),
        preferences: testPreferences(),
        smoothingFactor: 0,
        visibilityGracePeriod: 0,
        previewMinimumBytesPerSecond: 0
    )
    let baseTime = Date(timeIntervalSince1970: 6_500)

    store.consume(.snapshot(trendSnapshot(capturedAt: baseTime, download: 100, upload: 50)))
    store.consume(.snapshot(trendSnapshot(capturedAt: baseTime.addingTimeInterval(30), download: 300, upload: 150)))
    store.consume(.snapshot(trendSnapshot(capturedAt: baseTime.addingTimeInterval(60), download: 500, upload: 250)))

    store.selectedDisplayMode = .average
    store.selectedAverageWindow = .oneMinute
    #expect(store.snapshot?.totalDownloadBytesPerSecond == 300)
    #expect(store.snapshot?.totalUploadBytesPerSecond == 150)
    #expect(store.displayModeSummaryText == "Averaged over the last 1 min")

    store.consume(.snapshot(trendSnapshot(capturedAt: baseTime.addingTimeInterval(61), download: 700, upload: 350)))

    #expect(store.downloadTrend.samples.map(\.capturedAt) == [
        baseTime.addingTimeInterval(30),
        baseTime.addingTimeInterval(60),
        baseTime.addingTimeInterval(61)
    ])
    #expect(store.downloadTrend.samples.map(\.bytesPerSecond) == [300, 500, 700])
    #expect(store.snapshot?.totalDownloadBytesPerSecond == 500)
    #expect(store.snapshot?.totalUploadBytesPerSecond == 250)
}

@MainActor
@Test
func storePersistsDisplayModeAndAverageWindowChanges() {
    let defaults = isolatedUserDefaults()
    let preferences = NetworkMonitorPreferences(userDefaults: defaults)
    let store = TrafficDashboardStore(
        captureService: NettopCaptureService(producer: MockProducer(scripts: [])),
        preferences: preferences
    )

    store.selectedDisplayMode = .average
    store.selectedAverageWindow = .oneMinute

    let reloadedPreferences = NetworkMonitorPreferences(userDefaults: defaults)
    #expect(reloadedPreferences.defaultDisplayMode == .average)
    #expect(reloadedPreferences.defaultAverageWindow == .oneMinute)
}

@Test
func previewInteractionStaysVisibleAcrossHoverTransitions() {
    var model = StatusPreviewInteractionModel()

    #expect(model.observe(region: .statusItem) == [.scheduleHoverOpen])
    #expect(model.state == .hoverPending)
    #expect(model.hoverDelayElapsed(currentRegion: .statusItem) == [.showPreview])
    #expect(model.state == .previewVisible)
    #expect(model.observe(region: .outside) == [.scheduleDismiss])
    #expect(model.state == .dismissPending)
    #expect(model.observe(region: .previewPanel) == [.cancelDismiss])
    #expect(model.state == .previewVisible)
    #expect(model.observe(region: .outside) == [.scheduleDismiss])
    #expect(model.dismissDelayElapsed(currentRegion: .outside) == [.closePreview])
    #expect(model.state == .idle)
}

@Test
func captureServiceRestartsAfterFailure() async throws {
    let header = "time,,interface,state,bytes_in,bytes_out,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,tx_win,tc_class,tc_mgt,cc_algo,P,C,R,W,"
    let producer = MockProducer(
        scripts: [
            .failure([], MockError.boom),
            .failure(
                [
                    header,
                    "18:04:43.912151,Safari.1288,,,100,50,0,0,0,,,,,,,,,,,"
                ],
                MockError.stopAfterSnapshot
            )
        ]
    )

    let service = NettopCaptureService(
        producer: producer,
        restartDelayNanoseconds: 0,
        sleep: { _ in }
    )

    let recorder = EventRecorder()
    let eventTask = Task {
        for await event in service.events {
            await recorder.record(event)
            if await recorder.hasRecoveredSnapshot {
                await service.stop()
                break
            }
        }
    }

    await service.start()
    try await Task.sleep(nanoseconds: 200_000_000)
    eventTask.cancel()

    let events = await recorder.events
    #expect(events.contains(where: { if case .retrying = $0 { return true } else { return false } }))
    #expect(events.filter { if case .starting = $0 { return true } else { return false } }.count >= 2)
    #expect(events.contains(where: { if case .snapshot = $0 { return true } else { return false } }))
}

@Test
func captureServiceStopsAfterRepeatedStartupFailure() async throws {
    let service = NettopCaptureService(
        producer: MockProducer(
            scripts: [
                .throwing(NettopCaptureError.failedToStart("missing nettop")),
                .throwing(NettopCaptureError.failedToStart("missing nettop"))
            ]
        ),
        restartDelayNanoseconds: 0,
        terminalStartupFailureThreshold: 2,
        sleep: { _ in }
    )

    let recorder = EventRecorder()
    let eventTask = Task {
        for await event in service.events {
            await recorder.record(event)
            if await recorder.hasTerminalFailure {
                break
            }
        }
    }

    await service.start()
    try await Task.sleep(nanoseconds: 150_000_000)
    eventTask.cancel()

    let events = await recorder.events
    #expect(events.contains(where: { if case .retrying = $0 { return true } else { return false } }))
    #expect(events.contains(where: { if case .failed(let message) = $0 { return message.contains("missing nettop") } else { return false } }))
}

@Test
func captureServiceRestartWaitsForPreviousStopToFinish() async throws {
    let recorder = LockedRecorder()
    let producer = RestartSerializationProducer(recorder: recorder)
    let service = NettopCaptureService(
        producer: producer,
        restartDelayNanoseconds: 0,
        sleep: { _ in }
    )

    await service.start()
    try await Task.sleep(nanoseconds: 80_000_000)
    await service.restart()
    try await Task.sleep(nanoseconds: 80_000_000)

    let calls = recorder.snapshot()
    #expect(Array(calls.prefix(4)) == ["start1", "stop1-start", "stop1-end", "start2"])

    await service.stop()
}

@Test
func processTerminationPlanEscalatesWhenGracefulShutdownFails() async {
    let recorder = LockedRecorder()
    let waitPlan = WaitPlan([false, false, false])

    await ProcessTerminationPlan.stop(
        terminate: {
            recorder.record("terminate")
        },
        interrupt: {
            recorder.record("interrupt")
        },
        forceKill: {
            recorder.record("kill")
        },
        waitForExitWithin: { _ in
            await waitPlan.next()
        },
        waitForExit: {
            recorder.record("wait")
        }
    )

    #expect(recorder.snapshot() == ["terminate", "interrupt", "kill", "wait"])
}

@Test
func statusPopoverPositioningStaysBelowMenuBarAndInsideScreen() {
    let origin = StatusPopoverPositioning.origin(
        anchorFrame: CGRect(x: 800, y: 1180, width: 24, height: 22),
        popoverSize: CGSize(width: 360, height: 280),
        placementFrame: CGRect(x: 0, y: 0, width: 1512, height: 945)
    )

    #expect(origin.y == 657)
    #expect(origin.x == 632)
}

@Test
func statusPopoverPositioningClampsHorizontallyNearScreenEdge() {
    let origin = StatusPopoverPositioning.origin(
        anchorFrame: CGRect(x: 1490, y: 1180, width: 24, height: 22),
        popoverSize: CGSize(width: 360, height: 280),
        placementFrame: CGRect(x: 0, y: 0, width: 1512, height: 945)
    )

    #expect(origin.x == 1144)
    #expect(origin.y == 657)
}

@Test
func statusPopoverPlacementFrameHonorsSafeAreaInsets() {
    let frame = StatusPopoverPositioning.placementFrame(
        screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 954),
        safeAreaInsets: NSEdgeInsets(top: 74, left: 0, bottom: 0, right: 0)
    )

    #expect(frame == CGRect(x: 0, y: 0, width: 1512, height: 908))
}

private enum MockError: Error {
    case boom
    case stopAfterSnapshot
}

private func isolatedUserDefaults() -> UserDefaults {
    let suiteName = "NetworkMonitorTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

@MainActor
private func testPreferences() -> NetworkMonitorPreferences {
    NetworkMonitorPreferences(userDefaults: isolatedUserDefaults())
}

private func previewRowDescriptions(_ rows: [PreviewProcessRow]) -> [String] {
    rows.map { row in
        switch row {
        case let .active(usage):
            return "active:\(usage.name)"
        case let .lowTraffic(usage):
            return "low:\(usage.name)"
        case .empty:
            return "empty"
        }
    }
}

private func trendSnapshot(
    capturedAt: Date,
    download: UInt64,
    upload: UInt64 = 0
) -> LiveSnapshot {
    let total = download + upload
    let processes = total > 0 ? [
        ProcessUsage(
            pid: 42,
            name: "Safari",
            downloadBytesPerSecond: download,
            uploadBytesPerSecond: upload,
            totalBytesPerSecond: total,
            shareOfTotal: 1,
            lastSeen: capturedAt
        )
    ] : []

    return LiveSnapshot(
        capturedAt: capturedAt,
        totalDownloadBytesPerSecond: download,
        totalUploadBytesPerSecond: upload,
        processes: processes
    )
}

private actor WaitPlan {
    private var responses: [Bool]

    init(_ responses: [Bool]) {
        self.responses = responses
    }

    func next() -> Bool {
        if responses.isEmpty {
            return true
        }
        return responses.removeFirst()
    }
}

private final class LockedRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []

    func record(_ value: String) {
        lock.lock()
        calls.append(value)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

private final class StreamContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?

    func set(_ continuation: AsyncThrowingStream<String, Error>.Continuation) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func finish() {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        continuation?.finish()
    }
}

private final class RestartSerializationProducer: NettopStreamProducing, @unchecked Sendable {
    private let recorder: LockedRecorder
    private let lock = NSLock()
    private var attempt = 0

    init(recorder: LockedRecorder) {
        self.recorder = recorder
    }

    func makeStream() throws -> NettopStreamHandle {
        lock.lock()
        attempt += 1
        let currentAttempt = attempt
        lock.unlock()

        recorder.record("start\(currentAttempt)")
        let continuationBox = StreamContinuationBox()
        let stream = AsyncThrowingStream<String, Error> { continuation in
            continuationBox.set(continuation)
        }

        return NettopStreamHandle(
            lines: stream,
            stop: { [recorder] in
                recorder.record("stop\(currentAttempt)-start")
                try? await Task.sleep(nanoseconds: 50_000_000)
                continuationBox.finish()
                recorder.record("stop\(currentAttempt)-end")
            }
        )
    }
}

private final class MockProducer: NettopStreamProducing, @unchecked Sendable {
    enum Script {
        case finish([String])
        case failure([String], Error)
        case throwing(Error)
    }

    private let lock = NSLock()
    private var scripts: [Script]

    init(scripts: [Script]) {
        self.scripts = scripts
    }

    func makeStream() throws -> NettopStreamHandle {
        lock.lock()
        defer { lock.unlock() }

        let script = scripts.isEmpty ? .failure([], MockError.boom) : scripts.removeFirst()

        let stream = AsyncThrowingStream<String, Error> { continuation in
            let task = Task.detached {
                switch script {
                case let .finish(lines):
                    for line in lines {
                        continuation.yield(line)
                    }
                    continuation.finish()

                case let .failure(lines, error):
                    for line in lines {
                        continuation.yield(line)
                    }
                    continuation.finish(throwing: error)

                case let .throwing(error):
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }

        return NettopStreamHandle(lines: stream, stop: {})
    }
}

private actor EventRecorder {
    private(set) var events: [CaptureEvent] = []

    var hasRecoveredSnapshot: Bool {
        let restarted = events.filter { event in
            if case .starting = event { return true }
            return false
        }.count >= 2
        let snapshotted = events.contains { if case .snapshot = $0 { return true } else { return false } }
        let retrying = events.contains { if case .retrying = $0 { return true } else { return false } }
        return retrying && restarted && snapshotted
    }

    var hasTerminalFailure: Bool {
        events.contains { if case .failed = $0 { return true } else { return false } }
    }

    func record(_ event: CaptureEvent) {
        events.append(event)
    }
}
