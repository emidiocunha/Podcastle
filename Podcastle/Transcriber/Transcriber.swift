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
import UIKit
import NaturalLanguage
import FoundationModels
import UserNotifications

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
    // Whole-episode summary, generated once a transcript finishes completely and
    // stored in its own file alongside the transcript's .json.
    @Published var summary: String = ""
    var allSentences: [Sentence] = []
    private let lock:NSLock = NSLock()
    
    private var recognitionGroup:DispatchGroup? = nil
    private var audioURL:URL? = nil
    private var currentTask:SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var currentTimeOffset:TimeInterval = 0
    // Detected from the episode's title/description in load(); also picks the summary voice.
    private(set) var language = "en_US"
    private var handler:(([(String, TimeInterval)]?, Error?) -> Void)? = nil
    private var resumePosition:Int64 = 0
    private var subscriptions:Subscriptions?
    // Identifies the episode in the "summary ready" notification.
    private var episodeTitle:String = ""
    private var episodeAudioURL:String = ""
    // Lets cancel() actually stop the in-flight transcription.
    private var currentTranscriptionTask:Task<Void, Never>?
    // Where and when this run last checkpointed `allSentences` to disk.
    private var checkpointFilename:String?
    private var lastCheckpointAt:Date = .distantPast
    private let checkpointInterval:TimeInterval = 5.0
    // Whether this run transcribed the whole file (not cancelled or failed). Decides
    // whether to summarize.
    private var lastRunReachedEndOfAudio = false
    // Bumped for every new run. Recognition callbacks from an older run can still fire
    // after cancellation, so they check this before touching shared state.
    private var transcriptionGeneration = 0
    
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
        // Trim whitespace/newlines and handle trivial cases fast on the main thread
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            sentences = allSentences
            return
        }
        if query.count <= 2 {
            // Ignore very short queries to avoid unnecessary churn
            sentences = allSentences
            return
        }

        let source = allSentences

        DispatchQueue.global(qos: .userInitiated).async {
            let lower = query.lowercased()
            let result = source.filter { $0.sentence.lowercased().contains(lower) }

            DispatchQueue.main.async {
                self.sentences = result
            }
        }
    }
    
    func copyText() -> String {
        var text = ""
        sentences.forEach { sentence in
            text += "\n\(sentence.timestamp.prettyPrintSeconds()) "
            text += sentence.sentence
        }
        return text
    }

    // Saves the transcript so far to disk, throttled so long runs don't rewrite it constantly.
    private func saveCheckpoint() {
        guard let checkpointFilename else { return }
        let now = Date()
        guard now.timeIntervalSince(lastCheckpointAt) >= checkpointInterval else { return }
        lastCheckpointAt = now
        subscriptions?.saveArrayToDisk(array: allSentences, filePath: checkpointFilename)
    }

    // Shared by TranscriberView and background transcription so both pick the same locale.
    static func detectLanguage(title: String, desc: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(title + "\n\n" + desc)
        return recognizer.dominantLanguage?.rawValue ?? "en_US"
    }

    private func summaryFilename(for base: String) -> String {
        base + "-summary.txt"
    }

    private func languageName(for code: String) -> String {
        let bare = code.split(separator: "_").first.map(String.init) ?? code
        return Locale(identifier: "en_US").localizedString(forLanguageCode: bare) ?? bare
    }

    // Retries the summary for an already complete transcript without redoing it.
    // Bypasses load() so its own summary backfill doesn't run as well.
    func summarizeExistingTranscript(_ url: URL, title: String, desc: String, episodeAudioURL: String) async {
        guard let fn = url.deletingPathExtension().lastPathComponent as String? else { return }
        let loaded: [Sentence] = subscriptions?.loadArrayFromDisk(filePath: fn + ".json") ?? []
        guard !loaded.isEmpty else { return }
        audioURL = url
        episodeTitle = title
        self.episodeAudioURL = episodeAudioURL
        // load() isn't called on this path, so detect the language here too.
        language = Transcriber.detectLanguage(title: title, desc: desc)
        await summarizeIfNeeded(fn: fn, sentences: loaded)
    }

    // Summarizes once a transcript is complete. Skipped if a summary is already on disk.
    private func summarizeIfNeeded(fn: String, sentences: [Sentence]) async {
        let filename = summaryFilename(for: fn)
        guard subscriptions?.loadTextFromDisk(filePath: filename) == nil else { return }
        guard #available(iOS 26.0, *) else {
            print("Skipping summary: on-device summarization needs iOS 26 or later.")
            return
        }
        // Claims the episode so two Transcriber instances can't summarize it at once.
        guard let subscriptions, await subscriptions.beginSummarizing(filename) else { return }
        defer { Task { await subscriptions.endSummarizing(filename) } }

        // Captured up front: load()/reset() may switch this instance to another episode meanwhile.
        let capturedAudioURL = audioURL
        let capturedEpisodeTitle = episodeTitle
        let capturedEpisodeAudioURL = episodeAudioURL
        func stillCurrent() -> Bool { audioURL == capturedAudioURL }

        await setStatus("Summarizing")
        if let generated = await summarizeTranscript(sentences) {
            subscriptions.saveTextToDisk(generated, filePath: filename)
            await MainActor.run { updateSiriIndex() }
            if stillCurrent() {
                await MainActor.run { self.summary = generated }
                await notifySummaryReady(identifier: fn, summaryText: generated, episodeTitle: capturedEpisodeTitle, episodeAudioURL: capturedEpisodeAudioURL)
            }
        } else {
            print("Summary generation produced no result for \(fn) — check Apple Intelligence availability in Settings.")
        }
        // load()'s backfill has no wrapper that clears status, so clear it here, unless
        // another episode has taken over this instance.
        if stillCurrent() {
            await setStatus("")
        }
    }

    // Lets the user know a summary is ready without them having to keep checking —
    // only worth a notification if they're not already looking at the app.
    private func notifySummaryReady(identifier: String, summaryText: String, episodeTitle: String, episodeAudioURL: String) async {
        let isActive = await MainActor.run { UIApplication.shared.applicationState == .active }
        guard !isActive else { return }

        let content = UNMutableNotificationContent()
        content.title = episodeTitle.isEmpty ? "Summary Ready" : "\(episodeTitle) — Summary Ready"
        content.body = Self.teaser(from: summaryText)
        content.sound = .default
        content.userInfo = ["episodeAudioURL": episodeAudioURL]

        // Reuses the episode's own filename as the identifier so a re-generated
        // summary replaces its own earlier notification instead of piling up.
        let request = UNNotificationRequest(identifier: "summary-\(identifier)", content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            print("Failed to schedule summary notification: \(error.localizedDescription)")
        }
    }

    // A short teaser of the actual summary for the notification body, cut at a
    // word boundary rather than mid-word.
    private static func teaser(from text: String, maxLength: Int = 140) -> String {
        guard text.count > maxLength else { return text }
        let truncated = text.prefix(maxLength)
        let cut = truncated.lastIndex(of: " ").map { truncated[..<$0] } ?? truncated
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }

    // Summarizes on-device with FoundationModels. Long transcripts that overflow the
    // context window are summarized in chunks, then the chunk summaries are combined.
    @available(iOS 26.0, *)
    private func summarizeTranscript(_ sentences: [Sentence]) async -> String? {
        guard SystemLanguageModel.default.availability == .available else {
            print("Skipping summary: SystemLanguageModel unavailable (\(SystemLanguageModel.default.availability))")
            return nil
        }
        let fullText = sentences.map(\.sentence).joined(separator: " ")
        guard !fullText.isEmpty else { return nil }

        // Name the language explicitly so the summary matches the voice that reads it.
        let instructions = "You write concise summaries of podcast episodes from their transcripts. In 3 to 5 sentences, describe what the episode is about and its key points, written as flowing prose in \(languageName(for: language)). Do not mention that you are an AI, the transcript, or the summarization process."

        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: "Summarize this podcast transcript:\n\n\(fullText)")
            return response.content
        } catch {
            return await summarizeInChunks(sentences, instructions: instructions)
        }
    }

    @available(iOS 26.0, *)
    private func summarizeInChunks(_ sentences: [Sentence], instructions: String) async -> String? {
        let chunkInstructions = "You write concise notes on one excerpt of a podcast transcript, in 2 to 3 sentences, for later use in a combined episode summary, written in \(languageName(for: language)). Do not mention that you are an AI, the transcript, or the summarization process."
        let chunks = chunkedText(sentences)
        guard !chunks.isEmpty else { return nil }

        var partials: [String] = []
        for chunk in chunks {
            do {
                let session = LanguageModelSession(instructions: chunkInstructions)
                let response = try await session.respond(to: "Summarize this excerpt from a podcast transcript:\n\n\(chunk)")
                partials.append(response.content)
            } catch {
                print("Chunk summarization failed: \(error.localizedDescription)")
            }
        }
        guard !partials.isEmpty else { return nil }

        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: "Combine these section notes from one podcast episode into a single cohesive 3 to 5 sentence summary:\n\n\(partials.joined(separator: "\n\n"))")
            return response.content
        } catch {
            print("Final summarization pass failed: \(error.localizedDescription)")
            // Better than nothing: stitch the partial notes together as-is.
            return partials.joined(separator: " ")
        }
    }

    // Splits the transcript into pieces small enough for the on-device model's
    // context window, joining whole sentences so none is ever cut mid-thought.
    private func chunkedText(_ sentences: [Sentence], maxChars: Int = 3000) -> [String] {
        var chunks: [String] = []
        var current = ""
        for s in sentences {
            if !current.isEmpty && current.count + s.sentence.count + 1 > maxChars {
                chunks.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : " ") + s.sentence
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
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
    
    func checkResumable(_ audioFileURL:URL, definitelyComplete: Bool = false) {
        guard !definitelyComplete else {
            resumePosition = 0
            return
        }
        if let audioFile = loadAudioFile(fromURL: audioFileURL) {
            let sampleRate = Double(audioFile.processingFormat.sampleRate)
            let sizeInSeconds = AudioDuration.estimate(audioFileURL)
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
        var completedFully = false
        do {
            let audioFile = try AVAudioFile(forReading: audioFileURL)
            let audioFormat = audioFile.processingFormat
            let frameCount = audioFile.length
            let sampleRate = Double(audioFormat.sampleRate)
            let bufferSizeInSeconds = 120.0
            let bufferSizeInFrames = AVAudioFrameCount(bufferSizeInSeconds * sampleRate)
            let bufferSize: AVAudioFrameCount = bufferSizeInFrames
            var frameOffset: AVAudioFramePosition = resumePosition
            
            currentTimeOffset = resumePosition == 0 ? 0 : TimeInterval(resumePosition / Int64(sampleRate))
            
            await setStatus("Transcribing")
            while frameOffset < frameCount && !Task.isCancelled {
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
            completedFully = frameOffset >= frameCount
        } catch {
            print("Error loading audio file: \(error.localizedDescription)")
        }
        lastRunReachedEndOfAudio = completedFully
        checkResumable(audioFileURL, definitelyComplete: completedFully)
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

        // Callbacks from a cancelled run can still fire; checked below.
        let generation = transcriptionGeneration
        do {
            _ = try await withCheckedThrowingContinuation { continuation in
                currentTask = speechRecognizer.recognitionTask(with: recognitionRequest) { result, error in
                    if let result = result, result.isFinal {
                        let transcription = result.bestTranscription

                        var timestamps: [(String, TimeInterval)] = []

                        for segment in transcription.segments {
                            let word = segment.substring
                            let timestamp = self.currentTimeOffset + segment.timestamp
                            if word.count > 0 {
                                timestamps.append((word, timestamp))
                            }
                        }
                        if timestamps.count > 0, generation == self.transcriptionGeneration {
                            Task {
                                if generation == self.transcriptionGeneration {
                                    await self.updateTimestamps(timestamps)
                                    self.saveCheckpoint()
                                }
                                continuation.resume(returning: result.bestTranscription.formattedString)
                            }
                        } else {
                            continuation.resume(returning: result.bestTranscription.formattedString)
                        }
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
    
    // Builds the sentences locally and publishes once, avoiding a re-render per sentence.
    @MainActor func updateTimestamps(_ timestamps:[(String, TimeInterval)]) {
        var currentSentence = ""
        var sentenceTimestamp: TimeInterval = timestamps[0].1
        var nextID = allSentences.count
        var newSentences: [Sentence] = []

        for (word, timestamp) in timestamps {
            currentSentence += " " + word

            if word.contains(".") || word.contains("?") || word.contains("!") {
                let new = Sentence(id:nextID,sentence:currentSentence.trimmingCharacters(in: .whitespaces), timestamp:sentenceTimestamp)
                newSentences.append(new)
                nextID += 1
                sentenceTimestamp = timestamp
                currentSentence = ""
            }
        }

        if currentSentence.count > 0 {
            let new = Sentence(id:nextID,sentence:currentSentence.trimmingCharacters(in: .whitespaces), timestamp:sentenceTimestamp)
            newSentences.append(new)
        }

        guard !newSentences.isEmpty else { return }
        allSentences.append(contentsOf: newSentences)
        sentences.append(contentsOf: newSentences)
    }

    func transcribeAudioFileWithTimestamps(at url: URL) async {
        let fn = audioURL?.deletingPathExtension().lastPathComponent
        checkpointFilename = fn.map { $0 + ".json" }
        lastCheckpointAt = .distantPast
        await setStatus("Starting...")
        if #available(iOS 26.0, *) {
            await transcribeWithSpeechAnalyzer(at: url)
        } else {
            await recognizeSpeech(url)
        }
        if let fn = fn {
            subscriptions?.saveArrayToDisk(array: allSentences, filePath: fn + ".json")
            // Records that this transcript really is finished, so background
            // transcription stops re-selecting it (see Subscriptions.isTranscriptMarkedComplete).
            if lastRunReachedEndOfAudio {
                subscriptions?.setTranscriptComplete(fn, true)
            }
        }
        checkpointFilename = nil
        // Only a run that reached the end of the file gets a summary.
        if lastRunReachedEndOfAudio, !allSentences.isEmpty, let fn {
            await summarizeIfNeeded(fn: fn, sentences: allSentences)
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
        var completedFully = false
        do {
            let audioFile = try AVAudioFile(forReading: at)
            let sampleRate = audioFile.processingFormat.sampleRate
            audioFile.framePosition = resumePosition
            currentTimeOffset = resumePosition == 0 ? 0 : TimeInterval(resumePosition) / sampleRate

            var locale = Locale(identifier: "\(language)_\(Locale.current.language.region!.identifier)")
            
            if await !supported(locale: locale) {
               locale = await firstSupportedLocaleMatchingLanguage(language)
            }
            
            let transcriber = transcriber(for: locale)

            try await ensureModel(transcriber: transcriber, locale: locale)
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: audioFile.processingFormat)
            let input = AudioFileInput(file: audioFile, format: format)

            await setStatus("Transcribing")

            let offset = currentTimeOffset
            let results = Task {
                for try await result in transcriber.results where result.isFinal {
                    if let t = result.text.runs.first?.audioTimeRange {
                        await self.updateTimestamps([(String(result.text.characters), offset + t.start.seconds)])
                        self.saveCheckpoint()
                    }
                }
            }
            let lastSample = try await withTaskCancellationHandler {
                try await analyzer.analyzeSequence(input)
            } onCancel: {
                input.stop()
            }
            if !Task.isCancelled, let lastSample {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            try await results.value
            completedFully = !Task.isCancelled
        }
        catch {
            await setStatus("Could not transcribe \(error.localizedDescription)")
        }
        // Whether this run stopped early, so the next one resumes from resumePosition.
        lastRunReachedEndOfAudio = completedFully
        checkResumable(at, definitelyComplete: completedFully)
    }
    
    func cancel() {
        currentTask?.cancel()
        currentTranscriptionTask?.cancel()
        // TranscriberView checks `working` right after this returns, so set it synchronously
        // on the main thread. The background task's expirationHandler can call from any thread.
        if Thread.isMainThread {
            working = false
        } else {
            Task { @MainActor in
                self.working = false
            }
        }
    }
    
    func reset() {
        cancel()
        sentences.removeAll()
        allSentences.removeAll()
        summary = ""
        text = ""
        resumePosition = 0
    }
    
    func deleteTranscription() {
        if let fn = audioURL?.deletingPathExtension().lastPathComponent {
            if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                let fullPath = documents.appendingPathComponent(fn + ".json", isDirectory: false)
                let summaryPath = documents.appendingPathComponent(summaryFilename(for: fn), isDirectory: false)
                
                reset()
                subscriptions?.setTranscriptComplete(fn, false)
                do {
                    try FileManager.default.removeItem(at: fullPath)
                } catch {
                    print("Error deleting \(fn)")
                }
                try? FileManager.default.removeItem(at: summaryPath)
            }
        }
    }
    
    func load(_ url:URL?, title: String = "", desc: String = "", episodeAudioURL: String = "") -> Transcriber {
        audioURL = url
        episodeTitle = title
        self.episodeAudioURL = episodeAudioURL
        if !title.isEmpty || !desc.isEmpty {
            language = Transcriber.detectLanguage(title: title, desc: desc)
        }
        summary = ""
        if let fn = url?.deletingPathExtension().lastPathComponent {
            let array:[Sentence] = subscriptions?.loadArrayFromDisk(filePath: fn + ".json") ?? []
            allSentences = array
            sentences = allSentences
            summary = subscriptions?.loadTextFromDisk(filePath: summaryFilename(for: fn)) ?? ""

            // Backfill a summary for a complete transcript that doesn't have one yet.
            if summary.isEmpty, !array.isEmpty, let url, looksComplete(url, sentences: array) {
                Task { await self.summarizeIfNeeded(fn: fn, sentences: array) }
            }
        }
        return self
    }

    // Whether an on-disk transcript looks finished, for load()'s summary backfill.
    // Unlike checkResumable, it doesn't change any state.
    private func looksComplete(_ audioFileURL: URL, sentences: [Sentence]) -> Bool {
        if subscriptions?.isTranscriptMarkedComplete(audioFileURL.deletingPathExtension().lastPathComponent) == true {
            return true
        }
        guard let lastTimestamp = sentences.last?.timestamp else { return false }
        let sizeInSeconds = AudioDuration.estimate(audioFileURL)
        guard sizeInSeconds > 0 else { return false }
        return lastTimestamp >= sizeInSeconds - 120
    }
    
    func transcribe(_ url:URL) async {
        if let currentTask = currentTask {
            currentTask.cancel()
        }
        currentTranscriptionTask?.cancel()
        transcriptionGeneration += 1

        audioURL = url
        // Check for a checkpoint to resume before wiping. Transcripts marked complete are
        // redone from the start.
        let fn = url.deletingPathExtension().lastPathComponent
        checkResumable(url, definitelyComplete: subscriptions?.isTranscriptMarkedComplete(fn) == true)
        if resumePosition == 0 {
            // Backfill a missing summary from the existing transcript before it's wiped.
            if !allSentences.isEmpty {
                await summarizeIfNeeded(fn: fn, sentences: allSentences)
            }
            // Starting over — until this run reaches the end, it isn't complete.
            subscriptions?.setTranscriptComplete(fn, false)
            let task = Task { @MainActor in
                allSentences.removeAll()
                sentences.removeAll()
            }
            await task.value
        }

        let runTask = Task {
            await transcribeAudioFileWithTimestamps(at: url)
        }
        currentTranscriptionTask = runTask
        await runTask.value
    }
}

// Feeds an audio file to SpeechAnalyzer a chunk at a time, read on demand. Unlike
// start(inputAudioFile:), it treats a read error at the end as the end of the file:
// MP3 lengths are estimates, and AVAudioFile throws eofErr when the estimate is
// slightly long. SpeechAnalyzer then dropped everything it had read but not yet
// transcribed, so the episode could never finish.
@available(iOS 26.0, *)
final class AudioFileInput: AsyncSequence, @unchecked Sendable {
    typealias Element = AnalyzerInput

    private let file: AVAudioFile
    private let converter: AVAudioConverter?
    private let outputFormat: AVAudioFormat
    private let chunkFrames: AVAudioFrameCount
    private let lock = NSLock()
    private var stopped = false

    init(file: AVAudioFile, format: AVAudioFormat?, chunkSeconds: Double = 10) {
        self.file = file
        outputFormat = format ?? file.processingFormat
        converter = outputFormat == file.processingFormat ? nil : AVAudioConverter(from: file.processingFormat, to: outputFormat)
        chunkFrames = AVAudioFrameCount(chunkSeconds * file.processingFormat.sampleRate)
    }

    // Ends the input early, e.g. when the transcription is cancelled.
    func stop() {
        lock.withLock { stopped = true }
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        let input: AudioFileInput
        mutating func next() async -> AnalyzerInput? {
            input.nextChunk().map { AnalyzerInput(buffer: $0) }
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(input: self)
    }

    private func nextChunk() -> AVAudioPCMBuffer? {
        guard !lock.withLock({ stopped }),
              let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames) else { return nil }
        do {
            try file.read(into: source)
        } catch {
            return nil
        }
        guard source.frameLength > 0 else { return nil }
        guard let converter else { return source }

        let ratio = outputFormat.sampleRate / file.processingFormat.sampleRate
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(Double(source.frameLength) * ratio) + 1024) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return source
        }
        return error == nil ? output : nil
    }
}
