//
//  PodcastleApp.swift
//  Podcastle
//
//  Created by Emídio Cunha on 15/05/2025.
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

import SwiftUI
import Speech
import BackgroundTasks
import SwiftData
import UserNotifications
// Change as needed for your bundle IDs
public let kAppRefreshIdentifier = "com.mobyte.voicefeed.Refresh"
public let kBackgroundIdentifier = "com.mobyte.voicefeed.backgroundDownload"
public let kTranscriptionBackgroundIdentifier = "com.mobyte.voicefeed.transcribe"
// "Background Transcription" toggle in the More menu. Its default is registered in
// AppDelegate, which reads it before any SwiftUI view runs.
public let kBackgroundTranscriptionEnabledKey = "backgroundTranscriptionEnabled"
// Whether the one-time background transcription prompt has been shown.
public let kBackgroundTranscriptionOnboardingShownKey = "backgroundTranscriptionOnboardingShown"
// "Continue Playing" in the More menu: auto-advance to the next unplayed episode.
public let kContinuePlayingEnabledKey = "continuePlayingEnabled"
@MainActor public var kScreenScale = 2.0

@main
struct PodcastleApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var accentColor: Color = .blue
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var subscriptions: Subscriptions?
    // Shared with Siri intents and background tasks, which run without any UI.
    @StateObject var downloadStatus = PodcastleServices.shared.downloadStatus
    @StateObject var transcriber = PodcastleServices.shared.transcriber
    @StateObject var player = PodcastleServices.shared.player
    @StateObject var file = PodcastleServices.shared.file
    @StateObject var imageCache = ImageCache()
    private var downloads: Downloads { PodcastleServices.shared.downloads }
     
    var body: some Scene {
        WindowGroup {
            if let subscriptions {
                MainView()
                    .modelContainer(subscriptions.modelContainer)
                    .environmentObject(subscriptions)
                    .environmentObject(downloads)
                    .environmentObject(downloadStatus)
                    .environmentObject(transcriber)
                    .environmentObject(player)
                    .environmentObject(file)
                    .environmentObject(imageCache)
/*#if targetEnvironment
                    .frame(minWidth: 480, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity )
                    .windowStyle(.titleBar)
                    .windowResizability(.contentSize)
#endif*/

            }
            else {
                ProgressView()
                    .task {
                        do {
                            // A Siri intent or background task may already have done this setup.
                            self.subscriptions = try PodcastleServices.shared.sharedSubscriptions()
                            try await PodcastleServices.shared.start()
                        } catch {
                            print("Could not initialize: \(error)")
                        }
                    }
            }
        }
        .onChange(of: scenePhase) { oldScenePhase, newScenePhase in
            if newScenePhase == .active {
                kScreenScale = UIScreen.main.scale
                SFSpeechRecognizer.requestAuthorization { (status) in
                    switch status {
                        case .notDetermined: print("Speech: Not determined")
                        case .restricted: print("Speech: Restricted")
                        case .denied: print("Speech: Denied")
                        case .authorized: print("Speech: We can recognize speech now.")
                        @unknown default: print("Speech: Unknown case")
                    }
                }
                Task {
                    await subscriptions?.refresh()
                }
            } else if newScenePhase == .background {
                appDelegate.scheduleAppRefresh()
                AppDelegate.scheduleTranscriptionRefresh()
            }
        }
    }
}

// The app's long-lived objects, owned here rather than by PodcastleApp so Siri
// intents and background tasks on a cold launch use the same instances as the UI.
@MainActor
final class PodcastleServices {
    static let shared = PodcastleServices()
    private init() {}

    let downloadStatus = DownloadStatus()
    let downloads = Downloads()
    let transcriber = Transcriber()
    let player = PodcastPlayer()
    let file = PodcastFile()
    weak var appDelegate: AppDelegate?

    private var subscriptions: Subscriptions?
    private var startTask: Task<Subscriptions, Error>?

    // The single Subscriptions instance, so there's never a second ModelContainer.
    func sharedSubscriptions() throws -> Subscriptions {
        if let subscriptions { return subscriptions }
        let sub = try Subscriptions(modelContainer: ModelContainer(for: Directory.self, Episode.self, configurations: ModelConfiguration(isStoredInMemoryOnly: false)))
        subscriptions = sub
        return sub
    }

