//
//  Imagery.swift
//  VoiceFeed
//
//  Created by Emídio Cunha on 12/06/2023.
//

import Foundation
import SwiftUI
import CryptoKit

// This is a cache embryo.

class ImageCache {
    @Environment(\.displayScale) var displayScale
    
    static let shared = ImageCache()
    var cache:[String:Image] = [:]
    var color:[String:UIColor] = [:]
    
    private init() {
        prune(false)
    }
    
    subscript(url: String) -> Image? {
        get {
            if let image = cache[url] {
                return image
            } else {
                if let local = URL(string:localUrl(url)) {
                    if FileManager().fileExists(atPath:local.path()) {
                        do {
                            let img = try UIImage(data: Data(contentsOf: local))
                            
                            if let img = img {
                                let image = Image(uiImage:img)
                                
                                cache[url] = image
                                color[url] = img.averageColor?.darker() ?? UIColor.black
                                
                                #if DEBUG
                                print("Loading cached image: \(url)")
                                #endif
                                return image
                            }
                        }
                        catch let error {
                            print("Error loading image: ", error)
                        }
                    }
                }
                return nil
            }
        }
        set {
            guard let newValue = newValue else {
                return
            }
            
            cache[url] = newValue
            
            saveImage(from:newValue, url:url)
        }
    }
    
    func saveImage(from image: Image, url:String) {
        Task { @MainActor in
            let renderer = ImageRenderer(content: image)
        
            //renderer.scale = 3 //kScreenScale
            if let uiImage = renderer.uiImage {
                if let data = uiImage.jpegData(compressionQuality: 1.0) {
                    if let local = URL(string: localUrl(url)) {
                        do {
                            print("Caching local image on disk \(local.lastPathComponent)")
                            color[url] = uiImage.averageColor ?? UIColor.black
                            try data.write(to: local, options: Data.WritingOptions.atomic)
                        } catch let error {
                            print("Error saving: ", error)
                        }
                    }
                }
            }
        }
    }
    
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
    
    func reset() {
        cache.removeAll()
    }
    
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
    }
}

// Kind of cool async image loader, EXCEPT of you want to know its size.

struct AsyncImageView: View {
    var url: String
    var logo: Bool
    var width: CGFloat
    
    var body: some View {
        if !url.isEmpty {
            if let img = ImageCache.shared[url] {
                formatImage(img)
            } else {
                AsyncImage(url:URL(string: url)!) { phase in
                    switch phase {
                    case .empty:
                        ProgressView().frame(width: width, height:width * 0.75)
                    case .success(let image):
                        formatImage(cacheAndRender(image))
                    case .failure:
                        Color.clear
                    @unknown default:
                        EmptyView()
                    }
                }
            }
        }
    }
        
    func formatImage(_ image: Image) -> some View {
        image.resizable()
            .scaledToFit()
            .cornerRadius(4)
            .frame(maxWidth: logo ? 32 : width)
            .clipped()
    }
    
    func cacheAndRender(_ image: Image) -> Image {
        ImageCache.shared[url] = image
        return image
        //return ImageCache.shared[url] ?? Image("photo")
    }
}

extension UIImage {
    /// Average color of the image, nil if it cannot be found
    var averageColor: UIColor? {
        // convert our image to a Core Image Image
        guard let inputImage = CIImage(image: self) else { return nil }

        // Create an extent vector (a frame with width and height of our current input image)
        let extentVector = CIVector(x: inputImage.extent.origin.x,
                                    y: inputImage.extent.origin.y,
                                    z: inputImage.extent.size.width,
                                    w: inputImage.extent.size.height)

        // create a CIAreaAverage filter, this will allow us to pull the average color from the image later on
        guard let filter = CIFilter(name: "CIAreaAverage",
                                  parameters: [kCIInputImageKey: inputImage, kCIInputExtentKey: extentVector]) else { return nil }
        guard let outputImage = filter.outputImage else { return nil }

        // A bitmap consisting of (r, g, b, a) value
        var bitmap = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: kCFNull!])

        // Render our output image into a 1 by 1 image supplying it our bitmap to update the values of (i.e the rgba of the 1 by 1 image will fill out bitmap array
        context.render(outputImage,
                       toBitmap: &bitmap,
                       rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8,
                       colorSpace: nil)

        // Convert our bitmap images of r, g, b, a to a UIColor
        return UIColor(red: CGFloat(bitmap[0]) / 255,
                       green: CGFloat(bitmap[1]) / 255,
                       blue: CGFloat(bitmap[2]) / 255,
                       alpha: CGFloat(bitmap[3]) / 255)
    }
}

