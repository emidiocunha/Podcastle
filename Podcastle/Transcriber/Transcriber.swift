//
//  Transcriber.swift
//  Podcastle
//
//  Created by Emídio Cunha on 27/07/2023.
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
import Speech
import AVFoundation
import SwiftUI
import NaturalLanguage

struct Sentence:Codable, Identifiable {
    let id:Int
    let sentence:String
    let timestamp:TimeInterval
}

final class  Transcriber:NSObject, ObservableObject, SFSpeechRecognitionTaskDelegate {
    @Published var text:String = ""
    @Published var working = false
    @Published var sentences: [Sentence] = []
    @Published var status = ""
    var allSentences: [Sentence] = []
    private let lock:NSLock = NSLock()
    
    private var recognitionGroup:DispatchGroup? = nil
    private var audioURL:URL? = nil
    private var currentTask:SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var currentTimeOffset:TimeInterval = 0
    private var language = "en_US"
    private var handler:(([(String, TimeInterval)]?, Error?) -> Void)? = nil
    private var resumePosition:Int64 = 0
    private var subscriptions:Subscriptions?
    
    func setup(subscriptions:Subscriptions) {
        self.subscriptions = subscriptions
    }
    
    func setStatus(_ status:String) async {
        let task = Task { @MainActor in
            self.status = status
            self.working = status == "" ? false : true
        }
        await task.value
    }
    
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
        lock.lock()
        if text.count == 0 {
            sentences = allSentences
            return
        } else if text.count > 2 {
            //Task.init(priority: .userInitiated) {
                let s = text.lowercased()
                let result = allSentences.filter { value in
                    value.sentence.lowercased().contains(s)
                }
                //Task { @MainActor in
                sentences = result
                //}
            //}
        }
        lock.unlock()
    }
    
    func copyText() -> String {
        var text = ""
        sentences.forEach { sentence in
            text += "\n\(sentence.timestamp.prettyPrintSeconds()) "
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

    func recognizeSpeech(_ audioFileURL:URL) async {
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
            
            await setStatus("Transcribing")
            while frameOffset < frameCount {
                // Create an AVAudioPCMBuffer to hold the audio data
                guard let audioBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: bufferSize * 2) else {
                    print("Failed to create audio buffer.")
                    return
                }
                audioFile.framePosition = frameOffset
                try audioFile.read(into: audioBuffer, frameCount: bufferSize)
                frameOffset += Int64(audioBuffer.frameLength)
                
                if await recognizeSpeechBuffer(audioBuffer) == false {
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
    
    func recognizeSpeechBuffer(_ audioBuffer:AVAudioPCMBuffer) async -> Bool {
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
                
        do {
            _ = try await withCheckedThrowingContinuation { continuation in
                speechRecognizer.recognitionTask(with: recognitionRequest) { result, error in
                    if let result = result, result.isFinal {
                        // Get the transcribed text from the result
                        let transcription = result.bestTranscription
                        
                        // Get the word-level timing information
                        var timestamps: [(String, TimeInterval)] = []
                        
                        for segment in transcription.segments {
                            let word = segment.substring
                            let timestamp = self.currentTimeOffset + segment.timestamp
                            if word.count > 0 {
                                timestamps.append((word, timestamp))
                            }
                        }
                        if timestamps.count > 0 {
                            Task {
                                await self.updateTimestamps(timestamps)
                            }
                        }
                        continuation.resume(returning: result.bestTranscription.formattedString)
                    } else if let error = error {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch {
        }
        
        currentTask = nil
        
        currentTimeOffset += getPCMBufferLength(buffer: audioBuffer)
        return true
    }
    
    @MainActor func updateTimestamps(_ timestamps:[(String, TimeInterval)]) {
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
    }

    func transcribeAudioFileWithTimestamps(at url: URL) async { //}, completion: @escaping ([(String, TimeInterval)]?,
        let fn = audioURL?.deletingPathExtension().lastPathComponent
        
        await setStatus("Starting...")
        await recognizeSpeech(url)

        if let fn = fn {
            subscriptions?.saveArrayToDisk(array: allSentences, filePath: fn + ".json")
        }
        
        await setStatus("")
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
    
/*    func load(_ podcast:Podcast) {
        if let url = URL(string:podcast.localAudioUrl) {
            let fn = url.deletingPathExtension().lastPathComponent
            
            allSentences = subscriptions?.loadArrayFromDisk(filePath: fn + ".json") ?? []
            
            if let fullURL = podcast.fullLocalUrl(.audio) {
                checkResumable(fullURL)
                audioURL = fullURL
            }
            
            sentences = allSentences
        }
    }
 */
    
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
    
    func transcribe(_ url:URL) async {
        if let currentTask = currentTask {
            currentTask.cancel()
        }
        
        audioURL = url
        if resumePosition == 0 {
            let task = Task { @MainActor in
                allSentences.removeAll()
                sentences.removeAll()
            }
            await task.value
        }
            
        await transcribeAudioFileWithTimestamps(at: url)
    }
}

