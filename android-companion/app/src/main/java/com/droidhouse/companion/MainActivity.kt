package com.droidhouse.companion

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.layout.systemBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ScreenShare
import androidx.compose.material.icons.outlined.ContentPaste
import androidx.compose.material.icons.outlined.Notifications
import androidx.compose.material.icons.outlined.Shield
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.ui.draw.scale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import kotlinx.coroutines.delay

class MainActivity : ComponentActivity() {

    private val permissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { /* State is re-read on the next poll tick. */ }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        check(DeveloperConfig.validateLicense()) {
            "CRITICAL: Proprietary DroidHouse Developer Key Missing. Contact festomanolo on GitHub."
        }
        enableEdgeToEdge()

        startCompanionService()
        requestRuntimePermissions()

        setContent {
            DroidHouseTheme {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background
                ) {
                    var showSplash by remember { mutableStateOf(true) }
                    var currentScreen by remember { mutableStateOf("home") }

                    if (showSplash) {
                        AndroidSplashScreen(onFinished = { showSplash = false })
                    } else if (currentScreen == "remote") {
                        MacRemoteControlScreen(onNavigateBack = { currentScreen = "home" })
                    } else {
                        CompanionScreen(
                            onRequestPermissions = { requestRuntimePermissions() },
                            onOpenNotificationSettings = {
                                startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
                            },
                            onRestartService = { startCompanionService() },
                            onCaptureClipboard = {
                                ClipboardBridge.captureFromSystem(applicationContext, "app-button")
                            },
                            onOpenRemote = { currentScreen = "remote" }
                        )
                    }
                }
            }
        }
    }

    override fun onResume() {
        super.onResume()
        // The app now has focus, which is the one moment Android permits a
        // clipboard read. Grab whatever is there so simply opening DroidHouse
        // syncs the last thing the user copied.
        ClipboardBridge.captureFromSystem(applicationContext, "foreground")
    }

    private fun startCompanionService() {
        ContextCompat.startForegroundService(
            this,
            Intent(this, DroidHouseCompanion::class.java)
        )
    }

    private fun requestRuntimePermissions() {
        val wanted = mutableListOf(
            Manifest.permission.RECEIVE_SMS,
            Manifest.permission.SEND_SMS,
            Manifest.permission.READ_SMS,
            Manifest.permission.READ_CONTACTS,
            Manifest.permission.READ_CALL_LOG,
            // Required before AudioPlaybackCapture will hand us any samples.
            Manifest.permission.RECORD_AUDIO
        )

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            wanted += Manifest.permission.POST_NOTIFICATIONS
            wanted += Manifest.permission.READ_MEDIA_IMAGES
        } else {
            wanted += Manifest.permission.READ_EXTERNAL_STORAGE
        }

        val missing = wanted.filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }

        if (missing.isNotEmpty()) {
            permissionLauncher.launch(missing.toTypedArray())
        }
    }
}

// MARK: - State

private data class CompanionUiState(
    val bridgeLive: Boolean = false,
    val bridgeError: String? = null,
    val smsGranted: Boolean = false,
    val contactsGranted: Boolean = false,
    val audioGranted: Boolean = false,
    val notificationAccess: Boolean = false,
    val notificationCount: Int = 0,
    val screenshotCount: Int = 0,
    val sentCount: Int = 0,
    val clipboardPreview: String = "",
    val clipboardSource: String = "none",
    val aeroCastStreaming: Boolean = false,
    val aeroCastMessage: String = "Idle",
    val aeroCastSize: String = ""
) {
    val allAccessGranted: Boolean
        get() = smsGranted && contactsGranted && audioGranted && notificationAccess
}

// MARK: - Screen

