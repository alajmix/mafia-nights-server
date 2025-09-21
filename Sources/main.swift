import Vapor

struct Player: Codable, Hashable { let id: UUID; let name: String }
struct Room: Codable { let id: UUID; let code: String; var players: [Player] = []; var started: Bool = false }

enum Outbound: Codable { case room(Room); case system(String); case chat(String) }

final class RoomManager {
    var rooms: [String: Room] = [:]
    var sockets: [UUID: WebSocket] = [:]
    var playerRoom: [UUID: String] = [:]

    func join(room code: String, name: String, ws: WebSocket) -> (Room, Player) {
        var room = rooms[code] ?? Room(id: UUID(), code: code, players: [], started: false)
        let me = Player(id: UUID(), name: name)
        room.players.append(me)
        rooms[code] = room
        sockets[me.id] = ws
        playerRoom[me.id] = code
        broadcast(room)
        return (room, me)
    }

    func start(code: String) {
        guard var r = rooms[code] else { return }
        r.started = true
        rooms[code] = r
        broadcast(r)
    }

    func broadcast(_ room: Room) {
        do {
            let text = String(data: try JSONEncoder().encode(Outbound.room(room)), encoding: .utf8)!
            for (pid, ws) in sockets where playerRoom[pid] == room.code {
                ws.send(text)
            }
        } catch {
            print("broadcast error:", error)
        }
    }

    func disconnect(playerID: UUID) {
        sockets[playerID] = nil
        if let code = playerRoom[playerID], var r = rooms[code] {
            r.players.removeAll { $0.id == playerID }
            rooms[code] = r
            broadcast(r)
        }
        playerRoom[playerID] = nil
    }
}

let app = Application(.development)
defer { app.shutdown() }

// Bind to 0.0.0.0 and honor PORT env (Render/Heroku style)
app.http.server.configuration.hostname = "0.0.0.0"
if let portStr = Environment.get("PORT"), let p = Int(portStr) {
    app.http.server.configuration.port = p
}

let manager = RoomManager()

app.get("health") { _ in "ok" }

app.webSocket("ws") { req, ws in
    guard let code = req.query[String.self, at: "room"],
          let name = req.query[String.self, at: "name"] else {
        ws.close(promise: nil)
        return
    }

    let (room, me) = manager.join(room: code, name: name, ws: ws)

    ws.onText { ws, text in
    if text == "\"start\"" {
        manager.start(code: code)
        return
    }

    // Try parse small JSON messages from clients
    if let data = text.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

        // Broadcast phase change as a system message "phase:night" / "phase:day"
        if let phase = obj["phase"] as? String, (phase == "night" || phase == "day") {
            let sys = Outbound.system("phase:\(phase)")
            if let sysText = String(data: try! JSONEncoder().encode(sys), encoding: .utf8) {
                if let r = manager.rooms[code] {
                    for (pid, peer) in manager.sockets where manager.playerRoom[pid] == r.code {
                        peer.send(sysText)
                    }
                }
            }
            return
        }

        // Mafia chat or global chat
        if let msg = obj["chat"] as? String {
            let chat = Outbound.chat(msg)
            if let chatText = String(data: try! JSONEncoder().encode(chat), encoding: .utf8) {
                if let r = manager.rooms[code] {
                    for (pid, peer) in manager.sockets where manager.playerRoom[pid] == r.code {
                        peer.send(chatText)
                    }
                }
            }
            return
        }
    }
}

    ws.onClose.whenComplete { _ in
        manager.disconnect(playerID: me.id)
    }
}

try app.run()
