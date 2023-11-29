//
//  FeedbackView.swift
//  Podcastle
//
//  Created by Emídio Cunha on 17/11/2023.
//

import Foundation
import SwiftUI

struct FeedbackView: View {
    private let commentsLabel = "Comments and suggestions"
    @State private var comments = ""
    @State private var email = ""
    @FocusState var isEmailFocused:Bool
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
            ScrollView {
                Text("Write us your opinion, suggestions, or problems with the app!")
                TextField("email (optional)", text:$email).keyboardType(.emailAddress)
                    .textFieldStyle(.roundedBorder)
                    .padding()
                    .focused($isEmailFocused)
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
                    isEmailFocused = true
                }
            }
            .navigationTitle("Feedback")
        }
    }
    
    func sendComments() {
        let m = email
        let c = comments
        
        guard c != commentsLabel else { return }
        
        let s = "https://beacn.me/f?email=\(m)&feedback=PODCASTLE \(c)"
        let url = URL(string: s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)
        
        Task {
            try! String(contentsOf: url!, encoding: .utf8)
        }
        dismiss()
    }
}

struct Feedback_Previews: PreviewProvider {
    static var previews: some View {
        FeedbackView()
    }
}
