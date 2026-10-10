#if DEBUG
import Foundation

@MainActor enum W221bDevicesAcceptance {
    static func run() async throws -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard NativeStagingIsolation.isEnabled(environment), NativeStagingIsolation.validationError(environment) == nil,
              let live = environment["TATWO2_LIVE_ROOT"] else { throw DeviceFleetError.malformed }
        var passed = 0, failed = 0
        try await PrimaryOfflineAcceptance.quietDevicesChecks(environment: environment,
            root: URL(fileURLWithPath: live).appendingPathComponent("w221b-signed-devices")) { condition, label in
                if condition { passed += 1 } else { failed += 1 }
                print("W221BDEVICES \(condition ? "PASS" : "FAIL") \(label)")
            }
        print("W221BDEVICES SUMMARY passed=\(passed) failures=\(failed)")
        return failed == 0
    }
}
#endif
