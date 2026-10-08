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
    @State private var isAdding: Bool = false
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
                        guard !isAdding else { return }
                        isAdding = true
                        dismiss()
                        if top {
                            Task {
                                if let entry = await directory.fetchTop(item, downloads: downloads) {
                                    await subscriptions.addPodcast(entry)
                                }
                            }
                        } else {
                            Task {
                                await subscriptions.addPodcast(item)
                            }
                        }
                    }, label: {
                        if isAdding {
                            ProgressView().frame(width: 44)
                        } else {
                            Text("Add")
                        }
                    })
                    .buttonStyle(.bordered)
                    .disabled(isAdding)
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
    @State var showSuccessAlert = false
    @State private var isLoading = false
    @State private var isSearchingLive = false
    // Debounced live search: cancelling the previous attempt when a newer
    // keystroke supersedes it genuinely cuts the in-flight network request short
    // (Downloads.download checks Task cancellation), not just its stale response.
    @State private var liveSearchTask: Task<Void, Never>?
    // Guards against a slow, superseded search's response landing after a newer
    // one already updated the results — cancellation alone isn't quite enough to
    // rely on, since it's cooperative and checked only periodically.
    @State private var searchGeneration = 0
    let directory = PodcastDirectorySearch()
    @Environment(\.dismissSearch) var dismissSearch
    @Environment(\.dismiss) var dismiss
    @Environment(\.isSearching) var isSearching
    @EnvironmentObject var subscriptions:Subscriptions
    @EnvironmentObject var downloads:Downloads

    // Short enough to feel live, long enough that a normal typing cadence only
    // fires one request per pause rather than one per keystroke.
    private let liveSearchDebounce: Duration = .milliseconds(350)
    // Below this, a query is too broad to be worth a round trip on every pause —
    // still saves network for the first character or two, same spirit as only
    // searching on submit before, just far more responsive past that point.
    private let liveSearchMinimumLength = 2

    var body: some View {
        NavigationStack {
            List {
                if top {
                    Section("Popular Podcasts") {
                    }
                }
                if isSearchingLive {
                    HStack {
                        Spacer()
                        ProgressView().controlSize(.small)
                        Spacer()
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
            .searchable(text: $searchText, prompt:"Search for Podcasts or type a URL")
            .onChange(of: searchText) { _, newValue in
                scheduleLiveSearch(for: newValue)
            }
            .onSubmit(of: .search) {
                // An explicit Return/submit always runs right away, regardless of
                // length or any pending debounce — e.g. pasting a feed URL, or
                // just not wanting to wait out the pause.
                liveSearchTask?.cancel()
                performSearch(searchText, dismissAfterward: true, showBlockingOverlay: true)
            }
            .overlay {
                if isLoading {
                    ZStack {
                        Color.black.opacity(0.15).ignoresSafeArea()
                        ProgressView("Searching…")
                            .padding(16)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .allowsHitTesting(true)
                }
            }
            .alert("Podcast added successfully!", isPresented: $showSuccessAlert) {
                Button("OK", role: .cancel) {
                    dismissSearch()
                    dismiss()
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

    // Cancels whatever the previous keystroke scheduled, then — once typing has
    // paused and there's enough text to be worth it — runs the search for real.
    // No one types a feed URL character by character expecting live results from
    // it, so that case is still left to an explicit submit only.
    private func scheduleLiveSearch(for text: String) {
        liveSearchTask?.cancel()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Cleared back to nothing — snap straight back to the popular-podcasts
            // view (same fetch as onAppear) rather than waiting out a pause, and
            // rather than just blanking the list.
            searchGeneration += 1
            let generation = searchGeneration
            top = true
            Task {
                if let podcasts = await directory.fetchPodcasts(searchTerm: "", downloads: downloads),
                   generation == searchGeneration {
                    results = podcasts
                }
            }
            return
        }
        guard trimmed.count >= liveSearchMinimumLength, !startsWithValidURL(string: trimmed) else { return }

        liveSearchTask = Task {
            try? await Task.sleep(for: liveSearchDebounce)
            guard !Task.isCancelled else { return }
            performSearch(trimmed, dismissAfterward: false, showBlockingOverlay: false)
        }
    }

    // Shared by both the debounced live search and an explicit Return/submit —
    // only the loading indicator and whether the keyboard dismisses afterward
    // differ between the two.
    private func performSearch(_ text: String, dismissAfterward: Bool, showBlockingOverlay: Bool) {
        searchGeneration += 1
        let generation = searchGeneration

        if startsWithValidURL(string: text) {
            isLoading = true
            Task {
                defer { isLoading = false }
                if let podcasts = await directory.fetchPodcasts(urlString: text, downloads: downloads),
                   generation == searchGeneration,
                   let first = podcasts.first {
                    await subscriptions.addPodcast(first)
                    changes = changes + 1
                    showSuccessAlert = true
                }
            }
        } else {
            if showBlockingOverlay { isLoading = true } else { isSearchingLive = true }
            Task {
                defer {
                    if showBlockingOverlay { isLoading = false } else { isSearchingLive = false }
                }
                if let podcasts = await directory.fetchPodcasts(searchTerm: text, downloads: downloads),
                   generation == searchGeneration {
                    results = podcasts
                    top = false
                }
                if dismissAfterward {
                    dismissSearch()
                }
            }
        }
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
