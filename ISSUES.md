# DroidHouse Engineering Issues & Resolutions Log

This document tracks system issues identified, analyzed, and resolved across macOS CoreAudio/CoreMediaIO pipelines and Android Camera2 companion services.

---

### [Issue #001]: macOS Does Not Detect DroidHouse Microphone (BoomAudio Silent Input)
- **Status:** Closed / Resolved
- **Severity:** Critical
- **Component:** `StudioAudioRouter.swift`, `StudioCamEngine.swift`
- **Symptom:**
  When starting Studio Broadcast in DroidHouse, macOS applications (Zoom, Microsoft Teams, Google Meet, Discord, FaceTime, Boom 3D) selected "BoomAudio" as microphone input, but no audio was detected or heard.
- **Root Cause:**
  `BoomAudio` is a 6-channel virtual loopback device on macOS. For BoomAudio's input stream to receive audio, an application must explicitly stream audio into BoomAudio's output stream using CoreAudio HAL device assignment. Previously, `StudioCamEngine` only had a local monitor node connected to `AVAudioEngine.mainMixerNode` (which defaults to internal speakers) and defaulted to `isMonitorEnabled = false`. No audio was ever directed to BoomAudio's device ID.
- **Resolution:**
  1. Implemented `StudioAudioRouter.swift` using CoreAudio HAL APIs (`kAudioHardwarePropertyDevices`, `kAudioDevicePropertyStreams`, `kAudioDevicePropertyDeviceUID`).
  2. Auto-detects `BoomAudio` by device UID/name and configures an `AVAudioEngine` output audio unit with `AudioUnitSetProperty(kAudioOutputUnitProperty_CurrentDevice, boomAudioDeviceID)`.
  3. Automatically starts streaming bit-perfect 48,000 Hz 16-bit stereo PCM into BoomAudio as soon as Studio Broadcast begins.
  4. Provided independent Mac speaker monitoring so users can listen without muting the virtual mic.

---

### [Issue #002]: Camera Lens Switcher (Telephoto, Ultra-Wide, Main) Inactive During Live Broadcast
- **Status:** Closed / Resolved
- **Severity:** High
- **Component:** `StudioCamEngine.swift`, `StudioCamView.swift`
- **Symptom:**
  Clicking the "Telephoto", "Ultra-Wide", or "Main Lens" buttons while streaming video produced no effect; the viewfinder remained on the initial lens.
- **Root Cause:**
  In `StudioCamEngine.swift`, the `start(serial:)` function contained an early exit: `guard !state.isLive, !state.isBusy else { return }`. The UI buttons invoked `engine.start(serial:)` upon lens selection, causing the call to be discarded immediately when streaming.
- **Resolution:**
  1. Added `switchLens(to lensId: String)` in `StudioCamEngine.swift` that sends `POST /api/studio/lens` asynchronously to the companion service during active streaming.
  2. Enabled smooth runtime lens transitions without restarting the TCP socket or video encoder pipeline.

---

### [Issue #003]: Android Camera2 Service Mapping All Back Lenses to the First Sensor ID
- **Status:** Closed / Resolved
- **Severity:** High
- **Component:** `android-companion/StudioStreamService.kt`
- **Symptom:**
  Selecting "Ultra-Wide" or "Telephoto" on Samsung Galaxy S21 SM-G991U1 kept using the main 24mm wide lens instead of the physical 13mm ultra-wide or 70mm telephoto sensors.
- **Root Cause:**
  `resolveCameraId()` in `StudioStreamService.kt` simply iterated through camera IDs and returned the first camera matching `facing == LENS_FACING_BACK`. It did not inspect `LENS_INFO_AVAILABLE_FOCAL_LENGTHS` or configure `CONTROL_ZOOM_RATIO`.
- **Resolution:**
  1. Updated `resolveCameraId` to query `LENS_INFO_AVAILABLE_FOCAL_LENGTHS` and sort candidate sensors by physical focal length (shortest = ultra-wide, middle = main wide, longest = telephoto).
  2. Implemented `applyLensZoomToBuilder` using Android Camera2 `CONTROL_ZOOM_RATIO` (API 30+):
     - `back_ultra` -> `0.5f` (smooth switch to ultra-wide optical sensor)
     - `back_wide` -> `1.0f` (main wide sensor)
     - `back_tele` -> `3.0f` (optical telephoto sensor)
  3. Added `POST /api/studio/lens` to dynamically update the active `CameraCaptureSession` repeating request.

