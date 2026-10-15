import Foundation
import Testing
import BezelightAgents
@testable import BezelightCore

private func settings(_ edit: (inout AgentAlertSettings) -> Void) -> AgentAlertSettings {
    var s = AgentAlertSettings(); edit(&s); return s
}

// MARK: priority and several sessions

@Test func needsInputBeatsDoneAndErrorBeatsDone() {
    var rig = Rig()
    rig.send(.done, session: "a")
    #expect(rig.display?.kind == .done)
    rig.advance(1); rig.send(.error, session: "b")
    #expect(rig.display?.kind == .error)
    rig.advance(1); rig.send(.ask, session: "c")
    #expect(rig.display?.kind == .needsInput && rig.display?.waitingCount == 1)
    rig.advance(1); rig.send(.answered, session: "c", req: "x", src: "transcript")
    #expect(rig.display?.kind == .error)          // the next most important thing shows again
}

@Test func severalWaitingSessionsAreCounted() {
    var rig = Rig()
    for id in ["a", "b", "c"] { rig.send(.ask, session: id); rig.advance(0.1) }
    #expect(rig.display?.waitingCount == 3 && rig.display?.sessionCount == 3)
    rig.send(.interrupt, session: "b")
    #expect(rig.display?.waitingCount == 2)
}

@Test func newArrivalRestartsTheOpening() {
    var rig = Rig()
    rig.send(.ask, session: "a")
    let first = rig.display?.since
    rig.advance(5); rig.send(.ask, session: "b")
    #expect(rig.display?.since == rig.now && rig.display?.since != first)
}

@Test func differentAgentsDoNotCollide() {
    var rig = Rig()
    rig.send(.ask, .claude, session: "same")
    rig.send(.done, .codex, session: "same")
    #expect(rig.tracker.sessions.count == 2)
    #expect(rig.state("same", .claude) == .needsInput && rig.state("same", .codex) == .done)
}

// MARK: ordering

@Test func olderEventsAreDropped() {
    var rig = Rig()
    let t = rig.ms
    rig.send(.done, ts: t + 100)
    rig.send(.working, ts: t + 50)                // started earlier, arrived later
    #expect(rig.state() == .done)
}

@Test func atEqualTimeAnEndingBeatsWorking() {
    var rig = Rig()
    let t = rig.ms
    rig.send(.done, ts: t)
    rig.send(.working, ts: t)
    #expect(rig.state() == .done)
    rig.send(.working, ts: t + 1)
    #expect(rig.state() == .working)
}

@Test func unknownSessionsOnlyStartFromRealActivity() {
    var rig = Rig()
    for kind in [EventKind.answered, .seen, .substop, .interrupt, .end] { rig.send(kind, session: "ghost") }
    #expect(rig.tracker.isEmpty)
    rig.send(.done, session: "late")              // the app started mid-session: a finish still counts
    #expect(rig.state("late") == .done)
}

// MARK: acknowledgement and persistence

@Test func doneStaysUntilTheUserIsBack() {
    var rig = Rig()
    rig.send(.done)
    rig.advance(600); rig.tick()
    #expect(rig.display?.kind == .done)           // minutes later, nobody has looked
    rig.input(); rig.advance(1); rig.tick()
    #expect(rig.display == nil)
}

@Test func errorStaysUntilTheUserIsBack() {
    var rig = Rig()
    rig.send(.error)
    rig.advance(60); rig.tick()
    #expect(rig.display?.kind == .error)
    rig.input(); rig.advance(1); rig.tick()
    #expect(rig.display == nil)
}

@Test func withoutPresenceDetectionOnlyDismissClears() {
    var rig = Rig(settings: settings { $0.presence.enabled = false })
    rig.send(.done)
    rig.input(); rig.advance(5); rig.tick()
    #expect(rig.display?.kind == .done)
    rig.tracker.dismissAll(now: rig.now)
    #expect(rig.display == nil)
}

@Test func dismissHidesUntilSomethingNewHappens() {
    var rig = Rig()
    rig.send(.ask, session: "a"); rig.send(.done, session: "b")
    rig.advance(1); rig.tracker.dismissAll(now: rig.now)
    #expect(rig.display == nil)
    rig.tick()
    #expect(rig.display == nil)
    rig.advance(1); rig.send(.ask, session: "a", req: "again")
    #expect(rig.display?.kind == .needsInput)
}

@Test func timedPersistenceExpires() {
    var rig = Rig(settings: settings { $0.done.persistence = .timed; $0.done.timeoutSec = 10 })
    rig.send(.done)
    rig.advance(9); #expect(rig.display?.kind == .done)
    rig.advance(2); #expect(rig.display == nil)
}

