import Vapor

public func routes(_ app: Application) throws {

    app.webSocket("ws") { req, ws in
        let code = (try? req.query.get(String.self, at: "room")) ?? "ROOM"
        let name = (try? req.query.get(String.self, at: "name")) ?? "Guest"

        let client = Client(name: name, socket: ws)
        let room = Rooms.shared.room(code)
        room.join(client)

        app.logger.info("[WS] \(name) joined \(code)")

        let joinMsg = json(["type":"join", "name": name, "code": code])
        room.broadcast(joinMsg, excluding: client.id)

        ws.onText { _, text in
            app.logger.info("[WS in] \(text)")
            if text.contains("\"phase\"") {
                room.broadcast(text)
            } else {
                room.broadcast(text, excluding: client.id)
            }
        }

        ws.onClose.whenComplete { _ in
            Rooms.shared.removeClient(client.id, from: code)
            let leaveMsg = json(["type":"leave", "name": name, "code": code])
            room.broadcast(leaveMsg)
            app.logger.info("[WS] \(name) left \(code)")
        }
    }
}

func json(_ dict: [String:String]) -> String {
    var items: [String] = []
    for (k,v) in dict {
        let ks = k.replacingOccurrences(of: """, with: "\\"")
        let vs = v.replacingOccurrences(of: """, with: "\\"")
        items.append("\"\(ks)\":\"\(vs)\"")
    }
    return "{\(items.joined(separator: ","))}"
}
