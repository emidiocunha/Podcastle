//
//  PodcastleIntents.swift
//  Podcastle
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

import AppIntents
import CoreSpotlight
import Foundation
import MediaIntents
import SwiftUI

// Siri / App Shortcuts. Phrases must include the app's name. Intents often run on a
// cold launch with no UI, so they use PodcastleServices.

// MARK: - Podcast entity

// A subscribed podcast, as Siri sees it. The feed URL is the ID.
struct PodcastEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Podcast"
    static let defaultQuery = PodcastQuery()

    let id: String
    let name: String
    let artist: String

    var displayRepresentation: DisplayRepresentation {
        if artist.isEmpty {
            return DisplayRepresentation(title: "\(name)")
        }
        return DisplayRepresentation(title: "\(name)", subtitle: "\(artist)")
    }
}

struct PodcastQuery: EntityStringQuery {
    // Only needs the data store, not the full app setup — Siri calls this just to
    // resolve a spoken name, and that shouldn't wait on migration or the player.
    @MainActor
    private func allPodcasts() async throws -> [PodcastEntity] {
        let subscriptions = try PodcastleServices.shared.sharedSubscriptions()
        return await subscriptions.subscribedPodcasts().map {
            PodcastEntity(id: $0.feed, name: $0.name, artist: $0.artist)
        }
    }

    func entities(for identifiers: [PodcastEntity.ID]) async throws -> [PodcastEntity] {
        try await allPodcasts().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [PodcastEntity] {
        try await allPodcasts().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [PodcastEntity] {
        try await allPodcasts()
    }
}

// MARK: - Errors

// Siri speaks these back, so they're phrased for the listener.
enum PodcastleIntentError: Error, CustomLocalizedStringResourceConvertible {
    case nothingToPlay
    case noDownloadedEpisodes(String)
    case episodeNotDownloaded(String)
    case notFollowing(String)
    case couldNotFollow(String)
    case couldNotPlay

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .nothingToPlay:
            return "There's nothing downloaded to play in Podcastle yet."
        case .noDownloadedEpisodes(let name):
            return "There are no downloaded episodes of \(name) yet."
        case .episodeNotDownloaded(let title):
            return "\(title) hasn't been downloaded yet."
        case .notFollowing(let name):
            return "You don't follow \(name) in Podcastle yet."
        case .couldNotFollow(let name):
            return "Podcastle couldn't follow \(name)."
        case .couldNotPlay:
            return "Podcastle couldn't play that episode."
        }
    }
}

// MARK: - Playback helpers

@MainActor
private func playEpisode(_ episode: Episode, with player: PodcastPlayer) throws {
    // Already loaded: just resume, rather than reloading it and losing a moment
    // of position.
    if player.currentPodcast?.audio != episode.audio {
        guard player.setPodcast(episode) else { throw PodcastleIntentError.couldNotPlay }
    }
    player.play()
}

@MainActor
private func skip(_ seconds: Double) {
    let player = PodcastleServices.shared.player
    guard player.currentPodcast != nil else { return }
    player.seek(seconds)
    player.updateNowPlayingElapsed(player.progress)
}

// MARK: - Intents

// "Play Podcastle": resumes, else the last episode played, else the newest unplayed one.
struct ResumePodcastIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Podcast"
    static let description = IntentDescription("Resumes the episode you were last listening to.")

    @MainActor
    func perform() async throws -> some IntentResult {
        let services = PodcastleServices.shared
        let subscriptions = try await services.start()
        let player = services.player

        if let current = player.currentPodcast {
            try playEpisode(current, with: player)
        } else if let audio = UserDefaults.standard.string(forKey: "currentPodcast"),
                  let last = await subscriptions.findEpisode(audio) {
            try playEpisode(last, with: player)
        } else if let next = await subscriptions.mostRecentUnplayedDownloadedEpisode(excluding: nil) {
            try playEpisode(next, with: player)
        } else {
            throw PodcastleIntentError.nothingToPlay
        }
        return .result()
    }
}

