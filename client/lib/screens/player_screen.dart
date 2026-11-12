import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/media_item.dart';
import '../services/api_client.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, required this.api, required this.item});
  final ApiClient api;
  final MediaItem item;
  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final Player _player = Player(configuration: const PlayerConfiguration(title: 'TeleDrive Player', bufferSize: 64 * 1024 * 1024));
  late final VideoController _video = VideoController(_player);
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<String>? _errorSub;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _controls = true;
  bool _busy = true;
  bool _locked = false;
  bool _crop = false;
  bool _loopSeeking = false;
  String? _error;
  String? _overlay;
  Timer? _hideTimer;
  Timer? _sleepTimer;
  Duration? _loopA;
  Duration? _loopB;
  double _gestureBrightness = 0.5;
  double _volume = 100;
  double _rate = 1;
  String? _compressorBot;
  double _tapX = 0;
  int _lastSavedMs = 0;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WakelockPlus.enable();
    _loadCompressorBot();
    _start();
    _positionSub = _player.stream.position.listen((value) {
      if (!mounted) return;
      setState(() => _position = value);
      _checkAbLoop(value);
      if (value.inMilliseconds - _lastSavedMs > 10000) _saveProgress();
    });
    _durationSub = _player.stream.duration.listen((value) {
      if (mounted) setState(() => _duration = value);
    });
    _errorSub = _player.stream.error.listen((value) {
      if (mounted) setState(() => _error = value);
    });
  }

  Future<void> _loadCompressorBot() async {
    try {
      final config = await widget.api.appConfig();
      if (mounted) setState(() => _compressorBot = config['compressor_bot']?.toString());
    } catch (_) {}
  }

  Future<void> _openCompressorBot() async {
    final bot = _compressorBot;
    if (bot == null || bot.isEmpty) return;
    final uri = Uri.parse('https://t.me/$bot');
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!mounted) return;
    showDialog<void>(context: context, builder: (_) => AlertDialog(
      title: const Text('Forward media to the bot'),
      content: Text(opened
          ? 'Telegram has opened @$bot. Find the original Telegram post or file and forward it to the bot. A deep link cannot silently forward a private cloud file on your behalf.'
          : 'Could not open Telegram. Open @$bot manually and forward the original Telegram file.'),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
    ));
  }

  Future<void> _start() async {
    try {
      final platform = _player.platform;
      if (platform is NativePlayer) {
        // libmpv supports volume amplification above the normal 100% ceiling.
        await platform.command(['set', 'volume-max', '200']);
      }
      await _player.open(Media(widget.api.streamUrl(widget.item), httpHeaders: {
        if (widget.api.apiKey.isNotEmpty) 'X-API-Key': widget.api.apiKey,
        'Accept': '*/*',
      }));
      final progress = await widget.api.progress();
      final saved = progress[widget.item.key];
      if (saved is Map && (saved['position_ms'] as num? ?? 0) > 10000) {
        final savedPos = (saved['position_ms'] as num).toInt();
        final savedDuration = (saved['duration_ms'] as num?)?.toInt() ?? 0;
        if (savedDuration == 0 || savedPos < savedDuration - 15000) {
          await _player.seek(Duration(milliseconds: savedPos));
        }
      }
      if (mounted) setState(() => _busy = false);
      _showControls();
    } catch (e) {
      if (mounted) setState(() { _busy = false; _error = e.toString(); });
    }
  }

  void _showControls() {
    if (!mounted || _locked) return;
    setState(() => _controls = true);
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _player.state.playing && !_locked) setState(() => _controls = false);
    });
  }

  void _saveProgress() {
    if (_duration.inMilliseconds <= 0) return;
    _lastSavedMs = _position.inMilliseconds;
    widget.api.saveProgress(widget.item.key, _position.inMilliseconds, _duration.inMilliseconds).catchError((_) {});
  }

  void _checkAbLoop(Duration value) {
    if (_loopA != null && _loopB != null && value >= _loopB! && !_loopSeeking) {
      _loopSeeking = true;
      _player.seek(_loopA!).whenComplete(() => _loopSeeking = false);
    }
  }

  @override
  void dispose() {
    _saveProgress();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _errorSub?.cancel();
    _hideTimer?.cancel();
    _sleepTimer?.cancel();
    WakelockPlus.disable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _player.dispose();
    super.dispose();
  }

  String _time(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  Future<void> _seekBy(int seconds) async {
    final next = _position + Duration(seconds: seconds);
    final max = _duration.inMilliseconds > 0 ? _duration : const Duration(days: 365);
    await _player.seek(Duration(milliseconds: next.inMilliseconds.clamp(0, max.inMilliseconds).toInt()));
    _setOverlay('${seconds > 0 ? '+' : ''}${seconds}s');
  }

  void _setOverlay(String value) {
    setState(() => _overlay = value);
    Future.delayed(const Duration(milliseconds: 700), () { if (mounted) setState(() => _overlay = null); });
  }

  Future<void> _onVerticalStart() async {
    try { _gestureBrightness = await ScreenBrightness.instance.application; } catch (_) { _gestureBrightness = 0.5; }
  }

  Future<void> _onVerticalUpdate(DragUpdateDetails details, double width, double height) async {
    if (_locked) return;
    final leftSide = details.localPosition.dx < width / 2;
    final delta = -details.delta.dy / height;
    if (leftSide) {
      _gestureBrightness = (_gestureBrightness + delta).clamp(0.05, 1.0).toDouble();
      try { await ScreenBrightness.instance.setApplicationScreenBrightness(_gestureBrightness); } catch (_) {}
      _setOverlay('Brightness ${(100 * _gestureBrightness).round()}%');
    } else {
      _volume = (_volume + delta * 200).clamp(0, 200).toDouble();
      await _setPlayerVolume(_volume);
      _setOverlay('Volume ${_volume.round()}%');
    }
  }

  Future<void> _setPlayerVolume(double value) async {
    final volume = value.clamp(0, 200).toDouble();
    final platform = _player.platform;
    if (platform is NativePlayer) {
      await platform.command(['set', 'volume', volume.toStringAsFixed(1)]);
    } else {
      await _player.setVolume(volume.clamp(0, 100).toDouble());
    }
  }

  Future<void> _chooseAudio() async {
    final tracks = _player.state.tracks.audio;
    if (!mounted) return;
    await showModalBottomSheet<void>(context: context, builder: (_) => SafeArea(child: ListView(shrinkWrap: true, children: [
      const ListTile(title: Text('Audio tracks')),
      ...tracks.map((track) => ListTile(title: Text(track.title ?? track.language ?? 'Track ${track.id}'),
        subtitle: Text('${track.language ?? 'Unknown language'}  •  ${track.codec ?? 'Audio'}'),
        onTap: () { _player.setAudioTrack(track); Navigator.pop(context); })),
    ])));
  }

  Future<void> _chooseSubtitle() async {
    final tracks = _player.state.tracks.subtitle;
    if (!mounted) return;
    await showModalBottomSheet<void>(context: context, builder: (_) => SafeArea(child: ListView(shrinkWrap: true, children: [
      const ListTile(title: Text('Subtitle tracks')),
      ListTile(title: const Text('Subtitles off'), onTap: () { _player.setSubtitleTrack(SubtitleTrack.no()); Navigator.pop(context); }),
      ...tracks.map((track) => ListTile(title: Text(track.title ?? track.language ?? 'Track ${track.id}'),
        subtitle: Text('${track.language ?? 'Unknown language'}  •  ${track.codec ?? 'Subtitle'}'),
        onTap: () { _player.setSubtitleTrack(track); Navigator.pop(context); })),
      ListTile(leading: const Icon(Icons.link), title: const Text('Load subtitle URL (.srt / .vtt)'), onTap: () { Navigator.pop(context); _loadSubtitleUrl(); }),
    ])));
  }

  Future<void> _loadSubtitleUrl() async {
    final controller = TextEditingController();
    final url = await showDialog<String>(context: context, builder: (_) => AlertDialog(
      title: const Text('External subtitle URL'),
      content: TextField(controller: controller, autofocus: true, decoration: const InputDecoration(hintText: 'https://example.com/subtitles.vtt')),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('Load'))],
    ));
    controller.dispose();
    if (url == null || url.isEmpty) return;
    try {
      await _player.setSubtitleTrack(SubtitleTrack.uri(url, title: 'External subtitle'));
      _setOverlay('Subtitle loaded');
    } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Subtitle error: $e'))); }
  }

  Future<void> _selectSpeed() async {
    final values = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0];
    final selected = await showModalBottomSheet<double>(context: context, builder: (_) => SafeArea(child: Wrap(children: [
      const Padding(padding: EdgeInsets.all(16), child: Text('Playback speed', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
      ...values.map((value) => ListTile(title: Text('${value.toStringAsFixed(value % 1 == 0 ? 0 : 2)}×'),
        trailing: value == _rate ? const Icon(Icons.check, color: Color(0xFFE50914)) : null,
        onTap: () => Navigator.pop(context, value))),
    ])));
    if (selected != null) { _rate = selected; await _player.setRate(selected); _setOverlay('${selected}×'); }
  }

  Future<void> _sleepTimer() async {
    final minutes = await showModalBottomSheet<int>(context: context, builder: (_) => SafeArea(child: Wrap(children: [
      const Padding(padding: EdgeInsets.all(16), child: Text('Sleep timer', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
      ...[15, 30, 45, 60, 90].map((v) => ListTile(title: Text('$v minutes'), onTap: () => Navigator.pop(context, v))),
      ListTile(title: const Text('Cancel timer'), onTap: () => Navigator.pop(context, 0)),
    ])));
    _sleepTimer?.cancel();
    if (minutes != null && minutes > 0) {
      _sleepTimer = Timer(Duration(minutes: minutes), () { _player.pause(); if (mounted) _setOverlay('Sleep timer ended'); });
      _setOverlay('Sleep timer: $minutes min');
    }
  }

  void _abRepeat() {
    if (_loopA == null || _loopB != null) {
      _loopA = _position;
      _loopB = null;
      _setOverlay('A point set');
    } else {
      if (_position <= _loopA!) { _loopA = _position; _setOverlay('A point reset'); }
      else { _loopB = _position; _setOverlay('A–B repeat active'); }
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(builder: (context, constraints) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () { if (_locked) return; _controls ? setState(() => _controls = false) : _showControls(); },
          onDoubleTapDown: (d) => _tapX = d.localPosition.dx,
          onDoubleTap: () { if (!_locked) _seekBy(_tapX < constraints.maxWidth / 2 ? -10 : 10); },
          onLongPressStart: (_) { if (!_locked) _player.setRate(2.0); },
          onLongPressEnd: (_) { if (!_locked) _player.setRate(_rate); },
          onVerticalDragStart: (_) => _onVerticalStart(),
          onVerticalDragUpdate: (d) => _onVerticalUpdate(d, constraints.maxWidth, constraints.maxHeight),
          child: Stack(fit: StackFit.expand, children: [
            Center(child: Video(controller: _video, fit: _crop ? BoxFit.cover : BoxFit.contain, controls: NoVideoControls)),
            if (_busy) const Center(child: CircularProgressIndicator(color: Color(0xFFE50914))),
            if (_error != null) Center(child: Container(color: Colors.black87, padding: const EdgeInsets.all(20), child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.error_outline, color: Colors.redAccent, size: 42), const SizedBox(height: 10), Text(_error!, textAlign: TextAlign.center),
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Go back')),
            ]))),
            if (_overlay != null) Center(child: Container(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12), decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(10)), child: Text(_overlay!, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)))),
            if (_locked) Positioned(top: 30, right: 20, child: IconButton.filled(onPressed: () => setState(() => _locked = false), icon: const Icon(Icons.lock_open), tooltip: 'Unlock controls')),
            if (_controls && !_locked) _controlsOverlay(constraints.maxWidth),
          ]),
        );
      }),
    );
  }

  Widget _controlsOverlay(double width) => Container(
    decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
      colors: [Colors.black87, Colors.transparent, Colors.transparent, Colors.black87], stops: [0, .25, .55, 1])),
    child: SafeArea(child: Column(children: [
      Row(children: [IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.arrow_back)),
        Expanded(child: Text(widget.item.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold))),
        IconButton(tooltip: 'Lock screen', onPressed: () => setState(() { _locked = true; _controls = false; }), icon: const Icon(Icons.lock_outline)),
        IconButton(tooltip: 'Aspect ratio', onPressed: () { setState(() => _crop = !_crop); _setOverlay(_crop ? 'Crop to fill' : 'Fit to screen'); }, icon: const Icon(Icons.aspect_ratio)),
      ]),
      const Spacer(),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        IconButton(iconSize: 38, onPressed: () => _seekBy(-10), icon: const Icon(Icons.replay_10)),
        const SizedBox(width: 24),
        StreamBuilder<bool>(stream: _player.stream.playing, initialData: _player.state.playing, builder: (context, snapshot) =>
          IconButton(iconSize: 58, onPressed: () => _player.playOrPause(), icon: Icon(snapshot.data == true ? Icons.pause_circle_filled : Icons.play_circle_fill))),
        const SizedBox(width: 24),
        IconButton(iconSize: 38, onPressed: () => _seekBy(10), icon: const Icon(Icons.forward_10)),
      ]),
      const Spacer(),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 18), child: Column(children: [
        SliderTheme(data: SliderTheme.of(context).copyWith(trackHeight: 3, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6)),
          child: Slider(value: _duration.inMilliseconds > 0 ? _position.inMilliseconds.clamp(0, _duration.inMilliseconds).toDouble() : 0,
            max: _duration.inMilliseconds > 0 ? _duration.inMilliseconds.toDouble() : 1,
            onChanged: _duration.inMilliseconds > 0 ? (v) => setState(() => _position = Duration(milliseconds: v.toInt())) : null,
            onChangeEnd: (v) => _player.seek(Duration(milliseconds: v.toInt())))),
        Row(children: [Text(_time(_position), style: const TextStyle(fontSize: 11)), const Spacer(),
          Text(_time(_duration), style: const TextStyle(fontSize: 11)), const SizedBox(width: 12), Text('${_rate}×', style: const TextStyle(fontSize: 11, color: Colors.white70))]),
        const SizedBox(height: 8),
        Wrap(alignment: WrapAlignment.spaceBetween, spacing: 2, runSpacing: 0, children: [
          IconButton(tooltip: 'Audio tracks', onPressed: _chooseAudio, icon: const Icon(Icons.audiotrack)),
          IconButton(tooltip: 'Subtitles', onPressed: _chooseSubtitle, icon: const Icon(Icons.subtitles_outlined)),
          IconButton(tooltip: 'Playback speed', onPressed: _selectSpeed, icon: const Icon(Icons.speed)),
          IconButton(tooltip: 'A–B repeat', onPressed: _abRepeat, color: _loopA != null ? const Color(0xFFE50914) : null, icon: const Icon(Icons.repeat)),
          IconButton(tooltip: 'Sleep timer', onPressed: _sleepTimer, icon: const Icon(Icons.bedtime_outlined)),
          if (widget.item.size > 800 * 1024 * 1024 && _compressorBot != null) IconButton(tooltip: 'Open compressor bot', onPressed: _openCompressorBot, icon: const Icon(Icons.compress)),
          IconButton(tooltip: 'Volume boost', onPressed: () async { _volume = (_volume + 10).clamp(0, 200).toDouble(); await _setPlayerVolume(_volume); _setOverlay('Volume ${_volume.round()}%'); }, icon: const Icon(Icons.volume_up)),
        ]),
        if (_loopA != null) Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(_loopB == null ? 'A: ${_time(_loopA!)}  •  Set B point' : 'A–B: ${_time(_loopA!)} – ${_time(_loopB!)}', style: const TextStyle(color: Colors.white70, fontSize: 11))),
      ])),
    ])),
  );
}