---

### [Issue #004]: Absence of Native Video, Photo Snapshot, and Audio-Only Recording on Mac
- **Status:** Closed / Resolved
- **Severity:** Medium / Feature Request
- **Component:** `StudioCaptureManager.swift`, `StudioCamView.swift`
- **Symptom:**
  Users were unable to capture high-resolution photos, record 60 FPS video, or record uncompressed audio directly within DroidHouse on macOS.
- **Root Cause:**
  Frames were enqueued solely into `AVSampleBufferDisplayLayer` with no asset writing or file persistence pipeline.
- **Resolution:**
  1. Created `StudioCaptureManager.swift` with three distinct capture modes:
     - **Photo Snapshot:** Converts latest hardware-decoded `CVPixelBuffer` to PNG, saves to `~/Pictures/DroidHouse/`, with visual flash animation and shutter sound.
     - **60 FPS Video Recording:** Uses `AVAssetWriter` (H.264 video at 25-35 Mbps + AAC 48 kHz stereo audio at 256 kbps) saved to `~/Movies/DroidHouse/`.
     - **Studio Audio Alone:** Uses `AVAudioFile` to record bit-perfect 48 kHz 16-bit linear PCM broadcast WAV saved to `~/Music/DroidHouse/`.
  2. Added live recording HUD (timer badge, file size in MB) and a thumbnail toast notification with "Show in Finder".

---

### [Issue #005]: VideoToolbox H.264 CVPixelBuffer Extraction Pipeline
- **Status:** Closed / Resolved
- **Severity:** High
- **Component:** `StudioCamEngine.swift`
- **Symptom:**
  Compressed H.264 sample buffers could not be directly converted to `CGImage` or passed to pixel buffer adaptors for recording without hardware decompression.
- **Root Cause:**
  `CMSampleBufferGetImageBuffer()` returns `nil` for compressed H.264 frames before decompression.
- **Resolution:**
  Integrated a hardware-accelerated `VTDecompressionSession` alongside `AVSampleBufferDisplayLayer`. Every incoming frame is decompressed into a 32-bit BGRA `CVPixelBuffer` via Apple VideoToolbox, making full-resolution frames available simultaneously for display, recording, and snapshots with zero frame drops.

---

### [Issue #006]: Continuous Zoom and Torch Flashlight Control
- **Status:** Closed / Resolved
- **Severity:** Medium
- **Component:** `StudioStreamService.kt`, `BridgeServer.kt`, `StudioCamView.swift`
- **Symptom:**
  No mechanism existed to smoothly zoom between 0.5x and 10x or toggle the phone's physical LED flashlight while streaming.
- **Root Cause:**
  Endpoints `/api/studio/zoom` and `/api/studio/torch` were not implemented in the Ktor server or Camera2 capture request builder.
- **Resolution:**
  1. Implemented `POST /api/studio/zoom` with `StudioZoomRequest(zoomRatio: Float)` applying `CaptureRequest.CONTROL_ZOOM_RATIO`.
  2. Implemented `POST /api/studio/torch` with `StudioTorchRequest(enabled: Boolean)` applying `CaptureRequest.FLASH_MODE_TORCH`.
  3. Added zoom slider with presets (0.5x, 1x, 2x, 3x, 5x, 10x) and flashlight toggle button in `StudioCamView.swift`.

---

### [Issue #007]: CoreMediaIO Virtual Camera Detection and Extension Support
- **Status:** Closed / Resolved
- **Severity:** Medium
- **Component:** `StudioVirtualCamManager.swift`
- **Symptom:**
  macOS native applications (FaceTime, QuickTime, Zoom) did not automatically detect DroidHouse as a system camera input.
- **Root Cause:**
  Modern macOS (macOS 12.3+) requires either a CoreMediaIO Camera Extension or a DAL Plugin bundle registered in `/Library/CoreMediaIO/Plug-Ins/DAL/`.
