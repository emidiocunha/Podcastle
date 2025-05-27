//
//  UIExtensions.swift
//  Podcastle
//
//  Created by Emídio Cunha on 07/08/2023.
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

extension View {
    func animationsDisabled() -> some View {
        return self.transaction { (tx: inout Transaction) in
            tx.disablesAnimations = true
            tx.animation = nil
        }.animation(nil, value:UUID())
    }
}

extension Color {
    var isDarkColor: Bool {
        let uiColor = UIColor(self)
        var white: CGFloat = 0
        uiColor.getWhite(&white, alpha: nil)
        return white < 0.5
    }
}

extension UIColor {
    private func add(_ value: CGFloat, toComponent: CGFloat) -> CGFloat {
        return max(0, min(1, toComponent + value))
    }
    
    private func makeColor(componentDelta: CGFloat) -> UIColor {
        var red: CGFloat = 0
        var blue: CGFloat = 0
        var green: CGFloat = 0
        var alpha: CGFloat = 0
        
        // Extract r,g,b,a components from the
        // current UIColor
        getRed(
            &red,
            green: &green,
            blue: &blue,
            alpha: &alpha
        )
        
        // Create a new UIColor modifying each component
        // by componentDelta, making the new UIColor either
        // lighter or darker.
        return UIColor(
            red: add(componentDelta, toComponent: red),
            green: add(componentDelta, toComponent: green),
            blue: add(componentDelta, toComponent: blue),
            alpha: alpha
        )
    }
    
    func lighter(componentDelta: CGFloat = 0.1) -> UIColor {
        return makeColor(componentDelta: componentDelta)
    }
    
    func darker(componentDelta: CGFloat = 0.1) -> UIColor {
        return makeColor(componentDelta: -1*componentDelta)
    }
}

extension String {
    func removingHTMLTagsAndDecodingEntities() -> String {
        // Remove HTML tags
        let regexPattern = "<.*?>"
        let regex = try? NSRegularExpression(pattern: regexPattern, options: .caseInsensitive)
        let range = NSRange(location: 0, length: self.utf16.count)
        let htmlLessString = regex?.stringByReplacingMatches(in: self, options: [], range: range, withTemplate: "") ?? self
        
        // Decode common HTML entities
        var decodedString = htmlLessString
        let htmlEntities: [String: String] = [
            "&quot;": "\"",
            "&apos;": "'",
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&nbsp;": "\u{00a0}",
            "&copy;": "\u{00a9}",
            "&reg;": "\u{00ae}",
            "&euro;": "\u{20ac}",
            "&pound;": "\u{00a3}",
            "&yen;": "\u{00a5}"
        ]
        
        for (entity, replacement) in htmlEntities {
            decodedString = decodedString.replacingOccurrences(of: entity, with: replacement)
        }
        
        return decodedString
    }
}

extension Double {
    func prettyPrintSeconds() -> String {
        guard self.isFinite else { return "" }
        
        let seconds = Int(self)
        let hours = seconds / 3600
        let minutes = (seconds - (hours * 3600)) / 60
        let sec = (seconds - (hours * 3600) - (minutes * 60))
        let h = hours > 0 ? String(format:"%02d:", hours) : ""
        
        return String(format:"%@%02d:%02d", h, minutes, sec)
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
    
    func isAllWhite() -> Bool {
        guard let cgImage = self.cgImage else {
            return false // Return false for images with no underlying CGImage
        }
        
        let width = cgImage.width
        let height = cgImage.height
        
        let bytesPerPixel = 4 // RGBA
        let bytesPerRow = bytesPerPixel * width
        let bitsPerComponent = 8
        
        let pixelData = UnsafeMutablePointer<UInt8>.allocate(capacity: bytesPerRow * height)
        defer {
            pixelData.deallocate()
        }
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: pixelData,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        
        context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var x = 0
        let incX:Int = width / height
        
        for y in 0..<height {
            let offset = (y * bytesPerRow) + (x * bytesPerPixel)
            let red = pixelData[offset]
            let green = pixelData[offset + 1]
            let blue = pixelData[offset + 2]
            let alpha = pixelData[offset + 3]
            
            if red != 255 || green != 255 || blue != 255 || alpha != 255 {
                return false // If any non-white or non-opaque pixel is found, the image is not all-white
            }
            
            x = x + incX
        }
        
        return true // All pixels are white and opaque, so the image is considered all-white
    }
}
