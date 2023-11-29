//
//  Podcasts.swift
//  VoiceFeed
//
//  Created by Emídio Cunha on 11/06/2023.
//

import Foundation
import CryptoKit
import AVFoundation

class PodcastParser: NSObject, XMLParserDelegate /*, URLSessionDownloadDelegate */ {
    
    private var currentElement: String = ""
    private var currentTitle: String = ""
    private var currentDescription: String = ""
    private var currentSummary: String = ""
    private var currentLink: String = ""
    private var currentImageURL: String = ""
    private var currentAudioURL: String = ""
    private var currentDate: String = ""
    private var currentDuration: String = ""
    private var currentAuthor: String = ""
    
    private var isParsingItem = false
    private var podcasts: [Podcast] = []
    private var currentPodcast: Podcast?
    private var isFirstItem = false
    private var feed:String = ""
    
    private var completionHandler:([Podcast]) -> Void = {_ in }
    
    private var altArtwork:String = ""
    private var nest:Bool = true
    
    func parseRSSFeed(url:URL, artwork:String, nest:Bool, completion: @escaping ([Podcast]) -> Void) {
        completionHandler = completion
        
        altArtwork = artwork
        feed = url.path()
        self.nest = nest
        guard let parser = XMLParser(contentsOf: url) else {
            print("Failed to initialize XML parser")
            return
        }
        
        parser.delegate = self
        parser.parse()
        
    }
    
    // Download code
    /*
    
    func downloadFeed(url:URL) {
        let config = URLSessionConfiguration.default
        config.sessionSendsLaunchEvents = true
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        let backgroundTask = session.downloadTask(with: url)
        backgroundTask.resume()
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let parser = XMLParser(contentsOf: location) else {
            print("Failed to initialize XML parser")
            return
        }
        
        parser.delegate = self
        parser.parse()
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil {
            print("\(error!.localizedDescription)")
        }
    }*/
    
    // MARK: - XMLParserDelegate Methods
    
    func parserDidStartDocument(_ parser: XMLParser) {
        isFirstItem = true
        podcasts.removeAll()
    }
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
        if elementName == "item" {
            isParsingItem = true
            currentPodcast = Podcast()
        } else if elementName == "itunes:image" {
            currentImageURL = attributeDict["href"] ?? ""
        } else if elementName == "enclosure" {
            currentAudioURL = attributeDict["url"] ?? ""
        }
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        let parsedString = string.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if !parsedString.isEmpty {
            switch currentElement {
            case "title":
                if isParsingItem {
                    currentTitle += parsedString
                }
            case "description":
                if isParsingItem {
                    currentDescription += parsedString
                }
            case "link":
                if isParsingItem {
                    currentLink += parsedString
                }
            case "itunes:summary":
                if isParsingItem {
                    currentSummary += parsedString
                }
            case "pubDate":
                if isParsingItem {
                    currentDate += parsedString
                }
            case "itunes:duration":
                if isParsingItem {
                    currentDuration += parsedString
                }
            case "itunes:author":
                if isParsingItem {
                    currentAuthor += parsedString
                }
            default:
                break
            }
        }
    }
    
    func parseDate(_ dateString:String) -> Date {
        let fmt = DateFormatter()
        let fmts = ["yyyy-MM-dd'T'HH:mm:ssZ", "E, d MMM yyyy HH:mm:ss Z", "E, d MMM yyyy HH:mm Z", "E, d MMM yyyy HH:mm:ss zzz"]
        var date = Date()
        
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone.autoupdatingCurrent
        for f in fmts {
            fmt.dateFormat = f
            if let td = fmt.date(from: dateString) {
                date = td
                break
            }
        }
        return date
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "item" {
            isParsingItem = false
        
            currentPodcast?.title = currentTitle
            currentPodcast?.description = currentDescription
            currentPodcast?.summary = currentSummary
            currentPodcast?.link = currentLink
            currentPodcast?.artworkUrl = currentImageURL.count > 0 ? currentImageURL : altArtwork
            currentPodcast?.audioUrl = currentAudioURL
            currentPodcast?.date = parseDate(currentDate)
            
            let c = currentDuration.components(separatedBy: ":")
            if c.count > 1 {
                var s = 0
                if c.count == 3 {
                    s += (Int(c[0]) ?? 0) * 3600
                    s += (Int(c[1]) ?? 0) * 60
                    s += (Int(c[2]) ?? 0)
                } else {
                    s += (Int(c[0]) ?? 0) * 60
                    s += (Int(c[1]) ?? 0)
                }
                currentPodcast?.duration = Double(s)
            } else {
                currentPodcast?.duration = Double(currentDuration) ?? 0.0
            }
            
            currentPodcast?.localAudioUrl = localUrl(currentAudioURL)
            currentPodcast?.localArtworkUrl = localUrl(currentImageURL)
                    
            currentPodcast?.author = currentAuthor
            currentPodcast?.otherEpisodes = nil
                        
            if let podcast = currentPodcast {
                if !Subscriptions.shared.wasPodcastEpisodeDeleted(podcast) {
                    podcasts.append(podcast)
                }
            }
            
            currentTitle = ""
            currentDescription = ""
            currentSummary = ""
            currentLink = ""
            currentImageURL = ""
            currentAudioURL = ""
            currentPodcast = nil
            currentDate = ""
            currentDuration = ""
            currentAuthor = ""
        }
    }
    
    func localUrl(_ urlString:String) -> String {
        if let url = URL(string:urlString) {
            let hashed = SHA256.hash(data: urlString.data(using: .utf8)!)
            let fileName = String(format: "%@.%@", hashed.compactMap { String(format: "%02x", $0) }.joined(), url.pathExtension)
            
            return fileName
        }
        return ""
    }
    
    func parserDidEndDocument(_ parser: XMLParser) {
        if !nest {
            completionHandler(podcasts)
        } else if let first = podcasts.first {
            currentPodcast = Podcast()
            currentPodcast?.title = first.title
            currentPodcast?.description = first.description
            currentPodcast?.summary = first.summary
            currentPodcast?.link = first.link
            currentPodcast?.artworkUrl = first.artworkUrl
            currentPodcast?.audioUrl = first.audioUrl
            currentPodcast?.date = first.date
            currentPodcast?.duration = first.duration
            currentPodcast?.localAudioUrl = first.localAudioUrl
            currentPodcast?.localArtworkUrl = first.localArtworkUrl
            currentPodcast?.author = first.author
            
            // Only show up to N podcasts. Todo: Configure this value
            let n = podcasts.count
            if n > 10 {
                currentPodcast?.otherEpisodes = Array(podcasts.dropFirst().dropLast(n - 10))
            } else {
                currentPodcast?.otherEpisodes = Array(podcasts.dropFirst())
            }
            
            podcasts.insert(currentPodcast!, at: 0)
            completionHandler([currentPodcast!])
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        print("error \(parseError.localizedDescription)")
        parser.abortParsing()
        parserDidEndDocument(parser)
    }
}

