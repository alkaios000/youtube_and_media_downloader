# Keep youtubedl-android, FFmpeg, Aria2c, and Jackson mappers
-keep class com.yausername.** { *; }
-dontwarn com.yausername.**

# Keep Apache Commons Compress (used via reflection by ZipUtils when unpacking Python/FFmpeg)
-keep class org.apache.commons.compress.** { *; }
-dontwarn org.apache.commons.compress.**

# Keep Jackson annotations & databind used by youtubedl-android
-keep class com.fasterxml.jackson.** { *; }
-dontwarn com.fasterxml.jackson.**

# Keep Flutter plugins & Kotlin Coroutines / JNI bindings
-keep class io.flutter.plugins.** { *; }
-keep class kotlin.Unit { *; }
-keep class kotlin.Result { *; }
-keep class kotlin.Result$Failure { *; }
-keep class kotlin.coroutines.Continuation { *; }
-keep class kotlin.coroutines.intrinsics.** { *; }
-keep class com.linkdrop.linkdrop_downloader.** { *; }
