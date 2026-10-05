import Foundation

@main
struct ScrollFollowChecks {
    static func main() {
        var failed = 0, passed = 0
        func check(_ name: String, _ success: Bool) {
            if success { passed += 1 } else { failed += 1 }
            print("SCROLLFOLLOWTEST \(success ? "PASS" : "FAIL") \(name)")
        }
        var state = ChatTranscriptScrollFollowState()
        check("new transcript follows latest", state.shouldAutoScrollOnContentChange)
        state.update(bottomY: 900, viewportHeight: 500)
        check("long initial layout cannot cancel first positioning", state.shouldAutoScrollOnContentChange)
        state.detachFromLatest()
        check("reading history shows return control", state.showsJumpToLatest)
        state.update(bottomY: 0, viewportHeight: 500)
        check("missing sentinel cannot reattach", !state.shouldAutoScrollOnContentChange)
        state.update(bottomY: 300, viewportHeight: 0)
        check("missing viewport cannot reattach", !state.shouldAutoScrollOnContentChange)
        state.update(bottomY: .nan, viewportHeight: 500)
        check("invalid geometry cannot reattach", !state.shouldAutoScrollOnContentChange)
        state.update(bottomY: 500, viewportHeight: .infinity)
        check("infinite geometry cannot reattach", !state.shouldAutoScrollOnContentChange)
        state.update(bottomY: -1, viewportHeight: 500)
        check("negative sentinel cannot reattach", !state.shouldAutoScrollOnContentChange)
        state.update(bottomY: 900, viewportHeight: -1)
        check("negative viewport cannot reattach", !state.shouldAutoScrollOnContentChange)
        state.update(bottomY: .infinity, viewportHeight: 500)
        check("infinite sentinel cannot reattach", !state.shouldAutoScrollOnContentChange)
        state.update(bottomY: 900, viewportHeight: .nan)
        check("invalid viewport cannot reattach", !state.shouldAutoScrollOnContentChange)
        check("invalid geometry preserves last valid button distance", state.showsJumpToLatest)
        // 606ea9ec: within 80pt resumes follow; the button appears only beyond 360pt.
        state.update(bottomY: 861, viewportHeight: 500)
        check("return control appears beyond 360 points", state.showsJumpToLatest)
        state.update(bottomY: 860, viewportHeight: 500)
        check("360 point boundary hides button without resuming follow",
              !state.showsJumpToLatest && !state.shouldAutoScrollOnContentChange)
        state.update(bottomY: 581, viewportHeight: 500)
        check("81 points remains detached without a return button",
              !state.shouldAutoScrollOnContentChange && !state.showsJumpToLatest)
        state.update(bottomY: 580, viewportHeight: 500)
        check("returning to 80 point boundary resumes following", state.shouldAutoScrollOnContentChange)
        state.detachFromLatest()
        check("explicit history navigation cancels pending follow", !state.shouldAutoScrollOnContentChange)
        state.update(bottomY: 510, viewportHeight: 500)
        check("returning inside bottom threshold resumes following", state.shouldAutoScrollOnContentChange)
        state.detachFromLatest()
        state.update(bottomY: 500, viewportHeight: 500)
        check("returning to exact bottom resumes following", state.shouldAutoScrollOnContentChange)
        state.detachFromLatest()
        state.update(bottomY: 400, viewportHeight: 500)
        check("short transcript resumes following without a return button",
              state.shouldAutoScrollOnContentChange && !state.showsJumpToLatest)
        state.detachFromLatest()
        for offset in 0..<1000 { state.update(bottomY: CGFloat(581 + offset), viewportHeight: 500) }
        check("stream growth outside bottom threshold remains detached", !state.shouldAutoScrollOnContentChange)
        state.update(bottomY: 0, viewportHeight: 500)
        check("history intent survives lazy row replacement", !state.shouldAutoScrollOnContentChange)
        state.jumpToLatest()
        check("explicit latest control resumes following", state.shouldAutoScrollOnContentChange)
        check("explicit latest hides return button before geometry catches up", !state.showsJumpToLatest)
        state.update(bottomY: 580, viewportHeight: 500)
        check("existing 80 point threshold retained", state.shouldAutoScrollOnContentChange)
        state.update(bottomY: 581, viewportHeight: 500)
        check("large streamed block preserves active following", state.shouldAutoScrollOnContentChange)
        state.update(bottomY: 5000, viewportHeight: 500)
        check("large layout growth never detaches an active follower",
              state.shouldAutoScrollOnContentChange && !state.showsJumpToLatest)
        check("new conversation starts following independently", ChatTranscriptScrollFollowState().shouldAutoScrollOnContentChange)
        let detached = ChatTranscriptScrollFollowState(isFollowingLatest: false)
        check("unknown geometry in detached transcript does not invent return button",
              !detached.shouldAutoScrollOnContentChange && !detached.showsJumpToLatest)
        print("SCROLLFOLLOWTEST RESULT passed=\(passed) failed=\(failed) skipped=0")
        if failed > 0 { fatalError("scroll-follow regression") }
    }
}