    // Full app setup. Runs once; every caller waits for that same run.
    @discardableResult
    func start() async throws -> Subscriptions {
        if let startTask { return try await startTask.value }
        let task = Task { () throws -> Subscriptions in
            let subscriptions = try sharedSubscriptions()
            await subscriptions.setup(downloads: downloads)
            appDelegate?.registerSubscriptions(subscriptions)
            await migrateIfNeeded(subscriptions)
            await downloads.setup(status: downloadStatus)
            player.setup(subscriptions: subscriptions, transcriber: transcriber, file: file, downloads: downloads)
            appDelegate?.registerDownloads(downloads)
            appDelegate?.registerPlayer(player)
            CarPlayController.shared.player = player
            CarPlayController.shared.file = file
            CarPlayController.shared.subscriptions = subscriptions
            PodcastleShortcuts.updateAppShortcutParameters()
            updateSiriIndex()
            return subscriptions
        }
        startTask = task
        do {
            return try await task.value
        } catch {
            // Let a later caller try again rather than replaying this failure.
            startTask = nil
            throw error
        }
    }

    private func migrateIfNeeded(_ subscriptions: Subscriptions) async {
        let migration = Migration(modelContainer: subscriptions.modelContainer)
        await migration.setup(subscriptions: subscriptions)
        if await migration.needsMigration() {
            await migration.migrateJSON()
        }
    }
}

// Makes setTaskCompleted run once, whether the work or the expirationHandler gets there first.
private final class TaskCompletion {
    private let lock = NSLock()
    private var finished = false
    private let task: BGProcessingTask

    init(_ task: BGProcessingTask) {
        self.task = task
    }

    var isFinished: Bool {
        lock.withLock { finished }
    }

    func complete(_ success: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        task.setTaskCompleted(success: success)
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    // Opens the episode from a tapped "summary ready" notification.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                 didReceive response: UNNotificationResponse,
                                 withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        guard let audioURL = response.notification.request.content.userInfo["episodeAudioURL"] as? String,
              !audioURL.isEmpty else {
            return
        }
        guard subscriptions != nil, player != nil else {
            // Cold launch: opened once registerSubscriptions/registerPlayer have run.
            pendingNotificationEpisodeAudioURL = audioURL
            return
        }
        Task { await openEpisode(audioURL: audioURL) }
    }
}

