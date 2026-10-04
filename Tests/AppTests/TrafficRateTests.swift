import SSH
import Testing
@testable import App

/// Bandwidth, from two samples of a tunnel's running totals.
struct TrafficRateTests {
    private func stats(in bytesIn: UInt64, out bytesOut: UInt64) -> PortForward.Statistics {
        var stats = PortForward.Statistics()
        stats.bytesIn = bytesIn
        stats.bytesOut = bytesOut
        return stats
    }

    @Test("the difference over the interval, each way")
    func perSecond() {
        let rate = Forwards.Rate.between(stats(in: 1_000, out: 100),
                                         stats(in: 3_000, out: 700), seconds: 2)
        #expect(rate.bytesInPerSecond == 1_000)
        #expect(rate.bytesOutPerSecond == 300)
    }

    @Test("counters that went back to zero read as idle, not as a huge rate")
    func restartedCounters() {
        let rate = Forwards.Rate.between(stats(in: 5_000, out: 5_000),
                                         stats(in: 10, out: 20), seconds: 1)
        #expect(rate == Forwards.Rate())
    }

    @Test("no time between samples is no rate, not a division by zero")
    func noInterval() {
        let rate = Forwards.Rate.between(stats(in: 0, out: 0),
                                         stats(in: 100, out: 100), seconds: 0)
        #expect(rate == Forwards.Rate())
    }
}
