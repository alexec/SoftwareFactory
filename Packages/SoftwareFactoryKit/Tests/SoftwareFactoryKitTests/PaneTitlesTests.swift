import Testing
@testable import SoftwareFactoryKit

@Suite struct PaneTitlesTests {
    @Test func aSessionAndItsTitleComeBackTogether() {
        let lines = PaneTitles.parse("44F4E77B\t✳ Software Factory backlog\n")
        #expect(lines == [PaneTitles.Line(session: "44F4E77B", title: "✳ Software Factory backlog")])
    }

    @Test func aSessionThatHasSetNoTitleHasNone() {
        let lines = PaneTitles.parse("one\t\ntwo\t   \nthree")
        #expect(lines.map(\.session) == ["one", "two", "three"])
        #expect(lines.allSatisfy { $0.title == nil })
    }

    @Test func aTitleKeepsEveryTabAfterTheFirst() {
        let lines = PaneTitles.parse("one\tmake\tthe thing")
        #expect(lines.first?.title == "make\tthe thing")
    }

    @Test func blankRowsAreNotSessions() {
        #expect(PaneTitles.parse("\n\n").isEmpty)
    }
}
