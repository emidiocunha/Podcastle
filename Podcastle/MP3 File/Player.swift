//
//  Player.swift
//  Podcastle
//
//  Created by Emídio Cunha on 14/06/2025.
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
import AVKit
import AVFoundation
import MediaPlayer
import Speech
import NaturalLanguage
import SwiftData

@MainActor class AudioInterruptionObserver: ObservableObject {
    @Published var isAudioInterrupted = false

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
    }

    @objc private func handleAudioSessionInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            // Interruption began
            DispatchQueue.main.async {
                self.isAudioInterrupted = true
            }

        case .ended:
            // Interruption ended
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    // Resume playback if appropriate
                    DispatchQueue.main.async {
                        self.isAudioInterrupted = false
                    }
                }
            }

        @unknown default:
            break
        }
    }
}

@MainActor class PodcastPlayer : ObservableObject {
    // These are considered @Published vars but we do it manually
    var progress:Double = 20.0
    var duration:Double = 100.0
    var rate:Float = 1.0
    var isActive:Bool = false
    var isPlaying:Bool = false
    var title:String = ""
    var image:UIImage? = nil
    var secondsLeft:Double = 0.0
    var currentPodcast:Episode?
    
    // Heloper Objects
    private let audioPlayer = AVPlayer()
    private var timeObserverToken: Any?
    private var file:PodcastFile?
    private var subscriptions:Subscriptions?
    private var transcriber:Transcriber?
    private var downloads:Downloads?
    
    init() {
        // Listen for end of playback
        Task.detached {
            for await _ in NotificationCenter.default.notifications(
                named: .AVPlayerItemDidPlayToEndTime,
                object: self.audioPlayer.currentItem
            ) {
                Task { @MainActor in
                    self.pause()
                }
            }
        }
    }
    
    // Wire up helper objects that don't transfer from the SwiftUI environment
    func setup(subscriptions:Subscriptions?, transcriber:Transcriber?, file:PodcastFile?, downloads:Downloads?) {
        self.subscriptions = subscriptions
        self.transcriber = transcriber
        self.file = file
        self.downloads = downloads
        Task {
            // Delay just enough for view tree to be complete and trigger the setPodcast change
            try? await Task.sleep(nanoseconds: 2_000_000)
            if let p = UserDefaults.standard.object(forKey: "currentPodcast") {
                if let lastPodcast = await subscriptions?.findEpisode(p as! String) {
                    _ = setPodcast(lastPodcast)
                }
            }
            setupRemoteTransportControls()
        }
    }
    
    // Clear all values in preperation for a new podcast file
    func reset() {
        objectWillChange.send()
        currentPodcast = nil
        transcriber?.reset()
        title = ""
        secondsLeft = 0.0
        progress = 0.0
        duration = 0.0
        let r = UserDefaults.standard.float(forKey: "lastRate")
        if r != 0.0 {
            rate = r
        }
        image = nil
    }
    
    // Replaces current podcast with new one
    func setPodcast(_ podcast:Episode) -> Bool {
        guard podcast.fileSize(.audio).count > 0 else {
            return false
        }

        reset()
        currentPodcast = podcast
        Task {
            _ = await subscriptions?.save()
            _ = try! await downloads?.downloadFile(podcast.artwork, localPath:podcast.fullLocalUrl(.artwork)!.path(), overwrite:false, progress: false)
        }
        UserDefaults.standard.set(podcast.audio, forKey: "currentPodcast")
        transcriber?.reset()
        _ = transcriber?.load(podcast.audio)
        setupChapters()
        startPlaying()
        return true
    }
    
    // Local audio file location
    func audioFileURL() -> URL? {
        return currentPodcast?.fullLocalUrl(.audio)
    }
    
    // 
    func startPlaying() {
        if let t = timeObserverToken {
            audioPlayer.removeTimeObserver(t)
            timeObserverToken = nil
        }
        
        if let currentPodcast = currentPodcast {
            let url = currentPodcast.fullLocalUrl(.audio)!
            
            objectWillChange.send()
            audioPlayer.replaceCurrentItem(with: AVPlayerItem(url: url))
            progress = currentPodcast.position
            audioPlayer.seek(to:CMTimeMakeWithSeconds(currentPodcast.position, preferredTimescale:Int32(NSEC_PER_SEC)))
            duration = currentPodcast.duration
            secondsLeft = (duration) - progress
            if currentPodcast.duration == 0 {
                Task { @MainActor in
                    do {
                        let a_duration = try await audioPlayer.currentItem?.asset.load(.duration).seconds ?? 0.0
                        duration = a_duration
                    } catch let error {
                        print("\(error) while loading duration")
                    }
                }
            }
            title = currentPodcast.title
            isActive = true
            file?.updateCurrentChapter(progress)
            updateImage()
        }
    }
    
    // The podcast image cover, or chapter image is updated here if necessary
    func updateImage() {
        if let ch = file?.currentChapter {
            image = ch.chapterImage()
        } else {
            image = nil
        }
        if isPlaying {
            setupNowPlaying()
        }
    }

    // Rate controls the playback speed, and is stored at the defaults
    func setRate(_ rate:Float) {
        if let currentPodcast = currentPodcast {
            guard currentPodcast.audio.count > 0 else { return }
            objectWillChange.send()
            self.rate = rate
            UserDefaults.standard.setValue(rate, forKey: "lastRate")
            audioPlayer.rate = rate
        }
    }
    
