import Foundation

/// What the factory is under right now: the Mac's memory, swap, load, and how many
/// heavy things are running. A reading, not a record; it is taken when asked.
public struct MachineReading: Codable, Sendable, Equatable {
    /// Bytes of physical memory in the machine.
    public var memoryTotal: UInt64
    /// Bytes not in use, counting inactive pages the kernel would give back.
    public var memoryFree: UInt64
    public var swapUsed: UInt64
    public var swapTotal: UInt64
    /// The one-minute load average.
    public var load: Double
    public var cores: Int
    /// Swift and C compiler front ends running.
    public var compiles: Int
    /// Booted simulators.
    public var simulators: Int
    public var taken: Date

    public init(memoryTotal: UInt64, memoryFree: UInt64, swapUsed: UInt64, swapTotal: UInt64,
                load: Double, cores: Int, compiles: Int, simulators: Int, taken: Date = .now) {
        self.memoryTotal = memoryTotal
        self.memoryFree = memoryFree
        self.swapUsed = swapUsed
        self.swapTotal = swapTotal
        self.load = load
        self.cores = cores
        self.compiles = compiles
        self.simulators = simulators
        self.taken = taken
    }

    public var memoryFreeFraction: Double { memoryTotal == 0 ? 0 : Double(memoryFree) / Double(memoryTotal) }
    public var swapFraction: Double { swapTotal == 0 ? 0 : Double(swapUsed) / Double(swapTotal) }
    public var loadPerCore: Double { cores == 0 ? 0 : load / Double(cores) }
}

/// The limits the person sets. Only the app writes this; agents read it.
public struct Throttle: Codable, Sendable, Equatable {
    public var compileSlots: Int
    public var simulatorSlots: Int
    /// How many agents may be on the floor at once. Slots, like any other resource the
    /// factory hands out, and the person sets how many there are. (T209.)
    public var agentSlots: Int
    /// Swap use above this fraction and nothing new starts.
    public var swapCeiling: Double
    /// Memory free below this fraction and nothing new starts.
    public var memoryFloor: Double
    /// How much an agent may do without asking. (T373.)
    public var permissions: Permissions

    public init(compileSlots: Int = 5, simulatorSlots: Int = 4, agentSlots: Int = 8,
                swapCeiling: Double = 0.75, memoryFloor: Double = 0.15,
                permissions: Permissions = .allowEverything) {
        self.compileSlots = compileSlots
        self.simulatorSlots = simulatorSlots
        self.agentSlots = agentSlots
        self.swapCeiling = swapCeiling
        self.memoryFloor = memoryFloor
        self.permissions = permissions
    }

    /// A throttle written before a limit existed keeps everything else it said, and takes
    /// the default for what it does not mention.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Throttle()
        compileSlots = try c.decodeIfPresent(Int.self, forKey: .compileSlots) ?? fallback.compileSlots
        simulatorSlots = try c.decodeIfPresent(Int.self, forKey: .simulatorSlots) ?? fallback.simulatorSlots
        agentSlots = try c.decodeIfPresent(Int.self, forKey: .agentSlots) ?? fallback.agentSlots
        swapCeiling = try c.decodeIfPresent(Double.self, forKey: .swapCeiling) ?? fallback.swapCeiling
        memoryFloor = try c.decodeIfPresent(Double.self, forKey: .memoryFloor) ?? fallback.memoryFloor
        permissions = try c.decodeIfPresent(Permissions.self, forKey: .permissions) ?? fallback.permissions
    }

    /// What an agent may do without stopping to ask.
    ///
    /// Under ACP the agent asks its client before it acts, and the client is this factory.
    /// Before ACP every agent was launched with its own auto-approve flag, because there
    /// was nobody on the other end to ask; the flags are gone and this is what replaced
    /// them, so the default is the behaviour that was already there. Nothing gets slower
    /// on the day this lands. (T373.)
    public enum Permissions: String, Codable, Sendable, Equatable, CaseIterable, Identifiable {
        /// Say yes to everything, at once, and raise no question. What every agent was
        /// launched with before ACP.
        case allowEverything
        /// Reading and searching go through; editing, deleting, moving and running ask.
        case askAboutChanges
        /// Ask about all of it.
        case askAboutEverything

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .allowEverything: "Let them get on with it"
            case .askAboutChanges: "Ask before changing anything"
            case .askAboutEverything: "Ask about everything"
            }
        }

        public var detail: String {
            switch self {
            case .allowEverything:
                "Agents do what they need to and never stop to ask. This is how the factory worked before it spoke ACP."
            case .askAboutChanges:
                "Reading and searching go through. Editing a file, deleting one, or running a command becomes a question on the floor."
            case .askAboutEverything:
                "Every tool an agent reaches for becomes a question. Thorough, and a lot of questions."
            }
        }

        /// Whether this call may go through without asking. An agent that does not say
        /// what kind of thing it is running is treated as though it changes something,
        /// which is Grok, whose tool calls carry a name and no kind.
        public func allows(_ kind: ACP.ToolCall.Kind?) -> Bool {
            switch self {
            case .allowEverything: true
            case .askAboutEverything: false
            case .askAboutChanges: !(kind ?? .other).changesAnything
            }
        }
    }

    public static let `default` = Throttle()
}

/// The rules. The same three words machine.sh uses, and the same reasons.
public enum Capacity {
    public enum Verdict: String, Codable, Sendable {
        /// Start what you like.
        case under
        /// Nothing new that is heavy; finish what is running.
        case tight
        /// Pause something before anything else.
        case over
    }

    public enum Work: String, Codable, Sendable, CaseIterable {
        case compile, simulator, model
    }

