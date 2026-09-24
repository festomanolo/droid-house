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
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
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
import androidx.compose.material.icons.filled.PowerSettingsNew
import androidx.compose.material.icons.filled.Radio
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.ScreenShare
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.Tv
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

// MARK: - Mac Remote Control Screen (Jetpack Compose)
//
// Full-screen spatial companion interface for controlling macOS remotely over
// WAN (Tailscale/Internet) or local Wi-Fi. Features a fluid trackpad, live desktop
// streaming, system power and media controls, and virtual Mac keyboard typing.

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

    var selectedTab by remember { mutableIntStateOf(0) } // 0: Trackpad, 1: Live Desktop, 2: Media & System
    var showKeyboardInput by remember { mutableStateOf(false) }
    var textInputState by remember { mutableStateOf("") }
    var showConfigPanel by remember { mutableStateOf(false) }

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

        while (true) {
            connectionState = client.state
            statusMessage = client.statusMessage
            macName = client.connectedMacName
            latencyMs = client.rttLatencyMs
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
            modifier = Modifier
                .fillMaxSize()
                .windowInsetsPadding(WindowInsets.systemBars)
        ) {
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
                    onHostChange = { hostText = it },
                    onPortChange = { portText = it },
                    onPinChange = { pinText = it },
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
                        onToggleKeyboard = { showKeyboardInput = !showKeyboardInput }
                    )
                    1 -> LiveDesktopPane(
                        client = client,
                        frame = latestFrame,
                        isConnected = connectionState == MacRemoteClient.ConnectionState.CONNECTED
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
                onValueChange = { if (it.length <= 6) onPinChange(it) },
                modifier = Modifier.fillMaxWidth(),
                placeholder = { Text("6-digit Security PIN (shown on Mac)", color = Color.Gray, fontSize = 13.sp) },
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
    onToggleKeyboard: () -> Unit
) {
    val context = LocalContext.current
    var isDragging by remember { mutableStateOf(false) }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        // Trackpad Surface
        Box(
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth()
                .clip(RoundedCornerShape(20.dp))
                .background(Color(0xFF131722).opacity(0.85f))
                .border(1.dp, Color.White.opacity(0.08f), RoundedCornerShape(20.dp))
                .pointerInput(isConnected) {
                    if (!isConnected) return@pointerInput

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
                .pointerInput(isConnected) {
                    if (!isConnected) return@pointerInput

                    detectDragGestures(
                        onDragStart = { isDragging = true },
                        onDragEnd = { isDragging = false },
                        onDragCancel = { isDragging = false },
                        onDrag = { change, dragAmount ->
                            change.consume()
                            client.sendMouseMove(dragAmount.x, dragAmount.y)
                        }
                    )
                }
        ) {
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
                    Text(
                        text = if (isConnected) "Multi-Touch Glass Trackpad" else "Connect to Mac to enable trackpad",
                        style = MaterialTheme.typography.bodySmall.copy(color = Color.White.opacity(0.4f))
                    )

                    IconButton(onClick = onToggleKeyboard) {
                        Icon(
                            imageVector = Icons.Default.Keyboard,
                            contentDescription = "Keyboard",
                            tint = Color.White.opacity(0.7f)
                        )
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
                    text = "1-Finger: Move • Tap: Click • Long-Press: Right Click • Drag: Move",
                    style = MaterialTheme.typography.labelSmall.copy(
                        color = Color.White.opacity(0.35f),
                        fontSize = 10.sp
                    )
                )
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

// MARK: - Live Desktop Pane

@Composable
private fun LiveDesktopPane(
    client: MacRemoteClient,
    frame: Bitmap?,
    isConnected: Boolean
) {
    val context = LocalContext.current

    Box(
        modifier = Modifier
            .fillMaxSize()
            .padding(8.dp)
            .clip(RoundedCornerShape(16.dp))
            .background(Color.Black)
            .border(1.dp, Color.White.opacity(0.1f), RoundedCornerShape(16.dp)),
        contentAlignment = Alignment.Center
    ) {
        if (frame != null && isConnected) {
            Image(
                bitmap = frame.asImageBitmap(),
                contentDescription = "Mac Live Screen",
                modifier = Modifier
                    .fillMaxSize()
                    .pointerInput(Unit) {
                        detectTapGestures { offset ->
                            val xRatio = (offset.x / size.width).coerceIn(0f, 1f)
                            val yRatio = (offset.y / size.height).coerceIn(0f, 1f)
                            triggerHaptic(context)
                            client.sendMouseMoveAbs(xRatio, yRatio)
                            client.sendMouseClick("left")
                        }
                    },
                contentScale = ContentScale.Fit
            )
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

            // Quick Mac Shortcut Buttons
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                KeyShortcutChip("⌘ Space", "Spotlight") { onKeyCombo("spotlight") }
                KeyShortcutChip("⌘ Tab", "Apps") { onKeyCombo("app_switcher") }
                KeyShortcutChip("Esc", "Esc") { onKeyCombo("escape") }
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
    onClick: () -> Unit
) {
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(6.dp))
            .background(Color(0xFF262E40))
            .border(1.dp, Color.White.opacity(0.12f), RoundedCornerShape(6.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 8.dp, vertical = 6.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(
            text = keyLabel,
            style = MaterialTheme.typography.labelSmall.copy(
                fontWeight = FontWeight.Bold,
                color = Color.White,
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