    // This will move progress up by the number of seconds indicated
    // Negative number is allowed to move back
    func seek(_ seconds:Double) {
        if let currentPodcast = currentPodcast {
            guard currentPodcast.audio.count > 0 else { return }
            
            var n = progress + seconds
            
            // Check for boundaries, beginning and end of file
            if n < 0 {
                n = 0
            } else {
                let d = duration
                
                if n > d {
                    n = d
                }
            }
            self.objectWillChange.send()
            audioPlayer.seek(to:CMTimeMakeWithSeconds(n, preferredTimescale:Int32(NSEC_PER_SEC)))
            progress = n
            file?.updateCurrentChapter(n)
            updateImage()
        }
    }
    
    // To help move to absolute seconds into the podcast
    func absoluteSeek(_ seconds:Double) {
        progress = 0.0
        seek(seconds)
    }
    
    func addPeriodicTimeObserver() {
        // Invoke callback every second
        let interval = CMTime(seconds: 1.0,
                              preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        // Add time observer. Invoke closure on the main queue.
        timeObserverToken = audioPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }

            Task { @MainActor in
                // Cohalesce multiple variables update with this send
                // self.objectWillChange.send()
                
                // Update chapter information
                if let c = self.file?.currentChapter, time.seconds > Double(c.endTime / 1000) {
                    self.file?.updateCurrentChapter(time.seconds)
                    self.updateImage()
                }
                self.progress = time.seconds
                self.secondsLeft = self.duration - time.seconds
                // Throttle saving to database every 30s
                if Int(time.seconds) % 30 == 0 {
                    self.currentPodcast?.position = time.seconds
                    _ = await self.subscriptions?.save()
                }
            }
        }
    }
    
    func setupRemoteTransportControls() {
        // Get the shared MPRemoteCommandCenter
        let commandCenter = MPRemoteCommandCenter.shared()

        // Add wired playpase command
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [unowned self] event in
            if audioPlayer.rate != 0 {
                self.pause()
            } else {
                self.play()
            }
            return .success
        }
        
        // Add handler for Play Command
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [unowned self] event in
            if self.audioPlayer.rate == 0.0 {
                self.play()
                return .success
            }
            return .commandFailed
        }

        // Add handler for Pause Command
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [unowned self] event in
            if self.audioPlayer.rate == 1.0 {
                self.pause()
                self.setupNowPlaying()
                return .success
            }
            return .commandFailed
        }
        
        // Add handler for Skip Forward Command
        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(30.0)]
        commandCenter.skipForwardCommand.addTarget { [unowned self] event in
            if self.audioPlayer.rate == 1.0 {
                self.seek(30)
                self.setupNowPlaying()
                return .success
            }
            return .commandFailed
        }

        // Add handler for Skip Backward Command
        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(30.0)]
        commandCenter.skipBackwardCommand.addTarget { [unowned self] event in
            if self.audioPlayer.rate == 1.0 {
                self.seek(-30)
                return .success
            }
            return .commandFailed
        }
        
        // Add handler for Skip Forward Command
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [unowned self] event in
            if self.audioPlayer.rate == 1.0 {
                self.seek(30)
                self.setupNowPlaying()
                return .success
            }
            return .commandFailed
        }

        // Add handler for Skip Backward Command
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [unowned self] event in
            if self.audioPlayer.rate == 1.0 {
                self.seek(-30)
                return .success
            }
            return .commandFailed
        }

    }
    
    func setupNowPlaying() {
        // Define Now Playing Info
        var nowPlayingInfo = [String : Any]()
        
        if let currentPodcast = currentPodcast {
            nowPlayingInfo[MPMediaItemPropertyTitle] = currentPodcast.title
            nowPlayingInfo[MPMediaItemPropertyArtist] = currentPodcast.author
            do {
                var imageData: Data?
                
                if let image = image {
                    nowPlayingInfo[MPMediaItemPropertyArtwork] =
                    MPMediaItemArtwork(boundsSize: image.size) { size in
                        return image
                    }
                } else {
                    let localUrl = currentPodcast.fullLocalUrl(.artwork)!
                    imageData = try Data(contentsOf: localUrl)
                    
                    if  let imageData = imageData,
                        let image = UIImage(data:imageData) {
                        nowPlayingInfo[MPMediaItemPropertyArtwork] =
                        MPMediaItemArtwork(boundsSize: image.size) { size in
                            return image
                        }
                    }
                }
            } catch let error {
                print("Error using local image: ", error)
            }
            
            if let item = audioPlayer.currentItem {
                nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = item.currentTime().seconds as AnyObject
                nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration as AnyObject
                nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = audioPlayer.rate as AnyObject
                nowPlayingInfo[MPNowPlayingInfoPropertyIsLiveStream] = false as AnyObject
                nowPlayingInfo[MPNowPlayingInfoPropertyMediaType] = MPMediaType.podcast.rawValue as AnyObject
                nowPlayingInfo[MPMediaItemPropertyAlbumTrackNumber] = 1 as AnyObject
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
            }
        }
    }
    
    func setupChapters() {
        file?.loadFile(audioFileURL()?.path() ?? "", seconds:progress)
    }
        
    func play() {
        if let currentPodcast = currentPodcast {
            guard currentPodcast.audio.count > 0 else { return }
            
            self.objectWillChange.send()
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.allowAirPlay])
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                print(error)
            }
            let r = rate
            audioPlayer.rate = r
            audioPlayer.playImmediately(atRate: r)
            addPeriodicTimeObserver()
            setupNowPlaying()
            isPlaying = audioPlayer.rate != 0 && audioPlayer.error == nil
            MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        }
    }
    
    func pause() {
        self.objectWillChange.send()
        audioPlayer.pause()
        isPlaying = audioPlayer.rate != 0 && audioPlayer.error == nil
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        NotificationCenter.default.removeObserver(self)
        do {
            try AVAudioSession.sharedInstance().setActive(false)
        } catch {
            print(error)
        }
    }
}
