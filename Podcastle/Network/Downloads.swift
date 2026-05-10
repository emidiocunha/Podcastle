//
//  Downloads.swift
//  Podcastle
//
//  Created by Emídio Cunha on 28/06/2023.
//
//  MIT License
//
//  Copyright (c) 2025 Emídio Cunha
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

import Foundation
import UIKit

typealias ProgressHandler = (Double) -> Void
typealias CompletionHandler = (URL?, Error?) -> Void

// URLSession background identifier — shared with AppDelegate for handleEventsForBackgroundURLSession
let kBackgroundDownloadIdentifier = "com.mobyte.voicefeed.episodeDownloads"

// Represents a download task, including progress and file info.
struct Download {
    var url: URL
    var localURL: URL
    var task: Task<(Bool), any Error>?      // Swift Task for foreground streaming downloads
    var sessionTask: URLSessionTask?        // URLSessionTask for background episode downloads
    var progress: Double
    var temp: Bool
    var overwrite: Bool
}

// Observable class that tracks active download states and progress.
@MainActor class DownloadStatus:ObservableObject {
    @Published var downloads:[Download] = []
    static let shared = DownloadStatus()

    // Adds a new download to the status list if not already present.
    func addDownload(_ download:Download) {
        guard downloadWithURL(download.url) == nil else {
            return
        }
        downloads.append(download)
    }

    // Removes a download from the status list by URL.
    func removeDownload(_ url: URL) {
        downloads.removeAll(where: {$0.url == url} )
    }

    // Retrieves a download object matching the given URL.
    func downloadWithURL(_ url: URL) -> Download? {
        return downloads.first(where: {$0.url == url} )
    }

    // Updates the progress for a given URL if progress has advanced.
    func setDownloadProgress(_ url:URL, progress:Double) {
        if let index = downloads.firstIndex(where: {$0.url == url }) {
            if (downloads[index].progress < progress) {
                downloads[index].progress = progress
            }
        }
    }

    // Returns the current progress for a download URL, if any.
    func progress(_ url:URL) -> Double? {
        if let d = downloadWithURL(url) {
            return d.progress
        }
        return nil
    }

    // Checks if a download with the given URL is in progress.
    func contains(_ url:URL) -> Bool {
        return downloadWithURL(url) != nil
    }
}

// Handles URLSessionDownloadDelegate callbacks on behalf of the Downloads actor.
// Kept as a separate NSObject subclass so delegate calls arrive on the URLSession's
// own serial queue without needing actor-hop overhead.
// Thread-safety for shared mutable state is provided by a single NSLock.
private final class BackgroundDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    private let lock = NSLock()

    // Continuations keyed by URLSessionTask.taskIdentifier — present when the app
    // is live and startDownload() is awaiting the result.
    private var continuations: [Int: CheckedContinuation<Bool, Error>] = [:]
    // In-memory destination map for fast lookup while the app is active.
    private var destinations: [Int: URL] = [:]

    // Reports per-chunk progress to DownloadStatus on the main actor.
    var onProgress: ((URL, Double) -> Void)?
    // Invoked on the main thread once all pending background events have been delivered.
    // AppDelegate must call the system completion handler here.
    var onAllEventsDelivered: (() -> Void)?

    // MARK: - Registration

    func register(task: URLSessionDownloadTask, destination: URL,
                  continuation: CheckedContinuation<Bool, Error>) {
        lock.withLock {
            continuations[task.taskIdentifier] = continuation
            destinations[task.taskIdentifier] = destination
        }
        // Persist destination so we can move the file if the app is killed mid-download
        persistDestination(destination.path, for: task.taskIdentifier)
    }

    // MARK: - Destination persistence (survives app kill / restart)

    private func persistDestination(_ path: String, for taskID: Int) {
        var map = UserDefaults.standard.dictionary(forKey: "bgDownloads") as? [String: String] ?? [:]
        map[String(taskID)] = path
        UserDefaults.standard.set(map, forKey: "bgDownloads")
    }

    private func loadPersistedDestination(for taskID: Int) -> URL? {
        let map = UserDefaults.standard.dictionary(forKey: "bgDownloads") as? [String: String] ?? [:]
        return map[String(taskID)].map { URL(fileURLWithPath: $0) }
    }

    private func removePersistedDestination(for taskID: Int) {
        var map = UserDefaults.standard.dictionary(forKey: "bgDownloads") as? [String: String] ?? [:]
        map.removeValue(forKey: String(taskID))
        UserDefaults.standard.set(map, forKey: "bgDownloads")
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let taskID = downloadTask.taskIdentifier

        // Pull destination + continuation atomically before doing anything else
        let (destination, continuation) = lock.withLock { () -> (URL?, CheckedContinuation<Bool, Error>?) in
            (destinations.removeValue(forKey: taskID),
             continuations.removeValue(forKey: taskID))
        }

        // Fall back to the persisted map when the app was woken from a kill
        let finalDest = destination ?? loadPersistedDestination(for: taskID)

        // CRITICAL: move the temp file synchronously — iOS deletes it the moment this
        // method returns, so no async work can happen before the move.
        var success = false
        if let dest = finalDest {
            let fm = FileManager.default
            do {
                if fm.fileExists(atPath: dest.path) {
                    try fm.removeItem(at: dest)
                }
                try fm.moveItem(at: location, to: dest)
                success = true
                print("Background download finished: \(dest.lastPathComponent)")
            } catch {
                print("Background download: failed to move file: \(error)")
            }
        } else {
            print("Background download: no destination for task \(taskID), file discarded")
        }

        removePersistedDestination(for: taskID)

        // Resume the Swift continuation when the app was alive during the download
        continuation?.resume(returning: success)

        // Always post a notification — covers the app-wakeup case where no continuation exists
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .episodesChangedNotification, object: nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error else { return }

        let taskID = task.taskIdentifier
        let continuation = lock.withLock {
            destinations.removeValue(forKey: taskID)
            return continuations.removeValue(forKey: taskID)
        }
        removePersistedDestination(for: taskID)
        continuation?.resume(throwing: error)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let url = downloadTask.originalRequest?.url else { return }
        let progress: Double
        if totalBytesExpectedToWrite > 0 {
            // Known content-length: report exact percentage
            progress = floor(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) * 100.0)
        } else {
            // Content-Length unknown (server didn't send it): pulse between 0–90
            // using a log scale so the bar moves visibly without implying 100%.
            let mb = Double(totalBytesWritten) / 1_048_576.0
            progress = min(90.0, floor(log2(mb + 1) * 15.0))
        }
        onProgress?(url, progress)
    }

    // After all background events are delivered, call the system completion handler so
    // iOS knows the app has finished processing and can snapshot it again.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            self?.onAllEventsDelivered?()
            self?.onAllEventsDelivered = nil
        }
    }
}

