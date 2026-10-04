import Foundation

/// What a server is doing right now: CPU, memory, GPUs, load and uptime.
///
/// Read by one shell script sent over `exec`, which prints `key=value` lines.
/// Every figure is optional, because the script runs on whatever the server
/// happens to be and asks for each one separately: a value it cannot get is
/// simply not printed, and the card shows what it did get.
public struct ServerLoad: Equatable, Sendable {
    public struct GPU: Equatable, Sendable {
        public var name: String
        public var utilizationPercent: Double?
        /// Bytes.
        public var memoryUsed: UInt64?
        public var memoryTotal: UInt64?

        public init(name: String, utilizationPercent: Double? = nil,
                    memoryUsed: UInt64? = nil, memoryTotal: UInt64? = nil) {
            self.name = name
            self.utilizationPercent = utilizationPercent
            self.memoryUsed = memoryUsed
            self.memoryTotal = memoryTotal
        }
    }

    /// Since the previous sample; nil on the first, which has nothing to
    /// compare with.
    public var cpuPercent: Double?
    /// The raw counters behind it, kept so the next sample can be compared.
    public var cpuCounters: CPUCounters?
    /// Bytes.
    public var memoryUsed: UInt64?
    public var memoryTotal: UInt64?
    public var load1: Double?
    public var uptime: TimeInterval?
    public var diskUsedPercent: Double?
    public var gpus: [GPU] = []

    /// Jiffies spent in all, and of them idle, since boot -- /proc/stat's
    /// first line. Two readings give the CPU use in between; one gives
    /// nothing, which is why the script does not sleep for a second one.
    public struct CPUCounters: Equatable, Sendable {
        public var total: UInt64
        public var idle: UInt64

        public init(total: UInt64, idle: UInt64) {
            self.total = total
            self.idle = idle
        }
    }

    public init() {}

    /// The share of the time between two readings that was not idle. Nil
    /// when no time passed, or the counters went backwards (a reboot).
    public static func cpuPercent(from previous: CPUCounters, to current: CPUCounters) -> Double? {
        guard current.total > previous.total, current.idle >= previous.idle else { return nil }
        let total = Double(current.total - previous.total)
        let idle = Double(current.idle - previous.idle)
        return max(0, total - idle) * 100 / total
    }

    /// Used memory as a share of the total, for a bar.
    public var memoryPercent: Double? {
        guard let memoryUsed, let memoryTotal, memoryTotal > 0 else { return nil }
        return Double(memoryUsed) * 100 / Double(memoryTotal)
    }

    /// Written for POSIX sh with everything optional. Linux reads /proc;
    /// macOS asks sysctl and vm_stat. Each command fails on its own and
    /// quietly, and the script as a whole never does. It does not sleep: a
    /// CPU figure needs two readings, and the second is the next probe's.
    /// macOS has no counters a shell can read -- top's one-shot figure is the
    /// average since boot -- so it gives no CPU at all.
    public static let script = """
        if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
            total=$(sysctl -n hw.memsize 2>/dev/null)
            [ -n "$total" ] && echo "mem_total=$total"
            vm_stat 2>/dev/null | awk -v total="$total" '
                /page size of/ {page=$8}
                /Pages active/ {active=$3}
                /Pages wired down/ {wired=$4}
                /occupied by compressor/ {comp=$5}
                END {if (page != "") printf "mem_used=%.0f\\n", (active+wired+comp)*page}'
            sysctl -n vm.loadavg 2>/dev/null | awk '{print "load1=" $2}'
            boot=$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/^{ sec = \\([0-9]*\\).*/\\1/p')
            [ -n "$boot" ] && echo "uptime=$(( $(date +%s) - boot ))"
        else
            # Idle is idle and iowait; total is every column through steal.
            awk '/^cpu / {print "cpu_total=" $2+$3+$4+$5+$6+$7+$8+$9; print "cpu_idle=" $5+$6}' \
                /proc/stat 2>/dev/null
            awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} \
                END {if (t > 0) printf "mem_total=%.0f\\nmem_used=%.0f\\n", t*1024, (t-a)*1024}' \
                /proc/meminfo 2>/dev/null
            awk '{print "load1=" $1}' /proc/loadavg 2>/dev/null
            awk '{print "uptime=" $1}' /proc/uptime 2>/dev/null
            if command -v nvidia-smi >/dev/null 2>&1; then
                nvidia-smi --query-gpu=name,utilization.gpu,memory.used,memory.total \
                    --format=csv,noheader,nounits 2>/dev/null | sed 's/, */|/g; s/^/gpu=/'
            fi
        fi
        df -Pk / 2>/dev/null | awk 'NR == 2 {sub("%", "", $5); print "disk=" $5}'
        exit 0
        """

    /// Reads the script's output, with the CPU use worked out against the
    /// previous probe's counters when there are any. A line it does not
    /// understand is skipped, and a value it cannot read is left absent.
    public static func parse(_ output: String, after previous: ServerLoad? = nil) -> ServerLoad {
        var load = ServerLoad()
        var total: UInt64?, idle: UInt64?
        for line in output.split(separator: "\n") {
            guard let split = line.firstIndex(of: "=") else { continue }
            let key = line[..<split]
            let value = line[line.index(after: split)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "cpu_total": total = UInt64(value)
            case "cpu_idle":  idle = UInt64(value)
            case "mem_total": load.memoryTotal = UInt64(value)
            case "mem_used":  load.memoryUsed = UInt64(value)
            case "load1":     load.load1 = Double(value)
            case "uptime":    load.uptime = Double(value)
            case "disk":      load.diskUsedPercent = Double(value)
            case "gpu":
                // name|util%|used MiB|total MiB, as nvidia-smi prints them.
                let fields = value.split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                guard let name = fields.first, !name.isEmpty else { continue }
                let mebibytes = { (field: Int) in
                    fields.count > field ? UInt64(fields[field]).map { $0 << 20 } : nil
                }
                load.gpus.append(GPU(name: name,
                                     utilizationPercent: fields.count > 1 ? Double(fields[1]) : nil,
                                     memoryUsed: mebibytes(2), memoryTotal: mebibytes(3)))
            default: continue
            }
        }
        if let total, let idle { load.cpuCounters = CPUCounters(total: total, idle: idle) }
        if let before = previous?.cpuCounters, let now = load.cpuCounters {
            load.cpuPercent = cpuPercent(from: before, to: now)
        }
        return load
    }

    // MARK: - for showing

    /// "18.0" for 18 GiB, one decimal, with no unit.
    public static func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / Double(1 << 30))
    }

    /// "3d 4h", "5h 12m" or "40m": the two largest units that are not zero.
    public static func uptime(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.days, .hours, .minutes], width: .narrow,
                                                   maximumUnitCount: 2).locale(Locale(identifier: "en_US")))
    }
}