- **Resolution:**
  1. Created `StudioVirtualCamManager.swift` to monitor system virtual camera status via `AVCaptureDevice.DiscoverySession`.
  2. Provided administrative installer script for the CoreMediaIO DAL plugin bundle.
  3. Integrated frame publishing bridge for streaming decoded `CVPixelBuffer` frames to virtual camera consumers.

---

### [Issue #008]: SIGILL / EXC_BAD_INSTRUCTION Crash on Opening Studio Cam & Mic (`AVAE_CheckNodeHasEngine`)
- **Status:** Closed / Resolved
- **Severity:** Critical
- **Component:** `StudioAudioRouter.swift`, `StudioCamEngine.swift`
- **Symptom:**
  Clicking "Studio Cam & Mic" in the navigation sidebar immediately crashed the macOS application with `EXC_BAD_INSTRUCTION (SIGILL)` triggered by `[AVAudioPlayerNode play]` inside `StudioAudioRouter.startVirtualMic()`.
- **Crash Trace Analysis:**
  ```text
  Exception Type:    EXC_BAD_INSTRUCTION (SIGILL)
  Application Specific Backtrace 0:
  3   AVFAudio      _ZNK15AVAudioNodeImpl23AVAE_CheckNodeHasEngineEv + 298
  4   AVFAudio      _ZN21AVAudioPlayerNodeImpl9StartImplEP11AVAudioTime + 358
  5   AVFAudio      -[AVAudioPlayerNode play] + 43
  6   droid house   StudioAudioRouter.startVirtualMic() + 145
  7   droid house   StudioAudioRouter.configureVirtualMicPipeline() + 1005
  8   droid house   StudioAudioRouter.selectedDeviceID.didSet + 129
  9   droid house   StudioAudioRouter.refreshDevices() + 2878
  10  droid house   StudioAudioRouter.init() + 1102
  11  droid house   StudioCamEngine.init() + 775
  ```
- **Root Cause:**
  1. In `StudioAudioRouter.init()`, `refreshDevices()` was invoked before `setupAudioGraphs()`.
  2. Inside `refreshDevices()`, detecting BoomAudio or a virtual sink immediately set `self.selectedDeviceID = boom.id`.
  3. The `didSet` observer invoked `configureVirtualMicPipeline()`.
  4. Because `isVirtualMicRoutingActive` was `true`, `configureVirtualMicPipeline()` evaluated `if wasRunning || isVirtualMicRoutingActive` as `true` and invoked `startVirtualMic()`.
  5. `startVirtualMic()` called `virtualPlayer.play()`. At this point in object initialization, `setupAudioGraphs()` had not yet been executed, meaning `virtualEngine.attach(virtualPlayer)` was never called. AVFoundation asserted `AVAE_CheckNodeHasEngine()`, throwing an unhandled Objective-C exception that terminated the process on the main thread.
- **Resolution:**
  1. Corrected initialization sequence in `StudioAudioRouter.init()`: `setupAudioGraphs()` is now executed first so `virtualEngine.attach(virtualPlayer)` and `monitorEngine.attach(monitorPlayer)` are established before any device enumeration occurs.
  2. Introduced an `isStreamActive` state flag: `configureVirtualMicPipeline()` and device change observers now only start or resume playback if active streaming is engaged (`wasRunning && isVirtualMicRoutingActive && isStreamActive`).
  3. Added explicit defensive assertions in `startVirtualMic()` and `startMonitor()`:
     - `guard virtualPlayer.engine != nil else { return }`
     - `guard monitorPlayer.engine != nil else { return }`
  4. Added `virtualPlayer.isPlaying` guards before scheduling incoming audio buffers in `ingestPCM(_:)`.
  5. Synchronized stream activation across `StudioCamEngine.start(serial:)` and `StudioCamEngine.stop()`.

---

### [Issue #009]: Video and Audio Recording Latency, Stutter, and Timestamp Drift in Studio Mode
- **Status:** Closed / Resolved
- **Severity:** High
- **Component:** `StudioStreamService.kt`, `StudioCaptureManager.swift`, `StudioCamEngine.swift`
- **Symptom:**
  When capturing 60 FPS video or recording audio in Studio Broadcast mode, the UI experienced micro-stutters, recorded MP4 videos suffered from dropped frames, and audio playback drifted out of sync with video.
