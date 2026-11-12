import 'package:flutter/material.dart';
import '../services/api_client.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.api});
  final ApiClient api;
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _url = TextEditingController(text: widget.api.baseUrl);
  late final TextEditingController _key = TextEditingController(text: widget.api.apiKey);
  bool _busy = false;
  String? _status;
  bool _dataSaver = false;
  late Future<Map<String, dynamic>> _configFuture;

  @override
  void initState() { super.initState(); _dataSaver = widget.api.dataSaver; _configFuture = widget.api.appConfig(); }

  @override
  void dispose() { _url.dispose(); _key.dispose(); super.dispose(); }

  Future<void> _save() async {
    setState(() { _busy = true; _status = null; });
    try {
      await widget.api.saveConnection(_url.text, _key.text);
      await widget.api.checkHealth();
      if (mounted) setState(() => _status = 'Backend connection successful.');
    } catch (e) {
      if (mounted) setState(() => _status = e.toString());
    } finally { if (mounted) setState(() => _busy = false); }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Settings')),
    body: ListView(padding: const EdgeInsets.all(18), children: [
      const Text('Backend connection', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      const Text('The API runs on your own PC, home server or VPS. Android devices must use the server LAN address or HTTPS domain, not localhost.', style: TextStyle(color: Colors.white60)),
      const SizedBox(height: 16),
      TextField(controller: _url, decoration: const InputDecoration(labelText: 'Backend base URL', hintText: 'http://192.168.1.20:8000')),
      const SizedBox(height: 12),
      TextField(controller: _key, obscureText: true, decoration: const InputDecoration(labelText: 'Backend API key (optional in local mode)')),
      const SizedBox(height: 14),
      FilledButton(onPressed: _busy ? null : _save, child: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Save and test connection')),
      if (_status != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_status!, style: TextStyle(color: _status!.contains('successful') ? Colors.greenAccent : Colors.orangeAccent))),
      const Divider(height: 34),
      const Text('Playback and data usage', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: _dataSaver,
        activeColor: const Color(0xFFE50914),
        title: const Text('Low-data streaming (480p)'),
        subtitle: const Text('Uses the backend FFmpeg proxy. This stream mode is sequential and does not support normal byte-range seeking.'),
        onChanged: (value) async { await widget.api.setDataSaver(value); if (mounted) setState(() => _dataSaver = value); },
      ),
      FutureBuilder<Map<String, dynamic>>(
        future: _configFuture,
        builder: (context, snapshot) {
          if (snapshot.hasError) return Text('Backend capabilities unavailable: ${snapshot.error}', style: const TextStyle(color: Colors.white54));
          if (!snapshot.hasData) return const LinearProgressIndicator();
          final cfg = snapshot.data!;
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _Info(title: 'FFmpeg proxy', body: cfg['transcode_enabled'] == true ? 'Available. 480p, 720p and 1080p transcoding routes are enabled.' : 'Unavailable. Install FFmpeg in the backend container and set TRANSCODE_ENABLED=true.'),
            _Info(title: 'Gemini deep search', body: cfg['gemini_available'] == true ? 'Configured (${cfg['gemini_model']}).' : 'Not configured. Add GEMINI_API_KEY to the backend environment; offline search remains available.'),
            _Info(title: 'Compressor bot', body: cfg['compressor_bot'] != null ? '@${cfg['compressor_bot']} configured. The app opens the bot; you still need to forward the Telegram post/file manually.' : 'Optional. Set TELEGRAM_COMPRESSOR_BOT in the backend environment.'),
          ]);
        },
      ),
      const Divider(height: 34),
      const Text('How sources work', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      const SizedBox(height: 10),
      const _Info(title: 'Telegram', body: 'The backend uses a Telegram MTProto user session. Create a session string once and store it only in the backend environment.'),
      const _Info(title: 'Teldrive', body: 'Connect to your Teldrive server using its API base URL and API key. The starter mapping uses X-Api-Key, /api/files, and the file-name/hash download route; check your server OpenAPI reference because routes and response envelopes can vary by release.'),
      const _Info(title: 'JSON and REST', body: 'Map your API response fields in the source configuration editor. For private APIs, store tokens in backend environment variables.'),
    ]),
  );
}

class _Info extends StatelessWidget {
  const _Info({required this.title, required this.body});
  final String title; final String body;
  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.only(bottom: 14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(title, style: const TextStyle(fontWeight: FontWeight.w700)), const SizedBox(height: 3), Text(body, style: const TextStyle(color: Colors.white60)),
  ]));
}
