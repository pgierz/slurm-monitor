import Foundation

/// Pure text formatters for the figures the widgets show.
public enum Format {
    /// The placeholder for unknown values.
    public static let dash = "—"

    /// `5:12` — hours and two-digit minutes; seconds are dropped.
    public static func hoursMinutes(seconds: Int) -> String {
        let clamped = max(0, seconds)
        return "\(clamped / 3600):\(twoDigits((clamped % 3600) / 60))"
    }

    /// `5:12`, or `—` when the value is unknown.
    public static func hoursMinutes(seconds: Int?) -> String {
        guard let seconds = seconds else { return dash }
        return hoursMinutes(seconds: seconds)
    }

    /// `3h 12m` from one hour on, `18 min` below. Seconds are dropped.
    public static func durationWords(seconds: Int) -> String {
        let clamped = max(0, seconds)
        let hours = clamped / 3600
        let minutes = (clamped % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes) min"
    }

    /// `3h 12m` or `18 min`, or `—` when the value is unknown.
    public static func durationWords(seconds: Int?) -> String {
        guard let seconds = seconds else { return dash }
        return durationWords(seconds: seconds)
    }

    /// `5:12 / 12:00`; `5:12 / ∞` for an unlimited job.
    public static func elapsedOverLimit(elapsedSeconds: Int, limitSeconds: Int?) -> String {
        let limit = limitSeconds.map { hoursMinutes(seconds: $0) } ?? "∞"
        return hoursMinutes(seconds: elapsedSeconds) + " / " + limit
    }

    /// `950`, `14.2k`, `18k`, `1.5M` — at most one decimal, none when it is zero.
    public static func compactCount(_ value: Int) -> String {
        let magnitude = abs(value)
        if magnitude < 1000 {
            return "\(value)"
        }
        let sign = value < 0 ? "-" : ""
        var tenths = (magnitude * 10 + 500) / 1000
        var suffix = "k"
        if tenths >= 10000 {
            tenths = (magnitude * 10 + 500_000) / 1_000_000
            suffix = "M"
        }
        let whole = tenths / 10
        let fraction = tenths % 10
        if fraction == 0 {
            return "\(sign)\(whole)\(suffix)"
        }
        return "\(sign)\(whole).\(fraction)\(suffix)"
    }

    /// `14.2k / 18k`; only `14.2k` when there is no limit.
    public static func countOverLimit(_ value: Int, limit: Int?) -> String {
        guard let limit = limit else { return compactCount(value) }
        return compactCount(value) + " / " + compactCount(limit)
    }

    /// The whole percentage of a fraction, rounded: `0.826` gives `83`.
    public static func percentValue(_ fraction: Double) -> Int {
        Int((fraction * 100).rounded())
    }

    /// `97%` from `0.97`.
    public static func percent(_ fraction: Double) -> String {
        "\(percentValue(fraction))%"
    }

    /// `97%`, or `—` when the value is unknown.
    public static func percent(_ fraction: Double?) -> String {
        guard let fraction = fraction else { return dash }
        return percent(fraction)
    }

    /// `11/16`.
    public static func ratio(_ part: Int, _ whole: Int) -> String {
        "\(part)/\(whole)"
    }

    /// `12 R · 3 PD`.
    public static func queueLine(running: Int, pending: Int) -> String {
        "\(running) R · \(pending) PD"
    }

    /// `12 R · 3 PD`, or `—` when no user is known.
    public static func queueLine(_ counts: JobCounts?) -> String {
        guard let counts = counts else { return dash }
        return queueLine(running: counts.running, pending: counts.pending)
    }

    /// `HH:mm` on a 24 hour clock in the given time zone.
    public static func clockTime(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return twoDigits(parts.hour ?? 0) + ":" + twoDigits(parts.minute ?? 0)
    }

    /// `~ 15:40`, the estimated start of a pending job.
    public static func estimatedStart(_ date: Date, timeZone: TimeZone) -> String {
        "~ " + clockTime(date, timeZone: timeZone)
    }

    /// `as of 13:05`, the header of a stale widget.
    public static func asOf(_ date: Date, timeZone: TimeZone) -> String {
        "as of " + clockTime(date, timeZone: timeZone)
    }

    /// `36G` from MiB, rounded to whole GiB.
    public static func memoryGigabytes(mib: Int) -> String {
        "\(Int((Double(mib) / 1024).rounded()))G"
    }