struct PodcastNote:Identifiable, Codable, Equatable {
    var audioUrl:String
    var position:Double
    var deleted:Bool
    var id:String {audioUrl}
}

enum PodcastURLType {
    case artwork
    case audio
}

struct Podcast:Identifiable,Codable,Equatable {
    var title: String = ""
    var description: String = ""
    var summary: String = ""
    var author: String = ""
    var link: String = ""
    var artworkUrl: String = ""
    var audioUrl: String = ""
    var date: Date = Date()
    var duration: Double = 0.0
    var localArtworkUrl = ""
    var localAudioUrl = ""
    var id:String {audioUrl}
    var otherEpisodes:[Podcast]?
    
    func prettySinceDate() -> String {
        let dif = abs(date.timeIntervalSinceNow) / 3600.0
        
        if dif > 24 {
            let days = ceil(dif / 24)
            let s = days >= 2 ? "s" : ""
            
            return "\(String(format:"%.0f", days)) Day\(s) ago"
        } else if dif < 1 {
            let minutes = dif * 60
            let s = minutes >= 2 ? "s" : ""
            
            return "\(String(format:"%.0f", minutes)) Minute\(s) ago"
        }
        
        let s = dif >= 2 ? "s" : ""
        return "\(String(format:"%.0f", dif)) Hour\(s) ago"
    }
    
    func prettyDate() -> String {
        let df = DateFormatter()
        
        df.dateStyle = .short
        
        return df.string(from: date)
    }
        
    func makeLocalUrl(_ urlString:String) -> String {
        if let url = URL(string:urlString) {
            let hashed = SHA256.hash(data: urlString.data(using: .utf8)!)
            let fileName = String(format: "%@.%@", hashed.compactMap { String(format: "%02x", $0) }.joined(), url.pathExtension)
            
            return fileName
        }
        return ""
    }
    
    func fullLocalUrl(_ urlString:String) -> URL? {
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first, urlString.count > 0 {
            return documents.appendingPathComponent(urlString, isDirectory: false)
        } else {
            return nil
        }
    }
    
    func fullLocalUrl(_ podcastUrlType:PodcastURLType) -> URL? {
        switch(podcastUrlType) {
        case .artwork:
            return fullLocalUrl(localArtworkUrl)
        case .audio:
            return fullLocalUrl(localAudioUrl)
        }
    }
    
    func fileSize(_ podcastUrlType:PodcastURLType) -> String {
        guard let path = fullLocalUrl(podcastUrlType) else {
            return ""
        }
        
        do {
            if FileManager().fileExists(atPath: path.path()) {
                let fileAttributes = try FileManager.default.attributesOfItem(atPath: path.path())
                if let fileSize = fileAttributes[FileAttributeKey.size] as? Double {
                    // Convert the file size to megabytes
                    let fileSizeInMB = fileSize / (1024 * 1024)
                    return String(format: "%.1f MB", fileSizeInMB)
                }
            }
        } catch {
            print("Error: \(error)")
        }
        
        return ""
    }
    
    static func ==(lhs: Podcast, rhs: Podcast) -> Bool {
        return lhs.audioUrl == rhs.audioUrl && lhs.date == rhs.date
    }
}


