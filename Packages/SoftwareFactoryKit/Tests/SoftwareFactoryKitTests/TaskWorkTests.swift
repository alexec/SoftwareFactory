import Foundation
import Testing
@testable import SoftwareFactoryKit

@Suite struct TaskWorkTests {
    @Test func aRecordWithoutWorkReadsAsImplement() throws {
        let json = """
        {"version":2,"id":"\(UUID().uuidString)","projectID":"/p","title":"old","state":"backlog","rank":0,"note":"",
         "created":"2026-09-12T10:00:00Z","updated":"2026-09-12T10:00:00Z"}
        """
        let t = try FileStore.decoder.decode(FactoryTask.self, from: Data(json.utf8))
        #expect(t.work == .implement)
    }

    @Test func designRoundTripsAndTheOldKindIsIgnored() throws {
        var task = FactoryTask(projectID: "/p", title: "The add row", rank: 0, work: .design)
        task.number = 166
        let again = try FileStore.decoder.decode(FactoryTask.self, from: FileStore.encoder.encode(task))
        #expect(again.work == .design)
        #expect(again.work.word == "Design")
        #expect(again.work.brief.contains("Don't implement."))
        #expect(again.work.instruction.contains("Don't implement."))
        #expect(FactoryTask.Work.implement.word == "Code")
        #expect(FactoryTask.Work.implement.instruction == "Do it, and say when it is done.")
    }

    @Test func namedReadsTheWordAtTheStartOfATitle() {
        #expect(FactoryTask.Work.named("Code") == .implement)
        #expect(FactoryTask.Work.named("code") == .implement)
        #expect(FactoryTask.Work.named("Implement") == .implement)
        #expect(FactoryTask.Work.named("Design") == .design)
        #expect(FactoryTask.Work.named("investigate") == .investigate)
        #expect(FactoryTask.Work.named("Coding") == nil)
        #expect(FactoryTask.Work.parse("code") == .implement)
        #expect(FactoryTask.Work.parse("implement") == .implement)
        #expect(FactoryTask.Work.parse("design") == .design)
    }

    @Test func readingTakesWorkFromTheFirstWordAndKeepsTheTitle() {
        let coded = FactoryTask.Work.reading(title: "Code the add row")
        #expect(coded.work == .implement)
        #expect(coded.title == "Code the add row")
        let designed = FactoryTask.Work.reading(title: "  design a sheet")
        #expect(designed.work == .design)
        #expect(designed.title == "design a sheet")
        let plain = FactoryTask.Work.reading(title: "Move the add row")
        #expect(plain.work == .implement)
        #expect(plain.title == "Move the add row")
        #expect(FactoryTask.Work.implement.isPrefix(of: "Code the add row"))
        #expect(!FactoryTask.Work.design.isPrefix(of: "Code the add row"))
        #expect(!FactoryTask.Work.design.isPrefix(of: "the sheet"))
    }

    @Test func completionsMatchAPrefixAndStayQuietWhenEmptyOrExact() {
        #expect(FactoryTask.Work.completions(prefix: "").isEmpty)
        #expect(FactoryTask.Work.completions(prefix: "D") == [.design])
        #expect(FactoryTask.Work.completions(prefix: "c") == [.implement])
        #expect(FactoryTask.Work.completions(prefix: "Code").isEmpty)
        #expect(FactoryTask.Work.completions(prefix: "in") == [.investigate])
    }
}
