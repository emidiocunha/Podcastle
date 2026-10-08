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
    // Posted after a tapped "summary ready" notification has loaded its episode
    // into the player, so MainView can expand the player sheet to show it.
    static let openPlayerNotification = Notification.Name("openPlayerNotification")
}

struct GroupedEpisodeList:Identifiable {
    let id = UUID()
    let episode:Episode
    let children:[GroupedEpisodeList]?
}

// What the background transcription task should do next, as decided by
// Subscriptions.nextBackgroundTranscriptionAction(). Kept as two distinct cases
// rather than always calling Transcriber.transcribe() — an episode that's already
// fully transcribed and just missing a summary would otherwise get its whole
// transcription redone from scratch to backfill that summary, wasting the task's
// whole time budget on hours of audio that didn't need reprocessing.
enum BackgroundTranscriptionAction {
    case transcribe(Episode)
    case summarizeOnly(Episode)
}

@ModelActor actor Subscriptions:NSObject, ObservableObject, Sendable {
    private var downloadCount = 0
    private var tempDuration = 0.0
    private var context: ModelContext { modelExecutor.modelContext }
    private var downloads:Downloads?
    // Summaries in progress right now, keyed by filename — lets two independent
    // Transcriber instances (e.g. the interactive load() backfill and the
    // background task's own throwaway instance) notice they're about to
    // summarize the same episode at once. The "does a summary already exist on
    // disk" check Transcriber does itself isn't enough on its own: both can read
    // "no" before either has written anything.
    private var summarizingFilenames: Set<String> = []

    /// Atomically claims the right to generate this episode's summary — returns
    /// false if something else already claimed it, so the caller can skip
    /// running the (multi-second, on-device) LLM pass and sending a duplicate
    /// "Summary Ready" notification. Pair with endSummarizing when done.
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
    
    /// Saves plain text to disk (e.g. an episode summary) — kept as its own file
    /// rather than folded into the transcript's JSON, per the transcript/summary
    /// separation the caller wants.
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
    
    /// For the "Continue Playing" auto-advance: the most recent (by publish date)
    /// downloaded episode that hasn't finished playing yet, excluding whichever
    /// episode just ended. "Not played" mirrors the app's own "Played" badge
    /// (PodcastItemView) — within the last minute of the episode counts as done.
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

    /// Marker file written once a transcription run actually reaches the end of
    /// the audio. Completion can't be reliably inferred from the transcript alone:
    /// the last sentence's timestamp vs. the episode's length misreads episodes
    /// with long trailing music/silence, a missing feed duration, or dynamically
    /// inserted ads as unfinished — and background transcription would then pick
    /// the same episode again on every wake, forever.
    nonisolated func transcriptCompleteMarker(for base: String) -> String {
        base + "-complete"
    }

    nonisolated func isTranscriptMarkedComplete(_ base: String) -> Bool {
        loadTextFromDisk(filePath: transcriptCompleteMarker(for: base)) != nil
    }

    nonisolated func setTranscriptComplete(_ base: String, _ complete: Bool) {
        if complete {
            saveTextToDisk("", filePath: transcriptCompleteMarker(for: base))
        } else if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? FileManager.default.removeItem(at: documents.appendingPathComponent(transcriptCompleteMarker(for: base), isDirectory: false))
        }
    }

    /// Picks the next episode background transcription should work on. A partially
    /// transcribed episode (one with a checkpointed-but-incomplete .json transcript)
    /// takes priority over starting a fresh one, so a background wake finishes what
    /// an earlier wake started instead of scattering partial transcripts around.
    /// Only considers episodes whose audio is actually downloaded.
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

        // The completion marker is authoritative. Transcripts made before it
        // existed fall back to Transcriber.checkResumable's threshold, measured
        // against the downloaded file's real length rather than the feed's
        // (often missing or ad-skewed) duration. Even if that fallback misjudges
        // one, the resume run that follows reaches the end and writes the marker,
        // so an episode can't be re-selected more than once.
        func isComplete(_ episode: Episode, sentences: [Sentence]) -> Bool {
            guard let base = baseName(for: episode) else { return false }
            if isTranscriptMarkedComplete(base) { return true }
            guard let last = sentences.last,
                  let url = episode.fullLocalUrl(.audio),
                  let audioFile = try? AVAudioFile(forReading: url) else { return false }
            let seconds = Double(audioFile.length) / audioFile.processingFormat.sampleRate
            return last.timestamp >= seconds - 120
        }

        // 1. Finish a partially transcribed episode before starting anything else.
        if let inProgress = downloaded.first(where: { episode in
            guard let sentences = transcript(for: episode), !sentences.isEmpty else { return false }
            return !isComplete(episode, sentences: sentences)
        }) {
            return .transcribe(inProgress)
        }

        // 2. A finished transcript with no summary yet — e.g. the on-device model
        // was still downloading/preparing (SystemLanguageModel.modelNotReady) the
        // last time this ran. Retrying costs a few seconds of text generation, not
        // a full re-transcription, so it's worth doing before starting a fresh one.
        if let needsSummary = downloaded.first(where: { episode in
            guard let sentences = transcript(for: episode), !sentences.isEmpty,
                  isComplete(episode, sentences: sentences) else { return false }
            return !hasSummary(episode)
        }) {
            return .summarizeOnly(needsSummary)
        }

        // 3. Start a fresh episode.
        if let notStarted = downloaded.first(where: { transcript(for: $0) == nil }) {
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
        Task { await refreshSingle(directory) }
    }

    /// Downloads, parses and merges the feed for a single podcast directory.
    /// Notifies the UI and starts the latest-episode download as soon as done.
    /// Always marks the directory and notifies on failure/empty results so the
    /// pending placeholder never spins forever once the attempt is done.
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
            // Only directories with zero episodes matter for fetchFailed — a podcast
            // that already has episodes but got none new this cycle is not "failed".
            let emptyBefore = Set(loadEmptyDirectories().map { $0.persistentModelID })
            var firstInsertedAcrossAll: [Episode] = []
            for p in podcasts {
                do {
                    let (_, _) = try await downloads.downloadFile(p.feed, localPath:p.fileName(), overwrite:true, progress: false)

                    //let fileUrl = url ?? URL(string: p.fileName())

                    let parser = PodcastParser()
                    let items = await parser.parseRSSFeed(p)
                    let inserted = await merge(p, episodes: items, deferRefresh: true)
                    if emptyBefore.contains(p.persistentModelID) {
                        // First-time backfill for this podcast (e.g. addPodcast's refreshSingle
                        // hadn't finished yet when this refresh reached it) — only the latest
                        // episode should auto-download, not the whole fetched history.
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
            // Only directories with zero episodes matter for fetchFailed — a podcast
            // that already has episodes but got none new this cycle is not "failed".
            let emptyBefore = Set(loadEmptyDirectories().map { $0.persistentModelID })
            var firstInsertedAcrossAll: [Episode] = []
            for p in podcasts {
                do {
                    let (_, _) = try await downloads.downloadFile(p.feed, localPath:p.fileName(), overwrite:true, progress:false)
                    let parser = PodcastParser()

                    let items = await parser.parseRSSFeed(p)
                    let inserted = await merge(p, episodes:Array(items.prefix(10)), deferRefresh: true)
                    if emptyBefore.contains(p.persistentModelID) {
                        // First-time backfill for this podcast (e.g. addPodcast's refreshSingle
                        // hadn't finished yet when this refresh reached it) — only the latest
                        // episode should auto-download, not the whole fetched history.
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
