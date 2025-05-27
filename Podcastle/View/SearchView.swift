//
//  Search.swift
//  Podcastle
//
//  Created by Emídio Cunha on 16/06/2023.
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

struct PodcastDetails: View {
    var podcast: Directory
    @State var results:[Episode] = []
    @State var isSubscribed:Bool = false
    @EnvironmentObject var subscriptions: Subscriptions
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack {
                        HStack {
                            AsyncImageView(url:podcast.artwork, logo: false, width:100)
                            VStack(alignment: .leading) {
                                Text("\(podcast.name)").font(.title)
                            }
                            Spacer()
                            if isSubscribed {
                                Button(action: {
                                    Task {
                                        await subscriptions.removePodcast(podcast)
                                    }
                                    isSubscribed = false
                                }, label: {
                                    Text("Remove")
                                }).buttonStyle(.bordered)
                            } else {
                                Button(action: {
                                    Task {
                                        await subscriptions.addPodcast(podcast)
                                    }
                                    isSubscribed = true
                                }, label: {
                                    Text("Add")
                                }).buttonStyle(.bordered)
                            }
                        }
                        HStack {
                            Text("\(podcast.artist)")
                            Spacer()
                        }
                        HStack {
                            Text("\(podcast.feed)").font(.footnote)
                            Spacer()
                        }
                    }
                }
                Section("Episodes") {
                    ForEach(results, id:\.id) { item in
                        VStack(alignment: .leading) {
                            HStack {
                                AsyncImageView(url:item.artwork, logo: false, width:100)
                                Text("\(item.title)").font(.title)
                            }
                            Text("\(item.summary)").frame(maxWidth: .infinity, alignment: .topLeading)
                                .lineLimit(4)
                                .multilineTextAlignment(.leading)
                            Text("\(item.link)").font(.footnote)
                            HStack {
                                Text("\(item.prettySinceDate())")
                                Spacer()
                            }
                        }
                    }
                }
            }.listStyle(.plain)
            .navigationTitle(podcast.name)
        }.onAppear {
            Task {
                let parser = PodcastParser()
                results = await parser.parseRSSFeed(podcast)
                isSubscribed = await subscriptions.isSubscribed(podcast.feed)
            }
        }
    }
}

struct SearchViewItem: View {
    var item:Directory
    var top:Bool
    var directory:PodcastDirectorySearch
    @State private var isSubscribed: Bool = false
    @EnvironmentObject var downloads: Downloads
    @EnvironmentObject var subscriptions: Subscriptions
    @Environment(\.dismissSearch) var dismissSearch
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        VStack {
            HStack {
                AsyncImageView(url:item.artwork, logo: false, width:100)
                VStack(alignment: .leading) {
                    Text("\(item.name)").font(.title)
                }
                Spacer()
            }
            HStack {
                Text("\(item.artist)")
                Spacer()
                if isSubscribed {
                    Button(action: {
                        Task {
                            await subscriptions.removePodcast(item)
                        }
                        dismiss()
                    }, label: {
                        Text("Remove")
                    }).buttonStyle(.bordered)
                } else {
                    Button(action: {
                        if top {
                            Task {
                                if let entry = await directory.fetchTop(item, downloads: downloads) { //entry, error in
                                    await subscriptions.addPodcast(entry)
                                    dismiss()
                                }
                            }
                        } else {
                            Task {
                                await subscriptions.addPodcast(item)
                                dismiss()
                            }
                        }
                    }, label: {
                        Text("Add")
                    }).buttonStyle(.bordered)
                }
            }
            HStack {
                Text("\(item.feed)").font(.footnote)
                Spacer()
            }
        }
        .task {
            let result = await subscriptions.isSubscribed(podcastId: item.its_id)
            isSubscribed = result
        }
    }
}

struct SearchView: View {
    @State var results:[Directory] = []
    @State var searchText:String = ""
    @State var top = false
    @State var changes = 0
    let directory = PodcastDirectorySearch()
    @Environment(\.dismissSearch) var dismissSearch
    @Environment(\.dismiss) var dismiss
    @Environment(\.isSearching) var isSearching
    @EnvironmentObject var subscriptions:Subscriptions
    @EnvironmentObject var downloads:Downloads
    
    var body: some View {
        NavigationStack {
            List {
                if top {
                    Section("Popular Podcasts") {
                    }
                }
                ForEach(results, id:\.its_id) { item in
                    SearchViewItem(item: item, top:top, directory:directory)
                }
            }
            .navigationBarItems(trailing: Button("Close", action: { dismiss() }))
            .listStyle(.plain)
            .navigationTitle("Add Podcast")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt:"Search for Podcasts")
            .onSubmit(of: .search) {
                if startsWithValidURL(string:searchText) {
                    Task {
                        if let podcasts = await directory.fetchPodcasts(urlString: searchText, downloads: downloads) { //{ (podcasts, error) in
                            if let first = podcasts.first {
                                await subscriptions.addPodcast(first)
                                changes = changes + 1
                                dismissSearch()
                                dismiss()
                            }
                        }
                    }
                } else {
                    Task {
                        if let podcasts = await directory.fetchPodcasts(searchTerm: searchText, downloads: downloads) { results = podcasts
                        }
                        dismissSearch()
                        top = false
                    }
                }
            }
            .onAppear {
                top = true
                Task {
                    if let podcasts = await directory.fetchPodcasts(searchTerm: "", downloads: downloads) {
                        results = podcasts
                    }
                }
                
            }
        }
    }
    
    func startsWithValidURL(string: String) -> Bool {
        if let url = URL(string: string), let scheme = url.scheme, let host = url.host {
            // Check if the string starts with a valid URL scheme and host
            return string.hasPrefix("\(scheme)://\(host)")
        }
        
        return false
    }
}

struct Search_Container:View {
    @State var isActive : Bool = false
    
    var body: some View {
        SearchView()
    }
}

struct Search_Previews: PreviewProvider {
    static var previews: some View {
        Search_Container()
    }
}
