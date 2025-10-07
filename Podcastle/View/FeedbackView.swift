//
//  FeedbackView.swift
//  Podcastle
//
//  Created by Emídio Cunha on 17/11/2023.
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

struct FeedbackView: View {
    private let commentsLabel = "Comments and suggestions"
    @State private var comments = ""
    @State private var email = ""
    @FocusState var isFocused:Bool
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
            ScrollView {
                Text("Write us your opinion, suggestions, or problems with the app!")
                TextField("e-mail (optional)", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal)
                    .focused($isFocused)
                TextField(commentsLabel, text:$comments, axis: .vertical)
                    .lineLimit(4, reservesSpace: true)
                    .textFieldStyle(.roundedBorder)
                    .padding()
                Button {
                    sendComments()
                } label: {
                    Text("Send").frame(width:240)
                }.buttonStyle(.bordered).padding()
            }
            .onAppear{
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5){
                    isFocused = true
                }
            }
            .navigationTitle("Feedback")
            .navigationBarItems(trailing: Button("Close", action: { dismiss() }))
        }
    }
    
    func sendComments() {
        guard comments != commentsLabel else { return }

        /*let subject = "Feedback for Podcastle"
        let toEmail = "feedback@example.com" // Replace with actual feedback email address
        let body = """
        \(comments)

        --
        Sent from Podcastle
        \(email.isEmpty ? "" : "\nEmail: \(email)")
        """

        let urlString = "mailto:\(toEmail)?subject=\(subject)&body=\(body)"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        
        if let url = URL(string: urlString) {
            UIApplication.shared.open(url)
        }*/
        
        Task {
            let feedback = Feedback()
            
            try! await feedback.sendFeedback(contact: email, message: comments)
        }
        
        dismiss()
    }
}

struct Feedback {
    struct FeedbackPayload: Codable {
      let contact: String?
      let message: String
      let appVersion: String
      let os: String
      let locale: String
    }

    func sendFeedback(contact: String?, message: String) async throws {
      let payload = FeedbackPayload(
        contact: contact,
        message: message,
        appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
        os: "iOS \(await UIDevice.current.systemVersion)",
        locale: Locale.current.identifier
      )
      var req = URLRequest(url: URL(string: "https://feedback.mobyte.app")!)
      req.httpMethod = "POST"
      req.addValue("application/json", forHTTPHeaderField: "Content-Type")
      req.httpBody = try JSONEncoder().encode(payload)
      let (_, resp) = try await URLSession.shared.data(for: req)
      guard (resp as? HTTPURLResponse)?.statusCode == 204 else { throw URLError(.badServerResponse) }
    }
}

struct Feedback_Previews: PreviewProvider {
    static var previews: some View {
        FeedbackView()
    }
}
