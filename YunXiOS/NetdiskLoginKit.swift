import Foundation
import SwiftUI
import WebKit

enum NetdiskCookieStore {
    static func get(_ key: String) -> String {
        UserDefaults.standard.string(forKey: "netdisk.cookie." + key) ?? ""
    }
    static func set(_ value: String, for key: String) {
        UserDefaults.standard.set(value, forKey: "netdisk.cookie." + key)
    }
    static func merge(_ key: String, setCookies: [String]) {
        var jar: [String: String] = [:]
        for pair in get(key).split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { jar[parts[0]] = parts[1] }
        }
        for raw in setCookies {
            let pair = raw.split(separator: ";").first.map(String.init) ?? raw
            let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, !parts[1].isEmpty { jar[parts[0]] = parts[1] }
        }
        set(jar.map { "\($0.key)=\($0.value)" }.joined(separator: "; "), for: key)
    }
}

struct NetdiskWebLoginView: View {
    let title: String
    let startURL: String
    let domainSuffix: String
    let cookieKey: String
    @Environment(\.dismiss) private var dismiss
    @State private var loading = true
    @State private var cookieCount = 0

    var body: some View {
        NavigationStack {
            NetdiskWebView(startURL: startURL, domainSuffix: domainSuffix, loading: $loading, cookieCount: $cookieCount)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") {
                            save()
                            dismiss()
                        }
                        .disabled(cookieCount == 0)
                    }
                }
        }
    }

    private func save() {
        NetdiskWebView.collect(domainSuffix: domainSuffix) { cookie in
            if !cookie.isEmpty { NetdiskCookieStore.set(cookie, for: cookieKey) }
        }
    }
}

struct NetdiskWebView: UIViewRepresentable {
    let startURL: String
    let domainSuffix: String
    @Binding var loading: Bool
    @Binding var cookieCount: Int

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        if let url = URL(string: startURL) {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: NetdiskWebView
        init(_ parent: NetdiskWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.loading = false
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let matched = cookies.filter { $0.domain.contains(self.parent.domainSuffix) }
                DispatchQueue.main.async { self.parent.cookieCount = matched.count }
            }
        }
    }

    static func collect(domainSuffix: String, completion: @escaping (String) -> Void) {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            let matched = cookies.filter { $0.domain.contains(domainSuffix) }
            let joined = matched.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            DispatchQueue.main.async { completion(joined) }
        }
    }
}

struct NetdiskCookieAccountView: View {
    let platformName: String
    let cookieKey: String
    let loginTitle: String
    let startURL: String
    let domainSuffix: String
    let hint: String

    @State private var showLogin = false
    @State private var draft = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    Text(NetdiskCookieStore.get(cookieKey).isEmpty ? "未登录" : "已登录")
                    Spacer()
                    Text("Cookie \(NetdiskCookieStore.get(cookieKey).count) 字符")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("打开\(platformName)网页登录") { showLogin = true }
                Button("清除 Cookie", role: .destructive) {
                    NetdiskCookieStore.set("", for: cookieKey)
                    draft = ""
                }
                .disabled(NetdiskCookieStore.get(cookieKey).isEmpty)
            } header: {
                Text("\(platformName)账号")
            } footer: {
                Text(hint)
            }

            Section {
                TextEditor(text: $draft)
                    .frame(minHeight: 90)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("保存手动粘贴的 Cookie") {
                    NetdiskCookieStore.set(draft.trimmingCharacters(in: .whitespacesAndNewlines), for: cookieKey)
                }
            } header: {
                Text("手动填 Cookie")
            }
        }
        .navigationTitle("\(platformName)账号")
        .sheet(isPresented: $showLogin) {
            NetdiskWebLoginView(title: loginTitle, startURL: startURL, domainSuffix: domainSuffix, cookieKey: cookieKey)
        }
        .onAppear { draft = NetdiskCookieStore.get(cookieKey) }
    }
}
