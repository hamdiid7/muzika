/*
 *     Copyright (C) 2026 Muzika contributors
 *
 *     Muzika is free software: you can redistribute it and/or modify
 *     it under the terms of the GNU General Public License as published by
 *     the Free Software Foundation, either version 3 of the License, or
 *     (at your option) any later version.
 *
 *     Muzika is distributed in the hope that it will be useful,
 *     but WITHOUT ANY WARRANTY; without even the implied warranty of
 *     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *     GNU General Public License for more details.
 *
 *     You should have received a copy of the GNU General Public License
 *     along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:muzika/services/data_manager.dart';

/// A new music video in YouTube's own trending playlists (the "New &
/// Trending Songs" row of youtube.com's Music channel, which opens from
/// Ethiopia where YouTube Music doesn't).
class TrendingVideo {
  const TrendingVideo({
    required this.id,
    required this.title,
    required this.artists,
    required this.views,
    required this.age,
    required this.ageLabel,
    this.length,
    this.avatar,
    this.still,
  });

  /// The YouTube video; for a release with no music video, "release:" and
  /// the song's id (its story is the cover and a 30 s preview).
  final String id;

  /// The picture shown for a release with no video: its cover.
  final String? still;

  /// A music video (not a release told with its cover).
  bool get isVideo => !id.startsWith('release:');

  /// As uploaded: "JISOO - ADDICTED (Official MV)".
  final String title;

  /// As credited: "BigXthaPlug and Loe Shimmy".
  final String artists;

  /// "204K views".
  final String views;

  /// How long ago it came out, and as YouTube says it ("20 hours ago").
  final Duration age;
  final String ageLabel;
  final Duration? length;

  /// The artist's channel photo.
  final String? avatar;

  /// Uploaded by a label's channel ("LLOUD Official"), not the artist's.
  bool get _byLabel => _label.hasMatch(artists) && title.contains(' - ');

  /// Who it's by: the credit, or for a label's upload the artist named in
  /// the title ("LISA - Tarantino").
  String get credit =>
      _byLabel ? title.substring(0, title.indexOf(' - ')).trim() : artists;

  /// The first artist of [credit].
  String get artist =>
      credit.split(RegExp(r',| and | & | x | feat\.? ')).first.trim();

  /// The story's round photo: the artist's channel photo, or the video's
  /// own picture when a label uploaded it (its photo is the label's logo).
  String get photo => !isVideo
      ? (avatar ?? still ?? '')
      : _byLabel || avatar == null
      ? 'https://i.ytimg.com/vi/$id/mqdefault.jpg'
      : avatar!.replaceFirst(RegExp(r'=s\d+'), '=s176');

  /// The song's own name: "ADDICTED" from "JISOO - ADDICTED (Official MV)",
  /// "GASS" from "… - GASS feat. Travis Scott (Official Video)".
  String get songTitle {
    var t = title.replaceAll(RegExp(r'\s*[\(\[][^\)\]]*[\)\]]'), '');
    final dash = t.indexOf(' - ');
    if (dash > 0) t = t.substring(dash + 3);
    t = t.replaceAll(_featuring, '').trim();
    return t.isEmpty ? title : t;
  }

  /// Everyone on the song, the main artist first, each once: the credit
  /// ("BigXthaPlug and Loe Shimmy") and whoever the title features
  /// ("feat. Travis Scott", "(ft. Tems)").
  List<String> get collaborators {
    final names = <String>[];
    final keys = <String>{};
    void add(String name) {
      final n = name.trim();
      final k = n.toLowerCase();
      if (n.isNotEmpty && keys.add(k)) names.add(n);
    }

    final splitter = RegExp(r',| and | & | x | with ', caseSensitive: false);
    credit.split(splitter).forEach(add);
    for (final m in RegExp(
      r'\b(?:feat\.?|ft\.?|featuring)\s+([^\(\)\[\]|]+)',
      caseSensitive: false,
    ).allMatches(title)) {
      m[1]!.split(splitter).forEach(add);
    }
    return names;
  }

  String get thumbnail => still ?? 'https://i.ytimg.com/vi/$id/hqdefault.jpg';

  /// Views per hour since it came out: how hot it is.
  double get heat {
    final hours = age.inMinutes / 60 + 1;
    return _viewCount(views) / hours;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'artists': artists,
    'views': views,
    'age': age.inMinutes,
    'ageLabel': ageLabel,
    'length': length?.inSeconds,
    'avatar': avatar,
  };

  static TrendingVideo fromJson(Map j) => TrendingVideo(
    id: '${j['id']}',
    title: '${j['title']}',
    artists: '${j['artists']}',
    views: '${j['views'] ?? ''}',
    age: Duration(minutes: (j['age'] as num?)?.toInt() ?? 0),
    ageLabel: '${j['ageLabel'] ?? ''}',
    length: j['length'] is num
        ? Duration(seconds: (j['length'] as num).toInt())
        : null,
    avatar: j['avatar'] as String?,
  );
}

/// "New & Trending Songs" on youtube.com's Music channel: RELEASED, The
/// Short List, Pop Before It Breaks, INTERNET HITS, Clout Rising (new
/// hip-hop). YouTube's editors' lists; their ids stay the same.
const _playlists = [
  'RDCLAK5uy_k5n4srrEB1wgvIjPNTXS9G1ufE9WQxhnA',
  'RDCLAK5uy_lS3E3PgpboCkZ_PfLPCkLLNPI1uH6kfc0',
  'RDCLAK5uy_kkkZR6KAV5kBSqDCeaBb_pDDhA83VGFwg',
  'RDCLAK5uy_m5k78k1nN5yDlb_kmGHUVXALhIgHjtq4s',
  'RDCLAK5uy_k7O9KByATGA1TqFYhyOkylpJ6fM1avtww',
];

/// "feat. Travis Scott" (to the end) in a song's name.
final _featuring = RegExp(
  r'\s+(?:feat\.?|ft\.?|featuring)\s+.*$',
  caseSensitive: false,
);

/// A label's or a distributor's channel rather than an artist's.
final _label = RegExp(
  r'\b(official|oficial|records|recordings|music|entertainment|label|vevo|'
  r'tv)\b',
  caseSensitive: false,
);

/// Stories are new videos: older ones in the lists (last year's hits) stay
/// out.
const _newFor = Duration(days: 30);

/// How official uploads are titled: "Artist - Song (Official Video)", no
/// "|" pieces and no emoji ("Valhalla Calling 🔥❄️ | Official Music Video |
/// …" isn't a release).
bool _officialTitle(String title) =>
    title.contains(' - ') &&
    !title.contains('|') &&
    !RegExp(
      r'[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]',
      unicode: true,
    ).hasMatch(title);

/// Uploads that are the song's video (not its audio, lyrics or a live take).
final _isVideo = RegExp(
  r'\b(official\s+(music\s+)?video|music\s+video|official\s+mv|\bmv\b|'
  r'official\s+clip|\(video\))',
  caseSensitive: false,
);
final _notVideo = RegExp(
  r'\b(lyrics?|visuali[sz]er|audio|live|performance|teaser|trailer|'
  r'behind the scenes|reaction|snippet)\b',
  caseSensitive: false,
);

/// The music videos in those playlists (each once), newest first; kept six
/// hours. Lyric videos, audio uploads and visualizers are left out.
Future<List<TrendingVideo>> trendingMusicVideos() async {
  const key = 'yt_trending_v3';
  final cached = await getData(
    'cache',
    key,
    cachingDuration: const Duration(hours: 6),
  );
  if (cached is String) {
    return [
      for (final j in jsonDecode(cached) as List)
        if (j is Map) TrendingVideo.fromJson(j),
    ];
  }
  final lists = await Future.wait([
    for (final id in _playlists)
      _playlist(id).catchError((_) => <TrendingVideo>[]),
  ]);
  final seen = <String>{};
  final videos = [
    for (final list in lists)
      for (final v in list)
        if (v.age <= _newFor &&
            _officialTitle(v.title) &&
            _isVideo.hasMatch(v.title) &&
            !_notVideo.hasMatch(v.title) &&
            seen.add(v.id))
          v,
  ]..sort((a, b) => a.age.compareTo(b.age));
  if (videos.isNotEmpty) {
    unawaited(
      addOrUpdateData<String>(
        'cache',
        key,
        jsonEncode([for (final v in videos) v.toJson()]),
      ),
    );
  }
  return videos;
}

/// A playlist through YouTube's own browse API: about 40 KB for 50 songs.
Future<List<TrendingVideo>> _playlist(String id) async {
  final r = await http
      .post(
        Uri.parse(
          'https://www.youtube.com/youtubei/v1/browse?prettyPrint=false',
        ),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({
          'browseId': 'VL$id',
          'context': {
            'client': {
              'clientName': 'WEB',
              'clientVersion': '2.20251020.01.00',
              'hl': 'en',
            },
          },
        }),
      )
      .timeout(const Duration(seconds: 20));
  if (r.statusCode != 200) return const [];
  final found = <TrendingVideo>[];
  void walk(Object? node) {
    if (node is List) {
      node.forEach(walk);
    } else if (node is Map) {
      final lockup = node['lockupViewModel'];
      if (lockup is Map) {
        final video = _video(lockup);
        if (video != null) found.add(video);
        return;
      }
      node.values.forEach(walk);
    }
  }

  walk(jsonDecode(utf8.decode(r.bodyBytes)));
  return found;
}

TrendingVideo? _video(Map lockup) {
  final id = lockup['contentId'];
  final meta = (lockup['metadata'] as Map?)?['lockupMetadataViewModel'] as Map?;
  final title = ((meta?['title'] as Map?)?['content'])?.toString();
  if (id is! String || title == null) return null;
  final rows =
      (((meta?['metadata'] as Map?)?['contentMetadataViewModel']
              as Map?)?['metadataRows']
          as List?) ??
      const [];
  final parts = [
    for (final row in rows.whereType<Map>())
      for (final part
          in ((row['metadataParts'] as List?) ?? const []).whereType<Map>())
        '${(part['text'] as Map?)?['content'] ?? ''}',
  ];
  // [artist(s), "204K views", "20 hours ago"]
  if (parts.length < 3) return null;
  final raw = jsonEncode(lockup);
  final length = RegExp(r'"text":"(\d+:\d\d(?::\d\d)?)"').firstMatch(raw);
  final avatar = RegExp(r'"url":"(https://yt3\.ggpht\.com[^"]+)"')
      .firstMatch(raw);
  return TrendingVideo(
    id: id,
    title: title,
    artists: parts[0],
    views: parts[1],
    age: _age(parts[2]),
    ageLabel: parts[2],
    length: length == null ? null : _length(length[1]!),
    avatar: avatar?[1],
  );
}

/// "20 hours ago", "9 days ago", "2 weeks ago".
Duration _age(String label) {
  final m = RegExp(r'(\d+)\s+(minute|hour|day|week|month|year)')
      .firstMatch(label);
  if (m == null) return const Duration(days: 365);
  final n = int.parse(m[1]!);
  return switch (m[2]) {
    'minute' => Duration(minutes: n),
    'hour' => Duration(hours: n),
    'day' => Duration(days: n),
    'week' => Duration(days: n * 7),
    'month' => Duration(days: n * 30),
    _ => Duration(days: n * 365),
  };
}

Duration _length(String text) {
  var seconds = 0;
  for (final part in text.split(':')) {
    seconds = seconds * 60 + (int.tryParse(part) ?? 0);
  }
  return Duration(seconds: seconds);
}

/// "204K views" → 204000.
double _viewCount(String views) {
  final m = RegExp(r'([\d.]+)\s*([KMB]?)').firstMatch(views);
  if (m == null) return 0;
  final n = double.tryParse(m[1]!) ?? 0;
  return n *
      switch (m[2]) {
        'K' => 1e3,
        'M' => 1e6,
        'B' => 1e9,
        _ => 1,
      };
}
