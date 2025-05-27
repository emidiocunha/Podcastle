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

// Represents a download task, including progress and file info.
struct Download {
    var url:URL
    var localURL:URL
    var task: Task<(Bool), any Error>?
    var progress:Double
    var temp:Bool
    var overwrite:Bool
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

// Manages file downloads and communicates with DownloadStatus.
actor Downloads: NSObject, ObservableObject, Sendable {
    private var status:DownloadStatus?
    
    // Sets the download status observer for the session.
    func setup(status:DownloadStatus) {
        self.status = status
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
            }
        }
    }
    
    // Downloads a file to a temporary path with overwrite allowed.
    func downloadTempFile(_ url:String) async throws -> (URL?, Bool) {
        let uniqueIdentifier = UUID().uuidString
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let temporaryFilename = temporaryDirectory.appendingPathComponent("\(uniqueIdentifier)").path()
    
        return try await downloadFile(url, localPath: temporaryFilename, overwrite:true, progress:false)
    }
    
    // Downloads a file to disk, optionally tracking progress.
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
                
                let download = Download(url:url, localURL: localURL, task:task, progress:0.0, temp: temp, overwrite: overwrite)
                
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
    
    // Initiates a download for a specific Episode.
    func startDownload(_ item:Episode) async {
        if URL(string: item.audio) != nil {
            do {
                (_, _) = try await downloadFile(item.audio, localPath: item.fullLocalUrl(.audio)!.path(), overwrite: false, progress:true)
            }
            catch {
            }
        }
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

