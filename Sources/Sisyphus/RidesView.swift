import SwiftUI
import Charts
import UniformTypeIdentifiers
import SisyphusCore

final class RidesNavigation: ObservableObject {
    @Published var selection: UUID?
    @Published var showingStrava = false
}

private let stravaOrange = Color(red: 0.99, green: 0.30, blue: 0.01)

/// Ride history: a sidebar of rides by month, and each ride's summary, charts and export.
struct RidesView: View {
    @ObservedObject var store: RideStore
    @ObservedObject var strava: StravaService
    @ObservedObject var navigation: RidesNavigation

    var body: some View {
        NavigationSplitView {
            List(selection: $navigation.selection) {
                ForEach(months, id: \.title) { month in
                    Section(month.title) {
                        ForEach(month.rides) { ride in
                            RideRow(ride: ride, uploading: strava.uploads[ride.id] == .uploading).tag(ride.id)
                        }
                    }
                }
            }
            .overlay {
                if store.rides.isEmpty {
                    ContentUnavailableView("No Rides Yet", systemImage: "figure.indoor.cycle",
                                           description: Text("Rides you end are saved here."))
                }
            }
            .safeAreaInset(edge: .bottom) { stravaStatus }
            .navigationSplitViewColumnWidth(min: 230, ideal: 260)
        } detail: {
            if let id = navigation.selection, let ride = store.ride(id) {
                RideDetail(ride: ride, store: store, strava: strava, navigation: navigation).id(ride.id)
            } else {
                ContentUnavailableView(store.rides.isEmpty ? "Your Rides Will Appear Here" : "Select a Ride",
                                       systemImage: "chart.xyaxis.line")
            }
        }
        .sheet(isPresented: $navigation.showingStrava) { StravaSheet(strava: strava) }
        .onAppear {
            strava.load()
            if navigation.selection == nil { navigation.selection = store.rides.first?.id }
        }
    }

    private var months: [(title: String, rides: [RideLog])] {
        var groups: [(title: String, rides: [RideLog])] = []
        for ride in store.rides {
            let title = ride.start.formatted(.dateTime.month(.wide).year())
            if groups.last?.title == title { groups[groups.count - 1].rides.append(ride) }
            else { groups.append((title, [ride])) }
        }
        return groups
    }

    private var stravaStatus: some View {
        Button { navigation.showingStrava = true } label: {
            HStack(spacing: 8) {
                Circle().fill(strava.isConnected ? AnyShapeStyle(stravaOrange) : AnyShapeStyle(.tertiary)).frame(width: 8, height: 8)
                Text(strava.isConnected ? "Strava · \(strava.athleteName ?? "Connected")" : "Connect Strava…")
                    .lineLimit(1)
                Spacer()
            }
            .font(.callout)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct RideRow: View {
    let ride: RideLog
    let uploading: Bool

    var body: some View {
        let summary = ride.summary
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(ride.start, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                    .font(.headline)
                Text([Duration.seconds(summary.movingSeconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)),
                      summary.averagePower.map { "\($0) W" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if uploading {
                ProgressView().controlSize(.small)
            } else if ride.stravaActivityID != nil {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(stravaOrange).help("Uploaded to Strava")
            }
        }
        .padding(.vertical, 3)
    }
}

private struct RideDetail: View {
    let ride: RideLog
    @ObservedObject var store: RideStore
    @ObservedObject var strava: StravaService
    @ObservedObject var navigation: RidesNavigation
    @State private var confirmingDelete = false

    var body: some View {
        ScrollView {
            RideSummaryContent(ride: ride, strava: strava)
                .padding(28)
                .frame(maxWidth: 860, alignment: .leading)
        }
        .navigationTitle(ride.start.formatted(date: .abbreviated, time: .shortened))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                stravaButton
                Button("Export TCX…", systemImage: "square.and.arrow.up", action: export)
                Button("Delete", systemImage: "trash", role: .destructive) { confirmingDelete = true }
            }
        }
        .confirmationDialog("Delete this ride?", isPresented: $confirmingDelete) {
            Button("Delete Ride", role: .destructive) {
                navigation.selection = nil
                store.delete(ride.id)
            }
        } message: {
            Text(ride.stravaActivityID != nil ? "It stays on Strava." : "This can’t be undone.")
        }
    }

    @ViewBuilder private var stravaButton: some View {
        if let activity = ride.stravaActivityID {
            Button("View on Strava", systemImage: "arrow.up.right.square") { NSWorkspace.shared.open(Strava.activityURL(activity)) }
        } else if strava.uploads[ride.id] == .uploading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Uploading…").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
        } else {
            Button("Upload to Strava", systemImage: "arrow.up.circle") {
                if strava.isConnected { Task { await strava.upload(ride.id) } } else { navigation.showingStrava = true }
            }
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "tcx") ?? .xml]
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HHmm"
        panel.nameFieldStringValue = "Sisyphus Ride \(stamp.string(from: ride.start)).tcx"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try TCX.document(for: ride).write(to: url, options: .atomic) }
        catch { NSAlert(error: error).runModal() }
    }
}