@Composable
private fun CompanionScreen(
    onRequestPermissions: () -> Unit,
    onOpenNotificationSettings: () -> Unit,
    onRestartService: () -> Unit,
    onCaptureClipboard: () -> Boolean,
    onOpenRemote: () -> Unit
) {
    val context = LocalContext.current
    val auroraPhase = rememberAuroraPhase()
    var state by remember { mutableStateOf(CompanionUiState()) }

    // Poll rather than push: every source here is a volatile field or a
    // permission check, and a 1 Hz sample is imperceptibly behind while costing
    // nothing.
    LaunchedEffect(Unit) {
        while (true) {
            val aeroCast = AeroCastService.stateSnapshot()
            state = CompanionUiState(
                bridgeLive = DroidHouseCompanion.isBridgeRunning,
                bridgeError = DroidHouseCompanion.lastError,
                smsGranted = context.hasPermission(Manifest.permission.READ_SMS),
                contactsGranted = context.hasPermission(Manifest.permission.READ_CONTACTS),
                audioGranted = context.hasPermission(Manifest.permission.RECORD_AUDIO),
                notificationAccess = Settings.Secure.getString(
                    context.contentResolver, "enabled_notification_listeners"
                ).orEmpty().contains(context.packageName),
                notificationCount = NotificationService.capturedNotifications.size,
                screenshotCount = ScreenshotWatcher.lastKnownCount,
                sentCount = SentOutbox.count(),
                clipboardPreview = ClipboardBridge.capturedText.take(90),
                clipboardSource = ClipboardBridge.captureSource,
                aeroCastStreaming = aeroCast.streaming,
                aeroCastMessage = aeroCast.message,
                aeroCastSize = if (aeroCast.width > 0) "${aeroCast.width}×${aeroCast.height}" else ""
            )
            delay(1000)
        }
    }

    // Every glass panel refracts the *same* frame of the field, so the phase is
    // published once here rather than each panel animating its own.
    CompositionLocalProvider(LocalAuroraPhase provides auroraPhase) {
    Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)) {
        // The only source of colour in the app.
        AuroraBackground(phase = auroraPhase, intensity = if (state.bridgeLive) 1f else 0.5f)

        Column(
            modifier = Modifier
                .fillMaxSize()
                .windowInsetsPadding(WindowInsets.systemBars)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            TitleBar(state)
            ToolbarRow(
                state = state,
                onCaptureClipboard = onCaptureClipboard,
                onStartCast = {
                    AeroCastService.requestStart(context, audio = true, bitRate = null, maxWidth = null)
                },
                onRequestPermissions = onRequestPermissions,
                onOpenNotificationSettings = onOpenNotificationSettings
            )
            StatsStrip(state)
            MacRemoteCard(onOpenRemote = onOpenRemote)
            BridgeCard(state, onRestartService)
            ClipboardCard(state, onCaptureClipboard)
            AeroCastCard(state)
            AccessCard(state, onRequestPermissions, onOpenNotificationSettings)

            Spacer(Modifier.height(24.dp))
        }
    }
    }
}

private fun Context.hasPermission(permission: String): Boolean =
    ContextCompat.checkSelfPermission(this, permission) == PackageManager.PERMISSION_GRANTED

// MARK: - Title bar

/**
 * A macOS window title bar: name on the left, live state on the right, hairline
 * underneath. No hero art, no animation — the background carries the motion.
 */
@Composable
private fun TitleBar(state: CompanionUiState) {
    val entrance = remember { Animatable(0f) }
    LaunchedEffect(Unit) { entrance.animateTo(1f, CompanionMotion.cinematic()) }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .alpha(entrance.value)
            .padding(top = 14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
                Text(
                    text = "DroidHouse",
                    style = MaterialTheme.typography.headlineMedium,
                    color = MaterialTheme.colorScheme.onBackground
                )
                Text(
                    text = "Companion",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            Spacer(Modifier.weight(1f))

            LiveBadge(
                text = if (state.bridgeLive) "Live · 8080" else "Offline",
                accent = if (state.bridgeLive) AccentMint else AccentAmber
            )
        }

        HairlineDivider()
    }
}

