//
//  ManagePodcastsView.swift
//  Podcastle
//
//  Created by Emídio Cunha on 21/11/2023.
//

import SwiftUI
import Foundation

struct ManagePodcastsView: View {
    @State var results:[PodcastDirectoryEntry] = []
    @State var changes = 0
    let directory = Subscriptions.shared
    @Environment(\.dismissSearch) var dismissSearch
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
                List {
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
                                Button(action: {
                                    Subscriptions.shared.removePodcast(item)
                                    changes = changes + 1
                                    results = directory.podcastDirectory()
                                }, label: {
                                    Text("Remove")
                                }).buttonStyle(.bordered)
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
                .navigationTitle("Podcast Subscriptions")
                .navigationBarTitleDisplayMode(.inline)
                .onAppear {
                    results = directory.podcastDirectory()
                }
        }
    }
}

struct ManagePodcastsView_Previews: PreviewProvider {
    static var previews: some View {
        ManagePodcastsView()
    }
}
