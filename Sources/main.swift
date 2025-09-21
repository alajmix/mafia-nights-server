import Vapor
import Foundation

// MARK: - Wire models sent to clients

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

// MARK: - Game Types (server view)

enum Alignment: String { case town, mafia, neutral }

struct PlayerInfo {
    let id: UUID
    var name: String
    var role: String?          // raw, e.g. "mafia", "doctor", "grandma"
    var alive: Bool = true
    var selfHealsUsed: Int = 0 // doctor limit: 1 per game
    var linkPartner: UUID?     // cupid link
}

struct NightActions {
    var mafiaTargets: [UUID] = []    // all mafia picks (we'll count occurrences)
    var protects: [UUID] = []        // doctor
    var armedGrandmas: Set<UUID> = []// grandma flags by player id
    var cupidLinks: [UUID] = []      // target chosen by cupid (linked to cupid themself)
    var vigilanteShots: [UUID] = []  // vigilante shot targets
}

struct DayVotes {
    var votes: [String:Int] = [:]    // key = "skip" or uuidString; anonymous tally
    mutating func add(_ key: String) { votes[key, default: 0] += 1 }
    mutating func clear() { votes.removeAll() }
    func top() -> [(String, Int)] { votes.sorted { $0.value > $1.value } }
}

final class RoomState {
    let id = UUID()
    let code: String
    var started = false
    var players: [UUID: PlayerInfo] = [:]

    // phase tracking
    var nightIndex: Int = 1

    // rolling state
    var night = NightActions()
    var day = DayVotes()

    init(code: String) { self.code = code }

    func sroom() -> SRoom {
        let list = players.values.map { SPlayer(id: $0.id, name: $0.name) }
        return SRoom(id: id, code: code, players: list, started: started)
    }

    // helpers
    func alignment(of role: String) -> Alignment {
        switch role {
        case "mafia","consigliere","framer","silencer","janitor": return .mafia
        case "jester","arsonist","serialKiller","survivor","cultist","moderator": return .neutral
        default: return .town
        }
    }
    func role(of id: UUID) -> String? { players[id]?.role }
    func isAlive(_ id: UUID) -> Bool { players[id]?.alive ?? false }

    func mayorAlive() -> UUID? {
        players.values.first(where: { $0.alive && $0.role == "mayor" })?.id
    }
    func cupidAlive() -> UUID? {
        players.values.first(where: { $0.alive && $0.role == "cupid" })?.id
    }
    func mafiaAliveIDs() -> [UUID] {
        players.values.filter { $0.alive && alignment(of: $0.role ?? "") == .mafia }.map { $0.id }
    }
    func townAliveCount() -> Int {
        players.values.filter { $0.alive && alignment(of: $0.role ?? "") == .town }.count
    }
    func mafiaAliveCount() -> Int { mafiaAliveIDs().count }
    func grandmaAliveIDs() -> Set<UUID> {
        Set(players.values.filter { $0.alive && $0.role == "grandma" }.map { $0.id })
    }
}

// MARK: - In-memory manager

final class RoomManager {
    var rooms: [String: RoomState] = [:]        // code -> state
    var sockets: [UUID: WebSocket] = [:]        // player id -> ws
    var playerRoom: [UUID: String] = [:]        // player id -> room code

    func room(for code: String) -> RoomState {
        if let r = rooms[code] { return r }
        let r = RoomState(code: code)
        rooms[code] = r
        return r
    }

    func addPlayer(name: String, to code: String) -> PlayerInfo {
        let r = room(for: code)
        let p = PlayerInfo(id: UUID(), name: name, role: nil, alive: true)
        r.players[p.id] = p
        playerRoom[p.id] = code
        return p
    }

