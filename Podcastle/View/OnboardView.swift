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

// Shown when there are no subscribed podcasts. Refers to the toolbar buttons by icon,
// since their position varies (e.g. on iPhone Duo).
struct OnboardView: View {
    var addPodcast: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    // Rebuilt from Podcastle.icon's parts, which can't be loaded as an Image.
                    Image("app_icon_foreground")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .background(Color(red: 1.0, green: 0.231, blue: 0.188))
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                        .accessibilityHidden(true)
                    Text("Welcome to Podcastle")
                        .font(.title2.bold())
                }
                .padding(.top, 32)

                Button(action: addPodcast) {
                    Label("Add a Podcast", systemImage: "plus")
                        .frame(maxWidth: 320)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                VStack(alignment: .leading, spacing: 16) {
                    OnboardTip(systemImage: "plus",
                               text: "Search and add a Podcast to this list, the last episode of the podcast will download automatically.")
                    OnboardTip(systemImage: "ellipsis",
                               text: "For more options in the app, such as sending us feedback, looking at the app Log or clearing the local cache.")
                }
                .frame(maxWidth: 480)

                VStack(spacing: 8) {
                    Image("sample_row")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 480)
                    Text("Once you have an episode list, they will be grouped by Podcast. You tap once to select it as the current episode, and you can delete them individually by swipping left.")
                }

                VStack(spacing: 8) {
                    Text("Podcastle is now completely free, and also an Open Source project that you can contribute to!")
                    Link("github.com/emidiocunha/podcastle", destination: URL(string: "https://github.com/emidiocunha/podcastle")!)
                }
                .multilineTextAlignment(.center)
            }
            .font(.footnote)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            Spacer(minLength: 128)
        }
    }
}

// One toolbar button, shown by its icon, and what it does.
private struct OnboardTip: View {
    var systemImage: String
    var text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color(.secondarySystemFill)))
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#Preview {
    OnboardView(addPodcast: {})
}

#Preview("Dark") {
    OnboardView(addPodcast: {})
        .preferredColorScheme(.dark)
}
