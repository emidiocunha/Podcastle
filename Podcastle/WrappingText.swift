//
//  WrappingText.swift
//  VoiceFeed
//
//  Created by Emídio Cunha on 26/07/2023.
//

import Foundation
import SwiftUI
import UIKit

struct WrappingTextView: View {
    @State private var textHeight: CGFloat = .zero
    var text:String = ""
    
    var body: some View {
        /*GeometryReader { g in
            WrappingText(text:text, font:UIFont.preferredFont(forTextStyle: .title1), exclusionPaths: [UIBezierPath(rect: CGRect(x: 0, y: 0, width: 100, height: 100))]).frame(width:g.size.width, height:g.size.height)
        }*/
        WrappingText(height:$textHeight, text:text, font:UIFont.preferredFont(forTextStyle: .title1), exclusionPaths: [UIBezierPath(rect: CGRect(x: 0, y: 0, width: 100, height: 100))]).frame(height:textHeight)
    }
}

class WrappingTextHelper:NSObject, UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        //textView.sizeToFit()
    }
}

struct WrappingText: UIViewRepresentable {
    @Binding var height:CGFloat
    
    typealias UIViewType = UITextView
    
    private var text: String
    
    private var delegate = WrappingTextHelper()
    
    private let font: UIFont = UIFont.preferredFont(forTextStyle: .title1)
    private let textColor: UIColor
    private let textAlignment: NSTextAlignment
    private let exclusionPaths: [UIBezierPath]
    
    private let isEditable: Bool
    private let isSelectable: Bool
    private let autocorrectionType: UITextAutocorrectionType
    private let autocapitalizationType: UITextAutocapitalizationType
    
    private let textView:UITextView?
    
    init(height:Binding<CGFloat>,
         text: String,
         font: UIFont? = .systemFont(ofSize: 10),
         textColor: UIColor? = .black,
         textAlignment: NSTextAlignment = .left,
         exclusionPaths: [UIBezierPath],
         
         isEditable: Bool = false,
         isSelectable: Bool = false,
         autocorrectionType: UITextAutocorrectionType = .default,
         autocapitalizationType: UITextAutocapitalizationType = .sentences) {
        
        self._height = height
        self.text = text
        //self.font = font!
        self.textColor = textColor!
        self.textAlignment = textAlignment
        self.exclusionPaths = exclusionPaths
        
        self.isEditable = isEditable
        self.isSelectable = isSelectable
        
        self.autocorrectionType = autocorrectionType
        self.autocapitalizationType = autocapitalizationType
        self.textView = UITextView(frame: .zero)
    }
    
    func makeUIView(context: Context) -> UITextView {
        if let textView = textView {
            textView.backgroundColor = .clear
            
            textView.font = font
            textView.textColor = textColor
            textView.textAlignment = textAlignment
            textView.isSelectable = isSelectable
            textView.isEditable = false
            textView.textContainer.exclusionPaths = exclusionPaths
            
            textView.autocorrectionType = autocorrectionType
            textView.autocapitalizationType = autocapitalizationType
            textView.textContainerInset = .zero
            
            textView.isScrollEnabled = true
            //textView.translatesAutoresizingMaskIntoConstraints = true
            textView.text = text
            textView.textColor = .label
        }
        return textView ?? UITextView()
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        uiView.text = text
        uiView.font = font
        
        //DispatchQueue.main.sync {
        let fixedWidth = uiView.frame.size.width
        let newSize = uiView.sizeThatFits(CGSize(width: fixedWidth, height: CGFloat.greatestFiniteMagnitude))
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.height = newSize.height
            //print("\(self.height)")
        }
            
        //}
    }
}

class SelfSizingTextView: UITextView {
    private var preferredMaxLayoutWidth: CGFloat? {
        didSet {
            guard preferredMaxLayoutWidth != oldValue else { return }
            invalidateIntrinsicContentSize()
        }
    }
    
    override var attributedText: NSAttributedString! {
        didSet {
            invalidateIntrinsicContentSize()
        }
    }
    
    override var intrinsicContentSize: CGSize {
        guard let width = preferredMaxLayoutWidth else {
            return super.intrinsicContentSize
        }
        return CGSize(width: width, height: textHeightForWidth(width))
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        preferredMaxLayoutWidth = bounds.width
    }
}

private extension UIEdgeInsets {
    var horizontal: CGFloat { return left + right }
    var vertical: CGFloat { return top + bottom }
}

private extension UITextView {
    func textHeightForWidth(_ width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(attributedString: attributedText)
        let width = bounds.width - textContainerInset.horizontal
        let containerSize = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        let container = NSTextContainer(size: containerSize)
        let manager = NSLayoutManager()
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        container.lineFragmentPadding = textContainer.lineFragmentPadding
        container.lineBreakMode = textContainer.lineBreakMode
        _ = manager.glyphRange(for: container)
        let usedHeight = manager.usedRect(for: container).height
        return ceil(usedHeight + textContainerInset.vertical)
    }
}
