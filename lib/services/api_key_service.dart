import 'package:shared_preferences/shared_preferences.dart';

class ApiKeyService {
  static const _prefsKey = 'translink_api_key';
  static const _liteModeKey = 'lite_mode';
  static const _noKeyNoticeKey = 'no_key_notice_dismissed';

  static Future<String?> getKey() async {
    final prefs = await SharedPreferences.getInstance();
    final key = prefs.getString(_prefsKey);
    return (key == null || key.isEmpty) ? null : key;
  }

  static Future<void> setKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, key.trim());
  }

  static Future<bool> hasKey() async {
    return await getKey() != null;
  }

  static Future<bool> getLiteMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_liteModeKey) ?? false;
  }

  static Future<void> setLiteMode(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_liteModeKey, value);
  }

  /// The "no API key set" notice, dismissed for good (#321, agreed 10-17).
  /// Deliberately separate from Lite mode: dismissing must not switch Lite on,
  /// or a key added later would silently go unused.
  static Future<bool> getNoKeyNoticeDismissed() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_noKeyNoticeKey) ?? false;
  }

  static Future<void> dismissNoKeyNotice() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_noKeyNoticeKey, true);
  }
}
