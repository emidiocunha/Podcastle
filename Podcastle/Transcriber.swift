//
//  Transcriber.swift
//  VoiceFeed
//
//  Created by Emídio Cunha on 27/07/2023.
//

import Foundation
import Speech
import AVFoundation
import SwiftUI

struct Sentence:Codable, Identifiable {
    let id:Int
    let sentence:String
    let timestamp:TimeInterval
}

struct TranscriptView: View {
    @EnvironmentObject var player: PodcastPlayer
    @StateObject var transcriber = Transcriber.shared
    @State var searchString = ""
    @State var limit = 10
    
    var body: some View {
        VStack {
            Text("Transcript").font(.title2)
        }
        VStack(alignment: .leading) {
            if !transcriber.working {
                HStack {
                    Spacer()
                    TextField("", text:$searchString, prompt: Text("Search").foregroundColor(.gray)).onChange(of: searchString) { newValue in
                        transcriber.filter(searchString)
                    }.foregroundColor(.black).frame(height: 40).border(.white).background(.white).cornerRadius(8.0)
                    Spacer()
                }.onAppear {
                    UITextField.appearance().clearButtonMode = .whileEditing
                }
                Spacer(minLength: 20)
            }
            ForEach(transcriber.sentences.prefix(limit)) { sentence in
                HStack {
                    VStack {
                        Button {
                            player.absoluteSeek(sentence.timestamp)
                            if !player.isPlaying {
                                player.play()
                            }
                        } label: {
                            Text("\(transcriber.prettyPrintSeconds(sentence.timestamp))").font(.headline)
                        }.buttonStyle(.bordered)
                        Spacer()
                    }
                    Text("\(sentence.sentence)").onTapGesture {
                        player.absoluteSeek(sentence.timestamp)
                        if !player.isPlaying {
                            player.play()
                        }
                    }.gesture(LongPressGesture(minimumDuration: 1.0).onEnded {_ in
                        UIPasteboard.general.string = sentence.sentence
                        let feedbackGenerator:UISelectionFeedbackGenerator? = UISelectionFeedbackGenerator()
                        feedbackGenerator?.prepare()
                        feedbackGenerator?.selectionChanged()
                    })
                }
                Divider()
            }
            if transcriber.working {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        ProgressView().tint(.white).controlSize(.large)
                        Spacer()
                    }
                    HStack {
                        Spacer()
                        Text("\(transcriber.status)")
                        Spacer()
                    }
                    Spacer()
                }
            }
        }.padding()
        if !transcriber.working && limit < transcriber.sentences.count {
            Spacer()
            HStack {
                Spacer()
                Button {
                    limit = Int.max
                } label: {
                    Text("More...")
                }.buttonStyle(.bordered)
                Spacer()
            }
            Spacer(minLength: 20)
        }
        Spacer()
        HStack {
            Spacer()
            Button {
                if transcriber.working {
                    transcriber.cancel()
                } else {
                    limit = Int.max
                    player.transcribe()
                }
            } label: {
                Image(systemName: "waveform")
                Text(transcriber.working ? "Stop" : "Start")
            }.buttonStyle(.bordered)
            if !transcriber.working && transcriber.sentences.count > 0 {
                Spacer()
                Button {
                    transcriber.deleteTranscription()
                } label: {
                    Image(systemName: "trash")
                    Text("Delete")
                }.buttonStyle(.bordered)
                Spacer()
                ShareLink(item: transcriber.copyText()).buttonStyle(.borderedProminent)
            }
            Spacer()
        }
        Spacer()
    }
}

class Transcriber:NSObject, ObservableObject, SFSpeechRecognitionTaskDelegate {
    @Published var text:String = ""
    @Published var working = false
    @Published var sentences: [Sentence] = []
    @Published var status = ""
    var allSentences: [Sentence] = []
    
    private var recognitionGroup:DispatchGroup? = nil
    private var audioURL:URL? = nil
    private var currentTask:SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    static let shared = Transcriber()
    private var currentTimeOffset:TimeInterval = 0
    private var language = "en_US"
    private var handler:(([(String, TimeInterval)]?, Error?) -> Void)? = nil

    private var resumePosition:Int64 = 0
    
    func loadAudioFile(fromURL url: URL) -> AVAudioFile? {
        do {
            let audioFile = try AVAudioFile(forReading: url)
            return audioFile
        } catch {
            print("Error loading audio file: \(error)")
            return nil
        }
    }
    
    func filter(_ text:String) {
        if text.count == 0 {
            sentences = allSentences
            return
        } else if text.count > 2 {
            Task.init(priority: .userInitiated) {
                let s = text.lowercased()
                let result = allSentences.filter { value in
                    value.sentence.lowercased().contains(s)
                }
                Task { @MainActor in
                    sentences = result
                }
            }
        }
    }
    
