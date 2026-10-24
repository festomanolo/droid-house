# DroidHouse

DroidHouse connects an Android phone to a Mac. It has two apps:

- A **macOS app** (SwiftUI with some AppKit), in `droid house/`, with the Xcode project in `droid house.xcodeproj`.
- An **Android companion** (Kotlin, Jetpack Compose, Ktor server), in `android-companion/`.

The Mac talks to an HTTP bridge on the phone. It can reach the bridge through adb (a USB or wireless-debugging tunnel) or directly over Wi-Fi after the phone is paired. With Wi-Fi pairing, no adb is needed.

Author: Nolo (@festomanolo, festomanolofm@gmail.com). The project is proprietary.

## Repo rules (read first)

- **The source is private.** `origin` (github.com/festomanolo/droid-house) is the *public* showcase. Never push code there. Release binaries go to GitHub Releases, and the site lives in `web/`.
- **gitnolo-x** is a local process that auto-publishes working-tree edits to `origin` as WIP branches or PRs. Before editing:
  - Check whether it is running: `ps aux | grep gitnolo`.
  - If it is running, warn the user.
  - Never stop it, or repoint the remote, without asking.
- **Commit rules:**
  - No `Co-authored-by` trailers.
  - No mention of Claude, Anthropic or AI.
  - Authorship goes to the user only.
  - Use conventional-style subjects, for example `fix(adb): …`, `perf(roster): …`, `feat(notifications): …`.
- **Developer licence guard** (`DeveloperConfig.swift` and `DeveloperConfig.kt` are gitignored on purpose; never commit them):
  - **Mac:** `droid_houseApp.swift` refuses to launch unless `~/.droidhouse_license` contains `NOLO`.
  - **Android:** `MainActivity` throws unless one of these is true: `/sdcard/.droidhouse_license` exists, `/data/local/tmp/.nolo_dev` exists, or the user is `festomanolo`.
  - **Release script:** `release.sh` aborts if `DeveloperConfig.swift` is missing.
- Don't delete or commit the release artefacts in the root: `*.dmg`, `app-release.apk`, `hostinger_*.zip`. They're gitignored. Stray `*.o` files in `droid house/` are also ignored.
- `~/.gitnolo/config.json` holds secrets. Never print or copy its contents.

## Building

