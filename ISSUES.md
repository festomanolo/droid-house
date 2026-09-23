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