    public enum Answer: Equatable, Sendable {
        case yes
        case wait(String)
        case no(String)

        public var text: String {
            switch self {
            case .yes: "Yes."
            case .wait(let why): "Wait: \(why)"
            case .no(let why): "No: \(why)"
            }
        }
    }

    public static func verdict(_ r: MachineReading, throttle t: Throttle) -> Verdict {
        if r.swapFraction >= t.swapCeiling || r.memoryFreeFraction <= t.memoryFloor { return .over }
        if r.swapFraction >= t.swapCeiling * 0.66 || r.memoryFreeFraction <= t.memoryFloor * 2
            || r.compiles >= t.compileSlots || r.loadPerCore >= 0.9 { return .tight }
        return .under
    }

    /// One line on why the verdict is what it is.
    public static func reason(_ r: MachineReading, throttle t: Throttle) -> String {
        var parts: [String] = []
        if r.swapFraction >= t.swapCeiling * 0.66 { parts.append("swap \(Self.percent(r.swapFraction)) of \(Self.gigabytes(r.swapTotal))") }
        if r.memoryFreeFraction <= t.memoryFloor * 2 { parts.append("\(Self.percent(r.memoryFreeFraction)) memory free") }
        if r.compiles >= t.compileSlots { parts.append("\(r.compiles) of \(t.compileSlots) compile slots in use") }
        if r.loadPerCore >= 0.9 { parts.append("load \(String(format: "%.1f", r.load)) on \(r.cores) cores") }
        return parts.isEmpty ? "Room to spare." : parts.joined(separator: "; ") + "."
    }

    /// "Can I start a compiler?" and its kin.
    public static func ask(_ work: Work, _ r: MachineReading, throttle t: Throttle) -> Answer {
        let v = verdict(r, throttle: t)
        switch work {
        case .compile:
            if v == .over { return .no(reason(r, throttle: t)) }
            if r.compiles >= t.compileSlots { return .wait("\(r.compiles) of \(t.compileSlots) compile slots in use.") }
            if v == .tight { return .wait(reason(r, throttle: t)) }
            return .yes
        case .simulator:
            if v == .over { return .no(reason(r, throttle: t)) }
            if r.simulators >= t.simulatorSlots { return .wait("\(r.simulators) of \(t.simulatorSlots) simulators booted.") }
            return .yes
        case .model:
            // A model is the whole machine: only with nothing else heavy running.
            if v != .under { return .no(reason(r, throttle: t)) }
            if r.compiles > 0 || r.simulators > 0 { return .wait("\(r.compiles) compiles and \(r.simulators) simulators running; a model needs the Mac to itself.") }
            return .yes
        }
    }

    /// What is left: how many more of each kind of work could start now, by the verdict
    /// and the throttle. This is what the Factory screen leads with; the throttle is how
    /// the person changes it.
    public struct Headroom: Equatable, Sendable {
        public var compiles: Int
        public var simulators: Int
        public var memoryFree: UInt64
        public var swapFree: UInt64
    }

    public static func headroom(_ r: MachineReading, throttle t: Throttle) -> Headroom {
        let v = verdict(r, throttle: t)
        let compiles = v == .under ? max(0, t.compileSlots - r.compiles) : 0
        let simulators = v == .over ? 0 : max(0, t.simulatorSlots - r.simulators)
        return Headroom(compiles: compiles, simulators: simulators, memoryFree: r.memoryFree,
                        swapFree: r.swapTotal > r.swapUsed ? r.swapTotal - r.swapUsed : 0)
    }

    static func percent(_ f: Double) -> String { "\(Int((f * 100).rounded()))%" }
    static func gigabytes(_ bytes: UInt64) -> String { String(format: "%.1f GB", Double(bytes) / 1_073_741_824) }
}

#if os(macOS)
import Darwin

extension MachineReading {
    /// Reads the Mac. Every call is a fresh look; none of it needs privileges, and all of
    /// it works inside the sandbox.
    public static func sample(now: Date = .now) -> MachineReading {
        var memoryTotal: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &memoryTotal, &size, nil, 0)

        var free: UInt64 = 0
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let rc = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if rc == KERN_SUCCESS {
            var pageSize: vm_size_t = 0
            host_page_size(mach_host_self(), &pageSize)
            let page = UInt64(pageSize)
            free = (UInt64(stats.free_count) + UInt64(stats.inactive_count) + UInt64(stats.purgeable_count)) * page
        }

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)

        var cores: Int32 = 0
        var coresSize = MemoryLayout<Int32>.size
        sysctlbyname("hw.logicalcpu", &cores, &coresSize, nil, 0)

        let names = processNames()
        let compiles = names.filter { $0 == "swift-frontend" || $0 == "clang" || $0 == "swiftc" }.count
        let simulators = names.filter { $0 == "launchd_sim" }.count

        return MachineReading(memoryTotal: memoryTotal, memoryFree: min(free, memoryTotal),
                              swapUsed: swap.xsu_used, swapTotal: swap.xsu_total,
                              load: loads[0], cores: Int(cores), compiles: compiles, simulators: simulators, taken: now)
    }

    /// The short names of every visible process. `p_comm` is sixteen characters, which
    /// is enough for the ones counted above.
    static func processNames() -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return [] }
        let count = length / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, UInt32(mib.count), &procs, &length, nil, 0) == 0 else { return [] }
        let got = length / MemoryLayout<kinfo_proc>.stride
        return procs.prefix(got).map { p in
            withUnsafePointer(to: p.kp_proc.p_comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: 17) { String(cString: $0) }
            }
        }
    }
}
#endif
