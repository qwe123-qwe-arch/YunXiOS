import Foundation

/// 快手部分作品的视频地址不在 mainMvUrls 里（图集作品却带 atlas 图片），
/// 表现就是「只能解析图片」。这里重新抓一次作品页，深度扫一遍 JSON 找 mp4 地址补上。
enum KuaishouVideoFix {

    static func enrich(link: DetectedLink, result: ParseResult) async -> ParseResult {
        guard !result.medias.contains(where: { $0.kind == .video }) else { return result }

        let headers: [String: String] = [
            "User-Agent": Http.uaIphone,
            "Referer": "https://v.kuaishou.com/"
        ]
        var pageURL = await Http.expandRedirect(link.url, headers: headers)
        if pageURL.absoluteString.contains("/fw/long-video/") {
            pageURL = URL(string: pageURL.absoluteString.replacingOccurrences(of: "/fw/long-video/", with: "/fw/photo/")) ?? pageURL
        }
        guard let response = try? await Http.get(pageURL, headers: headers),
              response.status == 200,
              let initJSON = Http.extractInlineJson(response.body, key: "window.INIT_STATE"),
              let data = initJSON.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return result
        }

        var photo: [String: Any]?
        for (_, value) in root {
            if let dict = value as? [String: Any], let candidate = dict["photo"] as? [String: Any] {
                photo = candidate
                break
            }
        }
        guard let photo = photo, let video = deepVideoURL(photo) else { return result }

        var copy = result
        let base = result.title.isEmpty ? "kuaishou_\(link.id)" : NameUtil.sanitize(result.title)
        copy.medias.insert(MediaItem(url: video, kind: .video, fileName: base + ".mp4", headers: headers), at: 0)
        return copy
    }

    private static func deepVideoURL(_ node: Any) -> URL? {
        if let dict = node as? [String: Any] {
            for key in ["photoUrl", "videoUrl", "playUrl", "srcNoMark", "mainMvUrl", "url"] {
                if let raw = dict[key] as? String, looksVideo(raw), let url = URL(string: Http.secureURL(raw)) {
                    return url
                }
            }
            for (_, value) in dict {
                if let found = deepVideoURL(value) { return found }
            }
        } else if let array = node as? [Any] {
            for value in array {
                if let found = deepVideoURL(value) { return found }
            }
        } else if let raw = node as? String, looksVideo(raw) {
            return URL(string: Http.secureURL(raw))
        }
        return nil
    }

    private static func looksVideo(_ raw: String) -> Bool {
        guard raw.hasPrefix("http") || raw.hasPrefix("//") else { return false }
        let lower = raw.lowercased()
        if lower.contains(".mp4") || lower.contains(".m3u8") { return true }
        return lower.contains("ks-cdn") && lower.contains("/upic/")
    }
}
