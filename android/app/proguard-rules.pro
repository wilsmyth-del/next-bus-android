# google_mlkit_text_recognition only bundles the Latin script recognizer,
# but its initialize() method references the other script options classes.
# R8 flags these as missing even though they're never called at runtime.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**

# Deobfuscated two successive release-mode NPE traces via R8's mapping.txt
# on 2026-07-12. R8 strips several distinct internal ML Kit implementation
# packages that aren't reachable by normal reflection analysis — each fix
# below was confirmed necessary by decoding an actual crash trace, not
# guessed. com.google.mlkit.** covers vision.text (incl. its .internal
# subpackage) and common/sdkinternal in one rule; the com.google.android.gms
# ones are a separate top-level path and need listing individually.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_common.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_common.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_text_common.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_text_bundled_latin.** { *; }
