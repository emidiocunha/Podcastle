//
//  OnboardView.swift
//  Podcastle
//
//  Created by Emídio Cunha on 13/05/2025.
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

// This view is shown when the app has no subscribed podcasts
struct OnboardView: View {
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
                    Text("Start here to search and add a Podcast to this list, the last episode of the podcast will download automatically.")
                        .font(.footnote)
                        .padding()
                        .background(RoundedRectangle(cornerRadius: 10)
                        .fill(Color.yellow))
                    Spacer()
                    Text("For more options in the app, such as sending us feedback, looking at the app Log or clearing the local cache.")
                        .font(.footnote)
                        .padding()
                    Spacer()
                }
                Spacer()
                VStack {
                    Image("sample_row")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                    Text("Once you have an episode list, they will be grouped by Podcast. You tap once to select it as the current episode, and you can delete them individually by swipping left.").font(.footnote).padding()
                    Spacer()
                    Text("Podcastle is now completely free, and also an Open Source project that you can contribute to!").font(.footnote).padding()
                    Spacer()
                    Text("See more at http://github.com/emidiocunha/podcastle").font(.footnote).padding()
                    Spacer()
                }.padding(10)
                Spacer(minLength: 128)
            }
        }
    }
}
