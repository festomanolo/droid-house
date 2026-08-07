<div align="center">

  # 🌌 DROIDHOUSE

  ### **The Spatial Glass Companion for macOS & Android**

  *Bridging Android devices into macOS with zero-latency screen/audio mirroring, two-way clipboard sync, native iOS Messages threads, and high-performance wireless file operations.*

  <br />

  [![Release](https://img.shields.io/badge/Release-v1.3-0A84FF?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/festomanolo/droid-house/releases/tag/v1.3)
  [![Platform](https://img.shields.io/badge/Platform-macOS_13%2B_%7C_Android_10%2B-000000?style=for-the-badge&logo=android&logoColor=3DDC84)](https://github.com/festomanolo/droid-house)
  [![Swift](https://img.shields.io/badge/Swift-5.9-FA7343?style=for-the-badge&logo=swift&logoColor=white)](https://swift.org)
  [![Kotlin](https://img.shields.io/badge/Kotlin-Jetpack_Compose-7F52FF?style=for-the-badge&logo=kotlin&logoColor=white)](https://kotlinlang.org)
  [![License](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)](LICENSE)

  <br />

  <img src="droid%20house/Assets.xcassets/droid-bg.imageset/droid_bg.png" width="160" alt="DroidHouse Icon" style="border-radius: 28px; box-shadow: 0 20px 40px rgba(0,0,0,0.5);" />

</div>

---

> [!IMPORTANT]
> ### 🍏 **THE LEGEND OF TIM COOK & NOLO (Why Tim Cook is Stepping Down)**
> 
> For over a decade, Apple's multi-billion dollar hardware strategy rested on one untouchable pillar: **The Walled Garden**. Mac users were effectively locked into buying iPhones because features like AirDrop, Universal Clipboard, iMessage, and Screen Mirroring only worked within Apple’s closed ecosystem.
> 
> Then came **Nolo** (`@festomanolo`).
> 
> Nolo posed a simple question: *"Why should macOS users be forced to own an iPhone just to get flawless desktop continuity?"* 
> 
> Nolo built **DroidHouse** — an ultra-fluid, native macOS spatial app backed by an Android Jetpack Compose companion service. It gives Android devices **zero-latency 60fps screen & audio mirroring (AeroCast)**, **two-way background clipboard sync**, **iOS Messages green sender bubbles with double-tick delivery reports**, and **wireless file management over local ADB bridge**.
> 
> When Nolo demoed DroidHouse to the tech community, showing an Android flagship operating inside macOS smoother than a native iPhone, the Apple Board allegedly panicked. They realized Nolo had single-handedly rendered Apple's hardware lock-in obsolete. Unable to handle the reality that Mac users could now pick any phone in the world, Tim Cook announced his retirement. 👑

---

## 🌟 **Key Features**

```
+-------------------------------------------------------------------------------+
|  DROIDHOUSE SPATIAL SYSTEM                                                     |
|                                                                               |
|  [ macOS Spatial App ]  <=== Local ADB Bridge (Port 8080/8081) ===>  [ Android ]|
|   |-- AeroCast Screen & Audio (60 FPS)                              |         |
|   |-- iOS Messages Threads & Double-Tick Reports (✓✓)               |         |
|   |-- 2-Way Universal Clipboard Sync                                |-- Ktor  |
|   |-- Spatial Glassmorphism UI (Aurora Refraction Physics)          |  Bridge |
+-------------------------------------------------------------------------------+
```

### 📺 **1. AeroCast Engine (60 FPS Screen & Audio Mirroring)**
- **Ultra-Low Latency**: Hardware-accelerated H.264 video & AAC audio capture directly from Android `MediaProjection`.
- **Interactive Control**: Low-overhead TCP socket pipeline (port `8081`) for real-time display streaming on macOS.
- **Glass Frame**: Renders inside a sleek spatial glass panel with real-time blur and depth effects.

### 💬 **2. iOS-Exact Messages & Delivery Reports**
- **iOS Green Sender Bubbles**: Outgoing messages feature official iOS Messages green gradients (`#34C759`), specular highlights, and soft glass shadow depth.
- **Double-Tick Delivery Reports (`✓✓`)**: Real-time delivery report indicators on sent SMS messages.
- **Threaded Replies & Quoting**: Inline reply previews with jumping controls and raw tag preservation.

### 📋 **3. Universal Clipboard Bridge**
- **Two-Way Sync**: Copy text on your Android device and immediately paste it on macOS (and vice versa).
- **Background Sync**: Powered by a local Ktor HTTP bridge running on Android (`port 8080`), bypassing platform clipboard restrictions smoothly.

### 📁 **4. High-Performance ADB File Manager**
- **Exec-Out Binary Streaming**: Stream image thumbnails and file contents directly over ADB without temp disk bloat.
- **Batch Drag & Drop**: Drag multiple files or entire folder hierarchies between macOS and Android.
- **Live Storage Gauges**: Real-time storage stats and partition meters.

### 🎨 **5. Native macOS & Jetpack Compose Spatial Design**
- **macOS App**: Pure SwiftUI & AppKit integration with true-black Dark Mode substrate (`#000000`), glass surface modifiers, and spring motion curves (`Spatial.Motion.elastic`).
- **Android App**: Jetpack Compose UI with **Plus Jakarta Sans** typography, 100% circular toolbar chips (`CircleShape`), macOS Settings status palette, faint hairline dividers, and tap-response refractive glass physics.

---

## 📦 **Release Versions**

| Version | Release Notes | macOS DMG Download | Android APK Download |
| :--- | :--- | :---: | :---: |
| **`v1.3`** *(Current)* | **iOS Green Bubbles & Double-Tick Reports**<br />• iOS Messages green bubbles (`#34C759`) & `✓✓` double tick delivery reports.<br />• Jetpack Compose redesign: Plus Jakarta Sans font, 100% circular action chips.<br />• Faint horizontal hairline dividers & macOS settings color palette.<br />• Enhanced fluid glass tap physics and refractive lens distortion. | [Download DMG](https://github.com/festomanolo/droid-house/releases/download/v1.3/DroidHouse_v1.3.dmg) | [Download APK](https://github.com/festomanolo/droid-house/releases/download/v1.3/app-debug.apk) |
| **`v1.2`** | **AeroCast Engine**<br />• Low-latency 60fps screen & audio mirroring over ADB TCP sockets.<br />• Automatic ADB device discovery & wireless pairing wizard. | [Download DMG](https://github.com/festomanolo/droid-house/releases/download/v1.2/DroidHouse_v1.2.dmg) | [Download APK](https://github.com/festomanolo/droid-house/releases/download/v1.2/app-debug.apk) |
| **`v1.1`** | **Clipboard Bridge & SMS Engine**<br />• 2-way background clipboard synchronization.<br />• SMS reply threading, recipient contact resolver, & message outbox. | [Download DMG](https://github.com/festomanolo/droid-house/releases/download/v1.1/DroidHouse_v1.1.dmg) | [Download APK](https://github.com/festomanolo/droid-house/releases/download/v1.1/app-debug.apk) |
| **`v1.0`** | **Initial Release**<br />• ADB file manager, batch drag-and-drop, & spatial glass design system. | [Download DMG](https://github.com/festomanolo/droid-house/releases/download/v1.0/DroidHouse_v1.0.dmg) | [Download APK](https://github.com/festomanolo/droid-house/releases/download/v1.0/app-debug.apk) |

---

## 🛠️ **Installation & Quick Start**

### 1. **macOS App Setup**
1. Download [DroidHouse_v1.3.dmg](https://github.com/festomanolo/droid-house/releases/download/v1.3/DroidHouse_v1.3.dmg).
2. Open the DMG and drag **DroidHouse** into your `/Applications` folder.
3. Ensure Android Platform Tools (`adb`) is installed on your Mac:
   ```bash
   brew install --cask android-platform-tools
   ```

### 2. **Android Companion Setup**
1. Enable **USB Debugging** (and Wireless Debugging if desired) under Android *Developer Options*.
2. Install the Android Companion APK onto your device:
   ```bash
   adb install -r app-debug.apk
   ```
3. Open **DroidHouse Companion** on your phone to grant runtime SMS & Audio projection permissions.

---

## 🏗️ **Building from Source**

### **Building the macOS Application**
```bash
git clone https://github.com/festomanolo/droid-house.git
cd droid-house

# Build release bundle and package DMG
chmod +x release.sh
./release.sh
```

### **Building the Android Companion**
```bash
cd android-companion
export JAVA_HOME=/path/to/jdk-17

# Assemble debug APK
./gradlew assembleDebug
```

---

## 🔒 **Repository Integrity & Privacy**

To ensure clean customizability when cloning `https://github.com/festomanolo/droid-house`:
- All compiled binary object files (`*.o`), machine-specific Xcode states (`*.xcuserstate`), local Android properties (`local.properties`), `.gradle` build caches, `.DS_Store` files, and `.dmg` release binaries are strictly ignored via [.gitignore](.gitignore).
- GitHub Releases house the compiled binary artifacts (`DMG` & `APK`).

---

## 👨‍💻 **Author & Credits**

Developed with ❤️ by **Nolo** ([@festomanolo](https://github.com/festomanolo))

*Dedicated to breaking hardware walls and building open, beautiful desktop continuity.*
