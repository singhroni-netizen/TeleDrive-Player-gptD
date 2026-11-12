import 'dart:async';

import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../services/teledrive_native.dart';

class TeleDriveScreen extends StatefulWidget {
  const TeleDriveScreen({super.key, required this.onPlay});

  final Future<void> Function(MediaItem item) onPlay;

  @override
  State<TeleDriveScreen> createState() => _TeleDriveScreenState();
}

class _TeleDriveScreenState extends State<TeleDriveScreen> {
  final _apiId = TextEditingController();
  final _apiHash = TextEditingController();
  final _phone = TextEditingController();
  final _code = TextEditingController();
  final _password = TextEditingController();
  final _email = TextEditingController();

  StreamSubscription<Map<String, dynamic>>? _authSubscription;
  Map<String, dynamic> _auth = {'state': 'initializing', 'detail': ''};
  List<Map<String, dynamic>> _drives = [];
  List<Map<String, dynamic>> _files = [];
  Map<String, dynamic>? _selectedDrive;
  bool _busy = false;
  bool _showApiCredentials = true;
  String? _error;

  String get _state => _auth['state']?.toString() ?? 'initializing';
  String get _detail => _auth['detail']?.toString() ?? '';

  @override
  void initState() {
    super.initState();
    _authSubscription = TeleDriveNative.authEvents.listen(
      (event) {
        if (!mounted) return;
        setState(() {
          _auth = event;
          _error = null;
        });
        if (event['state'] == 'ready' && _drives.isEmpty) {
          _loadDrives();
        }
      },
      onError: (Object error) {
        if (mounted) setState(() => _error = error.toString());
      },
    );
    _refreshAuth();
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    _apiId.dispose();
    _apiHash.dispose();
    _phone.dispose();
    _code.dispose();
    _password.dispose();
    _email.dispose();
    super.dispose();
  }

