package com.droidhouse.companion

import android.content.Context
import android.graphics.Bitmap
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Fill
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.VolumeDown
import androidx.compose.material.icons.automirrored.filled.VolumeMute
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.BrightnessHigh
import androidx.compose.material.icons.filled.BrightnessLow
import androidx.compose.material.icons.filled.DesktopWindows
import androidx.compose.material.icons.filled.FastForward
import androidx.compose.material.icons.filled.FastRewind
import androidx.compose.material.icons.filled.Keyboard
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Mouse
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.foundation.BorderStroke
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.FitScreen
import androidx.compose.material.icons.filled.Fullscreen
import androidx.compose.material.icons.filled.FullscreenExit
import androidx.compose.material.icons.filled.PowerSettingsNew
import androidx.compose.material.icons.filled.Radio
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.ScreenShare
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.TouchApp
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.Tv
import androidx.compose.material.icons.filled.ZoomIn
import androidx.compose.material.icons.filled.ZoomOut
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Tab
import androidx.compose.material3.TabRow
import androidx.compose.material3.TabRowDefaults
import androidx.compose.material3.TabRowDefaults.tabIndicatorOffset
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay

private fun Color.opacity(alpha: Float): Color = this.copy(alpha = alpha)

// MARK: - Dual Mouse Input Modes (Chrome Remote Desktop interaction model)
enum class MouseInputMode {
    TRACKPAD,     // Relative swipe, tap = click, 2-finger scroll, follows cursor
    DIRECT_TOUCH  // Direct tap & drag at exact screen coordinates
}

// MARK: - Mac Remote Control Screen (Jetpack Compose)
//
// Full-screen spatial companion interface for controlling macOS remotely over
// WAN (Tailscale/Internet) or local Wi-Fi. Features a fluid trackpad, live desktop
// streaming with Chrome Remote Desktop features (zoom pads, full-screen, dual mouse modes),
// system power and media controls, and virtual Mac keyboard typing.

@Composable
fun MacRemoteControlScreen(
    onNavigateBack: () -> Unit
) {
    val context = LocalContext.current
    val client = remember { MacRemoteClient.shared }

    var hostText by remember { mutableStateOf(client.getSavedHost(context).ifEmpty { "192.168.1.116" }) }
    var portText by remember { mutableStateOf(client.getSavedPort(context).toString()) }
    var pinText by remember { mutableStateOf(client.getSavedPin(context)) }

    var connectionState by remember { mutableStateOf(client.state) }
    var statusMessage by remember { mutableStateOf(client.statusMessage) }
    var macName by remember { mutableStateOf(client.connectedMacName) }
    var latencyMs by remember { mutableLongStateOf(client.rttLatencyMs) }
    var latestFrame by remember { mutableStateOf<Bitmap?>(null) }

    var cursorX by remember { mutableFloatStateOf(client.cursorXRatio) }
    var cursorY by remember { mutableFloatStateOf(client.cursorYRatio) }
    var isCursorDown by remember { mutableStateOf(client.isCursorDown) }

    var selectedTab by remember { mutableIntStateOf(0) } // 0: Trackpad, 1: Live Desktop, 2: Media & System
    var showKeyboardInput by remember { mutableStateOf(false) }
    var textInputState by remember { mutableStateOf("") }
    var showConfigPanel by remember { mutableStateOf(false) }

    // Chrome Remote Desktop Feature States
    var isFullscreen by remember { mutableStateOf(false) }
    var mouseMode by remember { mutableStateOf(MouseInputMode.TRACKPAD) }
    var zoomScale by remember { mutableFloatStateOf(1.0f) }
    var panOffset by remember { mutableStateOf(Offset.Zero) }

    val auroraPhase = rememberAuroraPhase()

    // Keep state in sync with client
    LaunchedEffect(Unit) {
        client.onStateChanged = { state, msg ->
            connectionState = state
            statusMessage = msg
            macName = client.connectedMacName
            if (state == MacRemoteClient.ConnectionState.CONNECTED) {
                showConfigPanel = false
            }
        }

        client.onFrameReceived = { bitmap ->
            latestFrame = bitmap
        }

        client.onCursorMoved = { x, y, down ->
            cursorX = x
            cursorY = y
            isCursorDown = down
        }

        while (true) {
            connectionState = client.state
            statusMessage = client.statusMessage
            macName = client.connectedMacName
            latencyMs = client.rttLatencyMs
            cursorX = client.cursorXRatio
            cursorY = client.cursorYRatio
            isCursorDown = client.isCursorDown
            delay(1000)
        }
    }

    DisposableEffect(selectedTab) {
        if (selectedTab == 1 && connectionState == MacRemoteClient.ConnectionState.CONNECTED) {
            client.setScreenStreaming(true)
        } else if (selectedTab != 1 && client.isScreenStreaming) {
            client.setScreenStreaming(false)
        }
        onDispose { }
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(Color(0xFF0A0C10))
    ) {
        AuroraBackground(phase = auroraPhase, intensity = if (connectionState == MacRemoteClient.ConnectionState.CONNECTED) 0.8f else 0.4f)

        Column(
            modifier = if (isFullscreen) {
                Modifier.fillMaxSize()
            } else {
                Modifier
                    .fillMaxSize()
                    .windowInsetsPadding(WindowInsets.systemBars)
            }
        ) {
            if (!isFullscreen) {
                // Top App Bar
                TopBar(
                    macName = macName,
                    connectionState = connectionState,
                    latencyMs = latencyMs,
                    onNavigateBack = onNavigateBack,
                    onToggleSettings = { showConfigPanel = !showConfigPanel }
                )

                // Connection Settings Panel (Collapsible)
                AnimatedVisibility(
                    visible = showConfigPanel || connectionState != MacRemoteClient.ConnectionState.CONNECTED,
                    enter = fadeIn(),
                    exit = fadeOut()
                ) {
                    ConnectionCard(
                        host = hostText,
                        port = portText,
                        pin = pinText,
                        connectionState = connectionState,
                        statusMessage = statusMessage,
                        onHostChange = {
                            hostText = it
                            val p = portText.toIntOrNull() ?: MacRemoteProtocol.DEFAULT_PORT
                            client.saveConnectionDetails(context, it, p, pinText)
                        },
                        onPortChange = {
                            portText = it
                            val p = it.toIntOrNull() ?: MacRemoteProtocol.DEFAULT_PORT
                            client.saveConnectionDetails(context, hostText, p, pinText)
                        },
                        onPinChange = {
                            pinText = it
                            val p = portText.toIntOrNull() ?: MacRemoteProtocol.DEFAULT_PORT
                            client.saveConnectionDetails(context, hostText, p, it)
                        },
                        onConnect = {
                            val p = portText.toIntOrNull() ?: MacRemoteProtocol.DEFAULT_PORT
                            client.saveConnectionDetails(context, hostText, p, pinText)
                            client.connect(hostText, p, pinText)
                        },
                        onDisconnect = {
                            client.disconnect()
                        }
                    )
                }

                // Mode Tabs (Trackpad / Desktop Stream / Media & System)
                ModeTabs(
                    selectedTab = selectedTab,
                    onSelectTab = { newTab ->
                        selectedTab = newTab
                        if (newTab == 1 && connectionState == MacRemoteClient.ConnectionState.CONNECTED) {
                            client.setScreenStreaming(true)
                        } else if (newTab != 1 && client.isScreenStreaming) {
                            client.setScreenStreaming(false)
                        }
                    }
                )
            }

            // Virtual Keyboard Drawer (if toggled)
            AnimatedVisibility(visible = showKeyboardInput) {
                VirtualKeyboardBar(
                    text = textInputState,
                    onTextChange = { textInputState = it },
                    onSend = {
                        if (textInputState.isNotEmpty()) {
                            client.sendKeyText(textInputState)
                            textInputState = ""
                        }
                    },
                    onKeyCombo = { client.sendKeyCombo(it) },
                    onClose = { showKeyboardInput = false }
                )
            }

            // Tab Content
            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
            ) {
                when (selectedTab) {
                    0 -> TrackpadPane(
                        client = client,
                        isConnected = connectionState == MacRemoteClient.ConnectionState.CONNECTED,
                        cursorX = cursorX,
                        cursorY = cursorY,
                        onToggleKeyboard = { showKeyboardInput = !showKeyboardInput }
                    )
                    1 -> LiveDesktopPane(
                        client = client,
                        frame = latestFrame,
                        isConnected = connectionState == MacRemoteClient.ConnectionState.CONNECTED,
                        cursorX = cursorX,
                        cursorY = cursorY,
                        isCursorDown = isCursorDown,
                        mouseMode = mouseMode,
                        onToggleMouseMode = {
                            mouseMode = if (mouseMode == MouseInputMode.TRACKPAD) MouseInputMode.DIRECT_TOUCH else MouseInputMode.TRACKPAD
                        },
                        zoomScale = zoomScale,
                        onZoomChange = { zoomScale = it },
                        panOffset = panOffset,
                        onPanChange = { panOffset = it },
                        isFullscreen = isFullscreen,
                        onToggleFullscreen = {
                            isFullscreen = !isFullscreen
                            if (isFullscreen) {
                                selectedTab = 1
                            }
                        },
                        showKeyboard = showKeyboardInput,
                        onToggleKeyboard = { showKeyboardInput = !showKeyboardInput }
                    )
                    2 -> SystemMediaPane(
                        client = client,
                        isConnected = connectionState == MacRemoteClient.ConnectionState.CONNECTED
                    )
                }
            }
        }
    }
}

