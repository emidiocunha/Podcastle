//
//  ContentView.swift
//  VoiceFeed
//
//  Created by Emídio Cunha on 07/06/2023.
//

import SwiftUI
import Foundation
import BackgroundTasks

struct PodcastItemView: View {
    var item:Podcast
    @EnvironmentObject var player:PodcastPlayer
    @State var showTranscriberAlert:Bool = false
    
    var body: some View {
        VStack(alignment: .leading) {
            if item.otherEpisodes != nil {
                ZStack(alignment:.top) {
                    WrappingTextView(text: item.title)
                    HStack(alignment:.top) {
                        AsyncImageView(url:item.artworkUrl, logo: false, width:100)
                            .frame(width:100, height:100)
                        Spacer()
                    }
                }
            }
            else {
                Text("\(item.title)").font(.title2)
            }
            Text("\(item.summary)").frame(maxWidth: .infinity, alignment: .topLeading)
                .lineLimit(4)
                .multilineTextAlignment(.leading)
            Spacer()
            Text("\(item.link)").font(.footnote).foregroundColor(Color.gray)
        }
        .onTapGesture {
            if player.currentPodcast != item && Transcriber.shared.working {
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
        if player.isPlaying {
            player.pause()
        }
        if player.currentPodcast != item {
            _ = player.setPodcast(item)
        }
    }
}

struct PodcastItemActionsView: View {
    var item:Podcast
    @ObservedObject private var downloads:Downloads = Downloads.shared
    @EnvironmentObject var subscriptions:Subscriptions
    @EnvironmentObject var player:PodcastPlayer
    
    var body: some View {
        HStack {
            Text("\(item.prettySinceDate())")
            Spacer()
            if item.fileSize(.audio).count != 0 {
                let t = subscriptions.secondsLeft(item)
                ProgressBarView(progress:subscriptions.timeLeft(item),
                            title:t < 60 ? "Played" :  player.prettyPrintSeconds(t))
            }
            if item.fileSize(.audio).count == 0 {
                if let download = downloads.downloadSet.first(where: {$0.url.absoluteString == item.audioUrl }) {
                //if downloads.downloadSet.contains(item.) {
                    ProgressBarView(progress:download.progress, title: "")
                    /*ProgressBarView(progress:downloads.downloads.first(where: {$0.url.absoluteString == item.id })?.progress ?? 0.0, title:"").
                     */
                        .onTapGesture {
                        downloads.cancelDownload(item.id)
                    }
                } else {
                    Button {
                        downloads.startDownload(item)
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }.buttonStyle(.borderless)
                }
            }
            Spacer()
            if !downloads.downloadSet.contains(where: {$0.url.absoluteString == item.audioUrl }) {
                Button(action: {
                    if player.isPlaying && player.currentPodcast == item {
                        player.pause()
                    } else {
                        if player.setPodcast(item) {
                            player.play()
                            //presentationDetent = PresentationDetent.large
                        } else {
                            downloads.startDownload(item)
                        }
                    }
                }, label: {
                    Image(systemName: player.isPlaying &&  player.currentPodcast == item ? "pause.circle" : "play.circle")
                        .font(.system(size: 24))
                        .foregroundColor(.accentColor)
                }).buttonStyle(.bordered)
            } else {
                Button(action: {
                    downloads.cancelDownload(item.id)
                }, label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 24))
                        .foregroundColor(.accentColor)
                }).buttonStyle(.bordered)
            }
        }.environmentObject(player)
    }
}
    
struct PodcastListView: View {
    @ObservedObject private var player:PodcastPlayer = PodcastPlayer.shared
    @StateObject private var subscriptions = Subscriptions.shared
    
    var body: some View {
        if subscriptions.feed.count > 0 {
            List(subscriptions.feed, children:\.otherEpisodes) {
                item in
                if item.id != "eof" {
                    VStack {
                        Spacer()
                        PodcastItemView(item: item)
                        PodcastItemActionsView(item: item)
                        Spacer()
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            subscriptions.deletePodcastEpisode(item)
                        } label: {
                            Label("Remove", systemImage: "trash.fill")
                        }
                        .tint(.red)
                    }
                } else {
                    Group {
                        VStack {
                        }.frame(height:128)
                    }.listRowSeparator(.hidden, edges: .bottom)
                }
            }.environmentObject(subscriptions)
                .environmentObject(player)
                .onAppear {
                    UITableViewCell.appearance().selectionStyle = .none
                    /*Task {
                     await subscriptions.refresh()
                     }*/
                }
        }
        else {
            OnboardView()
        }
    }
}