@Test func oncePersistenceLastsOnlyTheOpening() {
    var rig = Rig(settings: settings { $0.done.persistence = .once })
    rig.send(.done)
    #expect(rig.display?.kind == .done)
    rig.advance(settings { _ in }.done.flourish.duration + 0.1)
    #expect(rig.display == nil)
}

@Test func untilDismissedIgnoresInput() {
    var rig = Rig(settings: settings { $0.done.persistence = .untilDismissed })
    rig.send(.done)
    rig.input(); rig.advance(30); rig.tick()
    #expect(rig.display?.kind == .done)
}

@Test func needsInputCanOptIntoEndingWhenTheUserReturns() {
    var rig = Rig(settings: settings { $0.needsInput.persistence = .untilReturn })
    rig.send(.ask)
    rig.advance(30); rig.tick()
    #expect(rig.display?.kind == .needsInput)
    rig.input(); rig.advance(1); rig.tick()
    #expect(rig.display == nil)
    #expect(rig.state() == .needsInput)           // still waiting, just no longer shouting
}

@Test func disabledAlertsAreHiddenButTracked() {
    var rig = Rig(settings: settings { $0.done.enabled = false })
    rig.send(.done)
    #expect(rig.display == nil && rig.state() == .done)
}

@Test func perAgentSwitchesApplyToTheAlert() {
    var rig = Rig(settings: settings { $0.done.perAgent = ["codex": false] })
    rig.send(.done, .codex); #expect(rig.display == nil)
    rig.send(.done, .claude, session: "other"); #expect(rig.display?.kind == .done)
}

@Test func disabledAgentsAreIgnoredAndForgotten() {
    var rig = Rig(settings: settings { $0.agents["codex"] = false })
    rig.send(.ask, .codex)
    #expect(rig.tracker.isEmpty)
    var s = AgentAlertSettings()
    rig.send(.ask, .claude); #expect(!rig.tracker.isEmpty)
    s.agents["claude"] = false
    rig.tracker.updateSettings(s)
    #expect(rig.tracker.isEmpty)
    var off = AgentAlertSettings(); off.enabled = false
    var rig2 = Rig(settings: off); rig2.send(.ask)
    #expect(rig2.tracker.isEmpty)
}

@Test func workingIsOffByDefaultAndShowsWhenEnabled() {
    var rig = Rig()
    rig.send(.working); #expect(rig.display == nil)
    var s = AgentAlertSettings(); s.working.enabled = true
    rig.tracker.updateSettings(s)
    #expect(rig.display?.kind == .working)
}

// MARK: several requests, questions

@Test func everyOpenCodeRequestMustBeAnswered() {
    var rig = Rig()
    rig.send(.ask, .opencode, req: "r1"); rig.send(.ask, .opencode, req: "r2")
    rig.send(.answered, .opencode, req: "r1")
    #expect(rig.state(("s1"), .opencode) == .needsInput)
    rig.send(.answered, .opencode, req: "r2")
    #expect(rig.state(("s1"), .opencode) == .working)
    rig.send(.answered, .opencode, req: "never-asked")      // from before the app connected
    #expect(rig.state(("s1"), .opencode) == .working)
}

@Test func mainActivityDoesNotAnswerASubagentAndViceVersa() {
    var rig = Rig()
    rig.send(.substart, sub: "A")
    rig.send(.ask, sub: "A")
    rig.send(.working)                                      // main agent keeps working
    #expect(rig.state() == .needsInput)
    rig.send(.working, sub: "A")                            // the subagent itself moved on
    #expect(rig.state() == .working)

    rig.send(.ask)                                          // the main agent asks
    rig.send(.working, sub: "A")                            // a subagent tool finishing is not an answer
    #expect(rig.state() == .needsInput)
    rig.send(.working)
    #expect(rig.state() == .working)
}

@Test func mainStopKeepsASubagentsQuestion() {
    var rig = Rig()
    rig.send(.substart, sub: "A")
    rig.send(.done)                                         // held: a subagent is still running
    #expect(rig.state() == .working)
    rig.send(.ask, sub: "A")
    #expect(rig.state() == .needsInput)
    rig.send(.substop, sub: "A")                            // it ended: the held finish completes
    #expect(rig.state() == .done)
}

@Test func heldDoneFinishesWhenTheLastQuestionIsAnswered() {
    var rig = Rig()
    rig.send(.substart, sub: "A")
    rig.send(.ask, sub: "A"); rig.send(.done)
    #expect(rig.state() == .needsInput)
    rig.send(.answered, .claude, sub: "A")
    rig.send(.substop, sub: "A")
    #expect(rig.state() == .done)
}

