import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:muzika/services/common_services.dart';
import 'package:muzika/services/library_merge.dart';
import 'package:muzika/services/library_pairing.dart';
import 'package:muzika/services/library_sync_service.dart';
import 'package:muzika/services/playlists_manager.dart';

const rings = {
  'ytid': 'QYh6mYIJG2Y',
  'title': '7 rings',
  'artist': 'Ariana Grande',
};
const other = {'ytid': 'abcdefghijk', 'title': 'Other', 'artist': 'Artist'};

void main() {
  late Directory temporary;
  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('muzika_library_sync_');
    Hive.init(temporary.path);
    for (final name in ['user', 'settings', 'cache', 'userNoBackup']) {
      await Hive.openBox(name);
    }
  });
  tearDownAll(() async {
    await Hive.close();
    await temporary.delete(recursive: true);
  });

  test(
    'same-name playlists add missing songs and retain all library categories',
    () {
      final pc = {
        'customPlaylists': [
          {
            'ytid': 'customId-pc',
            'title': 'Dink Mider',
            'source': 'user-created',
            'list': [other],
          },
        ],
        'likedSongs': [other],
        'recentlyPlayedSongs': [
          {...other, 'lastPlayed': DateTime(2026), 'listeningCount': 3},
        ],
      };
      final phone = {
        'customPlaylists': [
          {
            'ytid': 'customId-phone',
            'title': 'Dink Mider',
            'source': 'user-created',
            'list': [rings],
          },
        ],
        'likedSongs': [rings],
        'likedPlaylists': [
          {'ytid': 'UC123', 'title': 'Artist', 'isArtist': true},
          {'ytid': 'MPRE123', 'title': 'Album', 'isAlbum': true},
        ],
        'playlistFolders': [
          {'id': 'folder1', 'name': 'Favourites', 'playlists': []},
        ],
      };
      final merged = mergeLibraries(pc, phone);
      expect((merged['customPlaylists'] as List).single['list'], hasLength(2));
      final back = mergeLibraries(phone, portableLibrary(merged));
      for (final library in [merged, back]) {
        expect(library['likedSongs'], hasLength(2));
        expect(library['likedPlaylists'], hasLength(2));
        expect(library['playlistFolders'], hasLength(1));
        expect(library['recentlyPlayedSongs'], hasLength(1));
        expect(library['customPlaylists'], hasLength(1));
        expect(
          (library['customPlaylists'] as List).single['list'],
          hasLength(2),
        );
      }
      expect(mergeLibraries(merged, back)['customPlaylists'], hasLength(1));
    },
  );

  test(
    'real HTTP exchange completes in both directions with empty phone',
    () async {
      var phone = <String, dynamic>{};
      var confirmed = false;
      final desktop = {
        'likedSongs': [other],
        'customPlaylists': [
          {
            'ytid': 'customId-pc',
            'title': 'Dink Mider',
            'list': [rings],
          },
        ],
      };
      final server = await LibraryPairingServer.start(
        onExchange: (data) async => mergeLibraries(desktop, data),
        onConfirmed: () => confirmed = true,
      );
      addTearDown(server.close);
      await LibraryExchange(server.pairing('127.0.0.1')).sync(
        library: phone,
        save: (incoming) async {
          phone = mergeLibraries(phone, incoming);
        },
      );
      expect(confirmed, isTrue);
      expect(phone['likedSongs'], hasLength(1));
      expect((phone['customPlaylists'] as List).single['list'], [rings]);
    },
  );

  test(
    'production Hive save supports incoming playlists and history over HTTP',
    () async {
      userLikedSongsList.value = [other];
      userRecentlyPlayed.value = [
        {...other, 'lastPlayed': DateTime(2026), 'listeningCount': 3},
      ];
      userCustomPlaylists.value = [];
      userLikedPlaylists.value = [];
      userPlaylistFolders.value = [];
      userPlaylists.value = [];
      syncedPlaylistDetails.value = [];
      var phone = <String, dynamic>{
        'likedSongs': [rings],
        'customPlaylists': [
          {
            'ytid': 'customId-phone',
            'title': 'Dink Mider',
            'source': 'user-created',
            'list': [rings],
          },
        ],
        'recentlyPlayedSongs': [
          {...rings, 'lastPlayed': DateTime(2026, 10, 20), 'listeningCount': 2},
        ],
      };
      Object? saveError;
      final server = await LibraryPairingServer.start(
        onExchange: (incoming) async {
          try {
            return await mergeAndSaveSyncLibrary(incoming);
          } on Object catch (e, stack) {
            saveError = e;
            print('$e\n$stack');
            rethrow;
          }
        },
        onConfirmed: () {},
      );
      addTearDown(server.close);
      try {
        await LibraryExchange(server.pairing('127.0.0.1')).sync(
          library: phone,
          save: (incoming) async {
            phone = mergeLibraries(phone, incoming);
          },
        );
      } on Object {
        if (saveError != null) throw saveError!;
        rethrow;
      }
      expect(userLikedSongsList.value, hasLength(2));
      expect(userRecentlyPlayed.value, hasLength(2));
      expect(userCustomPlaylists.value.single['title'], 'Dink Mider');
      expect(Hive.box('user').get('customPlaylists'), hasLength(1));
      expect(phone['likedSongs'], hasLength(2));
      expect(phone['recentlyPlayedSongs'], hasLength(2));
    },
  );
}
