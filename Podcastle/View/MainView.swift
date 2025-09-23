//
//  MainView.swift
//  Podcastle
//
//  Created by Emídio Cunha on 07/06/2023.
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
import Foundation
import BackgroundTasks
import StoreKit
import SwiftData

struct PodcastItemView: View {
    var item:GroupedEpisodeList
    @EnvironmentObject var player:PodcastPlayer
    @EnvironmentObject var transcriber:Transcriber
    @State var showTranscriberAlert:Bool = false
    @State private var height: CGFloat?
    
    var body: some View {
        VStack(alignment: .leading) {
            if item.children != nil {
                HStack(alignment: .top) {
                    AsyncImageView(url:item.episode.artwork, logo: false, width:100)
                        .frame(width:100, height:100)
                    Text(item.episode.title).font(.title).frame(maxHeight:.infinity, alignment: .top).padding(EdgeInsets(top: -4, leading: 0, bottom: 0, trailing: 0))
                }
            }
            else
            {
                Text("\(item.episode.title)").font(.title2)
            }
            Text("\(item.episode.summary.removingHTMLTagsAndDecodingEntities())").frame(maxWidth: .infinity , alignment:.topLeading)
                .lineLimit(4)
                .multilineTextAlignment(.leading)
            Text("\(item.episode.link)").font(.footnote).foregroundColor(Color.gray).padding(.top, 8)
        }
        .onTapGesture {
            if player.currentPodcast != item.episode && transcriber.working {
                showTranscriberAlert = true
            } else {
                changeTo()
            }
        }
        .animation(.none, value: UUID())
        .alert(isPresented: $showTranscriberAlert) {
            Alert(
                title: Text("Transcribing in progress"),
                message: Text("If you change Podcast, it will be stopped."),
                primaryButton: .destructive(Text("Continue")) {
                    changeTo()
                },
                secondaryButton: .cancel()
            )
        }
    }
    
    func changeTo() {
        let p = player.isPlaying
        if p {
            player.pause()
        }
        if player.currentPodcast != item.episode {
            _ = player.setPodcast(item.episode)
        }
        if !p {
            player.play()
        }
    }
}

struct PodcastItemActionsView: View {
    var item:Episode
    @EnvironmentObject var downloads:Downloads
    @EnvironmentObject var downloadStatus:DownloadStatus
    @EnvironmentObject var player:PodcastPlayer
    
    var body: some View {
        HStack {
            Text("\(item.prettySinceDate())")
            Spacer()
        
            if item.fileSize(.audio).count == 0 {
                Button {
                    Task { await downloads.startDownload(item) }
                } label: {
                    Label("Download", systemImage: "arrow.down")
                }.buttonStyle(.borderless)
            } else if let progress = downloadStatus.progress(URL(string:item.audio)!) {
                 ProgressBarView(progress:progress, title: "")
                .onTapGesture {
                    Task { await downloads.cancelDownload(item.audio) }
                }
            } else {
                if (item.audio == player.currentPodcast?.audio && player.isPlaying) {
                    ProgressBarView(progress:0.0,
                                    title:"Playing...")
                } else {
                    let t = item.secondsLeft()
                    let p =  item.timeLeft()
                    
                    ProgressBarView(progress:p >= 0.0 && p <= 100.0 ? p : 0.0,
                                    title:t < 60 ? "Played" : t.prettyPrintSeconds())
                }
            }
            Spacer()
            if downloadStatus.progress(URL(string:item.audio)!) == nil {
                Button(action: {
                    Task {
                        if player.isPlaying && player.currentPodcast == item {
                            player.pause()
                        } else if player.currentPodcast == item {
                            player.play()
                        } else {
                            if player.setPodcast(item) {
                                player.play()
                                //presentationDetent = PresentationDetent.large
                            } else {
                                await downloads.startDownload(item)
                            }
                        }
                    }
                }, label: {
                    Image(systemName: player.isPlaying &&  player.currentPodcast == item ? "pause" : "play")
                        .font(.system(size: 24))
                        .foregroundColor(.accentColor)
                }).buttonStyle(.bordered)
            } else {
                Button(action: {
                    Task { await downloads.cancelDownload(item.audio) }
                }, label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 24))
                        .foregroundColor(.accentColor)
                }).buttonStyle(.bordered)
            }
        }
    }
}
    
struct PodcastListView: View {
    @EnvironmentObject var subscriptions: Subscriptions
    @State private var feed: [GroupedEpisodeList] = []
    @State private var showOnboard = false
    
