import Foundation
import CryptoKit
import Combine

/// Discovery is only an endpoint hint. HMAC and host-key pinning still authenticate the peer.
@MainActor
final class DevicePairingDiscovery: NSObject, ObservableObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    struct Peer: Identifiable, Equatable {
        let id: String
        let name: String
        let host: String
        let port: Int
        let session: String
    }
    static let serviceType = "_tatwo-pair._tcp."
    nonisolated static func sessionTag(_ code: String) -> String {
        Data(base64Encoded: DevicePairingAuth.makeNonce())!.map { String(format: "%02x", $0) }.joined()
    }
    static func resolvedHost(_ value: String) -> String? {
        let host = value.hasSuffix(".") ? String(value.dropLast()) : value
        return DevicePairingInput.validHost(host) ? host : nil
    }
    @Published private(set) var peers: [Peer] = []
    @Published private(set) var advertised = false
    @Published private(set) var unavailable = false
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var advertisement: NetService?

    func browse() {
        browser.delegate = self
        browser.searchForServices(ofType: Self.serviceType, inDomain: "local.")
    }
    func advertise(code: String, port: Int, name: String) {
        stopAdvertising()
        let service = NetService(domain: "local.", type: Self.serviceType, name: "TATWO Pairing", port: Int32(port))
        service.delegate = self
        service.setTXTRecord(NetService.data(fromTXTRecord: ["session": Data(Self.sessionTag(code).utf8)]))
        advertisement = service
        service.publish()
    }
    func stopAdvertising() { advertisement?.stop(); advertisement = nil; advertised = false }
    func stop() {
        stopAdvertising(); browser.stop(); services.forEach { $0.stop() }; services = []; peers = []
    }
    func matches(code: String) -> [Peer] {
        guard code.count == 6 else { return [] }
        return peers
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard services.count < 64 else { return }
        services.append(service); service.delegate = self; service.resolve(withTimeout: 4)
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        let id = service.domain + service.type + service.name
        peers.removeAll { $0.id == id }; services.removeAll { $0 == service }
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) { unavailable = true }
    func netServiceDidPublish(_ sender: NetService) { if sender === advertisement { advertised = true } }
    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) { advertised = false; unavailable = true }
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let rawHost = sender.hostName, let host = Self.resolvedHost(rawHost), (1...65535).contains(sender.port),
              let txt = sender.txtRecordData(), let data = NetService.dictionary(fromTXTRecord: txt)["session"],
              let tag = String(data: data, encoding: .utf8), tag.count == 64,
              tag.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return }
        let id = sender.domain + sender.type + sender.name
        peers.removeAll { $0.id == id }
        peers.append(.init(id: id, name: String(sender.name.prefix(80)), host: host, port: sender.port, session: tag))
    }
}