// Manages file downloads and communicates with DownloadStatus.
actor Downloads: NSObject, ObservableObject, Sendable {
    private var status:DownloadStatus?
    private let bgDelegate = BackgroundDownloadDelegate()
    private var _backgroundSession: URLSession?

    // Lazily creates (or reconnects to) the background URLSession.
    // Must always use the same identifier so iOS can match pending background events.
    private func makeBackgroundSession() -> URLSession {
        if let s = _backgroundSession { return s }
        let config = URLSessionConfiguration.background(withIdentifier: kBackgroundDownloadIdentifier)
        config.sessionSendsLaunchEvents = true  // Wake app when downloads complete
        config.isDiscretionary = false           // Start promptly, not deferred to idle
        let s = URLSession(configuration: config, delegate: bgDelegate, delegateQueue: nil)
        _backgroundSession = s
        return s
    }

    // Sets the download status observer for the session.
    func setup(status:DownloadStatus) {
        self.status = status
        bgDelegate.onProgress = { [weak status] url, progress in
            Task { @MainActor in
                await status?.setDownloadProgress(url, progress: progress)
            }
        }
    }

    // Called by AppDelegate.handleEventsForBackgroundURLSession.
    // Reconnects to the background session so iOS can deliver pending completion events,
    // then calls the system handler once all events have been processed.
    func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        bgDelegate.onAllEventsDelivered = handler
        _ = makeBackgroundSession()  // Ensure session exists to receive pending events
    }

    // Checks whether a file already exists at the given local path.
    func exists(_ localPath:String) -> (Bool, URL?, Bool) {
        if localPath.contains(FileManager.default.temporaryDirectory.path()) {
            return (false, URL(fileURLWithPath: localPath), true)
        }
        return (FileManager().fileExists(atPath: localPath), URL(fileURLWithPath: localPath), false)
    }

    // Cancels a download task by URL string identifier.
    func cancelDownload(_ id:String) async {
        if let url = URL(string:id) {
            if let d = await status?.downloadWithURL(url) {
                d.task?.cancel()
                d.sessionTask?.cancel()
            }
            await status?.removeDownload(url)
        }
    }

    // Downloads a file to a temporary path with overwrite allowed.
    func downloadTempFile(_ url:String) async throws -> (URL?, Bool) {
        let uniqueIdentifier = UUID().uuidString
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let temporaryFilename = temporaryDirectory.appendingPathComponent("\(uniqueIdentifier)").path()

        return try await downloadFile(url, localPath: temporaryFilename, overwrite:true, progress:false)
    }

    // Downloads a file to disk using the foreground streaming approach.
    // Suitable for small files (feeds, artwork) that don't need background support.
    func downloadFile(_ url:String, localPath:String, overwrite:Bool, progress:Bool) async throws -> (URL?, Bool) {
        if let url = URL(string: url) {
            let (fileExists, localURL, temp) = exists(localPath)

            if fileExists && !overwrite {
#if DEBUG
                print("\(localPath) already exists, will not download file")
#endif
                return (localURL!, true)
            }

            if let localURL = localURL {
                let task = Task {
                    try await URLSession.shared.download(from:url, localURL: localURL, downloadStatus:status)
                }

                let download = Download(url:url, localURL: localURL, task:task, sessionTask: nil,
                                        progress:0.0, temp: temp, overwrite: overwrite)

                if progress {
                    await status?.addDownload(download)
                }

                let result = try await task.value

                if progress {
                    await status?.removeDownload(download.url)
                }

                return (localURL, result)
            }
        }

        return (nil, false)
    }

    // Initiates a background URLSessionDownloadTask for an Episode's audio file.
    // The task is handed to iOS and continues even when the app is backgrounded or killed.
    func startDownload(_ item:Episode) async {
        guard let audioURL = URL(string: item.audio),
              let localURL = item.fullLocalUrl(.audio) else { return }

        guard !FileManager.default.fileExists(atPath: localURL.path) else { return }

        let session = makeBackgroundSession()
        let task = session.downloadTask(with: audioURL)

        let download = Download(url: audioURL, localURL: localURL, task: nil, sessionTask: task,
                                progress: 0.0, temp: false, overwrite: false)
        await status?.addDownload(download)

        do {
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                bgDelegate.register(task: task, destination: localURL, continuation: continuation)
                task.resume()
            }
        } catch {
            if (error as? URLError)?.code != .cancelled {
                print("Episode download failed for '\(item.title)': \(error)")
            }
        }

        await status?.removeDownload(audioURL)
    }

    // Checks for missing audio files and downloads them as needed.
    func checkForDownloads(_ feed:[Episode]) async {
        for p in feed {
            let (fileExists, _, _) = self.exists(p.fullLocalUrl(.audio)!.path())

            if fileExists {
                #if DEBUG
                print("\(p.fullLocalUrl(.audio)!.path()) already exists, will not download file")
                #endif
            } else {
                await self.startDownload(p)
            }
        }
    }
}


