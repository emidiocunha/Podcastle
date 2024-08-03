//
//  Subscriptions.swift
//  VoiceFeed
//
//  Created by Emídio Cunha on 16/06/2023.
//

import Foundation
import UIKit
import AVFoundation

extension Notification.Name {
    static let episodesChangedNotification = Notification.Name("episodesNotification")
}

class Subscriptions:NSObject, ObservableObject /*URLSessionDownloadDelegate*/ {
    static let shared = Subscriptions()
    private var podcasts:[PodcastDirectoryEntry]?
    private var podcastNotes:[PodcastNote] = []
    @Published var feed:[Podcast] = []
    var newFeedItems:[Podcast] = []
    private var workFeed:[Podcast] = []
    let semaphore = DispatchSemaphore(value: 1)
    private var downloadCount = 0
    private var tempDuration = 0.0
    
    private override init() {
        super.init()
        load()
    }
    
    @discardableResult func saveArrayToDisk<T: Codable>(array: [T], filePath: String) -> Bool {
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let fullPath = documents.appendingPathComponent(filePath, isDirectory: false)
            do {
                let data = try JSONEncoder().encode(array)
                return FileManager.default.createFile(atPath: fullPath.path, contents: data, attributes: nil)
            } catch {
                print("Failed to save array to disk: \(error)")
                return false
            }
        }
        return false
    }

    func loadArrayFromDisk<T: Codable>(filePath: String) -> [T]? {
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let fullPath = documents.appendingPathComponent(filePath, isDirectory: false)
            if let data = FileManager.default.contents(atPath: fullPath.path) {
                do {
                    let array = try JSONDecoder().decode([T].self, from: data)
                    return array
                } catch {
                    print("Failed to load array from disk: \(error)")
                    return nil
                }
            }
        }
        return nil
    }
    
    func load() {
        var podcastEpisodes:[Podcast]?
        
        podcasts = loadArrayFromDisk(filePath: "podcasts.json") ?? []
        podcastEpisodes = removeEOF(loadArrayFromDisk(filePath: "podcastEpisodes.json") ?? [])
        podcastNotes = loadArrayFromDisk(filePath: "podcastNotes.json") ?? []
        
        if podcastEpisodes != nil {
            feed = podcastEpisodes!
        }
    }
    
    // When Sync runs, the last element which is a placeholder for EOF is also saved
    func removeEOF(_ list:[Podcast]) -> [Podcast] {
        guard list.count > 0 else { return list }
        
        if let last = list.last, last.audioUrl == "eof" {
            return list.dropLast()
        } else {
            return list
        }
    }
    
    func podcastCount() -> Int {
        return podcasts?.count ?? 0
    }
    
    func podcastDirectory() -> [PodcastDirectoryEntry] {
        return podcasts ?? []
    }
    
    func addPodcast(_ podcast:PodcastDirectoryEntry) {
        if (podcasts?.first(where: { $0.id == podcast.id })) != nil {
            // Already exists, return
            return
        }
        podcasts?.append(podcast)
        sync()
        Task { await refresh() }
    }
    
    // Directly add a podcast from URL to feed
    func addPodcast(_ podcast:String) {
        let p = PodcastDirectoryEntry(id: UInt64.max, name: "", artistName: "", feedUrl: podcast, artworkUrl: "")
        podcasts?.append(p)
        sync()
        Task { await refresh() }
    }
    
    func removePodcast(_ podcast:PodcastDirectoryEntry) {
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let fullPath = documents.appendingPathComponent(podcast.fileName(), isDirectory: false)
            let parser = PodcastParser()
            parser.parseRSSFeed(url:fullPath, artwork: podcast.artworkUrl, nest:false) { [self] items in
                items.forEach { podcastEpisode in
                    let fileManager = FileManager.default
                    
                    if let artwork = podcastEpisode.fullLocalUrl(.artwork) {
                        try? fileManager.removeItem(at:artwork)
                        print("Removing \(artwork.path())")
                    }
                    if let audio = podcastEpisode.fullLocalUrl(.audio) {
                        try? fileManager.removeItem(at:audio)
                        print("Removing \(audio.path())")
                    }
                    if let i = podcastNotes.firstIndex(where:{ $0.id == podcastEpisode.id }) {
                        podcastNotes.remove(at: i)
                        print("Removing notes id at:\(i)")
                    }
                    
                    if let i = feed.firstIndex(where: {$0.id == podcastEpisode.id }) {
                        feed.remove(at: i)
                        workFeed.remove(at: i)
                    }
                }
                podcasts?.removeAll(where: { $0.id == podcast.id })
                print("Removing Podcast with ID: \(podcast.id)")
                sync()
                Task { await refresh() }
                NotificationCenter.default.post(name: Notification.Name.episodesChangedNotification, object:nil)
            }
        }
    }
    
    func updatePodcastNote(_ podcast:Podcast, position:Double) {
        if let i = podcastNotes.firstIndex(where:{ $0.id == podcast.id }) {
            podcastNotes[i].position = position
        } else {
            podcastNotes.append(PodcastNote(audioUrl: podcast.audioUrl, position: position, deleted: false))
        }
    }
    
    func wasPodcastEpisodeDeleted(_ podcast:Podcast) -> Bool {
        if let i = podcastNotes.firstIndex(where:{ $0.id == podcast.id }) {
            return podcastNotes[i].deleted
        } else {
            return false
        }
    }
    
    func find(_ url:String) -> Podcast? {
        return find(feed, url:url)
    }
    
    func find(_ array:[Podcast], url:String) -> Podcast? {
        for podcast in array {
            if podcast.id == url {
                return podcast
            } else {
                guard podcast.otherEpisodes != nil else {
                    continue
                }
                
                if let p = find(podcast.otherEpisodes!, url:url) {
                    return p
                }
            }
        }
        return nil
    }
    
    func find(podcastId:UInt64) -> PodcastDirectoryEntry? {
        return (podcasts?.first(where: {$0.id == podcastId}))
    }
    
    // Will check an array with otherEpisodes and returns
    // the index where it was found, with the Bool indicating
    // if it's the root element
    func exists(_ array:[Podcast], item:Podcast) -> (Int, Bool) {
        for index in 0..<array.count {
            let p = array[index]
            
            if p.audioUrl == item.audioUrl {
                return (index, false)
            } else {
                if let s = p.otherEpisodes {
                    if let i = s.first(where: {$0.audioUrl == item.audioUrl}) {
                        return (index, true)
                    }
                }
            }
        }
        
        return (-1, true)
    }
    
    func deletePodcastEpisode(_ podcast:Podcast) {
        let fileManager = FileManager.default
        
        if let i = podcastNotes.firstIndex(where:{ $0.id == podcast.id }) {
            podcastNotes[i].deleted = true
        } else {
            podcastNotes.append(PodcastNote(audioUrl: podcast.audioUrl, position: 0.0, deleted: true))
        }
        if let artwork = podcast.fullLocalUrl(.artwork) {
            try? fileManager.removeItem(at:artwork)
        }
        if let audio = podcast.fullLocalUrl(.audio) {
            try? fileManager.removeItem(at:audio)
        }
        if let i = feed.firstIndex(where:{ $0.id == podcast.id }) {
            if let other = feed[i].otherEpisodes, other.count > 0 {
                if var main = other.first {
                    main.otherEpisodes = Array(other.dropFirst())
                    feed[i] = main
                }
            } else {
                feed.remove(at: i)
            }
        }
        sync()
        NotificationCenter.default.post(name: Notification.Name.episodesChangedNotification, object:nil)
    }
    
    func podcastPosition(_ podcast:Podcast) -> Double {
        if let note = podcastNotes.first(where:{ $0.id == podcast.id }) {
            return note.position
        }
        return 0.0
    }
    
    func timeLeft(_ podcast:Podcast) -> Double {
        if let note = podcastNotes.first(where:{ $0.id == podcast.id }) {
            if note.position != 0.0 {
                let l = note.position / podcast.duration
                return l * 100
            }
        }
        return 0
    }
    
    func secondsLeft(_ podcast:Podcast) -> Double {
        var r = podcast.duration
        
        if r == 0.0 {
            r = podcastDuration(podcast)
        }
        if let note = podcastNotes.first(where:{ $0.id == podcast.id }) {
            if note.position != 0.0 {
                r = podcast.duration - note.position
            }
        }

        return r
    }
    
    // This function is Sync to avoid the new .load
    func podcastDuration(_ podcast:Podcast) -> Double {
        var sizeInSeconds:Double = 0.0
        
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let fullPath = documents.appendingPathComponent(podcast.localAudioUrl, isDirectory: false)
            
            if FileManager.default.fileExists(atPath: fullPath.path()) {
                do {
                    let audioFile = try AVAudioFile(forReading: fullPath)
                    let audioFormat = audioFile.processingFormat
                    let frameCount = audioFile.length
                    let sampleRate = Double(audioFormat.sampleRate)
                    
                    sizeInSeconds = Double(frameCount) / sampleRate
                } catch {
                    print("Error determining podcast duration: \(error)")
                }
            }
        }
        
        return sizeInSeconds
    }
    
    func syncNotes() {
        saveArrayToDisk(array:podcastNotes, filePath: "podcastNotes.json")
    }
    
    func sync() {
        if let podcasts = podcasts {
            saveArrayToDisk(array: podcasts, filePath: "podcasts.json")
        }
        /*if feed.count == workFeed.count {
            saveArrayToDisk(array: workFeed, filePath: "podcastEpisodes.json")
        }*/
        saveArrayToDisk(array: feed, filePath: "podcastEpisodes.json")
        syncNotes()
        print("Saved configuration (podcasts, feed, notes)")
    }
    
    func isSubscribed(_ url:String) -> Bool {
        return (podcasts?.first(where: {$0.feedUrl == url})) != nil
    }
    
    func isSubscribed(podcastId:UInt64) -> Bool {
        return (podcasts?.first(where: {$0.id == podcastId})) != nil
    }
    
    func backgroundRefresh() {
        print("entered backgroundRefresh")
        if let podcasts = podcasts, podcasts.count > 0 {
            downloadCount = podcasts.count
            for p in podcasts {
                Downloads.shared.downloadFile(p.feedUrl, localPath:p.fileName(), overwrite:true) { progress in } completionHandler: { url, error in
                    
                    /*guard url != nil && error == nil else {
                        return
                    }*/
                    
                    let fileUrl = url ?? URL(string: p.fileName())
                        
                    let parser = PodcastParser()
                    parser.parseRSSFeed(url: fileUrl!, artwork: p.artworkUrl, nest:true) { items in
                        self.merge(items)
                    }
                    
                    print("Processing \(p.feedUrl)")
                }
            }
        }
        else {
            Task { @MainActor in
                feed = workFeed
            }
        }
    }
    
    func refresh() async {
        //workFeed.removeAll(keepingCapacity: true)
        if let podcasts = podcasts, podcasts.count > 0 {
            downloadCount = podcasts.count
            for p in podcasts {
                Downloads.shared.downloadFile(p.feedUrl, localPath:p.fileName(), overwrite:true) { progress in } completionHandler: { url, error in
                    
                    /*guard url != nil && error == nil else {
                        return
                    }*/
                    
                    let fileUrl = url ?? URL(string: p.fileName())
                        
                    let parser = PodcastParser()
                    parser.parseRSSFeed(url: fileUrl!, artwork: p.artworkUrl, nest:true) { items in
                        self.merge(items)
                    }
                    
                    print("Processing \(p.feedUrl)")
                }
            }
        }
        else {
            Task { @MainActor in
                feed = workFeed
            }
        }
    }
    
    func merge(_ w:[Podcast]) {
        //Task { @MainActor in
            var i = 0
            
            //semaphore.wait()
            
            downloadCount -= 1
            var t = workFeed
    
            w.forEach { item in
                let (i, root) = exists(workFeed, item: item)
                
                if i >= 0 {
                    t.remove(at: i)
                }
                
                t.append(item)
                
                /*if !t.contains(where: {$0.id == item.id}) {
                    newFeedItems.append(item)
                    i = i + 1
                    //checkForVideos(item)
                }*/
            }
            
            t.sort(by: {$0.date.compare($1.date) == .orderedDescending})
            
            workFeed = t
            
            //updateCount(i)
            
            if downloadCount == 0 {
                //Config.shared.setLastUpdate(Date())
                if let i = workFeed.firstIndex(where: {$0.audioUrl == "eof"}) {
                    workFeed.remove(at: i)
                }
                
                var p = Podcast()
                p.audioUrl = "eof"
                workFeed.append(p)
                if workFeed != feed {
                    Task { @MainActor in
                        let state = UIApplication.shared.applicationState
                        
                        print("Updating feed")
                        if state == .active {
                            feed = workFeed
                        }
                        sync()
                        Downloads.shared.checkForDownloads(feed)
                    }
                }
            }
            
            //semaphore.signal()
        //}
    }
    
    func checkEpisode(_ episode:Podcast) -> Bool {
        var found:Bool = false
        
        feed.forEach { podcast in
            if episode.audioUrl == podcast.audioUrl {
                found = true
            }
            if let other = episode.otherEpisodes {
                other.forEach { podcast in
                    if episode.audioUrl == podcast.audioUrl {
                        found = true
                    }
                }
            }
        }
        return found
    }
    
}
    
