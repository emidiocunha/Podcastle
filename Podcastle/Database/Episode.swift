//
//  Episode.swift
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
import CryptoKit
import AVFoundation

@Model public final class Episode:Sendable {
    var artwork:    String = ""
    var audio:      String = ""
    var author:     String = ""
    var date:       Date = Date()
    var desc:       String = ""
    var duration:   Double = 0.0
    var link:       String = ""
    var summary:    String = ""
    var title:      String = ""
    var position:   Double = 0.0
    var deleted:    Bool = false
    var directory:  Directory? = nil
    
    public init() {
    }
    
    func prettySinceDate() -> String {
        let dif = abs(date.timeIntervalSinceNow) / 3600.0
        
        if dif > 24 {
            let days = ceil(dif / 24)
            let s = days >= 2 ? "s" : ""
            
            return "\(String(format:"%.0f", days)) Day\(s) ago"
        } else if dif < 1 {
            let minutes = dif * 60
            let s = minutes >= 2 ? "s" : ""
            
            return "\(String(format:"%.0f", minutes)) Minute\(s) ago"
        }
        
        let s = dif >= 2 ? "s" : ""
        return "\(String(format:"%.0f", dif)) Hour\(s) ago"
    }
    
    func prettyDate() -> String {
        let df = DateFormatter()
        
        df.dateStyle = .short
        
        return df.string(from: date)
    }
        
    func makeLocalUrl(_ urlString:String) -> String {
        if let url = URL(string:urlString) {
            let hashed = SHA256.hash(data: urlString.data(using: .utf8)!)
            let fileName = String(format: "%@.%@", hashed.compactMap { String(format: "%02x", $0) }.joined(), url.pathExtension)
            
            return fileName
        }
        return ""
    }
    
    func fullLocalUrl(_ urlString:String) -> URL? {
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first, urlString.count > 0 {
            return documents.appendingPathComponent(urlString, isDirectory: false)
        } else {
            return nil
        }
    }
    
    func localUrl(_ urlString:String?) -> String {
        guard let urlString = urlString else {
            return ""
        }
        
        if let url = URL(string:urlString) {
            let hashed = SHA256.hash(data: urlString.data(using: .utf8)!)
            let fileName = String(format: "%@.%@", hashed.compactMap { String(format: "%02x", $0) }.joined(), url.pathExtension)
            
            return fileName
        }
        return ""
    }
    
    func fullLocalUrl(_ podcastUrlType:PodcastURLType) -> URL? {
        switch(podcastUrlType) {
        case .artwork:
            return fullLocalUrl(localUrl(artwork))
        case .audio:
            return fullLocalUrl(localUrl(audio))
        }
    }
    
    func fileSize(_ podcastUrlType:PodcastURLType) -> String {
        guard let path = fullLocalUrl(podcastUrlType) else {
            return ""
        }
        
        do {
            if FileManager().fileExists(atPath: path.path()) {
                let fileAttributes = try FileManager.default.attributesOfItem(atPath: path.path())
                if let fileSize = fileAttributes[FileAttributeKey.size] as? Double {
                    // Convert the file size to megabytes
                    let fileSizeInMB = fileSize / (1024 * 1024)
                    return String(format: "%.1f MB", fileSizeInMB)
                }
            }
        } catch {
            print("Error: \(error)")
        }
        
        return ""
    }
    
    func timeLeft() -> Double {
        if duration != 0.0 {
            (position / duration) * 100
        } else {
            0.0
        }
    }
    
    func secondsLeft() -> Double {
        if duration == 0.0 {
            podcastDuration() - position
        } else {
            duration - position
        }
    }
    
    // This function is Sync to avoid the new .load
    func podcastDuration() -> Double {
        var sizeInSeconds = 0.0
        
        if let fullPath = fullLocalUrl(.audio) {
            if FileManager.default.fileExists(atPath: fullPath.path()) {
                do {
                    let audioFile = try AVAudioFile(forReading: fullPath)
                    let audioFormat = audioFile.processingFormat
                    let frameCount = audioFile.length
                    let sampleRate = Double(audioFormat.sampleRate)
                    
                    sizeInSeconds = Double(frameCount) / sampleRate
                } catch {
                    print("Error determining podcast duration: \(error)")
                }
            }
        }
        
        return sizeInSeconds
    }
}
