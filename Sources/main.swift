import Vapor
import Foundation

// MARK: - Wire models

struct SPlayer: Codable {
    let id: UUID
    let name: String
}

struct SRoom: Codable {
    let id: UUID
    let code: String
    let players: [SPlayer]
    let started: Bool
}

enum Outbound: Codable {
    case room(SRoom)
    case system(String)
    case chat(String)
}

// MARK: - In-memory state

final class RoomManager {
    struct Player {
        let id: UUID
        let name: String
    }
    struct Room {
        let id: UUID
        let code: String
        var started: Bool
        var players: [Player]
    }

    // room code -> Room
    var rooms: [String: Room] = [:]
    // player id -> WebSocket
    var sockets: [UUID: WebSocket] = [:]
    // player id -> room code
    var playerRoom: [UUID: String] = [:]

    func room(for code: String) -> Room {
        if let r = rooms[code] { return r }
        let created = Room(id: UUID(), code: code, started: false, players: [])
        rooms[code] = created
        return created
    }

    func addPlayer(name: String, to code: String) -> Player {
        var r = room(for: code)
        let p = Player(id: UUID(), name: name)
        r.players.append(p)
        rooms[code] = r
        playerRoom[p.id] = code
        return p
    }

    func removePlayer(_ id: UUID) {
        guard let code = playerRoom[id], var r = rooms[code] else { return }
        r.players.removeAll { $0.id == id }
        rooms[code] = r
        playerRoom[id] = nil
        sockets[id] = nil
    }

    func snapshot(_ code: String) -> SRoom? {
        guard let r = rooms[code] else { return nil }
        let players = r.players.map { SPlayer(id: $0.id, name: $0.name) }
        return SRoom(id: r.id, code: r.code, players: players, started: r.started)
    }
}

// MARK: - App bootstrap

@main
struct Run {
    static func main() throws {
        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)
        let app = Application(env)
        defer { app.shutdown() }

        let manager = RoomManager()

        // Health check
        app.get("health") { _ in "ok" }

        // WebSocket endpoint: ws://host/ws?room=ABC123&name=Ali
        app.webSocket("ws") { req, ws in
            guard
                let roomCode = req.query[String.self, at: "room"]?.uppercased(),
                let name = req.query[String.self, at: "name"], !name.trimmingCharacters(in: .whitespaces).isEmpty
            else {
                ws.send("error: missing room or name")
                ws.close(promise: nil)
                return
            }

            // Register player
            let player = manager.addPlayer(name: name, to: roomCode)
            manager.sockets[player.id] = ws

            // Send initial room snapshot
            if let snapshot = manager.snapshot(roomCode),
               let json = try? JSONEncoder().encode(Outbound.room(snapshot)),
               let text = String(data: json, encoding: .utf8) {
                ws.send(text)
            }

            // Broadcast "X joined" system message (optional)
            broadcastSystem("joined:\(player.name)", in: roomCode, via: manager)

            // Receive loop
            ws.onText { ws, text in
                // print raw
                app.logger.info("WS(\(player.name)) -> \(text)")

                // Try decode as JSON map
                if let data = text.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

                    // 1) Phase change
                    if let phase = obj["phase"] as? String,
                       (phase == "night" || phase == "day") {
                        let system = Outbound.system("phase:\(phase)")
                        broadcast(system, in: roomCode, via: manager)
                        return
                    }

                    // 2) Chat
                    if let msg = obj["chat"] as? String {
                        let chat = Outbound.chat(msg)
                        broadcast(chat, in: roomCode, via: manager)
                        return
                    }

                    // 3) Vote relay  ——> clients tally anonymously
                    //    Expected: { "type":"vote", "target":"<uuid-or-skip>", "from":"<name>", "code":"ABC123" }
                    if let type = obj["type"] as? String, type == "vote",
                       let target = obj["target"] as? String,
                       let from = obj["from"] as? String {
                        let sys = Outbound.system("vote:target:\(target):from:\(from)")
                        broadcast(sys, in: roomCode, via: manager)
                        return
                    }

                    // 4) Optional: start flag (if you want to propagate)
                    if let start = obj["start"] as? Bool, start == true {
                        // toggle started flag and broadcast room snapshot
                        if var r = manager.rooms[roomCode] {
                            r.started = true
                            manager.rooms[roomCode] = r
                            if let snap = manager.snapshot(roomCode),
                               let json = try? JSONEncoder().encode(Outbound.room(snap)),
                               let text = String(data: json, encoding: .utf8) {
                                broadcastRaw(text, in: roomCode, via: manager)
                            }
                        }
                        return
                    }

                    // Unknown JSON payload
                    return
                }

                // Non-JSON: allow plain "start"
                if text.trimmingCharacters(in: .whitespacesAndNewlines) == "start" {
                    if var r = manager.rooms[roomCode] {
                        r.started = true
                        manager.rooms[roomCode] = r
                        if let snap = manager.snapshot(roomCode),
                           let json = try? JSONEncoder().encode(Outbound.room(snap)),
                           let t = String(data: json, encoding: .utf8) {
                            broadcastRaw(t, in: roomCode, via: manager)
                        }
                    }
                    return
                }
            }

            // On close, clean up and notify
            ws.onClose.whenComplete { _ in
                manager.removePlayer(player.id)
                broadcastSystem("left:\(player.name)", in: roomCode, via: manager)
            }
        }

        // Serve
        try app.run()
    }
}

// MARK: - Broadcast helpers

private func broadcast(_ outbound: Outbound, in code: String, via manager: RoomManager) {
    guard let text = try? String(data: JSONEncoder().encode(outbound), encoding: .utf8) else { return }
    broadcastRaw(text, in: code, via: manager)
}

private func broadcastSystem(_ s: String, in code: String, via manager: RoomManager) {
    broadcast(.system(s), in: code, via: manager)
}

private func broadcastRaw(_ text: String, in code: String, via manager: RoomManager) {
    guard manager.rooms[code] != nil else { return }
    for (pid, ws) in manager.sockets where manager.playerRoom[pid] == code {
        ws.send(text)
    }
}
