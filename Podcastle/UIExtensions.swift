//
//  UIExtensions.swift
//  VoiceFeed
//
//  Created by Emídio Cunha on 07/08/2023.
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
