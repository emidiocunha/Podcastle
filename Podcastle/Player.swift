//
//  Player.swift
//  VoiceFeed
//
//  Created by Emídio Cunha on 14/06/2023.
//

import Foundation
import AVKit
import AVFoundation
import MediaPlayer
import Speech
import NaturalLanguage

class PodcastPlayer : NSObject, ObservableObject {
    static let shared = PodcastPlayer()
    var currentPodcast:Podcast?
    private let audioPlayer = AVPlayer()
    private var timeObserverToken: Any?
    private var downloads = Downloads.shared
    @Published var isActive:Bool = false
    @Published var isPlaying:Bool = false
    @Published var progress:Double = 20.0
    @Published var duration:Double = 100.0
    @Published var title:String = ""
    @Published var transcription = ""
    @Published var log:[String] = []
    private var lastTranscription = ""
    private var lastRate:Float = 1.0
    private var inputPipe = Pipe()
    private var outputPipe = Pipe()
    var transcriber = Transcriber.shared
    
    private override init() {
        super.init()
        if let p = UserDefaults.standard.object(forKey: "currentPodcast") {
            reset()
            if let lastPodcast = Subscriptions.shared.find(p as! String) {
                currentPodcast = lastPodcast
                if currentPodcast!.localAudioUrl.count > 0 {
                    Transcriber.shared.load(currentPodcast!) //URL(string:currentPodcast!.localAudioUrl)!)
                }
                startPlaying()
                setupRemoteTransportControls()
            }
            //Transcriber.shared.reset()
        }
        let r = UserDefaults.standard.float(forKey: "lastRate")
        if r != 0.0 {
            lastRate = r
        }
    }
    
    func reset() {
        currentPodcast = Podcast()
        Transcriber.shared.reset()
        title = ""
        progress = 0.0
        duration = 0.0
    }
    
    func setPodcast(_ podcast:Podcast) -> Bool {
        guard podcast.fileSize(.audio).count > 0 else {
            return false
        }
        reset()
        Subscriptions.shared.sync()
        currentPodcast = podcast
        Downloads.shared.downloadFile(podcast.artworkUrl, localPath:podcast.localArtworkUrl, overwrite:false) { progress in } completionHandler: { fileURL, error in }
        startPlaying()
        UserDefaults.standard.set(podcast.id, forKey: "currentPodcast")
        Transcriber.shared.reset()
        Transcriber.shared.load(podcast) //URL(string:podcast.localAudioUrl)!)
        extractChapters(from:podcast)
        return true
    }
    
