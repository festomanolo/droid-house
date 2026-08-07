package com.droidhouse.companion

import android.os.Build
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Animatable
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlurEffect
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TileMode
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

/**
 * Shared building blocks, styled after macOS: hairline borders, translucent
 * panels over the aurora, monochrome iconography, and colour reserved for state
 * and interaction.
 */

// MARK: - Panel

/**
 * A translucent panel with a hairline edge — the macOS inspector box.
 *
 * @param appearDelayMillis staggers entrances down the page so the screen
 *        assembles itself instead of popping in all at once.
 */
@Composable
fun SpatialCard(
    modifier: Modifier = Modifier,
    accent: Color = MaterialTheme.colorScheme.outline,
    appearDelayMillis: Long = 0,
    onClick: (() -> Unit)? = null,
    content: @Composable ColumnScope.() -> Unit
) {
    val scope = rememberCoroutineScope()

    // Entrance and press share ONE Animatable, so a press landing while the
    // entrance is still settling inherits its velocity instead of restarting.
    val scale = remember { Animatable(0.96f) }
    val reveal = remember { Animatable(0f) }

    LaunchedEffect(Unit) {
        delay(appearDelayMillis)
        scope.launch { scale.animateTo(1f, CompanionMotion.elastic()) }
        reveal.animateTo(1f, CompanionMotion.cinematic())
    }

    Column(
        modifier = modifier
            .fillMaxWidth()
            .scale(scale.value)
            .alpha(reveal.value)
            .clip(RoundedCornerShape(CompanionMotion.CardRadius))
            // Near-opaque so the aurora reads as light *behind* the panel
            // rather than noise showing through the text.
            .background(MaterialTheme.colorScheme.surface.copy(alpha = 0.82f))
            .border(
                width = CompanionMotion.Hairline,
                color = MaterialTheme.colorScheme.outline.copy(alpha = 0.9f * reveal.value),
                shape = RoundedCornerShape(CompanionMotion.CardRadius)
            )
            .then(
                if (onClick != null) {
                    Modifier.pointerInput(Unit) {
                        detectTapGestures(
                            onPress = {
                                scope.launch { scale.animateTo(0.985f, CompanionMotion.crisp()) }
                                tryAwaitRelease()
                                scope.launch { scale.animateTo(1f, CompanionMotion.elastic()) }
                            },
                            onTap = { onClick() }
                        )
                    }
                } else Modifier
            )
            .padding(horizontal = 14.dp, vertical = 13.dp),
        verticalArrangement = Arrangement.spacedBy(9.dp),
        content = content
    )
}

// MARK: - Rows

/**
 * A label/value line with a small state dot — styled like macOS System Settings:
 * macOS accent blue for active/good, neutral grey for off/inactive.
 */