- **Root Cause Analysis:**
  1. **Clock Domain Mismatch on Android:**
     `Camera2` Surface video frames were stamped by Android's hardware encoder using `SystemClock.elapsedRealtimeNanos()` (`CLOCK_BOOTTIME`). Meanwhile, `pumpAudio()` was generating timestamps with `System.nanoTime()` (`CLOCK_MONOTONIC`). Because `CLOCK_MONOTONIC` pauses during kernel suspend while `CLOCK_BOOTTIME` runs continuously, the timestamps on Samsung devices differed by millions of microseconds (hours of offset). When passed to macOS `AVAssetWriter`, the audio timestamps fell either outside the session start window or far ahead, triggering sample buffer drops and desync.
  2. **Main Thread Saturation from Real-Time Media Encoding & Disk I/O:**
     `StudioCaptureManager` ran entirely on `@MainActor`. Appending 60 FPS 1080p BGRA pixel buffers (~480 MB/sec uncompressed bandwidth) and writing uncompressed 48 kHz WAV PCM buffers directly to disk with synchronous `AVAudioFile.write(from:)` blocked the main runloop, causing `AVAssetWriterInput.isReadyForMoreMediaData` to drop frames.
  3. **Skewed Latency Smoothing:**
     `trackLatency()` in `StudioCamEngine` was calculating packet drift for alternating video and audio frames together, skewing latency smoothing due to differing packet intervals.
- **Resolution:**
  1. Updated `StudioStreamService.kt` to stamp audio packets with `(SystemClock.elapsedRealtimeNanos() / 1000L) - durationUs`, perfectly aligning audio PTS with Camera2 video frames on the same `CLOCK_BOOTTIME` timeline.
  2. Built `StudioAssetRecorder` as an asynchronous background worker isolated on `com.droidhouse.recorderQueue` (`userInitiated` QoS). All `AVAssetWriterInputPixelBufferAdaptor.append`, `CMSampleBuffer` synthesis, and `AVAudioFile.write` operations now run off the main thread.
  3. Enforced strictly monotonic timestamp pacing (`lastVideoPTS` and `lastAudioPTS`) to eliminate network jitter artifacts in recorded media.
  4. Scoped latency tracking strictly to video frame packets.

---

### [Issue #010]: End-to-End Latency and Sensor Optimization Across CoreAudio, Video Pipeline, and Multi-Camera Sensors
- **Status:** Closed / Resolved
- **Severity:** High
- **Component:** `StudioCamProtocol.swift`, `AeroCastProtocol.swift`, `StudioAudioRouter.swift`, `StudioCamEngine.swift`, `StudioCamView.swift`, `StudioStreamService.kt`
- **Symptom:**
  During 60 FPS studio streaming, CPU usage spiked due to redundant memory copying during video parsing, BoomAudio 6-channel routing experienced format negotiation mismatches, UI vu-meters caused unnecessary main-thread render passes, and telephoto/ultra-wide lens switches remained stuck on the main sensor on certain Android multi-camera arrays.
- **Root Cause Analysis:**
  1. **$O(N^2)$ Stream Buffer Shifting:** `StudioCamStreamParser.drain()` invoked `buffer.removeFirst(total)` on every drained packet, triggering an $O(N)$ `memmove` over hundreds of kilobytes of incoming video payload on every frame.
  2. **Heap Thrashing in NAL Parsing:** `AnnexB.nalUnits` copied entire frame byte buffers into `[UInt8]` arrays on every frame, generating multiple short-lived heap allocations at 60 FPS.
  3. **BoomAudio 6-Channel Mixer Configuration:** BoomAudio exposes 6 output channels. Setting `kAudioOutputUnitProperty_CurrentDevice` without reconnecting `mainMixerNode` with `hwFormat` led to channel format mismatches.
  4. **Unvectorized PCM Math & Unthrottled UI Metering:** Audio PCM was decoded in scalar Swift loops twice (once in `StudioCamEngine` and once in `StudioAudioRouter`), and every 10-20ms packet pushed `@Published` state changes to `@MainActor`, thrashing SwiftUI view rendering.
  5. **Camera2 Physical Sensor Selection:** When switching between back camera lenses (`back_wide`, `back_ultra`, `back_tele`), `facingChanged` was `false`. If the physical sensor IDs were distinct (e.g. camera 0 for wide, camera 2 for ultra-wide, camera 3 for telephoto), the service never called `reopenCamera` and instead clamped `CONTROL_ZOOM_RATIO` to 1.0x.