    var body: some View {
        VStack {
            if showOnboard {
                OnboardView()
            } else {
                VStack {
                    List(feed, children: \.children) {
                        item in
                        VStack {
                            PodcastItemView(item: item)
                            PodcastItemActionsView(item: item.episode)
                            // Adding space at the bottom to account for permanent sheet.
                            if item.id == feed.last?.id {
                                Spacer(minLength: 144)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                //subscriptions.deletePodcastEpisode(item)
                            } label: {
                                Label("Remove", systemImage: "trash.fill")
                            }
                            .tint(.red)
                        }
                        .padding(.top, 8).padding(.bottom, 9)
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name.episodesChangedNotification)) { object in
            Task {
                await load()
            }
        }
        .task {
            Task {
                await load()
            }
        }
    }
    
    func load() async {
        feed = await subscriptions.loadFeed()
        showOnboard = feed.count == 0 ? true : false
    }
}

struct MainView: View {
    @Environment(\.scenePhase) var scenePhase
    @EnvironmentObject var subscriptions: Subscriptions
    @EnvironmentObject var downloads: Downloads
    @EnvironmentObject var imageCache: ImageCache
    @EnvironmentObject var player: PodcastPlayer
    @EnvironmentObject var file: PodcastFile
    @State var showingSearch = false
    @State var showingPlayer = true
    @State var showingLog = false
    @State var showingClearCacheAlert = false
    @State var showingFeedback = false
    @State var showingSubscriptions = false
    @State var showingTipJar = false
    @State private var presentationDetent = PresentationDetent.height(144.0)
    @State var themeColor = Color.clear
    @State var title = "Podcastle"
  
    var body: some View {
        NavigationStack {
            ZStack(alignment: Alignment.top) {
                PodcastListView()
                    .listStyle(.plain)
                    //.navigationTitle(title)
                    //.navigationBarTitleDisplayMode(.automatic)
                    .refreshable {
                        Task {
                            await subscriptions.refresh()
                        }
                    }
                    //.toolbarBackground(themeColor, for: .navigationBar)
                    //.toolbarBackground(.visible, for: .navigationBar)
                    //.toolbarColorScheme(.dark, for: .navigationBar)
                    .toolbar {
                        ToolbarItemGroup(placement: .navigationBarLeading) {
                            Button(action: { showingSearch.toggle() }) {
                                Label("Add Podcast", systemImage: "plus")
                            }
                        }
                        ToolbarItemGroup(placement: .navigationBarTrailing) {
                            Menu {
                                Button(action: { showingFeedback.toggle() }) {
                                    Label("Send Feedback", systemImage: "hand.thumbsup")
                                }
                                Button(action: { showingSubscriptions.toggle() }) {
                                    Label("Manage Podcasts", systemImage: "checklist")
                                }
                                Button(action: { showingTipJar.toggle() }) {
                                    Label("Tip Jar", systemImage: "heart.fill")
                                }
                                Button(action: { showingLog.toggle() }) {
                                    Label("View Log", systemImage: "list.bullet.rectangle.portrait")
                                }
                                Button(action: {
                                    showingClearCacheAlert.toggle()
                                }) {
                                    Label("Clear Cache", systemImage: "trash")
                                }
                            } label: {
                                Label("More", systemImage: "ellipsis")
                            }
                        }
                    }
                    .sheet(isPresented:$showingPlayer) {
                        PlayerView(themeColor:$themeColor, title:$title, detent:$presentationDetent)
                            .presentationDetents ([.large, .height(144)], selection:$presentationDetent)
                            //.presentationBackground(.black)
                            .presentationBackgroundInteraction(.enabled)
                            .presentationDragIndicator(.visible)
                            .interactiveDismissDisabled()
                            .environmentObject(player)
                            .environmentObject(file)
                            .sheet(isPresented: $showingSearch) {
                                SearchView()
                                    .presentationDetents([.large])
                            }
                            .sheet(isPresented: $showingLog) {
                                LogView()
                                    .presentationDetents([.large])
                            }
                            .sheet(isPresented: $showingFeedback) {
                                FeedbackView()
                                    .presentationDetents([.large])
                            }
                            .sheet(isPresented: $showingSubscriptions) {
                                ManagePodcastsView()
                                    .presentationDetents([.large])
                            }
                            .sheet(isPresented: $showingTipJar) {
                                TipJarView()
                                    .presentationDetents([.medium])
                            }
                            .alert(isPresented: $showingClearCacheAlert) {
                                Alert(
                                    title: Text("Confirm Clear Cache"),
                                    message: Text("This will delete every image and audio file"),
                                    primaryButton: .destructive(Text("Continue")) {
                                        imageCache.prune(true)
                                    },
                                    secondaryButton: .cancel())
                            }
                    }
            }
        }
        .onChange(of: scenePhase) { oldScene, newScenePhase in
            switch newScenePhase {
            case .active:
                Task {
                    if await subscriptions.podcastCount() > 2 {
                        await MainActor.run {
                            if let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
                                AppStore.requestReview(in: scene)
                            }
                        }
                    }
                }
            case .inactive:
                print("Going inactive")
            case .background:
                print("Going into background")
            @unknown default:
                break
            }
        }
    }
}

// Example usage

struct MainView_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            MainView()
        }
    }
}
