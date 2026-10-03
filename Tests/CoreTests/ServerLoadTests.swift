import Foundation
import Testing
@testable import Core

/// The load figures a connection card shows, from one script sent over exec.
struct ServerLoadTests {
    @Test("a Linux answer with two GPUs is read in full")
    func linux() {
        let load = ServerLoad.parse("""
            cpu_total=1000000
            cpu_idle=625000
            mem_total=67108864000
            mem_used=16777216000
            load1=2.41
            uptime=273840
            gpu=NVIDIA GeForce RTX 4090|71|18432|24564
            gpu=NVIDIA GeForce RTX 4090|3|512|24564
            disk=63

            """)
        // Counters only: one reading says nothing about use.
        #expect(load.cpuPercent == nil)
        #expect(load.cpuCounters == ServerLoad.CPUCounters(total: 1_000_000, idle: 625_000))
        #expect(load.memoryTotal == 67_108_864_000)
        #expect(load.memoryUsed == 16_777_216_000)
        #expect(load.memoryPercent == 25)
        #expect(load.load1 == 2.41)
        #expect(load.uptime == 273_840)
        #expect(load.diskUsedPercent == 63)
        #expect(load.gpus.count == 2)
        #expect(load.gpus[0].name == "NVIDIA GeForce RTX 4090")
        #expect(load.gpus[0].utilizationPercent == 71)
        // nvidia-smi counts in MiB; the card wants bytes like everything else.
        #expect(load.gpus[0].memoryUsed == 18432 << 20)
        #expect(load.gpus[1].memoryTotal == 24564 << 20)
    }

    @Test("CPU use is the time between two readings that was not idle")
    func cpuBetweenReadings() {
        let first = ServerLoad.parse("cpu_total=1000\ncpu_idle=800\n")
        let second = ServerLoad.parse("cpu_total=1400\ncpu_idle=1100\n", after: first)
        #expect(second.cpuPercent == 25)
        // Nothing to compare with yet, or nothing passed, or a reboot.
        #expect(ServerLoad.parse("cpu_total=1400\ncpu_idle=1100\n", after: nil).cpuPercent == nil)
        #expect(ServerLoad.parse("cpu_total=1400\ncpu_idle=1100\n", after: second).cpuPercent == nil)
        #expect(ServerLoad.parse("cpu_total=100\ncpu_idle=50\n", after: second).cpuPercent == nil)
        // Counters missing on one side -- a macOS answer -- give no figure.
        #expect(ServerLoad.parse("mem_total=1\n", after: second).cpuPercent == nil)
    }

    @Test("a macOS answer has no CPU and no GPUs and is still read")
    func macOS() {
        let load = ServerLoad.parse("""
            mem_total=34359738368
            mem_used=20000000000
            load1=1.87
            uptime=4200
            disk=41
            """)
        #expect(load.cpuPercent == nil)
        #expect(load.memoryTotal == 34_359_738_368)
        #expect(load.load1 == 1.87)
        #expect(load.uptime == 4200)
        #expect(load.gpus.isEmpty)
    }

    @Test("an empty answer is a load with nothing in it, not a failure")
    func empty() {
        #expect(ServerLoad.parse("") == ServerLoad())
        #expect(ServerLoad.parse("nonsense\ncpu_total=\n").cpuCounters == nil)
    }

    @Test("the script runs on this Mac, without sleeping, and reports its memory")
    func runsLocally() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", ServerLoad.script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let load = ServerLoad.parse(output)
        #expect(load.memoryUsed != nil)
        #expect(load.load1 != nil)
    }

    @Test("uptime is said in its two largest units")
    func uptimeWords() {
        #expect(ServerLoad.uptime(3 * 86400 + 4 * 3600 + 59) == "3d 4h")
        #expect(ServerLoad.uptime(5 * 3600 + 12 * 60) == "5h 12m")
        #expect(ServerLoad.uptime(40 * 60) == "40m")
        #expect(ServerLoad.gigabytes(18432 << 20) == "18.0")
    }
}
