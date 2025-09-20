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
        }
    }

    ws.onClose.whenComplete { _ in
        manager.disconnect(playerID: me.id)
    }
}

try app.run()
