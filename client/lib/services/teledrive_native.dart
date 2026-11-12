import 'package:flutter/services.dart';

class TeleDriveNative {
  TeleDriveNative._();

  static const MethodChannel _methods =
      MethodChannel('com.teledriveplayer/teledrive');
  static const EventChannel _events =
      EventChannel('com.teledriveplayer/teledrive/events');

  static Stream<Map<String, dynamic>> get authEvents =>
      _events.receiveBroadcastStream().map(
        (event) => Map<String, dynamic>.from(event as Map),
      );

  static Future<Map<String, dynamic>> getAuthState() async =>
      (await _methods.invokeMapMethod<String, dynamic>('getAuthState')) ??
      <String, dynamic>{};

  static Future<Map<String, dynamic>> configure({
    required int apiId,
    required String apiHash,
  }) async =>
      (await _methods.invokeMapMethod<String, dynamic>('configure', {
        'apiId': apiId,
        'apiHash': apiHash,
      })) ??
      <String, dynamic>{};

  static Future<void> submitPhoneNumber(String phoneNumber) =>
      _methods.invokeMethod<void>('submitPhoneNumber', {
        'phoneNumber': phoneNumber,
      });

  static Future<void> submitCode(String code) =>
      _methods.invokeMethod<void>('submitCode', {'code': code});

  static Future<void> submitPassword(String password) =>
      _methods.invokeMethod<void>('submitPassword', {'password': password});

  static Future<void> submitEmail(String email) =>
      _methods.invokeMethod<void>('submitEmail', {'email': email});

  static Future<void> submitEmailCode(String code) =>
      _methods.invokeMethod<void>('submitEmailCode', {'code': code});

  static Future<List<Map<String, dynamic>>> getDrives() async {
    final result = await _methods.invokeListMethod<dynamic>('getDrives');
    return (result ?? const [])
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
  }

  static Future<List<Map<String, dynamic>>> getFiles(int chatId) async {
    final result = await _methods.invokeListMethod<dynamic>(
      'getFiles',
      {'chatId': chatId},
    );
    return (result ?? const [])
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
  }

  static Future<String> getStreamUrl(String id) async {
    final result = await _methods.invokeMethod<String>(
      'getStreamUrl',
      {'id': id},
    );
    if (result == null || result.isEmpty) {
      throw StateError('TeleDrive did not return a stream URL.');
    }
    return result;
  }

  static Future<void> logout() =>
      _methods.invokeMethod<void>('logout');
}
