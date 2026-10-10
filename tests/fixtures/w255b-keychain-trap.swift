import Foundation
import Security
private func w255bRefuseKeychain() -> Never { fputs("W255B_BOUNDARY: un-injected Keychain API\n", stderr); exit(86) }
func w255bRefuseSecItemCopyMatching(_ q: CFDictionary, _ r: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus { w255bRefuseKeychain() }
func w255bRefuseSecItemAdd(_ q: CFDictionary, _ r: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus { w255bRefuseKeychain() }
func w255bRefuseSecItemUpdate(_ q: CFDictionary, _ a: CFDictionary) -> OSStatus { w255bRefuseKeychain() }
func w255bRefuseSecItemDelete(_ q: CFDictionary) -> OSStatus { w255bRefuseKeychain() }
func w255bRefuseSecKeychainGetUserInteractionAllowed(_ state: UnsafeMutablePointer<DarwinBoolean>) -> OSStatus { w255bRefuseKeychain() }
func w255bRefuseSecKeychainSetUserInteractionAllowed(_ state: Bool) -> OSStatus { w255bRefuseKeychain() }
