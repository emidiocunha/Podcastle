//
//  PodcastDirectory.swift
//  Podcastle
//
//  Created by Emídio Cunha on 23/10/2023.
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
/*
        if URL(string:feedUrl) != nil {
            let hashed = SHA256.hash(data: id.data(using: .utf8)!)
            return String(format: "%@.json", hashed.compactMap { String(format: "%02x", $0) }.joined())
        }
        return ""*/
    }
}

struct PodcastDirectorySearch {
    // URL constants
    static let lookupUrlFormat = "https://itunes.apple.com/lookup?id="
    static let topUrlFormat = "https://rss.applemarketingtools.com/api/v2/us/podcasts/top/10/podcasts.json"
    static let searchUrlFormat = "https://itunes.apple.com/search?media=podcast&term="
    
    // Fetch the real feed URL from a TOP details loookup query
    func fetchTop(_ entry:PodcastDirectoryEntry, completion: @escaping (PodcastDirectoryEntry?, Error?) -> Void) {
        guard let searchUrlString = "\(PodcastDirectorySearch.lookupUrlFormat)\(entry.id)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return }
        
        Downloads.shared.downloadTempFile(searchUrlString) { url, error in
            // Ensure response has data
            guard let url = url,
                  error == nil else {
                completion(nil, error)
                return
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
                    let podcast = PodcastDirectoryEntry(id: entry.id, name: name, artistName: artistName, feedUrl: feedUrlString, artworkUrl: artworkUrlString)
                    completion(podcast, nil)
                }
            }
            catch {
                completion(nil, error) // JSON parsing error
            }
        }
    }
    
    // Function to fetch podcast data
    func fetchPodcasts(searchTerm: String, completion: @escaping ([PodcastDirectoryEntry]?, Error?) -> Void) {
        let s = searchTerm.count == 0 ? true : false
        
        // Create the search URL using the search term
        let searchUrlString:String? = (s ? PodcastDirectorySearch.topUrlFormat : "\(PodcastDirectorySearch.searchUrlFormat)\(searchTerm)").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        
        guard let searchUrlString = searchUrlString else { return }
        
        Downloads.shared.downloadTempFile(searchUrlString) { url, error in
            // Ensure response has data
            guard let url = url,
                  error == nil else {
                completion(nil, error)
                return
            }
            
            do {
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
                    var podcasts: [PodcastDirectoryEntry] = []
                    
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
                                let podcast = PodcastDirectoryEntry(id: podcastId, name: name, artistName: artistName, feedUrl: feedUrlString, artworkUrl: artworkUrlString)
                                podcasts.append(podcast)
                            }
                        }
/*
                        if searchTerm.count == 0 {
                            if let name = result["name"] as? String,
                               let artistName = result["artistName"] as? String,
                               let feedUrlString = result["url"] as? String,
                               let podcastId = result["id"] as? String,
                               let artworkUrlString = result["artworkUrl100"] as? String {
                                let podcast = PodcastDirectoryEntry(id: podcastId, name: name, artistName: artistName, feedUrl: feedUrlString, artworkUrl: artworkUrlString)
                                podcasts.append(podcast)
                            }
                        } else {
                            if let name = result["collectionName"] as? String,
                               let artistName = result["artistName"] as? String,
                               let feedUrlString = result["feedUrl"] as? String,
                               let podcastId = result["collectionId"] as? String,
                               let artworkUrlString = result["artworkUrl100"] as? String {
                                let podcast = PodcastDirectoryEntry(id: podcastId, name: name, artistName: artistName, feedUrl: feedUrlString, artworkUrl: artworkUrlString)
                                podcasts.append(podcast)
                            }
                        }*/
                    }
                    
                    completion(podcasts, nil) // Return the podcast data
                } else {
                    completion(nil, nil) // No results found
                }
            } catch {
                completion(nil, error) // JSON parsing error
            }
            
        }
    }
}
