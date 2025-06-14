//
//  HTMLView.swift
//  Podcastle
//
//  Created by Emídio Cunha on 16/08/2023.
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
import WebKit

// A SwiftUI wrapper for WKWebView to display styled HTML with dynamic height support.
struct HTMLView: UIViewRepresentable {
    @Binding var dynamicHeight: CGFloat
    let htmlString: String
    let cssString: String = "body { font-family: -apple-system, BlinkMacSystemFont, \"Segoe UI\", Roboto, Helvetica, Arial, sans-serif, \"Apple Color Emoji\", \"Segoe UI Emoji\", \"Segoe UI Symbol\"; font-size: 12pt; background-color: white; color:black;  } a { color: blue; }"

    // Creates and configures the WKWebView.
    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.isOpaque = true
        webView.backgroundColor = UIColor.white
        webView.navigationDelegate = context.coordinator
        return webView
    }

    // Updates the WKWebView with new HTML content.
    func updateUIView(_ uiView: WKWebView, context: Context) {
        var cleanString = htmlString
        cleanString = cleanString.contains("</a>") || cleanString.contains("</ul>") ? cleanString : cleanString.replacingOccurrences(of: "\n", with: "<br>")
        cleanString = insertNewlineBeforeHHMM(text: cleanString)
        let styledHTMLString = "<html><head><style>\(cssString)</style><meta name='viewport' content='width=device-width, shrink-to-fit=YES' initial-scale='1.0' maximum-scale='1.0' minimum-scale='1.0' user-scalable='no'></head><body>\(cleanString)</body></html>"
        uiView.loadHTMLString(styledHTMLString, baseURL: nil)
        //uiView.scrollView.isScrollEnabled = false
    }
    
    // Creates the coordinator to handle navigation.
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    // Inserts <br> before each time pattern (HH:MM) in the text.
    func insertNewlineBeforeHHMM(text: String) -> String {
        let pattern = #"\b\d{2}:\d{2}\b"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(location: 0, length: text.utf16.count)
        
        var modifiedText = text
        var offset = 0
        
        let matches = regex.matches(in: text, options: [], range: range)
        for match in matches {
            let start = match.range.lowerBound
            let end = match.range.upperBound
            
            let insertIndex = text.index(text.startIndex, offsetBy: start + offset)
            modifiedText.insert(contentsOf:"<br>", at: insertIndex)
            offset += 4
        }
        
        return modifiedText
    }
}

// WKNavigationDelegate implementation to handle links and window behavior.
class Coordinator: NSObject, WKNavigationDelegate {
    let parent: HTMLView

    init(_ parent: HTMLView) {
        self.parent = parent
    }
    
    // Opens external links in Safari and cancels in-web navigation.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, navigationAction.navigationType == .linkActivated {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    // Opens new target windows (e.g., target="_blank") in Safari.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else {
            return nil
        }

        if navigationAction.targetFrame == nil || !navigationAction.targetFrame!.isMainFrame {
            UIApplication.shared.open(url)
        }

        return nil
    }
    
    // Evaluates and updates the dynamic height after content loads.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("document.documentElement.scrollHeight", completionHandler: { (height, error) in
            DispatchQueue.main.async {
                //webView.invalidateIntrinsicContentSize()
                //webView.frame.size.height = height as! CGFloat
                if height != nil  {
                    self.parent.dynamicHeight = height as! CGFloat
                }
            }
        })
    }
}

