//
//  YunXiOS · 云析 iOS 版
//  解析逻辑移植自 YunX (https://github.com/CYQawa/YunX, AGPL-3.0)
//

import SwiftUI

@main
struct YunXiOSApp: App {
    @StateObject private var store = DownloadStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
    }
}

// MARK: - 模型

enum MediaKind {
    case video
    case image
    case audio
    case file

    var label: String {
        switch self {
        case .video: return "视频"
        case .image: return "图片"
        case .audio: return "音频"
        case .file: return "文件"
        }
    }
}

struct MediaItem: Identifiable {
    let id = UUID()
    var url: URL
    var kind: MediaKind
    var fileName: String
    var headers: [String: String]
    var quality: String = ""
    var selected: Bool = true
}

struct ParseResult: Identifiable {
    let id = UUID()
    var platform: Platform
    var title: String
    var author: String
    var avatar: URL?
    var cover: URL?
    var text: String
    var pageURL: URL?
    var medias: [MediaItem]
}

enum ParseError: LocalizedError {
    case unsupported(String)
    case blocked(String)
    case notFound(String)
    case network(String)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let m): return m.isEmpty ? "该链接暂不支持解析" : m
        case .blocked(let m): return m.isEmpty ? "被平台风控拦截，请稍后再试" : m
        case .notFound(let m): return m.isEmpty ? "内容不存在或已删除" : m
        case .network(let m): return m.isEmpty ? "网络请求失败" : m
        case .unknown(let m): return m.isEmpty ? "解析失败" : m
        }
    }
}

// MARK: - 平台

enum Platform: String, CaseIterable, Identifiable, Codable {
    case kuaishou
    case weibo
    case acfun
    case douyin
    case xhs
    case bilibili
    case pixiv
    case lanzou
    case quark
    case uc
    case xunlei
    case baidu
    case c139
    case pan123
    case pan115
    case guangya
    case ilanzou

    var id: String { rawValue }

    var display: String {
        switch self {
        case .kuaishou: return "快手"
        case .weibo: return "微博"
        case .acfun: return "AcFun"
        case .douyin: return "抖音"
        case .xhs: return "小红书"
        case .bilibili: return "哔哩哔哩"
        case .pixiv: return "Pixiv"
        case .lanzou: return "蓝奏云"
        case .quark: return "夸克网盘"
        case .uc: return "UC 网盘"
        case .xunlei: return "迅雷网盘"
        case .baidu: return "百度网盘"
        case .c139: return "139 网盘"
        case .pan123: return "123 云盘"
        case .pan115: return "115 网盘"
        case .guangya: return "光鸭云盘"
        case .ilanzou: return "蓝奏云优享版"
        }
    }

    var color: Color {
        switch self {
        case .kuaishou: return .orange
        case .weibo: return .red
        case .acfun: return .pink
        case .douyin: return .black
        case .xhs: return .red
        case .bilibili: return .blue
        case .pixiv: return .cyan
        case .lanzou: return .indigo
        case .quark: return .blue
        case .uc: return .teal
        case .xunlei: return .blue
        case .baidu: return .blue
        case .c139: return .green
        case .pan123: return .orange
        case .pan115: return .blue
        case .guangya: return .purple
        case .ilanzou: return .cyan
        }
    }
}

// MARK: - 链接识别（移植 VideoLinkParser）

struct DetectedLink {
    var platform: Platform
    var kind: String
    var id: String
    var url: URL
    var isShort: Bool
}

enum LinkDetector {

    private static let trailing = "。，,；;)]}\"'、！？…"

    private struct Rule {
        var platform: Platform
        var kind: String
        var pattern: String
    }

