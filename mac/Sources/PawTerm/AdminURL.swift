import Foundation

enum AdminURL {
    static func adminURL(port: Int, loginCode: String, view: String? = nil) -> URL? {
        var comps = URLComponents(string: "http://localhost:\(port)/admin")
        var items = [URLQueryItem(name: "admin_login_code", value: loginCode)]
        if let view { items.append(URLQueryItem(name: "view", value: view)) }
        comps?.queryItems = items
        return comps?.url
    }
}
