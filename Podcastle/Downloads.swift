//
//  Downloads.swift
//  VoiceFeed
//
//  Created by Emídio Cunha on 28/06/2023.
//
import Foundation
import UIKit

typealias ProgressHandler = (Double) -> Void
typealias CompletionHandler = (URL?, Error?) -> Void

struct Download {
    var url:URL
    var localURL:URL
    var progressHandler: ProgressHandler?
    var completionHandler: CompletionHandler?
    var downloadTask: URLSessionDownloadTask
    var progress:Double
    var temp:Bool
    var overwrite:Bool
}

struct DownloadSet {
    var url:URL
    var progress:Double
}

class Downloads: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = Downloads()
    var downloads:[Download] = []
    @Published var downloadSet:[DownloadSet] = []
    private let accessQueue = DispatchQueue(label: "threadSafeArrayAccess")
    
    override init() {
        super.init()
    }
    
    func exists(_ localPath:String) -> (Bool, URL?, Bool) {
        if localPath.contains(FileManager.default.temporaryDirectory.absoluteString) {
            return (false, URL(string:localPath), true)
        }
        if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let localURL = d.appendingPathComponent(localPath, isDirectory: false)
            
            return (FileManager().fileExists(atPath: localURL.path()), localURL, false)
        }
        return (false, nil, false)
    }
    
    func cancelDownload(_ id:String) {
        accessQueue.sync {
            if let i = downloads.firstIndex(where: {$0.url.absoluteString == id}) {
                downloads[i].downloadTask.cancel()
            }
        }
    }
    
    func downloadTempFile(_ url:String, completionHandler: @escaping CompletionHandler) {
        let uniqueIdentifier = UUID().uuidString
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let temporaryFilename = temporaryDirectory.appendingPathComponent("\(uniqueIdentifier)").absoluteString
    
        downloadFile(url, localPath: temporaryFilename, overwrite:true, progressHandler: { progress in }, completionHandler: completionHandler)
    }
    
    func downloadFile(_ url:String, localPath:String, overwrite:Bool, progressHandler: @escaping ProgressHandler, completionHandler: @escaping CompletionHandler) {
        if let url = URL(string: url) {
            guard !downloads.contains(where: { download in
                return download.url == url
            }) else { return }
            
            let (fileExists, localURL, temp) = exists(localPath)
            
            if fileExists && !overwrite {
                #if DEBUG
                    print("\(localPath) already exists, will not download file")
                #endif
                completionHandler(localURL, nil)
                return
            }
            
            let backgroundIdentifier = kBackgroundIdentifier
            let backgroundConfig = URLSessionConfiguration.background(withIdentifier: backgroundIdentifier)
            backgroundConfig.sessionSendsLaunchEvents = true
            let session = URLSession(configuration: backgroundConfig, delegate: self, delegateQueue: nil)
            let downloadTask = session.downloadTask(with: url)
            
            if let localURL = localURL {
                accessQueue.sync {
                    downloads.append(Download(url:url, localURL: localURL, progressHandler: progressHandler, completionHandler: completionHandler, downloadTask:downloadTask, progress:0.0, temp: temp, overwrite: overwrite))
                }
            }
            
            downloadTask.resume()
        }
    }
    
    func downloadFileInBackground(_ url:String, localPath:String, overwrite:Bool) async -> Bool {
        if let url = URL(string: url) {
            guard !downloads.contains(where: { download in
                return download.url == url
            }) else { return false }
            
            let (fileExists, localURL, temp) = exists(localPath)
            
            if fileExists && !overwrite {
                #if DEBUG
                    print("\(localPath) already exists, will not download file")
                #endif
                // completionHandler(localURL, nil)
                return true
            }
            
            if let localURL = URL(string:localPath) {
                accessQueue.sync {
                    downloads.append(Download(url:url, localURL: localURL, progressHandler: nil, completionHandler: nil, downloadTask:URLSessionDownloadTask(), progress:0.0, temp: temp, overwrite: overwrite))
                }
            } else {
                return false
            }
            
            let backgroundIdentifier = kBackgroundIdentifier
            let backgroundConfig = URLSessionConfiguration.background(withIdentifier: backgroundIdentifier)
            backgroundConfig.sessionSendsLaunchEvents = true
            let session = URLSession(configuration: backgroundConfig)
            let request = URLRequest(url:url)
            
            let task = session.downloadTask(with: request)
            
            task.delegate = self
            
            task.resume()
            
            return true
            
            /*
            
            let response = await withTaskCancellationHandler {
                try? await session.data(for:request)
            } onCancel: {
                let task = session.downloadTask(with: request)
                task.resume ()
            }
            
            if let (data, _) = response {
                var download:Download?
                
                accessQueue.sync {
                    download = downloads.first(where: {$0.url == url})
                }
                
                if let download = download, let localURL = localURL {
                    do {
                        if download.overwrite {
                            if FileManager.default.fileExists(atPath: download.localURL.path()) {
                                try FileManager.default.removeItem(at: download.localURL)
                            }
                        }
                        try data.write(to: localURL, options: .atomic)
                    } catch {
                        print("Download error: \(error.localizedDescription)")
                    }
                    
                    accessQueue.sync {
                        downloads.removeAll(where: {$0.url == url})
                    }
                }
            }
            return true
             */
        }
        return false
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        var download:Download?
        
        accessQueue.sync {
            download = downloads.first(where: {$0.downloadTask.taskIdentifier == downloadTask.taskIdentifier})
        }
        
        if let download = download {
            do {
                if download.overwrite {
                    if FileManager.default.fileExists(atPath: download.localURL.path()) {
                        try FileManager.default.removeItem(at: download.localURL)
                    }
                }
                try FileManager.default.copyItem(at: location, to: download.localURL)
            } catch {
                print("Download error: \(error.localizedDescription)")
            }
            
            download.completionHandler?(download.localURL, nil)
            
            accessQueue.sync {
                downloads.removeAll(where: {$0.downloadTask.taskIdentifier == downloadTask.taskIdentifier})
            }
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        accessQueue.sync {
            if let download = downloads.first(where: {$0.downloadTask.taskIdentifier == task.taskIdentifier}) {
                download.completionHandler?(download.localURL, error)
            }
            downloads.removeAll(where: {$0.downloadTask.taskIdentifier == task.taskIdentifier})
        }
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        accessQueue.sync {
            if let d = self.downloads.first(where: {$0.downloadTask.taskIdentifier == downloadTask.taskIdentifier}), d.temp {
                return
            }
            let progress = floor(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) * 100)
            if let i = self.downloads.firstIndex(where: {$0.downloadTask.taskIdentifier == downloadTask.taskIdentifier}) {
                let url = downloads[i].url
                
                if let d = self.downloadSet.firstIndex(where: {$0.url == url}) {
                    let download = downloadSet[d]
                
                    if progress > download.progress {
                        Task { @MainActor in
                            if let d = self.downloadSet.firstIndex(where: {$0.url == url}) {
                                var download = downloadSet[d]
                                
                                let state = UIApplication.shared.applicationState
                                if state == .active {
                                    download.progress = progress
                                    downloadSet[d] = download
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
    func startDownload(_ item:Podcast) {
        if let url = URL(string: item.audioUrl) {
            if UIApplication.shared.applicationState == .active {
                accessQueue.sync {
                    downloadSet.append(DownloadSet(url:url, progress: 0.0))
                }
            }
            Downloads.shared.downloadFile(item.audioUrl, localPath:item.localAudioUrl, overwrite: false)
            { progress in } completionHandler: { [self] fileURL, error in
                Task { @MainActor in
                    accessQueue.sync {
                        if let i = downloadSet.firstIndex(where:{$0.url == url}) {
                            downloadSet.remove(at: i)
                        }
                    }
                }
            }
        }
    }
    
    func checkForDownloads(_ feed:[Podcast]) {
        for p in feed {
            if p.id != "eof" {
                startDownload(p)
            }
        }
    }
}
