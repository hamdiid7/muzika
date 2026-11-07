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

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muzika/constants/clients.dart'
    show registerSongHintFrom, streamPlaybackHeaders;
import 'package:muzika/main.dart' show audioHandler;
import 'package:muzika/services/artist_service.dart';
import 'package:muzika/services/catalog_relay.dart';
import 'package:muzika/services/common_services.dart';
import 'package:muzika/services/desktop_panels.dart';
import 'package:muzika/services/itunes_catalog.dart';
import 'package:muzika/services/playlists_manager.dart';
import 'package:muzika/services/sample_cache.dart';
import 'package:muzika/services/song_battles.dart';
import 'package:muzika/services/synced_lyrics.dart';
import 'package:muzika/theme/muzika_tokens.dart';

String _cover(Map item) =>
    [item['highResImage'], item['image'], item['lowResImage']]
        .map((e) => '${e ?? ''}')
        .firstWhere((e) => e.startsWith('http'), orElse: () => '');

Widget _coverBox(Map item, double size, ColorScheme scheme) {
  final url = _cover(item);
  return ClipRRect(
    borderRadius: BorderRadius.circular(size / 8),
    child: SizedBox(
      width: size,
      height: size,
      child: url.isEmpty
          ? ColoredBox(color: scheme.surfaceContainerHigh)
          : Image(image: CachedNetworkImageProvider(url), fit: BoxFit.cover),
    ),
  );
}

// ---------------------------------------------------------------------------
// Picking the other album
// ---------------------------------------------------------------------------

/// The "Compare" sheet of an album: albums like it (the artist's others,
/// then related artists'), or any album found by search. Tapping one starts
/// the match.
Future<void> showAlbumOpponents(BuildContext context, Map album) {
  return showModalBottomSheet<void>(
    context: context,
    // Wide Windows layout: the sheet opens in the part it came from.
    useRootNavigator: !desktopPanels.value,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _OpponentSheet(album: album),
  );
}

class _OpponentSheet extends StatefulWidget {
  const _OpponentSheet({required this.album});

  final Map album;

  @override
  State<_OpponentSheet> createState() => _OpponentSheetState();
}

class _OpponentSheetState extends State<_OpponentSheet> {
  final _suggested = <Map>[];
  final _seen = <String>{};
  List<Map>? _results;
  bool _loading = true;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _seen.add('${widget.album['ytid']}');
    unawaited(_loadSuggestions());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _add(Iterable<Map> albums) {
    if (!mounted) return;
    setState(() {
      for (final a in albums) {
        final id = '${a['ytid'] ?? ''}';
        if (id.startsWith('MPRE') && _seen.add(id)) _suggested.add(a);
      }
    });
  }

  List<Map> _albumsOf(Map? profile, {int? take}) {
    final releases = (profile?['releases'] as List? ?? const [])
        .whereType<Map>()
        .where((r) => r['releaseType'] != 'single')
        .toList();
    return take == null ? releases : releases.take(take).toList();
  }

