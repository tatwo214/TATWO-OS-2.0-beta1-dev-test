import { readFileSync } from 'node:fs';
// Pin/endpoint tests compile the transport alone. They do not exercise RPC; fail closed
// if a fixture unexpectedly reaches signing. Actual RPC proofs run through the room binary.
export function fleetDispatchCompileStubs() {
  const dispatch = readFileSync('App/Sources/Tatwo2/Facade/DeviceDispatch.swift', 'utf8');
  const optionalFiles = dispatch.match(/static let optionalFiles = (\[[^\n]+\])/)[1];
  const settings = readFileSync('App/Sources/Tatwo2/Facade/HandsSettings.swift', 'utf8');
  const files = settings.slice(settings.indexOf('enum HandsFileError:'), settings.indexOf('/// W183 R3b 審查'));
  return `
import Darwin
import Foundation
${files}
// Standalone transport probes do not link the UI-owned sandbox lane.
struct HandsService {
  static let shared = Self()
  struct Lane { func remove(_ id: String) {} }
  let sandboxLane = Lane()
  func onMain(_ body: () -> Void) { body() }
}
struct DeviceDispatch {
  static let optionalFiles = ${optionalFiles}
  struct Failure: LocalizedError { let reason: String; var errorDescription: String? { reason } }
  init(entry: TatwoEntry, registry: DeviceRegistry, environment: [String: String]) {}
  func signedHandshake(method: String, params: [String: Any], recipient: String?) throws -> [String: Any] {
    throw NSError(domain: "unexpected-RPC-in-pin-only-fixture", code: 1)
  }
  func signed(method: String, payload: [String: Any], recipient: String?) throws -> [String: Any] {
    throw NSError(domain: "unexpected-RPC-in-pin-only-fixture", code: 1)
  }
}
`;
}
export function fleetRPCCompileStubs() {
  const bridge = readFileSync('App/Sources/Tatwo2/Facade/OSAgentBridge.swift', 'utf8');
  const methods = bridge.match(/static let signedDeviceMethods: Set<String> = (\[[\s\S]*?\])/)[1];
  return fleetDispatchCompileStubs() + `
struct OSAgentBridge { static let signedDeviceMethods: Set<String> = ${methods} }
`;
}