class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var subscriptions:Subscriptions?
    private var downloads:Downloads?
    private var player:PodcastPlayer?
    // Background URLSession events and tapped notifications that arrive before setup
    // finishes are held here until it does.
    private var pendingBackgroundSessionCompletion: (identifier: String, handler: () -> Void)?
    private var pendingNotificationEpisodeAudioURL: String?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    )  -> Bool {
        // Off by default: it costs battery, so the onboarding prompt asks first.
        UserDefaults.standard.register(defaults: [
            kBackgroundTranscriptionEnabledKey: false,
            kContinuePlayingEnabledKey: true
        ])
        PodcastleServices.shared.appDelegate = self
        _ = CarPlaySceneDelegate.self  // prevent linker dead-stripping
        let cls = NSClassFromString("CarPlaySceneDelegate")
        print("🚗 launch: CarPlaySceneDelegate class = \(String(describing: cls))")
        registerBackgroundTasks()
        scheduleAppRefresh()
        Self.scheduleTranscriptionRefresh()
        UNUserNotificationCenter.current().delegate = self
        requestNotificationAuthorization()
        return true
    }

    // See PodcastleServices.sharedSubscriptions.
    func sharedSubscriptions() throws -> Subscriptions {
        try PodcastleServices.shared.sharedSubscriptions()
    }

    func registerSubscriptions(_ sub:Subscriptions) {
        subscriptions = sub
        flushPendingNotification()
    }

    func registerPlayer(_ p: PodcastPlayer) {
        player = p
        flushPendingNotification()
    }

    private func flushPendingNotification() {
        guard let audioURL = pendingNotificationEpisodeAudioURL, subscriptions != nil, player != nil else { return }
        pendingNotificationEpisodeAudioURL = nil
        Task { await openEpisode(audioURL: audioURL) }
    }

    func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
            if let error {
                print("Notification authorization error: \(error.localizedDescription)")
            }
        }
    }

    func registerDownloads(_ d:Downloads) {
        downloads = d
        if let pending = pendingBackgroundSessionCompletion {
            pendingBackgroundSessionCompletion = nil
            Task {
                await d.setBackgroundCompletionHandler(pending.handler)
            }
        }
    }

    // Called when a background URLSession has events, possibly before setup has called
    // registerDownloads(). Buffered rather than dropped: the completion handler must be
    // called after urlSessionDidFinishEvents, or iOS penalizes the app.
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == kBackgroundDownloadIdentifier else {
            completionHandler()
            return
        }
        guard let downloads else {
            pendingBackgroundSessionCompletion = (identifier, completionHandler)
            return
        }
        Task {
            await downloads.setBackgroundCompletionHandler(completionHandler)
        }
    }

    func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier:kBackgroundIdentifier, using: nil) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let completion = TaskCompletion(processingTask)
            let work = Task {
                // Background launches show no window, so setup happens here.
                guard let subscriptions = try? await PodcastleServices.shared.start() else {
                    completion.complete(false)
                    return
                }
                await subscriptions.backgroundRefresh()
                completion.complete(true)
            }
            task.expirationHandler = {
                work.cancel()
                completion.complete(false)
            }
            self.scheduleAppRefresh()
        }

        BGTaskScheduler.shared.register(forTaskWithIdentifier: kTranscriptionBackgroundIdentifier, using: nil) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handleTranscriptionTask(processingTask)
        }
    }

    // Transcribes one episode per wake, using its own Transcriber so it never touches
    // what's on screen. The UI picks up the saved transcript next time it's opened.
    func handleTranscriptionTask(_ task: BGProcessingTask) {
        let completion = TaskCompletion(task)
        // Disabled: no reschedule, so the wakes stop until it's turned back on.
        guard UserDefaults.standard.bool(forKey: kBackgroundTranscriptionEnabledKey) else {
            completion.complete(true)
            return
        }
        // Skip while in Low Power Mode, but keep the next wake queued.
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else {
            print("Skipping background transcription: Low Power Mode is on.")
            Self.scheduleTranscriptionRefresh()
            completion.complete(true)
            return
        }
        let transcriber = Transcriber()

        task.expirationHandler = {
            // Transcriber checkpoints as it goes, so the next wake resumes from here.
            transcriber.cancel()
            completion.complete(false)
        }

        // Schedule the next wake now, not at the end: an expired run can be killed before
        // it gets that far.
        Self.scheduleTranscriptionRefresh()

        Task {
            guard let subscriptions = try? self.sharedSubscriptions() else {
                completion.complete(false)
                return
            }
            transcriber.setup(subscriptions: subscriptions)
            guard let action = await subscriptions.nextBackgroundTranscriptionAction() else {
                completion.complete(true)
                return
            }
            switch action {
            case .transcribe(let episode):
                guard let url = episode.fullLocalUrl(.audio) else { break }
                let base = url.deletingPathExtension().lastPathComponent
                let progressBefore = subscriptions.transcriptProgress(base)
                _ = transcriber.load(url, title: episode.title, desc: episode.desc, episodeAudioURL: episode.audio)
                await transcriber.transcribe(url)
                // A run iOS cut short doesn't count against the episode.
                if !completion.isFinished {
                    await subscriptions.recordBackgroundRun(base, progressBefore: progressBefore)
                }
            case .summarizeOnly(let episode):
                // Already transcribed; just retry the summary.
                guard let url = episode.fullLocalUrl(.audio) else { break }
                await transcriber.summarizeExistingTranscript(url, title: episode.title, desc: episode.desc, episodeAudioURL: episode.audio)
            }
            completion.complete(true)
        }
    }

    static func scheduleTranscriptionRefresh() {
        guard UserDefaults.standard.bool(forKey: kBackgroundTranscriptionEnabledKey) else {
            // Disabled in the More menu — make sure nothing is left pending either.
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: kTranscriptionBackgroundIdentifier)
            return
        }
        let request = BGProcessingTaskRequest(identifier: kTranscriptionBackgroundIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        request.earliestBeginDate = .now.addingTimeInterval(1800)

        do {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: kTranscriptionBackgroundIdentifier)
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("Couldn't schedule transcription task \(error.localizedDescription)")
        }
    }

    @MainActor
    private func openEpisode(audioURL: String) async {
        guard let subscriptions, let player,
              let episode = await subscriptions.findEpisode(audioURL) else { return }
        _ = player.setPodcast(episode)
        NotificationCenter.default.post(name: .openPlayerNotification, object: nil)
    }

    func scheduleAppRefresh() {
        let request = BGProcessingTaskRequest(identifier: kBackgroundIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = .now.addingTimeInterval(3600 * 4)
        
        do {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: kBackgroundIdentifier)
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("Couldn't schedule app refresh \(error.localizedDescription)")
        }
    }
}

