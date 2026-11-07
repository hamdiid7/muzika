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

import 'package:audio_service/audio_service.dart' show AudioProcessingState;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart';
import 'package:muzika/widgets/settings_icon_button.dart';
import 'package:muzika/constants/clients.dart'
    show registerSongHintFrom, streamPlaybackHeaders, youtubeIdOf;
import 'package:muzika/main.dart' show audioHandler;
import 'package:muzika/services/artist_service.dart'
    show ArtistSummary, ArtistSummaryEntry, artistSummary;
import 'package:muzika/services/clip_framing.dart';
import 'package:muzika/services/clip_prefs.dart';
import 'package:muzika/services/clip_requests.dart';
import 'package:muzika/services/common_services.dart';
import 'package:muzika/services/deezer_catalog.dart' show deezerArtistTopSongs;
import 'package:muzika/services/deezer_related.dart';
import 'package:muzika/services/itunes_catalog.dart';
import 'package:muzika/services/muzika_home.dart';
import 'package:muzika/services/playlists_manager.dart'
    show userCustomPlaylists;
import 'package:muzika/services/youtube_canvas.dart';
import 'package:muzika/theme/muzika_tokens.dart';
import 'package:muzika/widgets/discover_video_card.dart';
import 'package:muzika/widgets/lyric_video.dart';
import 'package:muzika/widgets/muzika_sheet_scaffold.dart';

/// Clips: 20 seconds of songs' official music videos on YouTube, full
/// screen and swiped up like short videos. The songs are the most played
/// ones (Deezer) of the artists you play (half of them) and their related
/// artists (the other half), never one already in your library; a clip you
/// have seen stays away for a week, and an artist you swipe away from twice
/// within 3 seconds is held back (see ClipPrefs). Which video a song has,
/// and its stream addresses, are kept (see youtube_canvas.dart), and the
/// next card waits opened in a second player, so a swipe starts it at once.
/// Previews are only for browsing (no stats, no history); what was playing
/// pauses on the way in and resumes on the way out. Tap the song at the
/// bottom to play it in full.
class DiscoverPage extends StatefulWidget {
  const DiscoverPage({super.key});

  @override
  State<DiscoverPage> createState() => _DiscoverPageState();
}

class _DiscoverPageState extends State<DiscoverPage> {
  final _pages = PageController();

  /// The feed, in order: each a song with its music video's id in
  /// [_clipOf] and the video's length in [_lengthOf].
  final _songs = <Map>[];
  final _clipOf = <String, String>{};
  final _lengthOf = <String, Duration>{};

  /// How much of each video plays, round and round.
  static const _slice = Duration(seconds: 20);

  /// Songs with no music video but synced lyrics: lyric videos, their
  /// audio played in the player from the chorus.
  final _lyricsOf = <String, LyricClip>{};

  /// Lyric videos waiting for their turn between clips.
  final _lyricWaiting = <Map>[];

  /// Lyric videos whose song's audio address is found or being found.
  final _lyricWarm = <String>{};
  StreamSubscription<Duration>? _lyricLoop;

  /// Lyric videos play their song here, in the background: the app's player
  /// (and your queue) stay as they were.
  mk.Player? _lyricPlayer;
  bool _loading = true;
  int _current = 0;
  bool? _visible;

  /// When the card on screen came up, to tell a quick skip.
  DateTime _shownAt = DateTime.now();

  /// What was playing when Clips opened: paused on the way in, resumed on
  /// the way out.
  String? _resumeId;
  int _playToken = 0;

  /// Artists whose clips are still to be fetched: yours and their related
  /// ones, taken in turn.
  final _mine = <({String name, String? id})>[];
  final _related = <({String name, String? id})>[];
  final _artistsSeen = <String>{};
  bool _fromMine = true;
  bool _fetching = false;

  /// Songs (with a video) ready for the feed; an artist's are spread out,
  /// two now and the rest later.
  final _ready = <Map>[];
  final _later = <Map>[];

  mk.Player? _video;
  VideoController? _videoView;