@Composable
fun StatusRow(
    label: String,
    value: String,
    isGood: Boolean,
    modifier: Modifier = Modifier
) {
    val dotColor by animateColorAsState(
        targetValue = if (isGood) AccentBlue else LabelTertiary,
        animationSpec = CompanionMotion.crisp(),
        label = "statusDot"
    )

    Row(
        modifier = modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
            Modifier
                .size(6.dp)
                .clip(CircleShape)
                .background(dotColor)
        )
        Spacer(Modifier.width(9.dp))
        Text(
            text = label,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurface
        )
        Spacer(Modifier.weight(1f))
        Text(
            text = value,
            style = MaterialTheme.typography.bodyMedium,
            color = if (isGood) AccentBlue else MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

/** Hairline separator, matching macOS/iOS Settings page dividers. */
@Composable
fun HairlineDivider(modifier: Modifier = Modifier) {
    Box(
        modifier
            .fillMaxWidth()
            .height(CompanionMotion.Hairline)
            .background(MaterialTheme.colorScheme.outline.copy(alpha = 0.45f))
    )
}

// MARK: - Buttons

/**
 * A macOS push button: compact, hairline-bordered, filled only when it is the
 * primary action.
 */
@Composable
fun SpatialButton(
    text: String,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    prominent: Boolean = true,
    accent: Color = AccentBlue,
    onClick: () -> Unit
) {
    val scope = rememberCoroutineScope()
    val scale = remember { Animatable(1f) }

    val background by animateColorAsState(
        targetValue = when {
            !enabled -> MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)
            prominent -> accent
            else -> MaterialTheme.colorScheme.surfaceVariant
        },
        animationSpec = CompanionMotion.crisp(),
        label = "buttonBackground"
    )

    val label = when {
        !enabled -> MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f)
        prominent -> Color.White
        else -> MaterialTheme.colorScheme.onSurface
    }

    Box(
        modifier = modifier
            .scale(scale.value)
            .height(32.dp)
            .clip(RoundedCornerShape(CompanionMotion.ChipRadius))
            .background(background)
            .border(
                CompanionMotion.Hairline,
                if (prominent && enabled) Color.Transparent
                else MaterialTheme.colorScheme.outline,
                RoundedCornerShape(CompanionMotion.ChipRadius)
            )
            .pointerInput(enabled) {
                if (!enabled) return@pointerInput
                detectTapGestures(
                    onPress = {
                        scope.launch { scale.animateTo(0.96f, CompanionMotion.crisp()) }
                        tryAwaitRelease()
                        scope.launch { scale.animateTo(1f, CompanionMotion.elastic()) }
                    },
                    onTap = { onClick() }
                )
            }
            .padding(horizontal = 14.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(
            text = text,
            fontSize = 12.5.sp,
            fontWeight = FontWeight.Medium,
            color = label
        )
    }
}

/**
 * Top circular action container (100% corner radius = circle):
 * Dynamic glass refraction, centered monochrome glyph & text, and elastic press physics.
 */
@Composable
fun QuickActionChip(
    label: String,
    icon: ImageVector,
    modifier: Modifier = Modifier,
    tint: Color? = null,
    enabled: Boolean = true,
    onClick: () -> Unit
) {
    val scope = rememberCoroutineScope()
    val scale = remember { Animatable(1f) }
    val iconScale = remember { Animatable(1f) }
    val pressFactor = remember { Animatable(0f) }
    val phase = LocalAuroraPhase.current
    val density = LocalDensity.current

    var chipOrigin by remember { mutableStateOf(Offset.Zero) }
    val configuration = LocalConfiguration.current
    val windowSize = with(density) {
        Size(configuration.screenWidthDp.dp.toPx(), configuration.screenHeightDp.dp.toPx())
    }

    val glyphColor = when {
        !enabled -> MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.4f)
        tint != null -> tint
        else -> MaterialTheme.colorScheme.onSurface
    }

    Box(
        modifier = modifier
            .aspectRatio(1f) // 1:1 ratio guarantees perfect circle
            .scale(scale.value)
            .clip(CircleShape) // 100% corner radius
            .onGloballyPositioned { coordinates ->
                chipOrigin = coordinates.boundsInRoot().topLeft
            }
            .border(
                CompanionMotion.Hairline,
                MaterialTheme.colorScheme.outline.copy(alpha = 0.8f + pressFactor.value * 0.2f),
                CircleShape
            )
            .pointerInput(enabled) {
                if (!enabled) return@pointerInput
                detectTapGestures(
                    onPress = {
                        scope.launch { pressFactor.animateTo(1f, CompanionMotion.crisp()) }
                        scope.launch { scale.animateTo(0.92f, CompanionMotion.crisp()) }
                        scope.launch { iconScale.animateTo(0.85f, CompanionMotion.crisp()) }
                        tryAwaitRelease()
                        scope.launch { pressFactor.animateTo(0f, CompanionMotion.elastic()) }
                        scope.launch { scale.animateTo(1f, CompanionMotion.elastic()) }
                        scope.launch { iconScale.animateTo(1f, CompanionMotion.elastic()) }
                    },
                    onTap = { onClick() }
                )
            },
        contentAlignment = Alignment.Center
    ) {
        // Refractive glass backdrop inside circle
        if (windowSize.width > 0f) {
            Canvas(
                modifier = Modifier
                    .fillMaxSize()
                    .graphicsLayer {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                            val blur = with(density) { (28.dp.value + pressFactor.value * 10f).dp.toPx() }
                            renderEffect = BlurEffect(blur, blur, TileMode.Decal)
                        }
                        val currentScale = 1.25f + pressFactor.value * 0.15f
                        scaleX = currentScale
                        scaleY = currentScale
                    }
            ) {
                drawAurora(
                    phase = phase,
                    field = windowSize,
                    origin = chipOrigin,
                    intensity = 1.40f + pressFactor.value * 0.60f
                )
            }
        }

        // Tint overlay
        Box(
            Modifier
                .matchParentSize()
                .background(Color.Black.copy(alpha = 0.42f - pressFactor.value * 0.10f))
        )

        // Top specular highlight
        Box(
            Modifier
                .matchParentSize()
                .background(
                    Brush.verticalGradient(
                        0.0f to Color.White.copy(alpha = 0.18f + pressFactor.value * 0.20f),
                        0.5f to Color.White.copy(alpha = 0.03f),
                        1.0f to Color.Transparent
                    )
                )
        )

        // Circle content
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
            modifier = Modifier.padding(4.dp)
        ) {
            Icon(
                imageVector = icon,
                contentDescription = label,
                tint = glyphColor,
                modifier = Modifier
                    .size(20.dp)
                    .scale(iconScale.value)
            )
            Spacer(Modifier.height(3.dp))
            Text(
                text = label,
                fontSize = 9.5.sp,
                fontWeight = FontWeight.SemiBold,
                color = if (enabled) MaterialTheme.colorScheme.onSurface
                        else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f)
            )
        }
    }
}

// MARK: - Metrics

/**
 * A number that springs to its new value rather than snapping, so a changing
 * count draws the eye without a jarring jump.
 */
@Composable
fun AnimatedCount(
    value: Int,
    modifier: Modifier = Modifier,
    style: TextStyle = MaterialTheme.typography.headlineMedium,
    color: Color = MaterialTheme.colorScheme.onSurface
) {
    val animated = remember { Animatable(value.toFloat()) }

    LaunchedEffect(value) {
        animated.animateTo(value.toFloat(), CompanionMotion.elastic())
    }

    Text(
        text = animated.value.roundToInt().toString(),
        style = style,
        color = color,
        modifier = modifier
    )
}

/**
 * One cell of the stats strip. Numbers are white and the caption grey — no
 * per-tile colour, which is what keeps three of them side by side calm.
 */
@Composable
fun MetricCell(
    label: String,
    value: Int,
    modifier: Modifier = Modifier
) {
    Column(
        modifier = modifier.padding(vertical = 2.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(1.dp)
    ) {
        AnimatedCount(
            value = value,
            style = MaterialTheme.typography.headlineMedium,
            color = MaterialTheme.colorScheme.onSurface
        )
        Text(
            text = label.uppercase(),
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

// MARK: - Section label

@Composable
fun SectionLabel(text: String, modifier: Modifier = Modifier) {
    Text(
        text = text.uppercase(),
        style = MaterialTheme.typography.labelSmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = modifier
    )
}
