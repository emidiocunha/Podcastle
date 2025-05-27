//
//  PodcastDirectory.swift
//  Podcastle
//
//  Created by Emídio Cunha on 23/10/2023
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

//
// Define a struct to represent a podcast directory entry from Apple iTunes
// Assumptions:
//
// collectionId in the search api is the same as Id in the marketing api, and
// they both are a unique identifier
//

struct PodcastDirectoryEntry:Identifiable,Codable {
    let id:UInt64
    let name: String
    let artistName: String
    let feedUrl: String
    let artworkUrl: String
    
    // return the file name used to cache the podcast episodes file
    func fileName() -> String {
        "\(id).json"
    }
}

struct PodcastDirectorySearch {
    // URL constants
    static let lookupUrlFormat = "https://itunes.apple.com/lookup?id="
    static let topUrlFormat = "https://rss.applemarketingtools.com/api/v2/us/podcasts/top/10/podcasts.json"
    static let searchUrlFormat = "https://itunes.apple.com/search?media=podcast&term="
    
    // Fetch the real feed URL from a TOP details loookup query
    func fetchTop(_ entry:Directory, downloads:Downloads) async -> Directory? {
        guard let searchUrlString = "\(PodcastDirectorySearch.lookupUrlFormat)\(entry.its_id)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return nil }
        
        do {
            let (url, _) = try await downloads.downloadTempFile(searchUrlString)
            guard let url = url else {
                return nil
            }
            
            do {
                let data = try Data(contentsOf: url)
                // Decode the JSON response
                let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
                let results:[[String: Any]]? = json?["results"] as? [[String: Any]]
            
                if let result = results?.first,
                   let name = result["collectionName"] as? String,
                   let artistName = result["artistName"] as? String,
                   let feedUrlString = result["feedUrl"] as? String,
                   let artworkUrlString = result["artworkUrl100"] as? String {
                    let podcast = Directory(its_id: entry.its_id, name: name, artist: artistName, feed: feedUrlString, artwork: artworkUrlString)
                    // completion(podcast, nil)
                    return podcast
                }
            }
            catch {
                return nil
            }
        } catch {
        }
        return nil
    }
    
    // Function to fetch podcast data
    func fetchPodcasts(searchTerm: String, downloads:Downloads) async -> [Directory]? {
        let s = searchTerm.count == 0 ? true : false
        
        // Create the search URL using the search term
        let searchUrlString:String? = (s ? PodcastDirectorySearch.topUrlFormat : "\(PodcastDirectorySearch.searchUrlFormat)\(searchTerm)").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        
        guard let searchUrlString = searchUrlString else { return nil }
        
        do {
            let (url, _) = try await downloads.downloadTempFile(searchUrlString)
            if let url = url {
                let data = try Data(contentsOf: url)
                // Decode the JSON response
                let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
                var results:[[String: Any]]?
                
                // Handle the TOP podcasts case
                if s {
                    if let root = json?["feed"] as? [String: Any] {
                        results = root["results"] as? [[String: Any]]
                    }
                } else {
                    results = json?["results"] as? [[String: Any]]
                }
                
                // Extract podcast results
                if let results = results {
                    var podcasts: [Directory] = []
                    
                    // Parse individual podcast data
                    for result in results {
                        if let name = result[s ? "name" : "collectionName"] as? String,
                           let artistName = result["artistName"] as? String,
                           let feedUrlString = result[s ? "url" : "feedUrl"] as? String,
                           let artworkUrlString = result["artworkUrl100"] as? String {
                            var podcastId:UInt64?
                            
                            if s {
                                if let id = result["id"] as? String {
                                    podcastId = UInt64(id)
                                }
                            } else {
                                podcastId = result["collectionId"] as? UInt64
                            }
                            
                            if let podcastId = podcastId {
                                let podcast = Directory(its_id: podcastId, name: name, artist: artistName, feed: feedUrlString, artwork: artworkUrlString)
                                podcasts.append(podcast)
                            }
                        }
                    }
                    return podcasts
                } else {
                    return nil
                }

            }
        } catch {
            return nil
        }
        return nil
    }
    
    // Function to fetch podcast data
    func fetchPodcasts(urlString: String, downloads:Downloads) async -> [Directory]? {
        do {
            let (url, _) = try await downloads.downloadTempFile(urlString)
            if let url = url {
                var podcasts: [Directory] = []
                let parser = PodcastParser()
                let request = Directory()
                
                request.feed = url.absoluteString
                
                let items = await parser.parseRSSFeed(request)
                
                if items.count > 0 {
                    if let first = items.first {
                        let podcast = Directory(its_id: UInt64.max, name: first.title, artist: first.author, feed: urlString, artwork: first.artwork)
                        podcasts.append(podcast)
                    }
                }
                return podcasts
            }
        } catch {
            return nil
        }
        return nil
    }
}
