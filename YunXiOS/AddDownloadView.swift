import SwiftUI
import UIKit

// MARK: - 解析结果页

struct ResultView: View {

    @EnvironmentObject private var store: DownloadStore
    @Environment(\.dismiss) private var dismiss

    @State private var result: ParseResult
    @State private var connections: Int

    init(result: ParseResult, connections: Int = 8) {
        _result = State(initialValue: result)
        _connections = State(initialValue: connections)
    }

    private var selectedCount: Int { result.medias.filter { $0.selected }.count }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    header
                }

                Section {
                    ForEach($result.medias) { $media in
                        mediaRow(media: $media)
                    }
                } header: {
                    Text("可下载内容（\(result.medias.count)")
                } footer: {
                    Text("直链有时效，解析后尽快下载；部分平台要求特定 Referer，下载时会自动带上。")
                }

                Section {
                    Stepper(value: $connections, in: 1...512) {
                        HStack {
                            Text("线程数")
                            Spacer()
                            Text("\(connections)").foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("下载设置")
                }
            }
            .navigationTitle(result.platform.display)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    downloadSelected()
                } label: {
                    Label("下载选中（\(selectedCount)）", systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedCount == 0)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .background(.bar)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: result.cover) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 10).fill(Color(.tertiarySystemFill))
            }
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 6) {
                Text(result.title.isEmpty ? "未命名作品" : result.title)
                    .font(.headline)
                    .lineLimit(3)
                if !result.author.isEmpty {
                    Text(result.author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !result.text.isEmpty, result.text != result.title {
                    Text(result.text)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func mediaRow(media: Binding<MediaItem>) -> some View {
        let item = media.wrappedValue
        return Button {
            media.wrappedValue.selected.toggle()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: item.selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.selected ? Color.accentColor : Color.secondary)
                Image(systemName: item.kind == .video ? "play.rectangle" : "photo")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.fileName)
                        .font(.subheadline)
                        .lineLimit(1)
                    Text([item.kind.label, item.quality].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }

    private func downloadSelected() {
        for media in result.medias where media.selected {
            _ = store.add(media: media, title: result.title, connections: connections)
        }
        dismiss()
    }
}

// MARK: - 直链下载

struct AddDownloadView: View {

    @EnvironmentObject private var store: DownloadStore
    @Environment(\.dismiss) private var dismiss

    @State private var urlString: String
    @State private var fileName = ""
    @State private var connections: Int
    @State private var showsError = false

    init(initialText: String = "", connections: Int = 8) {
        _urlString = State(initialValue: initialText)
        _connections = State(initialValue: connections)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://example.com/file.zip", text: $urlString)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        if let text = UIPasteboard.general.string { urlString = text }
                    } label: {
                        Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
                    }
                } header: {
                    Text("直链")
                }

                Section {
                    Stepper(value: $connections, in: 1...512) {
                        HStack {
                            Text("线程数")
                            Spacer()
                            Text("\(connections)").foregroundStyle(.secondary)
                        }
                    }
                    TextField("留空则使用服务器文件名", text: $fileName)
                        .autocorrectionDisabled()
                } header: {
                    Text("分片")
                } footer: {
                    Text("最多 512 线程；每片至少 64 KB，小文件会自动减少线程数。")
                }

                Section {
                    Button {
                        add()
                    } label: {
                        HStack {
                            Spacer()
                            Label("开始下载", systemImage: "arrow.down.circle.fill")
                            Spacer()
                        }
                    }
                    .disabled(urlString.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle("新建下载")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .alert("链接无效", isPresented: $showsError) {
                Button("好", role: .cancel) {}
            } message: {
                Text("请填写以 http:// 或 https:// 开头的完整地址。")
            }
        }
    }

    private func add() {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme, scheme == "http" || scheme == "https" else {
            showsError = true
            return
        }
        let name = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = store.addDirect(url: url, name: name.isEmpty ? nil : name, connections: connections)
        dismiss()
    }
}