// "Play <podcast> in Podcastle": the newest downloaded episode of that podcast.
struct PlayPodcastIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Podcast"
    static let description = IntentDescription("Plays the newest downloaded episode of a podcast you subscribe to.")

    @Parameter(title: "Podcast")
    var podcast: PodcastEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$podcast)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let services = PodcastleServices.shared
        let subscriptions = try await services.start()
        guard let episode = await subscriptions.latestDownloadedEpisode(feed: podcast.id) else {
            throw PodcastleIntentError.noDownloadedEpisodes(podcast.name)
        }
        try playEpisode(episode, with: services.player)
        return .result()
    }
}

// "Play the latest episode in Podcastle": same pick as Continue Playing.
struct PlayLatestEpisodeIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Latest Episode"
    static let description = IntentDescription("Plays the newest downloaded episode you haven't finished.")

    @MainActor
    func perform() async throws -> some IntentResult {
        let services = PodcastleServices.shared
        let subscriptions = try await services.start()
        guard let episode = await subscriptions.mostRecentUnplayedDownloadedEpisode(excluding: nil) else {
            throw PodcastleIntentError.nothingToPlay
        }
        try playEpisode(episode, with: services.player)
        return .result()
    }
}

// Lets these start audio without bringing the app to the foreground.
@available(iOS 17.0, *)
extension ResumePodcastIntent: AudioPlaybackIntent {}
@available(iOS 17.0, *)
extension PlayPodcastIntent: AudioPlaybackIntent {}
@available(iOS 17.0, *)
extension PlayLatestEpisodeIntent: AudioPlaybackIntent {}

struct PausePodcastIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Podcast"
    static let description = IntentDescription("Pauses the episode that's playing.")

    @MainActor
    func perform() async throws -> some IntentResult {
        // Nothing to set up: if the app wasn't running, nothing is playing.
        PodcastleServices.shared.player.pause()
        return .result()
    }
}

struct SkipForwardIntent: AppIntent {
    static let title: LocalizedStringResource = "Skip Forward"
    static let description = IntentDescription("Skips ahead 30 seconds.")

    @MainActor
    func perform() async throws -> some IntentResult {
        skip(30)
        return .result()
    }
}

struct SkipBackwardIntent: AppIntent {
    static let title: LocalizedStringResource = "Skip Back"
    static let description = IntentDescription("Goes back 30 seconds.")

    @MainActor
    func perform() async throws -> some IntentResult {
        skip(-30)
        return .result()
    }
}

// MARK: - Siri phrases

// Parameterized phrases only match known podcasts, so Subscriptions calls
// updateAppShortcutParameters() when podcasts change.
struct PodcastleShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayPodcastIntent(), phrases: [
            "Play \(\.$podcast) in \(.applicationName)",
            "Play \(\.$podcast) on \(.applicationName)",
            "Listen to \(\.$podcast) in \(.applicationName)"
        ], shortTitle: "Play Podcast", systemImageName: "play.circle")
        AppShortcut(intent: ResumePodcastIntent(), phrases: [
            "Play \(.applicationName)",
            "Resume \(.applicationName)",
            "Continue listening in \(.applicationName)"
        ], shortTitle: "Resume", systemImageName: "playpause")
        AppShortcut(intent: PlayLatestEpisodeIntent(), phrases: [
            "Play the latest episode in \(.applicationName)",
            "Play the newest episode in \(.applicationName)"
        ], shortTitle: "Latest Episode", systemImageName: "sparkles")
        AppShortcut(intent: PausePodcastIntent(), phrases: [
            "Pause \(.applicationName)",
            "Stop \(.applicationName)"
        ], shortTitle: "Pause", systemImageName: "pause")
        AppShortcut(intent: SkipForwardIntent(), phrases: [
            "Skip forward in \(.applicationName)",
            "Skip ahead in \(.applicationName)"
        ], shortTitle: "Skip Forward", systemImageName: "goforward.30")
        AppShortcut(intent: SkipBackwardIntent(), phrases: [
            "Skip back in \(.applicationName)",
            "Go back in \(.applicationName)"
        ], shortTitle: "Skip Back", systemImageName: "gobackward.30")
    }
}

// MARK: - iOS 27 audio schemas

