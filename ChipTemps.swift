// Chip Temps: a menu bar app that reads Mac temperature sensors every 5 seconds,
// keeps 7 days of history, and shows it as a chart when you click the menu bar item.
import SwiftUI
import Charts
import ServiceManagement

let every: TimeInterval = 5
let keep: TimeInterval = 7 * 24 * 3600

// MARK: - Readings

struct Row {
    var t: Date
    var v: [Double?]  // indexed by Sensor.rawValue
    var chipAvg: Double?
}

enum Sensor: Int, CaseIterable, Identifiable {
    case chip, ssd, battery
    var id: Int { rawValue }
    var name: String { ["Chip", "SSD", "Battery"][rawValue] }
    // Validated categorical palette, stepped separately for light and dark.
    var color: Color {
        let (light, dark) = [(0x2a78d6, 0x3987e5), (0xeb6834, 0xd95926), (0x1baf7a, 0x199e70)][rawValue]
        return Color(nsColor: NSColor(name: nil) { a in
            let hex = a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }
}

func readSensors() -> Row {
    let max = 128, stride = 64
    var names = [CChar](repeating: 0, count: max * stride)
    var vals = [Double](repeating: 0, count: max)
    let n = Int(read_sensors(&names, Int32(stride), &vals, Int32(max)))
    var sums: [String: (Double, Int)] = [:]
    for i in 0..<n where vals[i] > -100 {  // broken sensors read about -9200
        let name = names.withUnsafeBufferPointer { String(cString: $0.baseAddress! + i * stride) }
        let (s, c) = sums[name] ?? (0, 0)
        sums[name] = (s + vals[i], c + 1)
    }
    let avg = sums.mapValues { $0.0 / Double($0.1) }
    let die = avg.filter { $0.key.hasPrefix("PMU tdie") }.map(\.value)
    return Row(t: Date(), v: [die.max(), avg["NAND CH0 temp"], avg["gas gauge battery"]],
               chipAvg: die.isEmpty ? nil : die.reduce(0, +) / Double(die.count))
}

// MARK: - Store

@MainActor final class Store: ObservableObject {
    @Published var rows: [Row] = []
    private var timer: Timer?
    private let file: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Chip Temps")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.csv")
    }()

    init() {
        load()
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: every, repeats: true) { _ in
            Task { @MainActor in self.tick() }
        }
    }

    var latest: Row? { rows.last }

    private func tick() {
        let r = readSensors()
        rows.append(r)
        let cutoff = r.t.addingTimeInterval(-keep)
        if let first = rows.first, first.t < cutoff { rows.removeAll { $0.t < cutoff } }
        append(r)
    }

    // CSV: unix time, chip hottest, chip average, ssd, battery
    private func line(_ r: Row) -> String {
        let cols = [r.v[0], r.chipAvg, r.v[1], r.v[2]].map { $0.map { String(format: "%.1f", $0) } ?? "" }
        return "\(Int(r.t.timeIntervalSince1970)),\(cols.joined(separator: ","))\n"
    }

    private func append(_ r: Row) {
        guard let data = line(r).data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: file)
        }
    }

    private func load() {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        let cutoff = Date().addingTimeInterval(-keep)
        rows = text.split(separator: "\n").compactMap { l in
            let p = l.split(separator: ",", omittingEmptySubsequences: false).map { Double($0) }
            guard p.count == 5, let t = p[0] else { return nil }
            let d = Date(timeIntervalSince1970: t)
            return d < cutoff ? nil : Row(t: d, v: [p[1], p[3], p[4]], chipAvg: p[2])
        }
        try? rows.map(line).joined().write(to: file, atomically: true, encoding: .utf8)  // drop old rows
    }
}

// MARK: - Chart data

struct Point: Identifiable {
    let id = UUID()
    let t: Date, v: Double, sensor: Sensor, segment: Int
}

/// Averages rows into ~240 time buckets per sensor and breaks lines where the app was off.
func bucketed(_ rows: [Row], from t0: Date, to t1: Date) -> [Point] {
    let n = 240.0, width = t1.timeIntervalSince(t0) / n
    let gap = max(20, width * 3)
    var buckets: [Int: (t: Double, n: Int, s: [Double], c: [Int])] = [:]
    for r in rows where r.t >= t0 {
        let k = Int(r.t.timeIntervalSince(t0) / width)
        var b = buckets[k] ?? (0, 0, [0, 0, 0], [0, 0, 0])
        b.t += r.t.timeIntervalSince1970; b.n += 1
        for (i, v) in r.v.enumerated() { if let v { b.s[i] += v; b.c[i] += 1 } }
        buckets[k] = b
    }
    var out: [Point] = []
    for s in Sensor.allCases {
        var seg = 0, prev: Double?
        for k in buckets.keys.sorted() {
            let b = buckets[k]!
            guard b.c[s.rawValue] > 0 else { continue }
            let t = b.t / Double(b.n)
            if let prev, t - prev > gap { seg += 1 }
            prev = t
            out.append(Point(t: Date(timeIntervalSince1970: t), v: b.s[s.rawValue] / Double(b.c[s.rawValue]),
                             sensor: s, segment: seg))
        }
    }
    return out
}

// MARK: - Views

enum Span: Int, CaseIterable, Identifiable {
    case m5 = 300, h1 = 3600, h6 = 21600, h24 = 86400, d7 = 604800
    var id: Int { rawValue }
    var secs: Double { Double(rawValue) }
    var label: String { ["5m", "1h", "6h", "24h", "7d"][Span.allCases.firstIndex(of: self)!] }
    var tickStep: Double { [60, 900, 3600, 14400, 86400][Span.allCases.firstIndex(of: self)!] }

