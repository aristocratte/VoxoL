import AppKit
import SwiftUI

enum StatisticsPeriod: String, CaseIterable, Hashable {
    case week
    case month
    case all

    var title: LocalizedStringKey {
        switch self {
        case .week: "7 days"
        case .month: "30 days"
        case .all: "All"
        }
    }

    var days: Int? {
        switch self {
        case .week: 7
        case .month: 30
        case .all: nil
        }
    }
}

/// Everything the Statistics page shows, computed once per period and per history change.
///
/// With no history, the debug fixture shows the design's numbers so the layout can be judged.
struct StatisticsModel {
    struct Column: Identifiable {
        let id: Int
        let words: Int
        let label: String
        let isCurrent: Bool
    }

    struct AppRow: Identifiable {
        let id: String
        let name: String
        let bundleIdentifier: String?
        let count: Int
    }

    let recoveredMinutes: Int
    let words: Int
    let averageWPM: Int
    let activeDays: Int
    let spanDays: Int
    /// Words per day for a week or a month, per week beyond that, oldest first.
    let columns: [Column]
    /// The busiest column, named for the chart's note.
    let peak: (label: String, words: Int)?
    let apps: [AppRow]
    /// Dictations per weekday (rows, in the calendar's order) and two-hour band (columns).
    let hours: [[Int]]
    let weekdayLabels: [String]
    let bandLabels: [String]
    let busiestBand: String?

    static let bands: [(start: Int, end: Int)] = [
        (6, 8), (8, 10), (10, 12), (12, 14), (14, 16), (16, 18), (18, 20), (20, 22), (22, 6),
    ]