// MARK: - Top Bar

@Composable
private fun TopBar(
    macName: String?,
    connectionState: MacRemoteClient.ConnectionState,
    latencyMs: Long,
    onNavigateBack: () -> Unit,
    onToggleSettings: () -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        IconButton(onClick = onNavigateBack) {
            Icon(
                imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                contentDescription = "Back",
                tint = Color.White
            )
        }

        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = macName ?: "Mac Remote Control",
                style = MaterialTheme.typography.titleMedium.copy(
                    fontWeight = FontWeight.Bold,
                    color = Color.White
                )
            )

            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                val (color, label) = when (connectionState) {
                    MacRemoteClient.ConnectionState.CONNECTED -> Color(0xFF22C55E) to "Connected"
                    MacRemoteClient.ConnectionState.CONNECTING -> Color(0xFFF59E0B) to "Connecting…"
                    MacRemoteClient.ConnectionState.AUTHENTICATING -> Color(0xFF3B82F6) to "Authenticating…"
                    MacRemoteClient.ConnectionState.FAILED -> Color(0xFFEF4444) to "Failed"
                    MacRemoteClient.ConnectionState.DISCONNECTED -> Color.Gray to "Disconnected"
                }

                Box(
                    modifier = Modifier
                        .size(6.dp)
                        .clip(CircleShape)
                        .background(color)
                )

                Text(
                    text = label,
                    style = MaterialTheme.typography.bodySmall.copy(
                        color = color,
                        fontSize = 11.sp
                    )
                )

                if (connectionState == MacRemoteClient.ConnectionState.CONNECTED && latencyMs > 0) {
                    Text(
                        text = "• ${latencyMs}ms",
                        style = MaterialTheme.typography.bodySmall.copy(
                            color = Color.White.opacity(0.6f),
                            fontSize = 11.sp
                        )
                    )
                }
            }
        }

        IconButton(onClick = onToggleSettings) {
            Icon(
                imageVector = Icons.Default.Tune,
                contentDescription = "Settings",
                tint = Color.White.opacity(0.8f)
            )
        }
    }
}

// MARK: - Connection Card

@Composable
private fun ConnectionCard(
    host: String,
    port: String,
    pin: String,
    connectionState: MacRemoteClient.ConnectionState,
    statusMessage: String,
    onHostChange: (String) -> Unit,
    onPortChange: (String) -> Unit,
    onPinChange: (String) -> Unit,
    onConnect: () -> Unit,
    onDisconnect: () -> Unit
) {
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 6.dp),
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(containerColor = Color(0xFF141822).opacity(0.92f))
    ) {
        Column(
            modifier = Modifier.padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            Text(
                text = "Target Mac (WAN, Tailscale, or LAN IP)",
                style = MaterialTheme.typography.labelSmall.copy(
                    color = Color.White.opacity(0.7f),
                    fontWeight = FontWeight.Medium
                )
            )

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = host,
                    onValueChange = onHostChange,
                    modifier = Modifier.weight(2.5f),
                    placeholder = { Text("e.g. 100.84.x.x or IP", color = Color.Gray, fontSize = 13.sp) },
                    singleLine = true,
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedTextColor = Color.White,
                        unfocusedTextColor = Color.White,
                        focusedBorderColor = Color(0xFF38BDF8),
                        unfocusedBorderColor = Color.White.opacity(0.15f)
                    ),
                    shape = RoundedCornerShape(10.dp)
                )

                OutlinedTextField(
                    value = port,
                    onValueChange = onPortChange,
                    modifier = Modifier.weight(1f),
                    placeholder = { Text("Port", color = Color.Gray, fontSize = 13.sp) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedTextColor = Color.White,
                        unfocusedTextColor = Color.White,
                        focusedBorderColor = Color(0xFF38BDF8),
                        unfocusedBorderColor = Color.White.opacity(0.15f)
                    ),
                    shape = RoundedCornerShape(10.dp)
                )
            }

            OutlinedTextField(
                value = pin,
                onValueChange = { if (it.length <= 32) onPinChange(it) },
                modifier = Modifier.fillMaxWidth(),
                placeholder = { Text("Security PIN or Password (set on Mac)", color = Color.Gray, fontSize = 13.sp) },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Ascii),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedTextColor = Color.White,
                    unfocusedTextColor = Color.White,
                    focusedBorderColor = Color(0xFF38BDF8),
                    unfocusedBorderColor = Color.White.opacity(0.15f)
                ),
                shape = RoundedCornerShape(10.dp)
            )

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = statusMessage,
                    style = MaterialTheme.typography.bodySmall.copy(
                        color = Color.White.opacity(0.6f),
                        fontSize = 11.sp
                    ),
                    modifier = Modifier.weight(1f)
                )

                if (connectionState == MacRemoteClient.ConnectionState.CONNECTED) {
                    Button(
                        onClick = onDisconnect,
                        colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFEF4444)),
                        shape = RoundedCornerShape(8.dp)
                    ) {
                        Text("Disconnect", fontSize = 12.sp)
                    }
                } else {
                    Button(
                        onClick = onConnect,
                        colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF2563EB)),
                        shape = RoundedCornerShape(8.dp)
                    ) {
                        Text(if (connectionState == MacRemoteClient.ConnectionState.CONNECTING) "Connecting…" else "Connect to Mac", fontSize = 12.sp)
                    }
                }
            }
        }
    }
}

// MARK: - Mode Tabs

