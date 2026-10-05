import SwiftUI
import Combine

private struct WorkspaceVisibilityKey: EnvironmentKey {
    static let defaultValue = true
}
extension EnvironmentValues {
    var tatwoWorkspaceVisible: Bool {
        get { self[WorkspaceVisibilityKey.self] }
        set { self[WorkspaceVisibilityKey.self] = newValue }
    }
}

/// Retain view state while an opacity-hidden workspace stops receiving UI invalidations.
@MainActor @propertyWrapper struct WorkspaceObservedObject<Object: ObservableObject>: @preconcurrency DynamicProperty {
    let wrappedValue: Object
    @Environment(\.tatwoWorkspaceVisible) private var visible
    @StateObject private var observation: WorkspaceObservation<Object>
    init(wrappedValue: Object, forwardWhenHidden: @escaping (Object) -> [AnyPublisher<Void, Never>] = { _ in [] },
         shouldForward: @escaping (Object) -> Bool = { _ in true }) {
        self.wrappedValue = wrappedValue
        _observation = StateObject(wrappedValue: WorkspaceObservation(object: wrappedValue,
            forwardWhenHidden: forwardWhenHidden, shouldForward: shouldForward))
    }
    func forwardOrdinaryUpdates(_ enabled: Bool) { observation.forwardOverride = enabled }
    func update() { observation.configure(object: wrappedValue, visible: visible) }
    var projectedValue: Bindings { Bindings(object: wrappedValue) }
    @dynamicMemberLookup struct Bindings {
        let object: Object
        subscript<Value>(dynamicMember keyPath: ReferenceWritableKeyPath<Object, Value>) -> Binding<Value> {
            let path = WorkspaceBindingKeyPath(value: keyPath)
            return Binding(get: { object[keyPath: path.value] }, set: { object[keyPath: path.value] = $0 })
        }
    }
}

/// Immutable property key paths; the referenced models remain owned by the main actor.
struct WorkspaceBindingKeyPath<Object: AnyObject, Value>: @unchecked Sendable {
    let value: ReferenceWritableKeyPath<Object, Value>
}

@MainActor final class WorkspaceObservation<Object: ObservableObject>: ObservableObject {
    private weak var object: Object?
    private var watches = Set<AnyCancellable>()
    private let forwardWhenHidden: (Object) -> [AnyPublisher<Void, Never>]
    private let shouldForward: (Object) -> Bool
    var isVisible = true
    var forwardOverride = false
    init(object: Object, forwardWhenHidden: @escaping (Object) -> [AnyPublisher<Void, Never>] = { _ in [] },
         shouldForward: @escaping (Object) -> Bool = { _ in true }) {
        self.forwardWhenHidden = forwardWhenHidden
        self.shouldForward = shouldForward
        configure(object: object, visible: true)
    }
    func configure(object: Object, visible: Bool) {
        isVisible = visible
        guard self.object !== object else { return }
        watches.removeAll()
        self.object = object
        object.objectWillChange.sink { [weak self, weak object] _ in
            guard let self, let object, isVisible, forwardOverride || shouldForward(object) else { return }
            objectWillChange.send()
        }.store(in: &watches)
        for publisher in forwardWhenHidden(object) {
            publisher.sink { [weak self] in self?.objectWillChange.send() }.store(in: &watches)
        }
    }
}

struct VisibleTimelineSchedule<Base: TimelineSchedule>: TimelineSchedule {
    let base: Base
    let isVisible: Bool
    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnySequence<Date> {
        isVisible ? AnySequence(base.entries(from: startDate, mode: mode)) : AnySequence([])
    }
}
