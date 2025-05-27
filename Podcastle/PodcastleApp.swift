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

// Change as needed for your bundle IDs
public let kAppRefreshIdentifier = "com.mobyte.voicefeed.Refresh"
public let kBackgroundIdentifier = "com.mobyte.voicefeed.backgroundDownload"
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
            }
            else {
                ProgressView()
                    .task {
                        do {
                            let subscriptions = try Subscriptions(modelContainer: ModelContainer(for: Directory.self, Episode.self, configurations: ModelConfiguration(isStoredInMemoryOnly: false)))
                            self.subscriptions = subscriptions
                            await self.subscriptions?.setup(downloads: downloads)
                            appDelegate.registerSubscriptions(subscriptions)
                            await checkMigration()
                            await downloads.setup(status: downloadStatus)
                            player.setup(subscriptions: subscriptions, transcriber: transcriber, file:file, downloads:downloads)
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

class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var subscriptions:Subscriptions?
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    )  -> Bool {
        registerBackgroundTasks()
        scheduleAppRefresh()
        return true
    }
    
    func registerSubscriptions(_ sub:Subscriptions) {
        subscriptions = sub
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