@Composable
private fun ModeTabs(
    selectedTab: Int,
    onSelectTab: (Int) -> Unit
) {
    val tabTitles = listOf("Trackpad", "Desktop Live", "Media & Power")

    TabRow(
        selectedTabIndex = selectedTab,
        containerColor = Color.Transparent,
        contentColor = Color.White,
        indicator = { tabPositions ->
            TabRowDefaults.SecondaryIndicator(
                modifier = Modifier.tabIndicatorOffset(tabPositions[selectedTab]),
                color = Color(0xFF38BDF8),
                height = 3.dp
            )
        },
        divider = { }
    ) {
        tabTitles.forEachIndexed { index, title ->
            Tab(
                selected = selectedTab == index,
                onClick = { onSelectTab(index) },
                text = {
                    Text(
                        text = title,
                        style = MaterialTheme.typography.labelMedium.copy(
                            fontWeight = if (selectedTab == index) FontWeight.Bold else FontWeight.Normal,
                            color = if (selectedTab == index) Color.White else Color.White.opacity(0.6f)
                        )
                    )
                }
            )
        }
    }
}

// MARK: - Trackpad Pane

@Composable
private fun TrackpadPane(
    client: MacRemoteClient,
    isConnected: Boolean,
    cursorX: Float,
    cursorY: Float,
    onToggleKeyboard: () -> Unit
) {
    val context = LocalContext.current
    var activeGestureHint by remember { mutableStateOf<String?>(null) }
    var lastTapTimestamp by remember { mutableLongStateOf(0L) }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        // Trackpad Surface Container
        Box(
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth()
                .clip(RoundedCornerShape(20.dp))
                .background(Color(0xFF131722).opacity(0.85f))
                .border(1.dp, Color.White.opacity(0.08f), RoundedCornerShape(20.dp))
        ) {
            // Touch & Gestures Detection Area (Multi-Touch: 1-finger move/tap, 2-finger scroll/tap, 3-finger Mission Control)
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .pointerInput(isConnected) {
                        if (!isConnected) return@pointerInput

                        awaitEachGesture {
                            val firstDown = awaitFirstDown(requireUnconsumed = false)
                            var maxPointers = 1
                            var totalDist1 = 0f
                            val startTime = System.currentTimeMillis()
                            var isLongPressFired = false
                            var missionControlTriggered = false
                            var showDesktopTriggered = false
                            var threeFingerAccumY = 0f
                            var twoFingerTapEligible = true
                            var twoFingerStartTime = 0L

                            do {
                                val event = awaitPointerEvent()
                                val pressed = event.changes.filter { it.pressed }
                                val currentCount = pressed.size

                                if (currentCount > maxPointers) {
                                    maxPointers = currentCount
                                }

                                if (currentCount == 1 && maxPointers == 1) {
                                    val change = pressed.first()
                                    val delta = change.position - change.previousPosition
                                    totalDist1 += delta.getDistance()

                                    // Long-press detection (stationary > 500ms -> Right Click)
                                    if (!isLongPressFired && totalDist1 < 12f && (System.currentTimeMillis() - startTime >= 500L)) {
                                        isLongPressFired = true
                                        triggerHaptic(context)
                                        activeGestureHint = "Right Click"
                                        client.sendMouseClick("right")
                                    }

                                    if (totalDist1 > 6f) {
                                        client.sendMouseMove(delta.x, delta.y)
                                    }
                                    change.consume()
                                } else if (currentCount == 2) {
                                    if (twoFingerStartTime == 0L) {
                                        twoFingerStartTime = System.currentTimeMillis()
                                    }
                                    val c0 = pressed[0]
                                    val c1 = pressed[1]
                                    val d0 = c0.position - c0.previousPosition
                                    val d1 = c1.position - c1.previousPosition
                                    val avgDx = (d0.x + d1.x) / 2f
                                    val avgDy = (d0.y + d1.y) / 2f

                                    if (Math.abs(avgDx) > 2f || Math.abs(avgDy) > 2f) {
                                        twoFingerTapEligible = false
                                        activeGestureHint = "↕ Two-Finger Scrolling"
                                        client.sendMouseScroll(avgDx, avgDy)
                                    }
                                    pressed.forEach { it.consume() }
                                } else if (currentCount >= 3) {
                                    twoFingerTapEligible = false
                                    val avgDy = pressed.map { it.position.y - it.previousPosition.y }.average().toFloat()
                                    threeFingerAccumY += avgDy

                                    // Swipe UP (accumulated negative deltaY) -> Mission Control
                                    if (!missionControlTriggered && threeFingerAccumY < -50f) {
                                        missionControlTriggered = true
                                        triggerMissionControlHaptic(context)
                                        activeGestureHint = "⎋ Mission Control"
                                        client.sendSystemAction(MacRemoteProtocol.SystemAction.MISSION_CONTROL.rawValue)
                                    } else if (!showDesktopTriggered && threeFingerAccumY > 50f) {
                                        showDesktopTriggered = true
                                        triggerMissionControlHaptic(context)
                                        activeGestureHint = "⌘ Show Desktop"
                                        client.sendSystemAction(MacRemoteProtocol.SystemAction.SHOW_DESKTOP.rawValue)
                                    }
                                    pressed.forEach { it.consume() }
                                }
                            } while (event.changes.any { it.pressed })

                            // All fingers lifted
                            val elapsed = System.currentTimeMillis() - startTime
                            if (maxPointers == 1 && totalDist1 < 12f && !isLongPressFired && elapsed < 300) {
                                triggerHaptic(context)
                                val now = System.currentTimeMillis()
                                if (now - lastTapTimestamp < 320) {
                                    client.sendMouseDoubleClick()
                                    lastTapTimestamp = 0L
                                } else {
                                    client.sendMouseClick("left")
                                    lastTapTimestamp = now
                                }
                            } else if (maxPointers == 2 && twoFingerTapEligible && (System.currentTimeMillis() - twoFingerStartTime < 350)) {
                                // Two-finger tap -> Right Click!
                                triggerHaptic(context)
                                activeGestureHint = "Right Click"
                                client.sendMouseClick("right")
                            }

                            activeGestureHint = null
                        }
                    }
            )

            // Header HUD & Radar Controls inside Trackpad
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(16.dp),
                verticalArrangement = Arrangement.SpaceBetween,
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column {
                        Text(
                            text = if (isConnected) "Multi-Touch Glass Trackpad" else "Connect to Mac to enable trackpad",
                            style = MaterialTheme.typography.bodySmall.copy(color = Color.White.opacity(0.4f))
                        )
                        if (isConnected) {
                            Text(
                                text = "Cursor: X: ${(cursorX * 100).toInt()}% • Y: ${(cursorY * 100).toInt()}%",
                                style = MaterialTheme.typography.labelSmall.copy(
                                    color = Color(0xFF38BDF8),
                                    fontWeight = FontWeight.SemiBold,
                                    fontSize = 11.sp
                                )
                            )
                        }
                    }

                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        if (isConnected) {
                            // Mini Screen Radar View
                            Box(
                                modifier = Modifier
                                    .width(48.dp)
                                    .height(28.dp)
                                    .clip(RoundedCornerShape(4.dp))
                                    .background(Color.Black.opacity(0.6f))
                                    .border(1.dp, Color(0xFF38BDF8).opacity(0.4f), RoundedCornerShape(4.dp))
                            ) {
                                Canvas(modifier = Modifier.fillMaxSize()) {
                                    val dotX = cursorX * size.width
                                    val dotY = cursorY * size.height
                                    drawCircle(
                                        color = Color(0xFF38BDF8).copy(alpha = 0.4f),
                                        radius = 4.dp.toPx(),
                                        center = Offset(dotX, dotY)
                                    )
                                    drawCircle(
                                        color = Color.White,
                                        radius = 2.dp.toPx(),
                                        center = Offset(dotX, dotY)
                                    )
                                }
                            }
                        }

                        IconButton(onClick = onToggleKeyboard) {
                            Icon(
                                imageVector = Icons.Default.Keyboard,
                                contentDescription = "Keyboard",
                                tint = Color.White.opacity(0.7f)
                            )
                        }
                    }
                }

                if (!isConnected) {
                    Icon(
                        imageVector = Icons.Default.Mouse,
                        contentDescription = null,
                        tint = Color.White.opacity(0.15f),
                        modifier = Modifier.size(48.dp)
                    )
                }

                Text(
                    text = "1-Finger: Move/Tap • 2-Finger: Scroll/Right-Click • 3-Finger: Mission Control",
                    style = MaterialTheme.typography.labelSmall.copy(
                        color = Color.White.opacity(0.35f),
                        fontSize = 10.sp
                    )
                )
            }

            // Tactile Scroll Wheel - Docked at Right Center of Trackpad with Haptic Feedback
            if (isConnected) {
                Box(
                    modifier = Modifier
                        .align(Alignment.CenterEnd)
                        .padding(end = 12.dp)
                ) {
                    TactileScrollWheel(
                        modifier = Modifier
                            .width(46.dp)
                            .height(190.dp),
                        enabled = isConnected,
                        onScroll = { deltaY ->
                            client.sendMouseScroll(0f, deltaY)
                        },
                        onNotchTick = {
                            triggerScrollNotchHaptic(context)
                        }
                    )
                }
            }

            // Active Gesture HUD Pill Banner (Center of Trackpad)
            androidx.compose.animation.AnimatedVisibility(
                visible = activeGestureHint != null,
                enter = fadeIn() + scaleIn(),
                exit = fadeOut() + scaleOut(),
                modifier = Modifier.align(Alignment.Center)
            ) {
                Box(
                    modifier = Modifier
                        .clip(RoundedCornerShape(20.dp))
                        .background(Color(0xFF0F172A).copy(alpha = 0.94f))
                        .border(1.dp, Color(0xFF38BDF8).copy(alpha = 0.65f), RoundedCornerShape(20.dp))
                        .padding(horizontal = 16.dp, vertical = 9.dp)
                ) {
                    Text(
                        text = activeGestureHint ?: "",
                        style = MaterialTheme.typography.labelMedium.copy(
                            fontWeight = FontWeight.Bold,
                            color = Color(0xFF38BDF8),
                            fontSize = 13.sp
                        )
                    )
                }
            }
        }

        // Discrete Click Buttons
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            Box(
                modifier = Modifier
                    .weight(1.5f)
                    .height(56.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .background(Color(0xFF1E2433))
                    .border(1.dp, Color.White.opacity(0.1f), RoundedCornerShape(12.dp))
                    .clickable(enabled = isConnected) {
                        triggerHaptic(context)
                        client.sendMouseClick("left")
                    },
                contentAlignment = Alignment.Center
            ) {
                Text(
                    text = "Left Click",
                    style = MaterialTheme.typography.labelMedium.copy(
                        fontWeight = FontWeight.SemiBold,
                        color = if (isConnected) Color.White else Color.Gray
                    )
                )
            }

            Box(
                modifier = Modifier
                    .weight(1f)
                    .height(56.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .background(Color(0xFF1E2433))
                    .border(1.dp, Color.White.opacity(0.1f), RoundedCornerShape(12.dp))
                    .clickable(enabled = isConnected) {
                        triggerHaptic(context)
                        client.sendMouseClick("right")
                    },
                contentAlignment = Alignment.Center
            ) {
                Text(
                    text = "Right Click",
                    style = MaterialTheme.typography.labelMedium.copy(
                        fontWeight = FontWeight.SemiBold,
                        color = if (isConnected) Color.White else Color.Gray
                    )
                )
            }
        }
    }
}

