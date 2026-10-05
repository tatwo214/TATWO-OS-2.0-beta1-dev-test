import Foundation

/// 與 NSEvent 無關；時間使用單調遞增的秒數。一次手勢從第一顆修飾鍵到全部放開。
struct ModifierChordDetector {
    struct Flags: OptionSet {
        let rawValue: UInt
        static let option = Self(rawValue: 1 << 0)
        static let command = Self(rawValue: 1 << 1)
        static let shift = Self(rawValue: 1 << 2)
        static let control = Self(rawValue: 1 << 3)
        static let capsLock = Self(rawValue: 1 << 4)
        static let function = Self(rawValue: 1 << 5)
        static let other = Self(rawValue: 1 << 6)
        static let chord: Self = [.option, .command]
    }

    private var startedAt: TimeInterval?
    private var sawChord = false
    private var disqualified = false
    let maximumDuration: TimeInterval

    init(maximumDuration: TimeInterval = 1) {
        self.maximumDuration = maximumDuration
    }

    mutating func flagsChanged(_ flags: Flags, at time: TimeInterval) -> Bool {
        // Caps Lock 與事件分類旗標是狀態；只比對實際按住的修飾鍵。
        let heldFlags = flags.intersection([.option, .command, .shift, .control, .function])
        if heldFlags.isEmpty {
            let fire = startedAt.map {
                sawChord && !disqualified && time >= $0 && time - $0 <= maximumDuration
            } ?? false
            reset()
            return fire
        }
        if startedAt == nil { startedAt = time }
        if !heldFlags.subtracting(.chord).isEmpty { disqualified = true }
        if heldFlags == .chord { sawChord = true }
        return false
    }

    mutating func keyDown(at time: TimeInterval) {
        if startedAt != nil { disqualified = true }
    }

    mutating func reset() {
        startedAt = nil
        sawChord = false
        disqualified = false
    }
}
