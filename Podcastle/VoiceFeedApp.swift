//
//  VoiceFeedApp.swift
//  VoiceFeed
//
//  Created by Emídio Cunha on 07/06/2023.
//

import SwiftUI
import Speech
import BackgroundTasks

public let kAppRefreshIdentifier = "com.mobyte.voicefeed.Refresh"
public let kBackgroundIdentifier = "com.mobyte.voicefeed.backgroundDownload"
public var kScreenScale = 2.0

@main
struct VoiceFeedApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var accentColor: Color = .blue
    
    var body: some Scene {
        WindowGroup {
            MainView()
        }.onChange(of: scenePhase) { newScenePhase in
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
                    await Subscriptions.shared.refresh()
                }
            } else if newScenePhase == .background {
                scheduleAppRefresh()
            }
        }
        .backgroundTask(.appRefresh(kAppRefreshIdentifier)) {
            print("entered backgroundRefresh")
            scheduleAppRefresh()
            await Subscriptions.shared.refresh()
        }
        .backgroundTask(.urlSession(kBackgroundIdentifier)) {
        }
        
    }
    
    func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier:kAppRefreshIdentifier, using: nil) { task in
            scheduleAppRefresh()
            Subscriptions.shared.backgroundRefresh()
        }
    }
    
    func scheduleAppRefresh() {
        let request = BGProcessingTaskRequest(identifier: kAppRefreshIdentifier)
        //let request = BGAppRefreshTaskRequest(identifier: kAppRefreshIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = .now.addingTimeInterval(3600 * 6)
        try? BGTaskScheduler.shared.submit(request)
    }
}
