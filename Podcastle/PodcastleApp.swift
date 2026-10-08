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
// UserDefaults key for the "Background Transcription" toggle in MainView's More
// menu. Registered with a `true` default at launch (see AppDelegate) rather than
// relying on @AppStorage's own registration, since AppDelegate can read/act on it
// (didFinishLaunchingWithOptions, scheduling) before any SwiftUI view has run.
public let kBackgroundTranscriptionEnabledKey = "backgroundTranscriptionEnabled"
// Whether MainView has shown the one-time "enable background transcription?"
// onboarding prompt yet — asked once regardless of the answer.
public let kBackgroundTranscriptionOnboardingShownKey = "backgroundTranscriptionOnboardingShown"
// "Continue Playing" in the More menu — auto-advances to the most recent unplayed
// downloaded episode when the current one finishes. On by default, unlike
// background transcription: it costs nothing extra (just picks what plays next)
// rather than battery, so there's no need to ask before turning it on.
public let kContinuePlayingEnabledKey = "continuePlayingEnabled"
@MainActor public var kScreenScale = 2.0

@main
struct PodcastleApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var accentColor: Color = .blue
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var subscriptions: Subscriptions?
    @StateObject var downloadStatus = DownloadStatus()
    @StateObject var downloads = Downloads()
    @StateObject var transcriber = Transcriber()
    @StateObject var player = PodcastPlayer()
    @StateObject var file = PodcastFile()
    @StateObject var imageCache = ImageCache()
     
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
                            // Shared with AppDelegate — a background-task launch may
                            // already have created it before this view ever ran.
                            let subscriptions = try appDelegate.sharedSubscriptions()
                            self.subscriptions = subscriptions
                            await self.subscriptions?.setup(downloads: downloads)
                            appDelegate.registerSubscriptions(subscriptions)
                            await checkMigration()
                            await downloads.setup(status: downloadStatus)
                            player.setup(subscriptions: subscriptions, transcriber: transcriber, file:file, downloads:downloads)
                            appDelegate.registerDownloads(downloads)
                            appDelegate.registerPlayer(player)
                            CarPlayController.shared.player = player
                            CarPlayController.shared.file = file
                            CarPlayController.shared.subscriptions = subscriptions
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
    
    func checkMigration() async {
        let migration = Migration(modelContainer: subscriptions!.modelContainer)
        // Needed for some helper functions
        await migration.setup(subscriptions: subscriptions!)
        // If migration from JSON files to SwiftData is needed...
        if await migration.needsMigration() {
            await migration.migrateJSON()
        }
    }
}

// BGProcessingTask's expirationHandler can fire concurrently with the work it's
// guarding against — both paths want to call setTaskCompleted, but doing that twice
// is a misuse the system logs and penalizes. This makes "whoever gets there first
// wins, the other is a no-op" thread-safe.
private final class TaskCompletion {
    private let lock = NSLock()
    private var finished = false
    private let task: BGProcessingTask

