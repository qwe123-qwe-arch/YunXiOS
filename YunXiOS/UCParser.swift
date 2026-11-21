import Foundation

enum UCConfig {
    static let tokenURL = "https://pc-api.uc.cn/1/clouddrive/share/sharepage/token?pr=UCBrowser&fr=pc"
    static let transferDetailURL = "https://pc-api.uc.cn/1/clouddrive/transfer_share/detail?entry=ft&fr=pc&pr=UCBrowser"
    static let detailURL = "https://pc-api.uc.cn/1/clouddrive/share/sharepage/v2/detail?pr=UCBrowser&fr=pc"
    static let downloadURL = "https://pc-api.uc.cn/1/clouddrive/file/download?entry=ft&fr=pc&pr=UCBrowser"
    static let cloudUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) uc-cloud-drive/1.6.1 Chrome/100.0.4896.160 Electron/18.3.5.16-b62cf9c50d Safari/537.36 Channel/ucpan_other_ch"
    static let guestUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) uc-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch"
    static let webUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    static let cookieKey = "uc"
}

enum UCParser {

    private struct UCFile {
        var fid: String
        var name: String
        var size: Int64
        var isDir: Bool
        var token: String
    }

    static func parse(shareID: String, pwd: String?) async throws -> ParseResult {
        var cookie = NetdiskCookieStore.get(UCConfig.cookieKey)
        let tokenResp = try await postJSON(UCConfig.tokenURL, body: [
            "pwd_id": shareID,
            "passcode": pwd ?? "",
            "share_for_transfer": true
        ], cookie: cookie, ua: UCConfig.cloudUA, origin: "https://drive.uc.cn", referer: "https://drive.uc.cn/")
        NetdiskCookieStore.merge(UCConfig.cookieKey, setCookies: tokenResp.cookies)
        cookie = NetdiskCookieStore.get(UCConfig.cookieKey)
        let data = tokenResp.json["data"] as? [String: Any]
        guard let stoken = data?["stoken"] as? String, !stoken.isEmpty else {
            let code = (tokenResp.json["code"] as? NSNumber)?.intValue ?? 0
            if code == 41004 || code == 41005 { throw ParseError.blocked("UC 提取码不正确，或分享已失效") }
            throw ParseError.unknown("UC 没返回 stoken（code=\(code)）")
        }
        let title = (data?["title"] as? String) ?? ""
        var files = try await transferFiles(shareID: shareID, stoken: stoken, pdirFid: "0", cookie: cookie, page: 1)
        if files.isEmpty {
            files = try await v2Files(shareID: shareID, pwd: pwd, pdirFid: nil, cookie: cookie)
        }
        if files.count == 1, files[0].isDir {
            let next = files[0].fid
            var sub = try await transferFiles(shareID: shareID, stoken: stoken, pdirFid: next, cookie: cookie, page: 1)
            if sub.isEmpty {
                sub = try await v2Files(shareID: shareID, pwd: pwd, pdirFid: next, cookie: cookie)
            }
            files = sub
        }
        let downloadable = files.filter { !$0.isDir }
        guard !downloadable.isEmpty else { throw ParseError.notFound("这个 UC 分享里没有可下载的文件") }
        var medias: [MediaItem] = []
        var lastError: Error?
        for file in downloadable.prefix(20) {
            do {
                let link = try await downloadLink(file: file, shareID: shareID, stoken: stoken, cookie: cookie)
                medias.append(MediaItem(url: link.url,
                                        kind: MediaKind.from(fileName: file.name),
                                        fileName: file.name.isEmpty ? "uc_\(file.fid)" : file.name,
                                        headers: link.headers))
            } catch { lastError = error }
        }
        guard !medias.isEmpty else { throw lastError ?? ParseError.unknown("UC 没取到直链") }
        return ParseResult(
            platform: .uc,
            title: title.isEmpty ? "UC 分享 \(shareID)" : title,
            author: cookie.isEmpty ? "UC 网盘（游客，单文件 ≤50MB）" : "UC 网盘（已登录）",
            avatar: nil,
            cover: nil,
            text: "共 \(downloadable.count) 个文件，已取链 \(medias.count) 个",
            pageURL: URL(string: "https://drive.uc.cn/s/\(shareID)"),
            medias: medias
        )
    }

