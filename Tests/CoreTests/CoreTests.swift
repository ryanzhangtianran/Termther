import Testing
@testable import Core

@Test("every vendored engine links and runs")
func enginesLink() async {
    for (engine, ok) in await Termther.selfCheck() {
        #expect(ok, "\(engine) failed its link check")
    }
}
