# Next Bus

A minimal Android app for TransLink (Metro Vancouver) riders: search a stop number, scan a stop sign with your camera, save favourites, and see live or scheduled arrivals.

This is a personal project, not affiliated with or endorsed by TransLink.

## Features

- **Camera scan** — point your camera at a bus stop number; on-device text recognition (ML Kit) reads it and looks up the stop
- **Manual search** — type a stop number directly
- **Favourites** — save stops you check often
- **Live arrivals** — pulls TransLink's real-time GTFS-RT feed when you've added an API key; falls back to the static schedule otherwise
- **On-device GTFS** — the schedule itself lives on the device and updates from TransLink's published feed

## Getting a TransLink API key

Live arrivals need a free key from TransLink. Without one, the app still works off the static schedule.

1. Go to [developer.translink.ca](https://developer.translink.ca)
2. Create a free account and sign in
3. Register a new app to get an API key
4. Open the app's Settings tab, paste the key, and tap Save

## Building from source

Requires the [Flutter SDK](https://docs.flutter.dev/get-started/install).

```
flutter pub get
flutter build apk --release
```

The APK lands at `build/app/outputs/flutter-apk/app-release.apk`.

## Installing (sideload)

This isn't published to the Play Store. Grab the APK from the [Releases](../../releases) page, transfer it to your Android phone, open it, and allow "install unknown apps" if prompted.

## Privacy

Your TransLink API key is stored locally on your device (SharedPreferences) and is never sent anywhere except directly to TransLink's API. The app does not collect or transmit any personal data.