    @MainActor
    init(records: [TranscriptRecord], period: StatisticsPeriod, usesFixture: Bool, locale: Locale) {
        var calendar = Calendar.current
        calendar.locale = locale
        let now = Date.now
        let today = calendar.startOfDay(for: now)
        let start = period.days.flatMap { calendar.date(byAdding: .day, value: 1 - $0, to: today) }
        let inPeriod = start.map { start in records.filter { $0.createdAt >= start } } ?? records
        let entries = inPeriod.map(EditorialWordEntry.init)

        // Totals.
        let totalWords = entries.reduce(0) { $0 + $1.words }
        let speaking = entries.reduce(0) { $0 + $1.seconds }
        words = usesFixture ? 1_443 : totalWords
        averageWPM =
            usesFixture ? 135 : speaking > 0 ? Int((Double(totalWords) / speaking * 60).rounded()) : 0
        let speakingSeconds = usesFixture ? Double(words) / 135 * 60 : speaking
        recoveredMinutes = max(0, Int(((Double(words) / 40 * 60 - speakingSeconds) / 60).rounded()))
        activeDays =
            usesFixture
            ? (period == .week ? 6 : 19)
            : Set(inPeriod.map { calendar.startOfDay(for: $0.createdAt) }).count
        if let days = period.days {
            spanDays = days
        } else if let earliest = records.map(\.createdAt).min() {
            let elapsed =
                calendar.dateComponents([.day], from: calendar.startOfDay(for: earliest), to: today)
                .day ?? 0
            spanDays = max(1, elapsed + 1)
        } else {
            spanDays = 1
        }

        // Columns: one per day for a week or a month, one per week beyond that.
        var columns: [Column] = []
        switch period {
        case .week, .month:
            let count = period.days ?? 7
            var buckets: [Date: Int] = [:]
            for entry in entries { buckets[calendar.startOfDay(for: entry.date), default: 0] += entry.words }
            for offset in 0..<count {
                guard let day = calendar.date(byAdding: .day, value: offset - (count - 1), to: today)
                else { continue }
                let label: String =
                    period == .week
                    ? day.formatted(.dateTime.weekday(.abbreviated).locale(locale))
                    : (offset % 5 == (count - 1) % 5
                        ? calendar.component(.day, from: day).formatted() : "")
                let value =
                    usesFixture
                    ? Int(80 + 260 * abs(sin(Double(offset) * 1.7 + 0.4))) : buckets[day] ?? 0
                columns.append(
                    Column(id: offset, words: value, label: label, isCurrent: offset == count - 1))
            }
        case .all:
            let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
            let earliest = records.map(\.createdAt).min() ?? today
            let span =
                calendar.dateComponents([.weekOfYear], from: earliest, to: thisWeek).weekOfYear ?? 0
            let weeks = usesFixture ? 12 : min(12, max(4, span + 1))
            for offset in 0..<weeks {
                guard
                    let weekStart = calendar.date(
                        byAdding: .weekOfYear, value: offset - (weeks - 1), to: thisWeek),
                    let interval = calendar.dateInterval(of: .weekOfYear, for: weekStart)
                else { continue }
                let value =
                    usesFixture
                    ? Int(600 + 1_400 * abs(sin(Double(offset) * 1.3 + 0.2)))
                    : entries.filter { interval.contains($0.date) }.reduce(0) { $0 + $1.words }
                let label =
                    offset % 3 == (weeks - 1) % 3
                    ? weekStart.formatted(.dateTime.day().month(.abbreviated).locale(locale)) : ""
                columns.append(
                    Column(id: offset, words: value, label: label, isCurrent: offset == weeks - 1))
            }
        }
        self.columns = columns
        if let best = columns.max(by: { $0.words < $1.words }), best.words > 0 {
            let index = columns.firstIndex { $0.id == best.id } ?? 0
            let offset = index - (columns.count - 1)
            let name: String
            switch period {
            case .week, .month:
                let day = calendar.date(byAdding: .day, value: offset, to: today) ?? today
                name =
                    period == .week
                    ? day.formatted(.dateTime.weekday(.wide).locale(locale))
                    : day.formatted(.dateTime.day().month(.wide).locale(locale))
            case .all:
                let week =
                    calendar.date(byAdding: .weekOfYear, value: offset, to: today) ?? today
                name = String(
                    "the week of \(week.formatted(.dateTime.day().month(.wide).locale(locale)))",
                    in: locale)
            }
            peak = (label: name, words: best.words)
        } else {
            peak = nil
        }

        // Applications, by dictations, the five busiest then the rest together.
        if usesFixture {
            apps = [
                AppRow(id: "Slack", name: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap", count: 24),
                AppRow(id: "Mail", name: "Mail", bundleIdentifier: "com.apple.mail", count: 19),
                AppRow(id: "Notes", name: "Notes", bundleIdentifier: "com.apple.Notes", count: 18),
                AppRow(id: "Xcode", name: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", count: 12),
                AppRow(id: "Messages", name: "Messages", bundleIdentifier: "com.apple.MobileSMS", count: 9),
                AppRow(id: "other", name: String("Other", in: locale), bundleIdentifier: nil, count: 8),
            ]
        } else {
            let grouped = Dictionary(grouping: inPeriod, by: \.applicationName)
                .map { (name: $0.key, records: $0.value) }
                .sorted { $0.records.count > $1.records.count }
            var rows = grouped.prefix(5).map {
                AppRow(
                    id: $0.name, name: $0.name,
                    bundleIdentifier: $0.records.first?.applicationBundleIdentifier,
                    count: $0.records.count)
            }
            let rest = grouped.dropFirst(5).reduce(0) { $0 + $1.records.count }
            if rest > 0 {
                rows.append(
                    AppRow(
                        id: "other", name: String("Other", in: locale), bundleIdentifier: nil,
                        count: rest))
            }
            apps = rows
        }

        // When: dictations per weekday and two-hour band, the night folded into one band.
        var grid = Array(repeating: Array(repeating: 0, count: Self.bands.count), count: 7)
        if usesFixture {
            for row in 0..<7 {
                for column in Self.bands.indices {
                    let shape = sin(Double(column) * 0.72 + 0.5) * cos(Double(row) * 0.65 - 0.3)
                    grid[row][column] = max(0, Int(shape * (row >= 5 ? 2 : 5)))
                }
            }
        } else {
            for record in inPeriod {
                let hour = calendar.component(.hour, from: record.createdAt)
                let column =
                    Self.bands.firstIndex { hour >= $0.start && hour < $0.end }
                    ?? (Self.bands.count - 1)
                let row =
                    (calendar.component(.weekday, from: record.createdAt) - calendar.firstWeekday + 7)
                    % 7
                grid[row][column] += 1
            }
        }
        hours = grid
        let symbols = calendar.shortStandaloneWeekdaySymbols
        weekdayLabels = (0..<7).map { symbols[($0 + calendar.firstWeekday - 1) % 7] }
        bandLabels = Self.bands.map { "\($0.start) h" }
        let perBand = Self.bands.indices.map { column in grid.reduce(0) { $0 + $1[column] } }
        if let best = perBand.indices.max(by: { perBand[$0] < perBand[$1] }), perBand[best] > 0 {
            busiestBand = bandLabels[best]
        } else {
            busiestBand = nil
        }
    }
}

// MARK: - View

struct StatisticsView: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(TranscriptStore.self) private var transcripts
    @Environment(\.locale) private var locale

    @State private var period = StatisticsPeriod.week
    @State private var model: StatisticsModel?

    var body: some View {
        HubPage {
            HubPageHeader(title: "Statistics") {
                HubSegmented(options: StatisticsPeriod.allCases, selection: $period) {
                    Text($0.title)
                }
            }

            if let model {
                figures(model).padding(.top, 24)

                HubSectionHeader(title: "Words per day") {
                    if let peak = model.peak {
                        Text("Peak \(peak.label), \(peak.words) words")
                    }
                }
                DotColumns(columns: model.columns)
                    .frame(height: 200)

                HStack(alignment: .top, spacing: 40) {
                    VStack(alignment: .leading, spacing: 0) {
                        HubSectionHeader(title: "Applications") { Text("dictations") }
                        apps(model)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    VStack(alignment: .leading, spacing: 0) {
                        HubSectionHeader(title: "Hours") {
                            if let band = model.busiestBand { Text("mostly around \(band)") }
                        }
                        DotMatrix(
                            rows: model.hours,
                            rowLabels: model.weekdayLabels,
                            columnLabels: model.bandLabels
                        )
                        .frame(height: 176)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .onChange(of: period, initial: true) { _, _ in rebuild() }
        .onChange(of: transcripts.records) { _, _ in rebuild() }
        .onChange(of: transcripts.usesExampleData) { _, _ in rebuild() }
        .onChange(of: locale) { _, _ in rebuild() }
    }

    private func rebuild() {
        model = StatisticsModel(
            records: transcripts.records,
            period: period,
            usesFixture: transcripts.usesExampleData,
            locale: locale
        )
    }

    private func figures(_ model: StatisticsModel) -> some View {
        HStack(alignment: .top, spacing: 16) {
            figure("Time saved", value: recovered(model.recoveredMinutes))
            figure("Words dictated", value: Text(model.words.formatted()))
            figure(
                "Speed",
                value: Text("\(model.averageWPM)") + unit(String("words/min", in: locale)))
            figure(
                "Active days",
                value: Text("\(model.activeDays)")
                    + unit(String("of \(model.spanDays)", in: locale)))
        }
    }

    private func figure(_ label: LocalizedStringKey, value: Text) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(VoxoLTypography.font(size: 13))
                .foregroundStyle(theme.secondaryInk)
            value
                .font(VoxoLTypography.font(size: 28, weight: .medium))
                .foregroundStyle(theme.ink)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func unit(_ text: String) -> Text {
        Text(verbatim: " " + text)
            .font(VoxoLTypography.font(size: 14))
            .foregroundColor(theme.secondaryInk)
    }

    private func recovered(_ minutes: Int) -> Text {
        guard minutes >= 60 else { return Text("\(minutes)") + unit("min") }
        return Text("\(minutes / 60)") + unit("h") + Text(verbatim: String(format: " %02d", minutes % 60))
            + unit("min")
    }

    private func apps(_ model: StatisticsModel) -> some View {
        let top = max(1, model.apps.map(\.count).max() ?? 1)
        return VStack(alignment: .leading, spacing: 4) {
            if model.apps.isEmpty {
                Text("No dictation in this period.")
                    .font(VoxoLTypography.font(size: 13))
                    .foregroundStyle(theme.secondaryInk)
            }
            ForEach(Array(model.apps.enumerated()), id: \.element.id) { index, app in
                HStack(spacing: 10) {
                    HubAppIcon(bundleIdentifier: app.bundleIdentifier)
                    Text(verbatim: app.name)
                        .font(VoxoLTypography.font(size: 13))
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                        .frame(width: 84, alignment: .leading)
                    GeometryReader { geometry in
                        Capsule()
                            .fill(index == 0 ? theme.ink : theme.selection)
                            .frame(
                                width: max(4, geometry.size.width * CGFloat(app.count) / CGFloat(top)),
                                height: 4
                            )
                            .frame(maxHeight: .infinity)
                    }
                    Text(app.count.formatted())
                        .font(VoxoLTypography.font(size: 13))
                        .foregroundStyle(theme.secondaryInk)
                        .monospacedDigit()
                        .frame(width: 32, alignment: .trailing)
                }
                .frame(height: 28)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

// MARK: - Charts, printed in dots

/// Columns of halftone dots, denser at their foot, with a scale on the right. The current period
/// is printed in the data colour.
private struct DotColumns: View {
    @Environment(VoxoLTheme.self) private var theme

    let columns: [StatisticsModel.Column]

    var body: some View {
        let maximum = max(1, columns.map(\.words).max() ?? 1)
        let step = Self.niceStep(for: maximum)
        let top = Int((Double(maximum) / Double(step)).rounded(.up)) * step

        Canvas { context, size in
            let scaleWidth: CGFloat = 40
            let labelHeight: CGFloat = 20
            let plotHeight = size.height - labelHeight - 6
            let base = 6 + plotHeight
            let plotWidth = size.width - scaleWidth

            // Gridlines and the scale.
            var value = 0
            while value <= top {
                let y = base - CGFloat(value) / CGFloat(top) * plotHeight
                context.fill(
                    Path(CGRect(x: 0, y: y.rounded(), width: plotWidth, height: 1)),
                    with: .color(theme.well))
                context.draw(
                    Text(value.formatted())
                        .font(VoxoLTypography.font(size: 11))
                        .foregroundColor(theme.secondaryInk),
                    at: CGPoint(x: size.width, y: y), anchor: .trailing)
                value += step
            }

            let slot = plotWidth / CGFloat(max(1, columns.count))
            let cell: CGFloat = columns.count > 10 ? 4 : 6
            let columnWidth = max(cell * 2, min(slot * 0.6, cell * 7))
            for (index, column) in columns.enumerated() {
                let x = CGFloat(index) * slot + (slot - columnWidth) / 2
                let height = CGFloat(column.words) / CGFloat(top) * plotHeight
                if column.words > 0 {
                    context.fill(
                        Self.dots(x: x, width: columnWidth, height: height, base: base, cell: cell),
                        with: .color(column.isCurrent ? theme.cobalt : theme.ink))
                }
                if !column.label.isEmpty {
                    context.draw(
                        Text(verbatim: column.label)
                            .font(VoxoLTypography.font(size: 11))
                            .foregroundColor(column.isCurrent ? theme.ink : theme.secondaryInk),
                        at: CGPoint(x: CGFloat(index) * slot + slot / 2, y: size.height - 2),
                        anchor: .bottom)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Words per day"))
    }

    /// A column dithered like the prints: every dot present at the foot, fewer toward the top.
    static func dots(x: CGFloat, width: CGFloat, height: CGFloat, base: CGFloat, cell: CGFloat) -> Path {
        var path = Path()
        let columns = max(1, Int((width / cell).rounded()))
        let rows = max(1, Int((height / cell).rounded()))
        for column in 0..<columns {
            for row in 0..<rows {
                let t = rows == 1 ? 0 : Double(row) / Double(rows - 1)
                let edge = (columns > 2 && (column == 0 || column == columns - 1)) ? 0.7 : 1
                guard grain(Double(x / cell) + Double(column) * 1.7, Double(row) * 1.3)
                    <= (0.97 - 0.55 * t) * edge
                else { continue }
                let radius = cell * (0.3 + 0.14 * grain(Double(row), Double(x) + Double(column)))
                path.addEllipse(
                    in: CGRect(
                        x: x + CGFloat(column) * cell + cell / 2 - radius,
                        y: base - CGFloat(row) * cell - cell / 2 - radius,
                        width: radius * 2, height: radius * 2))
            }
        }
        return path
    }

    static func grain(_ x: Double, _ y: Double) -> Double {
        let value = sin(x * 127.1 + y * 311.7 + 47.3) * 43758.5453
        return value - value.rounded(.down)
    }

    static func niceStep(for maximum: Int) -> Int {
        let rough = Double(maximum) / 4
        let magnitude = pow(10, floor(log10(max(1, rough))))
        let normalized = rough / magnitude
        let nice: Double = normalized <= 1 ? 1 : normalized <= 2 ? 2 : normalized <= 5 ? 5 : 10
        return max(1, Int(nice * magnitude))
    }
}

/// One dot per cell, its size the count: a calendar of when the voice gets used.
private struct DotMatrix: View {
    @Environment(VoxoLTheme.self) private var theme

    let rows: [[Int]]
    let rowLabels: [String]
    let columnLabels: [String]

    var body: some View {
        let maximum = max(1, rows.flatMap { $0 }.max() ?? 1)
        Canvas { context, size in
            let labelWidth: CGFloat = 36
            let labelHeight: CGFloat = 18
            let cellWidth = (size.width - labelWidth) / CGFloat(max(1, columnLabels.count))
            let cellHeight = (size.height - labelHeight) / CGFloat(max(1, rows.count))
            for (row, values) in rows.enumerated() {
                let y = CGFloat(row) * cellHeight + cellHeight / 2
                context.draw(
                    Text(verbatim: rowLabels[row])
                        .font(VoxoLTypography.font(size: 11))
                        .foregroundColor(theme.secondaryInk),
                    at: CGPoint(x: 0, y: y), anchor: .leading)
                for (column, count) in values.enumerated() {
                    let x = labelWidth + CGFloat(column) * cellWidth + cellWidth / 2
                    let radius =
                        count > 0
                        ? 2 + CGFloat(count) / CGFloat(maximum) * min(cellWidth, cellHeight) * 0.3
                        : 1.3
                    context.fill(
                        Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                        with: .color(count > 0 ? theme.ink : theme.selection))
                }
            }
            for (column, label) in columnLabels.enumerated() where column % 2 == 0 {
                context.draw(
                    Text(verbatim: label)
                        .font(VoxoLTypography.font(size: 11))
                        .foregroundColor(theme.secondaryInk),
                    at: CGPoint(x: labelWidth + CGFloat(column) * cellWidth + cellWidth / 2, y: size.height),
                    anchor: .bottom)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Dictations by day and hour"))
    }
}
