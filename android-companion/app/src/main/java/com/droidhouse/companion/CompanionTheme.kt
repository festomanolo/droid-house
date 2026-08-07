package com.droidhouse.companion

import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.SpringSpec
import androidx.compose.animation.core.spring
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * The companion's visual language, modelled on macOS: true black, a single
 * accent, and almost everything else expressed in levels of grey.
 *
 * Colour here carries meaning rather than decoration — the accent marks what is
 * interactive, green and red mark state, and nothing else is tinted. The
 * background aurora supplies all the colour the screen needs.
 *
 * Dark-only by design: the aurora and the true-black substrate are the identity
 * of this app, and a light variant would be a different product.
 */

import androidx.compose.ui.text.font.Font

// The one accent. macOS-blue rather than the violet used elsewhere, because a
// single cool accent against grey is what makes the palette read as system UI.
val AccentBlue = Color(0xFF0A84FF)

// State colours — revised to macOS Settings style (no green/orange in containers).
val AccentMint = Color(0xFF0A84FF)   // macOS Settings active blue
val AccentAmber = Color(0xFF98989D)  // macOS Settings neutral secondary grey
val AccentRed = Color(0xFFFF453A)

// Kept for the AeroCast surfaces that were already violet-coded.
val AccentViolet = Color(0xFFBF5AF2)

// Greys, in the spacing macOS uses between window, sidebar and control levels.
val TrueBlack = Color(0xFF000000)
val SurfaceRaised = Color(0xFF141416)
val SurfaceHigh = Color(0xFF1C1C1F)
val HairlineGrey = Color(0xFF2E2E33)
val LabelPrimary = Color(0xFFF5F5F7)
val LabelSecondary = Color(0xFF98989D)
val LabelTertiary = Color(0xFF636366)

val PlusJakartaSans = FontFamily(
    Font(R.font.plus_jakarta_sans, FontWeight.Normal),
    Font(R.font.plus_jakarta_sans, FontWeight.Medium),
    Font(R.font.plus_jakarta_sans, FontWeight.SemiBold),
    Font(R.font.plus_jakarta_sans, FontWeight.Bold)
)

private val DarkColors = darkColorScheme(
    primary = AccentBlue,
    onPrimary = Color.White,
    secondary = LabelSecondary,
    onSecondary = TrueBlack,
    tertiary = AccentBlue,
    // True black so the panel switches OLED pixels off entirely and the aurora
    // has an untouched canvas to bloom against.
    background = TrueBlack,
    onBackground = LabelPrimary,
    surface = SurfaceRaised,
    onSurface = LabelPrimary,
    surfaceVariant = SurfaceHigh,
    onSurfaceVariant = LabelSecondary,
    outline = HairlineGrey,
    error = AccentRed,
    onError = Color.White
)

/**
 * Small, tight, and quiet — the proportions of a macOS inspector rather than a
 * phone dashboard.
 */
private val CompanionTypography = Typography(
    headlineMedium = TextStyle(
        fontFamily = PlusJakartaSans,
        fontWeight = FontWeight.SemiBold,
        fontSize = 22.sp,
        letterSpacing = (-0.4).sp
    ),
    titleMedium = TextStyle(
        fontFamily = PlusJakartaSans,
        fontWeight = FontWeight.Medium,
        fontSize = 15.sp,
        letterSpacing = (-0.2).sp
    ),
    bodyMedium = TextStyle(
        fontFamily = PlusJakartaSans,
        fontWeight = FontWeight.Normal,
        fontSize = 13.sp,
        lineHeight = 18.sp
    ),
    bodySmall = TextStyle(
        fontFamily = PlusJakartaSans,
        fontWeight = FontWeight.Normal,
        fontSize = 11.5.sp,
        lineHeight = 16.sp
    ),
    labelSmall = TextStyle(
        fontFamily = PlusJakartaSans,
        fontWeight = FontWeight.SemiBold,
        fontSize = 10.sp,
        letterSpacing = 0.7.sp
    )
)

/**
 * The house spring.
 *
 * `DampingRatioMediumBouncy` with `StiffnessLow` is the signature curve: it
 * overshoots enough to feel physical, settles without ringing, and — crucially
 * — because it is a spring rather than a duration-based tween, retargeting it
 * mid-flight preserves the current velocity instead of snapping back to zero.
 * That is what makes rapid, interrupted interactions feel continuous.
 */
object CompanionMotion {
    fun <T> elastic(): SpringSpec<T> = spring(
        dampingRatio = Spring.DampingRatioMediumBouncy,
        stiffness = Spring.StiffnessLow
    )

    /** Same family, quicker settle — for small, frequent state flips. */
    fun <T> crisp(): SpringSpec<T> = spring(
        dampingRatio = Spring.DampingRatioLowBouncy,
        stiffness = Spring.StiffnessMediumLow
    )

    /** Heavier and slower, for whole-panel entrances. */
    fun <T> cinematic(): SpringSpec<T> = spring(
        dampingRatio = Spring.DampingRatioMediumBouncy,
        stiffness = Spring.StiffnessVeryLow
    )

    val CardRadius = 14.dp
    val ChipRadius = 9.dp
    val Hairline = 1.dp
}

@Composable
fun DroidHouseTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = DarkColors,
        typography = CompanionTypography,
        content = content
    )
}