@Test func heldDoneGivesUpAfterTheHoldTime() {
    var rig = Rig(settings: settings { $0.subagentHoldSec = 60 })
    rig.send(.substart, sub: "A"); rig.send(.done)
    rig.advance(59); rig.tick(); #expect(rig.state() == .working)
    rig.advance(2); rig.tick(); #expect(rig.state() == .done)
}

@Test func errorWinsOverRunningSubagents() {
    var rig = Rig()
    rig.send(.substart, sub: "A"); rig.send(.error)
    #expect(rig.state() == .error)
    rig.send(.working, sub: "A")                            // a stray subagent event does not revive it
    #expect(rig.state() == .error)
}

// MARK: Claude refusals (no hook) and the transcript

@Test func transcriptAnswerIsUnconfirmedThenExpires() {
    var rig = Rig(settings: settings { $0.confirmSec = 45 })
    rig.send(.ask, tp: "/t.jsonl")
    rig.advance(4); rig.send(.answered, src: "transcript")
    #expect(rig.state() == .working && rig.tracker.session(.init(agent: .claude, session: "s1"))?.unconfirmed == true)
    rig.advance(40); rig.tick(); #expect(rig.state() == .working)
    rig.advance(6); rig.tick(); #expect(rig.state() == .idle)
}

@Test func aHookConfirmsATranscriptGuess() {
    var rig = Rig()
    rig.send(.ask, tp: "/t.jsonl")
    rig.advance(2); rig.send(.answered, src: "transcript")
    rig.advance(1); rig.send(.working)                      // PostToolUse: it was an approval after all
    rig.advance(120); rig.send(.working)
    rig.tick()
    #expect(rig.state() == .working && rig.tracker.session(.init(agent: .claude, session: "s1"))?.unconfirmed == false)
}

@Test func watchersFollowTheQuestion() {
    var rig = Rig()
    #expect(rig.send(.ask, tp: "/t.jsonl") == [.watchTranscript(.init(agent: .claude, session: "s1"), path: "/t.jsonl")])
    #expect(rig.send(.ask, req: "second", tp: "/t.jsonl").isEmpty)                  // already watching
    rig.advance(1)
    #expect(rig.send(.answered, src: "transcript") == [.unwatchTranscript(.init(agent: .claude, session: "s1"))])
    #expect(rig.send(.ask, .codex, session: "x").isEmpty)                            // only Claude needs it
    #expect(rig.send(.ask, .claude, session: "y").isEmpty)                           // no path to watch
}

@Test func endingASessionStopsWatchingAndForgetsIt() {
    var rig = Rig()
    rig.send(.ask, tp: "/t.jsonl")
    let key = SessionKey(agent: .claude, session: "s1")
    #expect(rig.send(.end) == [.unwatchTranscript(key), .sessionRemoved(key)])
    #expect(rig.tracker.isEmpty)
}

// MARK: seen / reset / expiry

@Test func openCodeSeenAcknowledgesOnlyWhenAllowed() {
    var rig = Rig()
    rig.send(.done, .opencode); rig.advance(1); rig.send(.seen, .opencode)
    #expect(rig.display == nil)
    var rig2 = Rig(settings: settings { $0.presence.useAgentSeen = false })
    rig2.send(.done, .opencode); rig2.advance(1); rig2.send(.seen, .opencode)
    #expect(rig2.display?.kind == .done)
}

@Test func newPromptClearsAnUnseenFinish() {
    var rig = Rig()
    rig.send(.done); rig.advance(5)
    rig.send(.working)
    #expect(rig.display == nil && rig.state() == .working)
    rig.advance(5); rig.send(.done)
    #expect(rig.display?.kind == .done)
}

@Test func sessionStartAndInterruptResetEverything() {
    var rig = Rig()
    rig.send(.ask); rig.advance(1); rig.send(.start)
    #expect(rig.state() == .idle && rig.display == nil)
    rig.advance(1); rig.send(.ask, session: "x"); rig.advance(1); rig.send(.interrupt, session: "x")
    #expect(rig.state("x") == .idle && rig.display == nil)
}

@Test func staleSessionsAreReleased() {
    var rig = Rig(settings: settings { $0.stale.workingSec = 120; $0.stale.needsInputSec = 300 })
    rig.send(.working, session: "w"); rig.send(.ask, session: "q")
    rig.advance(119); rig.tick(); #expect(rig.state("w") == .working && rig.state("q") == .needsInput)
    rig.advance(2); rig.tick(); #expect(rig.state("w") == .idle && rig.state("q") == .needsInput)
    rig.advance(200); rig.tick(); #expect(rig.state("q") == .idle && rig.display == nil)
}