  /// The artist's other albums first, then albums by related artists.
  Future<void> _loadSuggestions() async {
    try {
      final artistId = '${widget.album['artistId'] ?? ''}';
      final artist = artistId.isNotEmpty
          ? artistId
          : '${widget.album['artist'] ?? ''}';
      if (artist.isEmpty) return;
      final profile = await getArtistProfile(
        artist,
        preferredName: widget.album['artist']?.toString(),
      );
      _add(_albumsOf(profile));
      final related = (profile?['relatedArtists'] as List? ?? const [])
          .whereType<Map>()
          .take(6)
          .toList();
      await Future.wait([
        for (final r in related)
          getArtistProfile(
            '${r['ytid']}',
            preferredName: r['title']?.toString(),
          ).then((p) => _add(_albumsOf(p, take: 3))).catchError((_) {}),
      ]);
    } catch (_) {
      // The search box still works.
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _search(String query) {
    _debounce?.cancel();
    if (query.trim().isEmpty) {
      setState(() => _results = null);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      try {
        final found = await ytMusicClient.music.searchAlbums(query.trim());
        if (!mounted) return;
        setState(() {
          _results = [
            for (final c in found)
              if (c.id != widget.album['ytid']) collectionMapFromCatalog(c),
          ];
        });
      } catch (_) {
        if (mounted) setState(() => _results = const []);
      }
    });
  }

  void _start(Map other) {
    Navigator.of(context).pop();
    unawaited(
      Navigator.of(context, rootNavigator: !desktopPanels.value).push(
        MaterialPageRoute<void>(
          builder: (_) => AlbumBattlePage(left: widget.album, right: other),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final list = _results ?? _suggested;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.85,
      child: Column(
        children: [
          const SizedBox(height: 12),
          Text(
            'Compare with',
            style: muzikaHeading(20, color: scheme.onSurface),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              onChanged: _search,
              decoration: InputDecoration(
                hintText: 'Search albums',
                prefixIcon: const Icon(Icons.search_rounded),
                filled: true,
                fillColor: scheme.surfaceContainerHigh,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Expanded(
            child: list.isEmpty
                ? Center(
                    child: _loading && _results == null
                        ? const CircularProgressIndicator()
                        : Text(
                            'No albums found',
                            style: muzikaBody(
                              15,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 24),
                    itemCount: list.length,
                    itemBuilder: (context, i) {
                      final a = list[i];
                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 4,
                        ),
                        leading: _coverBox(a, 52, scheme),
                        title: Text(
                          '${a['title'] ?? ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: muzikaBody(
                            16,
                            weight: 600,
                            color: scheme.onSurface,
                          ),
                        ),
                        subtitle: Text(
                          [a['artist'], a['year']]
                              .where((e) => e != null && '$e'.isNotEmpty)
                              .join(' · '),
                          maxLines: 1,
                          style: muzikaBody(13, color: scheme.onSurfaceVariant),
                        ),
                        onTap: () => _start(a),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// The match
// ---------------------------------------------------------------------------

/// Two albums side by side, every track listed: track against track, ten
/// seconds of each (from the chorus), then tap the one you like more. The
/// song playing is outlined, winners stay green, losers fade. Wins feed
/// Library's "Song ranks".
class AlbumBattlePage extends StatefulWidget {
  const AlbumBattlePage({super.key, required this.left, required this.right});

  final Map left;
  final Map right;

  @override
  State<AlbumBattlePage> createState() => _AlbumBattlePageState();
}

class _AlbumBattlePageState extends State<AlbumBattlePage> {
  static const _sample = Duration(seconds: 10);
  static const _fadeIn = Duration(milliseconds: 700);
  static const _fadeOut = Duration(milliseconds: 800);

  final _player = AudioPlayer();
  final _leftScroll = ScrollController();
  final _rightScroll = ScrollController();
  int _token = 0;
  bool _resumeMain = false;

  List<Map> _a = const [];
  List<Map> _b = const [];
  bool _loadingAlbums = true;
  int _round = 0;

  /// Who won each round: true for the left album.
  final _results = <int, bool>{};

  /// The side whose sample is loading or playing (true = left), and whether
  /// it is paused.
  bool? _side;
  bool _sideLoading = false;
  bool _paused = false;

  int get _rounds => _a.length < _b.length ? _a.length : _b.length;
  bool get _finished => !_loadingAlbums && _round >= _rounds;
  int get _leftScore => _results.values.where((l) => l).length;
  int get _rightScore => _results.values.where((l) => !l).length;

  @override
  void initState() {
    super.initState();
    _resumeMain = audioHandler.playbackState.valueOrNull?.playing ?? false;
    if (_resumeMain) unawaited(audioHandler.pause());
    unawaited(_load());
  }

  @override
  void dispose() {
    _token++;
    unawaited(_player.dispose());
    _leftScroll.dispose();
    _rightScroll.dispose();
    if (_resumeMain) unawaited(audioHandler.play());
    super.dispose();
  }

  Future<List<Map>> _tracks(Map album) async {
    final list = album['list'];
    if (list is List && list.isNotEmpty) return list.whereType<Map>().toList();
    final full = await getPlaylistInfoForWidget('${album['ytid']}');
    return (full?['list'] as List? ?? const []).whereType<Map>().toList();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      _tracks(widget.left).catchError((_) => <Map>[]),
      _tracks(widget.right).catchError((_) => <Map>[]),
    ]);
    if (!mounted) return;
    setState(() {
      _a = [for (final s in results[0]) _withCover(s, widget.left)];
      _b = [for (final s in results[1]) _withCover(s, widget.right)];
      _loadingAlbums = false;
    });
    if (_rounds == 0) return;
    // The first two rounds' songs download straight away.
    _prefetchRounds(0, 2);
    unawaited(_playRound());
  }

  // -------------------------------------------------------------------------
  // Playback
  // -------------------------------------------------------------------------

  /// The left song's sample, then the right's; then it waits for a pick.
  Future<void> _playRound() async {
    final token = ++_token;
    // Two rounds ahead keep downloading while this one plays.
    _prefetchRounds(_round + 1, 2);
    await _playSample(true, token);
    if (token != _token || !mounted) return;
    await _playSample(false, token);
  }

  /// Starts downloading both songs of [count] rounds from [from] in the
  /// background (Apple's preview, or the song and where its chorus is).
  void _prefetchRounds(int from, int count) {
    for (var r = from; r < from + count && r < _rounds; r++) {
      for (final song in [_a[r], _b[r]]) {
        registerSongHintFrom(song);
        unawaited(
          SampleCache.fetch(song).then((file) {
            if (file != null && !SampleCache.isPreview(file)) {
              unawaited(_chorusOf(song));
            }
          }),
        );
      }
    }
  }

  /// Where each song's chorus starts, once its lyrics have been read.
  final _chorus = <String, Future<Duration?>>{};

  /// The song's best bit: the line sung most often (the chorus), the first
  /// time it comes after the intro. Null without synced lyrics.
  Future<Duration?> _chorusOf(Map song) {
    final id = '${song['ytid']}';
    return _chorus[id] ??= () async {
      final lyrics = await fetchSongLyrics(
        artist: '${song['artist'] ?? ''}',
        title: '${song['title'] ?? ''}',
        videoId: id,
        duration: song['duration'] is num
            ? Duration(seconds: (song['duration'] as num).toInt())
            : null,
        background: true,
      ).timeout(const Duration(seconds: 8)).catchError((_) => null);
      final lines = lyrics?.lines;
      if (lines == null || lines.length < 4) return null;
      String key(String t) => t.toLowerCase().replaceAll(
        RegExp(r'[^\p{L}\p{N}]', unicode: true),
        '',
      );
      final counts = <String, int>{};
      for (final l in lines) {
        final k = key(l.text);
        if (k.length > 3) counts[k] = (counts[k] ?? 0) + 1;
      }
      if (counts.isEmpty) return null;
      final top = counts.entries.reduce((a, b) => a.value >= b.value ? a : b);
      if (top.value < 2) return null; // nothing repeats: no clear chorus
      final intro = lines.last.time * 0.2;
      final hits = lines.where((l) => key(l.text) == top.key).toList();
      final at = hits.firstWhere(
        (l) => l.time >= intro,
        orElse: () => hits.first,
      );
      // A beat early, so the line is heard from its start.
      final start = at.time - const Duration(milliseconds: 800);
      return start.isNegative ? Duration.zero : start;
    }();
  }

  /// Turns the volume to [target] smoothly over [over].
  Future<void> _fadeTo(double target, Duration over, int token) async {
    const steps = 10;
    final from = _player.volume;
    for (var i = 1; i <= steps; i++) {
      if (token != _token) return;
      await _player.setVolume(from + (target - from) * i / steps);
      await Future<void>.delayed(over ~/ steps);
    }
  }

  /// Plays ten seconds of the current round's [left] or right song, from
  /// its chorus (or middle), fading in and out.
  Future<void> _playSample(bool left, int token) async {
    final song = (left ? _a : _b)[_round];
    setState(() {
      _side = left;
      _sideLoading = true;
      _paused = false;
    });
    _scrollToRound();
    try {
      final id = '${song['ytid']}';
      registerSongHintFrom(song);
      await _player.stop();
      // From the downloaded file when it's there (opens and seeks at once);
      // a download under way is worth a short wait; else stream it.
      var file = SampleCache.ready(song);
      if (file == null && SampleCache.started(song)) {
        file = await SampleCache.fetch(song)
            .timeout(const Duration(seconds: 6), onTimeout: () => null);
      }
      if (token != _token) return;
      final AudioSource source;
      // Apple's preview is already the catchy part: it plays from the start.
      var preview = file != null && SampleCache.isPreview(file);
      if (file != null) {
        source = AudioSource.file(file.path);
      } else if (await itunesPreviewFor(song)
              .timeout(const Duration(seconds: 6), onTimeout: () => null)
          case final url?) {
        if (token != _token) return;
        unawaited(SampleCache.fetch(song)); // ready for a replay
        source = AudioSource.uri(Uri.parse(url));
        preview = true;
      } else {
        unawaited(SampleCache.fetch(song)); // ready for a replay
        final url = await fetchSongStreamUrl(id, false);
        if (url == null || token != _token) return;
        final uri = Uri.parse(url);
        source = AudioSource.uri(
          uri,
          headers: uri.host.endsWith('googlevideo.com')
              ? streamPlaybackHeaders(id)
              : null,
        );
      }
      final duration = await _player.setAudioSource(source);
      if (token != _token) return;
      // Windows often reports no length on load: fall back to the catalog's.
      var total = duration ?? Duration.zero;
      if (total == Duration.zero && song['duration'] is num) {
        total = Duration(seconds: (song['duration'] as num).toInt());
      }
      // The chorus if the lyrics show it, otherwise the middle of the song.
      final chorus = preview
          ? null
          : await _chorusOf(song)
                .timeout(const Duration(seconds: 2), onTimeout: () => null);
      if (token != _token) return;
      final start = preview
          ? Duration.zero
          : chorus != null && (total == Duration.zero || chorus < total)
          ? chorus
          : total > const Duration(seconds: 40)
          ? total * 0.45
          : Duration.zero;
      await _player.setVolume(0);
      // Seek once playing: a seek before the first frame can be dropped.
      unawaited(_player.play());
      if (start > Duration.zero) {
        await _player.seek(start);
        for (var tries = 0; tries < 6 && token == _token; tries++) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          if (_player.position >= start - const Duration(seconds: 2)) break;
          await _player.seek(start);
        }
      }
      if (token != _token) return;
      if (mounted) setState(() => _sideLoading = false);
      await _fadeTo(1, _fadeIn, token);
      // Plays on (pauses don't count) until the sample is used up.
      var heard = _fadeIn;
      while (heard < _sample - _fadeOut && token == _token) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        if (!_paused) heard += const Duration(milliseconds: 200);
      }
      if (token != _token) return;
      await _fadeTo(0, _fadeOut, token);
      if (token != _token) return;
      await _player.pause();
    } catch (_) {
      // A song that won't play just skips its turn.
    } finally {
      if (token == _token && mounted) {
        setState(() {
          _side = null;
          _sideLoading = false;
          _paused = false;
        });
      }
    }
  }

  /// The button on a cover: pause what plays, carry on, or hear it again.
  void _coverButton(bool left) {
    if (_finished) return;
    if (_side == left && !_sideLoading) {
      if (_paused) {
        setState(() => _paused = false);
        unawaited(_player.play());
      } else {
        setState(() => _paused = true);
        unawaited(_player.pause());
      }
      return;
    }
    // Hear this side (again); the automatic turn order stops here.
    unawaited(_playSample(left, ++_token));
  }

  void _choose(bool left) {
    if (_finished || _results.containsKey(_round)) return;
    unawaited(HapticFeedback.mediumImpact());
    final a = _a[_round];
    final b = _b[_round];
    SongBattles.record(winner: left ? a : b, loser: left ? b : a);
    final token = ++_token;
    unawaited(
      _fadeTo(0, const Duration(milliseconds: 400), token).then((_) {
        if (token == _token) unawaited(_player.pause());
      }),
    );
    setState(() {
      _results[_round] = left;
      _side = null;
      _sideLoading = false;
    });
    Future.delayed(const Duration(milliseconds: 1200), () {
      if (!mounted || token != _token) return;
      setState(() => _round++);
      if (_round < _rounds) {
        unawaited(_player.setVolume(1));
        unawaited(_playRound());
      }
    });
  }

  void _scrollToRound() {
    const rowHeight = 64.0;
    for (final c in [_leftScroll, _rightScroll]) {
      if (!c.hasClients) continue;
      final target = (_round * rowHeight - rowHeight).clamp(
        0.0,
        c.position.maxScrollExtent,
      );
      unawaited(
        c.animateTo(
          target,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutCubic,
        ),
      );
    }
  }

  /// Album tracks often come without a picture of their own.
  Map _withCover(Map song, Map album) {
    if (_cover(song).isNotEmpty) return song;
    return {
      ...song,
      'image': album['image'],
      'highResImage': album['highResImage'] ?? album['image'],
      'lowResImage': album['lowResImage'] ?? album['image'],
    };
  }

  // -------------------------------------------------------------------------
  // Screen
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Album match')),
      body: SafeArea(
        top: false,
        child: _loadingAlbums
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  _top(scheme),
                  _status(scheme),
                  const SizedBox(height: 8),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: _trackList(scheme, true)),
                        const SizedBox(width: 8),
                        Expanded(child: _trackList(scheme, false)),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  /// The two covers (the current round's songs) with their play buttons,
  /// and the score in between.
  Widget _top(ColorScheme scheme) {
    Widget side(bool left) {
      final album = left ? widget.left : widget.right;
      final tracks = left ? _a : _b;
      final song = _round < tracks.length ? tracks[_round] : album;
      final active = _side == left;
      final icon = active && !_paused
          ? Icons.pause_rounded
          : Icons.play_arrow_rounded;
      return Expanded(
        child: Column(
          children: [
            GestureDetector(
              onTap: () => _coverButton(left),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: active ? scheme.onSurface : Colors.transparent,
                        width: 2.5,
                      ),
                    ),
                    padding: const EdgeInsets.all(3),
                    child: _coverBox(song, 120, scheme),
                  ),
                  if (!_finished)
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        shape: BoxShape.circle,
                      ),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 250),
                        transitionBuilder: (child, a) => FadeTransition(
                          opacity: a,
                          child: ScaleTransition(scale: a, child: child),
                        ),
                        child: active && _sideLoading
                            ? const Padding(
                                key: ValueKey('loading'),
                                padding: EdgeInsets.all(14),
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  color: Colors.white,
                                ),
                              )
                            : Icon(
                                icon,
                                key: ValueKey(icon),
                                color: Colors.white,
                                size: 32,
                              ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '${album['title'] ?? ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: muzikaBody(14, weight: 700, color: scheme.onSurface),
            ),
            Text(
              '${album['artist'] ?? ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: muzikaBody(12, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          side(true),
          Padding(
            padding: const EdgeInsets.only(top: 50),
            child: Text(
              '$_leftScore – $_rightScore',
              style: muzikaHeading(24, color: scheme.onSurface),
            ),
          ),
          side(false),
        ],
      ),
    );
  }

  Widget _status(ColorScheme scheme) {
    if (_rounds == 0) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'Couldn’t load the songs of these albums.',
          style: muzikaBody(15, color: scheme.onSurfaceVariant),
        ),
      );
    }
    if (_finished) {
      final text = _leftScore == _rightScore
          ? 'It’s a draw'
          : '${(_leftScore > _rightScore ? widget.left : widget.right)['title']} wins';
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            Expanded(
              child: Text(
                text,
                maxLines: 2,
                style: muzikaHeading(20, color: scheme.onSurface),
              ),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Done'),
            ),
          ],
        ),
      );
    }
    return Text(
      'Round ${_round + 1} of $_rounds · tap the song you like more',
      style: muzikaBody(13, color: scheme.onSurfaceVariant),
    );
  }

  /// One album's songs. The current round's song is outlined (strongly
  /// while it plays), winners are green, losers fade.
  Widget _trackList(ColorScheme scheme, bool left) {
    final tracks = left ? _a : _b;
    return ListView.builder(
      controller: left ? _leftScroll : _rightScroll,
      padding: EdgeInsets.fromLTRB(left ? 12 : 0, 4, left ? 0 : 12, 24),
      itemCount: tracks.length,
      itemExtent: 64,
      itemBuilder: (context, i) {
        final result = _results[i];
        final won = result != null && result == left;
        final lost = result != null && result != left;
        final current = i == _round && !_finished && result == null;
        final playing = current && _side == left;
        final inMatch = i < _rounds;
        final Color border;
        final double width;
        if (won) {
          border = const Color(0xFF43A047);
          width = 2;
        } else if (playing) {
          border = scheme.onSurface;
          width = 2;
        } else if (current) {
          border = scheme.outline;
          width = 1.2;
        } else {
          border = Colors.transparent;
          width = 1;
        }
        return AnimatedOpacity(
          duration: const Duration(milliseconds: 300),
          opacity: lost || !inMatch ? 0.35 : 1,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              decoration: BoxDecoration(
                color: won
                    ? const Color(0xFF43A047).withValues(alpha: 0.18)
                    : current
                    ? scheme.surfaceContainerHigh
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: border, width: width),
              ),
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: current ? () => _choose(left) : null,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 22,
                          child: won
                              ? const Icon(
                                  Icons.check_rounded,
                                  size: 18,
                                  color: Color(0xFF43A047),
                                )
                              : playing
                              ? Icon(
                                  Icons.graphic_eq_rounded,
                                  size: 18,
                                  color: scheme.onSurface,
                                )
                              : Text(
                                  '${i + 1}',
                                  style: muzikaBody(
                                    13,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '${tracks[i]['title'] ?? ''}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: muzikaBody(
                              14,
                              weight: current || won ? 700 : 500,
                              color: scheme.onSurface,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
