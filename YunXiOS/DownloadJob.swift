import Foundation
import Combine

enum DownloadState: Equatable {
    case idle
    case preparing
    case running
    case paused
    case completed
    case failed(String)

    var isActive: Bool {
        switch self {
        case .preparing, .running: return true
        default: return false
        }
    }

    var title: String {
        switch self {
        case .idle: return "等待开始"
        case .preparing: return "解析中…"
        case .running: return "下载中"
        case .paused: return "已暂停"
        case .completed: return "已完成"
        case .failed(let message): return "失败：\(message)"
        }
    }
}

/// 单个下载任务：HEAD 探测 → 切片 → 并发 Range 下载 → 落盘，支持暂停/续传。
final class DownloadJob: ObservableObject, Identifiable {

    let id = UUID()
    let url: URL
    let headers: [String: String]
    let connections: Int

    @Published var name: String
    @Published var state: DownloadState = .idle
    @Published var received: Int64 = 0
    @Published var total: Int64 = 0
    @Published var speed: Double = 0

    private(set) var fileURL: URL
    private var engine: DownloadEngine?
    private var segments: [DownloadEngine.Segment] = []
    private var useRange = false
    private var speedTimer: Timer?
    private var lastBytes: Int64 = 0
    private var lastTime = Date()

    init(url: URL, name: String? = nil, headers: [String: String] = [:], connections: Int = 8) {
        self.url = url
        self.headers = headers
        self.connections = max(1, min(512, connections))
        let fallback = url.lastPathComponent.isEmpty ? "download.bin" : url.lastPathComponent
        let resolved: String = (name?.isEmpty == false) ? (name ?? fallback) : fallback
        self.name = resolved
        self.fileURL = DownloadJob.uniqueFileURL(named: resolved)
    }

    deinit {
        speedTimer?.invalidate()
    }

    // MARK: - 对外操作

    func start() {
        guard !state.isActive else { return }
        state = .preparing
        probe { [weak self] size, supportsRange, suggested in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if let suggested = suggested, !suggested.isEmpty, self.name == self.fileURL.lastPathComponent {
                    self.name = suggested
                    self.fileURL = DownloadJob.uniqueFileURL(named: suggested)
                }
                self.begin(size: size, supportsRange: supportsRange)
            }
        }
    }

    func pause() {
        guard state.isActive else { return }
        speedTimer?.invalidate()
        speedTimer = nil
        engine?.cancel()
        segments = engine?.snapshot ?? segments
        engine = nil
        speed = 0
        state = .paused
    }

    func resume() {
        guard case .paused = state else { return }
        guard !segments.isEmpty else {
            start()
            return
        }
        state = .running
        runEngine()
    }

    func cancel() {
        engine?.cancel()
        engine = nil
        speedTimer?.invalidate()
        speedTimer = nil
        state = .paused
        received = 0
        segments = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - 探测

    private func probe(completion: @escaping (Int64, Bool, String?) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 20
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let http = response as? HTTPURLResponse else {
                completion(-1, false, nil)
                return
            }
            guard (200...299).contains(http.statusCode) else {
                completion(-1, false, nil)
                return
            }
            var size = http.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) } ?? -1
            let acceptRanges = http.value(forHTTPHeaderField: "Accept-Ranges") ?? ""
            let supportsRange = http.statusCode == 206 || acceptRanges.lowercased().contains("bytes")
            if http.statusCode == 206,
               let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
               let totalPart = contentRange.split(separator: "/").last,
               let totalSize = Int64(totalPart.trimmingCharacters(in: .whitespaces)) {
                size = totalSize
            }
            var suggested: String?
            if let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
               let range = disposition.range(of: "filename=") {
                var value = String(disposition[range.upperBound...])
                value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                if !value.isEmpty { suggested = value }
            }
            _ = data
            _ = error
            completion(size, supportsRange, suggested)
        }.resume()
    }

    // MARK: - 开始下载

    private func begin(size: Int64, supportsRange: Bool) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        if size > 0 {
            total = size
            fileManager.createFile(atPath: fileURL.path, contents: nil)
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                try? handle.truncate(atOffset: UInt64(size))
                try? handle.close()
            }
        } else {
            total = 0
            fileManager.createFile(atPath: fileURL.path, contents: nil)
        }

        let effectiveConnections: Int
        if size > 0, supportsRange {
            // 每片至少 64 KB，避免小文件被切成一堆无效请求；上限 512 条并发。
            effectiveConnections = min(connections, max(1, Int(size / (64 * 1024))))
        } else {
            effectiveConnections = 1
        }
        useRange = size > 0 && supportsRange

        segments = DownloadJob.makeSegments(total: max(size, 0), count: effectiveConnections, useRange: useRange)
        state = .running
        runEngine()
    }

    private static func makeSegments(total: Int64, count: Int, useRange: Bool) -> [DownloadEngine.Segment] {
        guard total > 0, useRange else {
            return [DownloadEngine.Segment(start: 0, end: total > 0 ? total - 1 : Int64.max, received: 0)]
        }
        var result: [DownloadEngine.Segment] = []
        let base = total / Int64(count)
        for index in 0..<count {
            let start = Int64(index) * base
            let end = index == count - 1 ? total - 1 : Int64(index + 1) * base - 1
            result.append(DownloadEngine.Segment(start: start, end: end, received: 0))
        }
        return result
    }

    private func runEngine() {
        let cleanSegments = segments.map {
            DownloadEngine.Segment(start: $0.start, end: $0.end, received: $0.received)
        }
        segments = cleanSegments
        let engine = DownloadEngine(url: url, headers: headers, fileURL: fileURL, segments: cleanSegments, useRange: useRange)
        self.engine = engine

        engine.onProgress = { [weak self] receivedAll in
            DispatchQueue.main.async {
                self?.received = receivedAll
            }
        }
        engine.onFinish = { [weak self] error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.speedTimer?.invalidate()
                self.speedTimer = nil
                if let error = error {
                    self.state = .failed(error.localizedDescription)
                    return
                }
                self.received = self.total > 0 ? self.total : self.received
                self.progress = 1
                self.speed = 0
                self.state = .completed
            }
        }

        lastBytes = received
        lastTime = Date()
        startSpeedTimer()
        engine.start()
    }

    private func startSpeedTimer() {
        speedTimer?.invalidate()
        speedTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let now = Date()
            let deltaBytes = self.received - self.lastBytes
            let deltaTime = now.timeIntervalSince(self.lastTime)
            if deltaTime > 0 {
                self.speed = Double(max(0, deltaBytes)) / deltaTime
            }
            self.lastBytes = self.received
            self.lastTime = now
        }
        if let timer = speedTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    // MARK: - 计算属性

    var progress: Double {
        get {
            guard total > 0 else { return 0 }
            return min(1, max(0, Double(received) / Double(total)))
        }
        set { objectWillChange.send() }
    }

    static func uniqueFileURL(named rawName: String) -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var name = rawName.replacingOccurrences(of: "/", with: "_")
        if name.isEmpty { name = "download.bin" }
        var candidate = documents.appendingPathComponent(name)
        var index = 2
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        while FileManager.default.fileExists(atPath: candidate.path) {
            let suffix = ext.isEmpty ? "" : ".\(ext)"
            candidate = documents.appendingPathComponent("\(base)-\(index)\(suffix)")
            index += 1
        }
        return candidate
    }
}
