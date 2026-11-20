import Foundation

/// 分片下载引擎：每个分片一条 HTTP Range 请求，写进同一个文件的对应偏移。
/// 所有 delegate 回调都在同一个串行队列上执行，因此 segments 与共享 FileHandle 都不需要加锁。
/// 为了支持 512 条并发，这里只用一个共享 FileHandle（iOS 单进程 fd 上限约 256）。
final class DownloadEngine: NSObject, URLSessionDataDelegate {

    struct Segment {
        var start: Int64
        var end: Int64
        var received: Int64 = 0

        var length: Int64 {
            if end == Int64.max { return Int64.max }
            return end >= start ? end - start + 1 : 0
        }
        var isFinished: Bool { received >= length }
    }

    private let url: URL
    private let headers: [String: String]
    private let fileURL: URL
    private var segments: [Segment]
    private let useRange: Bool
    private var session: URLSession?
    private var pending = 0
    private var cancelled = false
    private var finished = false
    private var handle: FileHandle?
    private var receivedTotal: Int64 = 0

    var onProgress: ((Int64) -> Void)?
    var onFinish: ((Error?) -> Void)?

    init(url: URL, headers: [String: String] = [:], fileURL: URL, segments: [Segment], useRange: Bool) {
        self.url = url
        self.headers = headers
        self.fileURL = fileURL
        self.segments = segments
        self.useRange = useRange
        super.init()
    }

    var snapshot: [Segment] { segments }

    func start() {
        receivedTotal = segments.reduce(0) { $0 + $1.received }
        handle = (try? FileHandle(forWritingTo: fileURL)) ?? nil
        if useRange && handle == nil {
            finish(DownloadEngine.makeError("打不开目标文件"))
            return
        }

        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = max(1, min(512, segments.count))
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 3600
        config.waitsForConnectivity = true
        config.allowsCellularAccess = true
        config.httpShouldUsePipelining = true
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session

        for index in segments.indices where !segments[index].isFinished {
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            if useRange {
                let from = segments[index].start + segments[index].received
                request.setValue("bytes=\(from)-\(segments[index].end)", forHTTPHeaderField: "Range")
            }
            let task = session.dataTask(with: request)
            task.taskDescription = String(index)
            pending += 1
            task.resume()
        }

        if pending == 0 {
            finish(nil)
        }
    }

    func cancel() {
        cancelled = true
        session?.invalidateAndCancel()
        session = nil
    }

    private func closeHandle() {
        try? handle?.close()
        handle = nil
    }

    private func finish(_ error: Error?) {
        if finished { return }
        finished = true
        closeHandle()
        session?.finishTasksAndInvalidate()
        session = nil
        let callback = onFinish
        DispatchQueue.main.async { callback?(error) }
    }

    private static func makeError(_ message: String) -> NSError {
        NSError(domain: "YunXiOS", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if cancelled || finished { return }
        guard let description = dataTask.taskDescription,
              let index = Int(description),
              index < segments.count else { return }

        if handle == nil {
            handle = try? FileHandle(forWritingTo: fileURL)
        }
        guard let handle = handle else { return }

        let offset = segments[index].start + segments[index].received
        do {
            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: data)
        } catch {
            finish(error)
            return
        }

        segments[index].received += Int64(data.count)
        receivedTotal += Int64(data.count)
        onProgress?(receivedTotal)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if cancelled || finished { return }

        if let error = error {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
            finish(error)
            return
        }

        pending = max(0, pending - 1)
        if pending == 0 {
            finish(nil)
        }
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        closeHandle()
    }
}
