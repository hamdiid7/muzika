import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:muzika/services/liked_songs_transfer.dart';

void main() {
  const first = {'ytid': 'abcdefghijk', 'title': 'First', 'artist': 'Artist'};
  const second = {'ytid': '123456789_-', 'title': 'Second', 'artist': 'Singer'};

  test('pairing accepts local IPv4 only and rejects other QR destinations', () {
    final pairing = LikedSongsPairing('192.168.1.12', 30123, 'a' * 64);
    expect(
      LikedSongsPairing.parse(pairing.code).endpoint.toString(),
      'http://192.168.1.12:30123/liked',
    );
    for (final host in [
      '8.8.8.8',
      'example.com',
      '192.168.1.2.example.com',
      '::1',
      '172.32.0.1',
      '169.254.1.1',
    ]) {
      expect(
        () => LikedSongsPairing.parse(
          LikedSongsPairing(host, 30123, 'a' * 64).code,
        ),
        throwsFormatException,
      );
    }
    expect(
      () => LikedSongsPairing.parse('https://muzika.com.et'),
      throwsFormatException,
    );
    expect(
      () => LikedSongsPairing.parse(
        LikedSongsPairing('10.0.0.2', 0, 'a' * 64).code,
      ),
      throwsFormatException,
    );
    expect(
      () => LikedSongsPairing.parse(
        const LikedSongsPairing('10.0.0.2', 80, 'short').code,
      ),
      throwsFormatException,
    );
  });

  test(
    'portable metadata excludes local files, playback URLs and invalid IDs',
    () {
      final songs = portableLikedSongs([
        {
          ...first,
          'artworkPath': 'C:/local/cover.jpg',
          'url': 'http://cached/audio',
          'image': 'file:///private/image.jpg',
          'highResImage': 'https://i.ytimg.com/cover.jpg',
          'duration': '3:20',
        },
        first,
        {'ytid': 'bad', 'title': 'Invalid'},
      ]);
      expect(songs, [
        {
          ...first,
          'highResImage': 'https://i.ytimg.com/cover.jpg',
          'duration': '3:20',
        },
      ]);
    },
  );

  test(
    'merging preserves existing library data and order, skips duplicate IDs',
    () {
      final existing = [
        {...first, 'artworkPath': 'local.jpg'},
      ];
      final merged = mergeTransferredLikes(existing, [first, second, second]);
      expect(merged, [existing.first, second]);
      expect(existing.length, 1);
    },
  );

  test(
    'real LAN protocol transfers full metadata once and merges likes',
    () async {
      var library = <dynamic>[first];
      var imports = 0;
      final receiver = await LikedSongsReceiver.start(
        bindAddress: InternetAddress.loopbackIPv4,
        onReceive: (songs) async {
          imports++;
          final merged = mergeTransferredLikes(library, songs);
          final added = merged.length - library.length;
          library = merged;
          return added;
        },
      );
      addTearDown(receiver.close);
      final pairing = receiver.pairing('127.0.0.1');
      final result = await sendLikedSongs(pairing, [first, second]);
      expect(result, (added: 1, received: 2));
      expect(library, [first, second]);
      expect(imports, 1);
      expect(receiver.completed, isTrue);
      await expectLater(sendLikedSongs(pairing, [second]), throwsA(anything));
      expect(imports, 1);
    },
  );

  test(
    'invalid token and malformed payload do not consume pairing or import',
    () async {
      var imports = 0;
      final receiver = await LikedSongsReceiver.start(
        bindAddress: InternetAddress.loopbackIPv4,
        onReceive: (songs) async {
          imports++;
          return songs.length;
        },
      );
      addTearDown(receiver.close);
      final pairing = receiver.pairing('127.0.0.1');
      await expectLater(
        sendLikedSongs(
          LikedSongsPairing(pairing.host, pairing.port, '0' * 64),
          [first],
        ),
        throwsFormatException,
      );
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final request = await client.postUrl(pairing.endpoint);
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${pairing.token}',
      );
      request.write(
        jsonEncode({
          'version': 1,
          'songs': [
            {'ytid': '../../bad'},
          ],
        }),
      );
      final response = await request.close();
      expect(response.statusCode, HttpStatus.badRequest);
      await response.drain<void>();
      expect(imports, 0);
      expect((await sendLikedSongs(pairing, [second])).added, 1);
      expect(imports, 1);
    },
  );

  test('closing or expiring a pairing prevents future imports', () async {
    var imports = 0;
    final receiver = await LikedSongsReceiver.start(
      bindAddress: InternetAddress.loopbackIPv4,
      lifetime: const Duration(milliseconds: 30),
      onReceive: (_) async {
        imports++;
        return 1;
      },
    );
    addTearDown(receiver.close);
    final pairing = receiver.pairing('127.0.0.1');
    await Future<void>.delayed(const Duration(milliseconds: 70));
    expect(receiver.expired, isTrue);
    await expectLater(sendLikedSongs(pairing, [first]), throwsA(anything));
    expect(imports, 0);
  });
}
