import SwiftUI
import UIKit

struct ContentView: View {
    var body: some View {
        TabView {
            ResolveView()
                .tabItem { Label("解析", systemImage: "wand.and.stars") }
            DownloadListView()
                .tabItem { Label("下载", systemImage: "arrow.down.circle") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
    }
}

// MARK: - 解析页

struct ResolveView: View {

    @EnvironmentObject private var store: DownloadStore

    @State private var input = ""
    @State private var busy = false
    @State private var result: ParseResult?
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var showManual = false

    @FocusState private var inputFocused: Bool
    private var detected: DetectedLink? { LinkDetector.detect(input) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    inputCard
                    detectedChip
                    actionButtons
                    hintCard
                    Spacer(minLength: 0)
                }
                .padding()
            }
            .navigationTitle("云析")
            .scrollDismissesKeyboard(.immediately)
            .onTapGesture { inputFocused = false }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { inputFocused = false }
                }
            }
            .sheet(item: $result) { item in
                ResultView(result: item)
                    .environmentObject(store)
            }
            .sheet(isPresented: $showManual) {
                AddDownloadView(initialText: input)
                    .environmentObject(store)
            }
            .alert("解析失败", isPresented: $showError) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if input.isEmpty {
                    Text("粘贴分享链接或直链，例如 快手/微博 作品页、夸克/蓝奏云分享、或任意 http 直链")
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                }
                TextEditor(text: $input)
                    .frame(minHeight: 130)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .scrollContentBackground(.hidden)
                    .focused($inputFocused)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private var detectedChip: some View {
        if let link = detected {
            HStack(spacing: 8) {
                Circle().fill(link.platform.color).frame(width: 8, height: 8)
                Text("识别为 \(link.platform.display)")
                    .font(.footnote.weight(.semibold))
                Text(link.kind)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemBackground), in: Capsule())
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    if let text = UIPasteboard.general.string { input = text }
                } label: {
                    Label("粘贴", systemImage: "doc.on.clipboard")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    parse()
                } label: {
                    if busy {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Label("解析", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Button {
                showManual = true
            } label: {
                Label("直接当直链下载", systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var hintCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("当前已接入")
                .font(.footnote.weight(.semibold))
            Text("快手（视频 / 图集）、微博（视频 / 九宫格）、蓝奏云、夸克分享、任意 Range 直链")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("10 家网盘链接都能识别并带提取码；已通：蓝奏云、夸克（游客 50MB，登录后不限）")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text("待接：抖音 / 小红书 / B站 / Pixiv / AcFun，UC / 百度 / 123 / 115 / 迅雷 / 139 / 光鸭 / 蓝奏云优享版")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func parse() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputFocused = false
        busy = true
        Task {
            defer { Task { @MainActor in busy = false } }
            do {
                if let parsed = try await ParseService.parse(text: text) {
                    await MainActor.run { result = parsed }
                } else {
                    await MainActor.run {
                        errorMessage = "没识别出受支持的平台链接。想直接下载的话，点下面的「直接当直链下载」。"
                        showError = true
                    }
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        }
    }
}

// MARK: - 下载页

struct DownloadListView: View {

    @EnvironmentObject private var store: DownloadStore

    var body: some View {
        NavigationStack {
            Group {
                if store.jobs.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(store.jobs) { job in
                            JobRow(job: job)
                        }
                        .onDelete(perform: store.remove)
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("下载")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("清理已完成") { store.clearCompleted() }
                        .disabled(store.jobs.allSatisfy { $0.state != .completed })
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 60, weight: .light))
                .foregroundStyle(.secondary)
            Text("还没有下载任务")
                .font(.title3.weight(.semibold))
            Text("去「解析」页粘贴链接，最多 \(store.defaultConnections) 线程并发下载")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }
}

struct JobRow: View {

    @ObservedObject var job: DownloadJob
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.name)
                        .font(.headline)
                        .lineLimit(2)
                    Text(job.url.absoluteString)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(job.state.title)
                    .font(.caption)
                    .foregroundStyle(color)
            }

            if job.total > 0 {
                ProgressView(value: job.progress).tint(color)
            } else {
                ProgressView().tint(color)
            }

            HStack(spacing: 12) {
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                buttons
            }
        }
        .padding(.vertical, 6)
    }

    private var color: Color {
        switch job.state {
        case .completed: return .green
        case .failed: return .red
        case .paused: return .orange
        default: return .accentColor
        }
    }

    private var detailText: String {
        if job.total > 0 {
            let base = "\(Formatters.bytes(job.received)) / \(Formatters.bytes(job.total))"
            if job.state == .running, job.speed > 0 {
                return base + " · " + Formatters.speed(job.speed)
            }
            return base
        }
        return Formatters.bytes(job.received)
    }

    @ViewBuilder
    private var buttons: some View {
        switch job.state {
        case .running, .preparing:
            Button { job.pause() } label: { Image(systemName: "pause.circle") }
                .buttonStyle(.borderless)
        case .paused:
            Button { job.resume() } label: { Image(systemName: "play.circle") }
                .buttonStyle(.borderless)
        case .completed:
            ShareLink(item: job.fileURL) { Image(systemName: "square.and.arrow.up") }
                .buttonStyle(.borderless)
        default:
            EmptyView()
        }

        Button(role: .destructive) {
            confirmDelete = true
        } label: {
            Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .confirmationDialog("删除这个任务？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除并移除文件", role: .destructive) {
                job.cancel()
                try? FileManager.default.removeItem(at: job.fileURL)
            }
        }
    }
}

// MARK: - 设置页

struct SettingsView: View {

    @EnvironmentObject private var store: DownloadStore

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: Binding(get: { store.defaultConnections },
                                          set: { store.defaultConnections = $0 }), in: 1...512) {
                        HStack {
                            Text("默认线程数")
                            Spacer()
                            Text("\(store.defaultConnections)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 8) {
                        ForEach([8, 64, 128, 512], id: \.self) { count in
                            Button("\(count)") { store.defaultConnections = count }
                                .buttonStyle(.bordered)
                                .tint(store.defaultConnections == count ? Color.accentColor : Color.secondary)
                        }
                        Spacer()
                    }
                } header: {
                    Text("下载")
                } footer: {
                    Text("每片至少 64 KB，按文件大小自动收敛；引擎共用一个 FileHandle，512 线程也不会撞 fd 上限。实际并发仍受服务器限制。")
                }

                Section {
                    ForEach(Platform.allCases.filter { !["quark", "uc", "xunlei", "baidu", "c139", "pan123", "pan115", "guangya", "ilanzou", "lanzou"].contains($0.rawValue) }) { platform in
                        HStack {
                            Circle().fill(platform.color).frame(width: 8, height: 8)
                            Text(platform.display)
                            Spacer()
                            Text(status(for: platform))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("视频解析能力")
                } footer: {
                    Text("网盘解析在下面的「网盘账号」里登录后生效：夸克已接（游客≤50MB，登录后不限）。")
                }

                Section {
                    NavigationLink {
                        QuarkAccountView()
                    } label: {
                        HStack {
                            Text("夸克账号")
                            Spacer()
                            Text(QuarkCookieStore.loggedIn ? "已登录" : "未登录（游客 50MB）")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("网盘账号")
                }

                Section {
                    ForEach(NetdiskPlatform.allCases) { platform in
                        HStack {
                            Text(platform.display)
                            Spacer()
                            Text(["lanzou", "quark"].contains(platform.rawValue) ? "已接入" : "待接入")
                                .font(.caption)
                                .foregroundStyle(["lanzou", "quark"].contains(platform.rawValue) ? Color.green : Color.secondary)
                        }
                    }
                } header: {
                    Text("网盘（10 家）")
                } footer: {
                    Text("蓝奏云匿名单文件已通；夸克游客可解析 ≤50MB，登录后走账号态。其余 8 家下一轮逐个补。")
                }

                Section {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text("1.1 (b2)").foregroundStyle(.secondary)
                    }
                    Link("YunX 原始项目（AGPL-3.0）", destination: URL(string: "https://github.com/CYQawa/YunX")!)
                } header: {
                    Text("关于")
                } footer: {
                    Text("解析逻辑移植自 YunX（© CYQawa，AGPL-3.0）。本工程同样以 AGPL-3.0 分发。")
                }
            }
            .navigationTitle("设置")
        }
    }

    private func status(for platform: Platform) -> String {
        switch platform {
        case .kuaishou, .weibo, .lanzou, .quark: return "已接入"
        default: return "下一版"
        }
    }
}

enum Formatters {
    static func bytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: max(0, value))
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: Int64(max(0, bytesPerSecond))) + "/s"
    }
}
