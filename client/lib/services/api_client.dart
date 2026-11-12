import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/media_item.dart';

class ApiClient {
  ApiClient(this._prefs);
  final SharedPreferences _prefs;
  List<dynamic> lastWarnings = [];

  static const _baseKey = 'api_base_url';
  static const _apiKey = 'api_key';
  static const _dataSaverKey = 'data_saver';

  String get baseUrl {
    final saved = _prefs.getString(_baseKey);
    if (saved != null && saved.trim().isNotEmpty) return saved.trim().replaceAll(RegExp(r'/$'), '');
    return Platform.isAndroid ? 'http://10.0.2.2:8000' : 'http://127.0.0.1:8000';
  }

  String get apiKey => _prefs.getString(_apiKey) ?? '';
  bool get dataSaver => _prefs.getBool(_dataSaverKey) ?? false;

  Future<void> setDataSaver(bool enabled) => _prefs.setBool(_dataSaverKey, enabled);

  Future<void> saveConnection(String url, String key) async {
    final parsed = Uri.tryParse(url.trim());
    if (parsed == null || !{'http', 'https'}.contains(parsed.scheme) || parsed.host.isEmpty) {
      throw Exception('Enter a valid backend URL, including http:// or https://');
    }
    await _prefs.setString(_baseKey, url.trim().replaceAll(RegExp(r'/$'), ''));
    await _prefs.setString(_apiKey, key.trim());
  }

  Map<String, String> get _headers => {
        'Accept': 'application/json',
        if (apiKey.isNotEmpty) 'X-API-Key': apiKey,
      };

  Uri _uri(String path, [Map<String, String>? query]) => Uri.parse('$baseUrl$path').replace(queryParameters: query);

  Future<Map<String, dynamic>> _json(http.Response response) async {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      var message = response.body;
      try {
        message = jsonDecode(response.body)['detail']?.toString() ?? message;
      } catch (_) {}
      throw Exception('HTTP ${response.statusCode}: $message');
    }
    return response.body.isEmpty ? <String, dynamic>{} : jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<void> checkHealth() async {
    final response = await http.get(_uri('/health')).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) throw Exception('Backend health check failed (${response.statusCode})');
    // /health is intentionally public; verify the saved API key against a
    // protected route as well, otherwise a wrong key could look successful.
    final protected = await http.get(_uri('/api/app-config'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    if (protected.statusCode == 401) throw Exception('Backend is reachable, but the API key is incorrect.');
    if (protected.statusCode < 200 || protected.statusCode >= 300) {
      throw Exception('Backend API check failed (${protected.statusCode}).');
    }
  }

  Future<List<MediaItem>> catalog({String query = ''}) async {
    final response = await http.get(_uri('/api/catalog', query.isEmpty ? null : {'q': query}), headers: _headers)
        .timeout(const Duration(seconds: 60));
    final json = await _json(response);
    lastWarnings = (json['warnings'] as List?) ?? [];
    return (json['items'] as List? ?? []).whereType<Map<String, dynamic>>().map(MediaItem.fromJson).toList();
  }

  Future<List<Map<String, dynamic>>> sources() async {
    final response = await http.get(_uri('/api/sources'), headers: _headers).timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) await _json(response);
    return (jsonDecode(response.body) as List).cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> addSource(String name, String kind, Map<String, dynamic> config) async {
    final response = await http.post(_uri('/api/sources'), headers: {..._headers, 'Content-Type': 'application/json'},
        body: jsonEncode({'name': name, 'kind': kind, 'config': config})).timeout(const Duration(seconds: 25));
    return _json(response);
  }

  Future<void> updateSource(String id, String name, String kind, Map<String, dynamic> config) async {
    final response = await http.put(_uri('/api/sources/$id'), headers: {..._headers, 'Content-Type': 'application/json'},
        body: jsonEncode({'name': name, 'kind': kind, 'config': config}));
    if (response.statusCode < 200 || response.statusCode >= 300) await _json(response);
  }

  Future<void> deleteSource(String id) async {
    final response = await http.delete(_uri('/api/sources/$id'), headers: _headers);
    if (response.statusCode < 200 || response.statusCode >= 300) await _json(response);
  }

  Future<void> setSourceEnabled(String id, bool enabled) async {
    final response = await http.patch(_uri('/api/sources/$id'), headers: {..._headers, 'Content-Type': 'application/json'},
        body: jsonEncode({'enabled': enabled}));
    if (response.statusCode < 200 || response.statusCode >= 300) await _json(response);
  }

  Future<Map<String, dynamic>> appConfig() async {
    final response = await http.get(_uri('/api/app-config'), headers: _headers);
    return _json(response);
  }

  Future<List<MediaItem>> deepSearch(String query) async {
    final response = await http.post(_uri('/api/search/deep'), headers: {..._headers, 'Content-Type': 'application/json'},
        body: jsonEncode({'query': query, 'use_ai': true})).timeout(const Duration(seconds: 50));
    final payload = await _json(response);
    lastWarnings = (payload['warnings'] as List?) ?? [];
    return (payload['items'] as List? ?? []).whereType<Map<String, dynamic>>().map(MediaItem.fromJson).toList();
  }

  Future<Map<String, dynamic>> catalogTree() async {
    final response = await http.get(_uri('/api/catalog/tree'), headers: _headers).timeout(const Duration(seconds: 60));
    return _json(response);
  }

  Future<Map<String, dynamic>> testSource(String id) async {
    final response = await http.post(_uri('/api/sources/$id/test'), headers: _headers).timeout(const Duration(seconds: 60));
    return _json(response);
  }

  Future<void> uploadJson(String sourceId) async {
    final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['json'], withData: false);
    if (result == null || result.files.single.path == null) return;
    final request = http.MultipartRequest('POST', _uri('/api/sources/$sourceId/upload-json'));
    request.headers.addAll(_headers);
    request.files.add(await http.MultipartFile.fromPath('file', result.files.single.path!));
    final streamed = await request.send().timeout(const Duration(minutes: 3));
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode < 200 || response.statusCode >= 300) await _json(response);
  }

  Future<Map<String, dynamic>> progress() async {
    final response = await http.get(_uri('/api/progress'), headers: _headers);
    return _json(response);
  }

  Future<void> saveProgress(String itemKey, int positionMs, int durationMs) async {
    final response = await http.put(_uri('/api/progress'), headers: {..._headers, 'Content-Type': 'application/json'},
        body: jsonEncode({'item_key': itemKey, 'position_ms': positionMs, 'duration_ms': durationMs}));
    if (response.statusCode < 200 || response.statusCode >= 300) await _json(response);
  }

  String streamUrl(MediaItem item) {
    final uri = Uri.parse('$baseUrl${item.streamUrl}');
    return dataSaver ? uri.replace(queryParameters: {...uri.queryParameters, 'quality': '480p'}).toString() : uri.toString();
  }
}