@Test func deadProcessesAreRemoved() {
    var rig = Rig()
    rig.send(.ask, pid: 111); rig.send(.ask, session: "ok", pid: 222)
    let fx = rig.tick(alive: { $0 == 222 })
    #expect(fx.contains(.sessionRemoved(.init(agent: .claude, session: "s1"))))
    #expect(rig.tracker.sessions.map(\.id.session) == ["ok"])
}

@Test func oldHistoryIsForgotten() {
    var rig = Rig()
    rig.send(.done, session: "d"); rig.send(.start, session: "i")
    rig.advance(3601); rig.input(); rig.tick()
    #expect(rig.tracker.isEmpty)
}

@Test func theTableIsBoundedAndNeverDropsAWaitingSession() {
    var rig = Rig()
    rig.send(.ask, session: "waiting")
    for i in 0..<300 { rig.advance(0.01); rig.send(.working, session: "w\(i)") }
    #expect(rig.tracker.sessions.count <= AgentTracker.maxSessions)
    #expect(rig.state("waiting") == .needsInput)
}

@Test func projectNameComesFromTheWorkingDirectory() {
    var rig = Rig()
    rig.send(.working, cwd: "/Users/me/work/my-app")
    #expect(rig.tracker.sessions.first?.project == "my-app")
}

// MARK: tick is cheap when nothing is going on

@Test func tickingAnEmptyTrackerDoesNothing() {
    var rig = Rig()
    #expect(rig.tick().isEmpty && rig.display == nil)
}

// MARK: ordering and change tracking

@Test func listsPutWhatNeedsTheUserFirst() {
    var rig = Rig()
    rig.send(.done, session: "finished"); rig.advance(1)
    rig.send(.error, session: "failed"); rig.advance(1)
    rig.send(.working, session: "busy"); rig.advance(1)
    rig.send(.ask, session: "waiting"); rig.advance(1)
    rig.send(.done, session: "finished-later")
    #expect(rig.tracker.sessions.map(\.id.session) == ["waiting", "failed", "finished-later", "finished", "busy"],
            "needs you, then failed, then finished (newest first), then working")
}

@Test func versionMovesOnlyForChangesAPersonCanSee() {
    var rig = Rig()
    rig.send(.working, cwd: "/w/app")
    let v0 = rig.tracker.version
    for _ in 0..<50 { rig.advance(0.1); rig.send(.working, cwd: "/w/app") }      // the same thing, over and over
    #expect(rig.tracker.version == v0)
    rig.advance(1); rig.send(.ask); #expect(rig.tracker.version > v0)
    let v1 = rig.tracker.version
    rig.advance(1); rig.send(.ask, req: "second"); #expect(rig.tracker.version > v1, "a second pending request is visible")
    let v2 = rig.tracker.version
    rig.advance(1); rig.send(.substart, sub: "a"); #expect(rig.tracker.version > v2, "a subagent starting is visible")
    let v3 = rig.tracker.version
    rig.advance(1); rig.tracker.dismissAll(now: rig.now); #expect(rig.tracker.version > v3)
    let v4 = rig.tracker.version
    rig.advance(1); rig.send(.end); #expect(rig.tracker.version > v4)
    let v5 = rig.tracker.version
    rig.tick(); #expect(rig.tracker.version == v5, "an empty tick changes nothing")
}

@Test func sessionsThatDifferOnlyInBookkeepingAreEqual() {
    var rig = Rig()
    rig.send(.working, cwd: "/w/app")
    let a = rig.tracker.sessions[0]
    rig.advance(30); rig.send(.working, cwd: "/w/app")
    #expect(rig.tracker.sessions[0] == a, "only the time of the last event moved")
    rig.advance(1); rig.send(.ask)
    #expect(rig.tracker.sessions[0] != a)
}

@Test func theTickIntervalFollowsWhatNeedsWatching() {
    var rig = Rig()
    #expect(rig.tracker.nextTickInterval == 30)                     // nothing at all
    rig.send(.done, session: "d")
    #expect(rig.tracker.nextTickInterval == 1, "a finish nobody has seen waits for the user's return")
    rig.advance(1); rig.input(); rig.advance(1); rig.tick()               // the user touches the keyboard after it finished
    #expect(rig.tracker.nextTickInterval == 30, "seen: only housekeeping is left")
    rig.advance(1); rig.send(.substart, session: "s", sub: "a"); rig.send(.done, session: "s")
    #expect(rig.tracker.nextTickInterval == 1, "a held finish waits on the subagent timeout")
}