// iOS 27 .audio app schemas: Siri understands free-form requests ("play the latest
// Hard Fork") without a fixed phrase. The App Shortcuts above cover iOS 16–26.

@available(iOS 27.0, *)
@AppEntity(schema: .audio.podcastShow)
struct PodcastShowEntity {
    static let defaultQuery = PodcastShowEntityQuery()

    // Feed URL, same as PodcastEntity.
    let id: String

    var title: String
    var showDescription: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }

    // Subscribed podcasts first, then ones the app has seen but you don't follow
    // (DiscoveredPodcasts) — so "follow this podcast" works on a search result.
    struct PodcastShowEntityQuery: EntityStringQuery, IntentValueQuery {
        @MainActor
        private func shows(where include: ((feed: String, name: String, artist: String)) -> Bool) async throws -> [PodcastShowEntity] {
            let subscriptions = try PodcastleServices.shared.sharedSubscriptions()
            let subscribed = await subscriptions.subscribedPodcasts()
            let feeds = Set(subscribed.map(\.feed))
            let discovered = DiscoveredPodcasts.all
                .filter { !feeds.contains($0.feed) }
                .map { (feed: $0.feed, name: $0.name, artist: $0.artist) }
            return (subscribed + discovered).filter(include).map(PodcastShowEntity.init)
        }

        func entities(for identifiers: [PodcastShowEntity.ID]) async throws -> [PodcastShowEntity] {
            try await shows { identifiers.contains($0.feed) }
        }

        func entities(matching string: String) async throws -> [PodcastShowEntity] {
            try await shows { $0.name.localizedCaseInsensitiveContains(string) }
        }

        func values(for input: AudioSearch) async throws -> [PodcastShowEntity] {
            switch input.criteria {
            case .searchQuery(let query):
                let known = try await entities(matching: query)
                return known.isEmpty ? try await searchDirectory(query) : known
            case .url(let urls):
                return try await entities(for: urls.map(\.absoluteString))
            default:
                return []
            }
        }

        // Nothing local matches — e.g. "Follow Hard Fork" for a podcast you don't
        // have yet — so ask the same Apple Podcasts directory the Add screen uses.
        @MainActor
        private func searchDirectory(_ query: String) async throws -> [PodcastShowEntity] {
            let services = PodcastleServices.shared
            try await services.start()
            let found = await PodcastDirectorySearch().fetchPodcasts(searchTerm: query, downloads: services.downloads) ?? []
            return found.prefix(5).map { directory in
                DiscoveredPodcasts.register(directory, needsLookup: false)
                return PodcastShowEntity((feed: directory.feed, name: directory.name, artist: directory.artist))
            }
        }
    }
}

@available(iOS 27.0, *)
extension PodcastShowEntity {
    init(id: String, title: String, showDescription: String?) {
        self.id = id
        self.title = title
        self.showDescription = showDescription
    }

    init(_ podcast: (feed: String, name: String, artist: String)) {
        self.init(id: podcast.feed, title: podcast.name, showDescription: podcast.artist.isEmpty ? nil : podcast.artist)
    }
}

// Indexed into Spotlight (see updateSiriIndex) with its summary and transcript,
// so Siri can find "the episode where they talked about the borrow checker".
@available(iOS 27.0, *)
@AppEntity(schema: .audio.podcastEpisode)
struct PodcastEpisodeEntity: IndexedEntity {
    static let defaultQuery = PodcastEpisodeEntityQuery()

    // Audio URL — what Subscriptions.findEpisode and the player key on.
    let id: String

    var title: String
    var showName: String?
    var show: PodcastShowEntity?
    var releaseDate: Date?
    var duration: Double?

    // The on-device summary, when there is one — also lets Siri answer "what's
    // this episode about?" for the episode on screen.
    @Property(title: "Summary", indexingKey: \.contentDescription)
    var summary: String?

    // Only filled in when indexing; too big to carry around in every query result.
    @Property(title: "Transcript", indexingKey: \.textContent)
    var transcript: String?

