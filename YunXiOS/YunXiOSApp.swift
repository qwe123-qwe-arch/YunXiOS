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

    var label: String {
        switch self {
        case .video: return "视频"
        case .image: return "图片"
        case .audio: return "音频"
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

    var id: String { rawValue }

    var display: String {
        switch self {
        case .kuaishou: return "快手"
        case .weibo: return "微博"
        case .acfun: return "AcFun"
        case .douyin: return "拖音"
        case .xhs: return "小红书"
        case .bilibili: return "喱哩喱哩"
        case .pixiv: return "Pixiv"
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

    private static let trailing = "。，,；;)]}\"‘、！？…"

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
        guard let link = LinkDetector.detect(text) else { return nil }
        switch link.platform {
        case .kuaishou:
            return try await KuaishouParser.parse(link: link)
        case .weibo:
            return try await WeiboParser.parse(link: link)
        case .acfun:
            throw ParseError.unsupported("AcFun 是 m3u8 分片流，iOS 版还没接 HLS 下载")
        case .douyin:
            throw ParseError.unsupported("拖音解析需要签名参数，这一版还没接")
        case .xhs:
            throw ParseError.unsupported("小红书需要登录态，这一版还没接")
        case .bilibili:
            throw ParseError.unsupported("喱哩喱哩需要 DASH 合轨，这一版还没接")
        case .pixiv:
            throw ParseError.unsupported("Pixiv 需要登录 Cookie，这一版还没接")
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

// MARK: - 快手解析

enum KuaishouParser {

    static func parse(link: DetectedLink) async throws -> ParseResult {
        let headers: [String: String] = [
            "User-Agent": Http.uaIphone,
            "Referer": "https://v.kuaishou.com/"
        ]

        var pageURL = await Http.expandRedirect(link.url, headers: headers)
        if pageURL.absoluteString.contains("/fw/long-video/") {
            pageURL = URL(string: pageURL.absoluteString.replacingOccurrences(of: "/fw/long-video/", with: "/fw/photo/")) ?? pageURL
        }

        let response = try await Http.get(pageURL, headers: headers)
        guard response.status == 200 else {
            throw ParseError.network("快手页面返回 \(response.status)")
        }
        guard let initJSON = Http.extractInlineJson(response.body, key: "window.INIT_STATE") else {
            throw ParseError.unknown("页面里没有 window.INIT_STATE，可能改版或需要验证")
        }
        guard let rawData = initJSON.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any] else {
            throw ParseError.unknown("INIT_STATE 不是合法 JSON")
        }

        var photo: [String: Any]?
        for (_, value) in root {
            if let dict = value as? [String: Any], let candidate = dict["photo"] as? [String: Any] {
                photo = candidate
                break
            }
        }
        guard let photo = photo else {
            throw ParseError.notFound("作品不存在或已删除")
        }

        let title = jsonString(photo, "caption")
        let cleaned = NameUtil.sanitize(title)
        let base = cleaned.isEmpty ? NameUtil.fallback(.kuaishou, link.id) : cleaned

        var medias: [MediaItem] = []

        if let mvUrls = photo["mainMvUrls"] as? [[String: Any]],
           let urlString = firstURLString(mvUrls),
           let url = URL(string: Http.secureURL(urlString)) {
            medias.append(MediaItem(url: url, kind: .video, fileName: base + ".mp4", headers: headers))
        }

        if let atlas = (photo["ext_params"] as? [String: Any])?["atlas"] as? [String: Any],
           let cdnList = atlas["cdnList"] as? [[String: Any]],
           let routes = atlas["list"] as? [String] {
            let cdn = cdnList.first.flatMap { jsonString($0, "cdn") } ?? ""
            if !cdn.isEmpty {
                for (index, route) in routes.enumerated() where !route.isEmpty {
                    if let url = URL(string: Http.secureURL("https://\(cdn)/\(route)")) {
                        medias.append(MediaItem(url: url, kind: .image, fileName: "\(base)_\(index + 1).jpg", headers: headers))
                    }
                }
            }
        }

        guard !medias.isEmpty else {
            throw ParseError.notFound("这个作品里没有可下载的视频或图片")
        }

        var cover: URL?
        if let coverUrls = photo["coverUrls"] as? [[String: Any]], let raw = firstURLString(coverUrls) {
            cover = URL(string: Http.secureURL(raw))
        }

        var avatar: URL?
        let headURL = jsonString(photo, "headUrl")
        if !headURL.isEmpty { avatar = URL(string: Http.secureURL(headURL)) }

        return ParseResult(
            platform: .kuaishou,
            title: title.isEmpty ? base : title,
            author: jsonString(photo, "userName").replacingOccurrences(of: "\u{3164}", with: "").trimmingCharacters(in: .whitespaces),
            avatar: avatar,
            cover: cover,
            text: title,
            pageURL: link.url,
            medias: medias
        )
    }

    private static func firstURLString(_ nodes: [[String: Any]]) -> String? {
        for node in nodes {
            let value = jsonString(node, "url")
            if !value.isEmpty { return value }
        }
        return nil
    }
}

// MARK: - 微博解析

enum WeiboParser {

    static func parse(link: DetectedLink) async throws -> ParseResult {
        switch link.kind {
        case "status":
            return try await parseStatus(link: link, weiboID: link.id)
        case "tv":
            throw ParseError.unsupported("weibo.com/tv 链接暂不支持，请改用 weibo.com/用户ID/微博ID")
        case "fid":
            throw ParseError.unsupported("video.weibo.com 的 fid 链接暂不支持")
        default:
            throw ParseError.unsupported("未知的微博链接形态：\(link.kind)")
        }
    }

    private static func parseStatus(link: DetectedLink, weiboID: String) async throws -> ParseResult {
        guard !weiboID.isEmpty else { throw ParseError.unsupported("链接里没解析出微博 ID") }

        let headers: [String: String] = [
            "accept": "application/json, text/plain, */*",
            "referer": "https://m.weibo.cn/detail/\(weiboID)",
            "origin": "https://m.weibo.cn",
            "x-requested-with": "XMLHttpRequest",
            "mweibo-pwa": "1",
            "sec-fetch-site": "same-origin",
            "sec-fetch-mode": "cors",
            "sec-fetch-dest": "empty",
            "User-Agent": Http.uaChrome
        ]

        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        guard let url = URL(string: "https://m.weibo.cn/statuses/show?id=\(weiboID)&_=\(stamp)") else {
            throw ParseError.unknown("URL 构造失败")
        }

        let response = try await Http.get(url, headers: headers, followRedirects: false)
        if response.status != 200 {
            switch response.status {
            case 403, 418, 429:
                throw ParseError.blocked("微博返回 \(response.status)，触发了风控或验证页")
            case 404, 410:
                throw ParseError.notFound("微博返回 \(response.status)，内容不存在")
            default:
                throw ParseError.network("微博接口返回 \(response.status)")
            }
        }

        let contentType = response.headers["content-type"] ?? ""
        guard contentType.contains("application/json") else {
            throw ParseError.blocked("微博返回的不是 JSON（\(contentType)），大概率被风控")
        }

        guard let data = response.body.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.unknown("微博 JSON 解析失败")
        }
        guard let post = root["data"] as? [String: Any] else {
            throw ParseError.notFound("该微博不存在或已删除")
        }

        return try build(link: link, post: post, allowRetweet: true)
    }

    private static func build(link: DetectedLink, post: [String: Any], allowRetweet: Bool) throws -> ParseResult {
        let mediaHeaders: [String: String] = [
            "User-Agent": Http.uaChrome,
            "Referer": "https://weibo.com/"
        ]

        let pageInfo = post["page_info"] as? [String: Any]
        let title = jsonString(pageInfo, "title")
        let cleaned = NameUtil.sanitize(title)
        let base = cleaned.isEmpty ? NameUtil.fallback(.weibo, link.id) : cleaned

        var medias: [MediaItem] = []

        if let urls = pageInfo?["urls"] as? [String: Any] {
            var candidate = jsonString(urls, "mp4_720p_mp4")
            if candidate.isEmpty { candidate = jsonString(urls, "mp4_hd_mp4") }
            if candidate.isEmpty { candidate = jsonString(urls, "mp4_ld_mp4") }
            if !candidate.isEmpty, let url = URL(string: Http.secureURL(candidate)) {
                medias.append(MediaItem(url: url, kind: .video, fileName: base + ".mp4", headers: mediaHeaders))
            }
        }

        if let pics = post["pics"] as? [[String: Any]] {
            var index = 0
            for pic in pics {
                guard let large = pic["large"] as? [String: Any] else { continue }
                let raw = jsonString(large, "url")
                guard !raw.isEmpty, let url = URL(string: Http.secureURL(raw)) else { continue }
                index += 1
                medias.append(MediaItem(url: url,
                                        kind: .image,
                                        fileName: "\(base)_\(index).jpg",
                                        headers: mediaHeaders,
                                        quality: "原图"))
            }
        }

        if medias.isEmpty, allowRetweet, let retweeted = post["retweeted_status"] as? [String: Any] {
            return try build(link: link, post: retweeted, allowRetweet: false)
        }

        guard !medias.isEmpty else {
            throw ParseError.notFound("这条微博里没有可下载的视频或图片")
        }

        var cover: URL?
        if let pic = pageInfo?["page_pic"] as? [String: Any] {
            let raw = jsonString(pic, "url")
            if !raw.isEmpty { cover = URL(string: Http.secureURL(raw)) }
        }

        let user = post["user"] as? [String: Any]
        var avatar: URL?
        let avatarRaw = jsonString(user, "profile_image_url")
        if !avatarRaw.isEmpty { avatar = URL(string: Http.secureURL(avatarRaw)) }

        return ParseResult(
            platform: .weibo,
            title: title.isEmpty ? base : title,
            author: jsonString(user, "screen_name"),
            avatar: avatar,
            cover: cover,
            text: cleanText(jsonString(post, "text")),
            pageURL: link.url,
            medias: medias
        )
    }

    private static func cleanText(_ html: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<[^>]+>") else { return html }
        let ns = html as NSString
        let plain = regex.stringByReplacingMatches(in: html, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        return plain.replacingOccurrences(of: "&nbsp;", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