  /// The card below, ready in a second player (opened, paused on its first
  /// frame): it shows while you swipe and starts at once when it's on.
  mk.Player? _nextVideo;
  VideoController? _nextView;
  String? _nextKey;
  String? _nextReady;
  CropPath? _nextFraming;
  Duration _nextStart = Duration.zero;

  /// Brings the clip on screen back to its slice's start.
  StreamSubscription<Duration>? _loopWatch;

  /// The clip loaded in [_video], and its framing.
  String? _playing;
  CropPath? _framing;
  bool _paused = false;
  StreamSubscription<bool>? _videoEnd;

  @override
  void initState() {
    super.initState();
    // A clip picked elsewhere before Clips was ever opened leads the feed.
    final asked = clipRequest.value;
    if (asked != null) {
      clipRequest.value = null;
      _showClip(asked);
    }
    clipRequest.addListener(_onRequest);
    unawaited(_start());
  }

  void _onRequest() {
    final asked = clipRequest.value;
    if (asked == null || !mounted) return;
    clipRequest.value = null;
    _showClip(asked);
  }

  /// Puts [clip] on screen now (from an artist's Clips row or Liked clips);
  /// the feed goes on after it.
  void _showClip(AppleClip clip) {
    final id = '${clip.song['ytid']}';
    final at = _songs.isEmpty ? 0 : _current + 1;
    setState(() {
      final before = _songs.indexWhere((s) => '${s['ytid']}' == id);
      if (before >= 0 && before != _current) _songs.removeAt(before);
      if (!_songs.any((s) => '${s['ytid']}' == id)) {
        _songs.insert(at.clamp(0, _songs.length), clip.song);
      }
      // Its YouTube video is looked up when it plays.
      _clipOf.putIfAbsent(id, () => '');
      _loading = false;
    });
    final index = _songs.indexWhere((s) => '${s['ytid']}' == id);
    if (index < 0) return;
    if (_songs.length == 1 || !_pages.hasClients) {
      _current = index;
      if (_visible ?? false) unawaited(_play(_songs[index]));
      return;
    }
    // Not a quick skip of the card it replaces.
    _shownAt = DateTime(2000);
    _pages.jumpToPage(index);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.valuesOf(context).enabled;
    if (visible == _visible) return;
    _visible = visible;
    final current = audioHandler.mediaItem.valueOrNull?.id;
    if (visible) {
      final state = audioHandler.playbackState.valueOrNull;
      // A song still loading counts too: it would start under the clip.
      final busy =
          state != null &&
          (state.playing ||
              state.processingState == AudioProcessingState.loading ||
              state.processingState == AudioProcessingState.buffering);
      if (busy) {
        _resumeId = current;
        unawaited(audioHandler.pause());
      }
      if (_songs.isNotEmpty) unawaited(_play(_songs[_current]));
    } else {
      _playToken++;
      unawaited(_video?.pause());
      // A lyric video's song stops with Clips.
      unawaited(_lyricLoop?.cancel());
      unawaited(_lyricPlayer?.pause());
      if (_resumeId != null && _resumeId == current) {
        _resumeId = null;
        unawaited(audioHandler.play());
      }
    }
  }

