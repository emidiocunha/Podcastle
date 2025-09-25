//
//  PodcastFile.swift
//  Podcastle
//
//  Created by Emídio Cunha on 03/08/2024.
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

@MainActor class PodcastFile: ObservableObject {
    // PodcastFile is responsible for managing chapter-based playback from an ID3v2-tagged audio file.
    // It uses ID3V2Frame objects to track and update the current playback chapter.
    
    // The chapter currently associated with the current playback time.
    @Published var currentChapter: ID3V2Frame? = nil
    
    // Represents the loaded ID3v2 file containing chapter metadata.
    var id3v2file: ID3V2File? = nil
    var hasChapters: Bool = false
    
    // Loads the specified ID3v2 audio file and updates the current chapter based on time.
    func loadFile(_ filename: String, seconds: Double, desc:String?) {
        id3v2file = ID3V2File(filename: filename)
        // Proceed to set chapter only if chapters are found.
        if id3v2file?.chapters().count ?? 0 > 0 {
            hasChapters = true
            updateCurrentChapter(seconds)
        } else {
            // Clear current chapter if no chapter data is available.
            if let desc = desc {
                if let chapters = id3v2file?.createChapters(from: desc), chapters.count > 0 {
                    updateCurrentChapter(seconds)
                    updateCurrentChapter(seconds)
                }
            } else {
                currentChapter = nil
                hasChapters = false
            }
        }
    }
    
    // Determines and updates the current chapter based on playback time in seconds.
    func updateCurrentChapter(_ seconds: Double) {
        let m = UInt32(ceil(seconds) * 1000)
        
        if let ch = id3v2file?.chapters().first(where: { frame in
            // Convert the playback time into milliseconds.
            // Check if current time is within the chapter's time range.
            return m >= frame.startTime && m < frame.endTime
        }) {
            // Avoid updating currentChapter if it's already the same.
            let current = currentChapter
            if current == nil || current?.id != ch.id {
                currentChapter = ch
            }
        }
    }
}
