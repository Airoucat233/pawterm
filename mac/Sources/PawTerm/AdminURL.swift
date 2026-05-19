import Foundation

enum AdminURL {
    static func adminURL(port: Int, token: String) -> URL? {
        URL(string: "http://localhost:\(port)/admin?token=\(token)")
    }
}
