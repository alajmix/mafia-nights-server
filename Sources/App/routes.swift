import Vapor

struct SPlayer: Content { let id: UUID; let name: String }
struct SRoom: Content {
    let id: UUID
    let code: String
    let players: [SPlayer]
    let started: Bool
}

enum Outbound: Content {
    case room(SRoom)
    case system(String)
    case chat(String)
}

final class Client {
    let id = UUID()
    let name: String
    weak var ws: WebSocket?
    init(name: String, ws: WebSocket) { self.name = name; self.ws = ws }
}

final class Room {
    let id = UUID()
    let code: String
    var started = false
    var clients: [UUID: Client] = [:]
    init(code: String) { self.code = code }
}

private var rooms: [String: Room] = [:]

private func encode(_ outbound: Outbound) -> String {
    let enc = JSONEncoder()
    let data = try! enc.encode(outbound)
    return String(data: data, encoding: .utf8)!
}

private func snapshot(_ room: Room) -> Outbound {
    let players = room.clients.values.map { SPlayer(id: $0.id, name: $0.name) }
    let s = SRoom(id: room.id, code: room.code, players: players, started: room.started)
    return .room(s)
}

private func broadcast(_ room: Room, _ payload: Outbound) {
    let text = encode(payload)
    room.clients.values.forEach { $0.ws?.send(text) }
}

public func routes(_ app: Application) throws {
    app.get("health") { _ in "ok" }

    app.webSocket("ws") { req, ws in
        guard let code = req.query[String.self, at: "room"],
              let name = req.query[String.self, at: "name"],
              !code.isEmpty, !name.isEmpty else {
            try? ws.close(code: .policyViolation)
            return
        }

        let room = rooms[code] ?? { let r = Room(code: code); rooms[code] = r; return r }()
        let client = Client(name: name, ws: ws)
        room.clients[client.id] = client

        ws.send(encode(snapshot(room)))
        broadcast(room, .system("joined:\(client.name)"))

        ws.onText { ws, text in
            if text.trimmingCharacters(in: .whitespacesAndNewlines) == "\"start\"" {
                room.started = true
                broadcast(room, snapshot(room))
                broadcast(room, .system("phase:night"))
                return
            }
            if let data = text.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

                if let phase = obj["phase"] as? String, (phase == "day" || phase == "night") {
                    broadcast(room, .system("phase:\(phase)"))
                }
                if let type = obj["type"] as? String, type == "vote" {
                    let from = obj["from"] as? String ?? "?"
                    let target = obj["target"] as? String ?? "skip"
                    broadcast(room, .system("vote:target:\(target):from:\(from)"))
                }
                if let chat = obj["chat"] as? String {
                    broadcast(room, .chat(chat))
                }
                return
            }
        }

        ws.onClose.whenComplete { _ in
            room.clients.removeValue(forKey: client.id)
            broadcast(room, snapshot(room))
            broadcast(room, .system("left:\(client.name)"))
            if room.clients.isEmpty { rooms.removeValue(forKey: room.code) }
        }
    }
}
