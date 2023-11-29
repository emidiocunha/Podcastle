//
//  PlayerView.swift
//  VoiceFeed
//
//  Created by Emídio Cunha on 16/06/2023.
//

import Foundation
import SwiftUI
import Speech
import WebKit

struct PlayerControlsView: View {
    @EnvironmentObject var player: PodcastPlayer
    let backgroundColor: Color
    
    var body: some View {
        HStack {
            Spacer()
            Button(action: {
                if player.isPlaying {
                    player.seek(-30)
                }
            }) {
                Image(systemName: "gobackward.30")
                    .font(.system(size: 40))
                    .foregroundColor(.white)
            }
            Spacer()
            ZStack {
                if player.currentPodcast != nil {
                    CircularProgressView(progress: Subscriptions.shared.timeLeft(player.currentPodcast!), backgroundColor: backgroundColor).frame(width:60, height:60)
                }
                Button(action: {
                    if player.isPlaying {
                        player.pause()
                    } else {
                        player.play()
                    }
                }) {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 36))
                        .foregroundColor(.white)
                }
            }
            Spacer()
            Button(action: {
                if player.isPlaying {
                    player.seek(30)
                }
            }) {
                Image(systemName: "goforward.30")
                    .font(.system(size: 40))
                    .foregroundColor(.white)
            }
            Spacer()
        }
    }
}

struct PlayerFileView: View {
    @EnvironmentObject var player: PodcastPlayer
    
    var body: some View {
        Divider()
        VStack {
            Text("Audio File").font(.title2)
        }
        VStack(alignment: .leading) {
            HStack {
                Spacer()
                if player.currentPodcast != nil {
                    Text(player.currentPodcast!.fileSize(.audio))
                    Spacer()
                    if let url = player.audioFileURL() {
                        ShareLink(item: url).buttonStyle(.bordered)
                    }
                }
                Spacer()
            }
        }
    }
}

struct PlayerProgressView: View {
    @EnvironmentObject var player:PodcastPlayer
    @State var progress = 0.0
    @State var isEditing = false
    
    var body: some View {
        VStack {
            Slider(value:$progress, in:0...player.duration, onEditingChanged: { editing in
                if !editing {
                    player.absoluteSeek(progress)
                }
                if !editing {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        isEditing = editing
                    }
                } else {
                    isEditing = editing
                }
            })
            .padding(20)
            .tint(.white)
            HStack {
                Text("\(player.prettyPrintSeconds(player.progress))")
                    .font(.body)
                Spacer()
                let s = stringForRate(player.rate())
                Menu("\(s)x") {
                    ForEach(0..<5) { rate in
                        let r = Float(1.0) + Float(rate) * Float(0.25)
                        let s = stringForRate(r)
                        Button("\(s)x", action: { player.setRate(r) })
                    }
                }
                Spacer()
                Text("-\(player.prettyPrintSeconds(player.duration-player.progress))").font(.body)
            }.padding(.leading, 20).padding(.trailing, 20)
        }
        .onChange(of: player.progress) { newValue in
            if progress != player.progress && !isEditing {
                progress = player.progress
            }
        }
        /*.onChange(of: player.progress) {
            if progress != player.progress && !isEditing {
                progress = player.progress
            }
        }*/
        .onAppear() {
            progress = player.progress
        }
    }
    
    func stringForRate(_ rate:Float) -> String {
        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        formatter.numberStyle = .decimal
        return formatter.string(for: rate) ?? ""
    }
}

struct PlayerFullHeaderView: View {
    @EnvironmentObject var player:PodcastPlayer
    
    var body: some View {
        VStack {
            Spacer(minLength: 20)
            AsyncImageView(url:player.podcast()?.artworkUrl ?? "", logo: false, width:300)
            HStack {
                Text("\(player.title)").font(.title3)
                Spacer()
            }.padding(.leading, 20).padding(.trailing, 20)
            Spacer()
            HStack {
                if player.currentPodcast != nil {
                    Text(player.currentPodcast!.date, style:.date)
                    Spacer()
                    Text(player.currentPodcast!.fileSize(.audio))
                }
            }.padding(.leading, 20).padding(.trailing, 20)
            Spacer()
        }
    }
}

