import Foundation
import SwiftUI
import WebKit
// MARK: - 夸克常量与 Cookie 存储
enum QuarkConfig {
    static let apiBase = "https://drive-pc.quark.cn"
    static let tokenURL = apiBase + "/1/clouddrive/share/sharepage/token?pr=ucpro&fr=pc"
    static let detailURL = apiBase + "/1/clouddrive/share/sharepage/detail?pr=ucpro&fr=pc"
    static let downloadURL = apiBase + "/1/clouddrive/file/download?pr=ucpro&fr=pc&sys=win32&ve=3.23.2"
    static let apiUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.12-a038f7b798 Safari/537.36 Channel/pckk_other_ch"
    static let webUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    static let cookieKey = "quark.cookie"
}
enum QuarkCookieStore {
    static var cookie: String {
        get { UserDefaults.standard.string(forKey: QuarkConfig.cookieKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: QuarkConfig.cookieKey) }
    }
    static var loggedIn: Bool { !cookie.isEmpty }
    static func merge(setCookies: [String]) {
        guard !setCookies.isEmpty else { return }
        var jar: [String: String] = [:]
        for pair in cookie.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { jar[parts[0]] = parts[1] }
        }
        for raw in setCookies {
            let pair = raw.split(separator: ";").first.map(String.init) ?? raw
            let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, !parts[1].isEmpty { jar[parts[0]] = parts[1] }
        }
        cookie = jar.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }
}
// MARK: - 夸克分享解析
enum QuarkParser {
    private struct ShareFile {
        var fid: String
        var name: String
        var size: Int64
        var isDir: Bool
        var token: String
    }
    static func parse(shareID: String, pwd: String?) async throws -> ParseResult {
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        var cookie = QuarkCookieStore.cookie
        let tokenBody: [String: Any] = [
            "pwd_id": shareID,
            "passcode": pwd ?? "",
            "support_visit_limit_private_share": true
        ]
        let tokenResp = try await postJSON(QuarkConfig.tokenURL, body: tokenBody, cookie: cookie)
        QuarkCookieStore.merge(setCookies: tokenResp.setCookies)
        cookie = QuarkCookieStore.cookie
        let tokenData = tokenResp.json["data"] as? [String: Any]
        guard let stoken = tokenData?["stoken"] as? String, !stoken.isEmpty else {
            let code = (tokenResp.json["code"] as? NSNumber)?.intValue ?? 0
            if code == 41004 || code == 41005 { throw ParseError.blocked("提取码不正确，或分享已失效") }
            throw ParseError.unknown("夸克没返回 stoken（code=\(code)），可能链接失效")
        }
        let shareTitle = (tokenData?["title"] as? String) ?? ""
        var files = try await listShare(shareID: shareID, stoken: stoken, pdirFid: "0", cookie: cookie, page: 1)
        if files.count == 1, files[0].isDir {
            files = try await listShare(shareID: shareID, stoken: stoken, pdirFid: files[0].fid, cookie: cookie, page: 1)
        }
        let downloadable = files.filter { !$0.isDir }
        guard !downloadable.isEmpty else {
            throw ParseError.notFound("这个分享里没有可下载的文件（可能是空文件夹）")
        }
        var medias: [MediaItem] = []
        var lastError: Error?
        for file in downloadable.prefix(20) {
            do {
                let link = try await downloadLink(file: file, shareID: shareID, stoken: stoken, cookie: cookie)
                medias.append(MediaItem(url: link.url,
                                        kind: MediaKind.from(fileName: file.name),
                                        fileName: file.name.isEmpty ? "quark_\(file.fid)" : file.name,
                                        headers: link.headers))
            } catch {
                lastError = error
            }
        }
        guard !medias.isEmpty else {
            throw lastError ?? ParseError.unknown("夸克没取到直链")
        }
        _ = stamp
        return ParseResult(
            platform: .quark,
            title: shareTitle.isEmpty ? "夸克分享 \(shareID)" : shareTitle,
            author: QuarkCookieStore.loggedIn ? "夸克网盘（已登录）" : "夸克网盘（游客，单文件 ≤50MB）",
            avatar: nil,
            cover: nil,
            text: "共 \(downloadable.count) 个文件，已取链 \(medias.count) 个",
            pageURL: URL(string: "https://pan.quark.cn/s/\(shareID)"),
            medias: medias
        )
    }
    private static func listShare(shareID: String, stoken: String, pdirFid: String, cookie: String, page: Int) async throws -> [ShareFile] {
        var components = URLComponents(string: QuarkConfig.detailURL)!
        var items = components.queryItems ?? []
        items.append(contentsOf: [
            URLQueryItem(name: "pwd_id", value: shareID),
            URLQueryItem(name: "stoken", value: stoken),
            URLQueryItem(name: "pdir_fid", value: pdirFid),
            URLQueryItem(name: "ver", value: "2"),
            URLQueryItem(name: "force", value: "0"),
            URLQueryItem(name: "_page", value: "\(page)"),
            URLQueryItem(name: "_size", value: "100"),
            URLQueryItem(name: "_fetch_banner", value: "0"),
            URLQueryItem(name: "_fetch_share", value: "0"),
            URLQueryItem(name: "fetch_relate_conversation", value: "0"),
            URLQueryItem(name: "_fetch_total", value: "1"),
            URLQueryItem(name: "_sort", value: "file_type:asc,file_name:asc")
        ])
        components.queryItems = items
        var headers: [String: String] = [
            "User-Agent": QuarkConfig.apiUA,
            "Origin": "https://pan.quark.cn",
            "Referer": "https://pan.quark.cn/"
        ]
        if !cookie.isEmpty { headers["Cookie"] = cookie }
        let result = try await Http.get(components.url!, headers: headers)
        guard let data = result.body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.unknown("夸克文件列表不是 JSON（HTTP \(result.status)）")
        }
        let code = (json["code"] as? NSNumber)?.intValue ?? 0
        if code == 31001 { throw ParseError.blocked("夸克要求登录：请先在设置里登录夸克账号") }
        guard let payload = json["data"] as? [String: Any],
              let list = payload["list"] as? [[String: Any]] else {
            throw ParseError.unknown("夸克文件列表为空（code=\(code)）")
        }
        return list.compactMap { item in
            guard let fid = item["fid"] as? String, !fid.isEmpty else { return nil }
            return ShareFile(fid: fid,
                             name: (item["file_name"] as? String) ?? "",
                             size: (item["size"] as? NSNumber)?.int64Value ?? 0,
                             isDir: (item["dir"] as? Bool) ?? false,
                             token: (item["share_fid_token"] as? String) ?? "")
        }
    }
    private static func downloadLink(file: ShareFile, shareID: String, stoken: String, cookie: String) async throws -> (url: URL, headers: [String: String]) {
        let body: [String: Any] = [
            "fids": [file.fid],
            "fids_token": [file.token],
            "pwd_id": shareID,
            "stoken": stoken,
            "speedup_session": "",
            "token": ""
        ]
        let resp = try await postJSON(QuarkConfig.downloadURL, body: body, cookie: cookie)
        QuarkCookieStore.merge(setCookies: resp.setCookies)
        let code = (resp.json["code"] as? NSNumber)?.intValue ?? 0
        if code == 31001 { throw ParseError.blocked("夸克要求登录后才能取这个文件的直链") }
        if code == 23018 { throw ParseError.blocked("文件超过游客 50MB 上限，登录夸克账号后再试") }
        guard let array = resp.json["data"] as? [[String: Any]], let first = array.first,
              let urlString = first["download_url"] as? String, let url = URL(string: urlString) else {
            let message = (resp.json["message"] as? String) ?? "没有 download_url"
            throw ParseError.unknown("夸克取链失败（code=\(code)，\(message)）")
        }
        var headers: [String: String] = [
            "User-Agent": QuarkConfig.apiUA,
            "Referer": "https://pan.quark.cn/"
        ]
        let jar = QuarkCookieStore.cookie
        if !jar.isEmpty { headers["Cookie"] = jar }
        return (url, headers)
    }
    // MARK: 网络
    private struct JSONResponse {
        var json: [String: Any]
        var setCookies: [String]
        var status: Int
    }
    private static func postJSON(_ urlString: String, body: [String: Any], cookie: String) async throws -> JSONResponse {
        guard let url = URL(string: urlString) else { throw ParseError.unknown("夸克接口地址不合法") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(QuarkConfig.apiUA, forHTTPHeaderField: "User-Agent")
        request.setValue("https://pan.quark.cn", forHTTPHeaderField: "Origin")
        request.setValue("https://pan.quark.cn/", forHTTPHeaderField: "Referer")
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
        let cookies = headers["set-cookie"] ?? []
        let text = String(data: data, encoding: .utf8) ?? ""
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if let status = http?.statusCode, status == 401 || status == 403 {
                throw ParseError.blocked("夸克接口 \(status)，需要登录")
            }
            throw ParseError.unknown("夸克返回的不是 JSON（HTTP \(http?.statusCode ?? 0)）")
        }
        _ = text
        return JSONResponse(json: json, setCookies: cookies, status: http?.statusCode ?? 0)
    }
}
// MARK: - 文件名判类型
extension MediaKind {
    static func from(fileName: String) -> MediaKind {
        let lower = fileName.lowercased()
        if [".mp4", ".mov", ".mkv", ".avi", ".webm", ".ts", ".m3u8", ".flv", ".wmv"].contains(where: { lower.hasSuffix($0) }) { return .video }
        if [".jpg", ".jpeg", ".png", ".webp", ".gif", ".heic", ".bmp"].contains(where: { lower.hasSuffix($0) }) { return .image }
        if [".mp3", ".m4a", ".wav", ".flac", ".aac", ".ogg"].contains(where: { lower.hasSuffix($0) }) { return .audio }
        return .file
    }
}
// MARK: - 夸克登录（WKWebView 抓 Cookie）
struct QuarkLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var loading = true
    @State private var cookieCount = 0
    var body: some View {
        NavigationStack {
            QuarkWebView(loading: $loading, cookieCount: $cookieCount)
                .navigationTitle("登录夸克网盘")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") {
                            saveCookies()
                            dismiss()
                        }
                        .disabled(cookieCount == 0)
                    }
                }
            if loading {
                ProgressView("加载中…")
            }
        }
    }
    private func saveCookies() {
        QuarkWebView.collectCookies { cookie in
            if !cookie.isEmpty { QuarkCookieStore.cookie = cookie }
        }
    }
}
struct QuarkWebView: UIViewRepresentable {
    @Binding var loading: Bool
    @Binding var cookieCount: Int
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        if let url = URL(string: "https://pan.quark.cn/login") {
            webView.load(URLRequest(url: url))
        }
        return webView
    }
    func updateUIView(_ webView: WKWebView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: QuarkWebView
        init(_ parent: QuarkWebView) { self.parent = parent }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.loading = false
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let quark = cookies.filter { $0.domain.contains("quark.cn") }
                DispatchQueue.main.async { self.parent.cookieCount = quark.count }
            }
        }
    }
    static func collectCookies(_ completion: @escaping (String) -> Void) {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            let quark = cookies.filter { $0.domain.contains("quark.cn") }
            let joined = quark.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            DispatchQueue.main.async { completion(joined) }
        }
    }
}
struct QuarkAccountView: View {
    @State private var showLogin = false
    @State private var cookieDraft = QuarkCookieStore.cookie
    var body: some View {
        Form {
            Section {
                HStack {
                    Text(QuarkCookieStore.loggedIn ? "已登录" : "未登录")
                    Spacer()
                    Text(QuarkCookieStore.loggedIn ? "Cookie \(cookieDraft.count) 字符" : "游客 50MB 限制")
                        .foregroundStyle(.secondary)
                }
                Button("打开夸克网页登录") { showLogin = true }
                Button("清除 Cookie", role: .destructive) {
                    QuarkCookieStore.cookie = ""
                    cookieDraft = ""
                }
                .disabled(!QuarkCookieStore.loggedIn)
            } header: {
                Text("夸克账号")
            } footer: {
                Text("登录后取链走账号态，不受游客 50MB 限制；Cookie 只存在本机。")
            }

            Section {
                NavigationLink {
                    XunleiAccountView()
                } label: {
                    HStack {
                        Text("迅雷账号")
                        Spacer()
                        Text(XunleiStore.loggedIn ? "已登录" : "未登录")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                NavigationLink {
                    NetdiskCookieAccountView(platformName: "UC 浏览器",
                                             cookieKey: "uc",
                                             loginTitle: "登录 UC 网盘",
                                             startURL: "https://drive.uc.cn/",
                                             domainSuffix: "uc.cn",
                                             hint: "UC 分享游客可解析 ≤50MB，登录后走账号态；Cookie 只存本机。")
                } label: {
                    HStack {
                        Text("UC 账号")
                        Spacer()
                        Text(NetdiskCookieStore.get("uc").isEmpty ? "未登录" : "已登录")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                NavigationLink {
                    NetdiskCookieAccountView(platformName: "115 网盘",
                                             cookieKey: "pan115",
                                             loginTitle: "登录 115 网盘",
                                             startURL: "https://115.com/",
                                             domainSuffix: "115.com",
                                             hint: "115 分享必须登录（UID/CID/SEID Cookie）才能取直链。")
                } label: {
                    HStack {
                        Text("115 账号")
                        Spacer()
                        Text(NetdiskCookieStore.get("pan115").isEmpty ? "未登录" : "已登录")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("其它网盘")
            }

            Section {
                TextEditor(text: $cookieDraft)
                    .frame(minHeight: 90)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("保存手动粘贴的 Cookie") {
                    QuarkCookieStore.cookie = cookieDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } header: {
                Text("手动填 Cookie")
            } footer: {
                Text("格式：`__pus=...; __puus=...`，从浏览器开发者工具里复制。")
            }
        }
        .navigationTitle("夸克账号")
        .sheet(isPresented: $showLogin) {
            QuarkLoginView()
        }
    }
}
