//
//  HTMLView.swift
//  VoiceFeed
//
//  Created by Emídio Cunha on 16/08/2023.
//

import Foundation
import SwiftUI
import WebKit

struct HTMLView: UIViewRepresentable {
    @Binding var dynamicHeight: CGFloat
    let htmlString: String
    let cssString: String = "body { font-family: -apple-system, BlinkMacSystemFont, \"Segoe UI\", Roboto, Helvetica, Arial, sans-serif, \"Apple Color Emoji\", \"Segoe UI Emoji\", \"Segoe UI Symbol\"; font-size: 12pt; background-color: white; color:black;  } a { color: blue; }"

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.isOpaque = true
        webView.backgroundColor = UIColor.white
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        var cleanString = htmlString
        cleanString = cleanString.contains("</a>") || cleanString.contains("</ul>") ? cleanString : cleanString.replacingOccurrences(of: "\n", with: "<br>")
        cleanString = insertNewlineBeforeHHMM(text: cleanString)
        let styledHTMLString = "<html><head><style>\(cssString)</style><meta name='viewport' content='width=device-width, shrink-to-fit=YES' initial-scale='1.0' maximum-scale='1.0' minimum-scale='1.0' user-scalable='no'></head><body>\(cleanString)</body></html>"
        uiView.loadHTMLString(styledHTMLString, baseURL: nil)
        //uiView.scrollView.isScrollEnabled = false
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
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

class Coordinator: NSObject, WKNavigationDelegate {
    let parent: HTMLView

    init(_ parent: HTMLView) {
        self.parent = parent
    }
    
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, navigationAction.navigationType == .linkActivated {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else {
            return nil
        }

        if navigationAction.targetFrame == nil || !navigationAction.targetFrame!.isMainFrame {
            UIApplication.shared.open(url)
        }

        return nil
    }
    
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