// MARK: - Tactile Physical Scroll Wheel Component

@Composable
private fun TactileScrollWheel(
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    onScroll: (deltaY: Float) -> Unit,
    onNotchTick: () -> Unit
) {
    var accumulatedDelta by remember { mutableFloatStateOf(0f) }
    var wheelAngle by remember { mutableFloatStateOf(0f) }
    var isTouching by remember { mutableStateOf(false) }

    Box(
        modifier = modifier
            .clip(RoundedCornerShape(24.dp))
            .background(
                Brush.verticalGradient(
                    colors = listOf(
                        Color(0xFF0F141F),
                        Color(0xFF181F2E),
                        Color(0xFF0F141F)
                    )
                )
            )
            .border(
                1.5.dp,
                Brush.verticalGradient(
                    colors = listOf(
                        Color(0xFF38BDF8).copy(alpha = if (isTouching) 0.65f else 0.25f),
                        Color.White.copy(alpha = 0.12f),
                        Color(0xFF38BDF8).copy(alpha = if (isTouching) 0.55f else 0.18f)
                    )
                ),
                RoundedCornerShape(24.dp)
            )
            .pointerInput(enabled) {
                if (!enabled) return@pointerInput
                detectDragGestures(
                    onDragStart = { isTouching = true },
                    onDragEnd = { isTouching = false },
                    onDragCancel = { isTouching = false },
                    onDrag = { change, dragAmount ->
                        change.consume()
                        val dy = dragAmount.y
                        wheelAngle += dy * 0.85f
                        accumulatedDelta += dy

                        val notchThreshold = 18f
                        while (Math.abs(accumulatedDelta) >= notchThreshold) {
                            val sign = if (accumulatedDelta > 0) 1f else -1f
                            onNotchTick()
                            onScroll(sign * 24f)
                            accumulatedDelta -= sign * notchThreshold
                        }
                    }
                )
            },
        contentAlignment = Alignment.Center
    ) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            val w = size.width
            val h = size.height

            // 1. 3D curved cylinder shading (radial/horizontal lighting)
            drawRoundRect(
                brush = Brush.horizontalGradient(
                    colors = listOf(
                        Color(0xFF0A0D14),
                        Color(0xFF263045),
                        Color(0xFF323F5A),
                        Color(0xFF263045),
                        Color(0xFF0A0D14)
                    )
                ),
                cornerRadius = CornerRadius(22.dp.toPx())
            )

            // 2. Tactile rib ridges / notches with perspective projection
            val ribSpacing = 16.dp.toPx()
            val totalRibs = (h / ribSpacing).toInt() + 4
            val baseOffset = (wheelAngle % ribSpacing + ribSpacing) % ribSpacing

            for (i in -2..totalRibs) {
                val y = i * ribSpacing + baseOffset
                if (y in -8f..(h + 8f)) {
                    val distFromCenter = Math.abs(y - h / 2f) / (h / 2f)
                    val alpha = (1f - distFromCenter * 0.75f).coerceIn(0.12f, 1f)
                    val notchW = w * (0.80f - distFromCenter * 0.16f)
                    val left = (w - notchW) / 2f
                    val right = left + notchW

                    // Highlight rim (light metallic)
                    drawLine(
                        color = Color.White.copy(alpha = alpha * 0.38f),
                        start = Offset(left, y),
                        end = Offset(right, y),
                        strokeWidth = 2.dp.toPx(),
                        cap = StrokeCap.Round
                    )
                    // Groove shadow (deep black)
                    drawLine(
                        color = Color.Black.copy(alpha = alpha * 0.9f),
                        start = Offset(left, y + 2.dp.toPx()),
                        end = Offset(right, y + 2.dp.toPx()),
                        strokeWidth = 2.dp.toPx(),
                        cap = StrokeCap.Round
                    )
                }
            }

            // 3. Center LED illumination detent pip
            val centerIndicatorAlpha = if (isTouching) 0.95f else 0.55f
            drawRoundRect(
                color = Color(0xFF38BDF8).copy(alpha = centerIndicatorAlpha),
                topLeft = Offset(w * 0.22f, h / 2f - 1.5.dp.toPx()),
                size = Size(w * 0.56f, 3.dp.toPx()),
                cornerRadius = CornerRadius(2.dp.toPx())
            )

            // 4. Recessed top/bottom shadow vignettes
            drawRect(
                brush = Brush.verticalGradient(
                    colors = listOf(
                        Color.Black.copy(alpha = 0.88f),
                        Color.Black.copy(alpha = 0.35f),
                        Color.Transparent
                    ),
                    startY = 0f,
                    endY = h * 0.26f
                )
            )
            drawRect(
                brush = Brush.verticalGradient(
                    colors = listOf(
                        Color.Transparent,
                        Color.Black.copy(alpha = 0.35f),
                        Color.Black.copy(alpha = 0.88f)
                    ),
                    startY = h * 0.74f,
                    endY = h
                )
            )
        }

        // Top & bottom subtle arrow chevrons
        Column(
            modifier = Modifier
                .fillMaxHeight()
                .padding(vertical = 8.dp),
            verticalArrangement = Arrangement.SpaceBetween,
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Icon(
                imageVector = Icons.Default.KeyboardArrowUp,
                contentDescription = "Scroll Up",
                tint = Color.White.copy(alpha = if (isTouching) 0.85f else 0.4f),
                modifier = Modifier.size(16.dp)
            )
            Icon(
                imageVector = Icons.Default.KeyboardArrowDown,
                contentDescription = "Scroll Down",
                tint = Color.White.copy(alpha = if (isTouching) 0.85f else 0.4f),
                modifier = Modifier.size(16.dp)
            )
        }
    }
}

