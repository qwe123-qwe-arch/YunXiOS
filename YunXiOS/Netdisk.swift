import Foundation

// MARK: - 网盘平台与分享链接识别（移植 ShareLinkParser）

enum NetdiskPlatform: String, CaseIterable, Identifiable {
    case quark
    case uc
    case xunlei
    case baidu
    case c139
    case pan123
    case pan115
    case guangya
    case ilanzou
    case lanzou

    var id: String { rawValue }

    var display: String {
        switch self {
        case .quark: return "夸克网盘"
        case .uc: return "UC 网盘"
        case .xunlei: return "迅雷网盘"
        case .baidu: return "百度网盘"
        case .c139: return "139 网盘"
        case .pan123: return "123 云盘"
        case .pan115: return "115 网盘"
        case .guangya: return "光鸭云盘"
        case .ilanzou: return "蓝奏云优享版"
        case .lanzou: return "蓝奏云"
        }
    }

    /// 只有蓝奏云的分享可以匿名解析；其余都要先登录拿 Cookie / JWT。
    var needsLogin: Bool { self != .lanzou }
}

struct NetdiskShare {
    var platform: NetdiskPlatform
    var shareID: String
    var pwd: String?
}

enum NetdiskDetector {

    private struct Rule {
        var platform: NetdiskPlatform
        var pattern: String
        var group: Int
    }

