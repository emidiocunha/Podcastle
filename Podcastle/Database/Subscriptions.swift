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
    // Posted once a tapped notification's episode is loaded, so MainView expands the player.
    static let openPlayerNotification = Notification.Name("openPlayerNotification")
}

struct GroupedEpisodeList:Identifiable {
    let id = UUID()
    let episode:Episode
    let children:[GroupedEpisodeList]?
}

// Next step for background transcription. A finished transcript missing only its
// summary gets just the summary, not a full re-transcription.
enum BackgroundTranscriptionAction {
    case transcribe(Episode)
    case summarizeOnly(Episode)
}

/// An episode as plain values, safe to hand out of the actor (see siriEpisodes).
struct SiriEpisodeInfo: Sendable {
    let audio: String
    let title: String
    let showName: String
    let feed: String
    let date: Date
    let duration: Double
    let summary: String?
}

@ModelActor actor Subscriptions:NSObject, ObservableObject, Sendable {
    private var downloadCount = 0
    private var tempDuration = 0.0
    private var context: ModelContext { modelExecutor.modelContext }
    private var downloads:Downloads?
    // Summaries in progress, so two Transcriber instances don't summarize the same episode.
    private var summarizingFilenames: Set<String> = []

    /// Claims the right to summarize this episode; false if already claimed.
    /// Pair with endSummarizing.
    func beginSummarizing(_ filename: String) -> Bool {
        guard !summarizingFilenames.contains(filename) else { return false }
        summarizingFilenames.insert(filename)
        return true
    }

    func endSummarizing(_ filename: String) {
        summarizingFilenames.remove(filename)
    }

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
    
    /// Saves plain text to disk, e.g. an episode summary.
    @discardableResult nonisolated func saveTextToDisk(_ text: String, filePath: String) -> Bool {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return false
        }
        let fullPath = documents.appendingPathComponent(filePath, isDirectory: false)
        do {
            try text.write(to: fullPath, atomically: true, encoding: .utf8)
            return true
        } catch {
            print("Failed to save text to disk: \(error)")
            return false
        }
    }

    /// Loads plain text from disk.
    nonisolated func loadTextFromDisk(filePath: String) -> String? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let fullPath = documents.appendingPathComponent(filePath, isDirectory: false)
        return try? String(contentsOf: fullPath, encoding: .utf8)
    }

    /// Initializes the Subscriptions instance with dependencies.
    func setup(downloads:Downloads) {
        self.downloads = downloads
    }
    
    /// For "Continue Playing": the newest downloaded episode not yet played, using the
    /// same rule as the "Played" badge (under a minute left).
    func mostRecentUnplayedDownloadedEpisode(excluding episode: Episode?) -> Episode? {
        guard let episodes = try? context.fetch(FetchDescriptor<Episode>(sortBy: [SortDescriptor(\Episode.date, order: .reverse)])) else {
            return nil
        }
        let excludedID = episode?.persistentModelID
        return episodes.first { candidate in
            guard candidate.persistentModelID != excludedID else { return false }
            guard let audioURL = candidate.fullLocalUrl(.audio),
                  FileManager.default.fileExists(atPath: audioURL.path) else { return false }
            return candidate.secondsLeft() >= 60
        }
    }

    /// Marker written when a transcription run reaches the end of the audio. The
    /// transcript alone can't show this reliably (trailing music, ads, missing duration).
    nonisolated func transcriptCompleteMarker(for base: String) -> String {
        base + "-complete"
    }

    nonisolated func isTranscriptMarkedComplete(_ base: String) -> Bool {
        loadTextFromDisk(filePath: transcriptCompleteMarker(for: base)) != nil
    }

    nonisolated func setTranscriptComplete(_ base: String, _ complete: Bool) {
        if complete {
            saveTextToDisk("", filePath: transcriptCompleteMarker(for: base))
            Task { @MainActor in updateSiriIndex() }
        } else if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? FileManager.default.removeItem(at: documents.appendingPathComponent(transcriptCompleteMarker(for: base), isDirectory: false))
        }
    }

    /// How far an episode's transcript reaches, in seconds; -1 with no transcript.
    nonisolated func transcriptProgress(_ base: String) -> Double {
        let sentences: [Sentence]? = loadArrayFromDisk(filePath: base + ".json")
        return sentences?.last?.timestamp ?? -1
    }

    /// Counts background runs that ended without finishing or advancing an
    /// episode's transcript; after `maxStalledRuns` in a row it's skipped, so one
    /// episode that always fails can't block the rest of the queue.
    func recordBackgroundRun(_ base: String, progressBefore: Double) {
        var stalls = UserDefaults.standard.dictionary(forKey: stalledRunsKey) as? [String: Int] ?? [:]
        if isTranscriptMarkedComplete(base) || transcriptProgress(base) > progressBefore {
            stalls[base] = nil
        } else {
            stalls[base, default: 0] += 1
            if stalls[base] == maxStalledRuns {
                print("Background transcription: skipping \(base) after \(maxStalledRuns) runs without progress.")
            }
        }
        UserDefaults.standard.set(stalls, forKey: stalledRunsKey)
    }

    private nonisolated var stalledRunsKey: String { "backgroundTranscriptionStalledRuns" }
    private nonisolated var maxStalledRuns: Int { 3 }

    nonisolated func isTranscriptionStalled(_ base: String) -> Bool {
        let stalls = UserDefaults.standard.dictionary(forKey: stalledRunsKey) as? [String: Int] ?? [:]
        return stalls[base, default: 0] >= maxStalledRuns
    }

    /// Picks the next episode for background transcription, finishing a partial
    /// transcript before starting a new one. Only downloaded episodes count.
    func nextBackgroundTranscriptionAction() -> BackgroundTranscriptionAction? {
        guard let episodes = try? context.fetch(FetchDescriptor<Episode>(sortBy: [SortDescriptor(\Episode.date, order: .reverse)])) else {
            return nil
        }

        let downloaded = episodes.filter { episode in
            guard let audioURL = episode.fullLocalUrl(.audio) else { return false }
            return FileManager.default.fileExists(atPath: audioURL.path)
        }

        func baseName(for episode: Episode) -> String? {
            episode.fullLocalUrl(.audio)?.deletingPathExtension().lastPathComponent
        }
        func transcript(for episode: Episode) -> [Sentence]? {
            guard let base = baseName(for: episode) else { return nil }
            return loadArrayFromDisk(filePath: base + ".json")
        }
        func hasSummary(_ episode: Episode) -> Bool {
            guard let base = baseName(for: episode) else { return false }
            return loadTextFromDisk(filePath: base + "-summary.txt") != nil
        }

        // Transcripts from before the completion marker existed fall back to a timestamp check.
        func isComplete(_ episode: Episode, sentences: [Sentence]) -> Bool {
            guard let base = baseName(for: episode) else { return false }
            if isTranscriptMarkedComplete(base) { return true }
            guard let last = sentences.last,
                  let url = episode.fullLocalUrl(.audio) else { return false }
            let seconds = AudioDuration.estimate(url)
            guard seconds > 0 else { return false }
            return last.timestamp >= seconds - 120
        }

        // Same rule as the app's "Played" badge (see mostRecentUnplayedDownloadedEpisode).
        func isStalled(_ episode: Episode) -> Bool {
            guard let base = baseName(for: episode) else { return false }
            return isTranscriptionStalled(base)
        }
        func isPlayed(_ episode: Episode) -> Bool {
            episode.secondsLeft() < 60
        }

        // 1. Finish a partial transcript, unless the episode has since been played.
        if let inProgress = downloaded.first(where: { episode in
            guard !isPlayed(episode), !isStalled(episode) else { return false }
            guard let sentences = transcript(for: episode), !sentences.isEmpty else { return false }
            return !isComplete(episode, sentences: sentences)
        }) {
            return .transcribe(inProgress)
        }

        // 2. A finished transcript missing its summary (e.g. the model wasn't ready).
        if let needsSummary = downloaded.first(where: { episode in
            guard let sentences = transcript(for: episode), !sentences.isEmpty,
                  isComplete(episode, sentences: sentences) else { return false }
            return !hasSummary(episode)
        }) {
            return .summarizeOnly(needsSummary)
        }

        // 3. Start an episode the user hasn't begun listening to.
        if let notStarted = downloaded.first(where: { episode in
            episode.position == 0 && !isPlayed(episode) && !isStalled(episode) && transcript(for: episode) == nil
        }) {
            return .transcribe(notStarted)
        }

        return nil
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
    
    /// Returns directories that have no episodes yet (e.g. still being fetched).
    func loadEmptyDirectories() -> [Directory] {
        do {
            let allDirs = try context.fetch(FetchDescriptor<Directory>())
            let allEpisodes = try context.fetch(FetchDescriptor<Episode>())
            let populatedIDs = Set(allEpisodes.compactMap { $0.directory?.persistentModelID })
            return allDirs.filter { !populatedIDs.contains($0.persistentModelID) }
        } catch {
            return []
        }
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
                updateSiriIndex()
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
    
    /// Adds a podcast and triggers a background refresh of that podcast's feed.
    func addPodcast(_ directory: Directory) {
        _ = addDirectory(directory)
        // So Siri recognizes the new podcast's name in "Play <podcast> in Podcastle".
        PodcastleShortcuts.updateAppShortcutParameters()
        Task { await refreshSingle(directory) }
    }

    /// Downloads, parses and merges one podcast's feed, then starts its latest
    /// episode's download. Always notifies, so the pending row never spins forever.
    private func refreshSingle(_ d: Directory) async {
        guard let downloads else { return }
        do {
            let (_, success) = try await downloads.downloadFile(d.feed, localPath: d.fileName(), overwrite: true, progress: false)
            if success {
                let parser = PodcastParser()
                let items = await parser.parseRSSFeed(d)
                let inserted = await merge(d, episodes: Array(items.prefix(10)), deferRefresh: false)
                if inserted.isEmpty {
                    print("Feed for '\(d.name)' parsed with no usable episodes")
                    d.fetchFailed = true
                    _ = saveAndRefresh()
                }
            } else {
                print("Feed download returned false for '\(d.name)'")
                d.fetchFailed = true
                _ = saveAndRefresh()
            }
        } catch {
            print("Failed to refresh new podcast '\(d.name)': \(error)")
            d.fetchFailed = true
            _ = saveAndRefresh()
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
        PodcastleShortcuts.updateAppShortcutParameters()
    }

    /// Subscribed podcasts as plain values (feed URL is the ID), for Siri.
    func subscribedPodcasts() -> [(feed: String, name: String, artist: String)] {
        let directories = (try? context.fetch(FetchDescriptor<Directory>(sortBy: [SortDescriptor(\Directory.name)]))) ?? []
        return directories
            .filter { !$0.name.isEmpty }
            .map { (feed: $0.feed, name: $0.name, artist: $0.artist) }
    }

    /// The newest downloaded episode of a podcast; the player only plays local files.
    func latestDownloadedEpisode(feed: String) -> Episode? {
        guard let episodes = try? context.fetch(FetchDescriptor<Episode>(sortBy: [SortDescriptor(\Episode.date, order: .reverse)])) else {
            return nil
        }
        return episodes.first { episode in
            guard episode.directory?.feed == feed,
                  let audioURL = episode.fullLocalUrl(.audio) else { return false }
            return FileManager.default.fileExists(atPath: audioURL.path)
        }
    }
    
    /// Episode metadata for Siri's episode entities, matched by `audio` URLs or by
    /// `query` in the title or podcast name, newest first.
    func siriEpisodes(audio: [String]? = nil, query: String? = nil, limit: Int = 20) -> [SiriEpisodeInfo] {
        guard let episodes = try? context.fetch(FetchDescriptor<Episode>(sortBy: [SortDescriptor(\Episode.date, order: .reverse)])) else {
            return []
        }
        let matches = episodes.lazy.filter { episode in
            guard !episode.deleted, let directory = episode.directory else { return false }
            if let audio { return audio.contains(episode.audio) }
            if let query {
                return episode.title.localizedCaseInsensitiveContains(query)
                    || directory.name.localizedCaseInsensitiveContains(query)
            }
            return true
        }
        return matches.prefix(limit).map(siriEpisodeInfo)
    }

    private func siriEpisodeInfo(_ episode: Episode) -> SiriEpisodeInfo {
        SiriEpisodeInfo(audio: episode.audio,
                        title: episode.title,
                        showName: episode.directory?.name ?? "",
                        feed: episode.directory?.feed ?? "",
                        date: episode.date,
                        duration: episode.duration,
                        summary: siriTranscriptBase(episode).flatMap { loadTextFromDisk(filePath: $0 + "-summary.txt") })
    }

    private func siriTranscriptBase(_ episode: Episode) -> String? {
        episode.fullLocalUrl(.audio)?.deletingPathExtension().lastPathComponent
    }

    /// Episodes for Siri's search index, each with a signature that changes when its
    /// indexed content does.
    func siriIndexCandidates() -> [(info: SiriEpisodeInfo, signature: String)] {
        guard let episodes = try? context.fetch(FetchDescriptor<Episode>()) else { return [] }
        return episodes.compactMap { episode in
            guard !episode.deleted, episode.directory != nil, !episode.audio.isEmpty else { return nil }
            let info = siriEpisodeInfo(episode)
            let complete = siriTranscriptBase(episode).map(isTranscriptMarkedComplete) ?? false
            return (info, "\(info.title)|\(info.showName)|\(info.summary?.count ?? 0)|\(complete)")
        }
    }

    /// The text of a finished transcript, for Siri's search index.
    func siriTranscriptText(audio: String) -> String? {
        let descriptor = FetchDescriptor<Episode>(predicate: #Predicate<Episode> { $0.audio == audio })
        guard let episode = try? context.fetch(descriptor).first,
              let base = siriTranscriptBase(episode),
              isTranscriptMarkedComplete(base),
              let sentences: [Sentence] = loadArrayFromDisk(filePath: base + ".json"),
              !sentences.isEmpty else { return nil }
        return sentences.map(\.sentence).joined(separator: " ")
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
            // Only podcasts with no episodes at all can be marked as failed.
            let emptyBefore = Set(loadEmptyDirectories().map { $0.persistentModelID })
            var firstInsertedAcrossAll: [Episode] = []
            for p in podcasts {
                do {
                    let (_, _) = try await downloads.downloadFile(p.feed, localPath:p.fileName(), overwrite:true, progress: false)


                    let parser = PodcastParser()
                    let items = await parser.parseRSSFeed(p)
                    let inserted = await merge(p, episodes: items, deferRefresh: true)
                    if emptyBefore.contains(p.persistentModelID) {
                        // First fetch for this podcast: download only the latest episode.
                        if let latest = inserted.first {
                            firstInsertedAcrossAll.append(latest)
                        } else {
                            p.fetchFailed = true
                        }
                    } else {
                        firstInsertedAcrossAll.append(contentsOf: inserted)
                    }

                    print("Processing \(p.feed)")
                }
                catch {
                    if emptyBefore.contains(p.persistentModelID) {
                        p.fetchFailed = true
                    }
                }
            }
            _ = saveAndRefresh()
            if !firstInsertedAcrossAll.isEmpty {
                await downloads.checkForDownloads(firstInsertedAcrossAll)
            }
        }
    }

    /// Refreshes podcast feeds.
    func refresh() async {
        print("refresh")
        if let podcasts = await podcastDirectory(), let downloads, podcasts.count > 0 {
            self.downloadCount = podcasts.count
            // Only podcasts with no episodes at all can be marked as failed.
            let emptyBefore = Set(loadEmptyDirectories().map { $0.persistentModelID })
            var firstInsertedAcrossAll: [Episode] = []
            for p in podcasts {
                do {
                    let (_, _) = try await downloads.downloadFile(p.feed, localPath:p.fileName(), overwrite:true, progress:false)
                    let parser = PodcastParser()

                    let items = await parser.parseRSSFeed(p)
                    let inserted = await merge(p, episodes:Array(items.prefix(10)), deferRefresh: true)
                    if emptyBefore.contains(p.persistentModelID) {
                        // First fetch for this podcast: download only the latest episode.
                        if let latest = inserted.first {
                            firstInsertedAcrossAll.append(latest)
                        } else {
                            p.fetchFailed = true
                        }
                    } else {
                        firstInsertedAcrossAll.append(contentsOf: inserted)
                    }

                    print("Processing \(p.feed)")
                } catch {
                    if emptyBefore.contains(p.persistentModelID) {
                        p.fetchFailed = true
                    }
                }
            }
            // Save once and notify UI once to reduce render thrash
            _ = saveAndRefresh()
            if !firstInsertedAcrossAll.isEmpty {
                await downloads.checkForDownloads(firstInsertedAcrossAll)
            }
        }
    }
    
    /// Merges new episodes into the data model.
    func merge(_ d:Directory, episodes:[Episode], deferRefresh: Bool = false) async -> [Episode] {
        var inserted: [Episode] = []
        for podcast in episodes {
            if await findEpisode(podcast.audio) == nil {
                podcast.directory = d
                context.insert(podcast)
                inserted.append(podcast)
            }
        }
        // Save changes; if deferring, leave pending changes for caller to batch-save & notify once
        if deferRefresh {
            return inserted
        } else {
            if saveAndRefresh(), let first = inserted.first {
                await downloads?.checkForDownloads([first])
            }
            return inserted
        }
    }
}
