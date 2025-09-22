import Vapor
import Foundation
import NIOConcurrencyHelpers

final class Room {
    let code: String
    private(set) var clients: [UUID: Client] = [:]

    init(code: String) { self.code = code }

    func join(_ c: Client) { clients[c.id] = c }
    func leave(_ id: UUID) { clients.removeValue(forKey: id) }

    func broadcast(_ payload: String, excluding excludeID: UUID? = nil) {
        clients.forEach { (id, c) in
            guard id != excludeID else { return }
            c.socket.send(payload)
        }
    }
}

final class Client {
    let id: UUID
    let name: String
    let socket: WebSocket

    init(id: UUID = UUID(), name: String, socket: WebSocket) {
        self.id = id
        self.name = name
        self.socket = socket
    }
}

final class Rooms {
    static let shared = Rooms()
    private let lock = NIOLock()
    private var map: [String: Room] = [:]

    func room(_ code: String) -> Room {
        lock.withLock {
            if let r = map[code] { return r }
            let r = Room(code: code)
            map[code] = r
            return r
        }
    }

    func withRoom(_ code: String, _ body: (Room)->Void) {
        lock.withLock {
            let r = map[code] ?? {
                let nr = Room(code: code)
                map[code] = nr
                return nr
            }()
            body(r)
        }
    }

    func removeClient(_ clientID: UUID, from code: String) {
        lock.withLock { map[code]?.leave(clientID) }
    }
}