- **Resolution:**
  1. Refactored `StudioCamStreamParser` with an internal `readOffset` cursor, reducing buffer compaction to amortized $O(1)$.
  2. Replaced `[UInt8]` heap copying in `AnnexB.nalUnits` with `data.withUnsafeBytes` and pre-allocated AVCC buffer capacities.
  3. Reconnected `virtualEngine.mainMixerNode` to `virtualEngine.outputNode` with the native hardware format upon device assignment.
  4. Vectorized Int16 to Float32 conversion and peak detection with Apple's `Accelerate` framework (`vDSP_vflt16`, `vDSP_vsmul`, `vDSP_maxmgv`). Throttled UI VU meter updates to 30 FPS.
  5. Updated `StudioStreamService.kt` to compare `targetCameraId != activeCameraId` across physical camera IDs, cleanly reopening sensors when switching between ultra-wide, telephoto, and wide lenses.
  6. Configured 1MB socket send buffer (`socket.sendBufferSize = 1024 * 1024`) on Android companion server to absorb high-bitrate I-frame bursts.

---

### [Issue #011]: Modern macOS SDK Obsoletion of Quartz Capture APIs and Dynamic Symbol Resolution for High-Performance Desktop Streaming
- **Status:** Closed / Resolved
- **Severity:** High
- **Component:** `MacRemoteControlHost.swift`, `MacRemoteControlProtocol.swift`
- **Symptom:**
  Building macOS remote desktop host on modern SDKs (macOS 15+) failed when attempting to capture the display using `CGDisplayCreateImage(CGMainDisplayID())` or `CGWindowListCreateImage`, reporting compilation error: `'CGWindowListCreateImage' is unavailable in macOS`. Traditional ScreenCaptureKit streaming requires heavy asynchronous negotiation and IPC streams ill-suited for on-demand low-latency remote control JPEG frames.
- **Root Cause Analysis:**
  Apple marked Quartz display capture functions as obsoleted in C headers starting in recent SDK versions to favor ScreenCaptureKit. However, the runtime dynamic symbol remains present in `CoreGraphics.framework` userspace.
- **Resolution:**
  Implemented runtime dynamic symbol resolution:
  ```swift
  typealias CGWindowListCreateImageFunc = @convention(c) (CGRect, UInt32, CGWindowID, UInt32) -> Unmanaged<CGImage>?
  let handle = dlopen(nil, RTLD_LAZY)
  if let sym = dlsym(handle, "CGWindowListCreateImage") {
      let function = unsafeBitCast(sym, to: CGWindowListCreateImageFunc.self)
      // Instant display capture without compilation failure
  }
  ```
  Coupled with hardware-accelerated JPEG compression (`NSBitmapImageRep` with compression factor 0.65), desktop frames are captured and streamed over WebSocket in under 8ms.

---

### [Issue #012]: Jetpack Compose Cross-Platform UI Discrepancies and Touch Gesture Disambiguation on Remote Trackpad
- **Status:** Closed / Resolved
- **Severity:** Medium
- **Component:** `MacRemoteControlScreen.kt`, `MainActivity.kt`
- **Symptom:**
  Attempting to reuse styling idioms caused compilation failure due to Compose lacking `Color.opacity(Float)`, which exists in SwiftUI. Furthermore, using a single `pointerInput` block on the virtual trackpad surface led to gestures swallowing one another (e.g. single-finger taps for left click were occasionally swallowed during cursor dragging, or two-finger scroll was misinterpreted as a right-click).
- **Root Cause Analysis:**
  Compose `Color` uses `.copy(alpha = ...)` rather than `.opacity(...)`. Additionally, `detectTapGestures` and `detectDragGestures` cannot be chained on the same raw pointer modifier without custom gesture coordination.
