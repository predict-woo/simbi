import Foundation

/// JSON-RPC id — the app-server sends Int ids for its own requests, but the
/// spec allows strings; echo back whatever arrived.
public enum RPCID: Equatable, Sendable, Hashable {
    case int(Int)
    case string(String)

    var jsonValue: any Sendable {
        switch self {
        case .int(let value): value
        case .string(let value): value
        }
    }
}

/// Classifies one incoming JSON-RPC message off the app-server stream.
/// Responses have an id and no method; server→client requests (approvals)
/// have BOTH method and id and must be answered; notifications have only a
/// method.
enum JSONRPCMessage {
    case response(id: Int, body: [String: Any])
    case serverRequest(id: RPCID, method: String, params: [String: Any])
    case notification(method: String, params: [String: Any])
    case invalid

    static func classify(_ object: [String: Any]) -> JSONRPCMessage {
        let method = object["method"] as? String
        let rpcId: RPCID? =
            if let intId = object["id"] as? Int {
                .int(intId)
            } else if let stringId = object["id"] as? String {
                .string(stringId)
            } else {
                nil
            }
        switch (method, rpcId) {
        case (nil, .int(let id)):
            return .response(id: id, body: object)
        case (let method?, let id?):
            return .serverRequest(
                id: id, method: method, params: object["params"] as? [String: Any] ?? [:])
        case (let method?, nil):
            return .notification(
                method: method, params: object["params"] as? [String: Any] ?? [:])
        default:
            return .invalid
        }
    }
}