    /// Round local times (e.g. every 15 min) that stay clear of both edges so no label gets cut off.
    func ticks(_ t0: Date, _ t1: Date) -> [Date] {
        let off = Double(TimeZone.current.secondsFromGMT()), edge = secs * 0.06
        var t = ((t0.timeIntervalSince1970 + off) / tickStep).rounded(.up) * tickStep - off
        var out: [Date] = []
        while t <= t1.timeIntervalSince1970 - edge {
            if t >= t0.timeIntervalSince1970 + edge { out.append(Date(timeIntervalSince1970: t)) }
            t += tickStep
        }
        return out
    }
}

struct Panel: View {
    @ObservedObject var store: Store
    @AppStorage("span") private var span: Span = .h1
    @State private var selected: Date?
    @State private var startAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        let now = store.latest?.t ?? Date()
        let t0 = now.addingTimeInterval(-span.secs)
        let points = bucketed(store.rows, from: t0, to: now)

        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Chip temperatures").font(.headline)
                Spacer()
                Text(verdict).font(.callout.weight(.semibold))
                if let t = store.latest?.t {
                    Text("· " + t.formatted(date: .omitted, time: .standard)).font(.callout).foregroundStyle(.secondary)
                }
            }
            tiles(since: now.addingTimeInterval(-86400))
            Picker("", selection: $span) {
                ForEach(Span.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 260)

            Chart {
                ForEach(points) { p in
                    LineMark(x: .value("Time", p.t), y: .value("°C", p.v),
                             series: .value("Line", "\(p.sensor.rawValue)-\(p.segment)"))
                        .foregroundStyle(p.sensor.color)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                if let selected, let near = nearest(points, to: selected) {
                    RuleMark(x: .value("Time", near.t))
                        .foregroundStyle(.secondary.opacity(0.4))
                        .annotation(position: .top, alignment: .leading, spacing: 0,
                                    overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            tooltip(points.filter { abs($0.t.timeIntervalSince(near.t)) < 1 }, at: near.t)
                        }
                    ForEach(points.filter { abs($0.t.timeIntervalSince(near.t)) < 1 }) { p in
                        PointMark(x: .value("Time", p.t), y: .value("°C", p.v))
                            .foregroundStyle(p.sensor.color).symbolSize(40)
                    }
                }
            }
            .chartXScale(domain: t0...now)
            .chartYScale(domain: .automatic(includesZero: false))
            .chartYAxis {
                AxisMarks(position: .leading) { v in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))°") } }
                }
            }
            .chartXAxis {
                AxisMarks(values: span.ticks(t0, now)) { _ in
                    AxisValueLabel(format: span.secs > 86400 ? .dateTime.weekday().hour() : .dateTime.hour().minute())
                }
            }
            .chartXSelection(value: $selected)
            .frame(height: 220)

            HStack {
                Toggle("Start at login", isOn: $startAtLogin)
                    .toggleStyle(.switch).controlSize(.mini)
                    .onChange(of: startAtLogin) { _, on in setLogin(on) }
                Spacer()
                Text("Under 80° is fine · slows down near 100°").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var verdict: String {
        guard let hot = store.latest?.v[0] else { return "Waiting…" }
        return hot < 80 ? "Fine" : hot < 95 ? "Warm" : "Hot — near slow-down"
    }

    private func tiles(since: Date) -> some View {
        let day = store.rows.filter { $0.t > since }
        return HStack(alignment: .top, spacing: 0) {
            ForEach(Sensor.allCases) { s in
                let vals = day.compactMap { $0.v[s.rawValue] }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 1).fill(s.color).frame(width: 10, height: 2)
                        Text(s.name).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(store.latest?.v[s.rawValue].map { String(format: "%.1f°", $0) } ?? "—")
                        .font(.system(size: 24, weight: .semibold)).monospacedDigit()
                    Group {
                        if s == .chip, let a = store.latest?.chipAvg, let peak = vals.max() {
                            Text(String(format: "avg %.1f · 24h peak %.1f", a, peak))
                        } else if let lo = vals.min(), let hi = vals.max() {
                            Text(String(format: "24h %.1f–%.1f", lo, hi))
                        }
                    }
                    .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func tooltip(_ ps: [Point], at t: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(t.formatted(date: span.secs > 86400 ? .abbreviated : .omitted, time: .shortened))
                .foregroundStyle(.secondary)
            ForEach(ps) { p in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 1).fill(p.sensor.color).frame(width: 10, height: 2)
                    Text(p.sensor.name)
                    Spacer(minLength: 12)
                    Text(String(format: "%.1f°", p.v)).fontWeight(.semibold)
                }
            }
        }
        .font(.caption).monospacedDigit()
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.background).shadow(radius: 3, y: 1))
        .frame(width: 150)
    }

    private func nearest(_ ps: [Point], to t: Date) -> Point? {
        ps.filter { $0.sensor == .chip }.min { abs($0.t.timeIntervalSince(t)) < abs($1.t.timeIntervalSince(t)) }
    }

    private func setLogin(_ on: Bool) {
        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
        catch { startAtLogin = SMAppService.mainApp.status == .enabled }
    }
}

@main struct ChipTempsApp: App {
    @StateObject private var store = Store()

    init() {
        // Start at login by default, once. The switch in the panel can turn it off.
        if !UserDefaults.standard.bool(forKey: "didSetLogin") {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "didSetLogin")
        }
    }

    var body: some Scene {
        MenuBarExtra {
            Panel(store: store)
        } label: {
            Text(store.latest?.v[0].map { "\(Int($0.rounded()))°" } ?? "–°")
        }
        .menuBarExtraStyle(.window)
    }
}