**Mac app**
- Xcode project format 77 uses file-system-synchronised groups. New `.swift` files in `droid house/` are picked up automatically, so don't edit `project.pbxproj` to add them.
- Settings:
  - Deployment target: macOS 26.2.
  - Swift 5 mode.
  - `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and `SWIFT_APPROACHABLE_CONCURRENCY = YES`. Every type is MainActor unless marked otherwise, so helper structs and classes used off the main actor need `nonisolated`.
  - Bundle id: `manolo.droid-house`. Marketing version: 1.7 (build 7).
  - `INFOPLIST_FILE = Info.plist` (the file in the repo root) holds the local-network keys: `NSLocalNetworkUsageDescription`, `NSBonjourServices` = `_droidhouse._tcp`, and `NSAllowsLocalNetworking`.
- Build check (keep products out of the repo):
  ```sh
  xcodebuild -project "droid house.xcodeproj" -scheme "droid house" -configuration Debug \
    CODE_SIGNING_ALLOWED=NO SYMROOT=<scratch>/sym OBJROOT=<scratch>/obj build
  ```
- Release: `./release.sh`. It builds Release, ad-hoc signs (notification replies need a signature), and creates `DroidHouse_v1.7.dmg`. Bump `DMG_NAME` and the version inside it.
- Paths contain spaces (`droid house`), so always quote them. In zsh scripts, use arrays.

**Android companion**
- Needs JDK 17. The system default is JDK 25, which won't work.
  ```sh
  cd android-companion
  JAVA_HOME=/Library/Java/JavaVirtualMachines/jdk-17.jdk/Contents/Home ./gradlew assembleDebug
  adb install -r app/build/outputs/apk/debug/app-debug.apk
  ```
- SDK levels:
  - `compileSdk`/`targetSdk` 35, `minSdk` 28 (Android 9).
  - Guard any API ≥ 29 call with `Build.VERSION.SDK_INT` or `@RequiresApi`, then run lint.
  - Example: AeroCast audio needs Q+, so Android 9 casts video only.
- Versions are `versionCode 6` and `versionName "2.4"`, in `app/build.gradle.kts`.
- Debug builds include `ReplyProbeReceiver` (`app/src/debug/`), a repliable test notification for testing Mac notification replies without messaging a real contact: `adb shell am broadcast -n com.droidhouse.companion/.ReplyProbeReceiver -a com.droidhouse.companion.debug.POST_PROBE --es text "hi"`. The reply lands in `logcat -s ReplyProbe`.
- Lint: `./gradlew lintDebug`. Run it online. It already fails with errors that existed before the Wi-Fi work: MissingPermission in `StudioStreamService.openCamera`, StartActivityAndCollapseDeprecated, and ChromeOS telephony. Don't add new errors.
- Dependencies: Ktor 2.3.12 (server-core, CIO, content-negotiation, cors, status-pages, kotlinx-json), kotlinx-serialization 1.7.3, coroutines 1.8.1, OkHttp 4.12, Compose BOM 2024.09.03.

## Test device

- Phones: Samsung Galaxy S21 (SM-G991U1), Android 15, on wireless adb at `192.168.1.182:5555`; Sony SOV36, Android 9, at `192.168.1.115:5555`.
- For the companion to start, `/data/local/tmp/.nolo_dev` must exist on the phone.
- Test changes there. Clean up after tests:
  - Remove test pairings with `run-as com.droidhouse.companion`.
  - Restore any accessibility or settings you changed.
- Ktor CIO drops the response when a client sends `Expect: 100-continue`. curl does that for large PUTs, so use `curl -H 'Expect:'`. URLSession doesn't send the header.

## Architecture

### Ports (on the phone)
| Port | What | Code |
|---|---|---|
| 8080 | HTTP bridge (Ktor CIO) | `BridgeServer.kt`, started by `DroidHouseCompanion.kt` |
| 8081 | AeroCast screen and audio stream (raw TCP, H.264/AAC, starts with an "AERO" handshake) | `AeroCastService.kt`, `AeroCastProtocol.kt` |
| 8082 | Studio Cam camera and mic stream (raw TCP) | `StudioStreamService.kt`, `StudioStreamProtocol.kt` |

The Mac also hosts **Mac Remote Control** on port **8089** (`MacRemoteControlHost.swift`). The phone connects to it from `MacRemoteClient.kt`, `MacRemoteControlScreen.kt` and `MacRemoteProtocol.kt`. It uses PIN challenge-response auth with a rate limit on wrong PINs, and it works over LAN, Tailscale or WAN.

### Two ways to reach the phone
1. **adb tunnel**:
   - `CompanionSync.setupPortForwarding` runs `adb forward` and points `CompanionLink.endpoint` at `.loopback` (127.0.0.1).
   - Loopback callers are trusted without a token.
   - Shell features also work this way: `adb shell`/`exec-out`/`pull`/`push`, "ADB Direct" mirroring, and `input` events.
2. **Wi-Fi, no adb** (protocol version 2, companion 2.2+):
   - **Binding:** with Wi-Fi mode on (the default, pref `droidhouse_lan`), the bridge and stream sockets bind to `0.0.0.0`.
   - **Pairing:** see `LanAccess.kt`.
     - The phone shows a 6-digit code. `POST /api/pair {code, clientName}` returns a token.
     - Codes are single-use. Five failures rotate the code and lock pairing for 30 s.
     - The phone stores only SHA-256 hashes of tokens.
   - **Auth:** LAN callers must send `Authorization: Bearer <token>`. Only `/api/hello` and `/api/pair` are public. An interceptor in `BridgeServer` enforces this.
   - **Streams:** on 8081 and 8082, a LAN client must first send `DHAUTH <token>\n` within 5 s (`LanAccess.acceptAuthorized`). Unauthenticated clients are dropped.
   - **Discovery:** NSD/Bonjour `_droidhouse._tcp` with TXT records `id`, `model` and `ip`.
   - **Plain HTTP:** traffic is token-authenticated but **not encrypted**. This is a known limitation.

### HTTP API (`BridgeServer.kt` and installers)
- Public:
  - `GET /api/hello`: deviceId, model, protocolVersion, and so on.
  - `POST /api/pair`.
- Status:
  - `GET /api/health`, `GET /api/status`.
- Messages:
  - `GET /api/messages`, `GET /api/messages/{threadId}`, `POST /api/messages/send`.
  - Code: `SmsRepository.kt`, `SentOutbox.kt`.
- Notifications:
  - `GET /api/notifications`, `POST /api/notifications/reply`.
  - Code: `NotificationService.kt`.
- Clipboard:
  - `GET`/`POST /api/clipboard`. `backgroundReadable` says whether phone copies arrive on their own.
  - `POST /api/clipboard/phone` and `POST /api/clipboard/daemon` (heartbeat): loopback only, called by `ClipDaemon` on the phone.
  - Code: `ClipboardBridge.kt`, `ClipboardWatcher.kt`, `ClipDaemon.kt`.
  - Automatic phone → Mac on Android 10+: apps can't read the clipboard in the background, but the shell user can (`READ_CLIPBOARD_IN_BACKGROUND`, as scrcpy does). `ClipDaemon` is started from the APK over adb with `app_process`, runs as shell under the name `droidhouse-clipd`, listens for clip changes and posts them to the bridge on loopback. It survives adb disconnecting, exits on reboot or when the APK is replaced, and the Mac (`CompanionSync.ensureClipboardDaemon`) restarts it on adb attach or when `backgroundReadable` is false. Check it with `adb shell pidof droidhouse-clipd` (not `pgrep -f`, which matches the launching shell).
- Screenshots:
  - `GET /api/screenshots`, `GET /api/screenshots/file`.
  - Code: `ScreenshotWatcher.kt`.
- Roster:
  - `GET /api/roster/{table}`. Unused: the Mac's "Smart Sync" screen that called it was removed in 1.7.
- AeroCast:
  - `/api/aerocast/{start,stop,status}`.
  - Code: `AeroCastConsentActivity.kt` handles MediaProjection consent.
- Studio Cam:
  - `/api/studio/{start,stop,status,cameras,lens,zoom,torch}`.
- Files (`FileBridge.kt`):
  - Paths must be absolute; relative paths get 400. Needs All Files Access on Android 11+, or WRITE_EXTERNAL_STORAGE on older versions.
  - `GET /api/fs/access`.
  - `GET /api/fs/list?path=`, `GET /api/fs/size`.
  - `GET /api/fs/file?path=&max=`.
  - `PUT /api/fs/file?path=&mtime=`: writes `.name.droidhouse-part`, then renames it.
  - `POST /api/fs/{mkdir,delete,move,copy}`.
  - `GET /api/fs/storage`.
  - `GET /api/fs/tar?root=&paths=` and `POST /api/fs/untar?root=`: date-preserving backup and restore.
- Remote input (`RemoteInputService.kt`, an AccessibilityService the user must enable):
  - `GET /api/device/display`: returns `{width, height, inputReady}`.
  - `POST /api/input`: types are `tap`, `longpress`, `swipe`, `key`, `text` and `backspace`.
  - Returns 409 when the service is off.
- Developer mode (`DeveloperMode.kt`, protocol 3, companion 2.3+):
  - `GET /api/device/developer`: developer options, USB and wireless debugging, the `adb tcpip` port, and `canToggle`.
  - `POST /api/device/developer {enabled}`: flips all three together. Returns 409 until WRITE_SECURE_SETTINGS is granted. Only adb can grant it (`pm grant`); the Mac grants it automatically when it sees the phone over adb. The grant survives `install -r` and switching developer mode off. When switching off, the endpoint replies first and applies the change 600 ms later, because it may be cutting off the adb tunnel the reply travels on.
  - Quick Settings tile: `DeveloperModeTileService`. Mac UI: `DeveloperModeControl.swift` (sidebar card under the selected device). If the bridge is down, the Mac falls back to `settings put` over adb shell.

### Mac app map (`droid house/`)
- **Entry and shell:**
  - `droid_houseApp.swift` (runs the licence check).
  - `ContentView.swift`: main window, toolbar, and the "Connect a Phone" sheet.
  - `SidebarView.swift`, `MainExplorerView.swift`, `OnboardingView.swift`, `SettingsView.swift`.
- **Devices and adb:**
  - `ADBService.swift` is the central `ObservableObject`. It covers device detection, the file explorer, and transfers. Every file operation branches to `CompanionFiles` when the device is Wi-Fi only (`device.isCompanionOnly`).
  - `ADBLocator.swift` finds the adb binary, with a bounded login-shell lookup.
  - `ADBProcess.swift` is the shared process runner.
  - `Models.swift` defines `ADBDevice` and `ConnectionType` (`.usb`, `.wifi`, `.companion` = "Wi-Fi"). Wi-Fi-only devices have id `wifi:<deviceId>`.
- **Companion link:**
  - `CompanionLink.swift`:
    - `CompanionEndpoint` (host, port, token, `request`, `streamPreamble`).
    - `CompanionLink.endpoint` and `CompanionLink.data(for:)`, which adds auth. Always use this, not `URLSession.shared`, for bridge calls.
    - `WiFiCompanionStore`: pairing, Bonjour browsing, a 5 s reachability loop, and Keychain tokens (service `manolo.droid-house.companion`). Paired phones are kept in UserDefaults under `droidhouse.pairedPhones`.
  - `CompanionSync.swift`:
    - Polls messages, notifications, clipboard and screenshots.
    - `attach(to:)` picks adb-forward or Wi-Fi.
    - `learnCompanionIdentity` links an adb serial to its paired Wi-Fi identity.
  - `CompanionFiles.swift`: the HTTP file client, with streaming downloads, upload progress and tar.
  - `WiFiPairingView.swift`: the pairing UI.
- **Features:**
  - AeroCast: `AeroCast*.swift`. `AeroCastController` sends input over adb shell, or over `/api/input` on Wi-Fi.
  - Studio Cam: `StudioCam*.swift`. Related managers:
    - `StudioAudioRouter` routes audio into the BoomAudio virtual mic.
    - `StudioCaptureManager` handles photo, video and WAV capture.
    - `StudioVirtualCamManager` is the CoreMediaIO webcam.
  - Messages: `MessagesView`, `ChatBubble`, `ContactsSidebarView`, `ReplyTag`, `SmartReplyEngine`. Replies from macOS notifications go through `PhoneNotificationRelay`, which logs to subsystem `manolo.droid-house`, category `notifications` (`/usr/bin/log show --predicate 'subsystem == "manolo.droid-house"'`; plain `log` is a zsh builtin). macOS won't relaunch the app for a reply, so replies only work while DroidHouse is running.
  - Clipboard: `ClipboardSyncManager` (created at launch in `droid_houseApp`; polls the phone every 1 s), `ClipboardSyncView`. Password-like copies are not synced.
  - Transfers: `TransferManager`, `TransfersView`, `TransferStatusPill`, `ArchiveTransferEngine` (tar backup and restore over adb or Wi-Fi), `TimestampTransferView`.
  - Previews: `FilePreviewPanel`, `ThumbnailManager`, `ScreenshotGalleryView`, `StorageIndicatorView`.
  - Look and feel: `DesignSystem.swift`, `Styles.swift`, `LiquidProgressBar.swift`. The "spatial glass" UI uses a true-black background.

### Android companion map (`android-companion/app/src/main/java/com/droidhouse/companion/`)
- `DroidHouseCompanion.kt`: the foreground service. It handles bridge start and stop, `ACTION_RESTART_BRIDGE`, NSD advertising, and the notification.
- `MainActivity.kt`: the Compose UI, made of cards. The Bridge card shows the endpoint. The Wi-Fi card shows the address, pairing code, paired Macs, and File access and Remote Input buttons.
- UI pieces: `CompanionTheme`, `CompanionComponents`, `GlassPanel`, `AuroraBackground`. Typography is Plus Jakarta Sans.
- `BridgeModels.kt` holds the `@Serializable` payloads.
- `res/xml/remote_input_service.xml` configures the accessibility service.

## Conventions

- Match the surrounding code: short doc comments on types, and comments explaining *why*, not what.
- **New bridge features must work over both paths:**
  - Use `CompanionLink`/`CompanionEndpoint` on the Mac.
  - Keep loopback trust plus bearer auth on the phone.
  - Don't add adb-only code paths without a Wi-Fi branch, unless the feature truly needs a shell.
- When adding endpoints, bump `PROTOCOL_VERSION` (currently 3) and `VERSION` in `BridgeServer.kt` if older Macs or phones need to detect the change.
- `ISSUES.md` is the engineering issue log, numbered `[Issue #NNN]`. Add an entry for significant bugs.
- `README.md` is the public, marketing-style readme. Its version badges and links point at public releases.
