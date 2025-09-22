import Vapor

public func configure(_ app: Application) throws {
    app.http.server.configuration.hostname = "0.0.0.0"
    app.http.server.configuration.port = Int(Environment.get("PORT") ?? "8080") ?? 8080

    app.webSocketPingInterval = .seconds(25)

    app.get("health") { _ in "ok" }

    try routes(app)
}