@Composable
private fun LiveBadge(text: String, accent: Color) {
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(6.dp))
            .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.8f))
            .border(1.dp, MaterialTheme.colorScheme.outline.copy(alpha = 0.5f), RoundedCornerShape(6.dp))
            .padding(horizontal = 9.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
            Modifier
                .width(6.dp)
                .height(6.dp)
                .clip(androidx.compose.foundation.shape.CircleShape)
                .background(accent)
        )
        Spacer(Modifier.width(6.dp))
        Text(
            text = text,
            fontSize = 11.sp,
            fontFamily = PlusJakartaSans,
            fontWeight = FontWeight.Medium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

// MARK: - Toolbar

/**
 * Four circular toolbar action items (100% corner radius), evenly divided across the width.
 */
@Composable
private fun ToolbarRow(
    state: CompanionUiState,
    onCaptureClipboard: () -> Boolean,
    onStartCast: () -> Unit,
    onRequestPermissions: () -> Unit,
    onOpenNotificationSettings: () -> Unit
) {
    val context = LocalContext.current

    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        QuickActionChip(
            label = "Send Clip",
            icon = Icons.Outlined.ContentPaste,
            modifier = Modifier.weight(1f)
        ) {
            val captured = onCaptureClipboard()
            Toast.makeText(
                context,
                if (captured) "Clipboard sent to Mac" else "Clipboard empty or unchanged",
                Toast.LENGTH_SHORT
            ).show()
        }

        QuickActionChip(
            label = if (state.aeroCastStreaming) "Casting" else "AeroCast",
            icon = Icons.AutoMirrored.Outlined.ScreenShare,
            tint = if (state.aeroCastStreaming) AccentBlue else null,
            enabled = !state.aeroCastStreaming,
            modifier = Modifier.weight(1f),
            onClick = onStartCast
        )

        QuickActionChip(
            label = "Access",
            icon = Icons.Outlined.Shield,
            tint = if (state.allAccessGranted) AccentBlue else LabelTertiary,
            modifier = Modifier.weight(1f),
            onClick = onRequestPermissions
        )

        QuickActionChip(
            label = "Listener",
            icon = Icons.Outlined.Notifications,
            tint = if (state.notificationAccess) AccentBlue else LabelTertiary,
            modifier = Modifier.weight(1f),
            onClick = onOpenNotificationSettings
        )
    }
}

// MARK: - Stats

/** One panel, three cells, hairline separators — not three coloured tiles. */
@Composable
private fun StatsStrip(state: CompanionUiState) {
    GlassPanel(appearDelayMillis = 30) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically
        ) {
            MetricCell("Notifs", state.notificationCount, Modifier.weight(1f))
            VerticalHairline()
            MetricCell("Shots", state.screenshotCount, Modifier.weight(1f))
            VerticalHairline()
            MetricCell("Sent", state.sentCount, Modifier.weight(1f))
        }
    }
}

@Composable
private fun VerticalHairline() {
    Box(
        Modifier
            .width(CompanionMotion.Hairline)
            .height(26.dp)
            .background(MaterialTheme.colorScheme.outline.copy(alpha = 0.5f))
    )
}

// MARK: - Cards

@Composable
private fun BridgeCard(state: CompanionUiState, onRestartService: () -> Unit) {
    GlassPanel(appearDelayMillis = 70) {
        SectionLabel("Local Bridge")
        HairlineDivider()
        StatusRow("Ktor server", if (state.bridgeLive) "Listening" else "Stopped", state.bridgeLive)
        HairlineDivider()
        StatusRow("Endpoint", "127.0.0.1:8080", true)
        HairlineDivider()
        StatusRow("adb forward", "tcp:8080 → tcp:8080", true)

        AnimatedVisibility(
            visible = state.bridgeError != null,
            enter = fadeIn() + expandVertically(animationSpec = CompanionMotion.elastic()),
            exit = fadeOut() + shrinkVertically(animationSpec = CompanionMotion.crisp())
        ) {
            Column {
                HairlineDivider()
                Spacer(Modifier.height(8.dp))
                Text(
                    text = state.bridgeError.orEmpty(),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.error
                )
            }
        }

        AnimatedVisibility(
            visible = !state.bridgeLive,
            enter = fadeIn() + expandVertically(animationSpec = CompanionMotion.elastic()),
            exit = fadeOut() + shrinkVertically(animationSpec = CompanionMotion.crisp())
        ) {
            Column {
                HairlineDivider()
                Spacer(Modifier.height(8.dp))
                SpatialButton(
                    text = "Restart Bridge",
                    modifier = Modifier.fillMaxWidth(),
                    onClick = onRestartService
                )
            }
        }
    }
}

