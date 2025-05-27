//
//  Imagery.swift
//  Podcastle
//
//  Created by Emídio Cunha on 12/06/2023.
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
import SwiftUI
import CryptoKit

// This is a cache embryo.

class ImageCache : ObservableObject {
    @Environment(\.displayScale) var displayScale
    var cache:[String:Image] = [:]
    var color:[String:UIColor] = [:]
    
    // Initializes the image cache and prunes old files.
    public init() {
        prune(false)
    }
    
    // Loads image from cache, disk, or fetches from remote if not cached.
    func image(for url: String) async -> Image? {
        if let image = cache[url] {
            return image
        }

        if let local = URL(string: localUrl(url)) {
            if FileManager().fileExists(atPath: local.path()) {
                do {
                    let data = try Data(contentsOf: local)
                    if let uiImage = UIImage(data: data), !uiImage.isAllWhite() {
                        let image = Image(uiImage: uiImage)
                        await MainActor.run {
                            self.cache[url] = image
                            self.color[url] = uiImage.averageColor?.darker() ?? UIColor.black
                        }
                        return image
                    } else {
                        try FileManager().removeItem(at: local)
                    }
                } catch {
                    print("Error loading image: ", error)
                }
            }
        }

        return nil
    }
    
    // Getter/setter for image cache, loading from disk if necessary.
    subscript(url: String) -> Image? {
        get {
            if let image = cache[url] {
                return image
            } else {
                if let local = URL(string: localUrl(url)) {
                    if FileManager().fileExists(atPath: local.path()) {
                        do {
                            let data = try Data(contentsOf: local)
                            if let uiImage = UIImage(data: data), !uiImage.isAllWhite() {
                                let image = Image(uiImage: uiImage)
                                
                                cache[url] = image
                                color[url] = uiImage.averageColor?.darker() ?? UIColor.black
                            } else {
                                try FileManager().removeItem(at: local)
                            }
                        } catch {
                            print("Error loading image: ", error)
                        }
                    }
                }
            }
            return nil
        }
        set {
            guard let newValue = newValue else {
                return
            }
            
            cache[url] = newValue
            
            saveImage(from:newValue, url:url)
        }
    }
    
    // Renders and saves a SwiftUI Image to disk asynchronously.
    func saveImage(from image: Image, url: String) {
        Task {
            // Render on the main actor (required for SwiftUI views)
            let uiImage: UIImage? = await MainActor.run {
                let renderer = ImageRenderer(content: image)
                return renderer.uiImage
            }

            guard let uiImage, let data = uiImage.jpegData(compressionQuality: 1.0) else { return }

            if let local = URL(string: localUrl(url)) {
                do {
                    print("Caching local image on disk \(local.lastPathComponent)")
                    await MainActor.run {
                        self.color[url] = uiImage.averageColor ?? UIColor.black
                    }
                    try data.write(to: local, options: .atomic)
                } catch {
                    print("Error saving: ", error)
                }
            }
        }
    }
    
    // Generates a hashed local file URL for a given remote URL string.
    func localUrl(_ urlString:String) -> String {
        if let url = URL(string:urlString) {
            let hashed = SHA256.hash(data: urlString.data(using: .utf8)!)
            if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                let fileName = String(format: "%@.%@", hashed.compactMap { String(format: "%02x", $0) }.joined(), url.pathExtension)
                let destination = d.appendingPathComponent(fileName, isDirectory: false)
                return destination.absoluteString
            }
        }
        return ""
    }
    
    // Clears the in-memory image cache.
    func reset() {
        cache.removeAll()
    }
    
    // Deletes old or all cached files from disk based on age or type.
    func prune(_ all:Bool) {
        let fileManager = FileManager.default
        let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        var ext = [".png", ".jpg"]

        guard let fileURLs = try? fileManager.contentsOfDirectory(at: documentsDirectory, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles) else {
            return
        }

        let oneMonthAgo = Calendar.current.date(byAdding: all ? .second : .month, value: -1, to: Date())!

        if all {
            ext.append(contentsOf: [".mp3", "m4a", "m4p"])
        }
        for fileURL in fileURLs {
            let proceed = ext.contains { e in
                return fileURL.absoluteString.hasSuffix(e)
            }
            
            guard proceed else { continue }
            
            let creationDate = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if let fileCreationDate = creationDate, fileCreationDate < oneMonthAgo {
                try? fileManager.removeItem(at: fileURL)
                print("Deleted file in the cache: \(fileURL.lastPathComponent)")
            }
        }
        
        if all {
            Task { @MainActor in
                NotificationCenter.default.post(name: Notification.Name.episodesChangedNotification, object:nil)
            }
        }
    }
}

// Async image loader, tries cache, disk and remote.

struct AsyncImageView: View {
    @EnvironmentObject var imageCache: ImageCache
    var url: String
    var logo: Bool
    var width: CGFloat
    
    @State private var loadedImage: Image? = nil
    
    var body: some View {
        if !url.isEmpty {
            if let img = loadedImage {
                formatImage(img)
            } else {
                ProgressView()
                .frame(width: width, height: width * 0.75)
                .task {
                    // Load image from cache, disk, or remote
                    if let img = await imageCache.image(for: url) {
                        loadedImage = img
                    } else {
                        // Attempt to fetch from the network
                        if let remoteURL = URL(string: url) {
                            do {
                                let (data, _) = try await URLSession.shared.data(from: remoteURL)
                                if let uiImage = UIImage(data: data), !uiImage.isAllWhite() {
                                    let image = Image(uiImage: uiImage)
                                    self.imageCache[url] = image
                                    await MainActor.run {
                                        loadedImage = image
                                    }
                                }
                            } catch {
                                print("Error loading image from network: ", error)
                            }
                        }

                    }
                }
            }
        }
        else {
            EmptyView()
        }
    }
    
    // Styles the image for display with optional logo sizing.
    func formatImage(_ image: Image) -> some View {
        image.resizable()
            .scaledToFit()
            .cornerRadius(4)
            .frame(maxWidth: logo ? 32 : width)
            .clipped()
    }
}

struct BlankImage {
    // Returns a blank (transparent) UIImage of specified size.
    static func image(width: CGFloat, height: CGFloat) -> UIImage {
        let size = CGSize(width: width, height: height)
        UIGraphicsBeginImageContextWithOptions(size, false, 0.0)
        let context = UIGraphicsGetCurrentContext()!

        // Set the fill color to clear (transparent) or any color you prefer
        context.setFillColor(UIColor.clear.cgColor)
        context.fill(CGRect(origin: .zero, size: size))

        let image = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        return image
    }
}