    private static let rules: [Rule] = [
        Rule(platform: .quark, pattern: #"pan\.quark\.cn/s/([A-Za-z0-9]+)"#, group: 1),
        Rule(platform: .uc, pattern: #"drive\.uc\.cn/s/([A-Za-z0-9]+)"#, group: 1),
        Rule(platform: .xunlei, pattern: #"pan\.xunlei\.com/s/([A-Za-z0-9_-]+)"#, group: 1),
        Rule(platform: .baidu, pattern: #"pan\.baidu\.com/s/(1[A-Za-z0-9_-]+)"#, group: 1),
        Rule(platform: .c139, pattern: #"yun\.139\.com/shareweb/.*?/w/i/([A-Za-z0-9_-]+)"#, group: 1),
        Rule(platform: .pan123, pattern: #"123(?:865|pan)\.(?:com|cn)/s/([A-Za-z0-9]+-[A-Za-z0-9]+)"#, group: 1),
        Rule(platform: .pan123, pattern: #"share\.123pan\.cn/123pan/([A-Za-z0-9-]+)"#, group: 1),
        Rule(platform: .pan123, pattern: #"api/srr\?sk=([A-Za-z0-9-]+)"#, group: 1),
        Rule(platform: .pan115, pattern: #"115(?:cdn|rc)?\.com/s/(sw[A-Za-z0-9]+)"#, group: 1),
        Rule(platform: .guangya, pattern: #"guangyapan\.com/s/([A-Za-z0-9_-]+)"#, group: 1),
        Rule(platform: .ilanzou, pattern: #"(?:^|[/.])ilanzou\.(?:com|net|org|cn)/s/([A-Za-z0-9_-]+)"#, group: 1),
        Rule(platform: .lanzou, pattern: #"(?:^|[/.])(?:lanzou[a-z0-9-]*|lan[zs]o[ux]|lanzn)\.(?:com|net|org|cn)/([A-Za-z0-9]+)"#, group: 1)
    ]

    static func detect(_ text: String) -> NetdiskShare? {
        guard let url = LinkDetector.firstURL(in: text) else { return nil }
        let absolute = url.absoluteString

        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]) else { continue }
            let ns = absolute as NSString
            guard let match = regex.firstMatch(in: absolute, range: NSRange(location: 0, length: ns.length)),
                  match.numberOfRanges > rule.group else { continue }
            let shareID = ns.substring(with: match.range(at: rule.group))
            guard !shareID.isEmpty else { continue }
            return NetdiskShare(platform: rule.platform, shareID: shareID, pwd: extractPwd(text: text, url: absolute, platform: rule.platform))
        }
        return nil
    }

    private static func extractPwd(text: String, url: String, platform: NetdiskPlatform) -> String? {
        let patterns: [String]
        switch platform {
        case .lanzou, .ilanzou:
            patterns = [#"[?&](?:pwd|pass|passcode|password)=([A-Za-z0-9]+)"#]
        case .pan115:
            patterns = [#"[?&]password=([A-Za-z0-9]+)"#, #"(?:访问码|提取码)[：:]\s*([A-Za-z0-9]{4,8})"#]
        default:
            patterns = [#"[?&]pwd=([A-Za-z0-9]+)"#]
        }

        for pattern in patterns {
            if let value = firstGroup(pattern, in: url, options: [.caseInsensitive]) { return value }
        }
        if let value = firstGroup(#"(?:提取码|访问码|密码)[：:]\s*([A-Za-z0-9]{4,8})"#, in: text) { return value }
        return nil
    }

    private static func firstGroup(_ pattern: String, in text: String, options: NSRegularExpression.Options = []) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return nil }
        let value = ns.substring(with: match.range(at: 1))
        return value.isEmpty ? nil : value
    }
}

// MARK: - 蓝奏云单文件分享解析（匿名）

enum LanzouParser {

    static func parse(url: URL, pwd: String?) async throws -> ParseResult {
        let host = url.host ?? ""
        guard !host.isEmpty else { throw ParseError.unknown("链接里没有域名") }
        let origin = "https://\(host)"
        let shareURL = url.absoluteString

        let headers: [String: String] = [
            "User-Agent": Http.uaChrome,
            "Referer": origin + "/"
        ]

        let page = try await Http.get(url, headers: headers)
        guard page.status == 200 else {
            throw ParseError.network("蓝奏云分享页返回 \(page.status)")
        }
        let html = page.body

        let title = extractTitle(html)
        let needsPwd = html.contains("请输入密码") || html.contains("id=\"pwbox\"") || html.contains("function down_p(")
        if needsPwd, (pwd ?? "").isEmpty {
            throw ParseError.unsupported("这个分享需要提取码，请在链接后面补上 ?pwd=xxxx 再解析")
        }
        if html.contains("文件不存在") || html.contains("已删除") {
            throw ParseError.notFound("分享已删除或不存在")
        }

        guard let fileID = firstGroup(#"(?:ajaxm|ajaxfile)\.php\?file=(\d+)"#, in: html)
                ?? firstGroup(#"name=[\"']file[\"']\s+value=[\"'](\d+)[\"']"#, in: html)
                ?? firstGroup(#"file=(\d+)"#, in: html) else {
            throw ParseError.unknown("没在分享页里找到文件 ID（可能是文件夹分享，这一版只支持单文件）")
        }

        guard let sign = firstGroup(#"sign\s*[:=]\s*['\"]([^'\"]+)['\"]"#, in: html) else {
            throw ParseError.unknown("没找到下载签名 sign")
        }

        let endpoint = URL(string: "\(origin)/ajaxm.php?file=\(fileID)")!
        var form: [String: String] = [
            "action": "downprocess",
            "sign": sign,
            "ves": "1"
        ]
        if let pwd = pwd, !pwd.isEmpty { form["pwd"] = pwd }

        let response = try await Http.postForm(endpoint, form: form, headers: [
            "User-Agent": Http.uaChrome,
            "Referer": shareURL,
            "Origin": origin,
            "X-Requested-With": "XMLHttpRequest"
        ])

        guard let data = response.body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.unknown("取链接口返回的不是 JSON")
        }

        let zt = (json["zt"] as? NSNumber)?.intValue ?? 0
        if zt == 3 { throw ParseError.blocked("提取码不正确") }
        guard zt == 1 else { throw ParseError.unknown("取链失败（zt=\(zt)）") }

        let dom = (json["dom"] as? String) ?? ""
        var path = (json["url"] as? String) ?? ""
        guard !path.isEmpty else { throw ParseError.unknown("取链接口没给下载地址") }

        if path.hasPrefix("?") { path = "/file/" + path }
        let candidate = path.hasPrefix("http") ? path : dom + path
        guard let linkURL = URL(string: candidate) else { throw ParseError.unknown("下载地址不合法") }

        let landing = try await Http.get(linkURL, headers: [
            "User-Agent": Http.uaChrome,
            "Referer": shareURL
        ])
        var direct = landing.finalURL ?? linkURL
        if landing.status != 200, landing.status != 206 {
            throw ParseError.network("下载页返回 \(landing.status)")
        }
        if direct.absoluteString == linkURL.absoluteString,
           let iframe = firstGroup(#"<iframe[^>]+src=[\"']([^\"']+)[\"']"#, in: landing.body),
           let next = URL(string: iframe, relativeTo: linkURL) {
            direct = next
        }

        let fileName = title.isEmpty ? "lanzou_\(fileID).bin" : title
        let mediaHeaders: [String: String] = [
            "User-Agent": Http.uaChrome,
            "Referer": shareURL
        ]

        return ParseResult(
            platform: .lanzou,
            title: fileName,
            author: "蓝奏云",
            avatar: nil,
            cover: nil,
            text: "来自 \(host) 的分享",
            pageURL: url,
            medias: [MediaItem(url: direct, kind: .file, fileName: fileName, headers: mediaHeaders)]
        )
    }

    private static func extractTitle(_ html: String) -> String {
        if let value = firstGroup(#"class=[\"']n[\"']>([^<]+)<"#, in: html) { return value.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let value = firstGroup(#"<title>([^<]+)</title>"#, in: html) { return value.trimmingCharacters(in: .whitespacesAndNewlines) }
        return ""
    }

    private static func firstGroup(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return nil }
        let value = ns.substring(with: match.range(at: 1))
        return value.isEmpty ? nil : value
    }
}
