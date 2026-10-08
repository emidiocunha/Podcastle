//
//  PodcastParser.swift
//  Podcastle
//
//  Created by Emídio Cunha on 11/06/2023.
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
import CryptoKit
import AVFoundation
import SwiftData

extension String {
    // Was NSAttributedString(data:options:[.documentType: .html],...) — that API
    // is backed by a legacy, single shared WebKit "Web Thread" (NSHTMLReader) that
    // is NOT safe to call off the main thread or concurrently with itself. This
    // runs during RSS parsing on Subscriptions' actor executor (a background
    // thread), once per feed item's title and summary — on every single refresh.
    // That's exactly the misuse that caused a real TestFlight crash: an
    // EXC_BAD_ACCESS deep in WebCore::DocumentLoader whenever it happened to
    // overlap with another HTML-to-NSAttributedString conversion elsewhere (e.g.
    // PlayerView rendering an episode's description on the main thread at the same
    // moment). title/summary are plain-text fields (unlike desc, which goes
    // through sanitizeHTML to keep a small whitelist for rich display), so this
    // just needs to end up as clean text — strip any real markup and unescape
    // entities, all as pure string manipulation with no WebKit involved, safe to
    // call from anywhere, concurrently or not.
    var htmlDecoded: String {
        guard contains("&") || contains("<") else { return self }
        var result = self

        // Strip real markup first, on the raw (not-yet-entity-decoded) string —
        // otherwise literal "<"/">" produced by decoding &lt;/&gt; just below
        // could get mistaken for tags and stripped right back out.
        if result.contains("<") {
            result = result.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        }

        // Numeric character references: &#NNN; (decimal) and &#xHH;/&#XHH; (hex).
        if let regex = try? NSRegularExpression(pattern: "&#([xX]?)([0-9A-Fa-f]+);") {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let fullRange = Range(match.range, in: result),
                      let hexFlagRange = Range(match.range(at: 1), in: result),
                      let digitsRange = Range(match.range(at: 2), in: result) else { continue }
                let isHex = !result[hexFlagRange].isEmpty
                guard let codePoint = UInt32(result[digitsRange], radix: isHex ? 16 : 10),
                      let scalar = Unicode.Scalar(codePoint) else { continue }
                result.replaceSubrange(fullRange, with: String(Character(scalar)))
            }
        }

        // Named entities actually seen in real-world podcast feed titles/summaries
        // — &amp; last, so a literal "&amp;lt;" (wanting to show "&lt;" as text)
        // isn't double-unescaped into "<".
        for (entity, replacement) in String.namedHTMLEntities where result.contains(entity) {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result
    }

    private static let namedHTMLEntities: [(String, String)] = [
        ("&nbsp;", "\u{00A0}"), ("&mdash;", "—"), ("&ndash;", "–"), ("&hellip;", "…"),
        ("&lsquo;", "‘"), ("&rsquo;", "’"), ("&ldquo;", "“"), ("&rdquo;", "”"),
        ("&copy;", "©"), ("&reg;", "®"), ("&trade;", "™"),
        ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"),
        ("&amp;", "&"),
    ]
}

enum PodcastURLType {
    case artwork
    case audio
}

// Parse the XML from the podcast file
class PodcastParser: NSObject, XMLParserDelegate {
    private var currentElement: String = ""
    private var currentTitle: String = ""
    private var currentDescription: String = ""
    private var currentSummary: String = ""
    private var currentLink: String = ""
    private var currentImageURL: String = ""
    private var currentAudioURL: String = ""
    private var currentDate: String = ""
    private var currentDuration: String = ""
    private var currentAuthor: String = ""
    
    private var isParsingItem = false
    private var podcasts: [Episode] = []
    private var currentPodcast: Episode?
    private var feed:String = ""
    
    private var completionHandler: @Sendable ([Episode]) async -> Void = { _ in }
    private var didComplete = false
    
    private var altArtwork:String = ""
    private var nest:Bool = true
    private var dir:Directory?
    
    // Starts parsing the RSS feed from the given directory.
    func parseRSSFeed(_ directory: Directory) async -> [Episode] {
        let url = URL(fileURLWithPath: directory.fileName())
        
        return await withCheckedContinuation { continuation in
            dir = directory
            altArtwork = directory.artwork
            feed = directory.feed
            completionHandler = { episodes in
                continuation.resume(returning: episodes)
            }
            
            guard let parser = XMLParser(contentsOf: url) else {
                print("Failed to initialize XML parser")
                continuation.resume(returning: [])
                return
            }
            parser.delegate = self
            parser.parse()
        }
    }
    
    // Called when the XML parser starts parsing the document.
    func parserDidStartDocument(_ parser: XMLParser) {
        podcasts.removeAll()
    }
    
