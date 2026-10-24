# Next Bus

A small Android app for TransLink (Metro Vancouver) riders. Type or scan a stop number, save the stops you use, and see when the next buses are due — live when TransLink's real-time feed is available, from the timetable when it isn't, and always saying which.

**[Download the latest APK](../../releases/latest)** · Android 7.0 or newer

This is a personal project, not affiliated with or endorsed by TransLink.

## Features

- **Find a stop** — type the five-digit stop number, or tap the camera and photograph the sign; the number is read on your phone (Google ML Kit) and looked up.
- **Now and Time** — *Now* shows what's coming; *Time* lets you pick a time of day and plan a trip from the timetable.
- **Live or scheduled, always labelled** — live rows come from TransLink's real-time feed. When the app falls back to the timetable it says why in a line under the header (no API key, key rejected, no connection, TransLink down…), so a quiet failure never looks like a working app. The no-key line can be dismissed for good.
- **When nothing is due** — the app names the next departure ("next bus 05:12") rather than just "no buses", so you can tell a quiet stop from missing data.
- **Favourites** — star a stop to save it. Long-press and drag to reorder; swipe left to rename or delete. A delete can be undone from the bar that appears, and several deletes in a row undo together.
- **Export and import** — save your favourites to a file and bring them back on a new phone (Settings → Export / Import, merge or replace).
- **Works offline** — the schedule lives on your phone. Live arrivals need a connection; everything else doesn't.
- **Lite mode** — turns off live arrivals and schedule downloads, for when data is precious.

## First launch

On first launch the app downloads TransLink's published schedule (GTFS) and builds a local database from it. It's a large download, so Wi-Fi is a good idea. TransLink publishes a new schedule most Fridays; the app tells you when one is available, and Settings → *Refresh Transit Data* fetches it.

## Live arrivals: getting a TransLink API key

Live arrivals need a free key from TransLink. Without one, the app works from the timetable.

1. Go to [developer.translink.ca](https://developer.translink.ca)
2. Create a free account and sign in
3. Register a new app to get an API key
4. In Next Bus, open Settings (the gear icon), paste the key, and tap Save

## Installing

Next Bus is not on the Play Store yet. Download the APK from the [Releases](../../releases) page, open it on your phone, and allow "install unknown apps" if Android asks.

**Upgrading from v1.2.0 or earlier:** v1.3.0 is signed with a new release key, so Android won't install it over an older version. Export your favourites first (Settings → Export favourites) and make a note of your API key, uninstall the old app, install the new one, then import.

## Privacy

Next Bus has no account, no server of its own, no ads and no analytics of its own.

**What leaves your phone:**
- **To TransLink:** the schedule download (`gtfs-static.translink.ca`) and, if you've added a key, the live feed request with your API key (`gtfsapi.translink.ca`). Nothing else about you is sent.
- **To Google, from the camera scan:** the photo is read on your phone and is never uploaded. Google's ML Kit library, which does the reading, sends Google diagnostic data — device and app information, performance metrics, error codes and a per-installation identifier — over HTTPS. Google says this is used for diagnostics and usage analytics and is not shared with third parties ([ML Kit data disclosure](https://developers.google.com/ml-kit/android-data-disclosure)).

**What stays on your phone:** your saved stops and settings, including your API key. They are included in Android's own backup — your Google account backup, and phone-to-phone transfer — so they survive a reinstall or a new phone. That is Android's backup, not ours; turn it off in your phone's backup settings if you prefer. The downloaded schedule is excluded and re-downloads instead.

Exporting your favourites writes a file only to where you choose to save or share it.

## Building from source

The project pins its Flutter version with [FVM](https://fvm.app) (see `.fvm/fvm_config.json`).

```
fvm flutter pub get
fvm flutter run
```

Release builds are signed and **refuse to build without a signing key** rather than quietly falling back to the debug key. To make your own release build, create a keystore and an `android/key.properties` file — the format is described at the top of `android/app/build.gradle.kts`. Both are gitignored; never commit them.

```
fvm flutter build apk --release
```

The APK lands at `build/app/outputs/flutter-apk/app-release.apk`.
