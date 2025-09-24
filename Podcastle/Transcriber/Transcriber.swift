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

final class Transcriber:NSObject, ObservableObject, SFSpeechRecognitionTaskDelegate {
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

    func transcribeAudioFileWithTimestamps(at url: URL) async {
        let fn = audioURL?.deletingPathExtension().lastPathComponent
        await setStatus("Starting...")
        if #available(iOS 26.0, *) {
            await transcribeWithSpeechAnalyzer(at: url)
        } else {
            await recognizeSpeech(url)
        }
        if let fn = fn {
            subscriptions?.saveArrayToDisk(array: allSentences, filePath: fn + ".json")
        }
        await setStatus("")
    }
    
    @available(iOS 26.0, *)
    public func ensureModel(transcriber: SpeechTranscriber, locale: Locale) async throws {
        guard await supported(locale: locale) else {
            throw NSError(domain: "SpeechAnalyzerExample", code: 1, userInfo: [NSLocalizedDescriptionKey: "Locale not supported"])
        }
        
        if await installed(locale: locale) {
            return
        } else {
            try await downloadIfNeeded(for: transcriber)
        }
    }
    
    @available(iOS 26.0, *)
    func supported(locale: Locale) async -> Bool {
        let supported = await SpeechTranscriber.supportedLocales
        return supported.map { $0.identifier(.bcp47) }.contains(locale.identifier(.bcp47))
    }

    @available(iOS 26.0, *)
    func installed(locale: Locale) async -> Bool {
        let installed = await Set(SpeechTranscriber.installedLocales)
        return installed.map { $0.identifier(.bcp47) }.contains(locale.identifier(.bcp47))
    }

    @available(iOS 26.0, *)
    func downloadIfNeeded(for module: SpeechTranscriber) async throws {
        if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await downloader.downloadAndInstall()
        }
    }
    
    @available(iOS 26.0, *)
    func transcriber(for locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
    }
    
    @available(iOS 26.0, *)
    private func firstSupportedLocaleMatchingLanguage(_ language: String) async -> Locale {
        // Build a Locale from the provided language string (e.g., "en", "pt", "zh-Hant")
        let target = Locale(identifier: language)

        // Extract a language code robustly across SDK evolutions
        // Prefer modern API; fall back to deprecated `languageCode` if needed.
        let targetCode = target.language.languageCode?.identifier
        ?? target.language.languageCode?.identifier  // deprecated but useful on older bases
            ?? language.lowercased()

        // Look through the SpeechTranscriber-supported locales
        let supported = await SpeechTranscriber.supportedLocales
        for loc in supported {
            let code = loc.language.languageCode?.identifier
            if code?.lowercased() == targetCode.lowercased() {
                return loc
            }
        }
        return Locale(identifier: "en-US")
    }
    
    @available(iOS 26.0, *)
    func transcribeWithSpeechAnalyzer(at:URL) async {
        do {
            let audioFile = try AVAudioFile(forReading: at)
        
            //Setting locale
            var locale = Locale(identifier: "\(language)_\(Locale.current.language.region!.identifier)")
            
            // Fallback
            if await !supported(locale: locale) {
               locale = await firstSupportedLocaleMatchingLanguage(language)
            }
            
            //Creating Transcriber Module
            let transcriber = transcriber(for: locale)

            //Checking Assets
            try await ensureModel(transcriber: transcriber, locale: locale)
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            
            try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)

            await setStatus("Transcribing")

            for try await result in transcriber.results {
                if !working {
                    // Cancel
                    await analyzer.cancelAndFinishNow()
                    return
                }
                if result.isFinal {
                    let bestTranscription = result.text // an AttributedString
                    let plainTextBestTranscription = String(bestTranscription.characters) // a String
                    
                    // Get the word-level timing information
                    var timestamps: [(String, TimeInterval)] = []
                    
                    if let t = result.text.runs.first?.audioTimeRange {
                        let timestamp = self.currentTimeOffset + t.start.seconds
                        timestamps.append((plainTextBestTranscription, timestamp))
                        
                        Task {
                            await self.updateTimestamps(timestamps)
                        }
                    }
                }
            }
        }
        catch {
            await setStatus("Could not transcribe \(error.localizedDescription)")
        }
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
    
    func deleteTranscription() {
        if let fn = audioURL?.deletingPathExtension().lastPathComponent {
            if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                let fullPath = documents.appendingPathComponent(fn + ".json", isDirectory: false)
                
                reset()
                do {
                    try FileManager.default.removeItem(at: fullPath)
                } catch {
                    print("Error deleting \(fn)")
                }
            }
        }
    }
    
    func load(_ url:URL?) -> Transcriber {
        audioURL = url
        if let fn = url?.deletingPathExtension().lastPathComponent {
            let array:[Sentence] = subscriptions?.loadArrayFromDisk(filePath: fn + ".json") ?? []
            allSentences = array
            sentences = allSentences
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
