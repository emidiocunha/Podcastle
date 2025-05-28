# Podcastle

**Podcastle** is a lightweight, open-source podcast player for iOS focused on privacy, performance, and simplicity. It lets users subscribe, download, and transcribe episodes — all without ads, tracking, or telemetry.

Available on the App Store: https://apps.apple.com/us/app/podcastle/id6450795970

## ✨ Features

* 🔊 Play and manage podcasts with a clean SwiftUI interface
* ⬇️ Offline downloads with progress tracking
* ✍️ On-device transcription using `Speech` framework
* 📦 Background task handling via `BackgroundTasks`
* 🔐 100% privacy-focused — no analytics, ads, or data collection

## 🧑‍💻 Tech Stack

* Swift / SwiftUI
* SwiftData for persistence
* Speech framework for transcription
* URLSession and BackgroundTasks for background downloading

## 🚀 Getting Started

1. Clone the repo:

   ```bash
   git clone https://github.com/emidiocunha/Podcastle.git
   cd podcastle
   ```

2. Open `Podcastle.xcodeproj` in Xcode.

3. Run the app on a simulator or device (iOS 16+ recommended).

## 🔧 Configuration

Update the following identifiers in `PodcastleApp.swift` as needed for your app group:

```swift
public let kAppRefreshIdentifier = "com.mobyte.voicefeed.Refresh"
public let kBackgroundIdentifier = "com.mobyte.voicefeed.backgroundDownload"
```

Make sure to enable background modes and speech recognition in your app’s capabilities.

## 📬 Feedback

To give feedback, open the app and use the "Send Feedback" form — it will open your mail client.

Alternatively, you can open an [issue](https://github.com/emidiocunha/Podcastle/issues) here on GitHub.

## 📄 License

This project is licensed under the MIT License.

---

© 2025 Emídio Cunha. Made with ❤️ in Swift.
