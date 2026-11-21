import Foundation
import CommonCrypto
import SwiftUI

enum XunleiConfig {
    static let authBase = "https://xluser-ssl.xunlei.com"
    static let panBase = "https://api-pan.xunlei.com"
    static let loginURL = authBase + "/xluser.core.login/v3/login"
    static let tokenURL = authBase + "/v1/auth/signin/token"
    static let captchaURL = authBase + "/v1/shield/captcha/init"
    static let shareURL = panBase + "/drive/v1/share"
    static let shareDetailURL = panBase + "/drive/v1/share/detail"
    static let filesURL = panBase + "/drive/v1/files"
    static let restoreURL = panBase + "/drive/v1/share/restore"
    static let deleteURL = panBase + "/drive/v1/files/batchDelete"
    static let webUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
    static let appClientID = "Xp6vsxz_7IYVw2BB"
    static let appClientSecret = "Xp6vsy4tN9toTVdMSpomVdXpRmES"
    static let appVersion = "8.31.0.9726"
    static let appPackage = "com.xunlei.downloadprovider"
    static let appKey = "34a062aaa22f906fca4fefe9fb3a3021"
    static let salts = ["9uJNVj/wLmdwKrJaVj/omlQ", "Oz64Lp0GigmChHMf/6TNfxx7O9PyopcczMsnf", "Eb+L7Ce+Ej48u", "jKY0", "ASr0zCl6v8W4aidjPK5KHd1Lq3t+vBFf41dqv5+fnOd", "wQlozdg6r1qxh0eRmt3QgNXOvSZO6q/GXK", "gmirk+ciAvIgA/cxUUCema47jr/YToixTT+Q6O", "5IiCoM9B1/788ntB", "P07JH0h6qoM6TSUAK2aL9T5s2QBVeY9JWvalf", "+oK0AN"]
}

enum XunleiStore {
    private static let defaults = UserDefaults.standard
    static var accessToken: String {
        get { defaults.string(forKey: "xunlei.token") ?? "" }
        set { defaults.set(newValue, forKey: "xunlei.token") }
    }
    static var userId: String {
        get { defaults.string(forKey: "xunlei.user") ?? "" }
        set { defaults.set(newValue, forKey: "xunlei.user") }
    }
    static var deviceId: String {
        if let saved = defaults.string(forKey: "xunlei.device"), !saved.isEmpty { return saved }
        let new = randomHex(32)
        defaults.set(new, forKey: "xunlei.device")
        return new
    }
    static var peerId: String {
        if let saved = defaults.string(forKey: "xunlei.peer"), !saved.isEmpty { return saved }
        let new = randomHex(32)
        defaults.set(new, forKey: "xunlei.peer")
        return new
    }
    static var deviceSign: String {
        if let saved = defaults.string(forKey: "xunlei.sign"), !saved.isEmpty { return saved }
        let sign = buildDeviceSign(deviceId)
        defaults.set(sign, forKey: "xunlei.sign")
        return sign
    }
    static var loggedIn: Bool { !accessToken.isEmpty }
    static func clear() {
        accessToken = ""
        userId = ""
    }
    private static func buildDeviceSign(_ id: String) -> String {
        let base = id + XunleiConfig.appPackage + "40" + XunleiConfig.appKey
        return "div101." + id + Crypto.md5(Crypto.sha1(base))
    }
    private static func randomHex(_ len: Int) -> String {
        let chars = Array("0123456789abcdef")
        return String((0..<len).map { _ in chars[Int.random(in: 0..<16)] })
    }
}

