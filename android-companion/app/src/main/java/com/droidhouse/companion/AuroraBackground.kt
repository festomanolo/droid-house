package com.droidhouse.companion

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin

/**
 * The living background: colours take turns glowing out of the top centre.
 *
 * Rather than several blobs wandering at once, one hue at a time swells from
 * behind the title, peaks, and fades as the next rises — so the screen reads as
 * a single light source changing colour, not a lava lamp. Two slow ambient
 * blooms drift underneath to keep the lower half from going inert, and the
 * bottom is pulled back to black so content stays legible.
 *
 * The same painting routine backs the frosted panels: [GlassPanel] draws this
 * field again, offset to its own position and blurred, which is what produces a
 * genuine refraction of whatever is actually behind it.
 */

/** Palette the top-centre glow cycles through, in order. */
private val CycleColors = listOf(
    Color(0xFF2E7BFF), // blue
    Color(0xFF9B5CFF), // violet
    Color(0xFFFF4D94), // pink
    Color(0xFF12D9C8), // teal
    Color(0xFFB84DFF)  // magenta-violet
)

/** Seconds each colour owns the centre before handing over. */
private const val SECONDS_PER_COLOR = 4.2f

/**
 * Shared animation phase in `[0, 1)`. Hoisted so panels can paint the *same*
 * frame of the background as the backdrop behind them — otherwise the glass
 * would refract a different moment than the one on screen.
 */
val LocalAuroraPhase = compositionLocalOf { 0f }

@Composable
fun rememberAuroraPhase(): Float {
    val transition = rememberInfiniteTransition(label = "aurora")
    val phase by transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(
                durationMillis = (SECONDS_PER_COLOR * CycleColors.size * 1000).toInt(),
                easing = LinearEasing
            ),
            repeatMode = RepeatMode.Restart
        ),
        label = "auroraPhase"
    )
    return phase
}

@Composable
fun AuroraBackground(
    modifier: Modifier = Modifier,
    phase: Float,
    intensity: Float = 1f
) {
    Canvas(modifier = modifier.fillMaxSize()) {
        drawAurora(phase = phase, field = size, origin = Offset.Zero, intensity = intensity)
        drawBottomFade(size)
    }
}

/**
 * Paints the colour field.
 *
 * @param field the size of the *whole screen*, not of the surface being drawn
 *        into — the composition is defined in screen space so a panel's
 *        backdrop lines up with the real background behind it.
 * @param origin the panel's top-left in screen space; the field is translated
 *        by its negation so the correct region lands inside the panel.
 */
fun DrawScope.drawAurora(
    phase: Float,
    field: Size,
    origin: Offset,
    intensity: Float = 1f
) {
    val w = field.width
    val h = field.height
    if (w <= 0f || h <= 0f) return

    val n = CycleColors.size
    val t = phase * n            // position within the cycle, in "slots"
    val tau = (2 * Math.PI).toFloat()

    // ---- the star of the show: one colour at a time, from the top centre ----
    CycleColors.forEachIndexed { index, color ->
        // Circular distance from this colour's turn, in slots.
        var d = abs(t - index)
        if (d > n / 2f) d = n - d

        // Each colour is visible for roughly one slot either side of its peak,
        // so exactly two are ever blending — the outgoing and the incoming.
        val linear = (1f - d).coerceIn(0f, 1f)
        if (linear <= 0f) return@forEachIndexed

        // Smoothstep, so a colour eases in and out instead of ramping linearly.
        val glow = linear * linear * (3f - 2f * linear)

        // A gentle sway keeps the source from looking pinned to one pixel.
        val sway = sin(phase * tau + index) * 0.05f
        val centre = Offset(w * (0.5f + sway), h * 0.06f)

        // The bloom swells as it brightens — that pairing is what makes it read
        // as a glow rather than a fade.
        val radius = w * (0.72f + 0.42f * glow)

        drawCircle(
            brush = Brush.radialGradient(
                colorStops = arrayOf(
                    0.0f to color.copy(alpha = 0.62f * glow * intensity),
                    0.30f to color.copy(alpha = 0.34f * glow * intensity),
                    0.65f to color.copy(alpha = 0.10f * glow * intensity),
                    1.0f to Color.Transparent
                ),
                center = centre - origin,
                radius = radius
            ),
            radius = radius,
            center = centre - origin,
            blendMode = BlendMode.Plus
        )
    }

    // ---- ambient drift, so the middle and lower screen still breathe ----
    val ambient = listOf(
        Triple(Color(0xFF5A6BFF), 0.29f, 0.55f),
        Triple(Color(0xFF12D9C8), 0.19f, 0.78f)
    )

    ambient.forEachIndexed { index, (color, freq, cy) ->
        val x = w * (0.5f + 0.30f * sin(phase * tau * freq * 3f + index * 2.3f))
        val y = h * (cy + 0.06f * cos(phase * tau * freq * 2f + index))
        val r = w * (0.52f + 0.10f * sin(phase * tau * freq * 5f))

        drawCircle(
            brush = Brush.radialGradient(
                colorStops = arrayOf(
                    0.0f to color.copy(alpha = 0.20f * intensity),
                    0.5f to color.copy(alpha = 0.08f * intensity),
                    1.0f to Color.Transparent
                ),
                center = Offset(x, y) - origin,
                radius = r
            ),
            radius = r,
            center = Offset(x, y) - origin,
            blendMode = BlendMode.Plus
        )
    }
}

/** Pulls the lower screen back toward black so the glow reads as top-down. */
fun DrawScope.drawBottomFade(field: Size) {
    drawRect(
        brush = Brush.verticalGradient(
            0.0f to Color.Transparent,
            0.35f to Color.Black.copy(alpha = 0.18f),
            0.62f to Color.Black.copy(alpha = 0.52f),
            1.0f to Color.Black.copy(alpha = 0.86f)
        ),
        size = field
    )
}
