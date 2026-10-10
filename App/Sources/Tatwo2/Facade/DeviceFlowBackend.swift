import Foundation

extension DeviceDispatch {
    /// Read-only card status through existing pinned SSH/RPC. Never mark offline peers complete.
    func flowOwnerConnectionsReady(_ roster: DeviceFleetRoster) -> Bool {
        guard let local = try? identity(), let localID = try? fleet.trust()?.localID else { return false }
        let expected = roster.devices.filter { roster.kind(of: $0.id) == .owner && $0.id != localID && !roster.revoked.contains($0.id) }
        let records = registry.list()
        return expected.allSatisfy { member in
            guard let record = records.first(where: { $0.id == member.id }),
                  let status = peerStatus(record), let identity = status.identity.value,
                  DeviceStatusPolicy.fresh(status.identity.acquiredAt, now: Date()) else { return false }
            return identity.deviceID == member.id && identity.primaryDeviceID == local.primaryDeviceID && identity.epoch == local.epoch
        }
    }
}