// MARK: - Live Desktop Pane (Chrome Remote Desktop Experience)

@Composable
private fun LiveDesktopPane(
    client: MacRemoteClient,
    frame: Bitmap?,
    isConnected: Boolean,
    cursorX: Float,
    cursorY: Float,
    isCursorDown: Boolean,
    mouseMode: MouseInputMode,
    onToggleMouseMode: () -> Unit,
    zoomScale: Float,
    onZoomChange: (Float) -> Unit,
    panOffset: Offset,
    onPanChange: (Offset) -> Unit,
    isFullscreen: Boolean,
    onToggleFullscreen: () -> Unit,
    showKeyboard: Boolean,
    onToggleKeyboard: () -> Unit
) {
    val context = LocalContext.current
    var isCrdToolsExpanded by remember { mutableStateOf(false) }

    BoxWithConstraints(
        modifier = Modifier
            .fillMaxSize()
            .then(
                if (!isFullscreen) {
                    Modifier
                        .padding(8.dp)
                        .clip(RoundedCornerShape(16.dp))
                        .border(1.dp, Color.White.opacity(0.1f), RoundedCornerShape(16.dp))
                } else {
                    Modifier
                }
            )
            .background(Color.Black),
        contentAlignment = Alignment.Center
    ) {
        val boxWidth = constraints.maxWidth.toFloat()
        val boxHeight = constraints.maxHeight.toFloat()

        if (frame != null && isConnected) {
            val frameW = frame.width.toFloat()
            val frameH = frame.height.toFloat()

            // Calculate precise aspect fit scaling and letterbox offsets
            val fitScale = minOf(boxWidth / frameW, boxHeight / frameH)
            val displayW = frameW * fitScale * zoomScale
            val displayH = frameH * fitScale * zoomScale

            val maxPanX = ((displayW - boxWidth) / 2f).coerceAtLeast(0f)
            val maxPanY = ((displayH - boxHeight) / 2f).coerceAtLeast(0f)

            val effectivePanX = panOffset.x.coerceIn(-maxPanX, maxPanX)
            val effectivePanY = panOffset.y.coerceIn(-maxPanY, maxPanY)

            val originX = (boxWidth - displayW) / 2f + effectivePanX
            val originY = (boxHeight - displayH) / 2f + effectivePanY

            val cursorPxX = originX + (cursorX * displayW)
            val cursorPxY = originY + (cursorY * displayH)

            // Auto-follow cursor when zoomed in Trackpad mode
            LaunchedEffect(cursorX, cursorY, zoomScale, mouseMode) {
                if (zoomScale > 1.0f && mouseMode == MouseInputMode.TRACKPAD) {
                    val margin = 80f
                    var curPanX = panOffset.x
                    var curPanY = panOffset.y
                    if (cursorPxX < margin) {
                        curPanX += (margin - cursorPxX)
                    } else if (cursorPxX > boxWidth - margin) {
                        curPanX -= (cursorPxX - (boxWidth - margin))
                    }
                    if (cursorPxY < margin) {
                        curPanY += (margin - cursorPxY)
                    } else if (cursorPxY > boxHeight - margin) {
                        curPanY -= (cursorPxY - (boxHeight - margin))
                    }
                    val cX = curPanX.coerceIn(-maxPanX, maxPanX)
                    val cY = curPanY.coerceIn(-maxPanY, maxPanY)
                    if (cX != panOffset.x || cY != panOffset.y) {
                        onPanChange(Offset(cX, cY))
                    }
                }
            }

            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .clipToBounds()
                    .pointerInput(mouseMode, zoomScale, originX, originY, displayW, displayH) {
                        if (mouseMode == MouseInputMode.DIRECT_TOUCH) {
                            detectTapGestures(
                                onTap = { offset ->
                                    val clickXRatio = ((offset.x - originX) / displayW).coerceIn(0f, 1f)
                                    val clickYRatio = ((offset.y - originY) / displayH).coerceIn(0f, 1f)
                                    triggerHaptic(context)
                                    client.sendMouseMoveAbs(clickXRatio, clickYRatio)
                                    client.sendMouseClick("left")
                                },
                                onDoubleTap = { offset ->
                                    val clickXRatio = ((offset.x - originX) / displayW).coerceIn(0f, 1f)
                                    val clickYRatio = ((offset.y - originY) / displayH).coerceIn(0f, 1f)
                                    triggerHaptic(context)
                                    client.sendMouseMoveAbs(clickXRatio, clickYRatio)
                                    client.sendMouseDoubleClick()
                                },
                                onLongPress = { offset ->
                                    val clickXRatio = ((offset.x - originX) / displayW).coerceIn(0f, 1f)
                                    val clickYRatio = ((offset.y - originY) / displayH).coerceIn(0f, 1f)
                                    triggerHaptic(context)
                                    client.sendMouseMoveAbs(clickXRatio, clickYRatio)
                                    client.sendMouseClick("right")
                                }
                            )
                        } else {
                            detectTapGestures(
                                onTap = {
                                    triggerHaptic(context)
                                    client.sendMouseClick("left")
                                },
                                onDoubleTap = {
                                    triggerHaptic(context)
                                    client.sendMouseDoubleClick()
                                },
                                onLongPress = {
                                    triggerHaptic(context)
                                    client.sendMouseClick("right")
                                }
                            )
                        }
                    }
                    .pointerInput(mouseMode, zoomScale, originX, originY, displayW, displayH) {
                        if (mouseMode == MouseInputMode.DIRECT_TOUCH) {
                            detectDragGestures(
                                onDragStart = { offset ->
                                    val clickXRatio = ((offset.x - originX) / displayW).coerceIn(0f, 1f)
                                    val clickYRatio = ((offset.y - originY) / displayH).coerceIn(0f, 1f)
                                    client.sendMouseMoveAbs(clickXRatio, clickYRatio)
                                    client.sendMouseDown("left")
                                },
                                onDragEnd = {
                                    client.sendMouseUp("left")
                                },
                                onDragCancel = {
                                    client.sendMouseUp("left")
                                },
                                onDrag = { change, _ ->
                                    change.consume()
                                    val clickXRatio = ((change.position.x - originX) / displayW).coerceIn(0f, 1f)
                                    val clickYRatio = ((change.position.y - originY) / displayH).coerceIn(0f, 1f)
                                    client.sendMouseMoveAbs(clickXRatio, clickYRatio)
                                }
                            )
                        } else {
                            detectDragGestures(
                                onDrag = { change, dragAmount ->
                                    change.consume()
                                    client.sendMouseMove(dragAmount.x, dragAmount.y)
                                }
                            )
                        }
                    }
            ) {
                // Desktop Frame Image with GPU acceleration, zoom scaling and translation
                Image(
                    bitmap = frame.asImageBitmap(),
                    contentDescription = "Mac Live Screen",
                    modifier = Modifier
                        .fillMaxSize()
                        .graphicsLayer {
                            scaleX = zoomScale
                            scaleY = zoomScale
                            translationX = effectivePanX
                            translationY = effectivePanY
                        },
                    contentScale = ContentScale.Fit
                )

                // High-Performance Real-Time Vector macOS Cursor Overlay
                Canvas(
                    modifier = Modifier.fillMaxSize()
                ) {
                    val s = 24.dp.toPx()

                    // Glowing Touch Halo / Pulse Indicator
                    drawCircle(
                        color = if (isCursorDown) Color(0xFF38BDF8).copy(alpha = 0.65f) else Color(0xFF38BDF8).copy(alpha = 0.32f),
                        radius = if (isCursorDown) 20.dp.toPx() else 15.dp.toPx(),
                        center = Offset(cursorPxX, cursorPxY)
                    )

                    // Draw Classic macOS Arrow Pointer Path
                    val path = Path().apply {
                        moveTo(cursorPxX, cursorPxY)
                        lineTo(cursorPxX, cursorPxY + s * 0.85f)
                        lineTo(cursorPxX + s * 0.22f, cursorPxY + s * 0.65f)
                        lineTo(cursorPxX + s * 0.42f, cursorPxY + s * 1.0f)
                        lineTo(cursorPxX + s * 0.58f, cursorPxY + s * 0.92f)
                        lineTo(cursorPxX + s * 0.38f, cursorPxY + s * 0.58f)
                        lineTo(cursorPxX + s * 0.68f, cursorPxY + s * 0.58f)
                        close()
                    }

                    // Shadow
                    drawPath(
                        path = path,
                        color = Color.Black.copy(alpha = 0.55f),
                        style = Fill
                    )

                    // White fill
                    drawPath(
                        path = path,
                        color = Color.White,
                        style = Fill
                    )

                    // Crisp black outline
                    drawPath(
                        path = path,
                        color = Color.Black,
                        style = Stroke(width = 2.0.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round)
                    )
                }

                // Floating Chrome Remote Desktop Tool Palette (Pill & Zoom Pad)
                Box(
                    modifier = Modifier
                        .align(Alignment.TopCenter)
                        .padding(top = if (isFullscreen) 16.dp else 10.dp)
                ) {
                    CrdFloatingToolbar(
                        isExpanded = isCrdToolsExpanded,
                        onToggleExpanded = { isCrdToolsExpanded = !isCrdToolsExpanded },
                        mouseMode = mouseMode,
                        onToggleMouseMode = onToggleMouseMode,
                        zoomScale = zoomScale,
                        onZoomIn = { onZoomChange((zoomScale + 0.25f).coerceAtMost(5.0f)) },
                        onZoomOut = {
                            val next = (zoomScale - 0.25f).coerceAtLeast(1.0f)
                            onZoomChange(next)
                            if (next == 1.0f) onPanChange(Offset.Zero)
                        },
                        onZoomFit = {
                            onZoomChange(1.0f)
                            onPanChange(Offset.Zero)
                        },
                        onZoomOneToOne = {
                            onZoomChange(2.0f)
                        },
                        isFullscreen = isFullscreen,
                        onToggleFullscreen = onToggleFullscreen,
                        showKeyboard = showKeyboard,
                        onToggleKeyboard = onToggleKeyboard,
                        onRefreshFrame = { client.requestSingleFrame() },
                        cursorX = cursorX,
                        cursorY = cursorY
                    )
                }
            }
        } else {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Icon(
                    imageVector = Icons.Default.Tv,
                    contentDescription = null,
                    tint = Color.White.opacity(0.2f),
                    modifier = Modifier.size(54.dp)
                )

                Text(
                    text = if (isConnected) "Starting Desktop Live Stream…" else "Connect to Mac to view screen",
                    style = MaterialTheme.typography.bodyMedium.copy(color = Color.White.opacity(0.5f))
                )

                if (isConnected) {
                    Button(
                        onClick = { client.requestSingleFrame() },
                        colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF2563EB)),
                        shape = RoundedCornerShape(8.dp)
                    ) {
                        Text("Refresh Screen Frame", fontSize = 12.sp)
                    }
                }
            }
        }
    }
}