struct OnboardView: View {
    @State var loadingIAP = false
    @State private var showAlert = false
    @State private var alertMessage:String = ""
    
    var body: some View {
        ScrollView {
            VStack {
                HStack {
                    Image("left_arrow")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 64)
                        .padding(.leading, 8)
                    Spacer()
                    Image("left_arrow")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(x: -1, y: 1)
                        .frame(width: 64)
                        .padding(.trailing, 8)
                }
                HStack {
                    Spacer()
                    Text("Start here to search and add a Podcast to this list, the last episode of the podcast will download automatically.").font(.footnote).padding()                    .background(RoundedRectangle(cornerRadius: 10)
                        .fill(Color.yellow))
                    Spacer()
                    Text("For more options in the app, such as sending us feedback, looking at the app Log or clearing the local cache.").font(.footnote).padding()
                    Spacer()
                }
                Spacer()
                VStack {
                    Image("sample_row")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                    Text("Once you have an episode list, they will be grouped by Podcast. You tap once to select it as the current episode, and you can delete them individually by swipping left.").font(.footnote).padding()
                    if !InAppPurchase.shared.unlocked() {
                        Text("To add more than 3 podcast subscriptions, you need to unlock the app with the In-App Purchase available here").font(.footnote).padding()
                        HStack {
                            Spacer()
                            Button("Unlock") {
                                if !loadingIAP {
                                    InAppPurchase.shared.start {message in
                                        alertMessage = message
                                        showAlert = true
                                    }
                                    loadingIAP = true
                                }
                            }.buttonStyle(.borderedProminent)
                            Spacer()
                        }.alert(alertMessage, isPresented: $showAlert) {
                            Button("OK", role: .cancel) { loadingIAP = false }
                        }
                    }
                    Spacer()
                }.padding(10)
                Spacer(minLength: 128)
            }
        }
    }
}

struct MainView: View {
    @Environment(\.scenePhase) var scenePhase
    @StateObject var iap = InAppPurchase.shared
    @State var showingSearch = false
    @State var showingPlayer = false
    @State var showingLog = false
    @State var showingClearCacheAlert = false
    @State var showingFeedback = false
    @State var showingSubscriptions = false
    @State private var presentationDetent = PresentationDetent.height(128.0)
  
    var body: some View {
        NavigationStack {
            PodcastListView()   //.padding(.bottom, 128)
            .listStyle(.plain)
            .navigationTitle("Podcastle")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                Subscriptions.shared.sync()
                Task {
                    await Subscriptions.shared.refresh()
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarLeading) {
                    Button(action: { showingSearch.toggle() }) {
                        Label("Add Podcast", systemImage: "plus.circle")
                    }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Menu {
                        Button(action: { showingFeedback.toggle() }) {
                            Label("Send Feedback", systemImage: "hand.thumbsup")
                        }
                        Button(action: { showingSubscriptions.toggle() }) {
                            Label("Manage Subscriptions", systemImage: "checklist")
                        }
                        Button(action: { iap.restore() }) {
                            Label("Restore Purchases", systemImage: "purchased")
                        }
                        Button(action: { showingLog.toggle() }) {
                            Label("Log", systemImage: "list.bullet.rectangle.portrait")
                        }
                        Button(action: {
                            showingClearCacheAlert.toggle()
                            }) {
                            Label("Clear Cache", systemImage: "trash")
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented:$showingPlayer) {
                PlayerView()
                .presentationDetents ([.large, .height(128)], selection:$presentationDetent)
                .presentationBackground(.black)
                .presentationBackgroundInteraction(.enabled)
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled()
                //.environmentObject(accentColor)
                .sheet(isPresented: $showingSearch) {
                    SearchView()
                        .presentationDetents([.large])
                        .environmentObject(iap)
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
                .alert(isPresented: $showingClearCacheAlert) {
                    Alert(
                        title: Text("Confirm Clear Cache"),
                        message: Text("This will delete every image and audio file"),
                        primaryButton: .destructive(Text("Continue")) {
                            ImageCache.shared.prune(true)
                        },
                        secondaryButton: .cancel())
                }
            }
            
        }
        .onChange(of: scenePhase) { newScenePhase in
            // TODO: Investigate how to change this to not hide the player
            switch newScenePhase {
            case .active:
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    showingPlayer = true
                }
                Subscriptions.shared.load()
                break;
            case .inactive:
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    showingPlayer = false
                }
            case .background:
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    showingPlayer = false
                }
                break
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
