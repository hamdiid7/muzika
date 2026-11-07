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

import 'package:muzika/constants/clients.dart';
import 'package:youtube_music_explode_dart/youtube_music_explode_dart.dart';

/// Shapes YouTube Music results for the few places that still read them
/// (the catalog itself is Deezer's and Apple's).

YoutubeMusicExplode createMusicClient() => YoutubeMusicExplode();

/// Square album art at [size]px; YouTube Music art URLs carry `=wN-hN…`.
String? squareArt(String? url, int size) {
  if (url == null) return null;
  return url.contains('=w')
      ? url.replaceFirst(RegExp(r'=w\d+-h\d+.*$'), '=w$size-h$size-l90-rj')
      : url;
}

/// A catalog song in the song-map shape the rest of the app uses.
Map<String, dynamic> songMapFromCatalog(MusicSong song, int index) {
  registerSongHint(
    song.videoId,
    title: song.title,
    artist: song.artist.split(',').first.trim(),
    duration: song.duration,
  );
  return {
    'id': index,
    'ytid': song.videoId,
    'title': song.title,
    'artist': song.artist,
    'artistId': song.artistId,
    'album': song.album,
    'albumId': song.albumId,
    'image': squareArt(song.thumbnailUrl, 544),
    'lowResImage': squareArt(song.thumbnailUrl, 226),
    'highResImage': squareArt(song.thumbnailUrl, 1080),
    'duration': song.duration?.inSeconds,
    'isLive': false,
    'isCatalog': true,
  };
}

/// A catalog album or playlist in the playlist-map shape the app uses; it
/// opens with `/home/playlist/<ytid>`.
Map<String, dynamic> collectionMapFromCatalog(MusicCollection c) => {
  'ytid': c.id,
  'title': c.title,
  'artist': c.artist,
  'subtitle': c.subtitle,
  'year': c.year,
  'image': squareArt(c.thumbnailUrl, 544),
  'lowResImage': squareArt(c.thumbnailUrl, 226),
  'isAlbum': c.isAlbum,
  'source': 'youtube-music',
};
