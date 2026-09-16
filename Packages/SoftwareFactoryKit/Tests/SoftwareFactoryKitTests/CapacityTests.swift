import Foundation
import Testing
@testable import SoftwareFactoryKit

@Suite struct CapacityTests {
    let gb: UInt64 = 1_073_741_824
    let t = Throttle()

    func reading(free: Double, swap: Double, pressure: MachineReading.Pressure = .normal,
                 load: Double = 1, compiles: Int = 0, simulators: Int = 0) -> MachineReading {
        MachineReading(memoryTotal: 32 * gb, memoryFree: UInt64(free * 32 * Double(gb)),
                       swapUsed: UInt64(swap * 4 * Double(gb)), swapTotal: 4 * gb, pressure: pressure,
                       load: load, cores: 10, compiles: compiles, simulators: simulators)
    }

    @Test func verdictsFollowPressureCompilesAndLoad() {
        #expect(Capacity.verdict(reading(free: 0.6, swap: 0.2), throttle: t) == .under)
        #expect(Capacity.verdict(reading(free: 0.6, swap: 0.2, pressure: .warning), throttle: t) == .tight)
        #expect(Capacity.verdict(reading(free: 0.6, swap: 0.2, pressure: .critical), throttle: t) == .over)
        #expect(Capacity.verdict(reading(free: 0.6, swap: 0.1, compiles: 5), throttle: t) == .tight)
        #expect(Capacity.verdict(reading(free: 0.6, swap: 0.1, load: 9.5), throttle: t) == .tight)
    }

    /// The case that started T430, as it was measured on Alex's Mac: swap nearly full by
    /// the old sum, the kernel saying pressure normal, and nothing swapping. The old rule
    /// said no to four builds in a row. macOS makes swapfiles on demand and sizes them to
    /// what is in use, so the fraction is high whatever is happening.
    @Test func aMacTheKernelCallsNormalMayBuildHoweverFullTheSwapfilesAre() {
        let swapping = reading(free: 0.19, swap: 0.78)
        #expect(Capacity.verdict(swapping, throttle: t) == .under)
        #expect(Capacity.ask(.compile, swapping, throttle: t) == .yes)
        #expect(Capacity.reason(swapping, throttle: t) == "Room to spare.")
    }

    @Test func askingToCompile() {
        #expect(Capacity.ask(.compile, reading(free: 0.6, swap: 0.2), throttle: t) == .yes)
        if case .wait(let why) = Capacity.ask(.compile, reading(free: 0.6, swap: 0.2, compiles: 5), throttle: t) {
            #expect(why.contains("5 of 5 compile slots"))
        } else { Issue.record("expected wait") }
        if case .no = Capacity.ask(.compile, reading(free: 0.6, swap: 0.9, pressure: .critical), throttle: t) {} else { Issue.record("expected no") }
        // A throttle with more slots lets more through.
        let wide = Throttle(compileSlots: 8)
        #expect(Capacity.ask(.compile, reading(free: 0.6, swap: 0.2, compiles: 5), throttle: wide) == .yes)
    }

    @Test func askingForASimulatorAndAModel() {
        #expect(Capacity.ask(.simulator, reading(free: 0.6, swap: 0.2, simulators: 3), throttle: t) == .yes)
        if case .wait = Capacity.ask(.simulator, reading(free: 0.6, swap: 0.2, simulators: 4), throttle: t) {} else { Issue.record("expected wait") }
        #expect(Capacity.ask(.model, reading(free: 0.7, swap: 0.05), throttle: t) == .yes)
        if case .wait = Capacity.ask(.model, reading(free: 0.7, swap: 0.05, compiles: 1), throttle: t) {} else { Issue.record("expected wait") }
        if case .no = Capacity.ask(.model, reading(free: 0.25, swap: 0.05, pressure: .warning), throttle: t) {} else { Issue.record("expected no") }
    }

    @Test func headroomSaysWhatCouldStart() {
        let h = Capacity.headroom(reading(free: 0.6, swap: 0.2, compiles: 2, simulators: 1), throttle: t)
        #expect(h.compiles == 3)
        #expect(h.simulators == 3)
        #expect(abs(Int64(h.swapFree) - Int64(0.8 * 4 * Double(gb))) <= 1)
        // Tight: no more compiles, simulators still allowed; over: nothing.
        #expect(Capacity.headroom(reading(free: 0.6, swap: 0.5, pressure: .warning, compiles: 2), throttle: t).compiles == 0)
        #expect(Capacity.headroom(reading(free: 0.6, swap: 0.5, pressure: .warning, compiles: 2), throttle: t).simulators == 4)
        let over = Capacity.headroom(reading(free: 0.1, swap: 0.9, pressure: .critical), throttle: t)
        #expect(over.compiles == 0 && over.simulators == 0)
    }

    @Test func reasonsNameTheCause() {
        #expect(Capacity.reason(reading(free: 0.6, swap: 0.2), throttle: t) == "Room to spare.")
        let why = Capacity.reason(reading(free: 0.2, swap: 0.6, pressure: .warning, compiles: 5), throttle: t)
        #expect(why.contains("memory pressure warning"))
        #expect(why.contains("5 of 5 compile slots"))
        // The two numbers that used to decide are not in the sentence any more, because
        // neither of them says what it was being read as saying. (T430.)
        #expect(!why.contains("swap"))
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
