class MediaItem {
  const MediaItem({
    required this.id,
    required this.sourceId,
    required this.sourceName,
    required this.title,
    required this.kind,
    required this.streamUrl,
    this.size = 0,
    this.mimeType = '',
    this.poster,
    this.description,
    this.year,
    this.season,
    this.episode,
    this.duration,
    this.filename,
    this.series,
    this.quality,
    this.codec,
  });

  final String id;
  final String sourceId;
  final String sourceName;
  final String title;
  final String kind;
  final String streamUrl;
  final int size;
  final String mimeType;
  final String? poster;
  final String? description;
  final int? year;
  final int? season;
  final int? episode;
  final num? duration;
  final String? filename;
  final String? series;
  final String? quality;
  final String? codec;

  String get key => '$sourceId:$id';
  bool get isVideo => kind == 'video' || mimeType.startsWith('video/') ||
      RegExp(r'\.(mkv|mp4|avi|mov|webm|m4v|ts|mpeg?)$', caseSensitive: false).hasMatch(title);

  factory MediaItem.fromJson(Map<String, dynamic> json) => MediaItem(
        id: '${json['id']}',
        sourceId: '${json['source_id']}',
        sourceName: '${json['source_name'] ?? ''}',
        title: '${json['title'] ?? 'Untitled'}',
        kind: '${json['kind'] ?? 'file'}',
        streamUrl: '${json['stream_url'] ?? ''}',
        size: (json['size'] as num?)?.toInt() ?? 0,
        mimeType: '${json['mime_type'] ?? ''}',
        poster: json['poster']?.toString(),
        description: json['description']?.toString(),
        year: (json['year'] as num?)?.toInt(),
        season: (json['season'] as num?)?.toInt(),
        episode: (json['episode'] as num?)?.toInt(),
        duration: json['duration'] as num?,
        filename: json['filename']?.toString(),
        series: json['series']?.toString(),
        quality: json['quality']?.toString(),
        codec: json['codec']?.toString(),
      );

  static String formatSize(int bytes) {
    if (bytes <= 0) return 'Size unavailable';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[unit]}';
  }
}
