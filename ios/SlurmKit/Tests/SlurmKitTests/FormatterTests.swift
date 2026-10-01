import Foundation
import XCTest
@testable import SlurmKit

final class FormatterTests: XCTestCase {
    func testHoursMinutes() {
        XCTAssertEqual(Format.hoursMinutes(seconds: 18720), "5:12")
        XCTAssertEqual(Format.hoursMinutes(seconds: 43200), "12:00")
        XCTAssertEqual(Format.hoursMinutes(seconds: 2520), "0:42")
        XCTAssertEqual(Format.hoursMinutes(seconds: 0), "0:00")
        XCTAssertEqual(Format.hoursMinutes(seconds: 172_800), "48:00")
        XCTAssertEqual(Format.hoursMinutes(seconds: -5), "0:00")
        let unknown: Int? = nil
        XCTAssertEqual(Format.hoursMinutes(seconds: unknown), "—")
    }

    func testDurationWords() {
        XCTAssertEqual(Format.durationWords(seconds: 11520), "3h 12m")
        XCTAssertEqual(Format.durationWords(seconds: 1080), "18 min")
        XCTAssertEqual(Format.durationWords(seconds: 3600), "1h 0m")
        XCTAssertEqual(Format.durationWords(seconds: 59), "0 min")
        let unknown: Int? = nil
        XCTAssertEqual(Format.durationWords(seconds: unknown), "—")
    }

    func testElapsedOverLimit() {
        XCTAssertEqual(Format.elapsedOverLimit(elapsedSeconds: 18720, limitSeconds: 43200), "5:12 / 12:00")
        XCTAssertEqual(Format.elapsedOverLimit(elapsedSeconds: 18720, limitSeconds: nil), "5:12 / ∞")
    }

    func testCompactCount() {
        XCTAssertEqual(Format.compactCount(0), "0")
        XCTAssertEqual(Format.compactCount(950), "950")
        XCTAssertEqual(Format.compactCount(1000), "1k")
        XCTAssertEqual(Format.compactCount(14200), "14.2k")
        XCTAssertEqual(Format.compactCount(14249), "14.2k")
        XCTAssertEqual(Format.compactCount(14250), "14.3k")
        XCTAssertEqual(Format.compactCount(18000), "18k")
        XCTAssertEqual(Format.compactCount(999_949), "999.9k")
        XCTAssertEqual(Format.compactCount(999_950), "1M")
        XCTAssertEqual(Format.compactCount(1_500_000), "1.5M")
        XCTAssertEqual(Format.compactCount(-14200), "-14.2k")
        XCTAssertEqual(Format.countOverLimit(14200, limit: 18000), "14.2k / 18k")
        XCTAssertEqual(Format.countOverLimit(620, limit: nil), "620")
    }

    func testPercent() {
        XCTAssertEqual(Format.percent(0.97), "97%")
        XCTAssertEqual(Format.percent(0.826), "83%")
        XCTAssertEqual(Format.percent(0.0), "0%")
        XCTAssertEqual(Format.percent(1.0), "100%")
        XCTAssertEqual(Format.percentValue(198.0 / 240.0), 83)
        let unknown: Double? = nil
        XCTAssertEqual(Format.percent(unknown), "—")
    }

    func testQueueLineAndRatio() {
        XCTAssertEqual(Format.queueLine(running: 12, pending: 3), "12 R · 3 PD")
        XCTAssertEqual(Format.queueLine(JobCounts(running: 12, pending: 3)), "12 R · 3 PD")
        XCTAssertEqual(Format.queueLine(nil), "—")
        XCTAssertEqual(Format.ratio(11, 16), "11/16")
    }

    func testClockTime() throws {
        let date = Date(timeIntervalSince1970: 1_790_812_800 + 13 * 3600 + 40 * 60)
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let berlin = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        XCTAssertEqual(Format.clockTime(date, timeZone: utc), "13:40")
        XCTAssertEqual(Format.clockTime(date, timeZone: berlin), "15:40")
        XCTAssertEqual(Format.estimatedStart(date, timeZone: berlin), "~ 15:40")
        XCTAssertEqual(Format.asOf(date, timeZone: utc), "as of 13:40")
        let early = Date(timeIntervalSince1970: 1_790_812_800 + 5 * 60)
        XCTAssertEqual(Format.clockTime(early, timeZone: utc), "00:05")
    }

