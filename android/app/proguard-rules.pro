# google_mlkit_text_recognition only bundles the Latin script recognizer,
# but its initialize() method references the other script options classes.
# R8 flags these as missing even though they're never called at runtime.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**

# Deobfuscated the actual release-mode NPE trace via R8's mapping.txt on
# 2026-07-12 — the classes really being stripped are in mlkit_common and
# mlkit_vision_common (zzmj/zzsr/LazyInstanceMap), not vision.text at all.
# The original -keep guess (below, removed) targeted the wrong package
# and never touched the real problem.
-keep class com.google.mlkit.common.** { *; }
-keep class com.google.android.gms.internal.mlkit_common.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_common.** { *; }
