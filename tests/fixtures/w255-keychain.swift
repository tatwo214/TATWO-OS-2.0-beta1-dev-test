enum BrowserPasswordVaultError: Error { case keychain(OSStatus), secretUnavailable }
protocol HandsTunnelTokenStore { func read() throws -> String? }
var items: [String: Data] = [:]
var writes: [[String: Any]] = []
var updates: [[String: Any]] = []
var deletes = 0
var denyDP = false
var denyMigration = false
func identity(_ q: [String: Any]) -> String {
    "\(q[kSecAttrService as String] ?? "")/\(q[kSecAttrAccount as String] ?? "")/\(q[kSecUseDataProtectionKeychain as String] as? Bool ?? false)"
}
func fakeSecItemCopyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
    let q = query as! [String: Any]
    if denyDP && q[kSecUseDataProtectionKeychain as String] as? Bool == true { return -34018 }
    guard let value = items[identity(q)] else { return errSecItemNotFound }
    result?.pointee = value as CFData
    return errSecSuccess
}
func fakeSecItemUpdate(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
    let q = query as! [String: Any], a = attributes as! [String: Any]
    updates.append(a)
    if denyMigration && a[kSecValueData as String] == nil { return errSecAuthFailed }
    guard items[identity(q)] != nil else { return errSecItemNotFound }
    if let data = a[kSecValueData as String] as? Data { items[identity(q)] = data }
    return errSecSuccess
}
func fakeSecItemAdd(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
    let q = query as! [String: Any]
    writes.append(q)
    if denyDP && q[kSecUseDataProtectionKeychain as String] as? Bool == true { return -34018 }
    items[identity(q)] = q[kSecValueData as String] as? Data
    return errSecSuccess
}
func fakeSecItemDelete(_ query: CFDictionary) -> OSStatus {
    deletes += 1; items.removeValue(forKey: identity(query as! [String: Any])); return errSecSuccess
}
func check(_ value: Bool) { precondition(value) }
func keychainChecks() throws {
    let browser = KeychainSecretStore(service: "w255-fake-browser"), id = UUID()
    if CommandLine.arguments.contains("dp") {
        try browser.set("synthetic", for: id)
        precondition(writes.first?[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        print("W255 H1 PASS data-protection write"); return
    }
    denyDP = true
    let legacy = UUID()
    try browser.set("legacy", for: legacy)
    let cf = CloudflareKeychain()
    try cf.save("synthetic-cert", service: "w255-fake-cf", account: "fixture")
    precondition(writes.count >= 3)
    for q in writes { precondition(q[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String) }
    let unreadable = UUID(), readCount = updates.count
    items["w255-fake-browser/" + unreadable.uuidString + "/false"] = Data([0xff])
    var failedRead = false
    do { _ = try browser.get(unreadable) } catch { failedRead = true }
    precondition(failedRead && updates.count == readCount)
    let before = items, deleteCount = deletes
    denyMigration = true
    check(try browser.get(legacy) == "legacy")
    check(try cf.read(service: "w255-fake-cf", account: "fixture") == "synthetic-cert")
    precondition(items == before && deletes == deleteCount)
    let failed = updates.count
    denyMigration = false
    check(try browser.get(legacy) == "legacy")
    check(try cf.read(service: "w255-fake-cf", account: "fixture") == "synthetic-cert")
    let migrated = updates.count
    precondition(migrated == failed + 2)
    _ = try browser.get(legacy); _ = try cf.read(service: "w255-fake-cf", account: "fixture")
    precondition(updates.count == migrated && items == before && deletes == deleteCount)
    for a in updates.suffix(4) { precondition(a[kSecValueData as String] == nil) }
    let tkey = "tatwo2-cloudflare-tunnel/tunnel/false"
    items[tkey] = Data("synthetic-tunnel".utf8)
    check(try HandsTunnelKeychain().read() == "synthetic-tunnel")
    precondition(items[tkey] == Data("synthetic-tunnel".utf8))
    print("W255 H1 PASS new-DP/login attributes, failed-read-migration preserves, retry, once, tunnel")
}
