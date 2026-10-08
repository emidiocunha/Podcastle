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
    // Set from the episode's title/description whenever load() runs, so it's
    // always correct for whatever's currently loaded — including a transcript or
    // summary produced earlier by the background task, which load() itself never
    // ran detection for. Exposed read-only so the summary's "Play" button can pick
    // a matching voice.
    private(set) var language = "en_US"
    private var handler:(([(String, TimeInterval)]?, Error?) -> Void)? = nil
    private var resumePosition:Int64 = 0
    private var subscriptions:Subscriptions?
    // Set by load(_:title:episodeAudioURL:) — used only to identify the episode in
    // the "summary ready" notification (episodeAudioURL is Episode.audio, the
    // stable ID Subscriptions.findEpisode(_:) looks episodes up by).
    private var episodeTitle:String = ""
    private var episodeAudioURL:String = ""
    // Owns the in-flight transcription so `cancel()` can actually stop it — the
    // SpeechAnalyzer path polls this via `Task.isCancelled` instead of racing on
    // the @Published `working` flag from whatever thread called cancel().
    private var currentTranscriptionTask:Task<Void, Never>?
    // Filename this run checkpoints `allSentences` to, and when we last did so.
    // Previously the transcript was only written to disk once, at the very end —
    // an app suspension, crash, or background-task expiration mid-run lost
    // everything transcribed so far.
    private var checkpointFilename:String?
    private var lastCheckpointAt:Date = .distantPast
    private let checkpointInterval:TimeInterval = 5.0
    // Set at the tail of recognizeSpeech/transcribeWithSpeechAnalyzer to whether
    // *this run* actually made it through the whole file, as opposed to being cut
    // short by cancellation or an error. transcribeAudioFileWithTimestamps uses
    // this — not resumePosition — to decide whether to summarize (see checkResumable
    // for why resumePosition alone is the wrong signal for that).
    private var lastRunReachedEndOfAudio = false
    // Bumped every time transcribe() starts a new run. recognizeSpeechBuffer's
    // completion handler captures the generation current when it starts and
    // checks it again before mutating allSentences/sentences — cancelling
    // currentTask/currentTranscriptionTask doesn't guarantee an already in-flight
    // SFSpeechRecognitionTask's completion handler won't still fire afterward,
    // and if it did and nothing else were checked, it would append stale
    // sentences and a stale checkpoint into whatever a newer run (a quick
    // Stop-then-Start, or background transcription racing a foreground one) had
    // already reset.
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

        // Capture snapshot to avoid concurrent mutation concerns
        let source = allSentences

        // Do the potentially expensive filtering off the main thread
        DispatchQueue.global(qos: .userInitiated).async {
            let lower = query.lowercased()
            let result = source.filter { $0.sentence.lowercased().contains(lower) }

            // Publish results back on the main thread
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

    // Flushes the transcript built so far to disk, throttled so a long run doesn't
    // rewrite the whole (growing) array on every recognition result. Called from
    // both recognition paths after each chunk of new sentences lands.
    private func saveCheckpoint() {
        guard let checkpointFilename else { return }
        let now = Date()
        guard now.timeIntervalSince(lastCheckpointAt) >= checkpointInterval else { return }
        lastCheckpointAt = now
        subscriptions?.saveArrayToDisk(array: allSentences, filePath: checkpointFilename)
    }

    // Best-effort language detection from an episode's title/description, shared by
    // the interactive transcribe flow (TranscriberView) and background transcription
    // so both pick the same locale.
    static func detectLanguage(title: String, desc: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(title + "\n\n" + desc)
        return recognizer.dominantLanguage?.rawValue ?? "en_US"
    }

    private func summaryFilename(for base: String) -> String {
        base + "-summary.txt"
    }

    // `language` is a bare or region-qualified code like "pt" or "en_US" — turn it
    // into a name the model can follow unambiguously regardless of what language
    // the transcript text itself happens to be in.
    private func languageName(for code: String) -> String {
        let bare = code.split(separator: "_").first.map(String.init) ?? code
        return Locale(identifier: "en_US").localizedString(forLanguageCode: bare) ?? bare
    }

    // Retries the summary for a transcript that's already complete, without
    // touching the transcript itself — used by background transcription to retry
    // a summary that couldn't be generated last time (e.g. SystemLanguageModel was
    // still downloading/preparing) without redoing potentially hours of already-
    // finished transcription. Sets episode identity directly rather than going
    // through load(), so it doesn't also trigger load()'s own backfill Task and
    // end up running the summarization twice.
    func summarizeExistingTranscript(_ url: URL, title: String, desc: String, episodeAudioURL: String) async {
        guard let fn = url.deletingPathExtension().lastPathComponent as String? else { return }
        let loaded: [Sentence] = subscriptions?.loadArrayFromDisk(filePath: fn + ".json") ?? []
        guard !loaded.isEmpty else { return }
        audioURL = url
        episodeTitle = title
        self.episodeAudioURL = episodeAudioURL
        // This path bypasses load() (deliberately, see above), which is where
        // language detection normally happens — without this, the background
        // task's fresh Transcriber() instance would default to "en_US" and both
        // the summarization language and the TTS voice match would be wrong for
        // a non-English episode.
        language = Transcriber.detectLanguage(title: title, desc: desc)
        await summarizeIfNeeded(fn: fn, sentences: loaded)
    }

    // Generates the whole-episode summary once, after a transcript finishes
    // completely — never from a run that stopped partway through. Skips work if a
    // summary is already on disk for this episode (deleteTranscription clears it,
    // which is what forces a fresh one next time).
    private func summarizeIfNeeded(fn: String, sentences: [Sentence]) async {
        let filename = summaryFilename(for: fn)
        guard subscriptions?.loadTextFromDisk(filePath: filename) == nil else { return }
        guard #available(iOS 26.0, *) else {
            print("Skipping summary: on-device summarization needs iOS 26 or later.")
            return
        }
        // Claims this episode atomically — the disk check above alone isn't
        // enough: two independent Transcriber instances (e.g. load()'s own
        // backfill here vs. the background task's throwaway instance, both
        // deciding at once that episode X needs a summary) could otherwise both
        // pass it before either has written anything, running the on-device LLM
        // twice and sending two "Summary Ready" notifications for the same
        // episode.
        guard let subscriptions, await subscriptions.beginSummarizing(filename) else { return }
        defer { Task { await subscriptions.endSummarizing(filename) } }

        // Captured now, not read lazily off `self` later — a later load()/reset()
        // switching this (shared, UI-facing) instance to a different episode
        // while this runs (easily multi-second) shouldn't end up writing that
        // *other* episode's live `summary`/status, or firing a notification
        // titled for it instead of the episode this summary is actually about.
        let capturedAudioURL = audioURL
        let capturedEpisodeTitle = episodeTitle
        let capturedEpisodeAudioURL = episodeAudioURL
        func stillCurrent() -> Bool { audioURL == capturedAudioURL }

        await setStatus("Summarizing")
        if let generated = await summarizeTranscript(sentences) {
            subscriptions.saveTextToDisk(generated, filePath: filename)
            if stillCurrent() {
                await MainActor.run { self.summary = generated }
                await notifySummaryReady(identifier: fn, summaryText: generated, episodeTitle: capturedEpisodeTitle, episodeAudioURL: capturedEpisodeAudioURL)
            }
        } else {
            print("Summary generation produced no result for \(fn) — check Apple Intelligence availability in Settings.")
        }
        // transcribeAudioFileWithTimestamps also clears status after calling this,
        // but load()'s backfill calls this standalone with no such wrapper — without
        // clearing it here too, "Summarizing" (and the working=true it implies)
        // would never go away for that path. Skipped if a newer episode has since
        // taken over this instance, so this doesn't clear *that* episode's own
        // legitimately-in-progress status.
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

    // Summarizes with Apple's on-device model (FoundationModels) — in keeping with
    // this app's privacy stance, no transcript text ever leaves the device. A full
    // podcast transcript can easily exceed the on-device model's context window, so
    // a single-pass failure falls back to summarizing in chunks and then summarizing
    // those summaries.
    @available(iOS 26.0, *)
    private func summarizeTranscript(_ sentences: [Sentence]) async -> String? {
        guard SystemLanguageModel.default.availability == .available else {
            print("Skipping summary: SystemLanguageModel unavailable (\(SystemLanguageModel.default.availability))")
            return nil
        }
        let fullText = sentences.map(\.sentence).joined(separator: " ")
        guard !fullText.isEmpty else { return nil }

        // Named explicitly rather than trusting the model to mirror the transcript's
        // language on its own — needed so the summary and the voice that later
        // reads it aloud (SummarySpeaker, matched to this same `language`) agree.
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
        var completedFully = false
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
            while frameOffset < frameCount && !Task.isCancelled {
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

        // Captured now — cancelling currentTask/currentTranscriptionTask doesn't
        // guarantee this buffer's completion handler won't still fire afterward
        // (e.g. a quick Stop-then-Start, or background transcription racing a
        // foreground one); checked again below before touching any shared state.
        let generation = transcriptionGeneration
        do {
            _ = try await withCheckedThrowingContinuation { continuation in
                // Assigning this is what actually lets cancel()'s
                // currentTask?.cancel() do anything — it was never previously
                // captured, so that call was always cancelling nil.
                currentTask = speechRecognizer.recognitionTask(with: recognitionRequest) { result, error in
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
    
    // Builds every completed Sentence locally first and publishes once at the end.
    // Appending to `sentences` (a @Published array) inside the loop fired a separate
    // SwiftUI re-render — including a full layout pass of the growing transcript list —
    // per sentence instead of per recognition result, which is what made the UI feel
    // sluggish as the transcript grew longer.
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
        // Only a run that actually reached the end of the file gets a whole-episode
        // summary — one built from a run that stopped partway through wouldn't
        // actually cover "the whole podcast". This used to check resumePosition == 0
        // instead, which looked at how close the last sentence's timestamp was to
        // the file's duration — any episode with more than two minutes of trailing
        // music or silence after the last spoken word made that look incomplete
        // even on a run that had genuinely finished, so the summary silently never
        // appeared.
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
        var completedFully = false
        do {
            let audioFile = try AVAudioFile(forReading: at)
            let sampleRate = audioFile.processingFormat.sampleRate
            audioFile.framePosition = resumePosition
            currentTimeOffset = resumePosition == 0 ? 0 : TimeInterval(resumePosition) / sampleRate

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
                if Task.isCancelled {
                    await analyzer.cancelAndFinishNow()
                    break
                }
                if result.isFinal {
                    let bestTranscription = result.text // an AttributedString
                    let plainTextBestTranscription = String(bestTranscription.characters) // a String
                    
                    // Get the word-level timing information
                    var timestamps: [(String, TimeInterval)] = []
                    
                    if let t = result.text.runs.first?.audioTimeRange {
                        let timestamp = self.currentTimeOffset + t.start.seconds
                        timestamps.append((plainTextBestTranscription, timestamp))
                        
                        await self.updateTimestamps(timestamps)
                        self.saveCheckpoint()
                    }
                }
            }
            completedFully = !Task.isCancelled
        }
        catch {
            await setStatus("Could not transcribe \(error.localizedDescription)")
        }
        // Mirrors recognizeSpeech: figure out whether this run stopped (cancellation,
        // expiration, or an error) with meaningful audio left untranscribed, so a
        // later call picks up from resumePosition instead of starting over.
        lastRunReachedEndOfAudio = completedFully
        checkResumable(at, definitelyComplete: completedFully)
    }
    
    func cancel() {
        currentTask?.cancel()
        currentTranscriptionTask?.cancel()
        // TranscriberView's Start/Stop button branches on `working` to decide
        // whether a tap means cancel or start — that only works if `working`
        // actually reads false by the time this call returns. Button taps are
        // already on the main thread, so flip it synchronously there; the
        // MainActor hop is only needed for the one other caller that isn't
        // already on it — the background transcription task's expirationHandler,
        // which iOS can invoke on an arbitrary thread.
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

            // A transcript that looks finished but has no summary yet — e.g. one
            // made before this feature existed, or before the completion-detection
            // fix that made summarization actually fire — otherwise sits there
            // forever: summarizeIfNeeded only ever runs from an active transcribe()
            // call, and just opening an episode doesn't trigger one.
            if summary.isEmpty, !array.isEmpty, let url, looksComplete(url, sentences: array) {
                // `array` (not self.allSentences) is captured by value here, so this
                // stays correct even if the user switches episodes — and this
                // Transcriber instance's allSentences gets reset — before it runs.
                Task { await self.summarizeIfNeeded(fn: fn, sentences: array) }
            }
        }
        return self
    }

    // Best-effort "does this on-disk transcript look finished" check, used only to
    // decide whether load() should backfill a missing summary. Deliberately doesn't
    // mutate allSentences/resumePosition the way checkResumable does — this is a
    // read for a UI decision, not a resume decision.
    private func looksComplete(_ audioFileURL: URL, sentences: [Sentence]) -> Bool {
        if subscriptions?.isTranscriptMarkedComplete(audioFileURL.deletingPathExtension().lastPathComponent) == true {
            return true
        }
        guard let lastTimestamp = sentences.last?.timestamp,
              let audioFile = loadAudioFile(fromURL: audioFileURL) else { return false }
        let sampleRate = Double(audioFile.processingFormat.sampleRate)
        let sizeInSeconds = Double(audioFile.length) / sampleRate
        return lastTimestamp >= sizeInSeconds - 120
    }
    
    func transcribe(_ url:URL) async {
        if let currentTask = currentTask {
            currentTask.cancel()
        }
        currentTranscriptionTask?.cancel()
        transcriptionGeneration += 1

        audioURL = url
        // A prior run — this launch or an earlier one, via a checkpoint `load()`
        // brought back from disk — may have left off partway through. Check before
        // wiping so that checkpoint isn't discarded unseen.
        // A transcript marked complete is never "resumed" from its last sentence
        // just because the episode ends in long music/silence — Start redoes it.
        let fn = url.deletingPathExtension().lastPathComponent
        checkResumable(url, definitelyComplete: subscriptions?.isTranscriptMarkedComplete(fn) == true)
        if resumePosition == 0 {
            // A complete transcript with no summary yet (e.g. transcribed before
            // this feature existed) gets backfilled from what's already there,
            // right before it's wiped below — Start still means "redo the
            // transcription" exactly as before, this just doesn't waste the
            // existing text.
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