    func copyText() -> String {
        var text = ""
        sentences.forEach { sentence in
            text += "\n\(prettyPrintSeconds(sentence.timestamp)) "
            text += sentence.sentence
        }
        return text
    }
    
    func temporaryFileURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
        let filename = UUID().uuidString + ".m4a"
        return directory.appendingPathComponent(filename)
    }
    
    func getPCMBufferLength(buffer: AVAudioPCMBuffer) -> TimeInterval {
        let framecount = Double(buffer.frameLength)
        let samplerate = buffer.format.sampleRate
        return TimeInterval(framecount / samplerate)
    }
    
    func checkResumable(_ audioFileURL:URL) {
        if let audioFile = loadAudioFile(fromURL: audioFileURL) {
            let audioFormat = audioFile.processingFormat
            let frameCount = audioFile.length
            let sampleRate = Double(audioFormat.sampleRate)
            let sizeInSeconds = Double(frameCount) / sampleRate
            if let lastSentenceTimeStamp = allSentences.last?.timestamp {
                if lastSentenceTimeStamp < (sizeInSeconds - 120) {
                    resumePosition = Int64(lastSentenceTimeStamp) * Int64(sampleRate)
                    allSentences = allSentences.dropLast()
                    return
                }
            }
        }
        resumePosition = 0
    }

    func recognizeSpeech(_ audioFileURL:URL) {
        do {
            let audioFile = try AVAudioFile(forReading: audioFileURL)
            let audioFormat = audioFile.processingFormat
            let frameCount = audioFile.length
            // Calculate the buffer size in frames
            let sampleRate = Double(audioFormat.sampleRate)
            let bufferSizeInSeconds = 120.0
            let bufferSizeInFrames = AVAudioFrameCount(bufferSizeInSeconds * sampleRate)
            let bufferSize: AVAudioFrameCount = bufferSizeInFrames
            var frameOffset: AVAudioFramePosition = resumePosition
            
            currentTimeOffset = resumePosition == 0 ? 0 : TimeInterval(resumePosition / Int64(sampleRate))
            
            while frameOffset < frameCount {
                // Create an AVAudioPCMBuffer to hold the audio data
                guard let audioBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: bufferSize * 2) else {
                    print("Failed to create audio buffer.")
                    return
                }
                audioFile.framePosition = frameOffset
                try audioFile.read(into: audioBuffer, frameCount: bufferSize)
                frameOffset += Int64(audioBuffer.frameLength)
                
                if !recognizeSpeechBuffer(audioBuffer) {
                    break
                }
            }
        } catch {
            print("Error loading audio file: \(error.localizedDescription)")
        }
        checkResumable(audioFileURL)
    }
    
    func setLanguage(_ languageCode:String) {
        language = languageCode
    }
    
    func recognizeSpeechBuffer(_ audioBuffer:AVAudioPCMBuffer) -> Bool {
        guard let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: language)) else {
            return false
        }
        
        let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        
        recognitionRequest.shouldReportPartialResults = false
#if targetEnvironment(simulator)
        recognitionRequest.requiresOnDeviceRecognition = false
#else
        recognitionRequest.requiresOnDeviceRecognition = speechRecognizer.supportsOnDeviceRecognition
