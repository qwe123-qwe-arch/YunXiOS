import Foundation
import SwiftUI
import Combine

/// 任务集合。只做内存列表，杀掉 App 后清空（文件仍留在 Documents）。
final class DownloadStore: ObservableObject {

    @Published var jobs: [DownloadJob] = []

    @AppStorage("defaultConnections") var defaultConnections: Int = 8

    @discardableResult
    func add(media: MediaItem, title: String, connections: Int) -> DownloadJob {
        let preferredName = media.fileName.isEmpty ? nil : media.fileName
        let job = DownloadJob(url: media.url, name: preferredName, headers: media.headers, connections: connections)
        jobs.insert(job, at: 0)
        job.start()
        return job
    }

    @discardableResult
    func addDirect(url: URL, name: String?, connections: Int) -> DownloadJob {
        let job = DownloadJob(url: url, name: name, headers: [:], connections: connections)
        jobs.insert(job, at: 0)
        job.start()
        return job
    }

    func remove(at offsets: IndexSet) {
        for index in offsets { jobs[index].cancel() }
        jobs.remove(atOffsets: offsets)
    }

    func clearCompleted() {
        jobs.removeAll { $0.state == .completed }
    }
}