// Initiates a download from URL using the provided local path.
extension URLSession {
    func download(from url: URL, localURL:URL, downloadStatus:DownloadStatus?) async throws -> Bool {
        try await download(for: URLRequest(url: url), localURL: localURL, downloadStatus: downloadStatus)
    }

    // Performs streaming download with progress reporting and cancellation support.
    func download(for request: URLRequest, localURL:URL, downloadStatus:DownloadStatus?) async throws -> Bool {
        var totalUnitCount:Int64

        // 1MB buffer
        let bufferSize =  1_048_576
        let estimatedSize: Int64 = 1_000_000

        let (asyncBytes, response) = try await bytes(for: request, delegate: nil)

        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let expectedLength = response.expectedContentLength
        totalUnitCount = expectedLength > 0 ? expectedLength : estimatedSize

        guard let output = OutputStream(url: localURL, append: false) else {
            return false
        }

        output.open()

        let mem = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        let array = UnsafeMutableBufferPointer(start: mem, count: bufferSize)

        defer {
            mem.deallocate()
            output.close()
        }

        var count: Int64 = 0
        var index: Int = 0

        do {
            for try await byte in asyncBytes {
                count += 1
                array[index] = byte
                index += 1

                if index >= bufferSize {
                    try Task.checkCancellation()

                    let data = Data(bytes: array.baseAddress!, count: index)
                    try output.write(data)

                    index = 0

                    Task {
                        await downloadStatus?.setDownloadProgress(request.url!, progress: floor(Double(count) / Double(totalUnitCount) * 100))
                    }
                }
            }
        } catch {
            output.close()
            if FileManager.default.fileExists(atPath: localURL.path) {
                try FileManager.default.removeItem(at: localURL)
            }
            return false
        }

        if index != 0 && index < bufferSize {
            let data = Data(bytes: array.baseAddress!, count: index)

            if data.count > 0 {
                try output.write(data)
            }
        }

        output.close()

        return true
    }
}

// Writes a Data buffer to the stream with safety checks.
extension OutputStream {
    enum OutputStreamError: Error {
       case stringConversionFailure
       case bufferFailure
       case writeFailure
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) throws in
            guard var pointer = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw OutputStreamError.bufferFailure
            }

            var bytesRemaining = buffer.count

            while bytesRemaining > 0 {
                let bytesWritten = write(pointer, maxLength: bytesRemaining)
                if bytesWritten < 0 {
                    throw OutputStreamError.writeFailure
                }

                bytesRemaining -= bytesWritten
                pointer += bytesWritten
            }
        }
    }
}
