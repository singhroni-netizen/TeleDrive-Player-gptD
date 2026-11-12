import 'package:flutter/material.dart';
import '../models/media_item.dart';

class PosterCard extends StatelessWidget {
  const PosterCard({super.key, required this.item, required this.onTap, this.progress = 0});
  final MediaItem item;
  final VoidCallback onTap;
  final double progress;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 158,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          AspectRatio(
            aspectRatio: 2 / 3,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Stack(fit: StackFit.expand, children: [
                if (item.poster != null && item.poster!.isNotEmpty)
                  Image.network(item.poster!, fit: BoxFit.cover, errorBuilder: (_, __, ___) => _fallback())
                else
                  _fallback(),
                Positioned(
                  left: 0, right: 0, bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.black87])),
                    child: Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
                  ),
                ),
                if (item.isVideo)
                  const Positioned(right: 8, top: 8, child: Icon(Icons.play_circle_fill, color: Colors.white, size: 22)),
              ]),
            ),
          ),
          if (progress > 0)
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(5),
                child: LinearProgressIndicator(value: progress.clamp(0, 1).toDouble(), minHeight: 3,
                    backgroundColor: Colors.white24, color: const Color(0xFFE50914)),
              ),
            ),
          const SizedBox(height: 5),
          Text(item.sourceName, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white54, fontSize: 10)),
        ]),
      ),
    );
  }

  Widget _fallback() => Container(
    color: const Color(0xFF202020),
    child: Center(child: Icon(item.isVideo ? Icons.movie_outlined : Icons.insert_drive_file_outlined,
      size: 42, color: Colors.white24)),
  );
}
