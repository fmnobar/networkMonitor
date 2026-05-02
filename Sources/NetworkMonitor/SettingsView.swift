import SwiftUI

struct SettingsView: View {
    @ObservedObject var preferences: NetworkMonitorPreferences

    var body: some View {
        TabView {
            Form {
                Section("General") {
                    Picker("Default mode", selection: $preferences.defaultDisplayMode) {
                        ForEach(TrafficDisplayMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }

                    Picker("Default average", selection: $preferences.defaultAverageWindow) {
                        ForEach(AverageWindow.allCases) { window in
                            Text(window.title).tag(window)
                        }
                    }

                    Picker("Dashboard rows", selection: $preferences.dashboardProcessVisibility) {
                        ForEach(DashboardProcessVisibility.allCases) { visibility in
                            Text(visibility.title).tag(visibility)
                        }
                    }
                }
            }
            .padding(20)
            .tabItem {
                Label("General", systemImage: "gearshape")
            }

            Form {
                Section("Display") {
                    Picker("Rate units", selection: $preferences.rateUnitStyle) {
                        ForEach(NetworkRateUnitStyle.allCases) { style in
                            Text("\(style.title) (\(style.detail))").tag(style)
                        }
                    }

                    Picker("Preview threshold", selection: $preferences.previewThreshold) {
                        ForEach(PreviewTrafficThreshold.allCases) { threshold in
                            Text(threshold.title).tag(threshold)
                        }
                    }
                }
            }
            .padding(20)
            .tabItem {
                Label("Display", systemImage: "textformat.size")
            }
        }
        .frame(width: 460, height: 300)
    }
}
