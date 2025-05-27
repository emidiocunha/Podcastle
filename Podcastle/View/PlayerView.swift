//
//  PlayerView.swift
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
import Speech
import WebKit

struct PlayerControlsView: View {
    let backgroundColor: Color
    @EnvironmentObject var player:PodcastPlayer
    @StateObject private var audioObserver = AudioInterruptionObserver()
    @EnvironmentObject var progress:Progress
    
    var body: some View {
        HStack {
            Spacer()
            Button(action: {
                Task {
                    if player.isPlaying {
                        player.seek(-30)
                    }
                }
            }) {
                Image(systemName: "gobackward.30")
                    .font(.system(size: 40))
                    .foregroundColor(.white)
            }
            Spacer()
            ZStack {
                if player.currentPodcast != nil {
                    CircularProgressView(progress: timeLeft(), backgroundColor: backgroundColor).frame(width:60, height:60)
                }
                Button(action: {
                    Task {
                        if player.isPlaying {
                            player.pause()
                        } else {
                            player.play()
                        }
                    }
                }) {
                    Image(systemName: player.isPlaying && !audioObserver.isAudioInterrupted ? "pause.fill" : "play.fill")
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
    
    func timeLeft() -> Double {
        let d = player.duration
        
        return d != 0.0 ? (progress.value / d) * 100.0 : 0.0
    }
    
}

struct PlayerFileView: View {
    @EnvironmentObject var player:PodcastPlayer
    
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
                    if let url = player.currentPodcast?.fullLocalUrl(.audio) {
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
    @EnvironmentObject var file:PodcastFile
    @EnvironmentObject var progress:Progress
    @State var isEditing = false
    @State var rate:Float = 0.0
    
    var body: some View {
        VStack {
            Slider(value:$progress.value, in:0...player.duration, onEditingChanged: { editing in
                if !editing {
                    player.absoluteSeek(progress.value)
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
                Text("\(player.progress.prettyPrintSeconds())")
                    .font(.body.monospacedDigit())
                Spacer()
                let s = stringForRate(rate)
                Menu {
                    ForEach(0..<5) { r in
                        let rs = Float(1.0) + Float(r) * Float(0.25)
                        let s = stringForRate(rs)
                        Button("\(s)x", action: {
                            player.setRate(rs)
                            rate = rs
                        })
                    }
                } label: {
                    Button("\(s)x", action:{}).buttonStyle(.bordered)
                }
                Spacer()
                Text("-\(Double(player.duration - player.progress).prettyPrintSeconds())").font(.body.monospacedDigit())
            }.padding(.leading, 20).padding(.trailing, 20)
        }
/*        .onChange(of: player.progress) { oldValue, newValue in
            if progressValue != player.progress && !isEditing {
                progressValue = player.progress
                file.updateCurrentChapter(player.progress)
            }
        }*/
        .onChange(of: player.rate) { oldValue, newValue in
            rate = player.rate
        }
        .onAppear() {
            rate = player.rate
            //progressValue = player.progress
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
        VStack(spacing:20.0) {
            Spacer().frame(maxHeight: 20.0)
            if player.image != nil {
                Image(uiImage: player.image!)
                    .resizable()
                    .scaledToFit()
                    .cornerRadius(4)
                    .frame(maxWidth: 300)
                    .clipped()
            } else {
                AsyncImageView(url:player.currentPodcast?.artwork ?? "", logo: false, width:300)
            }
            HStack {
                Text("\(player.title)").font(.title3)
                Spacer()
            }.padding(.leading, 20).padding(.trailing, 20)
            HStack {
                if player.currentPodcast != nil {
                    Text(player.currentPodcast!.date, style:.date)
                    Spacer()
                    Text(player.currentPodcast!.fileSize(.audio))
                }
            }.padding(.leading, 20).padding(.trailing, 20)
        }
    }
}

struct PlayerChaptersView: View {
    @EnvironmentObject var file:PodcastFile
    @EnvironmentObject var player:PodcastPlayer
    
    var body: some View {
        VStack {
            if file.currentChapter != nil {
                //Spacer()
                let current = file.currentChapter!.prettyPrintChapterTitle(time:true)
                ForEach(file.id3v2file!.chapters(), id:\.id) { chapter in
                    HStack {
                        //Menu {
                        let s = chapter.prettyPrintChapterTitle(time:true)
                        if s == current {
                            Button("\(s)", action: { player.absoluteSeek(Double(chapter.startTime) / 1000.0) })
                                .buttonBorderShape(.capsule)
                                .buttonStyle(.borderedProminent)
                                .tint(.white)
                                .foregroundColor(.black)
                            
                        } else {
                            Button("\(s)", action: {
                                player.absoluteSeek(Double(chapter.startTime) / 1000.0)
                            }).buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                        }
                        Spacer()
                    }.padding(.leading, 20).padding(.trailing, 20)
                    if let u = chapter.chapterURL(), file.currentChapter == chapter {
                        HStack {
                            Link(u.absoluteString, destination: u).font(.footnote).padding(.leading, 20).padding(.trailing, 20)
                            Spacer()
                        }.padding(.top, 20).padding(.bottom, 20)
                    }
                    //} label: {
                    //    Button("\(s)", action:{}).buttonStyle(.bordered)
                    //}
                    
                }
                /*if let u = file.currentChapter!.chapterURL() {
                    Link(u.absoluteString, destination: u).font(.footnote).padding(.leading, 20).padding(.trailing, 20)
                }*/
                //Spacer()
            }
        }
    }
}

class Progress: ObservableObject {
    @Published var value: Double
    
    init(_ initialValue: Double = 0.0) {
        self.value = initialValue
    }
}

struct PlayerView: View {
    @Binding var themeColor: Color
    @Binding var title: String
    @Binding var detent: PresentationDetent
    @EnvironmentObject var player:PodcastPlayer
    @EnvironmentObject var file:PodcastFile
    @EnvironmentObject var subscriptions:Subscriptions
    @EnvironmentObject var imageCache:ImageCache
    @State private var backgroundColor: Color = .black
    @State private var podcastNotes:AttributedString? = nil
    @State private var forceRedraw = false
    @State private var timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()
    @StateObject var progress = Progress(0.0)
    
    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                ZStack(alignment: .top) {
                    Color.clear
                    if proxy.size.height > 128 || forceRedraw {
                        VStack(alignment: .center, spacing: 20.0) {
                            PlayerFullHeaderView()
                            PlayerControlsView(backgroundColor:backgroundColor)
                            PlayerProgressView()
                            PlayerChaptersView()
                            Text(podcastNotes ?? "")
                                .font(.system(size: 16))
                                .foregroundColor(.black)
                                .background(.white)
                                .padding(28)
                                .cornerRadius(8.0)
                                .background(
                                    RoundedRectangle(cornerRadius: 8).padding(20))
                                .onAppear {
                                    if forceRedraw { forceRedraw = false }
                                }
                            TranscriptView()
                            PlayerFileView()
                        }.opacity(1.0 - fader(proxy.size.height))
                    }
                    
                    VStack(alignment:.center) {
                        HStack {
                            Text("\(player.title)").font(.body).padding().lineLimit(1)
                            Spacer()
                        }
                        PlayerControlsView(backgroundColor:backgroundColor)
                    }.opacity(fader(proxy.size.height))
                }
            }
            .environmentObject(file)
            .environmentObject(progress)
            .foregroundColor(.white)
            .background(backgroundColor)
            .frame(maxWidth:.infinity)
            .animationsDisabled()
            .scrollDismissesKeyboard(.immediately)
            .onAppear {
                if player.currentPodcast != nil {
                    backgroundColor = Color(imageCache.color[player.currentPodcast!.artwork] ?? .black)
                    podcastNotes = notes()
                    forceRedraw = true
                    themeColor = backgroundColor
                    title = player.currentPodcast?.author ?? ""
                }
            }
            .onChange(of: player.currentPodcast) { oldValue, newValue in
                if player.currentPodcast != nil {
                    backgroundColor = Color(imageCache.color[player.currentPodcast!.artwork] ?? .black)
                    podcastNotes = notes()
                    forceRedraw = true
                    themeColor = backgroundColor
                    title = newValue?.author ?? ""
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name.episodesChangedNotification)) { object in
                Task {
                    await checkCurrentEpisode()
                }
            }
            .onReceive(timer) { _ in
                if (player.isPlaying) {
                    progress.value = player.progress
                }
            }
            .onChange(of: player.isPlaying) { _, newValue in
                if newValue {
                    timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()
                } else {
                    timer.upstream.connect().cancel()
                }
            }
            .onChange(of: detent) {
                themeColor = detent == .large ? .clear : backgroundColor
            }
        }
    }
    
    func fader(_ height:Double) -> Double {
        var r:Double = 2.0 - 1.0/128.0 * height
        
        if r < 0 {
            r = 0
        }
        
        return r
    }
    
    func notes() -> AttributedString? {
        if let string:NSAttributedString = attributedStringFromHTML(htmlString: player.currentPodcast!.desc) {
            if let attributedString = try? AttributedString(string, including: \.uiKit) {
                return attributedString
            }
        }
        return nil
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
    
    func checkCurrentEpisode() async {
        if let episode = player.currentPodcast {
            if await subscriptions.findEpisode(episode.audio) == nil {
                player.pause()
                player.reset()
            }
        }
    }

}

// Preview code

struct SheetView: View {
    @State var presentationDetent = PresentationDetent.large
    @State private var showing = true
    @State var themeColor: Color = .clear
    @State var title: String = ""
    
    var body: some View {
        ScrollView {
            
        }.sheet(isPresented: $showing) {
            PlayerView(themeColor:$themeColor, title:$title, detent:$presentationDetent)
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