struct PlayerView: View {
    @Namespace var bottomID
    @StateObject var player: PodcastPlayer = PodcastPlayer.shared
    @State private var backgroundColor: Color = .black
    @State private var details = 0
    @State private var webViewHeight: CGFloat = .zero
    @State private var podcastNotes:AttributedString? = nil
    
    var body: some View {
        GeometryReader { proxy in
            ScrollViewReader { scroll in
                ScrollView {
                    if proxy.size.height == 128 {
                        HStack {
                            Text("\(player.title)").font(.body).padding().lineLimit(1)
                            Spacer()
                        }
                        PlayerControlsView(backgroundColor:backgroundColor)
                    } else {
                        VStack(alignment: .center) {
                            Spacer(minLength: 20)
                            PlayerFullHeaderView()
                            PlayerControlsView(backgroundColor:backgroundColor)
                            PlayerProgressView()
                            Spacer(minLength: 10)
                            if podcastNotes != nil {
                                ZStack {
                                    Rectangle()
                                        .cornerRadius(8.0)
                                        .padding(20)
                                    Text(podcastNotes!)
                                        .font(.system(size: 16))
                                        .foregroundColor(.black)
                                        .background(.white)
                                        .padding(28)
                                }
                            }
                            Spacer()
                            TranscriptView()
                            Spacer()
                            PlayerFileView()
                            Spacer(minLength: 20).id("bottom")
                        }
                    }
                }
                .environmentObject(player)
                .foregroundColor(.white)
                .background(backgroundColor)
                .frame(maxWidth:.infinity)
                .animationsDisabled()
                .scrollDismissesKeyboard(.immediately)
                .onAppear {
                    if player.currentPodcast != nil {
                        backgroundColor = Color(ImageCache.shared.color[player.currentPodcast!.artworkUrl] ?? .black)
                        
                        loadNotes()
                    }
                }
                .onChange(of: player.currentPodcast) { newValue in
                    if player.currentPodcast != nil {
                        backgroundColor = Color(ImageCache.shared.color[player.currentPodcast!.artworkUrl] ?? .black)
                        webViewHeight = .zero
                        loadNotes()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name.episodesChangedNotification)) { object in
                        checkCurrentEpisode()
                    }
                //.environmentObject(player)
            }
        }
    }
    
    func loadNotes() {
        if let string:NSAttributedString = attributedStringFromHTML(htmlString: player.currentPodcast!.description) {
            if let attributedString = try? AttributedString(string, including: \.uiKit) {
                podcastNotes = attributedString
            }
        }
    }
    
    func attributedStringFromHTML(htmlString: String) -> NSAttributedString? {
        var cleanString = htmlString
        cleanString = cleanString.contains("</a>") || cleanString.contains("</ul>") ? cleanString : cleanString.replacingOccurrences(of: "\n", with: "<br>")

        guard let data = cleanString.data(using: .utf16) else {
            return nil
        }
        
        do {
            let attributedString = try NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html
                ],
                documentAttributes: nil
            )
            let newAttributedString = NSMutableAttributedString(attributedString: attributedString)
            let font = UIFont.preferredFont(forTextStyle: .body)
            newAttributedString.addAttributes([.font: font], range: NSRange(0..<newAttributedString.length))
            return newAttributedString
        } catch {
            print("Error converting HTML to NSAttributedString: \(error.localizedDescription)")
            return nil
        }
    }
    
    func checkCurrentEpisode() {
        if let episode = player.currentPodcast {
             if !Subscriptions.shared.checkEpisode(episode) {
                player.pause()
                player.reset()
            }
        }
    }

}

struct SheetView: View {
    @State private var presentationDetent = PresentationDetent.large
    @State private var showing = true
    
    var body: some View {
        ScrollView {
            
        }.sheet(isPresented: $showing) {
            PlayerView()
            .presentationDetents ([.large, .height(128)], selection:$presentationDetent)
            .presentationBackground(.black)
            .presentationBackgroundInteraction(.enabled)
            .presentationDragIndicator(.visible)
            .interactiveDismissDisabled()
         }
    }
}

struct Player_Previews: PreviewProvider {
    static var previews: some View {
        SheetView()
    }
}

