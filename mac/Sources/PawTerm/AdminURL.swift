import Foundation

enum AdminURL {
    /// Re-reads ~/.config/pawterm/config.json on each call so token changes
    /// after server restart are picked up without restarting the .app.
    static func loadConfig() -> (port: Int, token: String)? {
        let configPath = "\(NSHomeDirectory())/.config/pawterm/config.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let port = json["port"] as? Int ?? 8765
        guard let token = json["token"] as? String, !token.isEmpty else { return nil }
        return (port, token)
    }

    static func adminURL() -> URL? {
        guard let c = loadConfig() else { return nil }
        return URL(string: "http://localhost:\(c.port)/admin?token=\(c.token)")
    }
}
