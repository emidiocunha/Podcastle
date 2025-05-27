//
//  Migrate.swift
//  Podcastle
//
//  Created by Emídio Cunha on 26/02/2025.
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

// Previous versions of Podcastle had the model live in JSON Dictionaries
// So this code attempts a migration to Swift Data

import SwiftData
import Foundation

@ModelActor actor Migration {
    private var subscriptions:Subscriptions?
    private var context: ModelContext { modelExecutor.modelContext }
    
    func setup(subscriptions:Subscriptions) {
        self.subscriptions = subscriptions
    }
    
    func needsMigration() async -> Bool {
        if let JSONDirectory:[PodcastDirectoryEntry] = subscriptions?.loadArrayFromDisk(filePath: "podcasts.json"),
            let DBDirectory = await subscriptions?.podcastDirectory() {
            if DBDirectory.count == 0 && JSONDirectory.count > 0 {
                return true
            }
        }
        return false
    }
    
    func migrateJSON() async {
        do {
            let JSONDirectory:[PodcastDirectoryEntry] = subscriptions?.loadArrayFromDisk(filePath: "podcasts.json") ?? []
            
            try context.delete(model: Directory.self)
            try context.delete(model: Episode.self)
            try context.save()
            
            for dir in JSONDirectory {
                let newDir = Directory(its_id: dir.id, name: dir.name, artist: dir.artistName, feed: dir.feedUrl, artwork: dir.artworkUrl)
                
                context.insert(newDir)
                print("\(newDir.artist) podcast directory entry added to database")
                try context.save()
            }
        } catch {
            fatalError("Failed to migrate model.")
        }
    }
    
    func addEpisodesForDir(_ directory:Directory) async {
        let parser = PodcastParser()
        let items = await parser.parseRSSFeed(directory)
        let top = Array(items.prefix(10))
        for episode in top {
            if await subscriptions?.findEpisode(episode.audio) == nil {
                await addEpisode(directory, episode:episode)
            }
        }
    }
    
    func addEpisode(_ directory:Directory, episode: Episode) async {
        let newEpisode = Episode()
        
        newEpisode.title = episode.title
        newEpisode.desc = episode.desc
        newEpisode.summary = episode.summary
        newEpisode.author = episode.author
        newEpisode.link = episode.link
        newEpisode.artwork = episode.artwork
        newEpisode.audio = episode.audio
        newEpisode.date = episode.date
        newEpisode.duration = episode.duration
        newEpisode.position = episode.position
        newEpisode.deleted = episode.deleted
        newEpisode.directory = directory
        context.insert(newEpisode)
        
        print("\(newEpisode.title) \(newEpisode.directory?.name ?? "") podcast episode added to database")
    }
    
}
