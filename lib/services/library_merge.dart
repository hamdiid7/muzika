import 'dart:convert';
import 'dart:math';

import 'package:muzika/services/liked_songs_transfer.dart'
    show portableLikedSongs;

const libraryListKeys = [
  'likedSongs',
  'recentlyPlayedSongs',
  'customPlaylists',
  'likedPlaylists',
  'playlistFolders',
  'playlists',
  'playlistDetails',
  'pinnedPlaylistIds',
  'likedRadioStations',
];

List<dynamic> _list(dynamic value) => value is List ? value : const [];
String _text(dynamic value, [int limit = 512]) =>
    value is String ? value.substring(0, min(limit, value.length)).trim() : '';
String _name(dynamic value) =>
    _text(value).toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
bool _validId(String id) => RegExp(r'^[a-zA-Z0-9_-]{1,512}$').hasMatch(id);
int _time(dynamic value) {
  if (value is DateTime) return value.millisecondsSinceEpoch;
  if (value is int && value >= 0 && value <= 8640000000000000) return value;
  if (value is String)
    return DateTime.tryParse(value)?.millisecondsSinceEpoch ?? 0;
  return 0;
}

List<String> _strings(dynamic value) =>
    _list(value).whereType<String>().where((v) => _validId(v)).toSet().toList();

/// JSON-safe library data only: no settings, credentials, file paths or downloads.
Map<String, dynamic> portableLibrary(Map data) {
  var songReferences = 0;
  List<Map<String, dynamic>> songs(dynamic values, {bool recent = false}) {
    final raw = _list(values);
    if (raw.length > 10000 || (songReferences += raw.length) > 100000) {
      throw const FormatException(
        'This library is too large for one transfer.',
      );
    }
    final result = portableLikedSongs(raw);
    if (recent) {
      final original = <String, Map>{};
      for (final item in raw.whereType<Map>()) {
        final id = '${item['ytid']}';
        if (!original.containsKey(id) ||
            _time(item['lastPlayed']) > _time(original[id]!['lastPlayed']))
          original[id] = item;
      }
      for (final item in result) {
        final source = original[item['ytid']]!;
        item['lastPlayed'] = _time(source['lastPlayed']);
        final count = source['listeningCount'];
        item['listeningCount'] = count is int && count > 0
            ? min(count, 1000000000)
            : 1;
      }
    }
    return result;
  }

  List<Map<String, dynamic>> collections(dynamic values) {
    final raw = _list(values);
    if (raw.length > 5000)
      throw const FormatException('Too many library items.');
    return [
      for (final p in raw.whereType<Map>())
        if (_validId(_text(p['ytid'])))
          {
            'ytid': _text(p['ytid']),
            'title': _text(p['title']),
            for (final key in [
              'artist',
              'description',
              'source',
              'artistId',
              'albumId',
              'name',
            ])
              if (_text(p[key]).isNotEmpty) key: _text(p[key]),
            for (final key in [
              'image',
              'lowResImage',
              'highResImage',
              'thumbnailUrl',
            ])
              if (p[key] is String &&
                  (p[key] as String).length <= 2048 &&
                  Uri.tryParse(p[key])?.scheme == 'https')
                key: p[key],
            for (final key in ['isArtist', 'isAlbum'])
              if (p[key] is bool) key: p[key],
            'createdAt': _time(p['createdAt']),
            'syncAliases': _strings(p['syncAliases']).take(128).toList(),
            'list': songs(p['list']),
          },
    ];
  }

  final folders = _list(data['playlistFolders']);
  if (folders.length > 1000) throw const FormatException('Too many folders.');
  return {
    'likedSongs': songs(data['likedSongs']),
    'recentlyPlayedSongs': songs(data['recentlyPlayedSongs'], recent: true),
    'customPlaylists': collections(data['customPlaylists']),
    'likedPlaylists': collections(data['likedPlaylists']),
    'playlistDetails': collections(data['playlistDetails']),
    'playlistFolders': [
      for (final f in folders.whereType<Map>())
        if (_text(f['name']).isNotEmpty)
          {
            'id': _text(f['id']),
            'name': _text(f['name']),
            'createdAt': _time(f['createdAt']),
            'playlists': collections(f['playlists']),
          },
    ],
    for (final key in ['playlists', 'pinnedPlaylistIds', 'likedRadioStations'])
      key: _strings(data[key]),
  };
}

Map<String, dynamic> _copy(Map source) =>
    source.map((key, value) => MapEntry(key.toString(), value));

List<Map<String, dynamic>> _mergeSongs(
  Iterable local,
  Iterable incoming, {
  bool recent = false,
}) {
  final result = <Map<String, dynamic>>[];
  final indices = <String, int>{};
  for (final item in [...local, ...incoming]) {
    if (item is! Map) continue;
    final song = _copy(item);
    final id = '${song['ytid']}';
    final index = indices[id];
    if (index == null) {
      indices[id] = result.length;
      result.add(song);
    } else {
      final existing = result[index];
      for (final entry in song.entries) {
        if (existing[entry.key] == null || existing[entry.key] == '')
          existing[entry.key] = entry.value;
      }
      if (recent) {
        existing['lastPlayed'] = max(
          _time(existing['lastPlayed']),
          _time(song['lastPlayed']),
        );
        existing['listeningCount'] = max(
          (existing['listeningCount'] as num?)?.toInt() ?? 1,
          (song['listeningCount'] as num?)?.toInt() ?? 1,
        );
      }
    }
  }
  if (recent) {
    result.sort((a, b) {
      final time = _time(b['lastPlayed']).compareTo(_time(a['lastPlayed']));
      return time == 0 ? '${a['ytid']}'.compareTo('${b['ytid']}') : time;
    });
  }
  return result;
}

