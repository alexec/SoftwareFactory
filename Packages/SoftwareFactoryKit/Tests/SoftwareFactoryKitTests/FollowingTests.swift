import Foundation
import Testing
@testable import SoftwareFactoryKit

/// A chat follows the newest thing while you are watching it and leaves you alone while you
/// are reading further up. Every one of these is a case that was wrong on screen at some
/// point today. (Alex, 16 Sep 2026.)
@Suite struct FollowingTests {
    /// A window 800 tall with 2,000 of conversation in it, scrolled to the end.
    private let atTheEnd = Following.Where(offset: 1_200, container: 800, content: 2_000)

    /// The bug, and the reason this type exists. An agent saying something makes the content
    /// taller without moving the offset, so the end goes off screen. Believing that would
    /// turn following off at the exact moment there is something to follow, and it would
    /// never come back on, because nothing afterwards moves the offset either.
    @Test func anAgentTalkingDoesNotCountAsScrollingAway() {
        var following = Following()
        let taller = Following.Where(offset: 1_200, container: 800, content: 2_400)
        #expect(!taller.isAtEnd, "the end really is off screen: that is what made this hard")
        following.moved(from: atTheEnd, to: taller)
        #expect(following.isOn, "content arriving says nothing about what the person wants")
    }

    @Test func scrollingUpStopsItFollowing() {
        var following = Following()
        let up = Following.Where(offset: 400, container: 800, content: 2_000)
        following.moved(from: atTheEnd, to: up)
        #expect(!following.isOn)
    }

    @Test func scrollingBackToTheEndStartsItAgain() {
        var following = Following(isOn: false)
        let up = Following.Where(offset: 400, container: 800, content: 2_000)
        following.moved(from: up, to: atTheEnd)
        #expect(following.isOn)
    }

    /// Our own scroll to the end is a move with the height unchanged, so it turns following
    /// back on by the same rule rather than needing a special case.
    @Test func ourOwnScrollToTheEndCountsAsBeingThere() {
        var following = Following(isOn: false)
        let up = Following.Where(offset: 400, container: 800, content: 2_000)
        following.moved(from: up, to: atTheEnd)
        #expect(following.isOn)
    }

    /// A page that has just animated to the end often stops a pixel short.
    @Test func aPixelShortOfTheEndIsTheEnd() {
        var following = Following(isOn: false)
        let nearly = Following.Where(offset: 1_190, container: 800, content: 2_000)
        following.moved(from: atTheEnd, to: nearly)
        #expect(following.isOn)
        // Far enough up and it is not.
        following.moved(from: nearly, to: Following.Where(offset: 1_100, container: 800, content: 2_000))
        #expect(!following.isOn)
    }

    /// Shrinking is a content change too: rows collapse when a run of tool calls folds into
    /// its latest. It says as little about what the person wants as growing does.
    @Test func contentGettingShorterDoesNotCountEither() {
        var following = Following(isOn: false)
        let shorter = Following.Where(offset: 1_200, container: 800, content: 1_500)
        #expect(shorter.isAtEnd, "the end is on screen now, which is the trap in reverse")
        following.moved(from: atTheEnd, to: shorter)
        #expect(!following.isOn, "it was scrolled away from, and rows collapsing did not change that")
    }

    /// A conversation shorter than the window sits at zero for ever and reads as both ends at
    /// once. The page must not take that as being at the top and ask for more of the log.
    @Test func aPageWithNothingToScrollIsNotAtTheTop() {
        let short = Following.Where(offset: 0, container: 800, content: 300)
        #expect(!short.scrolls)
        #expect(short.isAtEnd, "it is at the end, because the end is all there is")
    }

    @Test func sayingSomethingTakesYouToTheEndWhereverYouWere() {
        var following = Following(isOn: false)
        following.said()
        #expect(following.isOn)
    }
}
