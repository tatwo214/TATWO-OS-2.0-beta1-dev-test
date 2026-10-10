// 自測與 staging 一律不碰主機鑰匙圈。
// 整個 App 模組的這六個呼叫都經過這裡。
import Foundation
import Security

// W255b/W293: selftests and staging fail closed before host Keychain APIs.
private enum W255TestKeychain {
    static var active: Bool {
        let environment = ProcessInfo.processInfo.environment
        if NativeStagingIsolation.isW276Bundle { return true }
        return NativeStagingIsolation.isSelfTest(environment)
    }
}
func SecItemCopyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
    if W255TestKeychain.active { result?.pointee = nil; return errSecInteractionNotAllowed }
    return Security.SecItemCopyMatching(query, result)
}
func SecItemAdd(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
    if W255TestKeychain.active { result?.pointee = nil; return errSecInteractionNotAllowed }
    return Security.SecItemAdd(query, result)
}
func SecItemUpdate(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
    if W255TestKeychain.active { return errSecInteractionNotAllowed }
    return Security.SecItemUpdate(query, attributes)
}
func SecItemDelete(_ query: CFDictionary) -> OSStatus {
    if W255TestKeychain.active { return errSecInteractionNotAllowed }
    return Security.SecItemDelete(query)
}
func SecKeychainGetUserInteractionAllowed(_ state: UnsafeMutablePointer<DarwinBoolean>) -> OSStatus {
    if W255TestKeychain.active { state.pointee = false; return errSecInteractionNotAllowed }
    return Security.SecKeychainGetUserInteractionAllowed(state)
}
func SecKeychainSetUserInteractionAllowed(_ state: Bool) -> OSStatus {
    if W255TestKeychain.active { return errSecInteractionNotAllowed }
    return Security.SecKeychainSetUserInteractionAllowed(state)
}

// W255b: end selftest Keychain boundary.