    /// `36G`, or `—` when the value is unknown.
    public static func memoryGigabytes(mib: Int?) -> String {
        guard let mib = mib else { return dash }
        return memoryGigabytes(mib: mib)
    }

    /// `74°`, or `—` when the value is unknown.
    public static func temperature(celsius: Double?) -> String {
        guard let celsius = celsius else { return dash }
        return "\(Int(celsius.rounded()))°"
    }

    /// `286W`, or `—` when the value is unknown.
    public static func power(watts: Double?) -> String {
        guard let watts = watts else { return dash }
        return "\(Int(watts.rounded()))W"
    }

    /// `0.42`, a fairshare factor with two decimals; `—` when unknown.
    public static func fairshare(_ value: Double?) -> String {
        guard let value = value else { return dash }
        let hundredths = Int((value * 100).rounded())
        return "\(hundredths / 100).\(twoDigits(hundredths % 100))"
    }

    /// The text inside a GPU card cell: `97%`, `alloc`, `free`, `drain`, `down`.
    public static func cardText(_ card: GpuCard) -> String {
        switch card.state {
        case .busy, .idleAllocated:
            return card.utilisation.map { percent($0) } ?? "alloc"
        case .allocated:
            return "alloc"
        case .free:
            return "free"
        case .drained:
            return "drain"
        case .down:
            return "down"
        case .unknown:
            return dash
        }
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}

// MARK: - Derived view values

/// The four node states with their counts, in display order.
public struct NodeStateCounts: Sendable, Equatable {
    public var allocated: Int
    public var idle: Int
    public var drained: Int
    public var down: Int

    public init(allocated: Int, idle: Int, drained: Int, down: Int) {
        self.allocated = allocated
        self.idle = idle
        self.drained = drained
        self.down = down
    }

    /// Sum of the four counts.
    public var total: Int { allocated + idle + drained + down }

    /// Each count as a fraction of the sum, in the order allocated, idle, drained, down.
    public var fractions: [Double] {
        let sum = total
        if sum == 0 { return [0, 0, 0, 0] }
        return [allocated, idle, drained, down].map { Double($0) / Double(sum) }
    }
}

extension NodesData {
    /// Allocated nodes over all nodes, 0…1; 0 when there are no nodes.
    public var allocatedFraction: Double {
        total > 0 ? Double(allocated) / Double(total) : 0
    }

    /// The four counts for the ring and the legend.
    public var stateCounts: NodeStateCounts {
        NodeStateCounts(allocated: allocated, idle: idle, drained: drained, down: down)
    }
}

extension PartitionNodes {
    /// Allocated nodes over all nodes of the partition, 0…1.
    public var allocatedFraction: Double {
        total > 0 ? Double(allocated) / Double(total) : 0
    }

    /// The four counts for the stacked bar.
    public var stateCounts: NodeStateCounts {
        NodeStateCounts(allocated: allocated, idle: idle, drained: drained, down: down)
    }

    /// `148/170`.
    public var allocatedText: String {
        Format.ratio(allocated, total)
    }
}

extension QosEntry {
    /// CPUs in use over the limit; `nil` without a limit or with a limit of zero.
    public var usedFraction: Double? {
        guard let limit = cpuLimit, limit > 0 else { return nil }
        return Double(cpusInUse) / Double(limit)
    }

    /// True above 95 % of the limit; the bar then turns amber.
    public var isNearLimit: Bool {
        guard let fraction = usedFraction else { return false }
        return fraction > 0.95
    }

    /// `14.2k / 18k`.
    public var usageText: String {
        Format.countOverLimit(cpusInUse, limit: cpuLimit)
    }
}

extension QueueData {
    /// The user's pending job with the earliest estimated start, if any has one.
    public var nextPendingStart: JobSummary? {
        myJobs
            .filter { $0.state == .pending && $0.estimatedStart != nil }
            .min { ($0.estimatedStart ?? .distantFuture) < ($1.estimatedStart ?? .distantFuture) }
    }

    /// How many of the user's jobs are not in `myJobs`, given how many rows are shown.
    public func moreJobsCount(shown: Int) -> Int {
        max(0, myJobsTotal - min(shown, myJobs.count))
    }

    /// `12 R · 3 PD` for the user's jobs, `—` when no user is known.
    public var mineLine: String {
        Format.queueLine(mine)
    }
}

extension JobSummary {
    /// Elapsed time over the limit, 0…1; `nil` for unlimited jobs.
    public var elapsedFraction: Double? {
        guard let limit = timeLimitSeconds, limit > 0 else { return nil }
        return min(1, Double(elapsedSeconds) / Double(limit))
    }
}

extension GpuTypeCount {
    /// `11/16`.
    public var allocatedText: String {
        Format.ratio(allocated, total)
    }

