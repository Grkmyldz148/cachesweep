import SwiftUI

struct HistoryView: View {
    private let history = ActivityHistory.shared
    @State private var window: Window = .week

    enum Window: String, CaseIterable, Identifiable {
        case day, week, all
        var id: String { rawValue }
        @MainActor var label: String {
            switch self {
            case .day:  return L("history.today")
            case .week: return L("history.week")
            case .all:  return L("history.all")
            }
        }
        var since: Date {
            switch self {
            case .day:  return Date().addingTimeInterval(-86_400)
            case .week: return Date().addingTimeInterval(-7 * 86_400)
            case .all:  return .distantPast
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $window) {
                ForEach(Window.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(DS.s3)

            Divider()

            let rows = history.topGrowers(since: window.since, limit: 40)
            if rows.isEmpty {
                ContentUnavailableView(
                    L("history.empty.title"),
                    systemImage: "chart.line.uptrend.xyaxis",
                    description: Text(L("history.empty.desc")))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows, id: \.record.id) { row in
                            HistoryRow(record: row.record, growth: row.growth)
                            Divider().padding(.leading, DS.s3)
                        }
                    }
                }
            }
        }
        .frame(width: 480, height: 520)
        .background(.regularMaterial)
    }
}

struct HistoryRow: View {
    let record: GrowthRecord
    let growth: Int64
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: DS.s3) {
            VStack(alignment: .leading, spacing: 2) {
                MarqueeText(text: record.label)
                    .font(.callout.weight(.medium))
                Text("\(record.lastSize.fileSize) · \(relativeSeen)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: DS.s2)
            Button {
                Reveal.inFinder(record.path)
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .foregroundStyle(.secondary)
            .help(L("reveal.help"))
            .opacity(isHovering ? 1 : 0)
            .allowsHitTesting(isHovering)
            Sparkline(samples: record.samples)
                .frame(width: 64, height: 22)
            Text(growthText)
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(growth >= 0 ? Color.green : Color.secondary)
                .frame(width: 78, alignment: .trailing)
        }
        .padding(.horizontal, DS.s3)
        .padding(.vertical, DS.s2)
        .onHover { isHovering = $0 }
    }

    private var growthText: String {
        (growth >= 0 ? "▲ " : "▼ ") + UInt64(abs(growth)).fileSize
    }

    private var relativeSeen: String {
        let s = Int(Date().timeIntervalSince(record.lastSeen))
        if s < 60 { return L("time.justNow") }
        if s < 3600 { return Lf("time.minutesAgo", Int32(s / 60)) }
        if s < 86_400 { return Lf("time.hoursAgo", Int32(s / 3600)) }
        return Lf("time.daysAgo", Int32(s / 86_400))
    }
}

/// Tiny inline line chart of a folder's size over its samples.
struct Sparkline: View {
    let samples: [GrowthRecord.Sample]

    var body: some View {
        GeometryReader { geo in
            let vals = samples.map { Double($0.size) }
            if vals.count >= 2, let mn = vals.min(), let mx = vals.max() {
                let range = max(mx - mn, 1)
                Path { p in
                    for (i, v) in vals.enumerated() {
                        let x = geo.size.width * Double(i) / Double(vals.count - 1)
                        let y = geo.size.height * (1 - (v - mn) / range)
                        if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                        else { p.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            } else {
                Rectangle().fill(.secondary.opacity(0.15))
                    .frame(height: 1)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
        }
    }
}