@Composable
private fun ClipboardCard(state: CompanionUiState, onCaptureClipboard: () -> Boolean) {
    val context = LocalContext.current

    GlassPanel(appearDelayMillis = 110) {
        SectionLabel("Clipboard")
        HairlineDivider()
        StatusRow(
            label = "Captured via",
            value = state.clipboardSource,
            isGood = state.clipboardSource != "none"
        )
        HairlineDivider()
        Text(
            text = state.clipboardPreview.ifEmpty { "Nothing captured yet" },
            style = MaterialTheme.typography.bodyMedium,
            color = if (state.clipboardPreview.isEmpty())
                MaterialTheme.colorScheme.onSurfaceVariant
            else MaterialTheme.colorScheme.onSurface,
            maxLines = 3
        )
        HairlineDivider()
        // Being explicit about the platform limit beats looking broken.
        Text(
            text = "Android blocks background clipboard reads. Use the DroidHouse " +
                "action in the text selection toolbar, the Quick Settings tile, or " +
                "open this app.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        HairlineDivider()
        SpatialButton(
            text = "Send Clipboard Now",
            modifier = Modifier.fillMaxWidth()
        ) {
            val captured = onCaptureClipboard()
            Toast.makeText(
                context,
                if (captured) "Clipboard sent to Mac" else "Clipboard empty or unchanged",
                Toast.LENGTH_SHORT
            ).show()
        }
    }
}

@Composable
private fun MacRemoteCard(onOpenRemote: () -> Unit) {
    val client = remember { MacRemoteClient.shared }
    val isConnected = client.state == MacRemoteClient.ConnectionState.CONNECTED

    GlassPanel(appearDelayMillis = 130) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(modifier = Modifier.weight(1f)) {
                SectionLabel("Mac Remote Control")
                Spacer(Modifier.height(2.dp))
                Text(
                    text = if (isConnected) "Connected to ${client.connectedMacName ?: "Mac"}" else "Control mouse, keyboard, media & screen over WAN/LAN",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            if (isConnected) {
                LiveBadge(text = "Connected", accent = AccentMint)
            }
        }

        HairlineDivider()

        SpatialButton(
            text = if (isConnected) "Open Remote Trackpad & Screen" else "Connect & Control Mac Remotely",
            modifier = Modifier.fillMaxWidth(),
            onClick = onOpenRemote
        )
    }
}

@Composable
private fun AeroCastCard(state: CompanionUiState) {
    val context = LocalContext.current

    GlassPanel(appearDelayMillis = 150) {
        SectionLabel("AeroCast")
        HairlineDivider()
        StatusRow(
            label = "Screen + audio",
            value = if (state.aeroCastStreaming) "Live" else "Idle",
            isGood = state.aeroCastStreaming
        )
        HairlineDivider()
        StatusRow(label = "Port", value = "8081", isGood = true)

        AnimatedVisibility(
            visible = state.aeroCastSize.isNotEmpty(),
            enter = fadeIn() + expandVertically(animationSpec = CompanionMotion.elastic()),
            exit = fadeOut() + shrinkVertically(animationSpec = CompanionMotion.crisp())
        ) {
            Column {
                HairlineDivider()
                Spacer(Modifier.height(8.dp))
                StatusRow(label = "Resolution", value = state.aeroCastSize, isGood = true)
            }
        }

        HairlineDivider()
        Text(
            text = state.aeroCastMessage,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        HairlineDivider()
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            SpatialButton(
                text = if (state.aeroCastStreaming) "Streaming" else "Start Cast",
                enabled = !state.aeroCastStreaming,
                modifier = Modifier.weight(1f)
            ) {
                AeroCastService.requestStart(context, audio = true, bitRate = null, maxWidth = null)
            }
            SpatialButton(
                text = "Stop",
                prominent = false,
                enabled = state.aeroCastStreaming,
                modifier = Modifier.weight(1f)
            ) {
                AeroCastService.requestStop(context)
            }
        }
    }
}

@Composable
private fun AccessCard(
    state: CompanionUiState,
    onRequestPermissions: () -> Unit,
    onOpenNotificationSettings: () -> Unit
) {
    GlassPanel(appearDelayMillis = 190) {
        SectionLabel("Access")
        HairlineDivider()
        StatusRow("Read & send SMS", if (state.smsGranted) "Granted" else "Missing", state.smsGranted)
        HairlineDivider()
        StatusRow("Contacts", if (state.contactsGranted) "Granted" else "Missing", state.contactsGranted)
        HairlineDivider()
        StatusRow("Record audio", if (state.audioGranted) "Granted" else "Missing", state.audioGranted)
        HairlineDivider()
        StatusRow(
            "Notification listener",
            if (state.notificationAccess) "Enabled" else "Disabled",
            state.notificationAccess
        )

        AnimatedVisibility(
            visible = !state.allAccessGranted,
            enter = fadeIn() + expandVertically(animationSpec = CompanionMotion.elastic()),
            exit = fadeOut() + shrinkVertically(animationSpec = CompanionMotion.crisp())
        ) {
            Column {
                HairlineDivider()
                Spacer(Modifier.height(8.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    SpatialButton(
                        text = "Grant",
                        modifier = Modifier.weight(1f),
                        onClick = onRequestPermissions
                    )
                    SpatialButton(
                        text = "Listener",
                        prominent = false,
                        modifier = Modifier.weight(1f),
                        onClick = onOpenNotificationSettings
                    )
                }
            }
        }
    }
}

@Composable
private fun AndroidSplashScreen(onFinished: () -> Unit) {
    var startAnim by remember { mutableStateOf(false) }

    val logoScale by animateFloatAsState(
        targetValue = if (startAnim) 1.0f else 0.75f,
        animationSpec = tween(durationMillis = 600)
    )
    val logoAlpha by animateFloatAsState(
        targetValue = if (startAnim) 1.0f else 0.0f,
        animationSpec = tween(durationMillis = 600)
    )
    val textOffsetY by animateDpAsState(
        targetValue = if (startAnim) 115.dp else 0.dp,
        animationSpec = spring(dampingRatio = 0.72f, stiffness = 300f)
    )
    val textAlpha by animateFloatAsState(
        targetValue = if (startAnim) 1.0f else 0.0f,
        animationSpec = tween(durationMillis = 700)
    )

    LaunchedEffect(Unit) {
        startAnim = true
        delay(4000)
        onFinished()
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color(0xFF0A0B0E)),
        contentAlignment = Alignment.Center
    ) {
        // Text shifting down from behind logo
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier
                .offset(y = textOffsetY)
                .alpha(textAlpha)
        ) {
            Text(
                text = "DROIDHOUSE",
                fontSize = 32.sp,
                fontFamily = PlusJakartaSans,
                fontWeight = FontWeight.Black,
                color = Color.White
            )
            Spacer(Modifier.height(4.dp))
            Text(
                text = "Wireless Companion Service",
                fontSize = 13.sp,
                fontFamily = PlusJakartaSans,
                color = Color.White.copy(alpha = 0.75f)
            )
        }

        // Logo Image on top
        Image(
            painter = painterResource(id = R.drawable.droid_bg),
            contentDescription = "DroidHouse Logo",
            modifier = Modifier
                .size(135.dp)
                .scale(logoScale)
                .alpha(logoAlpha)
                .clip(RoundedCornerShape(28.dp))
        )
    }
}