    func testMemoryTemperaturePowerFairshare() {
        XCTAssertEqual(Format.memoryGigabytes(mib: 36864), "36G")
        XCTAssertEqual(Format.memoryGigabytes(mib: 40960), "40G")
        XCTAssertEqual(Format.memoryGigabytes(mib: 0), "0G")
        let unknownMemory: Int? = nil
        XCTAssertEqual(Format.memoryGigabytes(mib: unknownMemory), "—")
        XCTAssertEqual(Format.temperature(celsius: 74), "74°")
        XCTAssertEqual(Format.temperature(celsius: nil), "—")
        XCTAssertEqual(Format.power(watts: 286), "286W")
        XCTAssertEqual(Format.power(watts: nil), "—")
        XCTAssertEqual(Format.fairshare(0.42), "0.42")
        XCTAssertEqual(Format.fairshare(0.05), "0.05")
        XCTAssertEqual(Format.fairshare(1.0), "1.00")
        XCTAssertEqual(Format.fairshare(nil), "—")
    }

    func testCardText() {
        func card(_ state: CardState, _ utilisation: Double?) -> GpuCard {
            GpuCard(index: 0, state: state, utilisation: utilisation, memoryUsedMib: nil, memoryTotalMib: nil, temperatureC: nil, powerW: nil, user: nil)
        }
        XCTAssertEqual(Format.cardText(card(.busy, 0.97)), "97%")
        XCTAssertEqual(Format.cardText(card(.idleAllocated, 0.01)), "1%")
        XCTAssertEqual(Format.cardText(card(.allocated, nil)), "alloc")
        XCTAssertEqual(Format.cardText(card(.free, nil)), "free")
        XCTAssertEqual(Format.cardText(card(.drained, nil)), "drain")
        XCTAssertEqual(Format.cardText(card(.down, nil)), "down")
    }

    func testNodeDerivedValues() {
        let nodes = SampleData.nodes.data
        XCTAssertEqual(nodes.allocatedFraction, 198.0 / 240.0, accuracy: 1e-9)
        XCTAssertEqual(Format.percent(nodes.allocatedFraction), "83%")
        XCTAssertEqual(nodes.stateCounts.total, 240)
        XCTAssertEqual(nodes.stateCounts.fractions.reduce(0, +), 1.0, accuracy: 1e-9)
        XCTAssertEqual(nodes.partitions[0].allocatedText, "148/170")
        XCTAssertEqual(NodeStateCounts(allocated: 0, idle: 0, drained: 0, down: 0).fractions, [0, 0, 0, 0])
        let empty = NodesData(total: 0, allocated: 0, idle: 0, drained: 0, down: 0, partitions: [])
        XCTAssertEqual(empty.allocatedFraction, 0)
    }

    func testQosDerivedValues() {
        let entries = SampleData.qos.data.qos
        XCTAssertEqual(entries.map { $0.name }, ["12h", "48h", "30min"])
        XCTAssertEqual(entries[0].usageText, "14.2k / 18k")
        XCTAssertFalse(entries[0].isNearLimit)
        XCTAssertTrue(entries[1].isNearLimit)
        XCTAssertFalse(QosEntry(name: "x", cpusInUse: 95, cpuLimit: 100, runningJobs: 0, pendingJobs: 0, maxWallSeconds: nil).isNearLimit)
        XCTAssertTrue(QosEntry(name: "x", cpusInUse: 96, cpuLimit: 100, runningJobs: 0, pendingJobs: 0, maxWallSeconds: nil).isNearLimit)
        let unlimited = QosEntry(name: "x", cpusInUse: 96, cpuLimit: nil, runningJobs: 0, pendingJobs: 0, maxWallSeconds: nil)
        XCTAssertNil(unlimited.usedFraction)
        XCTAssertFalse(unlimited.isNearLimit)
    }

