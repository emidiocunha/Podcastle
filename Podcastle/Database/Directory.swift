//
//  Directory.swift
//  Podcastle
//
//  Created by Emídio Cunha on 26/02/2025.
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
import SwiftData

@Model public final class Directory:Sendable {
    var its_id:     UInt64 = 0
    var name:       String = ""
    var artist:     String = ""
    var feed:       String = ""
    var artwork:    String = ""
    
    public init() {
    }
    
    public init(its_id: UInt64, name: String, artist: String, feed: String, artwork: String) {
        self.its_id = its_id
        self.name = name
        self.artist = artist
        self.feed = feed
        self.artwork = artwork
    }
    
    func fileName() -> String {
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            return documents.appendingPathComponent("\(its_id).json", isDirectory: false).path()
        } else {
            return ""
        }
    }
}