    // Called when the parser finds a new XML element.
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
        if elementName == "item" {
            isParsingItem = true
            currentPodcast = Episode()
        } else if elementName == "itunes:image" {
            currentImageURL = attributeDict["href"] ?? ""
        } else if elementName == "enclosure" {
            currentAudioURL = attributeDict["url"] ?? ""
        }
    }
    
    // Called when the parser finds characters between XML tags.
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        let parsedString = string.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if !parsedString.isEmpty {
            switch currentElement {
            case "title":
                if isParsingItem {
                    currentTitle += parsedString
                }
            case "description":
                if isParsingItem {
                    currentDescription += parsedString
                }
            case "link":
                if isParsingItem {
                    currentLink += parsedString
                }
            case "itunes:summary":
                if isParsingItem {
                    currentSummary += parsedString
                }
            case "pubDate":
                if isParsingItem {
                    currentDate += parsedString
                }
            case "itunes:duration":
                if isParsingItem {
                    currentDuration += parsedString
                }
            case "itunes:author":
                if isParsingItem {
                    currentAuthor += parsedString
                }
            default:
                break
            }
        }
    }
    
    // Converts a string to a Date using common podcast formats.
    func parseDate(_ dateString:String) -> Date {
        let fmt = DateFormatter()
        let fmts = ["yyyy-MM-dd'T'HH:mm:ssZ", "E, d MMM yyyy HH:mm:ss Z", "E, d MMM yyyy HH:mm Z", "E, d MMM yyyy HH:mm:ss zzz"]
        var date = Date()
        
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone.autoupdatingCurrent
        for f in fmts {
            fmt.dateFormat = f
            if let td = fmt.date(from: dateString) {
                date = td
                break
            }
        }
        return date
    }
    
    // Called when the parser finishes an XML element.
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "item" {
            isParsingItem = false
            
            currentPodcast?.title = currentTitle.htmlDecoded
            currentPodcast?.desc = sanitizeHTML(currentDescription)
            currentPodcast?.summary = currentSummary.htmlDecoded
            currentPodcast?.link = currentLink
            currentPodcast?.artwork = currentImageURL.count > 0 ? currentImageURL : altArtwork
            currentPodcast?.audio = currentAudioURL
            currentPodcast?.date = parseDate(currentDate)
            
            let c = currentDuration.components(separatedBy: ":")
            if c.count > 1 {
                var s = 0
                if c.count == 3 {
                    s += (Int(c[0]) ?? 0) * 3600
                    s += (Int(c[1]) ?? 0) * 60
                    s += (Int(c[2]) ?? 0)
                } else {
                    s += (Int(c[0]) ?? 0) * 60
                    s += (Int(c[1]) ?? 0)
                }
                currentPodcast?.duration = Double(s)
            } else {
                currentPodcast?.duration = Double(currentDuration) ?? 0.0
            }
            
            currentPodcast?.author = currentAuthor
            
            if let podcast = currentPodcast {
                podcasts.append(podcast)
            }
            
            currentTitle = ""
            currentDescription = ""
            currentSummary = ""
            currentLink = ""
            currentImageURL = ""
            currentAudioURL = ""
            currentPodcast = nil
            currentDate = ""
            currentDuration = ""
            currentAuthor = ""
        }
    }
    
    // Remove potential security issues with a tag that might have HTML
    func sanitizeHTML(_ html: String) -> String {
        var cleaned = html
        
        // Remove <script> and <style> tags completely
        let patterns = ["<script[^>]*>.*?</script>", "<style[^>]*>.*?</style>"]
        for pattern in patterns {
            cleaned = cleaned.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        
        // Remove all on-event attributes (like onclick, onload)
        cleaned = cleaned.replacingOccurrences(of: "\\s+on\\w+\\s*=\\s*(['\"]).*?\\1", with: "", options: .regularExpression)
        
        // Optionally: Remove all tags not in a whitelist (e.g., allow only p, br, strong, em, a, ul, li)
        let whitelist = "p|br|strong|b|em|i|a|ul|ol|li"
        cleaned = cleaned.replacingOccurrences(
            of: "</?(?!\(whitelist))(\\w+)[^>]*>",
            with: "",
            options: .regularExpression
        )
        
        return cleaned
    }
    
    // Returns a hashed filename from a given URL string.
    func localUrl(_ urlString:String) -> String {
        if let url = URL(string:urlString) {
            let hashed = SHA256.hash(data: urlString.data(using: .utf8)!)
            let fileName = String(format: "%@.%@", hashed.compactMap { String(format: "%02x", $0) }.joined(), url.pathExtension)
            
            return fileName
        }
        return ""
    }
    
    // Called when the XML document parsing is complete.
    func parserDidEndDocument(_ parser: XMLParser) {
        guard !didComplete else { return }
        didComplete = true
        Task { [completionHandler, podcasts] in
            await completionHandler(podcasts)
        }
    }

    // Called when a parsing error occurs.
    // XMLParser never calls parserDidEndDocument after abortParsing(), so without this
    // the completionHandler is never invoked and parseRSSFeed's continuation hangs forever
    // — leaving the pending-podcast placeholder spinner stuck indefinitely.
    // libxml2 can still report a trailing parse error after already calling
    // parserDidEndDocument (e.g. junk after the root element), so guard against
    // resuming the continuation twice, which is a fatal error.
    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        print("error \(parseError.localizedDescription)")
        parser.abortParsing()
        guard !didComplete else { return }
        didComplete = true
        Task { [completionHandler, podcasts] in
            await completionHandler(podcasts)
        }
    }
}