    var displayRepresentation: DisplayRepresentation {
        if let showName, !showName.isEmpty {
            return DisplayRepresentation(title: "\(title)", subtitle: "\(showName)")
        }
        return DisplayRepresentation(title: "\(title)")
    }

    struct PodcastEpisodeEntityQuery: EntityStringQuery, IntentValueQuery {
        @MainActor
        private func subscriptions() throws -> Subscriptions {
            try PodcastleServices.shared.sharedSubscriptions()
        }

        func entities(for identifiers: [PodcastEpisodeEntity.ID]) async throws -> [PodcastEpisodeEntity] {
            try await subscriptions().siriEpisodes(audio: identifiers, limit: identifiers.count)
                .map(PodcastEpisodeEntity.init)
        }

        func entities(matching string: String) async throws -> [PodcastEpisodeEntity] {
            try await subscriptions().siriEpisodes(query: string).map(PodcastEpisodeEntity.init)
        }

        func values(for input: AudioSearch) async throws -> [PodcastEpisodeEntity] {
            switch input.criteria {
            case .searchQuery(let query):
                return try await entities(matching: query)
            case .url(let urls):
                return try await entities(for: urls.map(\.absoluteString))
            case .unspecified:
                // "Play a podcast": same pick as Continue Playing.
                let subscriptions = try await subscriptions()
                guard let next = await subscriptions.mostRecentUnplayedDownloadedEpisode(excluding: nil) else {
                    return []
                }
                return try await entities(for: [next.audio])
            @unknown default:
                return []
            }
        }
    }
}

@available(iOS 27.0, *)
extension PodcastEpisodeEntity {
    init(_ info: SiriEpisodeInfo) {
        self.id = info.audio
        self.title = info.title
        self.showName = info.showName
        self.show = PodcastShowEntity(id: info.feed, title: info.showName, showDescription: nil)
        self.releaseDate = info.date
        self.duration = info.duration > 0 ? info.duration : nil
        self.summary = info.summary
        self.transcript = nil
    }
}

// What Siri can ask Podcastle to play: a whole show (its newest downloaded
// episode) or one episode.
@available(iOS 27.0, *)
@UnionValue
enum PodcastAudioItem {
    case show(PodcastShowEntity)
    case episode(PodcastEpisodeEntity)
}

// Podcastle has no shuffle/repeat or play queue, but the schemas need these types
// to exist; the intents accept them and ignore them.
@available(iOS 27.0, *)
@AppEnum(schema: .audio.playbackAttributes)
enum PodcastPlaybackAttributes: String {
    case shuffle
    case `repeat`

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .shuffle: "Shuffle",
        .repeat: "Repeat"
    ]
}

@available(iOS 27.0, *)
@AppEnum(schema: .audio.queueInsertionLocation)
enum PodcastQueueInsertionLocation: String {
    case next
    case tail

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .next: "Play Next",
        .tail: "Play Last"
    ]
}

// Handed back by WarmupAudioQueueIntent and passed into PlayAudioIntent, so the
// play step knows which episode is already loaded.
@available(iOS 27.0, *)
@AppEntity(schema: .audio.warmupAudioQueueResult)
struct PodcastWarmupResult: TransientAppEntity {
    @Property(title: "Episode")
    var audio: String

    init() {
        audio = ""
    }

    init(audio: String) {
        self.audio = audio
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "Ready to play")
    }
}

// Resolves what Siri picked to a downloaded episode. The player only plays local
// files, so an episode that isn't downloaded yet can't be played.
@available(iOS 27.0, *)
@MainActor
private func downloadedEpisode(for item: PodcastAudioItem, in subscriptions: Subscriptions) async throws -> Episode {
    switch item {
    case .show(let show):
        guard await subscriptions.isSubscribed(show.id) else {
            throw PodcastleIntentError.notFollowing(show.title)
        }
        guard let episode = await subscriptions.latestDownloadedEpisode(feed: show.id) else {
            throw PodcastleIntentError.noDownloadedEpisodes(show.title)
        }
        return episode
    case .episode(let entity):
        guard let episode = await subscriptions.findEpisode(entity.id),
              episode.fileSize(.audio).count > 0 else {
            throw PodcastleIntentError.episodeNotDownloaded(entity.title)
        }
        return episode
    }
}