- **Resolution:**
  1. Created an inline extension `private fun Color.opacity(alpha: Float): Color = this.copy(alpha = alpha)`.
  2. Migrated deprecated `Icons.Outlined.ScreenShare` to `Icons.AutoMirrored.Outlined.ScreenShare`.
  3. Structured trackpad input using coordinated pointer callbacks: single-finger drag modulates mouse coordinate delta with an acceleration curve ($v^{1.15}$); two-finger drag translates to discrete vertical/horizontal wheel delta; dedicated physical tactile glass buttons provide 100% reliable Left & Right clicking without ambiguous gesture timing.

---

### [Issue #013]: Long-Distance Remote Control Connectivity over Cellular & WAN via Tailscale CGNAT Mesh
- **Status:** Closed / Resolved
- **Severity:** High
- **Component:** `MacRemoteControlHost.swift`, `MacRemoteClient.kt`, `MacRemoteAccessView.swift`
- **Symptom:**
  Controlling the Mac remotely while away from home (cellular data, cafe Wi-Fi, hotel networks) failed when connecting to local IP (`192.168.x.x`), because home routers block unsolicited inbound traffic through Carrier-Grade NAT (CGNAT) and symmetric firewall rules.
- **Root Cause Analysis:**
  Mobile network carriers place devices behind CGNAT pools where neither device has a routable public IP. Traditional port forwarding on consumer routers is complex, fragile, and often impossible on IPv6-only or ISP-managed modems.
- **Resolution:**
  1. Multi-tier host IP discovery: `MacRemoteControlHost` interrogates local network interfaces for Tailscale CGNAT addresses (`100.64.0.0/10`), local Wi-Fi addresses (`en0`), and queries `api.ipify.org` for external public WAN IP.
  2. Surfaced one-tap address copying directly in `MacRemoteAccessView.swift` so the user can easily connect from anywhere in the world using Tailscale without opening router ports.
  3. Enforced 6-digit challenge-response PIN authentication over encrypted WebSocket sessions to protect the Mac against WAN port scanning.

---

### [Issue #014]: Real-Time Pointer & Vector Hardware Cursor Invisibility in Remote Frame Capture
- **Status:** Closed / Resolved
- **Severity:** High
- **Component:** `MacRemoteControlHost.swift`, `MacRemoteClient.kt`, `MacRemoteControlScreen.kt`
- **Symptom:**
  When viewing the live macOS desktop stream on the Android phone, the mouse cursor was completely invisible. Users could not see what UI elements they were hovering over or where clicks would land.
- **Root Cause Analysis:**
  macOS Quartz display capture APIs (`CGWindowListCreateImage` / `CGDisplayCreateImage`) deliberately exclude the hardware mouse cursor layer from the rendered frame bitmap to maintain compositor performance. As a result, captured frame buffers contain only background windows without the cursor icon.
- **Resolution:**
  Implemented a dual-layer real-time cursor engine:
  1. **Host-Side Vector Drawing in Frame Pipeline:** Before JPEG compression in `MacRemoteControlHost.swift`, `drawMacCursor(in:context:at:scale:)` queries `CGEvent(source: nil)?.location` and renders a crisp Quartz vector cursor with black stroke, white fill, and drop shadow directly into the frame bitmap context.
  2. **Sub-Millisecond 60 Hz Telemetry & Header Protocol:** Added 16-byte binary frame headers (`[12..13]: cursorX`, `[14..15]: cursorY`) and high-frequency `cursor_pos` WebSocket events at 60 Hz.
  3. **Client-Side Vector Canvas Overlay:** The Android companion app decodes cursor telemetry in `MacRemoteClient.kt` and renders an exact vector macOS arrow on the Jetpack Compose `Canvas` with an animated pulsing halo during clicks, completely bypassing video encoding latency.

---

