package com.droidhouse.companion

import android.os.Build
import androidx.compose.animation.core.Animatable
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlurEffect
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TileMode
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * A pane of frosted glass sitting over the aurora.
 *
 * This is real glassmorphism, not a translucent grey rectangle. The panel
 * measures where it sits on screen and then **repaints the same background
 * field**, translated by its own position, blurred, and magnified slightly.
 * Magnifying a blurred backdrop is what a thick lens actually does to what is
 * behind it, so the colours bend and swell at the edges the way they would
 * through glass — and because the paint is driven by the shared aurora phase,
 * the refraction always matches the exact frame on screen behind it.
 *
 * Layer order, bottom to top:
 *   1. blurred + magnified backdrop (the refraction)
 *   2. a faint dark tint, so text keeps its contrast
 *   3. a specular highlight along the top edge (the "lit from above" cue)
 *   4. a hairline rim
 *   5. content
 */
@Composable
fun GlassPanel(
    modifier: Modifier = Modifier,
    cornerRadius: androidx.compose.ui.unit.Dp = 26.dp,
    appearDelayMillis: Long = 0,
    blurRadius: androidx.compose.ui.unit.Dp = 42.dp,
    tintAlpha: Float = 0.40f,
    onClick: (() -> Unit)? = null,
    content: @Composable ColumnScope.() -> Unit
) {
    val scope = rememberCoroutineScope()
    val density = LocalDensity.current
    val phase = LocalAuroraPhase.current

    // Entrance and press share ONE Animatable, so a press landing while the
    // entrance is still settling inherits its velocity instead of restarting.
    val scale = remember { Animatable(0.965f) }
    val reveal = remember { Animatable(0f) }
    val pressFactor = remember { Animatable(0f) } // 0f when released, 1f when tapped

    LaunchedEffect(Unit) {
        delay(appearDelayMillis)
        scope.launch { scale.animateTo(1f, CompanionMotion.elastic()) }
        reveal.animateTo(1f, CompanionMotion.cinematic())
    }

    // Where this panel sits in the window, and how big the window is — both
    // needed to paint the correct slice of the background field.
    var panelOrigin by remember { mutableStateOf(Offset.Zero) }
    // Screen size in pixels — the field the aurora is composed against.
    val configuration = LocalConfiguration.current
    val windowSize = with(density) {
        Size(configuration.screenWidthDp.dp.toPx(), configuration.screenHeightDp.dp.toPx())
    }

    val shape = RoundedCornerShape(cornerRadius)
    val blurPx = with(density) { blurRadius.toPx() }

    Box(
        modifier = modifier
            .fillMaxWidth()
            .scale(scale.value)
            .alpha(reveal.value)
            // Shadow must precede the clip so it renders outside the shape.
            .shadow(
                elevation = (22.dp.value + pressFactor.value * 8f).dp,
                shape = shape,
                clip = false,
                ambientColor = Color.Black,
                spotColor = Color.Black
            )
            .clip(shape)
            .onGloballyPositioned { coordinates ->
                // Position in root (window) space — this is what lets the
                // backdrop paint the exact slice of the field behind us.
                panelOrigin = coordinates.boundsInRoot().topLeft
            }
            .then(
                if (onClick != null) {
                    Modifier.pointerInput(Unit) {
                        detectTapGestures(
                            onPress = {
                                scope.launch { pressFactor.animateTo(1f, CompanionMotion.crisp()) }
                                scope.launch { scale.animateTo(0.97f, CompanionMotion.crisp()) }
                                tryAwaitRelease()
                                scope.launch { pressFactor.animateTo(0f, CompanionMotion.elastic()) }
                                scope.launch { scale.animateTo(1f, CompanionMotion.elastic()) }
                            },
                            onTap = { onClick() }
                        )
                    }
                } else Modifier
            )
    ) {
        // 1 — enhanced refraction with dynamic tap morphing physics
        if (windowSize.width > 0f) {
            Canvas(
                modifier = Modifier
                    .fillMaxSize()
                    .graphicsLayer {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                            val activeBlur = blurPx + pressFactor.value * 12f
                            renderEffect = BlurEffect(activeBlur, activeBlur, TileMode.Decal)
                        }
                        // Dynamic magnification scale: lens swells fluidly on tap press
                        val currentScale = 1.24f + pressFactor.value * 0.14f
                        scaleX = currentScale
                        scaleY = currentScale
                    }
            ) {
                drawAurora(
                    phase = phase,
                    field = windowSize,
                    origin = panelOrigin,
                    // Amplified brightness intensity for vibrant glass physics
                    intensity = 1.50f + pressFactor.value * 0.70f
                )
            }
        }

        // 2 — dynamic tint for legibility & contrast
        Box(
            Modifier
                .matchParentSize()
                .background(Color.Black.copy(alpha = tintAlpha - pressFactor.value * 0.08f))
        )

        // 3 — specular top edge highlight with press shimmer pulse
        Box(
            Modifier
                .matchParentSize()
                .background(
                    Brush.verticalGradient(
                        0.0f to Color.White.copy(alpha = 0.16f + pressFactor.value * 0.20f),
                        0.35f to Color.White.copy(alpha = 0.04f + pressFactor.value * 0.06f),
                        1.0f to Color.Transparent
                    )
                )
        )

        // 4 — hairline rim with glass reflection response
        Box(
            Modifier
                .matchParentSize()
                .border(
                    width = 1.dp,
                    brush = Brush.verticalGradient(
                        listOf(
                            Color.White.copy(alpha = (0.28f + pressFactor.value * 0.30f) * reveal.value),
                            Color.White.copy(alpha = (0.08f + pressFactor.value * 0.15f) * reveal.value)
                        )
                    ),
                    shape = shape
                )
        )

        // 5 — content
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 15.dp),
            verticalArrangement = Arrangement.spacedBy(9.dp),
            content = content
        )
    }
}