    func audioFileURL() -> URL? {
        if let currentPodcast = currentPodcast,
           let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let url = d.appendingPathComponent(currentPodcast.localAudioUrl, isDirectory: false)
            
            return url
        }
        return nil
    }
    
    func startPlaying() {
        if let t = timeObserverToken {
            audioPlayer.removeTimeObserver(t)
            timeObserverToken = nil
        }
        
        if let currentPodcast = currentPodcast,
           let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let url = d.appendingPathComponent(currentPodcast.localAudioUrl, isDirectory: false)
            
            audioPlayer.replaceCurrentItem(with: AVPlayerItem(url: url))
            progress = Subscriptions.shared.podcastPosition(currentPodcast)
            audioPlayer.seek(to:CMTimeMakeWithSeconds(Subscriptions.shared.podcastPosition(currentPodcast), preferredTimescale:Int32(NSEC_PER_SEC)))
            duration = currentPodcast.duration
            if duration == 0 {
                Task {
                    do {
                        let a_duration = try await audioPlayer.currentItem?.asset.load(.duration).seconds ?? 0.0
                        Task { @MainActor in
                            duration = a_duration
                        }
                    } catch let error {
                        print("\(error) while loading duration")
                    }
                }
            }
            title = currentPodcast.title
            isActive = true
        }
    }
    
    func setRate(_ rate:Float) {
        if let currentPodcast = currentPodcast {
            guard currentPodcast.id.count > 0 else { return }
            
            lastRate = rate
            UserDefaults.standard.setValue(rate, forKey: "lastRate")
            audioPlayer.rate = rate
        }
    }
    
    func rate() -> Float {
        let rate = audioPlayer.rate
        
        if rate == 0.0 {
            return lastRate
        } else {
            return audioPlayer.rate
        }
    }
    
    func seek(_ seconds:Double) {
        if let currentPodcast = currentPodcast {
            guard currentPodcast.id.count > 0 else { return }
            
            var n = progress + seconds
            
            if n < 0 {
                n = 0
            } else if n > duration {
                n = duration
            }
            
            audioPlayer.seek(to:CMTimeMakeWithSeconds(n, preferredTimescale:Int32(NSEC_PER_SEC)))
        }
    }
    
    func absoluteSeek(_ seconds:Double) {
        seek(seconds - progress)
    }
    
    func podcast() -> Podcast? {
        return currentPodcast
    }
    
    func addPeriodicTimeObserver() {
        // Invoke callback every second
        let interval = CMTime(seconds: 1.0,
                              preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        // Add time observer. Invoke closure on the main queue.
        timeObserverToken =
            audioPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                guard self?.currentPodcast != nil else {
                    return
                }
                self?.progress = time.seconds
                Subscriptions.shared.updatePodcastNote(self!.currentPodcast!, position: time.seconds)
                if Int(time.seconds) % 30 == 0 {
                    Subscriptions.shared.syncNotes()
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
                
                if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                    let localUrl = d.appendingPathComponent(currentPodcast.localArtworkUrl, isDirectory: false)
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
        
    func play() {
        if let currentPodcast = currentPodcast {
            guard currentPodcast.id.count > 0 else { return }
            
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.allowAirPlay])
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                print(error)
            }
            NotificationCenter.default.addObserver(self,
                                                   selector:#selector(self.playerDidFinishPlaying(note:)),
                                                   name: NSNotification.Name.AVPlayerItemDidPlayToEndTime,
                                                   object: audioPlayer.currentItem)
            audioPlayer.rate = lastRate
            audioPlayer.play()
            addPeriodicTimeObserver()
            setupNowPlaying()
            isPlaying = audioPlayer.rate != 0 && audioPlayer.error == nil
            MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        }
    }
    
    @objc func playerDidFinishPlaying(note: NSNotification) {
        pause()
    }
    
    func pause() {
        do {
            try AVAudioSession.sharedInstance().setActive(false)
        } catch {
            print(error)
        }
        audioPlayer.pause()
        isPlaying = audioPlayer.rate != 0 && audioPlayer.error == nil
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        NotificationCenter.default.removeObserver(self)
        Subscriptions.shared.syncNotes()
    }
    
    func prettyPrintSeconds(_ seconds:Double) -> String {
        let hours:Int = Int(seconds) / 3600
        let minutes:Int = (Int(seconds) - (hours * 3600)) / 60
        let sec:Int = (Int(seconds) - (hours * 3600) - (minutes * 60))
        var ret = hours > 0 ? String(format:"%02d:", hours) : ""
        
        ret.append(String(format:"%02d:%02d", minutes, sec))
        return ret
    }
    
    func extractChapters(from podcast: Podcast) {
        let asset = AVAsset(url: URL(string: podcast.localAudioUrl)!)
        
        // Accessing metadata
        let metadata = asset.commonMetadata + asset.metadata
        
        for item in metadata {
           if let value = item.value {
              switch item.commonKey?.rawValue {
              default:
                  print("\(value)")
                 break
              }
           }
        }
        
        // Filter for ID3 metadata potentially containing chapter info
        /*
        let id3Metadata = metadata.filter { $0.commonKey ==  }
        
        for item in id3Metadata {
            // Assuming chapters might be encoded in the 'comment' field or similar
            if let key = item.key as? String, key == "COMM" || key == "chapters" {
                if let value = item.value {
                    print("Chapter Info: \(value)")
                    // Further parsing might be required here depending on how chapters are encoded
                }
            }
        }*/
    }
    
    func detectLanguage() -> String {
        if let currentPodcast = currentPodcast {
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(currentPodcast.description)
            
            if let languageCode = recognizer.dominantLanguage?.rawValue {
                let detectedLanguage = languageCode
                print("Detected language \(detectedLanguage)")
                return detectedLanguage 
            }
        }
        return "en_US"
    }
    
    func transcribe() {
        if let currentPodcast = currentPodcast,
           let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let localUrl = d.appendingPathComponent(currentPodcast.localAudioUrl, isDirectory: false)
            
            transcriber.setLanguage(detectLanguage())
            transcriber.transcribe(localUrl)
        }
            
    /*
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = true
            request.addsPunctuation = true
            if let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en_US")) {
                if speechRecognizer.isAvailable {
                    speechRecognizer.recognitionTask(with: request, resultHandler: { result, error in
                        guard error == nil, let result = result else {
                            print("Transcription error: \(error?.localizedDescription ?? "")")
                            return
                        }
                        let formattedString = result.bestTranscription.formattedString
                        /*if result.isFinal {
                            let formattedString = result.bestTranscription.segments.reduce("") { (prev, segment) in
                                let timestamp = segment.timestamp
                                let text = segment.substring
                                let annotatedText = String(format: "%.2f: %@", timestamp, text)
                                return prev + annotatedText + "\n"
                            }
                            self.transcription = formattedString*/
                        
                        if formattedString.count < self.lastTranscription.count {
                            self.transcription += self.lastTranscription
                            self.transcription += "\n"
                            self.lastTranscription = formattedString
                        } else {
                            self.lastTranscription = formattedString
                        }
                        
                        //print("\(self.transcription)")
                        //}
                    })
                }
            }
        }*/
    }
}
