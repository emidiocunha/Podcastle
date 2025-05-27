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

    var body: some View {
        VStack {
            Text("Transcript").font(.title2)
        }
        VStack(alignment: .leading, spacing: 8.0) {
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
        }.padding()
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
                    transcriber.deleteTranscription()
                } label: {
                    Image(systemName: "trash")
                    Text("Delete")
                }.buttonStyle(.bordered)
                Spacer()
                ShareLink(item: transcriber.copyText()).buttonStyle(.borderedProminent)
            }
            Spacer()
        }
    }
    
    func transcribe() async {
        transcriber.setup(subscriptions:subscriptions)
        if let currentPodcast = player.currentPodcast {
            let localUrl = currentPodcast.fullLocalUrl(.audio)!
            
            transcriber.setLanguage(detectLanguage())
            await transcriber.transcribe(localUrl)
        }
    }
    
    func detectLanguage() -> String {
        if let currentPodcast = player.currentPodcast {
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(currentPodcast.desc)
            
            if let languageCode = recognizer.dominantLanguage?.rawValue {
                let detectedLanguage = languageCode
                print("Detected language \(detectedLanguage)")
                return detectedLanguage
            }
        }
        return "en_US"
    }
}