// Called while Siri is still talking: loads the episode without playing it, unless
// something is already playing.
@available(iOS 27.0, *)
@AppIntent(schema: .audio.warmupAudioQueue)
struct WarmupAudioQueueIntent: AudioPlaybackIntent {
    var audioEntity: PodcastAudioItem
    var playbackAttributes: Set<PodcastPlaybackAttributes>

    @MainActor
    func perform() async throws -> some ReturnsValue<PodcastWarmupResult> {
        let services = PodcastleServices.shared
        let subscriptions = try await services.start()
        let player = services.player
        let episode = try await downloadedEpisode(for: audioEntity, in: subscriptions)

        if !player.isPlaying, player.currentPodcast?.audio != episode.audio {
            guard player.setPodcast(episode) else { throw PodcastleIntentError.couldNotPlay }
        }
        return .result(value: PodcastWarmupResult(audio: episode.audio))
    }
}

@available(iOS 27.0, *)
@AppIntent(schema: .audio.playAudio)
struct PlayAudioIntent: AudioPlaybackIntent {
    var audioEntity: PodcastAudioItem
    var playbackAttributes: Set<PodcastPlaybackAttributes>
    var warmupAudioQueueResult: PodcastWarmupResult?
    var queueLocation: PodcastQueueInsertionLocation?

    @MainActor
    func perform() async throws -> some IntentResult {
        let services = PodcastleServices.shared
        let subscriptions = try await services.start()
        let player = services.player

        // Warmed up and still loaded: skip the lookup.
        if let warmed = warmupAudioQueueResult?.audio, player.currentPodcast?.audio == warmed {
            player.play()
            return .result()
        }
        let episode = try await downloadedEpisode(for: audioEntity, in: subscriptions)
        try playEpisode(episode, with: player)
        return .result()
    }
}

// "Follow this podcast" / "Follow Hard Fork". Same as tapping Add in search. An
// episode is always from a podcast you already follow, so there's nothing to do.
@available(iOS 27.0, *)
@AppIntent(schema: .audio.addToLibrary)
struct AddToLibraryIntent {
    var audioEntity: PodcastAudioItem

    @MainActor
    func perform() async throws -> some IntentResult {
        guard case .show(let show) = audioEntity else { return .result() }
        let services = PodcastleServices.shared
        let subscriptions = try await services.start()
        guard await !subscriptions.isSubscribed(show.id) else { return .result() }

        guard let discovered = DiscoveredPodcasts.find(feed: show.id) else {
            throw PodcastleIntentError.couldNotFollow(show.title)
        }
        var directory = discovered.makeDirectory()
        // Top-chart entries only carry an Apple Podcasts page URL; look up the
        // real feed first, as SearchViewItem does.
        if discovered.needsLookup {
            guard let looked = await PodcastDirectorySearch().fetchTop(directory, downloads: services.downloads) else {
                throw PodcastleIntentError.couldNotFollow(show.title)
            }
            directory = looked
        }
        await subscriptions.addPodcast(directory)
        return .result()
    }
}

// MARK: - Podcasts seen but not followed

// Search results and directory lookups, remembered for this run so a show entity
// can still be resolved and followed after its screen is gone.
@MainActor
enum DiscoveredPodcasts {
    struct Entry {
        let itsID: UInt64
        let name: String
        let artist: String
        let feed: String
        let artwork: String
        let needsLookup: Bool

        func makeDirectory() -> Directory {
            Directory(its_id: itsID, name: name, artist: artist, feed: feed, artwork: artwork)
        }
    }

    private static var entries: [String: Entry] = [:]

    static var all: [Entry] { Array(entries.values) }

    static func find(feed: String) -> Entry? { entries[feed] }

    static func register(_ directory: Directory, needsLookup: Bool) {
        guard !directory.feed.isEmpty else { return }
        entries[directory.feed] = Entry(itsID: directory.its_id, name: directory.name, artist: directory.artist,
                                        feed: directory.feed, artwork: directory.artwork, needsLookup: needsLookup)
    }
}

// MARK: - Spotlight index for Siri

