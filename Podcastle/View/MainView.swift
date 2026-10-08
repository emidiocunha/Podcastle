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
import UIKit
import Foundation
import BackgroundTasks
import StoreKit
import SwiftData

// UIView subclass that owns text layout; sizeThatFits is the single source of truth for SwiftUI.
private final class FloatingLabelView: UIView {
    static let imageSize: CGFloat = 100
    static let spacing: CGFloat = 8

    private let textView = UITextView()

    var text: String = "" {
        didSet { textView.text = text; invalidateIntrinsicContentSize() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.isSelectable = false
        textView.isUserInteractionEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.lineBreakMode = .byTruncatingTail
        textView.textContainer.maximumNumberOfLines = 7
        textView.textContainer.exclusionPaths = [
            UIBezierPath(rect: CGRect(x: 0, y: 0,
                                     width: Self.imageSize + Self.spacing,
                                     height: Self.imageSize))
        ]
        textView.font = UIFont.preferredFont(forTextStyle: .title1)
        textView.textColor = UIColor.label
        addSubview(textView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        textView.frame = bounds
    }

    // SwiftUI calls this to determine the view's size. We measure the text at the proposed
    // width so the text container wraps correctly, then return the real content height.
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let w = size.width > 0 ? size.width : UIScreen.main.bounds.width
        textView.frame.size.width = w
        let measured = textView.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude))
        return CGSize(width: w, height: max(measured.height, Self.imageSize))
    }

    override var intrinsicContentSize: CGSize {
        sizeThatFits(CGSize(width: bounds.width, height: 0))
    }
}

private struct FloatingTitleView: UIViewRepresentable {
    let title: String

    func makeUIView(context: Context) -> FloatingLabelView {
        let v = FloatingLabelView()
        v.text = title
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return v
    }

    func updateUIView(_ uiView: FloatingLabelView, context: Context) {
        if uiView.text != title { uiView.text = title }
    }
}

struct PodcastItemView: View {
    var item:GroupedEpisodeList
    @EnvironmentObject var player:PodcastPlayer
    @EnvironmentObject var transcriber:Transcriber
    @State var showTranscriberAlert:Bool = false