    private static let rules: [Rule] = [
        Rule(platform: .kuaishou, kind: "short", pattern: #"v\.kuaishou\.com/[A-Za-z\d._?%&+\-=/#]+"#),
        Rule(platform: .kuaishou, kind: "photo", pattern: #"(?:www\.)?kuaishou\.com/(?:short-video|fw/photo|fw/long-video)/([A-Za-z\d]+)"#),
        Rule(platform: .kuaishou, kind: "photo", pattern: #"(?:www\.)?kuaishou\.com/f/([A-Za-z\d]+)"#),
        Rule(platform: .kuaishou, kind: "photo", pattern: #"(?:v\.m\.)?chenzhongtech\.com/fw/(?:photo|long-video)/([A-Za-z\d]+)"#),
        Rule(platform: .weibo, kind: "tv", pattern: #"weibo\.com/tv/show/\d{4}:\d+\?mid=(\d+)"#),
        Rule(platform: .weibo, kind: "fid", pattern: #"video\.weibo\.com/show\?fid=(\d+:\d+)"#),
        Rule(platform: .weibo, kind: "status", pattern: #"weibo\.cn/(?:status|statuses|detail)/([0-9a-zA-Z]+)"#),
        Rule(platform: .weibo, kind: "status", pattern: #"weibo\.com/\d+/([0-9a-zA-Z]{6,})"#),
        Rule(platform: .acfun, kind: "ac", pattern: #"acfun\.cn/.*(?:ac=|/ac)(\d+)"#),
        Rule(platform: .douyin, kind: "short", pattern: #"v\.douyin\.com/[A-Za-z0-9_\-]+"#),
        Rule(platform: .douyin, kind: "video", pattern: #"(?:www\.)?douyin\.com/(video|note)/(\d{10,})"#),
        Rule(platform: .douyin, kind: "video", pattern: #"douyin\.com/[^\s]*[?&]modal_id=(\d{10,})"#),
        Rule(platform: .xhs, kind: "short", pattern: #"xhslink\.(?:com|cn)/[A-Za-z0-9._?%&+=/#@\-]+"#),
        Rule(platform: .xhs, kind: "note", pattern: #"xiaohongshu\.com/(?:explore|discovery/item|discovery)/([0-9a-zA-Z]{10,})"#),
        Rule(platform: .bilibili, kind: "short", pattern: #"b23\.tv/[A-Za-z\d]+"#),
        Rule(platform: .bilibili, kind: "video", pattern: #"bilibili\.com/video/(BV[0-9a-zA-Z]{10}|av\d+)"#),
        Rule(platform: .pixiv, kind: "artwork", pattern: #"pixiv\.net/(?:[a-z]{2}/)?artworks/(\d+)"#)
    ]

    static func firstURL(in text: String) -> URL? {
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s]+"#) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var raw = ns.substring(with: match.range)
        while let last = raw.last, trailing.contains(last) { raw.removeLast() }
        guard let url = URL(string: raw), let scheme = url.scheme, scheme.hasPrefix("http") else { return nil }
        return url
    }

    static func detect(_ text: String) -> DetectedLink? {
        guard let url = firstURL(in: text) else { return nil }
        let absolute = url.absoluteString
        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]) else { continue }
            let ns = absolute as NSString
            guard let match = regex.firstMatch(in: absolute, range: NSRange(location: 0, length: ns.length)) else { continue }
            var identifier = ""
            if match.numberOfRanges > 1 {
                for index in stride(from: match.numberOfRanges - 1, through: 1, by: -1) {
                    let candidate = ns.substring(with: match.range(at: index))
                    if !candidate.isEmpty { identifier = candidate; break }
                }
            }
            let isShort = rule.kind == "short"
            return DetectedLink(platform: rule.platform, kind: rule.kind, id: isShort ? "" : identifier, url: url, isShort: isShort)
        }
        return nil
    }
}

// MARK: - HTTP

struct HttpResult {
    var status: Int
    var body: String
    var headers: [String: String]
    var finalURL: URL?
}

final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum Http {

    static let uaChrome = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    static let uaIphone = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    private static let noRedirectSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpShouldSetCookies = false
        return URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }()

    static func get(_ url: URL, headers: [String: String] = [:], followRedirects: Bool = true) async throws -> HttpResult {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(uaChrome, forHTTPHeaderField: "User-Agent")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let session = followRedirects ? URLSession(configuration: .ephemeral) : noRedirectSession
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ParseError.network("响应不是 HTTP")
        }
        var headerMap: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let k = key as? String, let v = value as? String { headerMap[k.lowercased()] = v }
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        return HttpResult(status: http.statusCode, body: body, headers: headerMap, finalURL: http.url)
    }

    static func postForm(_ url: URL, form: [String: String], headers: [String: String] = [:]) async throws -> HttpResult {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(uaChrome, forHTTPHeaderField: "User-Agent")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = form.map { key, value in
            "\(key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
        request.httpBody = encoded.data(using: .utf8)
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ParseError.network("响应不是 HTTP") }
        return HttpResult(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "", headers: [:], finalURL: http.url)
    }

    static func expandRedirect(_ url: URL, headers: [String: String]) async -> URL {
        if let result = try? await get(url, headers: headers, followRedirects: false),
           result.status >= 300, result.status < 400,
           let location = result.headers["location"],
           let next = URL(string: location, relativeTo: url) {
            return next
        }
        return url
    }

    static func extractInlineJson(_ html: String, key: String) -> String? {
        let pattern = NSRegularExpression.escapedPattern(for: key) + #"\s*=\s*(.*?)</script>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
        let ns = html as NSString
        guard let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)), match.numberOfRanges > 1 else { return nil }
        return ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func unescapeQuotes(_ text: String) -> String {
        text.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\/", with: "/")
    }

    static func secureURL(_ raw: String) -> String {
        if raw.hasPrefix("//") { return "https:" + raw }
        if raw.hasPrefix("http://") { return "https://" + raw.replacingOccurrences(of: "http://", with: "") }
        return raw
    }
}

// MARK: - 解析服务

enum ParseService {

    static func parse(text: String) async throws -> ParseResult? {
        if let share = NetdiskDetector.detect(text) {
            switch share.platform {
            case .lanzou:
                guard let url = LinkDetector.firstURL(in: text) else {
                    throw ParseError.unknown("链接不合法")
                }
                return try await LanzouParser.parse(url: url, pwd: share.pwd)
            case .quark:
                return try await QuarkParser.parse(shareID: share.shareID, pwd: share.pwd)
            case .xunlei:
                return try await XunleiService.parse(shareID: share.shareID, passCode: share.pwd)
            case .uc:
                return try await UCParser.parse(shareID: share.shareID, pwd: share.pwd)
            case .pan115:
                return try await Pan115Parser.parse(shareID: share.shareID, pwd: share.pwd)
            default:
                throw ParseError.unsupported("识别到\(share.platform.display)分享（\(share.shareID)）。该网盘要先用账号 Cookie / JWT 登录才能取链，这一版还没接 —— 下一版按平台逐个补。")
            }
        }
        guard let link = LinkDetector.detect(text) else { return nil }
        switch link.platform {
        case .kuaishou:
            let parsed = try await KuaishouParser.parse(link: link)
            return await KuaishouVideoFix.enrich(link: link, result: parsed)
        case .weibo:
            return try await WeiboParser.parse(link: link)
        case .acfun:
            throw ParseError.unsupported("AcFun 是 m3u8 分片流，iOS 版这一版还没接 HLS 下载")
        case .douyin:
            throw ParseError.unsupported("抖音解析需要签名参数，这一版还没接（下一版补）")
        case .xhs:
            throw ParseError.unsupported("小红书需要登录态，这一版还没接（下一版补）")
        case .bilibili:
            throw ParseError.unsupported("哔哩哔哩需要 DASH 合轨，这一版还没接（下一版补）")
        case .pixiv:
            throw ParseError.unsupported("Pixiv 需要登录 Cookie，这一版还没接（下一版补）")
        case .lanzou:
            return try await LanzouParser.parse(url: link.url, pwd: nil)
        case .quark:
            return try await QuarkParser.parse(shareID: link.id.isEmpty ? "0" : link.id, pwd: nil)
        case .xunlei:
            return try await XunleiService.parse(shareID: link.id.isEmpty ? "0" : link.id, passCode: nil)
        case .baidu, .c139, .pan123, .guangya, .ilanzou:
            throw ParseError.unsupported("\(link.platform.display)解析器还没接（下一版逐个补）")
        }
    }
}

// MARK: - 通用小工具

enum NameUtil {
    static func sanitize(_ raw: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let cleaned = raw.components(separatedBy: illegal).joined(separator: "_")
        return String(cleaned.prefix(80))
    }

    static func fallback(_ platform: Platform, _ identifier: String) -> String {
        "\(platform.display)_\(identifier.isEmpty ? "link" : identifier)"
    }
}

private func jsonString(_ dict: [String: Any]?, _ key: String) -> String {
    guard let value = dict?[key] as? String, value != "null" else { return "" }
    return value
}