    init(_ task: BGProcessingTask) {
        self.task = task
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
    // Tapping the "summary ready" notification should open straight to that
    // episode's player/transcript, not just bring the app to the foreground.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                 didReceive response: UNNotificationResponse,
                                 withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        guard let audioURL = response.notification.request.content.userInfo["episodeAudioURL"] as? String,
              !audioURL.isEmpty else {
            return
        }
        guard subscriptions != nil, player != nil else {
            // Cold launch: PodcastleApp's async setup hasn't registered these yet —
            // flushed by registerSubscriptions/registerPlayer once it has.
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
    // Set when iOS relaunches the app in the background to deliver background URLSession
    // events before PodcastleApp's async setup task has finished and called registerDownloads.
    // Flushed as soon as downloads becomes available so the completion handler is never dropped.
    private var pendingBackgroundSessionCompletion: (identifier: String, handler: () -> Void)?
    // Same idea for a "summary ready" notification tapped on a cold launch —
    // subscriptions/player haven't finished their async setup yet, so the episode
    // it points to is remembered and opened once registerSubscriptions/registerPlayer
    // have both run.
    private var pendingNotificationEpisodeAudioURL: String?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    )  -> Bool {
        // Off by default — MainView's one-time onboarding prompt is what turns
        // this on, since it costs battery and the user should opt in knowingly
        // rather than finding out it's already been running.
        UserDefaults.standard.register(defaults: [
            kBackgroundTranscriptionEnabledKey: false,
            kContinuePlayingEnabledKey: true
        ])
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

    // The one Subscriptions instance for the whole process. Lives here rather than
    // only in PodcastleApp's state because when iOS launches the app purely to run
    // the transcription BGTask, no window is shown and PodcastleApp's setup `.task`
    // never runs — the task has to be able to build Subscriptions itself. Whichever
    // side gets here first creates it; the other reuses it, so there's never a
    // second ModelContainer on the same store.
    func sharedSubscriptions() throws -> Subscriptions {
        if let subscriptions { return subscriptions }
        let sub = try Subscriptions(modelContainer: ModelContainer(for: Directory.self, Episode.self, configurations: ModelConfiguration(isStoredInMemoryOnly: false)))
        subscriptions = sub
        return sub
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

    // Needed so a summary finishing while the app is backgrounded (interactively
    // or via the transcription BGTask) can actually alert the user.
    func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
            if let error {
                print("Notification authorization error: \(error.localizedDescription)")
            }
        }
    }

    func registerDownloads(_ d:Downloads) {
        downloads = d
        // Flush a handoff that arrived before PodcastleApp's async setup finished —
        // otherwise the completion handler would be dropped forever (see below).
        if let pending = pendingBackgroundSessionCompletion {
            pendingBackgroundSessionCompletion = nil
            Task {
                await d.setBackgroundCompletionHandler(pending.handler)
            }
        }
    }

    // iOS calls this when a background URLSession has events to deliver. This can happen
    // as soon as the app is relaunched into the background — potentially before
    // PodcastleApp's async setup task has run and called registerDownloads(), in which case
    // `downloads` is still nil here. Buffer the handoff instead of dropping it: failing to
    // ever call completionHandler gets the app penalized by iOS, and skipping
    // setBackgroundCompletionHandler means the background session/delegate never
    // reconnects, so pending download-completion events are never delivered either.
    // We must create/reconnect to the same session and call the completion
    // handler only after urlSessionDidFinishEvents fires — telling iOS the
    // app is done processing so it can take a new snapshot.
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
            // Handle the background task execution
            task.expirationHandler = {
                task.setTaskCompleted(success: false)
            }
            Task {
                // Perform background refresh
                await self.subscriptions?.backgroundRefresh()
                
                // Ensure completion is called on main thread
                await MainActor.run {
                    task.setTaskCompleted(success: true)
                }
            }
            // Schedule next refresh
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

    // Transcribes one downloaded-but-untranscribed (or partially transcribed) episode
    // per wake. Runs a scratch Transcriber rather than the one wired into the live
    // player/UI, so a background run never clobbers whatever the user has on screen —
    // both write the same per-episode .json checkpoint file, so the UI picks up
    // whatever background transcription completed next time that episode is opened.
    func handleTranscriptionTask(_ task: BGProcessingTask) {
        let completion = TaskCompletion(task)
        // Turned off in the More menu — nothing to do, and no reschedule below
        // means the chain of wakes stops here until the user turns it back on.
        guard UserDefaults.standard.bool(forKey: kBackgroundTranscriptionEnabledKey) else {
            completion.complete(true)
            return
        }
        // Low Power Mode usually means the user is specifically trying to stretch
        // a low battery — this is exactly the kind of background CPU work that
        // should sit out until it's off again. Unlike the disabled-setting case
        // above, this is transient, so (unlike that one) it still explicitly
        // queues the next wake itself — if the device is still in Low Power Mode
        // next time too, it's skipped again then.
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else {
            print("Skipping background transcription: Low Power Mode is on.")
            Self.scheduleTranscriptionRefresh()
            completion.complete(true)
            return
        }
        let transcriber = Transcriber()

        task.expirationHandler = {
            // Cancel cooperatively — Transcriber checkpoints as it goes, so whatever
            // it finished transcribing before expiration is already saved to disk,
            // and the next wake resumes from there instead of starting over.
            transcriber.cancel()
            completion.complete(false)
        }

        // Queue the next attempt right away, the same way registerBackgroundTasks
        // does above for the download-refresh task — NOT after this run finishes.
        // expirationHandler only gets a short grace period, and if our cancellation
        // doesn't unwind fast enough the process can be torn down before it runs at
        // all; scheduling up front means a request is already sitting in
        // BGTaskScheduler regardless of how this run ends.
        Self.scheduleTranscriptionRefresh()

        Task {
            // On a cold background launch PodcastleApp's setup hasn't run (and
            // won't, with no window shown), so build Subscriptions here if needed.
            guard let subscriptions = try? self.sharedSubscriptions() else {
                completion.complete(false)
                return
            }
            transcriber.setup(subscriptions: subscriptions)
            guard let action = await subscriptions.nextBackgroundTranscriptionAction() else {
                // Nothing needs doing right now.
                completion.complete(true)
                return
            }
            switch action {
            case .transcribe(let episode):
                guard let url = episode.fullLocalUrl(.audio) else { break }
                // load() detects and sets the episode's language itself now.
                _ = transcriber.load(url, title: episode.title, desc: episode.desc, episodeAudioURL: episode.audio)
                await transcriber.transcribe(url)
            case .summarizeOnly(let episode):
                // Already fully transcribed — just retry the summary (e.g. the
                // on-device model was still downloading/preparing last time)
                // without redoing potentially hours of finished transcription.
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
        // On-device speech recognition needs no network, just CPU time.
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

