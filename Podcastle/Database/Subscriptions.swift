//
//  Subscriptions.swift
//  Podcastle
//
//  Created by Emídio Cunha on 16/06/2023.
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
import AVFoundation
import SwiftData

extension Notification.Name {
    static let episodesChangedNotification = Notification.Name("episodesNotification")
}

struct GroupedEpisodeList:Identifiable {
    let id = UUID()
    let episode:Episode
    let children:[GroupedEpisodeList]?
}

@ModelActor actor Subscriptions:NSObject, ObservableObject, Sendable {
    private var downloadCount = 0
    private var tempDuration = 0.0
    private var context: ModelContext { modelExecutor.modelContext }
    private var downloads:Downloads?
    
    /// Saves a Codable array to disk.
    @discardableResult nonisolated func saveArrayToDisk<T: Codable>(array: [T], filePath: String) -> Bool {
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
    
    /// Loads a Codable array from disk.
    nonisolated func loadArrayFromDisk<T: Codable>(filePath: String) -> [T]? {
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
    
    /// Initializes the Subscriptions instance with dependencies.
    func setup(downloads:Downloads) {
        self.downloads = downloads
    }
    
    /// Loads episodes grouped by directory.
    func loadFeed() -> [GroupedEpisodeList] {
        let descriptor = FetchDescriptor<Episode>(sortBy: [SortDescriptor(\Episode.date, order: .reverse)])
        var feed: [GroupedEpisodeList] = []
        
        do {
            let episodes = try context.fetch(descriptor)
            let grouped = Dictionary(grouping: episodes, by: { $0.directory })
            feed = grouped.compactMap { _, items in
                guard let first = items.first else { return nil }
                let remainingEpisodes = items.dropFirst()
                return GroupedEpisodeList(episode: first, children: remainingEpisodes.isEmpty ? nil : remainingEpisodes.map { GroupedEpisodeList(episode: $0, children: nil)})
            }.sorted { $0.episode.date > $1.episode.date }
        } catch {
            print("Failed to fetch episodes: \(error)")
        }
        return feed
    }
    
    /// Returns the number of podcast directories.
    func podcastCount() async -> Int {
        return await podcastDirectory()?.count ?? 0
    }
    
    /// Retrieves all podcast directories.
    func podcastDirectory() async -> [Directory]? {
        do {
            var descriptor = FetchDescriptor<Directory>()
            descriptor.includePendingChanges = false
            let directory = try context.fetch(descriptor)
            
            return directory
        }
        catch {
            return nil
        }
    }
    
    /// Saves context changes, if any.
    func save() -> Bool {
        do {
            if context.hasChanges {
                try context.save()
                return true
            }
        } catch {
            print("Failed to save context: \(error)")
        }
        return false
    }
    
    /// Saves context and posts a refresh notification.
    func saveAndRefresh() -> Bool {
        let r = save()
        
        if r {
            Task { @MainActor in
                NotificationCenter.default.post(name: Notification.Name.episodesChangedNotification, object:nil)
            }
        }
        return r
    }
    
    /// Finds a directory by its unique ID.
    func findDirectory(_ id:UInt64) -> Directory? {
        do {
            let descriptor = FetchDescriptor<Directory>(predicate: #Predicate<Directory> { $0.its_id == id })
            let directory = try context.fetch(descriptor)
            
            return directory.first
        }
        catch {
            return nil
        }
    }
    
    /// Finds a directory by its feed URL.
    func findDirectory(_ url:String) -> Directory? {
        do {
            let descriptor = FetchDescriptor<Directory>(predicate: #Predicate<Directory> { $0.feed == url })
            let directory = try context.fetch(descriptor)
            
            return directory.first
        }
        catch {
            return nil
        }
    }
    
    /// Adds a new podcast directory.
    func addDirectory(_ directory:Directory) -> Bool {
        context.insert(directory)
        return saveAndRefresh()
    }
    
    /// Adds a podcast and refreshes feeds.
    func addPodcast(_ directory:Directory) {
        _ = addDirectory(directory)
        Task {
            await refresh()
        }
    }
    
    /// Removes a podcast and associated data.
    func removePodcast(_ podcast:Directory) async {
        do {
            let pid = podcast.persistentModelID
            let descriptor = FetchDescriptor<Episode>(predicate: #Predicate<Episode> { $0.directory?.persistentModelID == pid })
            let items = try context.fetch(descriptor)
            
            for podcastEpisode in items {
                let fileManager = FileManager.default
                
                if let artwork = podcastEpisode.fullLocalUrl(.artwork) {
                    try? fileManager.removeItem(at:artwork)
                    print("Removing \(artwork.path())")
                }
                if let audio = podcastEpisode.fullLocalUrl(.audio) {
                    try? fileManager.removeItem(at:audio)
                    print("Removing \(audio.path())")
                }
                context.delete(podcastEpisode)
            }
            context.delete(podcast)
        }
        catch {
            print("Unable to fetch episodes for podcast \(podcast.feed)")
        }
        _ = saveAndRefresh()
    }
    
    /// Finds an episode by its audio URL.
    func findEpisode(_ url:String) async -> Episode? {
        do {
            let descriptor = FetchDescriptor<Episode>(predicate: #Predicate<Episode> { $0.audio == url })
            let episodes = try context.fetch(descriptor)
            
            return episodes.count > 0 ? episodes.first : nil
        }
        catch {
            return nil
        }
    }
     
    /// Checks if a podcast is subscribed by feed URL.
    func isSubscribed(_ url:String) -> Bool {
        do {
            let descriptor = FetchDescriptor<Directory>(predicate: #Predicate<Directory> { $0.feed == url })
            let dir = try context.fetch(descriptor)
            
            return dir.count > 0 ? true : false
        }
        catch {
            return false
        }
        
        //return (podcasts?.first(where: {$0.feedUrl == url})) != nil
    }
    
    /// Checks if a podcast is subscribed by ID.
    func isSubscribed(podcastId:UInt64) -> Bool {
        return findDirectory(podcastId) != nil ? true : false  //(podcasts?.first(where: {$0.id == podcastId})) != nil
    }
    
    /// Refreshes podcast feeds in the background.
    func backgroundRefresh() async {
        print("entered backgroundRefresh")
        if let podcasts = await podcastDirectory(), let downloads, podcasts.count > 0 {
            downloadCount = podcasts.count
            for p in podcasts {
                do {
                    let (_, _) = try await downloads.downloadFile(p.feed, localPath:p.fileName(), overwrite:true, progress: false)
                    
                    //let fileUrl = url ?? URL(string: p.fileName())
                    
                    let parser = PodcastParser()
                    let items = await parser.parseRSSFeed(p)
                    await self.merge(p, episodes:items)
                    
                    print("Processing \(p.feed)")
                }
                catch {
                    
                }
            }
        }
    }
    
    /// Refreshes podcast feeds.
    func refresh() async {
        print("refresh")
        if let podcasts = await podcastDirectory(), let downloads, podcasts.count > 0 {
            self.downloadCount = podcasts.count
            for p in podcasts {
                do {
                    let (_, _) = try await downloads.downloadFile(p.feed, localPath:p.fileName(), overwrite:true, progress:false)
                    let parser = PodcastParser()
                    
                    let items = await parser.parseRSSFeed(p)
                    await self.merge(p, episodes:Array(items.prefix(10)))
                    
                    print("Processing \(p.feed)")
                } catch {
                }
            }
        }
    }
    
    /// Merges new episodes into the data model.
    func merge(_ d:Directory, episodes:[Episode]) async {
        let newEpisodes:[Episode] = episodes.first != nil ? [episodes.first!] : []
        
        for podcast in episodes {
            if await findEpisode(podcast.audio) == nil {
                podcast.directory = d
                context.insert(podcast)
            }
        }
        if saveAndRefresh() && newEpisodes.count > 0 {
            await downloads?.checkForDownloads(newEpisodes)
        }
    }
}
    
