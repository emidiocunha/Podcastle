//
//  Search.swift
//  VoiceFeed
//
//  Created by Emídio Cunha on 16/06/2023.
//

import Foundation
import SwiftUI

struct PodcastDetails: View {
    var podcast: PodcastDirectoryEntry
    @State var results:[Podcast] = []
    @State var isSubscribed:Bool = false
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack {
                        HStack {
                            AsyncImageView(url:podcast.artworkUrl, logo: false, width:100)
                            VStack(alignment: .leading) {
                                Text("\(podcast.name)").font(.title)
                            }
                            Spacer()
                            if isSubscribed {
                                Button(action: {
                                    Subscriptions.shared.removePodcast(podcast)
                                    isSubscribed = false
                                }, label: {
                                    Text("Remove")
                                }).buttonStyle(.bordered)
                            } else {
                                Button(action: {
                                    Subscriptions.shared.addPodcast(podcast)
                                    isSubscribed = true
                                }, label: {
                                    Text("Add")
                                }).buttonStyle(.bordered)
                            }
                        }
                        HStack {
                            Text("\(podcast.artistName)")
                            Spacer()
                        }
                        HStack {
                            Text("\(podcast.feedUrl)").font(.footnote)
                            Spacer()
                        }
                    }
                }
                Section("Episodes") {
                    ForEach(results, id:\.id) { item in
                        VStack(alignment: .leading) {
                            HStack {
                                AsyncImageView(url:item.artworkUrl, logo: false, width:100)
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
            let parser = PodcastParser()
            if let url = URL(string:podcast.feedUrl) {
                parser.parseRSSFeed(url: url, artwork: podcast.artworkUrl, nest:false) { items in
                    results = items
                }
            }
            isSubscribed = Subscriptions.shared.isSubscribed(podcast.feedUrl)
        }
    }
}

struct SearchView: View {
    @State var results:[PodcastDirectoryEntry] = []
    @State var searchText:String = ""
    @State var top = false
    @State var changes = 0
    @State var showingUnlock = false
    @State private var loadingIAP = false
    @State private var showAlert = false
    @State private var alertMessage:String = ""
    @EnvironmentObject var iap: InAppPurchase
    let directory = PodcastDirectorySearch()
    @Environment(\.dismissSearch) var dismissSearch
    @Environment(\.dismiss) var dismiss
    @Environment(\.isSearching) var isSearching
    
    var body: some View {
        NavigationStack {
                if !iap.unlocked() {
                    HStack {
                        Text("To add more than 3 podcasts, you need to")
                        Button("Unlock") {
                            if !loadingIAP {
                                InAppPurchase.shared.start {message in
                                    alertMessage = message
                                    showAlert = true
                                }
                                loadingIAP = true
                            }
                        }.buttonStyle(.borderedProminent)
                    }
                }
                List {
                    if top {
                        Section("Popular Podcasts") {
                        }
                    }
                    ForEach(results, id:\.id) { item in
                        VStack {
                            HStack {
                                AsyncImageView(url:item.artworkUrl, logo: false, width:100)
                                VStack(alignment: .leading) {
                                    Text("\(item.name)").font(.title)
                                }
                                Spacer()
                            }
                            HStack {
                                Text("\(item.artistName)")
                                Text("\(changes)").hidden()
                                Spacer()
                                let isSubscribed = Subscriptions.shared.isSubscribed(podcastId: item.id)
                                if isSubscribed {
                                    Button(action: {
                                        Subscriptions.shared.removePodcast(item)
                                        //isSubscribed = false
                                        changes = changes + 1
                                        dismiss()
                                    }, label: {
                                        Text("Remove")
                                    }).buttonStyle(.bordered)
                                } else {
                                    Button(action: {
                                        if top {
                                            directory.fetchTop(item) { entry, error in
                                                if let entry = entry {
                                                    if !iap.unlocked() && Subscriptions.shared.podcastCount() > 2 {
                                                        showingUnlock.toggle()
                                                    } else {
                                                        Subscriptions.shared.addPodcast(entry)
                                                        changes = changes + 1
                                                        dismiss()
                                                    }
                                                }
                                            }
                                        } else {
                                            if !iap.unlocked() && Subscriptions.shared.podcastCount() > 2 {
                                                showingUnlock.toggle()
                                            } else {
                                                Subscriptions.shared.addPodcast(item)
                                                changes = changes + 1
                                                dismiss()
                                            }
                                        }
                                        //isSubscribed = true
                                    }, label: {
                                        Text("Add")
                                    }).buttonStyle(.bordered)
                                }
                            }
                            HStack {
                                Text("\(item.feedUrl)").font(.footnote)
                                Spacer()
                            }
                        }
                    }
                }
                .navigationBarItems(trailing: Button("Close", action: { dismiss() }))
                .listStyle(.plain)
                .navigationTitle("Add Podcast")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $searchText, prompt:"Search for Podcasts")
                .onSubmit(of: .search) {
                    if startsWithValidURL(string:searchText) {
                        directory.fetchPodcasts(urlString: searchText) { (podcasts, error) in
                            if let first = podcasts?.first {
                                Subscriptions.shared.addPodcast(first)
                                changes = changes + 1
                                dismissSearch()
                                dismiss()
                            }
                        }
                    } else {
                        directory.fetchPodcasts(searchTerm: searchText) { (podcasts, error) in
                            if let error = error {
                                print("Error: \(error)")
                                return
                            }
                            if let podcasts = podcasts {
                                results = podcasts
                            } else {
                                print("No podcasts found.")
                            }
                        }
                        dismissSearch()
                        top = false
                    }
                }
                .onAppear {
                    top = true
                    directory.fetchPodcasts(searchTerm: "") { (podcasts, error) in
                        if let error = error {
                            print("Error: \(error)")
                            return
                        }
                        if let podcasts = podcasts {
                            results = podcasts
                        } else {
                            print("No podcasts found.")
                        }
                    }
                }
                .alert(isPresented: $showingUnlock) {
                    Alert(
                        title: Text("You can add up to three Podcasts for free"),
                        message: Text("To add more Podcasts, you need to Unlock!"),
                        primaryButton: .default(Text("Unlock")) {
                            if !loadingIAP {
                                iap.start {message in
                                    alertMessage = message
                                    showAlert = true
                                }
                                loadingIAP = true
                            }
                        },
                        secondaryButton: .cancel())
                }
                .alert(alertMessage, isPresented: $showAlert) {
                    Button("OK", role: .cancel) { loadingIAP = false }
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
