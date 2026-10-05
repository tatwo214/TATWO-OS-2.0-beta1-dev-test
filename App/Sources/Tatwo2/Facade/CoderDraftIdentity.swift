import Foundation

/// nil is this device, distinct from every remote device identifier.
struct CoderDraftIdentity: Hashable {
    let deviceID: String?
    let threadID: UUID
}
