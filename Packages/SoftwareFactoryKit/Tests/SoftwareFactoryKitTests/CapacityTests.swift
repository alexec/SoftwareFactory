import Foundation
import Testing
@testable import SoftwareFactoryKit

@Suite struct CapacityTests {
    let gb: UInt64 = 1_073_741_824
    let t = Throttle()

    func reading(free: Double, swap: Double, load: Double = 1, compiles: Int = 0, simulators: Int = 0) -> MachineReading {
        MachineReading(memoryTotal: 32 * gb, memoryFree: UInt64(free * 32 * Double(gb)), swapUsed: UInt64(swap * 4 * Double(gb)), swapTotal: 4 * gb,
                       load: load, cores: 10, compiles: compiles, simulators: simulators)
    }

    @Test func verdictsFollowSwapMemoryCompilesAndLoad() {
        #expect(Capacity.verdict(reading(free: 0.6, swap: 0.2), throttle: t) == .under)
        #expect(Capacity.verdict(reading(free: 0.6, swap: 0.5), throttle: t) == .tight)
        #expect(Capacity.verdict(reading(free: 0.6, swap: 0.8), throttle: t) == .over)
        #expect(Capacity.verdict(reading(free: 0.25, swap: 0.1), throttle: t) == .tight)
        #expect(Capacity.verdict(reading(free: 0.1, swap: 0.1), throttle: t) == .over)
        #expect(Capacity.verdict(reading(free: 0.6, swap: 0.1, compiles: 5), throttle: t) == .tight)
        #expect(Capacity.verdict(reading(free: 0.6, swap: 0.1, load: 9.5), throttle: t) == .tight)
    }

    @Test func askingToCompile() {
        #expect(Capacity.ask(.compile, reading(free: 0.6, swap: 0.2), throttle: t) == .yes)
        if case .wait(let why) = Capacity.ask(.compile, reading(free: 0.6, swap: 0.2, compiles: 5), throttle: t) {
            #expect(why.contains("5 of 5 compile slots"))
        } else { Issue.record("expected wait") }
        if case .no = Capacity.ask(.compile, reading(free: 0.6, swap: 0.9), throttle: t) {} else { Issue.record("expected no") }
        // A throttle with more slots lets more through.
        let wide = Throttle(compileSlots: 8)
        #expect(Capacity.ask(.compile, reading(free: 0.6, swap: 0.2, compiles: 5), throttle: wide) == .yes)
    }

    @Test func askingForASimulatorAndAModel() {
        #expect(Capacity.ask(.simulator, reading(free: 0.6, swap: 0.2, simulators: 3), throttle: t) == .yes)
        if case .wait = Capacity.ask(.simulator, reading(free: 0.6, swap: 0.2, simulators: 4), throttle: t) {} else { Issue.record("expected wait") }
        #expect(Capacity.ask(.model, reading(free: 0.7, swap: 0.05), throttle: t) == .yes)
        if case .wait = Capacity.ask(.model, reading(free: 0.7, swap: 0.05, compiles: 1), throttle: t) {} else { Issue.record("expected wait") }
        if case .no = Capacity.ask(.model, reading(free: 0.25, swap: 0.05), throttle: t) {} else { Issue.record("expected no") }
    }

    @Test func headroomSaysWhatCouldStart() {
        let h = Capacity.headroom(reading(free: 0.6, swap: 0.2, compiles: 2, simulators: 1), throttle: t)
        #expect(h.compiles == 3)
        #expect(h.simulators == 3)
        #expect(abs(Int64(h.swapFree) - Int64(0.8 * 4 * Double(gb))) <= 1)
        // Tight: no more compiles, simulators still allowed; over: nothing.
        #expect(Capacity.headroom(reading(free: 0.6, swap: 0.5, compiles: 2), throttle: t).compiles == 0)
        #expect(Capacity.headroom(reading(free: 0.6, swap: 0.5, compiles: 2), throttle: t).simulators == 4)
        let over = Capacity.headroom(reading(free: 0.1, swap: 0.9), throttle: t)
        #expect(over.compiles == 0 && over.simulators == 0)
    }

    @Test func reasonsNameTheCause() {
        #expect(Capacity.reason(reading(free: 0.6, swap: 0.2), throttle: t) == "Room to spare.")
        let why = Capacity.reason(reading(free: 0.2, swap: 0.6, compiles: 5), throttle: t)
        #expect(why.contains("swap 60% of 4.0 GB"))
        #expect(why.contains("20% memory free"))
        #expect(why.contains("5 of 5 compile slots"))
    }

    #if os(macOS)
    @Test func theMacCanBeRead() {
        let r = MachineReading.sample()
        #expect(r.memoryTotal > 0)
        #expect(r.memoryFree <= r.memoryTotal)
        #expect(r.cores > 0)
        #expect(!MachineReading.processNames().isEmpty)
    }
    #endif
}
