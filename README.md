<div align="center">

  # Droid House

  ### **The Spatial Glass Companion for macOS & Android**

  *The app that made Apple executives sweat and shattered the Walled Garden once and for all.*

  <br />

  [![Release](https://img.shields.io/badge/Release-v1.3-0A84FF?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/festomanolo/droid-house/releases/tag/v1.3)
  [![Platform](https://img.shields.io/badge/Platform-macOS_13%2B_%7C_Android_10%2B-000000?style=for-the-badge&logo=android&logoColor=3DDC84)](https://github.com/festomanolo/droid-house)
  [![Swift](https://img.shields.io/badge/Swift-5.9-FA7343?style=for-the-badge&logo=swift&logoColor=white)](https://swift.org)
  [![Kotlin](https://img.shields.io/badge/Kotlin-Jetpack_Compose-7F52FF?style=for-the-badge&logo=kotlin&logoColor=white)](https://kotlinlang.org)
  [![License](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)](LICENSE)

  <br />

  <a href="assets/droid.ico">
    <img src="assets/droid-bg.png" width="160" alt="DroidHouse Icon" style="border-radius: 28px; box-shadow: 0 20px 40px rgba(0,0,0,0.5);" />
  </a>

</div>

---

> [!CAUTION]
> ### 🚨 **LEAKED SEC FILING: The Real Reason Tim Cook is Stepping Down as Apple CEO**
> 
> **Apple Boardroom — Cupertino, CA (3:42 AM)**
> 
> **Tim Cook:** *"Team, our ecosystem moat is impenetrable. Mac users are forced to buy a $1,200 iPhone every single year just for AirDrop, Universal Clipboard, and iMessage bubbles. Our hardware lock-in is infinite money printing."*
> 
> **Nolo (`@festomanolo`):** *"Hold my espresso."* ☕️
> 
> Suddenly, Nolo walks in and drops **DroidHouse** onto the Apple Executive Conference table.
> 
> Nolo plugs a $150 Android phone into a Mac Studio. Instantly:
> - ⚡ **60 FPS zero-latency screen + audio streaming** (AeroCast) blooms across macOS in a spatial glass window.
> - 📋 **Clipboard text copied on Android** magically pastes into Mac apps without touching a button.
> - 💬 **SMS & MMS messages** load with official iOS Messages green bubbles & double-tick delivery reports (`✓✓`).
> - 📁 **Remote files stream over ADB** faster than AirDrop could even scan for Bluetooth.
> 
> **Craig Federighi:** *(drops his hairbrush in shock)* *"My God... the spatial glass refraction... the spring animation physics... it's smoother than macOS Continuity!"*
> 
> **Tim Cook:** *(sweating heavily, adjusting glasses)* *"Wait, if Mac users can buy ANY Android phone in the world and still get 100% desktop continuity... why would anyone ever buy an iPhone again?!"*
> 
> **Nolo:** *"That's the neat part, Tim. They won't."*
> 
> 10 minutes later, the Apple Board voted unanimously to accept Tim Cook's early retirement. Tim looked at Nolo, sighed, handed over the keys to Apple Park, and whispered: *"Just promise me you'll take care of the dongle business."* 🕊️

---

## 🌟 **Why DroidHouse Exists**

Apple built the **Walled Garden** to keep you trapped into buying iPhones. If you use a Mac, owning an Android phone meant living like a second-class citizen: no AirDrop, no Clipboard sync, no Screen Mirroring, no SMS desktop integration.

**DroidHouse** breaks the wall down:
- **No iPhone Required**: Get full Apple-grade continuity with *any* Android device.
- **Native Spatial Glass UI**: Renders on macOS using SwiftUI, AppKit, true-black Dark Mode substrate (`#000000`), real-time background aurora field refraction, and spring physics.
- **Android Companion App**: Built with Jetpack Compose, **Plus Jakarta Sans** typography, 100% circular action chips, macOS Settings color scheme, and fluid glass tap optics.

---

## 🚀 **Key Capabilities**

```
+-------------------------------------------------------------------------------+
|  DROIDHOUSE ARCHITECTURE                                                      |
|                                                                               |
|  [ macOS App (SwiftUI/AppKit) ] <=== ADB Bridge (8080/8081) ===> [ Android ] |
|   |-- 🎥 AeroCast 60FPS Screen & Audio Streaming                |  Jetpack    |
|   |-- 💬 iOS Messages Threads & Double-Tick Reports (✓✓)        |  Compose    |
|   |-- 📋 2-Way Universal Clipboard Sync                         |  Companion  |
|   |-- 📁 Exec-Out ADB File Explorer & Drag-and-Drop             |  Service    |
+-------------------------------------------------------------------------------+
```

### 📺 **1. AeroCast Engine (60 FPS Screen & Audio Mirroring)**
- **Hardware Capture**: Android `MediaProjection` capturing raw H.264 video & AAC audio.
- **Zero-Delay Socket**: Direct TCP stream over ADB (port `8081`) straight to macOS display buffer.
- **Glass Window**: Framed inside a translucent spatial glass pane with live specular top highlights.

### 💬 **2. iOS Messages Threads & Delivery Reports**
- **iOS Green Bubbles**: Outgoing messages render in official iOS Messages green (`#34C759`), complete with top highlights and glass shadow depth.
- **Double-Tick Delivery Reports (`✓✓`)**: Live status indicators on sent messages.
- **Threaded Replies**: Interactive reply tagging with instant jump controls.

### 📋 **3. Two-Way Universal Clipboard**
- Copy text on Android $\rightarrow$ Paste instantly on Mac.
- Copy text on Mac $\rightarrow$ Paste instantly on Android.
- Powered by a background Ktor server running on Android (port `8080`).

### 📁 **4. ADB Binary File Streaming**
- **No Temp Files**: Previews images & videos directly from Android RAM over `exec-out`.
- **Drag & Drop**: Drag multi-file selections or whole folder trees between Mac and Android.

### 🎙️ **5. Studio Camera & BoomAudio Virtual Mic for Mac**
- **System Virtual Mic**: Automatically routes bit-perfect 48 kHz stereo PCM into BoomAudio so Zoom, Teams, Meet, Discord, and FaceTime detect phone audio with zero delay.
- **Triple-Lens Switching**: Live sensor toggling between 0.5x Ultra-Wide, 1.0x Main Lens, 3.0x Telephoto, and Front Portrait.
- **Smooth Zoom & Torch**: Continuous 0.5x–10x slider + quick preset pills, plus flashlight toggle.
- **Native Mac Capture**: Instant high-res photo snapshots (PNG to Pictures), 60 FPS video recording with synced audio (MP4 to Movies), and uncompressed studio audio-only recording (WAV to Music).
- **CoreMediaIO Virtual Webcam**: Hardware-accelerated VideoToolbox decompression into raw CVPixelBuffers for system webcam feeds.

### 🎮 **6. Long-Distance Mac Remote Control (Trackpad, Keyboard, Live Desktop & Media)**
- **Anywhere in the World**: Remotely control your Mac even when far away via cellular data or public Wi-Fi using zero-configuration Tailscale mesh (`100.x.y.z`) or direct WAN port forwarding.
- **Precision Virtual Trackpad**: Smooth cursor motion with velocity acceleration ($v^{1.15}$), 1-finger tap left click, 2-finger tap right click, 2-finger scroll, double-tap drag, and tactile glass buttons.
- **Remote Keyboard & Quick Shortcuts**: Direct unicode typing + Mac modifier toggles (`⌘ Cmd`, `⌥ Opt`, `⌃ Ctrl`, `⇧ Shift`), and instant shortcut chips (`⌘+Space` Spotlight, `⌘+Tab` App Switcher, `⌘+C`, `⌘+V`, `⌘+Z`, `⌘+A`).
- **Live Desktop View**: Low-latency Quartz screen streaming over encrypted WebSockets with touch-to-click coordinate translation.
- **Media & Power Remote**: Volume, brightness, media playback, Display Sleep, System Sleep, and Screen Lock.
- **Enterprise-Grade Security**: Challenge-response 6-digit PIN authentication prevents unauthorized access over WAN.

---

## 📦 **Latest Release**

| Version | Highlights & Changes | macOS Download | Android Download |
| :--- | :--- | :---: | :---: |
| **`v1.6`** *(Latest)* | **Mac Remote Control (Trackpad, Keyboard, Live Desktop & Media over WAN)**<br />• Remote Trackpad with cursor acceleration, 2-finger scroll, and tactile buttons.<br />• Live desktop streaming with touch-to-click coordinate dispatch.<br />• Remote Keyboard & macOS shortcuts (Spotlight, App Switcher, Media keys).<br />• Multi-tier WAN connectivity: Tailscale WireGuard mesh & Public WAN support.<br />• Secure 6-digit challenge PIN authentication. | [Download DMG (v1.6)](https://github.com/festomanolo/droid-house/releases/download/v1.6/DroidHouse_v1.6.dmg) | [Download APK (v1.6)](https://github.com/festomanolo/droid-house/releases/download/v1.6/app-release.apk) |
| **`v1.5`** | **Studio Camera & Microphone Input, BoomAudio Routing & Media Capture**<br />• CoreAudio automatic routing to BoomAudio virtual mic for Zoom, Teams, and Meet.<br />• Triple-lens switching: Ultra-Wide (0.5x), Main (1.0x), and Telephoto (3.0x).<br />• Native Mac capture suite: High-res snapshots, 60 FPS video + audio, studio WAV. | [Download DMG (v1.5)](https://github.com/festomanolo/droid-house/releases/download/v1.5/DroidHouse_v1.5.dmg) | [Download APK (v1.5)](https://github.com/festomanolo/droid-house/releases/download/v1.5/app-debug.apk) |

---

## 🛠️ **Installation & Quick Start**

### 1. **macOS Setup**
```bash
# Install Android Platform Tools (ADB) if you haven't already
brew install --cask android-platform-tools
```
- Download [DroidHouse_v1.3.dmg](https://github.com/festomanolo/droid-house/releases/download/v1.3/DroidHouse_v1.3.dmg) and drag **DroidHouse** into your `/Applications` folder.

### 2. **Android Setup**
1. Enable **USB Debugging** (and Wireless Debugging) under *Developer Options*.
2. Install the companion APK:
   ```bash
   adb install -r app-release.apk
   ```
3. Open **DroidHouse Companion** on your phone to grant runtime SMS & Audio projection permissions.

---

## 🏗️ **Building from Source**

```bash
# Clone the repository
git clone https://github.com/festomanolo/droid-house.git
cd droid-house

# Build macOS app and package release DMG
chmod +x release.sh
./release.sh

# Build Android Companion debug APK
cd android-companion
export JAVA_HOME=/path/to/jdk-17
./gradlew assembleDebug
```

---

## 👨‍💻 **Author**

Created by **Nolo** ([@festomanolo](https://github.com/festomanolo))

*P.S. Sorry Tim, someone had to liberate the Mac.* 🍏⚡️