/// The ride's header, stats and charts.
private struct RideSummaryContent: View {
    let ride: RideLog
    @ObservedObject var strava: StravaService

    var body: some View {
        let summary = ride.summary
        let points = ChartPoint.points(for: ride)
        let minutes = 0...max(1, Double(ride.samples.count) / 60)
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Indoor Ride").font(.largeTitle.weight(.bold))
                Text(ride.start.formatted(date: .complete, time: .shortened)).foregroundStyle(.secondary)
            }
            if case .failed(let message)? = strava.uploads[ride.id] {
                HStack(alignment: .firstTextBaseline) {
                    Label(message, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                    Spacer()
                    Button("Try Again") { Task { await strava.upload(ride.id) } }
                }
                .padding(12)
                .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Stat("Moving Time", RideSession.time(Double(summary.movingSeconds)), symbol: "timer", tint: .yellow)
                    Stat("Elapsed Time", RideSession.time(Double(summary.elapsedSeconds)), symbol: "clock", tint: .yellow)
                    Stat("Work", String(summary.workKilojoules), unit: "kJ", symbol: "flame.fill", tint: .orange)
                }
                GridRow {
                    Stat("Avg Power", summary.averagePower.map(String.init), unit: "W", symbol: "bolt.fill", tint: .green)
                    Stat("Normalized Power", summary.normalizedPower.map(String.init), unit: "W", symbol: "bolt.fill", tint: .green)
                    Stat("Max Power", summary.maximumPower.map(String.init), unit: "W", symbol: "bolt.fill", tint: .green)
                }
                GridRow {
                    Stat("Avg Cadence", summary.averageCadence.map(String.init), unit: "RPM", symbol: "arrow.trianglehead.2.clockwise", tint: .cyan)
                    Stat("Avg Heart Rate", summary.averageHeartRate.map(String.init), unit: "BPM", symbol: "heart.fill", tint: .red)
                    Stat("Max Heart Rate", summary.maximumHeartRate.map(String.init), unit: "BPM", symbol: "heart.fill", tint: .red)
                }
            }
            if points.contains(where: { $0.power != nil }) {
                ChartCard(title: "Power") {
                    Chart(points) { point in
                        if let power = point.power {
                            AreaMark(x: .value("Minutes", point.minute), y: .value("Power", power), series: .value("Series", "Power"))
                                .foregroundStyle(LinearGradient(colors: [.green.opacity(0.3), .green.opacity(0)], startPoint: .top, endPoint: .bottom))
                                .interpolationMethod(.monotone)
                            LineMark(x: .value("Minutes", point.minute), y: .value("Power", power), series: .value("Series", "Power"))
                                .foregroundStyle(.green)
                                .interpolationMethod(.monotone)
                        }
                        LineMark(x: .value("Minutes", point.minute), y: .value("Target", point.target), series: .value("Series", "Target"))
                            .foregroundStyle(.secondary)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .interpolationMethod(.stepEnd)
                    }
                    .chartXScale(domain: minutes)
                    .chartXAxisLabel("Minutes")
                    .chartYAxisLabel("Watts")
                }
            }
            if points.contains(where: { $0.heartRate != nil }) {
                ChartCard(title: "Heart Rate") {
                    Chart(points) { point in
                        if let heartRate = point.heartRate {
                            LineMark(x: .value("Minutes", point.minute), y: .value("Heart Rate", heartRate))
                                .foregroundStyle(.red)
                                .interpolationMethod(.monotone)
                        }
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartXScale(domain: minutes)
                    .chartXAxisLabel("Minutes")
                    .chartYAxisLabel("BPM")
                }
            }
        }
    }
}

