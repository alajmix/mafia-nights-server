import Vapor

public func configure(_ app: Application) throws {
    if let p = Environment.get("PORT"), let port = Int(p) {
        app.http.server.configuration.hostname = "0.0.0.0"
        app.http.server.configuration.port = port
    }
    try routes(app)
}
