# google_mlkit_text_recognition only bundles the Latin script recognizer,
# but its initialize() method references the other script options classes.
# R8 flags these as missing even though they're never called at runtime.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**

# The Latin recognizer classes actually used at runtime need an explicit
# -keep — -dontwarn only silences the build warning, it doesn't stop R8
# from stripping them.
-keep class com.google.mlkit.vision.text.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_text_bundled_latin.** { *; }
