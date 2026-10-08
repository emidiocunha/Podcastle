//
//  TranscriberView.swift
//  Podcastle
//
//  Created by Emídio Cunha on 26/04/2025.
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
import NaturalLanguage

struct TranscriptView: View {
    @EnvironmentObject var transcriber:Transcriber
    @EnvironmentObject var player:PodcastPlayer
    @EnvironmentObject var subscriptions:Subscriptions
    @State var searchString = ""
    @State var limit = 10
    @State private var showDeleteConfirm = false
    @StateObject private var summarySpeaker = SummarySpeaker()

    var body: some View {
        VStack {
            Text("Transcript").font(.title2)
        }
        HStack {
            Spacer()
            Button {
                if transcriber.working {
                    transcriber.cancel()
                } else {
                    limit = Int.max
                    Task { await transcribe() }
                }
            } label: {
                Image(systemName: "waveform")
                Text(transcriber.working ? "Stop" : "Start")
            }.buttonStyle(.bordered)
            if !transcriber.working && transcriber.sentences.count > 0 {
                Spacer()
                Button {
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                    Text("Delete")
                }
                .buttonStyle(.bordered)
                .alert("Delete transcription?", isPresented: $showDeleteConfirm) {
                    Button("Delete", role: .destructive) {
                        transcriber.deleteTranscription()
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("This will permanently remove the current transcript.")
                }
                Spacer()
                ShareLink(item: transcriber.copyText()).buttonStyle(.bordered)
            }
            Spacer()
        }
        // Lazy so off-screen sentence rows skip layout entirely — this view sits inside
        // PlayerView's ScrollView, and the transcript can grow to hundreds of rows while
        // actively transcribing. A plain VStack here forced a full layout pass of every
        // sentence on every single append, which is what made live updates feel sluggish.
        LazyVStack(alignment: .leading, spacing: 8.0) {
            if !transcriber.working && !transcriber.summary.isEmpty {
                VStack(alignment: .leading, spacing: 6.0) {
                    HStack {
                        Text("Summary").font(.headline)
                        Spacer()
                        Button(action: {
                            // Starting playback and speech at once would talk over
                            // the episode itself — pause it first. Stopping speech
                            // doesn't touch playback, so the user stays in control
                            // of resuming it themselves.
                            if !summarySpeaker.isSpeaking && player.isPlaying {
                                player.pause()
                            }
                            summarySpeaker.toggle(transcriber.summary, language: transcriber.language)
                        }) {
                            Image(systemName: summarySpeaker.isSpeaking ? "stop.circle.fill" : "play.circle.fill")
                                .font(.title2)
                        }
                    }
                    Text(transcriber.summary).font(.body)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color.white.opacity(0.08))
                .cornerRadius(8.0)
                .padding(.bottom, 8.0)
                .onDisappear { summarySpeaker.stop() }
            }
            if !transcriber.working {
                HStack {
                    Spacer()
                    TextField("", text:$searchString, prompt: Text("Search").foregroundColor(.gray)).onChange(of: searchString) {
                        transcriber.filter(searchString)
                    }.foregroundColor(.black).frame(height: 40).border(.white).background(.white).cornerRadius(8.0)
                    Spacer()
                }.onAppear {
                    UITextField.appearance().clearButtonMode = .whileEditing
                }.padding(.bottom, 12.0)
            }
            if transcriber.working {
                VStack(spacing: 20.0) {
                    HStack {
                        Spacer()
                        ProgressView().tint(.white).controlSize(.large)
                        Spacer()
                    }
                    HStack {
                        Spacer()
                        Text("\(transcriber.status)")
                        Spacer()
                    }
                }.padding(.top, 20.0).padding(.bottom, 20.0)
            }
            ForEach(transcriber.sentences.prefix(limit)) { sentence in
                HStack(alignment: .top) {
                    VStack {
                        Button {
                            player.absoluteSeek(sentence.timestamp)
                            if !player.isPlaying {
                                player.play()
                            }
                        } label: {
                            Text("\(sentence.timestamp.prettyPrintSeconds())").font(.headline)
                        }.buttonStyle(.bordered)
                    }
                    Text("\(sentence.sentence)").onTapGesture {
                        player.absoluteSeek(sentence.timestamp)
                        if !player.isPlaying {
                            player.play()
                        }
                    }.gesture(LongPressGesture(minimumDuration: 1.0).onEnded {_ in
                        UIPasteboard.general.string = sentence.sentence
                        let feedbackGenerator:UISelectionFeedbackGenerator? = UISelectionFeedbackGenerator()
                        feedbackGenerator?.prepare()
                        feedbackGenerator?.selectionChanged()
                    })
                }
                Divider()
            }
        }.padding().ignoresSafeArea(.keyboard, edges: .bottom)
        if !transcriber.working && limit < transcriber.sentences.count {
            HStack {
                Spacer()
                Button {
                    limit = Int.max
                } label: {
                    Text("More...")
                }.buttonStyle(.bordered)
                Spacer()
            }
        }
    }
    
    func transcribe() async {
        if let currentPodcast = player.currentPodcast {
            // Player.setPodcast's load() call already detected and set the
            // episode's language before this could ever run.
            let localUrl = currentPodcast.fullLocalUrl(.audio)!
            await transcriber.transcribe(localUrl)
        }
    }
}