enum Crypto {
    static func md5(_ input: String) -> String {
        let data = Data(input.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_MD5(ptr.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    static func sha1(_ input: String) -> String {
        let data = Data(input.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_SHA1(ptr.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum XunleiService {

    static func captchaSign(deviceId: String, ts: Int64) -> String {
        var hash = XunleiConfig.appClientID + XunleiConfig.appVersion + XunleiConfig.appPackage + deviceId + String(ts)
        for salt in XunleiConfig.salts { hash = Crypto.md5(hash + salt) }
        return "1." + hash
    }

    static func initCaptcha(action: String) async throws -> String {
        let deviceId = XunleiStore.deviceId
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        let body: [String: Any] = [
            "client_id": XunleiConfig.appClientID,
            "action": action,
            "device_id": deviceId,
            "meta": [
                "username": "",
                "phone_number": "",
                "email": "",
                "package_name": XunleiConfig.appPackage,
                "client_version": XunleiConfig.appVersion,
                "captcha_sign": captchaSign(deviceId: deviceId, ts: ts),
                "timestamp": String(ts),
                "user_id": XunleiStore.userId
            ]
        ]
        let resp = try await postJSON(XunleiConfig.captchaURL, body: body, headers: [
            "Content-Type": "text/plain;charset=UTF-8",
            "Origin": "https://pan.xunlei.com",
            "Referer": "https://pan.xunlei.com/",
            "User-Agent": XunleiConfig.webUA
        ])
        if let token = resp["captcha_token"] as? String, !token.isEmpty { return token }
        return ""
    }

    static func exchange(sessionId: String) async throws {
        let deviceId = XunleiStore.deviceId
        let captcha = try? await initCaptcha(action: "POST:/v1/auth/signin/token")
        var headers: [String: String] = [
            "User-Agent": XunleiConfig.webUA,
            "Accept": "application/json;charset=UTF-8",
            "Content-Type": "application/json",
            "X-Client-Id": XunleiConfig.appClientID,
            "X-Device-Id": deviceId,
            "X-Client-Version": XunleiConfig.appVersion
        ]
        if let captcha = captcha, !captcha.isEmpty { headers["X-Captcha-Token"] = captcha }
        let tokenResp = try await postJSON(XunleiConfig.tokenURL, body: [
            "client_id": XunleiConfig.appClientID,
            "client_secret": XunleiConfig.appClientSecret,
            "provider": "access_end_point_token",
            "signin_token": sessionId
        ], headers: headers)
        guard let access = (tokenResp["access_token"] as? String) ?? (tokenResp["accessToken"] as? String), !access.isEmpty else {
            throw ParseError.unknown("迅雷换取 token 失败")
        }
        XunleiStore.accessToken = access
        XunleiStore.userId = jwtSub(access)
    }

    static func sendSMS(mobile: String) async throws -> (credit: String, token: String) {
        let body = loginBody(deviceId: XunleiStore.deviceId, clientVersion: "8.31.0.9726", sdkVersion: "231500").merging([
            "mobile": mobile,
            "register": "0"
        ]) { $1 }
        let resp = try await postJSON(XunleiConfig.authBase + "/xluser.core.login/v3/sendsms", body: body, headers: [
            "User-Agent": "android-ok-http-client/xl-acc-sdk/version-5.0.12.512000",
            "Content-Type": "application/json"
        ])
        let error = (resp["error"] as? String) ?? ""
        if error == "success" || (resp["errorCode"] as? String) == "0" {
            let credit = (resp["creditkey"] as? String) ?? ""
            let token = (resp["token"] as? String) ?? ""
            if credit.isEmpty || token.isEmpty { throw ParseError.unknown("迅雷短信接口没返回 creditkey/token") }
            return (credit, token)
        }
        let desc = (resp["errorDesc"] as? String) ?? "短信发送失败（\(error)）"
        throw ParseError.blocked(desc)
    }

    static func smsLogin(mobile: String, code: String, credit: String, smsToken: String) async throws {
        let body = loginBody(deviceId: XunleiStore.deviceId, clientVersion: "8.31.0.9726", sdkVersion: "231500", creditKey: credit).merging([
            "mobile": mobile,
            "smsCode": code,
            "token": smsToken,
            "register": "0"
        ]) { $1 }
        let resp = try await postJSON(XunleiConfig.authBase + "/xluser.core.login/v3/smslogin", body: body, headers: [
            "User-Agent": "android-ok-http-client/xl-acc-sdk/version-5.0.12.512000",
            "Content-Type": "application/json"
        ])
        let errorCode = (resp["errorCode"] as? String) ?? ""
        let error = (resp["error"] as? String) ?? ""
        guard errorCode == "0" || error == "success" else {
            let desc = (resp["errorDesc"] as? String) ?? "短信登录失败（\(error) \(errorCode)）"
            throw ParseError.blocked(desc)
        }
        let sessionId = (resp["sessionID"] as? String) ?? ""
        guard !sessionId.isEmpty else { throw ParseError.unknown("迅雷短信登录没返回 sessionID") }
        try await exchange(sessionId: sessionId)
    }

    static func login(username: String, password: String) async throws {
        let deviceId = XunleiStore.deviceId
        var body = loginBody(deviceId: deviceId)
        body["userName"] = username
        body["passWord"] = password
        body["verifyKey"] = ""
        body["verifyCode"] = ""
        body["isMd5Pwd"] = "0"
        let resp = try await postJSON(XunleiConfig.loginURL, body: body, headers: [
            "User-Agent": "android-ok-http-client/xl-acc-sdk/version-5.1.3.513006",
            "Content-Type": "application/json"
        ])
        let errorCode = (resp["errorCode"] as? String) ?? ""
        let error = (resp["error"] as? String) ?? ""
        guard errorCode == "0" || error == "success" else {
            let review = (resp["reviewurl"] as? String) ?? ""
            if error == "review_panel" || errorCode == "1007" || !review.isEmpty {
                throw ParseError.blocked("迅雷要求短信/安全验证，请改用「手机号 + 短信」登录")
            }
            let desc = (resp["errorDesc"] as? String) ?? "登录失败（\(error) \(errorCode)）"
            throw ParseError.blocked(desc)
        }
        let sessionId = (resp["sessionID"] as? String) ?? ""
        guard !sessionId.isEmpty else { throw ParseError.unknown("迅雷登录没有返回 sessionID") }
        _ = deviceId
        try await exchange(sessionId: sessionId)
    }

    private static func loginBody(deviceId: String, clientVersion: String = "25.0.5.25", sdkVersion: String = "513006", creditKey: String = "") -> [String: Any] {
        [
            "protocolVersion": "301",
            "sequenceNo": String(Int.random(in: 10000000...99999999)),
            "platformVersion": "10",
            "isCompressed": "0",
            "appid": "40",
            "clientVersion": clientVersion,
            "peerID": XunleiStore.peerId,
            "appName": "ANDROID-com.xunlei.downloadprovider",
            "sdkVersion": sdkVersion,
            "devicesign": XunleiStore.deviceSign,
            "netWorkType": "WIFI",
            "providerName": "NONE",
            "deviceModel": "M2004J7AC",
            "deviceName": "Xiaomi_M2004j7ac",
            "OSVersion": "12",
            "creditkey": creditKey,
            "hl": "zh-CN"
        ]
    }

    static func jwtSub(_ token: String) -> String {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return "" }
        var payload = String(parts[1])
        payload = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        return (json["sub"] as? String) ?? ""
    }

    static func parse(shareID: String, passCode: String?) async throws -> ParseResult {
        var headers = panHeaders()
        if headers["X-Captcha-Token"] == nil {
            if let token = try? await initCaptcha(action: "GET:/drive/v1/share"), !token.isEmpty {
                headers["X-Captcha-Token"] = token
            }
        }
        var components = URLComponents(string: XunleiConfig.shareURL)!
        components.queryItems = [
            URLQueryItem(name: "share_id", value: shareID),
            URLQueryItem(name: "pass_code", value: passCode ?? ""),
            URLQueryItem(name: "limit", value: "100"),
            URLQueryItem(name: "page_token", value: ""),
            URLQueryItem(name: "thumbnail_size", value: "SIZE_SMALL")
        ]
        let first = try await getJSON(components.url!, headers: headers)
        try checkShareStatus(first)
        guard let data = first["data"] as? [String: Any] else {
            throw ParseError.unknown("迅雷分享接口没有返回 data")
        }
        let title = (data["title"] as? String) ?? ""
        let passToken = (data["pass_code_token"] as? String) ?? ""
        var files = parseFiles(data["files"])
        if files.count == 1, files[0].isDir {
            var sub = URLComponents(string: XunleiConfig.shareDetailURL)!
            sub.queryItems = [
                URLQueryItem(name: "share_id", value: shareID),
                URLQueryItem(name: "parent_id", value: files[0].id),
                URLQueryItem(name: "pass_code_token", value: passToken),
                URLQueryItem(name: "limit", value: "100"),
                URLQueryItem(name: "page_token", value: ""),
                URLQueryItem(name: "thumbnail_size", value: "SIZE_SMALL")
            ]
            let detail = try await getJSON(sub.url!, headers: headers)
            if let payload = detail["data"] as? [String: Any] {
                files = parseFiles(payload["files"])
            }
        }
        let downloadable = files.filter { !$0.isDir }
        guard !downloadable.isEmpty else {
            throw ParseError.notFound("这个迅雷分享里没有可下载的文件")
        }
        guard XunleiStore.loggedIn else {
            throw ParseError.blocked("迅雷分享已读到「\(title.isEmpty ? shareID : title)」，但取直链必须登录：设置 → 网盘账号 → 迅雷账号（手机号+短信）登录后再解析。")
        }
        var medias: [MediaItem] = []
        var lastError: Error?
        for file in downloadable.prefix(10) {
            do {
                if let media = try await fetchMedia(file: file, shareID: shareID, passToken: passToken) {
                    medias.append(media)
                }
            } catch { lastError = error }
        }
        guard !medias.isEmpty else { throw lastError ?? ParseError.unknown("迅雷没取到直链") }
        return ParseResult(
            platform: .xunlei,
            title: title.isEmpty ? "迅雷分享 \(shareID)" : title,
            author: "迅雷网盘（已登录）",
            avatar: nil,
            cover: nil,
            text: "共 \(downloadable.count) 个文件，已取链 \(medias.count) 个",
            pageURL: URL(string: "https://pan.xunlei.com/s/\(shareID)"),
            medias: medias
        )
    }

    private struct ShareFile {
        var id: String
        var name: String
        var size: Int64
        var isDir: Bool
    }

    private static func parseFiles(_ raw: Any?) -> [ShareFile] {
        guard let array = raw as? [[String: Any]] else { return [] }
        return array.compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            return ShareFile(id: id,
                             name: (item["name"] as? String) ?? "",
                             size: (item["size"] as? NSNumber)?.int64Value ?? 0,
                             isDir: ((item["kind"] as? String) ?? "") == "drive#folder")
        }
    }

    private static func checkShareStatus(_ json: [String: Any]) throws {
        guard let data = json["data"] as? [String: Any] else {
            let message = (json["error_description"] as? String) ?? (json["error"] as? String) ?? ""
            if message.contains("captcha") { throw ParseError.blocked("迅雷风控要求验证码，稍后重试") }
            throw ParseError.unknown("迅雷分享接口返回异常：\(message)")
        }
        switch (data["share_status"] as? String) ?? "" {
        case "PASS_CODE_EMPTY": throw ParseError.blocked("这个迅雷分享需要提取码，请在链接后面补上（?pwd=xxxx）")
        case "PASS_CODE_ERROR": throw ParseError.blocked("迅雷提取码不正确")
        case "PASS_CODE_NEED": throw ParseError.blocked("这个迅雷分享需要提取码")
        default: return
        }
    }

    private static func fetchMedia(file: ShareFile, shareID: String, passToken: String) async throws -> MediaItem? {
        let folderId = try await ensureTempFolder()
        let restored = try await restore(shareID: shareID, passToken: passToken, parent: folderId, fileId: file.id)
        Task { try? await deleteFiles([restored]) }
        var components = URLComponents(string: XunleiConfig.filesURL + "/\(restored)")!
        components.queryItems = [
            URLQueryItem(name: "_magic", value: "2021"),
            URLQueryItem(name: "usage", value: "PLAY"),
            URLQueryItem(name: "thumbnail_size", value: "SIZE_LARGE"),
            URLQueryItem(name: "with", value: "hdr10")
        ]
        let detail = try await getJSON(components.url!, headers: panHeaders())
        guard let data = detail["data"] as? [String: Any] else { throw ParseError.unknown("迅雷文件详情为空") }
        var direct = ""
        if let links = data["links"] as? [String: Any],
           let octet = links["application/octet-stream"] as? [String: Any],
           let url = octet["url"] as? String {
            direct = url
        }
        if direct.isEmpty { direct = (data["web_content_link"] as? String) ?? "" }
        guard let url = URL(string: direct), !direct.isEmpty else {
            throw ParseError.unknown("迅雷没返回下载直链（文件可能被限制）")
        }
        let name = (data["name"] as? String) ?? file.name
        return MediaItem(url: url,
                         kind: MediaKind.from(fileName: name),
                         fileName: name.isEmpty ? "xunlei_\(file.id)" : name,
                         headers: ["User-Agent": XunleiConfig.webUA, "Referer": "https://pan.xunlei.com/"])
    }

    private static func ensureTempFolder() async throws -> String {
        let body: [String: Any] = ["kind": "drive#folder", "parent_id": "", "name": "云析临时转存", "space": ""]
        let resp = try await postJSON(XunleiConfig.filesURL, body: body, headers: panHeaders())
        if let file = resp["file"] as? [String: Any], let id = file["id"] as? String { return id }
        if let id = resp["id"] as? String { return id }
        if let data = resp["data"] as? [String: Any], let id = data["id"] as? String { return id }
        throw ParseError.unknown("迅雷建临时目录失败")
    }

    private static func restore(shareID: String, passToken: String, parent: String, fileId: String) async throws -> String {
        let body: [String: Any] = [
            "share_id": shareID,
            "pass_code_token": passToken,
            "parent_id": parent,
            "ancestor_ids": [],
            "file_ids": [fileId],
            "specify_parent_id": true
        ]
        let resp = try await postJSON(XunleiConfig.restoreURL, body: body, headers: panHeaders())
        if let data = resp["data"] as? [String: Any] {
            if let params = data["params"] as? [String: Any],
               let traceRaw = params["trace_file_ids"] as? String,
               let traceData = traceRaw.data(using: .utf8),
               let map = try? JSONSerialization.jsonObject(with: traceData) as? [String: Any],
               let newId = map[fileId] as? String {
                return newId
            }
            if let fid = data["file_id"] as? String, !fid.isEmpty { return fid }
        }
        throw ParseError.unknown("迅雷转存失败（可能空间不足或分享失效）")
    }

    private static func deleteFiles(_ ids: [String]) async throws {
        _ = try await postJSON(XunleiConfig.deleteURL, body: ["ids": ids, "space": ""], headers: panHeaders())
    }

    static func panHeaders() -> [String: String] {
        var headers: [String: String] = [
            "User-Agent": XunleiConfig.webUA,
            "X-Device-Id": XunleiStore.deviceId,
            "X-Client-Version": XunleiConfig.appVersion,
            "Content-Type": "application/json",
            "Origin": "https://pan.xunlei.com",
            "Referer": "https://pan.xunlei.com/"
        ]
        if XunleiStore.loggedIn { headers["Authorization"] = "Bearer " + XunleiStore.accessToken }
        return headers
    }

    private static func getJSON(_ url: URL, headers: [String: String]) async throws -> [String: Any] {
        let result = try await Http.get(url, headers: headers)
        guard let data = result.body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.unknown("迅雷接口返回非 JSON（HTTP \(result.status)）")
        }
        return json
    }

    private static func postJSON(_ urlString: String, body: [String: Any], headers: [String: String]) async throws -> [String: Any] {
        guard let url = URL(string: urlString) else { throw ParseError.unknown("迅雷接口地址不合法") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.unknown("迅雷接口 \(status) 返回非 JSON")
        }
        if let error = json["error"] as? String, error == "captcha_invalid" {
            throw ParseError.blocked("迅雷风控：验证码无效，请稍后重试")
        }
        return json
    }
}

struct XunleiAccountView: View {
    @State private var username = ""
    @State private var password = ""
    @State private var mobile = ""
    @State private var smsCode = ""
    @State private var credit = ""
    @State private var smsToken = ""
    @State private var busy = false
    @State private var sending = false
    @State private var countdown = 0
    @State private var message: String?
    @State private var showAlert = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Text(XunleiStore.loggedIn ? "已登录" : "未登录")
                    Spacer()
                    Text(XunleiStore.loggedIn ? "token 已保存" : "分享可读，取直链需登录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("退出登录", role: .destructive) { XunleiStore.clear() }
                    .disabled(!XunleiStore.loggedIn)
            } header: {
                Text("迅雷账号")
            } footer: {
                Text("迅雷分享列表可以不登录看，但下载直链必须先登录（官方限制）。")
            }

            Section {
                TextField("手机号", text: $mobile)
                    .keyboardType(.numberPad)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                HStack {
                    TextField("短信验证码", text: $smsCode)
                        .keyboardType(.numberPad)
                    Button(countdown > 0 ? "重发 \(countdown)s" : "获取验证码") {
                        sendCode()
                    }
                    .buttonStyle(.borderless)
                    .disabled(sending || countdown > 0 || mobile.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Button {
                    loginSMS()
                } label: {
                    if busy { ProgressView() } else { Text("短信验证码登录") }
                }
                .disabled(busy || mobile.isEmpty || smsCode.isEmpty || credit.isEmpty)
            } header: {
                Text("手机号 + 短信（安全验证走这里）")
            } footer: {
                Text("密码登录被要求「短信/安全验证」时用这个：先发验证码，填码登录成功后直接拿 token。")
            }

            Section {
                TextField("手机号 / 邮箱 / 迅雷账号", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("密码", text: $password)
                Button {
                    loginPassword()
                } label: {
                    if busy { ProgressView() } else { Text("账号密码登录") }
                }
                .disabled(busy || username.isEmpty || password.isEmpty)
            } header: {
                Text("账号密码登录")
            } footer: {
                Text("走迅雷官方 v3/login；若返回 review_panel 会被要求安全验证，请改用上面的短信登录。")
            }
        }
        .navigationTitle("迅雷账号")
        .alert("迅雷登录", isPresented: $showAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    private func sendCode() {
        sending = true
        Task {
            do {
                let pair = try await XunleiService.sendSMS(mobile: mobile.trimmingCharacters(in: .whitespaces))
                await MainActor.run {
                    sending = false
                    credit = pair.credit
                    smsToken = pair.token
                    countdown = 60
                    message = "验证码已发送"
                    showAlert = true
                }
                startCountdown()
            } catch {
                await MainActor.run {
                    sending = false
                    message = error.localizedDescription
                    showAlert = true
                }
            }
        }
    }

    private func startCountdown() {
        Task {
            while countdown > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await MainActor.run { countdown -= 1 }
            }
        }
    }

    private func loginSMS() {
        busy = true
        Task {
            do {
                try await XunleiService.smsLogin(mobile: mobile.trimmingCharacters(in: .whitespaces),
                                                 code: smsCode.trimmingCharacters(in: .whitespaces),
                                                 credit: credit,
                                                 smsToken: smsToken)
                await MainActor.run {
                    busy = false
                    message = "登录成功"
                    showAlert = true
                }
            } catch {
                await MainActor.run {
                    busy = false
                    message = error.localizedDescription
                    showAlert = true
                }
            }
        }
    }

    private func loginPassword() {
        busy = true
        Task {
            do {
                try await XunleiService.login(username: username.trimmingCharacters(in: .whitespaces), password: password)
                await MainActor.run {
                    busy = false
                    message = "登录成功"
                    showAlert = true
                }
            } catch {
                await MainActor.run {
                    busy = false
                    message = error.localizedDescription + "\n若提示安全验证，请用上方「手机号 + 短信」登录。"
                    showAlert = true
                }
            }
        }
    }
}