// Keeps Spotlight's copy of each episode (title, show, summary, transcript) current
// for Siri. Runs are coalesced and only changed episodes are re-sent.
@MainActor
func updateSiriIndex() {
    guard #available(iOS 27.0, *) else { return }
    SiriEpisodeIndexer.shared.update()
}

@available(iOS 27.0, *)
@MainActor
private final class SiriEpisodeIndexer {
    static let shared = SiriEpisodeIndexer()

    private static let signaturesKey = "siriIndexSignatures"
    // Spotlight caps how much text it keeps per item anyway; this keeps a
    // multi-hour transcript from being sent whole.
    private static let maxTranscriptLength = 200_000

    private var running: Task<Void, Never>?
    private var rerun = false

    func update() {
        guard running == nil else {
            rerun = true
            return
        }
        running = Task {
            // Saves come in bursts (a feed refresh saves per episode); let them settle.
            try? await Task.sleep(for: .seconds(3))
            await run()
            running = nil
            if rerun {
                rerun = false
                update()
            }
        }
    }

    private func run() async {
        guard let subscriptions = try? PodcastleServices.shared.sharedSubscriptions() else { return }
        let candidates = await subscriptions.siriIndexCandidates()
        var signatures = UserDefaults.standard.dictionary(forKey: Self.signaturesKey) as? [String: String] ?? [:]
        let index = CSSearchableIndex.default()

        let current = Set(candidates.map(\.info.audio))
        let removed = signatures.keys.filter { !current.contains($0) }
        if !removed.isEmpty {
            do {
                try await index.deleteAppEntities(identifiedBy: removed, ofType: PodcastEpisodeEntity.self)
                removed.forEach { signatures[$0] = nil }
            } catch {
                print("Siri index: couldn't remove episodes: \(error)")
            }
        }

        let changed = candidates.filter { signatures[$0.info.audio] != $0.signature }
        // Small batches, so one huge run doesn't hold every transcript in memory.
        for start in stride(from: 0, to: changed.count, by: 20) {
            let batch = changed[start..<min(start + 20, changed.count)]
            var entities: [PodcastEpisodeEntity] = []
            for candidate in batch {
                let entity = PodcastEpisodeEntity(candidate.info)
                entity.transcript = await subscriptions.siriTranscriptText(audio: candidate.info.audio)
                    .map { String($0.prefix(Self.maxTranscriptLength)) }
                entities.append(entity)
            }
            do {
                try await index.indexAppEntities(entities)
                batch.forEach { signatures[$0.info.audio] = $0.signature }
            } catch {
                print("Siri index: couldn't index episodes: \(error)")
            }
        }
        UserDefaults.standard.set(signatures, forKey: Self.signaturesKey)
    }
}

// MARK: - On-screen awareness

// Tags a view with the episode or podcast it shows, so Siri can resolve "this
// episode" / "follow this podcast" against what's on screen. No-ops before iOS 27.
extension View {
    @ViewBuilder
    func siriEpisode(_ audio: String) -> some View {
        if #available(iOS 27.0, *) {
            appEntityIdentifier(EntityIdentifier(for: PodcastEpisodeEntity.self, identifier: audio))
        } else {
            self
        }
    }

    @ViewBuilder
    func siriPodcast(_ feed: String) -> some View {
        if #available(iOS 27.0, *) {
            appEntityIdentifier(EntityIdentifier(for: PodcastShowEntity.self, identifier: feed))
        } else {
            self
        }
    }

    // For the player: the episode it's showing is "this episode" even when no
    // list row is visible.
    func siriNowPlaying(_ episode: Episode?) -> some View {
        userActivity(siriNowPlayingActivityType, isActive: episode != nil) { activity in
            guard let episode else { return }
            activity.title = episode.title
            if #available(iOS 27.0, *) {
                activity.appEntityIdentifier = EntityIdentifier(for: PodcastEpisodeEntity.self, identifier: episode.audio)
            }
        }
    }
}

// Also listed under NSUserActivityTypes in Info.plist.
let siriNowPlayingActivityType = "com.mobytestudio.VoiceFeed.episode"
