//
//  SummarySpeaker.swift
//  Podcastle
//
//  Created by Emídio Cunha on 30/09/2026.
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
import AVFoundation

// Reads a podcast's summary aloud with on-device text-to-speech, for the "Play"
// button next to the Summary card. Deliberately tiny and single-purpose: it knows
// nothing about Transcriber or the episode, just how to speak (and stop speaking)
// a piece of text.
@MainActor final class SummarySpeaker: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // Starts speaking `text` in a voice matching `language` (Transcriber's detected
    // episode language, e.g. "pt" or "en_US" — the same code used to pick the
    // transcription locale and, now, the summarization language), or stops if
    // already speaking.
    func toggle(_ text: String, language: String) {
        if synthesizer.isSpeaking {
            stop()
            return
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice(for: language)
        synthesizer.speak(utterance)
        isSpeaking = true
    }

    func stop() {
        guard synthesizer.isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    // AVSpeechSynthesisVoice expects a full BCP 47 code (e.g. "pt-PT"), but the
    // detected language is often just a bare ISO code (e.g. "pt") with no region.
    // Matches it against the installed voices' own language codes rather than
    // guessing a region, falling back to the device's own language if nothing
    // installed matches at all.
    private static func voice(for language: String) -> AVSpeechSynthesisVoice? {
        let bare = language.split(separator: "_").first.map(String.init) ?? language
        let installed = AVSpeechSynthesisVoice.speechVoices().map(\.language)
        if let match = installed.first(where: { $0.lowercased().hasPrefix(bare.lowercased()) }) {
            return AVSpeechSynthesisVoice(language: match)
        }
        return AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
    }
}

extension SummarySpeaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
}
