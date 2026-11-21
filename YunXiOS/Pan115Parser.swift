import Foundation

enum Pan115Config {
    static let apiBase = "https://webapi.115.com"
    static let snapURL = apiBase + "/share/snap"
    static let shareDownloadURL = apiBase + "/share/downurl"
    static let appVersionURL = "https://appversion.115.com/1/web/1.0/api/chrome"
    static let webUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36"
    static let cookieKey = "pan115"
    static let shareHost = "https://115cdn.com"
}

enum Pan115Parser {

    private struct PFile {
        var fid: String
        var name: String
        var size: Int64
        var isDir: Bool
    }

    private static var clientUA = "Mozilla/5.0 115Browser/36.0.1"

    static func parse(shareID: String, pwd: String?) async throws -> ParseResult {
        let cookie = NetdiskCookieStore.get(Pan115Config.cookieKey)
        guard !cookie.isEmpty else {
            throw ParseError.blocked("115 需要登录：请在 设置 → 网盘账号 → 115 账号 网页登录后再解析")
        }
        try await refreshClientUA()
        var page = try await sharePage(shareCode: shareID, receiveCode: pwd ?? "", cid: "0", cookie: cookie)
        if page.files.count == 1, page.files[0].isDir {
            page = try await sharePage(shareCode: shareID, receiveCode: pwd ?? "", cid: page.files[0].fid, cookie: cookie)
        }
        let downloadable = page.files.filter { !$0.isDir }
        guard !downloadable.isEmpty else { throw ParseError.notFound("这个 115 分享里没有可下载的文件") }
        var medias: [MediaItem] = []
        var lastError: Error?
        for file in downloadable.prefix(10) {
            do {
                let link = try await downloadLink(shareCode: shareID, receiveCode: pwd ?? "", userId: page.userId, file: file, cookie: cookie)
                medias.append(MediaItem(url: link.url,
                                        kind: MediaKind.from(fileName: file.name),
                                        fileName: file.name.isEmpty ? "115_\(file.fid)" : file.name,
                                        headers: link.headers))
            } catch { lastError = error }
        }
        guard !medias.isEmpty else { throw lastError ?? ParseError.unknown("115 没取到直链") }
        return ParseResult(
            platform: .pan115,
            title: page.title.isEmpty ? "115 分享 \(shareID)" : page.title,
            author: "115 网盘（已登录）",
            avatar: nil,
            cover: nil,
            text: "共 \(downloadable.count) 个文件，已取链 \(medias.count) 个",
            pageURL: URL(string: "https://115cdn.com/s/\(shareID)"),
            medias: medias
        )
    }

    private struct Page {
        var files: [PFile]
        var userId: String
        var title: String
    }

    private static func sharePage(shareCode: String, receiveCode: String, cid: String, cookie: String) async throws -> Page {
        var components = URLComponents(string: Pan115Config.snapURL)!
        components.queryItems = [
            URLQueryItem(name: "share_code", value: shareCode),
            URLQueryItem(name: "receive_code", value: receiveCode),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "limit", value: "100"),
            URLQueryItem(name: "asc", value: "0"),
            URLQueryItem(name: "cid", value: cid),
            URLQueryItem(name: "format", value: "json")
        ]
        let referer = receiveCode.isEmpty
            ? "\(Pan115Config.shareHost)/s/\(shareCode)"
            : "\(Pan115Config.shareHost)/s/\(shareCode)?password=\(receiveCode)&"
        let result = try await Http.get(components.url!, headers: [
            "User-Agent": Pan115Config.webUA,
            "Accept": "application/json, text/plain, */*",
            "X-Requested-With": "XMLHttpRequest",
            "Referer": referer,
            "Cookie": cookie
        ])
        guard let data = result.body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.unknown("115 分享接口返回非 JSON（HTTP \(result.status)）")
        }
        if let state = json["state"] as? Bool, !state {
            let message = (json["error"] as? String) ?? "115 分享读取失败（可能需要提取码或分享失效）"
            throw ParseError.blocked(message)
        }
        guard let payload = json["data"] as? [String: Any] else {
            throw ParseError.notFound("115 分享为空或需要提取码")
        }
        let shareInfo = payload["shareinfo"] as? [String: Any]
        let title = (shareInfo?["share_title"] as? String) ?? ""
        var userId = ""
        if let user = payload["userinfo"] as? [String: Any] {
            if let value = user["user_id"] as? String { userId = value }
            else if let number = user["user_id"] as? NSNumber { userId = number.stringValue }
        }
        let list = payload["list"] as? [[String: Any]] ?? []
        let files = list.compactMap { item -> PFile? in
            let fid = (item["fid"] as? String) ?? ""
            let isDir = (item["fc"] as? NSNumber)?.intValue == 0
            let id = isDir ? ((item["cid"] as? String) ?? "") : fid
            guard !id.isEmpty else { return nil }
            return PFile(fid: id,
                         name: (item["n"] as? String) ?? "",
                         size: (item["s"] as? NSNumber)?.int64Value ?? 0,
                         isDir: isDir)
        }
        return Page(files: files, userId: userId, title: title)
    }

    private static func downloadLink(shareCode: String, receiveCode: String, userId: String, file: PFile, cookie: String) async throws -> (url: URL, headers: [String: String]) {
        guard !userId.isEmpty else { throw ParseError.unknown("115 分享缺少分享者 user_id") }
        var components = URLComponents(string: Pan115Config.shareDownloadURL)!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "dl", value: "1"),
            URLQueryItem(name: "user_id", value: userId),
            URLQueryItem(name: "share_code", value: shareCode),
            URLQueryItem(name: "file_id", value: file.fid)
        ]
        if !receiveCode.isEmpty { items.append(URLQueryItem(name: "receive_code", value: receiveCode)) }
        components.queryItems = items
        let referer = receiveCode.isEmpty
            ? "\(Pan115Config.shareHost)/s/\(shareCode)"
            : "\(Pan115Config.shareHost)/s/\(shareCode)?password=\(receiveCode)&"
        let result = try await Http.get(components.url!, headers: [
            "User-Agent": clientUA,
            "Accept": "application/json, text/plain, */*",
            "X-Requested-With": "XMLHttpRequest",
            "Referer": referer,
            "Cookie": cookie
        ])
        guard let data = result.body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.unknown("115 取链返回非 JSON（HTTP \(result.status)）")
        }
        if let state = json["state"] as? Bool, !state {
            let message = (json["error"] as? String) ?? "115 取链失败"
            throw ParseError.blocked(message)
        }
        let payload = json["data"] as? [String: Any] ?? [:]
        var raw = (payload["file_url_302"] as? String) ?? ""
        if raw.isEmpty { raw = (payload["file_url"] as? String) ?? "" }
        if raw.isEmpty, let urlDict = payload["url"] as? [String: Any] { raw = (urlDict["url"] as? String) ?? "" }
        guard let url = URL(string: raw), !raw.isEmpty else {
            throw ParseError.unknown("115 没返回下载地址")
        }
        return (url, ["User-Agent": clientUA, "Referer": referer, "Cookie": cookie])
    }

    private static func refreshClientUA() async throws {
        if let result = try? await Http.get(URL(string: Pan115Config.appVersionURL)!, headers: [:])
           , let data = result.body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let win = json["data"] as? [String: Any],
           let info = win["win"] as? [String: Any],
           let code = info["version_code"] as? String,
           code.first?.isNumber == true, code.count <= 16 {
            clientUA = "Mozilla/5.0 115Browser/\(code)"
        }
    }
}