// MARK: - Floating CRD Toolbar (Pill, Zoom Pads, Modes, Fullscreen)

@Composable
private fun CrdFloatingToolbar(
    isExpanded: Boolean,
    onToggleExpanded: () -> Unit,
    mouseMode: MouseInputMode,
    onToggleMouseMode: () -> Unit,
    zoomScale: Float,
    onZoomIn: () -> Unit,
    onZoomOut: () -> Unit,
    onZoomFit: () -> Unit,
    onZoomOneToOne: () -> Unit,
    isFullscreen: Boolean,
    onToggleFullscreen: () -> Unit,
    showKeyboard: Boolean,
    onToggleKeyboard: () -> Unit,
    onRefreshFrame: () -> Unit,
    cursorX: Float,
    cursorY: Float
) {
    Surface(
        shape = RoundedCornerShape(16.dp),
        color = Color(0xFF141822).copy(alpha = 0.90f),
        border = BorderStroke(1.dp, Color.White.copy(alpha = 0.15f)),
        shadowElevation = 8.dp
    ) {
        Column(
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 6.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            // Main Pill Row (Always Visible)
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                // Mode Toggle Button (Trackpad vs Direct Touch)
                Surface(
                    shape = RoundedCornerShape(10.dp),
                    color = if (mouseMode == MouseInputMode.TRACKPAD) Color(0xFF2563EB).copy(alpha = 0.35f) else Color(0xFF10B981).copy(alpha = 0.35f),
                    border = BorderStroke(1.dp, if (mouseMode == MouseInputMode.TRACKPAD) Color(0xFF38BDF8) else Color(0xFF34D399)),
                    modifier = Modifier.clickable { onToggleMouseMode() }
                ) {
                    Row(
                        modifier = Modifier.padding(horizontal = 8.dp, vertical = 5.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(4.dp)
                    ) {
                        Icon(
                            imageVector = if (mouseMode == MouseInputMode.TRACKPAD) Icons.Default.Mouse else Icons.Default.TouchApp,
                            contentDescription = null,
                            tint = if (mouseMode == MouseInputMode.TRACKPAD) Color(0xFF38BDF8) else Color(0xFF34D399),
                            modifier = Modifier.size(15.dp)
                        )
                        Text(
                            text = if (mouseMode == MouseInputMode.TRACKPAD) "Trackpad" else "Touch",
                            color = Color.White,
                            fontSize = 11.sp,
                            fontWeight = FontWeight.Bold
                        )
                    }
                }

                // Dedicated Zoom Pad Pill
                Surface(
                    shape = RoundedCornerShape(10.dp),
                    color = Color.White.copy(alpha = 0.08f),
                    border = BorderStroke(1.dp, Color.White.copy(alpha = 0.12f))
                ) {
                    Row(
                        modifier = Modifier.padding(horizontal = 4.dp, vertical = 2.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(2.dp)
                    ) {
                        IconButton(
                            onClick = onZoomOut,
                            modifier = Modifier.size(26.dp)
                        ) {
                            Icon(Icons.Default.ZoomOut, contentDescription = "Zoom Out", tint = Color.White, modifier = Modifier.size(16.dp))
                        }

                        Text(
                            text = "${(zoomScale * 100).toInt()}%",
                            color = Color(0xFF38BDF8),
                            fontSize = 11.sp,
                            fontWeight = FontWeight.Bold,
                            modifier = Modifier.padding(horizontal = 2.dp)
                        )

                        IconButton(
                            onClick = onZoomIn,
                            modifier = Modifier.size(26.dp)
                        ) {
                            Icon(Icons.Default.ZoomIn, contentDescription = "Zoom In", tint = Color.White, modifier = Modifier.size(16.dp))
                        }

                        Box(
                            modifier = Modifier
                                .clip(RoundedCornerShape(6.dp))
                                .background(if (zoomScale == 1.0f) Color(0xFF2563EB) else Color.White.copy(alpha = 0.1f))
                                .clickable { onZoomFit() }
                                .padding(horizontal = 6.dp, vertical = 3.dp)
                        ) {
                            Text("Fit", color = Color.White, fontSize = 10.sp, fontWeight = FontWeight.SemiBold)
                        }

                        Box(
                            modifier = Modifier
                                .clip(RoundedCornerShape(6.dp))
                                .background(Color.White.copy(alpha = 0.1f))
                                .clickable { onZoomOneToOne() }
                                .padding(horizontal = 6.dp, vertical = 3.dp)
                        ) {
                            Text("1:1", color = Color.White, fontSize = 10.sp, fontWeight = FontWeight.SemiBold)
                        }
                    }
                }

                // Keyboard Toggle
                IconButton(
                    onClick = onToggleKeyboard,
                    modifier = Modifier.size(28.dp)
                ) {
                    Icon(
                        imageVector = Icons.Default.Keyboard,
                        contentDescription = "Keyboard",
                        tint = if (showKeyboard) Color(0xFF38BDF8) else Color.White.copy(alpha = 0.8f),
                        modifier = Modifier.size(18.dp)
                    )
                }

                // Fullscreen Toggle
                IconButton(
                    onClick = onToggleFullscreen,
                    modifier = Modifier.size(28.dp)
                ) {
                    Icon(
                        imageVector = if (isFullscreen) Icons.Default.FullscreenExit else Icons.Default.Fullscreen,
                        contentDescription = if (isFullscreen) "Exit Fullscreen" else "Enter Fullscreen",
                        tint = if (isFullscreen) Color(0xFF38BDF8) else Color.White.copy(alpha = 0.8f),
                        modifier = Modifier.size(18.dp)
                    )
                }

                // Refresh Frame
                IconButton(
                    onClick = onRefreshFrame,
                    modifier = Modifier.size(28.dp)
                ) {
                    Icon(
                        imageVector = Icons.Default.Refresh,
                        contentDescription = "Refresh Frame",
                        tint = Color.White.copy(alpha = 0.8f),
                        modifier = Modifier.size(17.dp)
                    )
                }

                // Expand/Collapse Details
                IconButton(
                    onClick = onToggleExpanded,
                    modifier = Modifier.size(26.dp)
                ) {
                    Icon(
                        imageVector = Icons.Default.Tune,
                        contentDescription = "More Tools",
                        tint = if (isExpanded) Color(0xFF38BDF8) else Color.White.copy(alpha = 0.5f),
                        modifier = Modifier.size(15.dp)
                    )
                }
            }

            // Expanded Sub-Bar: Mini Cursor Radar & Guidance
            AnimatedVisibility(visible = isExpanded) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 4.dp, vertical = 2.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        text = "Mac Pointer: X: ${(cursorX * 100).toInt()}% • Y: ${(cursorY * 100).toInt()}%",
                        color = Color.White.copy(alpha = 0.7f),
                        fontSize = 10.sp,
                        fontWeight = FontWeight.Medium
                    )

                    Text(
                        text = if (mouseMode == MouseInputMode.TRACKPAD) "Swipe to move cursor • Tap to click" else "Direct touch active • Tap element",
                        color = Color(0xFF38BDF8).copy(alpha = 0.8f),
                        fontSize = 10.sp
                    )
                }
            }
        }
    }
}

