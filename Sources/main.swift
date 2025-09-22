import Vapor

func routes(_ app: Application) throws {
    app.get { req in
        "Mafia Nights Server is running!"
    }

    app.webSocket("ws") { req, ws in
        ws.send("Connected to Mafia Nights Server!")
    }
}

public func configure(_ app: Application) throws {
    try routes(app)
}

import Vapor

var env = try Environment.detect()
let app = Application(env)
defer { app.shutdown() }
try configure(app)
try app.run()