    func testGpuDerivedValues() {
        let gpu = SampleData.gpu.data
        XCTAssertEqual(gpu.allocatedText, "14/24")
        XCTAssertEqual(gpu.types.map { $0.label + " " + $0.allocatedText }, ["A100 11/16", "A40 3/8"])
        let groups = gpu.typeGroups
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].heading, "A100 · 4 per node")
        XCTAssertEqual(groups[0].nodes.count, 4)
        XCTAssertEqual(groups[1].cardsPerNode, 2)
        XCTAssertEqual(groups[1].nodes.map { $0.name }, ["gpu-005", "gpu-006", "gpu-007", "gpu-008"])
        XCTAssertTrue(gpu.showsIdleAllocated)
        XCTAssertEqual(gpu.sparklineLabel, "utilisation, 6 h")
        XCTAssertEqual(gpu.currentSparklineValue, 0.71)
        XCTAssertEqual(gpu.pendingLine, "6 jobs pending · 3h 12m")
        XCTAssertEqual(gpu.nodes[0].cards[0].memoryFraction ?? 0, 0.9, accuracy: 1e-9)

        var odd = gpu
        odd.nodes.append(GpuNode(name: "gpu-099", type: "h100", state: .idle, cards: [
            GpuCard(index: 0, state: .free, utilisation: nil, memoryUsedMib: nil, memoryTotalMib: nil, temperatureC: nil, powerW: nil, user: nil),
        ]))
        XCTAssertEqual(odd.typeGroups.count, 3)
        XCTAssertEqual(odd.typeGroups[2].type, GpuTypeCount(type: "h100", label: "H100", total: 1, allocated: 0))
    }

    func testQueueAndRunnerDerivedValues() throws {
        let queue = SampleData.queue.data
        XCTAssertEqual(queue.mineLine, "12 R · 3 PD")
        XCTAssertEqual(queue.nextPendingStart?.name, "awiesm_lig127k")
        XCTAssertEqual(queue.moreJobsCount(shown: 7), 8)
        XCTAssertEqual(queue.moreJobsCount(shown: 20), 0)
        XCTAssertEqual(queue.myJobs[0].elapsedFraction ?? 0, 18720.0 / 43200.0, accuracy: 1e-9)

        let runners = SampleData.runners.data
        XCTAssertEqual(runners.ci.oldestWaitText, "18 min")
        XCTAssertEqual(runners.dask.clusters[0].label, "alice · a3f1")
        XCTAssertEqual(runners.dask.clusters[0].workersText, "14/16")
        XCTAssertEqual(runners.dask.clusters[0].walltimeLeftText, "0:42")
        XCTAssertFalse(runners.dask.clusters[0].isNearWalltime)
        XCTAssertTrue(runners.dask.clusters[1].isNearWalltime)
        XCTAssertEqual(runners.dask.clusters[2].walltimeLeftText, "—")
    }

    func testSampleDataMatchesTheMockupFigures() {
        let nodes = SampleData.nodes.data
        XCTAssertEqual(nodes.partitions.map { $0.name }, ["mpp", "smp", "fat", "gpu"])
        XCTAssertEqual(nodes.partitions.map { $0.total }, [170, 50, 12, 8])
        XCTAssertEqual(nodes.partitions.map { $0.nodes.count }, [170, 50, 12, 8])
        XCTAssertEqual(nodes.partitions.reduce(0) { $0 + $1.allocated }, nodes.allocated)
        XCTAssertEqual(nodes.partitions.reduce(0) { $0 + $1.idle }, nodes.idle)
        XCTAssertEqual(nodes.partitions.reduce(0) { $0 + $1.drained }, nodes.drained)
        XCTAssertEqual(nodes.partitions.reduce(0) { $0 + $1.down }, nodes.down)
        XCTAssertEqual(nodes.partitions[0].allocated, 148)
        XCTAssertEqual(nodes.partitions[0].down, 2)
        XCTAssertEqual(nodes.partitions[0].nodes.first?.name, "prod-001")
        XCTAssertEqual(nodes.partitions[0].nodes.last?.name, "prod-170")
        XCTAssertEqual(nodes.partitions[0].nodes.filter { $0.state == .down }.count, 2)

        let queue = SampleData.queue.data
        XCTAssertEqual(queue.running, 412)
        XCTAssertEqual(queue.pending, 96)
        XCTAssertEqual(queue.myJobs.count, 15)
        XCTAssertEqual(queue.myJobs.filter { $0.state == .running }.count, 12)
        XCTAssertEqual(queue.pendingByReason.reduce(0) { $0 + $1.count }, 96)
        XCTAssertEqual(queue.history.count, 72)

        let gpu = SampleData.gpu.data
        let cards = gpu.nodes.flatMap { $0.cards }
        XCTAssertEqual(cards.count, 24)
        XCTAssertEqual(cards.filter { $0.state.isAllocated }.count, 14)
        XCTAssertEqual(cards.filter { $0.state == .idleAllocated }.count, 3)
        XCTAssertEqual(gpu.topUsers.reduce(0) { $0 + $1.cards }, 14)
        XCTAssertEqual(gpu.history.count, 72)

        let plain = SampleData.gpuNoMetrics.data
        XCTAssertFalse(plain.metricsAvailable)
        XCTAssertNil(plain.idleAllocated)
        let plainCards = plain.nodes.flatMap { $0.cards }
        XCTAssertEqual(plainCards.filter { $0.state == .allocated }.count, 14)
        XCTAssertFalse(plainCards.contains { $0.state == .busy || $0.state == .idleAllocated })
        XCTAssertTrue(plainCards.allSatisfy { $0.utilisation == nil && $0.memoryUsedMib == nil })
        XCTAssertTrue(plain.history.allSatisfy { $0.utilisation == nil })

        let runners = SampleData.runners.data
        XCTAssertEqual(runners.dask.clusters.count, 3)
        XCTAssertEqual(runners.jupyterhub, JupyterHubRunners(sessions: 23, withGpu: 4, nearWalltime: 2))
    }
}