// MARK: - System & Media Pane

@Composable
private fun SystemMediaPane(
    client: MacRemoteClient,
    isConnected: Boolean
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        // Media Playback Card
        SectionCard(title = "Media Playback") {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceEvenly
            ) {
                MediaButton(icon = Icons.Default.FastRewind, label = "Prev", isConnected = isConnected) {
                    client.sendSystemAction(MacRemoteProtocol.SystemAction.PREV_TRACK.rawValue)
                }

                MediaButton(icon = Icons.Default.PlayArrow, label = "Play/Pause", isConnected = isConnected) {
                    client.sendSystemAction(MacRemoteProtocol.SystemAction.PLAY_PAUSE.rawValue)
                }

                MediaButton(icon = Icons.Default.FastForward, label = "Next", isConnected = isConnected) {
                    client.sendSystemAction(MacRemoteProtocol.SystemAction.NEXT_TRACK.rawValue)
                }
            }
        }

        // Volume Card
        SectionCard(title = "Volume & Audio") {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceEvenly
            ) {
                MediaButton(icon = Icons.AutoMirrored.Filled.VolumeDown, label = "Vol -", isConnected = isConnected) {
                    client.sendSystemAction(MacRemoteProtocol.SystemAction.VOLUME_DOWN.rawValue)
                }

                MediaButton(icon = Icons.AutoMirrored.Filled.VolumeMute, label = "Mute", isConnected = isConnected) {
                    client.sendSystemAction(MacRemoteProtocol.SystemAction.VOLUME_MUTE.rawValue)
                }

                MediaButton(icon = Icons.AutoMirrored.Filled.VolumeUp, label = "Vol +", isConnected = isConnected) {
                    client.sendSystemAction(MacRemoteProtocol.SystemAction.VOLUME_UP.rawValue)
                }
            }
        }

        // Display & Power Card
        SectionCard(title = "System Power & Display") {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceEvenly
                ) {
                    MediaButton(icon = Icons.Default.BrightnessLow, label = "Dimmer", isConnected = isConnected) {
                        client.sendSystemAction(MacRemoteProtocol.SystemAction.BRIGHTNESS_DOWN.rawValue)
                    }

                    MediaButton(icon = Icons.Default.BrightnessHigh, label = "Brighter", isConnected = isConnected) {
                        client.sendSystemAction(MacRemoteProtocol.SystemAction.BRIGHTNESS_UP.rawValue)
                    }
                }

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceEvenly
                ) {
                    MediaButton(icon = Icons.Default.Lock, label = "Lock Mac", isConnected = isConnected) {
                        client.sendSystemAction(MacRemoteProtocol.SystemAction.LOCK_SCREEN.rawValue)
                    }

                    MediaButton(icon = Icons.Default.PowerSettingsNew, label = "Sleep Display", isConnected = isConnected) {
                        client.sendSystemAction(MacRemoteProtocol.SystemAction.SLEEP_DISPLAY.rawValue)
                    }
                }
            }
        }
    }
}

