# Mafia Nights Server (Vapor + WebSockets)

Endpoints:
- GET /health -> ok
- WS /ws?room=CODE&name=Ali

Broadcasts:
- {"room":{...}} snapshots
- {"system":"phase:night"} / "phase:day"
- {"system":"vote:target:<uuid-or-skip>:from:<name>"}
- {"chat":"..."}