    var body: some View {
        VStack(alignment: .leading) {
            if item.children != nil {
                ZStack(alignment: .topLeading) {
                    FloatingTitleView(title: item.episode.title)
                    AsyncImageView(url: item.episode.artwork, logo: false, width: 100)
                        .frame(width: 100, height: 100)
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
        
            if let progress = downloadStatus.progress(URL(string:item.audio)!) {
                // Download in progress — background tasks write to a temp file so
                // fileSize() returns "" the whole time; check this before fileSize.
                ProgressBarView(progress:progress, title: "")
                .onTapGesture {
                    Task { await downloads.cancelDownload(item.audio) }
                }
            } else if item.fileSize(.audio).count == 0 {
                Button {
                    Task { await downloads.startDownload(item) }
                } label: {
                    Label("Download", systemImage: "arrow.down")
                }.buttonStyle(.borderless)
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
    
struct PendingPodcastRow: View {
    var directory: Directory
    @EnvironmentObject var subscriptions: Subscriptions

    var body: some View {
        HStack {
            AsyncImageView(url: directory.artwork, logo: false, width: 60)
                .frame(width: 60, height: 60)
            VStack(alignment: .leading) {
                Text(directory.name).font(.headline)
                if directory.fetchFailed {
                    Text("Couldn't load episodes").font(.subheadline).foregroundColor(.secondary)
                } else {
                    Text(directory.artist).font(.subheadline).foregroundColor(.secondary)
                }
            }
            Spacer()
            if directory.fetchFailed {
                Button {
                    Task { await subscriptions.removePodcast(directory) }
                } label: {
                    Image(systemName: "exclamationmark.triangle").foregroundColor(.orange)
                }.buttonStyle(.borderless)
            } else {
                ProgressView()
            }
        }
        .padding(.vertical, 8)
    }
}

struct PodcastListView: View {
    @EnvironmentObject var subscriptions: Subscriptions
    @State private var feed: [GroupedEpisodeList] = []
    @State private var pendingPodcasts: [Directory] = []
    @State private var showOnboard = false

    var body: some View {
        VStack {
            if showOnboard {
                OnboardView()
            } else {
                List {
                    ForEach(pendingPodcasts, id: \.persistentModelID) { dir in
                        PendingPodcastRow(directory: dir)
                    }
                    OutlineGroup(feed, children: \.children) { item in
                        VStack {
                            PodcastItemView(item: item)
                            PodcastItemActionsView(item: item.episode)
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
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name.episodesChangedNotification)) { _ in
            Task { await load() }
        }
        .task {
            await load()
        }
    }

    func load() async {
        feed = await subscriptions.loadFeed()
        pendingPodcasts = await subscriptions.loadEmptyDirectories()
        showOnboard = feed.isEmpty && pendingPodcasts.isEmpty
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
    @State private var presentationDetent = PresentationDetent.height(144.0)
    @State var themeColor = Color.clear
    @State var title = "Podcastle"
    // Global on/off for the BGProcessingTask that transcribes downloaded episodes
    // in the background (see PodcastleApp's scheduleTranscriptionRefresh). The
    // shared key/default are registered at launch so AppDelegate reads the same
    // value this switch controls. Off by default — the one-time onboarding prompt
    // below is what turns it on.
    @AppStorage(kBackgroundTranscriptionEnabledKey) var backgroundTranscriptionEnabled = false
    @AppStorage(kBackgroundTranscriptionOnboardingShownKey) private var backgroundTranscriptionOnboardingShown = false
    @State private var showBackgroundTranscriptionOnboarding = false
    // Auto-advance to the most recent unplayed downloaded episode when the
    // current one finishes (see PodcastPlayer's end-of-playback handler). On by
    // default — unlike background transcription, this doesn't cost battery, so
    // there's no onboarding prompt gating it.
    @AppStorage(kContinuePlayingEnabledKey) var continuePlayingEnabled = true
  
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
                                Button(action: {
                                    if let url = URL(string: "https://www.alimentestaideia.pt/Donation") {
                                        UIApplication.shared.open(url)
                                    }
                                }) {
                                    Label("Donate", systemImage: "heart.fill")
                                }
                                Button(action: { showingLog.toggle() }) {
                                    Label("View Log", systemImage: "list.bullet.rectangle.portrait")
                                }
                                Button(action: {
                                    showingClearCacheAlert.toggle()
                                }) {
                                    Label("Clear Cache", systemImage: "trash")
                                }
                                Toggle(isOn: $backgroundTranscriptionEnabled) {
                                    Label("Background Transcription", systemImage: "waveform.badge.mic")
                                }
                                Toggle(isOn: $continuePlayingEnabled) {
                                    Label("Continue Playing", systemImage: "forward.end.fill")
                                }
                            } label: {
                                Label("More", systemImage: "ellipsis")
                            }
                        }
                    }
                    .sheet(isPresented:$showingPlayer) {
                        PlayerView(themeColor:$themeColor, title:$title, detent:$presentationDetent)
                            .presentationDetents ([.large, .height(144)], selection:$presentationDetent)
                            .presentationBackground(.black)
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
.alert(isPresented: $showingClearCacheAlert) {
                                Alert(
                                    title: Text("Confirm Clear Cache"),
                                    message: Text("This will delete every image and audio file"),
                                    primaryButton: .destructive(Text("Continue")) {
                                        imageCache.prune(true)
                                    },
                                    secondaryButton: .cancel())
                            }
                            // Alongside showingClearCacheAlert above, not on the
                            // NavigationStack that presents this sheet — an alert
                            // and this sheet both trying to present from the same
                            // underlying view controller is a real conflict (not a
                            // timing one: a delay didn't fix it) that left the
                            // sheet simply never appearing. Attached here, inside
                            // the sheet's own content, it presents from the
                            // sheet's own hosting controller instead, same as
                            // showingClearCacheAlert already does safely.
                            .task {
                                // Asked once, ever, regardless of the answer — the
                                // More menu switch covers changing your mind
                                // either way after this.
                                if !backgroundTranscriptionOnboardingShown {
                                    showBackgroundTranscriptionOnboarding = true
                                }
                            }
                            .alert("Background Transcription", isPresented: $showBackgroundTranscriptionOnboarding) {
                                Button("Enable") {
                                    backgroundTranscriptionEnabled = true
                                    backgroundTranscriptionOnboardingShown = true
                                }
                                Button("Not Now", role: .cancel) {
                                    backgroundTranscriptionOnboardingShown = true
                                }
                            } message: {
                                Text("Podcastle can now transcribe your podcasts in the background, and also provide a summary of the contents. Would you like to enable it?\n\nCaution: this will consume more battery, and you can always disable it later in the More menu.")
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
        .onReceive(NotificationCenter.default.publisher(for: .openPlayerNotification)) { _ in
            // AppDelegate already loaded the tapped notification's episode into
            // `player` by the time this fires — just bring the sheet up so the
            // user actually sees it instead of landing on the collapsed mini player.
            showingPlayer = true
            presentationDetent = .large
        }
        .onChange(of: backgroundTranscriptionEnabled) { _, enabled in
            // Submits a request as soon as it's turned on, rather than waiting for
            // the next launch/backgrounding to do it — otherwise an app that's
            // killed instead of backgrounded would never have one queued.
            // Turning it off cancels any already-queued request (the scheduler
            // does that itself when it sees the setting is off).
            AppDelegate.scheduleTranscriptionRefresh()
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