@Composable
private fun SectionCard(
    title: String,
    content: @Composable () -> Unit
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(containerColor = Color(0xFF141822).opacity(0.85f))
    ) {
        Column(
            modifier = Modifier.padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            Text(
                text = title,
                style = MaterialTheme.typography.labelMedium.copy(
                    color = Color.White.opacity(0.6f),
                    fontWeight = FontWeight.Bold
                )
            )
            content()
        }
    }
}

@Composable
private fun MediaButton(
    icon: ImageVector,
    label: String,
    isConnected: Boolean,
    onClick: () -> Unit
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(4.dp)
    ) {
        Box(
            modifier = Modifier
                .size(56.dp)
                .clip(CircleShape)
                .background(Color(0xFF1E2433))
                .border(1.dp, Color.White.opacity(0.12f), CircleShape)
                .clickable(enabled = isConnected, onClick = onClick),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                imageVector = icon,
                contentDescription = label,
                tint = if (isConnected) Color.White else Color.Gray,
                modifier = Modifier.size(24.dp)
            )
        }

        Text(
            text = label,
            style = MaterialTheme.typography.labelSmall.copy(
                color = Color.White.opacity(0.7f),
                fontSize = 11.sp
            )
        )
    }
}

// MARK: - Virtual Keyboard Bar

@Composable
private fun VirtualKeyboardBar(
    text: String,
    onTextChange: (String) -> Unit,
    onSend: () -> Unit,
    onKeyCombo: (String) -> Unit,
    onClose: () -> Unit
) {
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 4.dp),
        shape = RoundedCornerShape(14.dp),
        colors = CardDefaults.cardColors(containerColor = Color(0xFF181E2B))
    ) {
        Column(
            modifier = Modifier.padding(10.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            // Typing Input
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                OutlinedTextField(
                    value = text,
                    onValueChange = onTextChange,
                    modifier = Modifier.weight(1f),
                    placeholder = { Text("Type text to send to Mac…", color = Color.Gray, fontSize = 13.sp) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                    keyboardActions = KeyboardActions(onSend = { onSend() }),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedTextColor = Color.White,
                        unfocusedTextColor = Color.White,
                        focusedBorderColor = Color(0xFF38BDF8),
                        unfocusedBorderColor = Color.White.opacity(0.2f)
                    ),
                    shape = RoundedCornerShape(8.dp)
                )

                Button(
                    onClick = onSend,
                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF2563EB)),
                    shape = RoundedCornerShape(8.dp)
                ) {
                    Text("Type", fontSize = 12.sp)
                }

                TextButton(onClick = onClose) {
                    Text("Close", color = Color.Gray, fontSize = 11.sp)
                }
            }

            // Quick Mac Shortcut Buttons - Row 1 (System & Window Actions)
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                KeyShortcutChip("⌘⌥Esc", "Force Quit", accentColor = Color(0xFFF87171), borderColor = Color(0xFFEF4444).copy(alpha = 0.5f)) {
                    onKeyCombo("force_quit")
                }
                KeyShortcutChip("⌘ Space", "Spotlight", accentColor = Color(0xFF38BDF8)) {
                    onKeyCombo("spotlight")
                }
                KeyShortcutChip("⌘ Tab", "Apps") {
                    onKeyCombo("app_switcher")
                }
                KeyShortcutChip("⌘ W", "Close") {
                    onKeyCombo("close_window")
                }
                KeyShortcutChip("⌘ Q", "Quit") {
                    onKeyCombo("quit_app")
                }
                KeyShortcutChip("⌘ Z", "Undo") {
                    onKeyCombo("undo")
                }
            }

            // Quick Mac Shortcut Buttons - Row 2 (Editing & Navigation)
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(5.dp)
            ) {
                KeyShortcutChip("⌘ C", "Copy") { onKeyCombo("copy") }
                KeyShortcutChip("⌘ V", "Paste") { onKeyCombo("paste") }
                KeyShortcutChip("⌘ A", "Select All") { onKeyCombo("select_all") }
                KeyShortcutChip("⌘ S", "Save") { onKeyCombo("save") }
                KeyShortcutChip("Esc", "Esc") { onKeyCombo("escape") }
                KeyShortcutChip("Tab", "Tab") { onKeyCombo("tab") }
                KeyShortcutChip("Enter", "Return") { onKeyCombo("enter") }
                KeyShortcutChip("⌫", "Del") { onKeyCombo("backspace") }
                KeyShortcutChip("Space", "Space") { onKeyCombo("space") }
            }
        }
    }
}

@Composable
private fun KeyShortcutChip(
    keyLabel: String,
    helpText: String,
    accentColor: Color = Color.White,
    backgroundColor: Color = Color(0xFF262E40),
    borderColor: Color = Color.White.copy(alpha = 0.12f),
    onClick: () -> Unit
) {
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(6.dp))
            .background(backgroundColor)
            .border(1.dp, borderColor, RoundedCornerShape(6.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 7.dp, vertical = 5.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(
            text = keyLabel,
            style = MaterialTheme.typography.labelSmall.copy(
                fontWeight = FontWeight.Bold,
                color = accentColor,
                fontSize = 11.sp
            )
        )
    }
}

private fun triggerHaptic(context: Context) {
    try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val vibratorManager = context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager
            vibratorManager?.defaultVibrator?.vibrate(VibrationEffect.createPredefined(VibrationEffect.EFFECT_CLICK))
        } else {
            @Suppress("DEPRECATION")
            val vibrator = context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
            @Suppress("DEPRECATION")
            vibrator?.vibrate(20)
        }
    } catch (_: Exception) { }
}

private fun triggerScrollNotchHaptic(context: Context) {
    try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                (context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager)?.defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
            }
            vibrator?.vibrate(VibrationEffect.createPredefined(VibrationEffect.EFFECT_TICK))
        } else {
            @Suppress("DEPRECATION")
            val vibrator = context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
            @Suppress("DEPRECATION")
            vibrator?.vibrate(10)
        }
    } catch (_: Exception) { }
}

private fun triggerMissionControlHaptic(context: Context) {
    try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                (context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager)?.defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
            }
            vibrator?.vibrate(VibrationEffect.createPredefined(VibrationEffect.EFFECT_HEAVY_CLICK))
        } else {
            @Suppress("DEPRECATION")
            val vibrator = context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
            @Suppress("DEPRECATION")
            vibrator?.vibrate(35)
        }
    } catch (_: Exception) { }
}