    func removePlayer(_ id: UUID) {
        guard let code = playerRoom[id], let r = rooms[code] else { return }
        r.players[id] = nil
        playerRoom[id] = nil
        sockets[id] = nil
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

// MARK: - Night resolution engine

private func resolveNight(_ r: RoomState, log: (String)->Void) -> [UUID] {
    var deaths: Set<UUID> = []

    let mafiaTargets = r.night.mafiaTargets
    let protects = Set(r.night.protects)
    let grandmas = r.night.armedGrandmas
    let mafiaAlive = r.mafiaAliveIDs()
    let mafiaCount = mafiaAlive.count

    // Majority mafia target (or last pick if none). Also count occurrences.
    var mafiaVoteCount: [UUID:Int] = [:]
    for t in mafiaTargets { mafiaVoteCount[t, default: 0] += 1 }
    let mafiaChosen = mafiaVoteCount.sorted { $0.value > $1.value }.first?.key

    // Vigilante shots apply directly (server authoritative)
    for target in r.night.vigilanteShots {
        if r.isAlive(target) && !protects.contains(target) {
            deaths.insert(target)
            log("result:vigilante:shot:\(target.uuidString)")
        } else if protects.contains(target) {
            log("result:vigilante:blocked:\(target.uuidString)")
        }
    }

    // Mafia kill resolution (consider Grandma)
    if let target = mafiaChosen, r.isAlive(target) {
        if grandmas.contains(target) {
            // Grandma trap: if only one mafia left -> grandma dies.
            // Else if mafia double-targeted grandma (>=2 votes), grandma survives and mafia is safe.
            let votesOnGrandma = mafiaVoteCount[target] ?? 0
            if mafiaCount == 1 {
                deaths.insert(target)
                log("result:grandma:killed:\(target.uuidString)")
            } else if votesOnGrandma >= 2 {
                log("result:grandma:doubletargeted:\(target.uuidString)")
                // no deaths from grandma trap
            } else {
                // trap kills one mafia attacker (pick any alive mafia)
                if let attacker = mafiaAlive.first(where: { r.isAlive($0) }) {
                    deaths.insert(attacker)
                    log("result:grandma:trap_killed_mafia:\(attacker.uuidString)")
                }
            }
        } else {
            // Normal mafia kill (blocked by doctor?)
            if !protects.contains(target) {
                deaths.insert(target)
                log("result:mafia:kill:\(target.uuidString)")
            } else {
                log("result:mafia:blocked:\(target.uuidString)")
            }
        }
    }

    // Cupid link: if linked target died by NIGHT kill, cupid dies too.
    if let cupidID = r.cupidAlive(),
       let partner = r.players[cupidID]?.linkPartner,
       deaths.contains(partner) {
        deaths.insert(cupidID)
        log("result:cupid:died_with:\(partner.uuidString)")
    }

    return Array(deaths)
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

        // Health
        app.get("health") { _ in "ok" }

        // WebSocket
        app.webSocket("ws") { req, ws in
            guard
                let code = req.query[String.self, at: "room"]?.uppercased(),
                let name = req.query[String.self, at: "name"], !name.trimmingCharacters(in: .whitespaces).isEmpty
            else {
                ws.send("error: missing room or name")
                ws.close(promise: nil)
                return
            }

            let p = manager.addPlayer(name: name, to: code)
            manager.sockets[p.id] = ws

            // send snapshot
            let r = manager.room(for: code)
            if let text = try? String(data: JSONEncoder().encode(Outbound.room(r.sroom())), encoding: .utf8) {
                ws.send(text)
            }
            broadcastSystem("joined:\(name)", in: code, via: manager)

            // receive
            ws.onText { ws, text in
                app.logger.debug("WS(\(name)) -> \(text)")
                guard let r = manager.rooms[code] else { return }

                // Try parse JSON map
                if let data = text.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

                    // 0) Assign roles from host
                    if let t = obj["type"] as? String, t == "assign",
                       let roles = obj["roles"] as? [String:String] {
                        for (idStr, roleRaw) in roles {
                            if let id = UUID(uuidString: idStr), var pi = r.players[id] {
                                pi.role = roleRaw
                                r.players[id] = pi
                            }
                        }
                        r.started = true
                        broadcast(.room(r.sroom()), in: code, via: manager)
                        broadcastSystem("phase:night", in: code, via: manager)
                        return
                    }

                    // 1) Phase change (host)
                    if let phase = obj["phase"] as? String, (phase == "night" || phase == "day") {
                        broadcastSystem("phase:\(phase)", in: code, via: manager)
                        return
                    }

                    // 2) Chat
                    if let msg = obj["chat"] as? String {
                        broadcast(.chat(msg), in: code, via: manager)
                        return
                    }

                    // 3) Votes (anonymous)
                    if let type = obj["type"] as? String, type == "vote",
                       let target = obj["target"] as? String {
                        r.day.add(target)
                        broadcastSystem("vote:target:\(target):from:\(name)", in: code, via: manager)
                        return
                    }

                    // 4) Mayor tie-break
                    if let type = obj["type"] as? String, type == "tie_break",
                       let target = obj["target"] as? String {
                        // Mayor decides -> broadcast and clear day
                        broadcastSystem("day:tiebreak:\(target):from:\(name)", in: code, via: manager)
                        r.day.clear()
                        return
                    }

                    // 5) Night actions (authoritative)
                    if let type = obj["type"] as? String, type == "action",
                       let role = obj["role"] as? String,
                       let op = obj["op"] as? String {
                        let targetStr = obj["target"] as? String
                        let fromID = p.id

                        func result(_ s: String) { broadcastSystem("result:\(s)", in: code, via: manager) }

                        // Ensure player alive & role matches
                        guard let actualRole = r.players[fromID]?.role, actualRole == role, r.players[fromID]?.alive == true else {
                            result("error:forbidden_action_by:\(fromID.uuidString)")
                            return
                        }

                        // Doctor self-heal limit: only once per game
                        if role == "doctor",
                           op == "protect",
                           let tStr = targetStr, let target = UUID(uuidString: tStr) {
                            if fromID == target {
                                var pi = r.players[fromID]!
                                if pi.selfHealsUsed >= 1 {
                                    result("doctor:selfheal_denied:\(fromID.uuidString)")
                                    return
                                }
                                pi.selfHealsUsed += 1
                                r.players[fromID] = pi
                            }
                            r.night.protects.append(target)
                            result("doctor:protect:\(target.uuidString)")
                            return
                        }

                        if role == "grandma" {
                            if op == "arm" {
                                r.night.armedGrandmas.insert(fromID)
                                result("grandma:armed:\(fromID.uuidString)")
                            } else {
                                result("grandma:skip:\(fromID.uuidString)")
                            }
                            return
                        }

                        if role == "cupid" {
                            if op == "link", let tStr = targetStr, let target = UUID(uuidString: tStr) {
                                // link cupid <-> target
                                r.players[fromID]?.linkPartner = target
                                r.players[target]?.linkPartner = fromID
                                result("cupid:linked:\(target.uuidString):with:\(fromID.uuidString)")
                            } else {
                                result("cupid:skip:\(fromID.uuidString)")
                            }
                            return
                        }

                        if role == "vigilante" {
                            if r.nightIndex < 2 {
                                result("vigilante:too_early:\(fromID.uuidString)")
                                return
                            }
                            if op == "shoot", let tStr = targetStr, let target = UUID(uuidString: tStr) {
                                r.night.vigilanteShots.append(target)
                                result("vigilante:shot:\(target.uuidString)")
                            } else {
                                result("vigilante:skip:\(fromID.uuidString)")
                            }
                            return
                        }

                        if role == "detective" {
                            if op == "inspect", let tStr = targetStr, let target = UUID(uuidString: tStr),
                               let roleRaw = r.players[target]?.role {
                                let align = r.alignment(of: roleRaw).rawValue
                                result("detective:\(target.uuidString):\(roleRaw):\(align)")
                            } else {
                                result("detective:skip:\(fromID.uuidString)")
                            }
                            return
                        }

                        if role == "mafia" {
                            if op == "kill", let tStr = targetStr, let target = UUID(uuidString: tStr) {
                                r.night.mafiaTargets.append(target)
                                result("mafia:queued:\(target.uuidString)")
                            } else {
                                result("mafia:skip:\(fromID.uuidString)")
                            }
                            return
                        }

                        // Unknown role/op
                        result("ignored:\(role):\(op)")
                        return
                    }

                    // 6) Start flag from host
                    if let start = obj["start"] as? Bool, start == true {
                        r.started = true
                        broadcast(.room(r.sroom()), in: code, via: manager)
                        broadcastSystem("phase:night", in: code, via: manager)
                        return
                    }
                } // end JSON map branch

                // Non-JSON "start"
                if text.trimmingCharacters(in: .whitespacesAndNewlines) == "start" {
                    r.started = true
                    broadcast(.room(r.sroom()), in: code, via: manager)
                    broadcastSystem("phase:night", in: code, via: manager)
                    return
                }
            } // onText

            ws.onClose.whenComplete { _ in
                manager.removePlayer(p.id)
                broadcastSystem("left:\(name)", in: code, via: manager)
            }
        }

        // Endpoint to resolve night (host calls via webhook or you can wire a JSON "resolve_night")
        app.post("resolve_night") { req async throws -> HTTPStatus in
            struct Payload: Content { let code: String }
            let payload = try req.content.decode(Payload.self)
            guard let r = manager.rooms[payload.code] else { return .notFound }

            func log(_ s: String) { broadcastSystem(s, in: r.code, via: manager) }

            // Resolve
            let deaths = resolveNight(r, log: log)
            // Apply deaths
            for id in deaths {
                if var pi = r.players[id], pi.alive {
                    pi.alive = false
                    r.players[id] = pi
                }
            }
            // Win check
            let mafia = r.mafiaAliveCount()
            let town  = r.townAliveCount()
            if mafia == 0 {
                broadcastSystem("win:town", in: r.code, via: manager)
            } else if mafia >= town {
                broadcastSystem("win:mafia", in: r.code, via: manager)
            }

            // Clear night, advance to day
            r.night = NightActions()
            r.nightIndex += 1
            broadcastSystem("phase:day", in: r.code, via: manager)
            return .ok
        }

        // Endpoint to finalize day votes (host triggers)
        app.post("finalize_day") { req async throws -> HTTPStatus in
            struct Payload: Content { let code: String }
            let payload = try req.content.decode(Payload.self)
            guard let r = manager.rooms[payload.code] else { return .notFound }

            let sorted = r.day.top()
            guard let top = sorted.first else {
                // no votes -> skip
                broadcastSystem("day:skip", in: r.code, via: manager)
                r.day.clear()
                broadcastSystem("phase:night", in: r.code, via: manager)
                return .ok
            }
            let topVal = top.1
            let tied = sorted.filter { $0.1 == topVal }
            if tied.count > 1 {
                // wait for mayor tie_break
                broadcastSystem("day:tie:\(tied.map{$0.0}.joined(separator: \",\"))", in: r.code, via: manager)
                return .ok
            }

            // resolve winner
            if top.0 == "skip" {
                broadcastSystem("day:skip", in: r.code, via: manager)
            } else if let id = UUID(uuidString: top.0), var pi = r.players[id], pi.alive {
                pi.alive = false
                r.players[id] = pi
                broadcastSystem("day:lynched:\(id.uuidString)", in: r.code, via: manager)
            }

            // Win check
            let mafia = r.mafiaAliveCount()
            let town  = r.townAliveCount()
            if mafia == 0 {
                broadcastSystem("win:town", in: r.code, via: manager)
            } else if mafia >= town {
                broadcastSystem("win:mafia", in: r.code, via: manager)
            }

            r.day.clear()
            broadcastSystem("phase:night", in: r.code, via: manager)
            return .ok
        }

        try app.run()
    }
}