  @override
  void dispose() {
    clipRequest.removeListener(_onRequest);
    unawaited(_lyricLoop?.cancel());
    unawaited(_videoEnd?.cancel());
    unawaited(_loopWatch?.cancel());
    unawaited(_video?.dispose());
    unawaited(_nextVideo?.dispose());
    unawaited(_lyricPlayer?.dispose());
    _pages.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Feed
  // -------------------------------------------------------------------------

  /// Starts from the artists you play, like and put in your playlists most
  /// (before any of that, those of the songs picked for you).
  Future<void> _start() async {
    final counts = <String, int>{};
    final ids = <String, String>{};
    void count(Iterable<Map> songs) {
      for (final s in songs) {
        final artist = '${s['artist'] ?? ''}'
            .replaceAll(RegExp(r'\s*-\s*Topic$'), '')
            .split(',')
            .first
            .trim();
        if (artist.isEmpty) continue;
        counts[artist] = (counts[artist] ?? 0) + 1;
        final id = '${s['artistId'] ?? ''}';
        if (id.startsWith('UC')) ids[artist] ??= id;
      }
    }

    count([
      ...userRecentlyPlayed.value.whereType<Map>(),
      ...userLikedSongsList.value.whereType<Map>(),
      // Your own playlists' songs too ("Dink Mider" and the like).
      for (final playlist in userCustomPlaylists.value)
        ...((playlist['list'] as List?) ?? const []).whereType<Map>(),
    ]);
    if (counts.isEmpty) {
      if (discoveryPool.isEmpty) await forYouSongs(count: 30);
      count(discoveryPool);
    }
    if (!mounted) return;
    for (final e
        in (counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
            .take(12)) {
      _addArtist(_mine, e.key, ids[e.key]);
    }
    await _more();
  }

  void _addArtist(
    List<({String name, String? id})> into,
    String name,
    String? id,
  ) {
    if (name.isEmpty || !_artistsSeen.add(name.toLowerCase())) return;
    into.add((name: name, id: id));
  }

  /// Fetches the next artists' clips (yours and related ones in turn) until
  /// eight cards wait past the one on screen.
  Future<void> _more() async {
    if (_fetching) return;
    _fetching = true;
    try {
      while (mounted && _songs.length - _current < 8) {
        // Two of each artist now; their other clips only once no artist is
        // left to fetch, so one artist's clips don't come in a row.
        if (_ready.isNotEmpty) {
          _append();
          continue;
        }
        final from = (_fromMine && _mine.isNotEmpty) || _related.isEmpty
            ? _mine
            : _related;
        if (from.isEmpty) {
          if (_later.isEmpty) {
            if (_lyricWaiting.isEmpty) break;
            _appendLyric();
            continue;
          }
          _append();
          continue;
        }
        _fromMine = !_fromMine;
        final artist = from.removeAt(0);
        if (ClipPrefs.heldBack(artist.name)) continue;
        final results = await Future.wait([
          _artistVideos(artist.name),
          if (artist.id != null) artistSummary(artist.id!),
        ]);
        if (!mounted) return;
        final clips = results.first as List<Map>;
        if (results.length > 1) {
          final summary = results[1] as ArtistSummary?;
          for (final r in summary?.related ?? const <ArtistSummaryEntry>[]) {
            if (_artistsSeen.length < 120) _addArtist(_related, r.name, r.id);
          }
        }
        // Artists like this one, from Deezer.
        for (final r in await relatedArtists(artist.name)) {
          if (_artistsSeen.length < 120) _addArtist(_related, r.name, null);
        }
        _ready.addAll(clips.take(2));
        _later.addAll(clips.skip(2));
      }
    } finally {
      _fetching = false;
      if (mounted && _loading) setState(() => _loading = false);
    }
  }

  /// [artist]'s most played songs (Deezer's order) that have an official
  /// music video on YouTube: not in your library, not seen this week, one
  /// version of each. Six are looked at, at the same time.
  Future<List<Map>> _artistVideos(String artist) async {
    List<Map<String, dynamic>> top;
    try {
      top = await deezerArtistTopSongs(artist);
    } catch (_) {
      return const [];
    }
    final titles = <String>{};
    final picked = [
      for (final song in top)
        if (!_inLibrary(song) &&
            !ClipPrefs.seenRecently('${song['ytid']}') &&
            !_clipOf.containsKey('${song['ytid']}') &&
            titles.add(_titleKey(song)))
          song,
    ].take(6).toList();
    final videos = await Future.wait([
      for (final song in picked) musicVideoFor(song).catchError((_) => null),
    ]);
    return [
      for (final (i, video) in videos.indexed)
        if (video != null) _withVideo(picked[i], video),
    ];
  }

  Map _withVideo(Map song, MusicVideo video) {
    final id = '${song['ytid']}';
    _clipOf[id] = video.id;
    _lengthOf[id] = video.length;
    return song;
  }

  /// Looks up the video of a card that came without one (opened from an
  /// artist's page or Liked clips); false when it has none.
  Future<bool> _resolve(Map song) async {
    final id = '${song['ytid']}';
    if (_clipOf[id]?.isNotEmpty ?? false) return true;
    final video = await musicVideoFor(song).catchError((_) => null);
    if (video == null) return false;
    _withVideo(song, video);
    return true;
  }

  /// The next waiting lyric video joins the end of the feed.
  void _appendLyric() {
    final song = _lyricWaiting.removeAt(0);
    setState(() {
      _songs.add(song);
      _loading = false;
    });
    _warmLyrics(_current);
  }

  /// Clips are for finding music: nothing already in your library (liked,
  /// in your playlists, downloaded) joins the feed. A clip you open from an
  /// artist's page or Liked clips still shows.
  bool _inLibrary(Map song) {
    final library = [
      ...userLikedSongsList.value,
      ...userOfflineSongs.value,
      for (final playlist in userCustomPlaylists.value)
        ...((playlist['list'] as List?) ?? const []),
    ].whereType<Map>().toList();
    if (library.length != _librarySize) {
      _librarySize = library.length;
      _libraryKeys
        ..clear()
        ..addAll([
          for (final s in library) ...['${s['ytid']}', _songKey(s)],
        ]);
    }
    return _libraryKeys.contains('${song['ytid']}') ||
        _libraryKeys.contains(_songKey(song));
  }

  final _libraryKeys = <String>{};
  int _librarySize = -1;

  /// The same song from Apple or YouTube: its title and main artist.
  String _songKey(Map song) {
    final artist = '${song['artist'] ?? ''}'
        .replaceAll(RegExp(r'\s*-\s*Topic$'), '')
        .split(RegExp(r',|&| x | feat\.?'))
        .first
        .toLowerCase()
        .replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');
    return '${_titleKey(song)}|$artist';
  }

  String _titleKey(Map song) => '${song['title'] ?? ''}'
      .toLowerCase()
      .replaceAll(RegExp(r'\(.*?\)|\[.*?\]'), '')
      .replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');

  /// One card from the ready clips (an earlier artist's later clips once no
  /// artist is left to fetch).
  void _append() {
    final song = (_ready.isNotEmpty ? _ready : _later).removeAt(0);
    final id = '${song['ytid']}';
    if (_songs.any((s) => '${s['ytid']}' == id) || _inLibrary(song)) return;
    final first = _songs.isEmpty;
    setState(() {
      _songs.add(song);
      _loading = false;
    });
    // The covers come before the clip: fetched as the card joins the feed.
    for (final k in ['lowResImage', 'image']) {
      final link = song[k]?.toString();
      if (link == null || !link.startsWith('http')) continue;
      unawaited(
        precacheImage(
          CachedNetworkImageProvider(link),
          context,
        ).catchError((_) {}),
      );
    }
    if (first && (_visible ?? false)) {
      unawaited(_play(_songs.first));
    } else {
      _prefetch(_current);
    }
  }

  void _onPage(int index) {
    unawaited(HapticFeedback.selectionClick());
    // Swiped away within 3 seconds: less of that artist from now on.
    if (DateTime.now().difference(_shownAt) < const Duration(seconds: 3) &&
        _current < _songs.length &&
        index > _current) {
      ClipPrefs.quickSkip('${_songs[_current]['artist'] ?? ''}');
    }
    setState(() => _current = index);
    unawaited(_play(_songs[index]));
    unawaited(_more());
  }

  /// A card that won't play leaves the feed; the next one moves up.
  void _dropCard(Map song) {
    final index = _songs.indexOf(song);
    if (index < 0) return;
    setState(() {
      _songs.removeAt(index);
      if (_current >= _songs.length && _songs.isNotEmpty) {
        _current = _songs.length - 1;
      }
    });
    if (index == _current && _songs.isNotEmpty && (_visible ?? false)) {
      unawaited(_play(_songs[_current]));
    }
    unawaited(_more());
  }

  // -------------------------------------------------------------------------
  // Playing
  // -------------------------------------------------------------------------

  /// Readies the cards after [index]: the next three's videos and stream
  /// addresses are found (and kept), and their covers fetched.
  void _prefetch(int index) {
    for (var k = 1; k <= 3 && index + k < _songs.length; k++) {
      final song = _songs[index + k];
      unawaited(
        _resolve(song)
            .then((found) {
              final video = _clipOf['${song['ytid']}'];
              if (!found || video == null || video.isEmpty) return null;
              return youtubeStreamsFor(video, audio: true);
            })
            .catchError((_) => null),
      );
      final cover = song['image']?.toString();
      if (cover != null && cover.startsWith('http')) {
        unawaited(
          precacheImage(
            CachedNetworkImageProvider(cover),
            context,
          ).catchError((_) {}),
        );
      }
    }
  }

  /// Opens a card's video in [player], paused at its slice's start, with
  /// the video's own sound.
  Future<Duration?> _openClip(mk.Player player, Map song) async {
    final key = '${song['ytid']}';
    if (!await _resolve(song)) return null;
    final video = _clipOf[key]!;
    final streams = await youtubeStreamsFor(
      video,
      audio: true,
    ).catchError((_) => null);
    if (streams == null) return null;
    final start = sliceStart(_lengthOf[key] ?? Duration.zero, _slice);
    final native = player.platform;
    if (native is mk.NativePlayer) {
      // The headers for the sound too, which comes as a second stream.
      await native.setProperty(
        'http-header-fields',
        [
          for (final e in streams.headers.entries)
            '${e.key}: ${e.value.replaceAll(',', r'\,')}',
        ].join(','),
      );
    }
    await player.open(
      // Straight at the slice: media_kit sets mpv's start as it loads
      // (a start set before opening is cleared when the last video unloads).
      mk.Media(streams.video, httpHeaders: streams.headers, start: start),
      play: false,
    );
    if (streams.audio != null) {
      await player.setAudioTrack(mk.AudioTrack.uri(streams.audio!));
    }
    return start;
  }

  /// A player for clips that keeps only about the 20 s slice: mpv's usual
  /// 32 MB read-ahead downloads the whole video on a slow line.
  static mk.Player _clipPlayer() => mk.Player(
    configuration: const mk.PlayerConfiguration(bufferSize: 6 * 1024 * 1024),
  );

  /// Round again to the slice's start after [_slice].
  void _loop(mk.Player player, Duration start, int token) {
    unawaited(_loopWatch?.cancel());
    _loopWatch = player.stream.position.listen((p) {
      if (token != _playToken) return;
      if (p >= start + _slice) unawaited(player.seek(start));
    });
    unawaited(_videoEnd?.cancel());
    _videoEnd = player.stream.completed.listen((done) {
      if (!done || token != _playToken) return;
      unawaited(player.seek(start).then((_) => player.play()));
    });
  }

  /// The card's video slice on a loop with its own sound (the card below
  /// is usually ready and swaps in at once).
  Future<void> _play(Map song) async {
    final token = ++_playToken;
    final key = '${song['ytid']}';
    _shownAt = DateTime.now();
    ClipPrefs.markSeen(key);
    unawaited(_lyricLoop?.cancel());
    _lyricLoop = null;
    final lyric = _lyricsOf[key];
    if (lyric != null) return _playLyrics(song, key, lyric, token);
    // Leaving a lyric video: its song stops.
    unawaited(_lyricPlayer?.pause());
    if (_nextReady == key && _nextVideo != null) {
      return _playReady(song, key, token);
    }
    unawaited(_video?.pause());
    setState(() {
      _playing = null;
      _framing = null;
      _paused = false;
    });
    final player = _video ??= _clipPlayer();
    _videoView ??= VideoController(player);
    Duration? start;
    try {
      start = await _openClip(player, song);
    } catch (_) {
      start = null;
    }
    if (token != _playToken || !mounted) return;
    if (start == null) return _dropCard(song);
    _loop(player, start, token);
    setState(() => _playing = _clipOf[key]);
    if (_visible ?? false) unawaited(player.play());
    _prefetch(_current);
    unawaited(_readyNext());
  }

  /// A lyric video: the song itself plays (not counted as listened until
  /// opened) from its chorus, round again after [lyricClipLength].
  Future<void> _playLyrics(
    Map song,
    String key,
    LyricClip lyric,
    int token,
  ) async {
    unawaited(_video?.pause());
    setState(() {
      _playing = key;
      _framing = null;
      _paused = false;
    });
    if (!(_visible ?? false)) return;
    registerSongHintFrom(song);
    final url = await fetchSongStreamUrl(key, false).catchError((_) => null);
    if (url == null || token != _playToken || !mounted) return;
    final player = _lyricPlayer ??= mk.Player();
    try {
      await player.open(
        mk.Media(
          url,
          httpHeaders: url.startsWith('http')
              ? streamPlaybackHeaders(youtubeIdOf(key))
              : null,
        ),
        play: false,
      );
      // Seek once the song's length is known (it can't seek before).
      await player.stream.duration
          .firstWhere((d) => d > Duration.zero)
          .timeout(const Duration(seconds: 20));
    } catch (_) {
      return;
    }
    if (token != _playToken || !mounted) return;
    await player.seek(lyric.start);
    if (_visible ?? false) unawaited(player.play());
    final end = lyric.start + lyricClipLength;
    _lyricLoop = player.stream.position.listen((position) {
      if (token != _playToken) return;
      if (position > end) unawaited(player.seek(lyric.start));
    });
    _prefetch(_current);
    unawaited(_readyNext());
  }

  /// The next three cards' lyric videos: their song's playable upload and
  /// audio address are found now (and kept by the player), so the song
  /// starts soon after its card comes on.
  void _warmLyrics(int index) {
    for (var k = 1; k <= 3 && index + k < _songs.length; k++) {
      final song = _songs[index + k];
      final key = '${song['ytid']}';
      if (!_lyricsOf.containsKey(key) || !_lyricWarm.add(key)) continue;
      registerSongHintFrom(song);
      unawaited(
        fetchSongStreamUrl(key, false)
            .timeout(const Duration(seconds: 20))
            .then((url) {
              if (url == null) _lyricWarm.remove(key);
            })
            .catchError((_) {
              _lyricWarm.remove(key);
            }),
      );
    }
  }

  /// The card that was waiting below is now on: its player swaps in, so the
  /// clip starts at once, and the old player readies the next card.
  void _playReady(Map song, String key, int token) {
    final url = _clipOf[key];
    if (url == null) return;
    final old = _video;
    final oldView = _videoView;
    _video = _nextVideo;
    _videoView = _nextView;
    _nextVideo = old;
    _nextView = oldView;
    unawaited(old?.pause());
    final framing = _nextFraming;
    final start = _nextStart;
    _nextKey = null;
    _nextReady = null;
    _nextFraming = null;
    final player = _video!;
    _loop(player, start, token);
    setState(() {
      _playing = url;
      _framing = framing;
      _paused = false;
    });
    if (_visible ?? false) unawaited(player.play());
    _prefetch(_current);
    unawaited(_readyNext());
  }

  /// Opens the card below in the second player, paused on its slice's
  /// first frame.
  Future<void> _readyNext() async {
    final index = _current + 1;
    if (index >= _songs.length) return;
    final song = _songs[index];
    final key = '${song['ytid']}';
    if (_nextKey == key || _lyricsOf.containsKey(key)) return;
    _nextKey = key;
    final player = _nextVideo ??= _clipPlayer();
    _nextView ??= VideoController(player);
    Duration? start;
    try {
      start = await _openClip(player, song);
    } catch (_) {
      start = null;
    }
    if (!mounted || _nextKey != key) return;
    if (start == null) {
      _nextKey = null;
      return;
    }
    _nextStart = start;
    setState(() => _nextReady = key);
  }

  void _togglePause() {
    if (_current < _songs.length &&
        _lyricsOf.containsKey('${_songs[_current]['ytid']}')) {
      unawaited(HapticFeedback.selectionClick());
      setState(() => _paused = !_paused);
      final player = _lyricPlayer;
      if (player != null) {
        unawaited(_paused ? player.pause() : player.play());
      }
      return;
    }
    final player = _video;
    if (player == null || _playing == null) return;
    unawaited(HapticFeedback.selectionClick());
    setState(() => _paused = !_paused);
    unawaited(_paused ? player.pause() : player.play());
  }

  /// The song at the bottom plays it in full, in the player, from the
  /// start (the clip is its own moment of the video).
  Future<void> _openPlayer(Map song) async {
    _playToken++;
    unawaited(_lyricLoop?.cancel());
    unawaited(_lyricPlayer?.pause());
    unawaited(_video?.pause());
    _resumeId = null;
    if (!mounted) return;
    MuzikaTopPlayer.openNowPlaying(context);
    await audioHandler.addPlaylistToQueue([song], replace: true);
  }

  /// The card's video on YouTube, kept with a liked clip.
  String? _clipLink(Map song) {
    final video = _clipOf['${song['ytid']}'];
    return video == null || video.isEmpty
        ? null
        : 'https://www.youtube.com/watch?v=$video';
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, box) {
          return Stack(
            fit: StackFit.expand,
            children: [
              if (_loading && _songs.isEmpty)
                const Center(
                  child: CircularProgressIndicator(color: Colors.white70),
                )
              else if (_songs.isEmpty)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      'No clips right now. Play a few songs: Clips shows '
                      'videos of the artists you play and similar ones.',
                      textAlign: TextAlign.center,
                      style: muzikaBody(16, color: Colors.white70),
                    ),
                  ),
                )
              else
                PageView.builder(
                  controller: _pages,
                  scrollDirection: Axis.vertical,
                  itemCount: _songs.length,
                  onPageChanged: _onPage,
                  itemBuilder: (context, i) {
                    final song = _songs[i];
                    final active = i == _current;
                    // The card below shows its clip, paused, while swiping.
                    final waiting = !active && _nextReady == '${song['ytid']}';
                    if (waiting) {
                      return ClipCard(
                        song: song,
                        clipUrl: _clipLink(song),
                        playing: true,
                        player: _nextVideo,
                        controller: _nextView,
                        framing: _nextFraming,
                        paused: false,
                        onTogglePause: _togglePause,
                        onOpenPlayer: () => _openPlayer(song),
                      );
                    }
                    final lyric = _lyricsOf['${song['ytid']}'];
                    if (lyric != null) {
                      return ClipCard(
                        song: song,
                        lyrics: lyric,
                        lyricPosition: _lyricPlayer?.stream.position,
                        playing: active,
                        player: null,
                        controller: null,
                        framing: null,
                        paused: active && _paused,
                        onTogglePause: _togglePause,
                        onOpenPlayer: () => _openPlayer(song),
                      );
                    }
                    return ClipCard(
                      song: song,
                      clipUrl: _clipLink(song),
                      playing: active && _playing == _clipOf['${song['ytid']}'],
                      player: active ? _video : null,
                      controller: active ? _videoView : null,
                      framing: active ? _framing : null,
                      paused: active && _paused,
                      onTogglePause: _togglePause,
                      onOpenPlayer: () => _openPlayer(song),
                    );
                  },
                ),
              // The title over the top of the clip, under the status bar.
              IgnorePointer(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Container(
                    width: double.infinity,
                    padding: EdgeInsets.fromLTRB(20, top + 12, 20, 28),
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0x99000000), Color(0x00000000)],
                      ),
                    ),
                    child: Row(
                      children: [
                        // Room for the gear (it's above this shade).
                        const SizedBox(width: 42),
                        Text(
                          'Clips',
                          style: muzikaHeading(24, color: Colors.white),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 14,
                top: top + 10,
                child: const SettingsIconButton(color: Colors.white),
              ),
            ],
          );
        },
      ),
    );
  }
}