bool _artist(Map p) => p['isArtist'] == true || p['source'] == 'youtube-artist';
bool _album(Map p) => p['isAlbum'] == true || '${p['ytid']}'.startsWith('MPRE');
String _collectionName(Map p) =>
    _artist(p) || _album(p) ? '' : _name(p['title']);

/// An additive union. IDs already in use locally stay stable, including folder
/// references and pins. Aliases let differently-created same-name playlists
/// keep matching on subsequent syncs, even after one device renames a playlist.
Map<String, dynamic> mergeLibraries(Map local, Map remote) {
  final incoming = portableLibrary(remote);
  final all = <Map<String, dynamic>>[];
  final byId = <String, Map<String, dynamic>>{};
  final byName = <String, Map<String, dynamic>>{};

  Map<String, dynamic> register(Map raw) {
    final p = _copy(raw);
    final id = '${p['ytid']}';
    final aliases = {id, ..._strings(p['syncAliases'])};
    Map<String, dynamic>? target;
    for (final alias in aliases) {
      target ??= byId[alias];
    }
    final name = _collectionName(p);
    if (name.isNotEmpty) target ??= byName[name];
    if (target == null) {
      target = p;
      all.add(target);
    } else {
      final mergedSongs = _mergeSongs(_list(target['list']), _list(p['list']));
      for (final entry in p.entries) {
        if (target[entry.key] == null || target[entry.key] == '')
          target[entry.key] = entry.value;
      }
      target['list'] = mergedSongs;
    }
    final ids = {
      '${target['ytid']}',
      ..._strings(target['syncAliases']),
      ...aliases,
    };
    target['syncAliases'] = ids.toList();
    for (final alias in ids) {
      byId[alias] = target;
    }
    if (name.isNotEmpty) byName[name] = target;
    return target;
  }

  Iterable<Map> records(Map library) sync* {
    for (final key in [
      'customPlaylists',
      'likedPlaylists',
      'playlistDetails',
    ]) {
      yield* _list(library[key]).whereType<Map>();
    }
    for (final f in _list(library['playlistFolders']).whereType<Map>()) {
      yield* _list(f['playlists']).whereType<Map>();
    }
  }

  for (final p in records(local)) {
    register(p);
  }
  for (final p in records(incoming)) {
    register(p);
  }

  Map<String, dynamic> resolve(Map p) => byId['${p['ytid']}']!;
  String resolveId(String id) => '${byId[id]?['ytid'] ?? id}';
  List<Map<String, dynamic>> combine(dynamic left, dynamic right) {
    final result = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final p in [..._list(left), ..._list(right)].whereType<Map>()) {
      final resolved = resolve(p);
      if (seen.add('${resolved['ytid']}')) result.add(resolved);
    }
    return result;
  }

  final folders = <Map<String, dynamic>>[];
  final folderNames = <String, Map<String, dynamic>>{};
  final folderIds = <String>{};
  for (final f in [
    ..._list(local['playlistFolders']),
    ..._list(incoming['playlistFolders']),
  ].whereType<Map>()) {
    final name = _name(f['name']);
    final existing = folderNames[name];
    if (existing != null) {
      existing['playlists'] = combine(existing['playlists'], f['playlists']);
    } else {
      final copy = _copy(f);
      var id = '${copy['id'] ?? ''}';
      if (id.isEmpty || !folderIds.add(id)) {
        id =
            'sync-folder-${base64Url.encode(utf8.encode(name)).replaceAll('=', '')}';
        folderIds.add(id);
      }
      copy['id'] = id;
      copy['playlists'] = combine(f['playlists'], const []);
      folders.add(copy);
      folderNames[name] = copy;
    }
  }

  // Existing locations are retained. An incoming root copy of a playlist
  // already present inside a local folder is resolved to that same item.
  final folderPlaylistIds = {
    for (final f in folders)
      for (final p in f['playlists'] as List) '${p['ytid']}',
  };
  final localCustomIds = {
    for (final p in _list(local['customPlaylists']).whereType<Map>())
      resolveId('${p['ytid']}'),
  };
  final custom = combine(local['customPlaylists'], incoming['customPlaylists'])
      .where(
        (p) =>
            localCustomIds.contains('${p['ytid']}') ||
            !folderPlaylistIds.contains('${p['ytid']}'),
      )
      .toList();
  final liked = combine(local['likedPlaylists'], incoming['likedPlaylists']);
  final youtube = <String>{
    for (final id in [
      ..._strings(local['playlists']),
      ..._strings(incoming['playlists']),
    ])
      resolveId(id),
  }.toList();
  final pins = <String>{
    for (final id in [
      ..._strings(local['pinnedPlaylistIds']),
      ..._strings(incoming['pinnedPlaylistIds']),
    ])
      resolveId(id),
  }.toList();

  return {
    'likedSongs': _mergeSongs(
      _list(local['likedSongs']),
      incoming['likedSongs'] as List,
    ),
    'recentlyPlayedSongs': _mergeSongs(
      _list(local['recentlyPlayedSongs']),
      incoming['recentlyPlayedSongs'] as List,
      recent: true,
    ),
    'customPlaylists': custom,
    'likedPlaylists': liked,
    'playlistFolders': folders,
    'playlists': youtube,
    'playlistDetails': all,
    'pinnedPlaylistIds': pins,
    'likedRadioStations': {
      ..._strings(local['likedRadioStations']),
      ..._strings(incoming['likedRadioStations']),
    }.toList(),
  };
}