  Future<void> _refreshAuth() async {
    try {
      final state = await TeleDriveNative.getAuthState();
      if (!mounted) return;
      setState(() {
        _auth = state;
        if (state['state'] != 'notConfigured') _showApiCredentials = false;
      });
      if (state['state'] == 'ready') await _loadDrives();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await _refreshAuth();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _configure() async {
    final id = int.tryParse(_apiId.text.trim());
    if (id == null || _apiHash.text.trim().length < 16) {
      setState(() => _error = 'Enter the API ID and API Hash from my.telegram.org.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _showApiCredentials = false;
    });
    try {
      final state = await TeleDriveNative.configure(
        apiId: id,
        apiHash: _apiHash.text.trim(),
      );
      if (mounted) setState(() => _auth = state);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _showApiCredentials = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadDrives() async {
    setState(() {
      _busy = true;
      _error = null;
      _selectedDrive = null;
      _files = [];
    });
    try {
      final rows = await TeleDriveNative.getDrives();
      if (mounted) setState(() => _drives = rows);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _selectDrive(Map<String, dynamic> drive) async {
    final chatId = (drive['chatId'] as num).toInt();
    setState(() {
      _busy = true;
      _error = null;
      _selectedDrive = drive;
      _files = [];
    });
    try {
      final rows = await TeleDriveNative.getFiles(chatId);
      if (mounted) setState(() => _files = rows);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _playFile(Map<String, dynamic> file) async {
    if (file['locked'] == true) {
      setState(() => _error =
          'This file uses TeleDrive encryption. The current bridge supports files with encryption OFF.');
      return;
    }
    final mime = file['mimeType']?.toString() ?? 'application/octet-stream';
    final title = file['title']?.toString() ?? 'Untitled';
    final item = MediaItem(
      id: file['id'].toString(),
      sourceId: 'teledrive-native',
      sourceName: _selectedDrive?['title']?.toString() ?? 'TeleDrive',
      title: title,
      kind: mime.startsWith('video/') ? 'video' : 'file',
      streamUrl: file['id'].toString(),
      size: (file['size'] as num?)?.toInt() ?? 0,
      mimeType: mime,
      filename: title,
    );
    await widget.onPlay(item);
  }

  @override
  Widget build(BuildContext context) {
    final ready = _state == 'ready';
    final authPending = _state.startsWith('waiting');
    return Scaffold(
      appBar: AppBar(
        title: const Text('TeleDrive Storage'),
        actions: [
          if (ready)
            IconButton(
              tooltip: 'Refresh channels',
              onPressed: _busy ? null : _loadDrives,
              icon: const Icon(Icons.refresh),
            ),
          if (ready)
            IconButton(
              tooltip: 'Sign out',
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                        await TeleDriveNative.logout();
                        _drives = [];
                        _files = [];
                      }),
              icon: const Icon(Icons.logout),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _connectionCard(ready),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Colors.orangeAccent)),
          ],
          if (_showApiCredentials && !ready) ...[
            const SizedBox(height: 18),
            const Text('Telegram API credentials',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
            const SizedBox(height: 8),
            TextField(
              controller: _apiId,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'API ID'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _apiHash,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'API Hash'),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _busy ? null : _configure,
              child: const Text('Connect Telegram'),
            ),
            const SizedBox(height: 6),
            const Text(
              'Credentials are encrypted with Android Keystore and stored on this device. They are sent only to Telegram.',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ],
          if (_state == 'waitingForPhoneNumber') ...[
            const SizedBox(height: 18),
            TextField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Telegram phone number',
                hintText: '+91xxxxxxxxxx',
              ),
            ),
            const SizedBox(height: 10),
            FilledButton(
              onPressed: _busy
                  ? null
                  : () => _run(() => TeleDriveNative.submitPhoneNumber(_phone.text.trim())),
              child: const Text('Send login code'),
            ),
          ],
          if (_state == 'waitingForCode') ...[
            const SizedBox(height: 18),
            TextField(
              controller: _code,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Telegram login code'),
            ),
            const SizedBox(height: 10),
            FilledButton(
              onPressed: _busy
                  ? null
                  : () => _run(() => TeleDriveNative.submitCode(_code.text.trim())),
              child: const Text('Verify code'),
            ),
          ],
          if (_state == 'waitingForPassword') ...[
            const SizedBox(height: 18),
            TextField(
              controller: _password,
              obscureText: true,
              decoration: InputDecoration(
                labelText: _detail.isEmpty ? 'Telegram 2-step verification password' : 'Password ($_detail)',
              ),
            ),
            const SizedBox(height: 10),
            FilledButton(
              onPressed: _busy
                  ? null
                  : () => _run(() => TeleDriveNative.submitPassword(_password.text)),
              child: const Text('Submit password'),
            ),
          ],
          if (_state == 'waitingForEmail') ...[
            const SizedBox(height: 18),
            TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'Telegram login email'),
            ),
            const SizedBox(height: 10),
            FilledButton(
              onPressed: _busy
                  ? null
                  : () => _run(() => TeleDriveNative.submitEmail(_email.text.trim())),
              child: const Text('Submit email'),
            ),
          ],
          if (_state == 'waitingForEmailCode') ...[
            const SizedBox(height: 18),
            TextField(
              controller: _code,
              decoration: const InputDecoration(labelText: 'Email verification code'),
            ),
            const SizedBox(height: 10),
            FilledButton(
              onPressed: _busy
                  ? null
                  : () => _run(() => TeleDriveNative.submitEmailCode(_code.text.trim())),
              child: const Text('Verify email code'),
            ),
          ],
          if (_state == 'registrationRequired')
            const Padding(
              padding: EdgeInsets.only(top: 16),
              child: Text('Telegram requires account registration in an official Telegram client first.'),
            ),
          if (ready) ...[
            const SizedBox(height: 20),
            Row(
              children: [
                const Expanded(
                  child: Text('Your TeleDrive channels',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ),
                TextButton(
                  onPressed: _busy ? null : _loadDrives,
                  child: const Text('Refresh'),
                ),
              ],
            ),
            if (_drives.isEmpty && !_busy)
              const Text('No TeleDrive storage channels found on this Telegram account.',
                  style: TextStyle(color: Colors.white54)),
            ..._drives.map((drive) {
              final selected = _selectedDrive?['chatId'] == drive['chatId'];
              return Card(
                color: const Color(0xFF171717),
                child: ListTile(
                  leading: const Icon(Icons.cloud_outlined, color: Color(0xFFE50914)),
                  title: Text(drive['title']?.toString() ?? 'TeleDrive'),
                  subtitle: Text('Channel ID: ${drive['chatId']}'),
                  trailing: Icon(selected ? Icons.check_circle : Icons.chevron_right),
                  onTap: _busy ? null : () => _selectDrive(drive),
                ),
              );
            }),
          ],
          if (_selectedDrive != null) ...[
            const SizedBox(height: 18),
            Text(_selectedDrive!['title']?.toString() ?? 'Files',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            if (_files.isEmpty && !_busy)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('No indexed files found in this channel.',
                    style: TextStyle(color: Colors.white54)),
              ),
            ..._files.map((file) {
              final locked = file['locked'] == true;
              final mime = file['mimeType']?.toString() ?? '';
              final video = mime.startsWith('video/');
              final size = (file['size'] as num?)?.toInt() ?? 0;
              return Card(
                color: const Color(0xFF171717),
                child: ListTile(
                  leading: Icon(
                    locked ? Icons.lock_outline : (video ? Icons.play_circle_outline : Icons.insert_drive_file_outlined),
                    color: locked ? Colors.orangeAccent : const Color(0xFFE50914),
                  ),
                  title: Text(file['title']?.toString() ?? 'Untitled'),
                  subtitle: Text('${mime.isEmpty ? 'File' : mime}  ·  ${MediaItem.formatSize(size)}'),
                  trailing: Icon(locked ? Icons.lock : (video ? Icons.play_arrow : Icons.open_in_new)),
                  onTap: locked || (!video && !mime.startsWith('audio/')) ? null : () => _playFile(file),
                ),
              );
            }),
          ],
          if (_busy) ...[
            const SizedBox(height: 18),
            const LinearProgressIndicator(color: Color(0xFFE50914)),
          ],
        ],
      ),
    );
  }

  Widget _connectionCard(bool ready) => Card(
        color: const Color(0xFF171717),
        child: ListTile(
          leading: Icon(
            ready ? Icons.cloud_done : Icons.cloud_outlined,
            color: ready ? Colors.greenAccent : const Color(0xFFE50914),
          ),
          title: Text(ready ? 'Telegram connected' : _stateLabel(_state)),
          subtitle: Text(_detail.isEmpty ? 'Direct TDLib connection · No backend required' : _detail),
        ),
      );

  String _stateLabel(String state) => switch (state) {
        'notConfigured' => 'Not connected',
        'initializing' => 'Connecting to Telegram',
        'waitingForPhoneNumber' => 'Waiting for phone number',
        'waitingForCode' => 'Waiting for login code',
        'waitingForPassword' => 'Waiting for 2-step password',
        'waitingForEmail' => 'Waiting for login email',
        'waitingForEmailCode' => 'Waiting for email code',
        'waitingForQr' => 'Waiting for QR confirmation',
        'registrationRequired' => 'Telegram registration required',
        'closed' => 'Telegram session closed',
        _ => state,
      };
}