    private static func transferFiles(shareID: String, stoken: String, pdirFid: String, cookie: String, page: Int) async throws -> [UCFile] {
        var components = URLComponents(string: UCConfig.transferDetailURL)!
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "pwd_id", value: shareID),
            URLQueryItem(name: "pdir_fid", value: pdirFid),
            URLQueryItem(name: "fetch_file_list", value: "1"),
            URLQueryItem(name: "passcode", value: ""),
            URLQueryItem(name: "_page", value: "\(page)"),
            URLQueryItem(name: "_size", value: "50"),
            URLQueryItem(name: "_fetch_total", value: "1"),
            URLQueryItem(name: "_fetch_task", value: "1"),
            URLQueryItem(name: "_fetch_share", value: "1"),
            URLQueryItem(name: "_sort", value: ""),
            URLQueryItem(name: "stoken", value: stoken)
        ]
        var headers: [String: String] = [
            "User-Agent": UCConfig.webUA,
            "Origin": "https://fast.uc.cn",
            "Referer": "https://fast.uc.cn/"
        ]
        if !cookie.isEmpty { headers["Cookie"] = cookie }
        let result = try await Http.get(components.url!, headers: headers)
        guard let data = result.body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let payload = json["data"] as? [String: Any]
        let list = (payload?["list"] as? [[String: Any]])
            ?? ((payload?["detail_info"] as? [String: Any])?["list"] as? [[String: Any]])
            ?? []
        return list.compactMap { item in
            guard let fid = item["fid"] as? String, !fid.isEmpty else { return nil }
            return UCFile(fid: fid,
                          name: (item["file_name"] as? String) ?? "",
                          size: (item["size"] as? NSNumber)?.int64Value ?? 0,
                          isDir: (item["dir"] as? Bool) ?? false,
                          token: (item["share_fid_token"] as? String) ?? "")
        }
    }

    private static func v2Files(shareID: String, pwd: String?, pdirFid: String?, cookie: String) async throws -> [UCFile] {
        var body: [String: Any] = [
            "pwd_id": shareID,
            "passcode": pwd ?? "",
            "force": 0,
            "page": 1,
            "size": 50,
            "fetch_banner": 1,
            "fetch_share": 1,
            "fetch_total": 1,
            "sort": "file_type:asc,file_name:asc",
            "banner_platform": "other",
            "web_platform": "windows",
            "fetch_error_background": 1
        ]
        if let pdirFid = pdirFid, !pdirFid.isEmpty, pdirFid != "0" { body["pdir_fid"] = pdirFid }
        let resp = try await postJSON(UCConfig.detailURL + "&ve=2.5.20", body: body, cookie: cookie,
                                      ua: UCConfig.webUA, origin: "https://drive.uc.cn", referer: "https://drive.uc.cn/")
        let payload = resp.json["data"] as? [String: Any]
        let list = ((payload?["detail_info"] as? [String: Any])?["list"] as? [[String: Any]])
            ?? (payload?["list"] as? [[String: Any]])
            ?? []
        return list.compactMap { item in
            guard let fid = item["fid"] as? String, !fid.isEmpty else { return nil }
            return UCFile(fid: fid,
                          name: (item["file_name"] as? String) ?? "",
                          size: (item["size"] as? NSNumber)?.int64Value ?? 0,
                          isDir: (item["dir"] as? Bool) ?? false,
                          token: (item["share_fid_token"] as? String) ?? "")
        }
    }

    private static func downloadLink(file: UCFile, shareID: String, stoken: String, cookie: String) async throws -> (url: URL, headers: [String: String]) {
        let resp = try await postJSON(UCConfig.downloadURL, body: [
            "fids": [file.fid],
            "pwd_id": shareID,
            "stoken": stoken,
            "fids_token": [file.token]
        ], cookie: cookie, ua: UCConfig.guestUA, origin: nil, referer: nil)
        NetdiskCookieStore.merge(UCConfig.cookieKey, setCookies: resp.cookies)
        let code = (resp.json["code"] as? NSNumber)?.intValue ?? 0
        if code == 31001 { throw ParseError.blocked("UC 要求登录：请先在 网盘账号 → UC 账号 登录") }
        if code == 23018 { throw ParseError.blocked("文件超过 UC 游客 50MB 上限，登录后再试") }
        if code == 14001 { throw ParseError.blocked("UC 分享已失效") }
        guard let array = resp.json["data"] as? [[String: Any]], let first = array.first,
              let urlString = first["download_url"] as? String, let url = URL(string: urlString) else {
            let message = (resp.json["message"] as? String) ?? "没有 download_url"
            throw ParseError.unknown("UC 取链失败（code=\(code)，\(message)）")
        }
        var headers: [String: String] = [
            "User-Agent": UCConfig.guestUA,
            "Referer": "https://drive.uc.cn/"
        ]
        let jar = NetdiskCookieStore.get(UCConfig.cookieKey)
        if !jar.isEmpty { headers["Cookie"] = jar }
        return (url, headers)
    }

    private struct JSONResponse {
        var json: [String: Any]
        var cookies: [String]
    }

    private static func postJSON(_ urlString: String, body: [String: Any], cookie: String, ua: String, origin: String?, referer: String?) async throws -> JSONResponse {
        guard let url = URL(string: urlString) else { throw ParseError.unknown("UC 接口地址不合法") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(ua, forHTTPHeaderField: "User-Agent")
        if let origin = origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        if let referer = referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
        if !cookie.isEmpty { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config)
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let headers = (http?.allHeaderFields ?? [:]).reduce(into: [String: [String]]()) { partial, pair in
            guard let key = pair.key as? String, let value = pair.value as? String else { return }
            partial[key.lowercased(), default: []].append(value)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if let status = http?.statusCode, status == 401 || status == 403 {
                throw ParseError.blocked("UC 接口 \(status)，需要登录")
            }
            throw ParseError.unknown("UC 返回的不是 JSON（HTTP \(http?.statusCode ?? 0)）")
        }
        return JSONResponse(json: json, cookies: headers["set-cookie"] ?? [])
    }
}