#endif
        recognitionRequest.addsPunctuation = true
        recognitionRequest.append(audioBuffer)
        recognitionRequest.endAudio()
        
        recognitionGroup = DispatchGroup()
        recognitionGroup?.enter()

        currentTask = speechRecognizer.recognitionTask(with: recognitionRequest, delegate: self)
        
        Task { @MainActor in
            status = "Transcribing"
        }
        
        if recognitionGroup?.wait(timeout: .now() + 120) == .timedOut {
            Task { @MainActor in
                status = "Transcribing timed out"
                currentTask?.cancel()
            }
            return false
        }
        
        if let currentTask = currentTask, currentTask.isCancelled {
            return false
        }
        
        currentTask = nil
        
        currentTimeOffset += getPCMBufferLength(buffer: audioBuffer)
        return true
    }
    
    func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishSuccessfully successfully: Bool) {
        recognitionGroup?.leave()
        //audioEngine.inputNode.removeTap(onBus: 0)
    }
    
    func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishRecognition recognitionResult: SFSpeechRecognitionResult) {
        // Get the transcribed text from the result
        let transcription = recognitionResult.bestTranscription
        
        // Get the word-level timing information
        var timestamps: [(String, TimeInterval)] = []
        
        for segment in transcription.segments {
            let word = segment.substring
            let timestamp = currentTimeOffset + segment.timestamp
            if word.count > 0 {
                timestamps.append((word, timestamp))
            }
        }
        if timestamps.count > 0 {
            handler?(timestamps, nil)
        }
        
        if currentTask?.state == .completed {
            currentTask?.finish()
        }
    }
    
    func speechRecognitionTaskWasCancelled(_ task: SFSpeechRecognitionTask) {
        sentences.append(Sentence(id:sentences.count,
                                  sentence:"Speech Recognition Was Cancelled",
                                  timestamp:TimeInterval.infinity))
        recognitionGroup?.leave()
        //resumePosition = 0
        //audioEngine.inputNode.removeTap(onBus: 0)
    }
    
    func transcribeAudioFileWithTimestamps(at url: URL, completion: @escaping ([(String, TimeInterval)]?, Error?) -> Void) {
        handler = completion
        //currentTimeOffset = 0
        Task.init(priority:.medium) { [self] in
            //audioFiles = await splitAudioFileIntoSegments(fromURL: url)
            //while (recognizeSpeechForNextAudioSegment()) {}
            let fn = audioURL?.deletingPathExtension().lastPathComponent
            
            recognizeSpeech(url)
    
            if let fn = fn {
                Subscriptions.shared.saveArrayToDisk(array: allSentences, filePath: fn + ".json")
            }
            
            Task { @MainActor in
                status = "Saved transcription"
                working = false
            }
        }
        
        working = true
        status = ""
    }
    
    func cancel() {
        currentTask?.cancel()
        working = false
    }
    
    func reset() {
        cancel()
        sentences.removeAll()
        allSentences.removeAll()
        text = ""
        resumePosition = 0
    }
    
    func load(_ podcast:Podcast) {
        if let url = URL(string:podcast.localAudioUrl) {
            let fn = url.deletingPathExtension().lastPathComponent
            
            allSentences = Subscriptions.shared.loadArrayFromDisk(filePath: fn + ".json") ?? []
            
            if let fullURL = podcast.fullLocalUrl(.audio) {
                checkResumable(fullURL)
                audioURL = fullURL
            }
            
            sentences = allSentences
        }
        /*text = ""
        
        for s in sentences {
            text += "\n\(prettyPrintSeconds(s.timestamp)) "
            text += s.sentence
        }*/
    }
    
    func deleteTranscription() {
        if let fn = audioURL?.deletingPathExtension().lastPathComponent {
            reset()
            do {
                try FileManager.default.removeItem(atPath: fn + ".json")
            } catch {
                print("Error deleting \(fn)")
            }
        }
    }
    
    func load(_ string:String) -> Transcriber {
        if let path = Bundle.main.path(forResource: string, ofType: "json") {
            if let data = FileManager.default.contents(atPath: path) {
                do {
                    let array = try JSONDecoder().decode([Sentence].self, from: data)
                    allSentences = array
                    sentences = allSentences
                } catch {
                    print("Failed to load array from disk: \(error)")
                }
            }
        }
        return self
    }
    
    func transcribe(_ url:URL) {
        if let currentTask = currentTask {
            currentTask.cancel()
        }
        
        audioURL = url
        if resumePosition == 0 {
            allSentences.removeAll()
            sentences.removeAll()
        }
            
        transcribeAudioFileWithTimestamps(at: url) { [self] timestamps, error in
            if let timestamps = timestamps {
                Task { @MainActor in
                    var currentSentence = ""
                    var sentenceTimestamp: TimeInterval = timestamps[0].1
                    
                    for (word, timestamp) in timestamps {
                        currentSentence += " " + word
                        
                        if word.contains(".") || word.contains("?") || word.contains("!") {
                            let new = Sentence(id:allSentences.count,sentence:currentSentence.trimmingCharacters(in: .whitespaces), timestamp:sentenceTimestamp)
                            allSentences.append(new)
                            sentences.append(new)
                            sentenceTimestamp = timestamp
                            currentSentence = ""
                        }
                    }
                    
                    if currentSentence.count > 0 {
                        let new = Sentence(id:allSentences.count,sentence:currentSentence.trimmingCharacters(in: .whitespaces), timestamp:sentenceTimestamp)
                        allSentences.append(new)
                        sentences.append(new)
                    }
                    
                    
                    //print("Sentences: \(sentences.count)")
                    
                    //status = status
                    //text += "\n\(prettyPrintSeconds(sentenceTimestamp)) "
                    //text += currentSentence
                }
            } else if let error = error {
                print("Error: \(error.localizedDescription)")
            }
        }
    }
    
    func prettyPrintSeconds(_ seconds:Double) -> String {
        let hours:Int = Int(seconds) / 3600
        let minutes:Int = (Int(seconds) - (hours * 3600)) / 60
        let sec:Int = (Int(seconds) - (hours * 3600) - (minutes * 60))
        var ret = hours > 0 ? String(format:"%02d:", hours) : ""
        
        if seconds == TimeInterval.infinity {
            ret = ""
        } else {
            ret.append(String(format:"%02d:%02d", minutes, sec))
        }
        return ret
    }
}

struct Player_TranscriberPreview: PreviewProvider {
    static let p = PodcastPlayer.shared
    static var previews: some View {
        ScrollView {
            TranscriptView(transcriber:Transcriber.shared.load("sampletranscript"))
                .environmentObject(p)
        }
    }
}