private struct Stat: View {
    let title: String
    let value: String?
    var unit: String?
    let symbol: String
    let tint: Color

    init(_ title: String, _ value: String?, unit: String? = nil, symbol: String, tint: Color) {
        self.title = title; self.value = value; self.unit = unit; self.symbol = symbol; self.tint = tint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol).foregroundStyle(tint)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value ?? "--").font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit()
                if let unit, value != nil {
                    Text(unit).font(.system(.subheadline, design: .rounded).weight(.semibold)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct ChartCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content.frame(height: 180)
        }
        .padding(16)
        .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Ride samples averaged into at most a few hundred points, plotted against moving time.
private struct ChartPoint: Identifiable {
    let id: Int
    let minute: Double
    let power: Double?
    let target: Double
    let heartRate: Double?

    static func points(for ride: RideLog, limit: Int = 300) -> [ChartPoint] {
        let samples = ride.samples
        guard !samples.isEmpty else { return [] }
        let size = max(1, Int((Double(samples.count) / Double(limit)).rounded(.up)))
        func mean(_ values: [Int]) -> Double? { values.isEmpty ? nil : Double(values.reduce(0, +)) / Double(values.count) }
        return stride(from: 0, to: samples.count, by: size).enumerated().map { index, start in
            let bucket = samples[start..<min(start + size, samples.count)]
            return ChartPoint(id: index, minute: Double(start) / 60,
                              power: mean(bucket.compactMap(\.power).map { max(0, $0) }),
                              target: Double(bucket.last!.target),
                              heartRate: mean(bucket.compactMap(\.heartRate).filter { $0 > 0 }))
        }
    }
}

private struct StravaSheet: View {
    @ObservedObject var strava: StravaService
    @Environment(\.dismiss) private var dismiss
    @State private var clientID = ""
    @State private var clientSecret = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if strava.isConnected {
                    Section {
                        LabeledContent("Account", value: strava.athleteName ?? "Connected")
                        Toggle("Upload rides when you end them", isOn: $strava.uploadAutomatically)
                    } header: {
                        Text("Strava")
                    } footer: {
                        Text("Rides upload as indoor rides with power, cadence and heart rate.").foregroundStyle(.secondary)
                    }
                    Section {
                        Button("Disconnect", role: .destructive) { Task { await strava.disconnect() } }
                    }
                } else {
                    Section {
                        TextField("Client ID", text: $clientID)
                        SecureField("Client Secret", text: $clientSecret)
                    } header: {
                        Text("Your Strava API Application")
                    } footer: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Sisyphus uploads through an API application you own, so rides go straight from this Mac to Strava.")
                            Text("Create one in Strava’s API settings with the Authorization Callback Domain set to **localhost**, then copy its Client ID and Client Secret here.")
                            Link("Open Strava API Settings", destination: URL(string: "https://www.strava.com/settings/api")!)
                        }
                        .foregroundStyle(.secondary)
                    }
                    if strava.connecting {
                        Section {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Finish connecting in your browser…")
                                Spacer()
                                Button("Cancel") { strava.cancelConnecting() }
                            }
                        }
                    }
                    if let error = strava.connectError {
                        Section {
                            Label(error, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                if !strava.isConnected {
                    Button("Connect") { Task { await strava.connect(clientID: clientID, clientSecret: clientSecret) } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(strava.connecting || clientID.isEmpty || clientSecret.isEmpty)
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(strava.isConnected ? .defaultAction : .cancelAction)
            }
            .padding(16)
        }
        .frame(width: 480, height: strava.isConnected ? 280 : 460)
        .onAppear {
            strava.load()
            clientID = strava.credentials?.clientID ?? ""
            clientSecret = strava.credentials?.clientSecret ?? ""
        }
    }
}
