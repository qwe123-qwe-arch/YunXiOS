//
//  YunXiOS · 快手 / 微博 解析器（移植 KuaishouParser、WeiboParser status 路径）
//

import Foundation

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
        let base = NameUtil.sanitize(title).isEmpty ? NameUtil.fallback(.kuaishou, link.id) : NameUtil.sanitize(title)

        var medias: [MediaItem] = []

        if let mvUrls = photo["mainMvUrls"] as? [[String: Any]],
           let urlString = firstURLString(mvUrls),
           let url = URL(string: Http.secureURL(urlString)) {
            medias.append(MediaItem(url: url, kind: .video, fileName: base + ".mp4", headers: headers))
        }

        if let atlas = (photo["ext_params"] as? [String: Any])?["atlas"] as? [String: Any],
           let cdnList = atlas["cdnList"] as? [[String: Any]],
           let cdn = cdnList.first.flatMap({ jsonString($0, "cdn") }).flatMap({ $0.isEmpty ? nil : $0 }),
           let routes = atlas["list"] as? [String] {
            for (index, route) in routes.enumerated() where !route.isEmpty {
                if let url = URL(string: Http.secureURL("https://\(cdn)/\(route)")) {
                    medias.append(MediaItem(url: url, kind: .image, fileName: "\(base)_\(index + 1).jpg", headers: headers))
                }
            }
        }

        guard !medias.isEmpty else {
            throw ParseError.notFound("这个作品里没有可下载的视频或图片")
        }

        var cover: URL?
        if let coverUrls = photo["coverUrls"] as? [[String: Any]],
           let raw = firstURLString(coverUrls) {
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
            throw ParseError.unsupported("weibo.com/tv 链接暂不支持，请改用 weibo.com/用户ID/微博ID 或 m.weibo.cn/detail/微博ID")
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
        let base = NameUtil.sanitize(title).isEmpty ? NameUtil.fallback(.weibo, link.id) : NameUtil.sanitize(title)

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
        if let pic = (pageInfo?["page_pic"] as? [String: Any]), !jsonString(pic, "url").isEmpty {
            cover = URL(string: Http.secureURL(jsonString(pic, "url")))
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