    /// Allocated cards over all cards of the type, 0…1.
    public var allocatedFraction: Double {
        total > 0 ? Double(allocated) / Double(total) : 0
    }
}

extension GpuCard {
    /// Memory used over memory total, 0…1; `nil` without metrics.
    public var memoryFraction: Double? {
        guard let used = memoryUsedMib, let total = memoryTotalMib, total > 0 else { return nil }
        return min(1, Double(used) / Double(total))
    }
}

/// The GPU nodes of one type, for the grouped grid.
public struct GpuTypeGroup: Sendable, Equatable, Identifiable {
    public var type: GpuTypeCount
    public var nodes: [GpuNode]

    public var id: String { type.type }

    public init(type: GpuTypeCount, nodes: [GpuNode]) {
        self.type = type
        self.nodes = nodes
    }

    /// The largest card count among the nodes of the group; 0 without nodes.
    public var cardsPerNode: Int {
        nodes.map { $0.cards.count }.max() ?? 0
    }

    /// `A100 · 4 per node`.
    public var heading: String {
        "\(type.label) · \(cardsPerNode) per node"
    }
}

extension GpuData {
    /// Allocated cards over all cards, 0…1.
    public var allocatedFraction: Double {
        total > 0 ? Double(allocated) / Double(total) : 0
    }

    /// `14/24`.
    public var allocatedText: String {
        Format.ratio(allocated, total)
    }

    /// The nodes grouped by type, in the order of `types`. Nodes of a type
    /// missing from `types` form further groups at the end, counted from their cards.
    public var typeGroups: [GpuTypeGroup] {
        var groups: [GpuTypeGroup] = []
        var known = Set<String>()
        for type in types {
            known.insert(type.type)
            groups.append(GpuTypeGroup(type: type, nodes: nodes.filter { $0.type == type.type }))
        }
        var extraOrder: [String] = []
        for node in nodes where !known.contains(node.type) {
            known.insert(node.type)
            extraOrder.append(node.type)
        }
        for name in extraOrder {
            let members = nodes.filter { $0.type == name }
            let cards = members.flatMap { $0.cards }
            let count = GpuTypeCount(type: name, label: name.uppercased(), total: cards.count, allocated: cards.filter { $0.state.isAllocated }.count)
            groups.append(GpuTypeGroup(type: count, nodes: members))
        }
        return groups
    }

    /// True when the amber "allocated but idle" line is to be shown.
    public var showsIdleAllocated: Bool {
        metricsAvailable && (idleAllocated ?? 0) > 0
    }

    /// The sparkline values, oldest first: utilisation with metrics, the allocated fraction without.
    public var sparklineValues: [Double] {
        if metricsAvailable {
            return history.map { $0.utilisation ?? 0 }
        }
        return history.map { $0.allocatedFraction }
    }

    /// `utilisation, 6 h` with metrics, `allocated, 6 h` without.
    public var sparklineLabel: String {
        metricsAvailable ? "utilisation, 6 h" : "allocated, 6 h"
    }

    /// The latest sparkline value, if there is any history.
    public var currentSparklineValue: Double? {
        sparklineValues.last
    }

    /// `6 jobs pending · 3h 12m`; only the first part when no wait is known.
    public var pendingLine: String {
        let jobs = "\(pendingJobs) jobs pending"
        guard let wait = longestWaitSeconds else { return jobs }
        return jobs + " · " + Format.durationWords(seconds: wait)
    }
}

extension DaskCluster {
    /// `owner · id`.
    public var label: String {
        owner + " · " + id
    }

    /// `14/16`.
    public var workersText: String {
        Format.ratio(workersRunning, workersRequested)
    }

    /// `0:42`, or `—` when unknown.
    public var walltimeLeftText: String {
        Format.hoursMinutes(seconds: walltimeLeftSeconds)
    }

    /// True below 15 minutes of walltime left; the figure then turns amber.
    public var isNearWalltime: Bool {
        guard let left = walltimeLeftSeconds else { return false }
        return left < 900
    }
}

extension CiRunners {
    /// `18 min`, or `—` when no job waits.
    public var oldestWaitText: String {
        Format.durationWords(seconds: oldestWaitSeconds)
    }
}
