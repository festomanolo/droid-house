# Ignore missing desktop JVM classes in Ktor/SLF4J
-dontwarn java.lang.management.**
-dontwarn org.slf4j.impl.**
-dontwarn org.fusesource.jansi.**

# Keep Ktor & Netty classes
-keep class io.ktor.** { *; }
-keep class io.netty.** { *; }

# Keep kotlinx serialization models
-keepattributes *Annotation*, ElementValueAttribute
-keepclassmembers class * {
    @kotlinx.serialization.SerialName <fields>;
}
-keepclassmembers class * {
    *** Companion;
}
-keepclassmembers class * {
    *** serializer(...);
}

# Keep DroidHouse Companion models & services
-keep class com.droidhouse.companion.** { *; }