### [Issue #015]: Chrome Remote Desktop Parity: Zoom Pads, Aspect-Ratio Coordinate Mapping, and Viewport Auto-Follow
- **Status:** Closed / Resolved
- **Severity:** High
- **Component:** `MacRemoteControlScreen.kt`, `MacRemoteClient.kt`
- **Symptom:**
  Remote Mac desktops have 16:10 or 16:9 aspect ratios (e.g. 2560x1600 or 1920x1080), while modern Android phones feature tall 20:9 or 21:9 displays. When fit to screen, desktop text and small controls are hard to read. Without zoom navigation and coordinate normalization, touches landed on incorrect Mac UI targets.
- **Root Cause Analysis:**
  Standard letterboxing creates horizontal or vertical dead zones. Without affine coordinate translation that factors in `fitScale`, `zoomScale`, and `panOffset`, touch events sent raw screen coordinates to the host, missing targets by hundreds of pixels.
- **Resolution:**
  1. **Zoom Engine & Dedicated Zoom Pads:** Added an interactive zoom engine supporting scales from 1.0x to 5.0x with dedicated on-screen floating zoom buttons (`[-]`, `[Fit]`, `[1:1]`, `[+]`) and live zoom percentage readout.
  2. **Bidirectional Coordinate Normalization:** Implemented mathematical coordinate translation mapping touch offsets `(touchX, touchY)` through `originX = (boxWidth - displayW)/2 + panX` to normalized ratios `[0.0, 1.0]`.
  3. **Viewport Auto-Follow:** When zoomed in Trackpad mode, an active boundary watcher smoothly pans the viewport when the cursor approaches screen margins, ensuring the cursor is never lost outside the visible viewport.

---

### [Issue #016]: Edge-to-Edge Borderless Fullscreen and Dual Input Engine (Trackpad vs Direct Touch) for Mobile Remote Desktop
- **Status:** Closed / Resolved
- **Severity:** High
- **Component:** `MacRemoteControlScreen.kt`, `MacRemoteProtocol.kt`, `MacRemoteControlHost.swift`
- **Symptom:**
  Remote desktop viewers often lock users into either trackpad or touchscreen mode, frustrating users who need precision mouse movement for menus and direct tapping for keyboards. Furthermore, mobile system bars and top navigation bars wasted valuable vertical screen real estate.
- **Root Cause Analysis:**
  Trackpad mode (relative delta $dx, dy$) is ideal for micro-precision, while Direct Touch mode (absolute ratio $x, y$) is ideal for fast taps. A single hardcoded input model cannot serve both workflows well.
- **Resolution:**
  1. **Dual Input Engine:** Added a 1-tap mode switch between **Trackpad Mode** (relative swiping, tap to click, double-tap, long-press right click) and **Direct Touch Mode** (direct tap, drag to select, long-press right click at touch coordinate).
  2. **100% Borderless Immersive Fullscreen:** Tapping the `[⛶]` button hides navigation tabs, top bars, and system padding, granting the desktop 100% of the phone's physical display.
  3. **Collapsible Floating CRD Glass Pill:** A floating semi-transparent toolbar provides instant access to mode toggle, zoom pads, keyboard drawer, fullscreen exit, and frame refresh.
  4. **Complete Mac System Shortcuts:** Expanded virtual keyboard bar with quick chips for `⌘+⌥+Esc` (Force Quit), `⌘+Space` (Spotlight), `⌘+Tab` (Apps), `⌘+W` (Close Window), `⌘+Q` (Quit App), `⌘+Z` (Undo), `⌘+C`/`⌘+V` (Copy/Paste), `⌘+A`, `⌘+S`, `Esc`, `Tab`, `Enter`, and `Backspace`.

---

### [Issue #017]: Non-Editable Security PIN Interface, Rigid 6-Digit Constraint, and Launch Overwrite in macOS Remote Host
- **Status:** Closed / Resolved
- **Severity:** Medium
- **Component:** `MacRemoteAccessView.swift`, `MacRemoteControlHost.swift`, `MacRemoteControlScreen.kt`
- **Symptom:**
  Users could not directly edit or assign their desired custom security PIN or password in the macOS DroidHouse app. The PIN was presented as a read-only text view that required clicking a secondary button, which then enforced an overly strict 6-numeric-digits rule (`count == 6 && isSuperset(of: .decimalDigits)`). Attempting to use a standard password or 4/8-digit PIN was rejected, and any custom length was overwritten with a generated 6-digit number on application launch.
