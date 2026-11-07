import 'package:hive/hive.dart';
import 'package:muzika/services/common_services.dart';
import 'package:muzika/services/library_merge.dart';
import 'package:muzika/services/playlist_download_service.dart';
import 'package:muzika/services/playlists_manager.dart';

Map<String, dynamic> readSyncLibrary() {
  final user = Hive.box('user');
  final result = <String, dynamic>{
    for (final key in libraryListKeys)
      key: user.get(key, defaultValue: <dynamic>[]),
    'likedSongs': userLikedSongsList.value,
    'recentlyPlayedSongs': userRecentlyPlayed.value,
    'customPlaylists': userCustomPlaylists.value,
    'likedPlaylists': userLikedPlaylists.value,
    'playlistFolders': userPlaylistFolders.value,
    'playlists': userPlaylists.value,
    'pinnedPlaylistIds': pinnedPlaylistIds.value,
    'likedRadioStations': userLikedRadioStations.value,
  };
  final known = <String, Map>{};
  void remember(Iterable records) {
    for (final p in records.whereType<Map>()) {
      final id = p['ytid']?.toString();
      if (id != null && id.isNotEmpty) known[id] = p;
    }
  }

  remember(playlists);
  remember(onlinePlaylists.value);
  remember(syncedPlaylistDetails.value);
  remember(userLikedPlaylists.value);
  remember(userCustomPlaylists.value);
  for (final folder in userPlaylistFolders.value) {
    remember(folder['playlists'] as List? ?? []);
  }
  final ids = <String>{...userPlaylists.value};
  ids.addAll(userCustomPlaylists.value.map((p) => '${p['ytid']}'));
  ids.addAll(userLikedPlaylists.value.map((p) => '${p['ytid']}'));
  for (final f in userPlaylistFolders.value) {
    ids.addAll(
      (f['playlists'] as List? ?? []).whereType<Map>().map(
        (p) => '${p['ytid']}',
      ),
    );
  }
  // A playlist can be visible in Library solely because it was downloaded.
  // Transfer its catalog entry, never its device-specific download state.
  final extraCustom = <Map>[];
  final extraSaved = <Map>[];
  for (final p
      in offlinePlaylistService.offlinePlaylists.value.whereType<Map>()) {
    final id = p['ytid']?.toString();
    if (id == null || !ids.add(id)) continue;
    known[id] = p;
    if (p['source'] == 'user-created') {
      extraCustom.add(p);
    } else {
      extraSaved.add(p);
    }
  }
  result['customPlaylists'] = [...userCustomPlaylists.value, ...extraCustom];
  result['likedPlaylists'] = [...userLikedPlaylists.value, ...extraSaved];
  final details = <Map>[];
  for (final id in ids) {
    final record = <String, dynamic>{
      ...?known[id]?.map((k, v) => MapEntry(k.toString(), v)),
      'ytid': id,
    };
    if (userPlaylists.value.contains(id)) record['source'] ??= 'user-youtube';
    final cached = Hive.isBoxOpen('cache')
        ? Hive.box('cache').get('playlistSongs$id')
        : null;
    if (cached is List && cached.isNotEmpty) {
      final songs = List<dynamic>.of(record['list'] as List? ?? []);
      final seen = songs.whereType<Map>().map((s) => s['ytid']).toSet();
      for (final song in cached.whereType<Map>()) {
        if (seen.add(song['ytid'])) songs.add(song);
      }
      record['list'] = songs;
    }
    details.add(record);
  }
  result['playlistDetails'] = details;
  return result;
}

/// Apply synchronously to all library notifiers before awaiting storage, so
/// playback/history updates during the disk flush start from the merged state.
Future<Map<String, dynamic>> mergeAndSaveSyncLibrary(Map incoming) async {
  final merged = mergeLibraries(readSyncLibrary(), incoming);
  final recents = (merged['recentlyPlayedSongs'] as List).map((s) {
    final result = Map<String, dynamic>.from(s as Map);
    final time = result['lastPlayed'];
    if (time is int)
      result['lastPlayed'] = DateTime.fromMillisecondsSinceEpoch(time);
    return result;
  }).toList();
  merged['recentlyPlayedSongs'] = recents;
  final save = Hive.box('user').putAll(merged);
  userLikedSongsList.value = List<dynamic>.from(merged['likedSongs'] as List);
  userRecentlyPlayed.value = recents;
  userCustomPlaylists.value = List<Map>.from(merged['customPlaylists'] as List);
  userLikedPlaylists.value = List<Map>.from(merged['likedPlaylists'] as List);
  userPlaylistFolders.value = List<Map>.from(merged['playlistFolders'] as List);
  syncedPlaylistDetails.value = List<Map>.from(
    merged['playlistDetails'] as List,
  );
  pinnedPlaylistIds.value = List<String>.from(
    merged['pinnedPlaylistIds'] as List,
  );
  userLikedRadioStations.value = List<String>.from(
    merged['likedRadioStations'] as List,
  );
  // Notify YouTube playlist listeners after their saved metadata is available.
  userPlaylists.value = List<String>.from(merged['playlists'] as List);
  await save;
  return portableLibrary(readSyncLibrary());
}
