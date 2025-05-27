//
//  ManagePodcastsView.swift
//  Podcastle
//
//  Created by Emídio Cunha on 21/11/2023.
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

import SwiftUI
import SwiftData
import Foundation

struct ManagePodcastsView: View {
    @EnvironmentObject var subscriptions: Subscriptions
    @Environment(\.dismissSearch) var dismissSearch
    @Environment(\.dismiss) var dismiss
    @State var results: [Directory] = []
    
    var body: some View {
        NavigationStack {
            List {
                ForEach(results, id:\.id) { item in
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
                            Button(action: {
                                Task {
                                    await subscriptions.removePodcast(item)
                                }
                                dismiss()
                            }, label: {
                                Text("Remove")
                            }).buttonStyle(.bordered)
                        }
                        HStack {
                            Text("\(item.feed)").font(.footnote)
                            Spacer()
                        }
                    }
                }
            }
            .navigationBarItems(trailing: Button("Close", action: { dismiss() }))
            .listStyle(.plain)
            .navigationTitle("Podcast Subscriptions")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                results = await subscriptions.podcastDirectory() ?? []
            }
        }
    }
}

struct ManagePodcastsView_Previews: PreviewProvider {
    static var previews: some View {
        ManagePodcastsView()
    }
}