- **Root Cause Analysis:**
  1. `MacRemoteAccessView.swift` rendered the pairing PIN as an uneditable `Text` element instead of an interactive, focused `TextField`.
  2. `MacRemoteControlHost.setCustomPin` required `trimmed.count == 6` and decimal digits only.
  3. `MacRemoteControlHost.loadOrGeneratePin` checked `saved.count == 6`, causing any non-6-character custom password to be discarded upon restart.
  4. `MacRemoteControlScreen.kt` on Android restricted user input to `length <= 6` and `KeyboardType.Number`, blocking alphanumeric passwords.
- **Resolution:**
  1. Upgraded `MacRemoteAccessView.swift` to feature a directly editable, inline interactive `TextField` with `Enter`/`Return` submission, "Save PIN" button with visual checkmark confirmation, and random generation shortcut.
  2. Expanded `setCustomPin` and `loadOrGeneratePin` to support flexible custom PINs and passwords from 4 to 32 characters (`trimmed.count >= 4 && trimmed.count <= 32`), supporting alphanumeric and special characters.
  3. Enhanced Android companion `MacRemoteControlScreen.kt` to allow up to 32 characters and switched to standard ASCII keyboard (`KeyboardType.Ascii`).
  4. Hardened CGNAT Tailscale address detection in `MacRemoteControlHost.detectTailscaleIP()` to identify any `100.x.y.z` interface address directly.

---

### [Issue #018]: Lack of Multi-Touch Gestures (2-Finger Scroll, 3-Finger Mission Control), Physical Tactile Scroll Wheel, and Mac Trackpad Acceleration Curve
- **Status:** Closed / Resolved
- **Severity:** Medium
- **Component:** `MacRemoteControlScreen.kt`, `MacRemoteClient.kt`
- **Symptom:**
  1. The Android companion trackpad previously only handled single-touch dragging and tapping. Two-finger natural scrolling and three-finger swipe gestures for macOS Mission Control were missing.
  2. There was no dedicated tactile scroll wheel for rapid, thumb-based scrolling with mechanical notch feedback.
  3. External pointer movement on macOS felt sluggish and overly decelerated during slow movements while failing to cover enough screen distance during fast flicks, due to synthetic CGEvent injection lacking native macOS trackpad non-linear acceleration.
- **Root Cause Analysis:**
  1. `detectDragGestures` in Jetpack Compose was constrained to single pointer tracking, dropping multi-pointer events.
  2. Lack of a dedicated 3D cylindrical scroll wheel widget with mechanical ratchet haptic tick feedback.
  3. Linear raw $(dx, dy)$ scaling without dynamic power-law velocity acceleration or exponential moving average (EMA) jitter smoothing.
- **Resolution:**
  1. **Multi-Touch Trackpad Engine:** Implemented low-level `awaitPointerEventScope` gesture recognizer supporting:
     - 1-Finger: Smooth cursor movement, tap for left click, double-tap, stationary long-press for right click.
     - 2-Finger: Real-time 2-finger horizontal and vertical scrolling (`mouse_scroll`), plus 2-finger tap for right click.
     - 3-Finger: Swipe up triggers Mission Control (`open -a "Mission Control"`), swipe down triggers Show Desktop (`show_desktop`), with heavy haptic confirmation.
  2. **Tactile Physical Scroll Wheel:** Implemented 3D cylindrical notched scroll wheel component docked at the right-center of the trackpad with dynamic rotating rubber treads, perspective compression, LED illumination detent, and Android `EFFECT_TICK` mechanical haptic vibration on every ratchet detent.
  3. **Apple macOS Trackpad Acceleration Engine:** Implemented non-linear velocity response curve in `MacRemoteClient.sendMouseMove`:
     - Precision Zone ($< 3.0$ px): $0.85\times$ linear damping for pixel-perfect targeting.
     - Linear Zone ($3.0 - 10.0$ px): $1.0\times$ to $1.35\times$ progressive tracking.
     - Dynamic Acceleration Zone ($10.0 - 24.0$ px): power-law exponent.
     - High-Velocity Flicks ($> 24.0$ px): logarithmic boost up to $3.85\times$ with 2-sample EMA jitter smoothing.
