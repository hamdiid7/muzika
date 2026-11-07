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
import 'dart:math';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muzika/constants/clients.dart'
    show registerSongHintFrom, streamPlaybackHeaders;
import 'package:muzika/main.dart' show audioHandler;
import 'package:muzika/services/common_services.dart';
import 'package:muzika/services/desktop_panels.dart';
import 'package:muzika/services/synced_lyrics.dart';
import 'package:muzika/theme/muzika_tokens.dart';

/// Opens the lyrics game with [songs] (an artist's top songs).
Future<void> openLyricsGame(BuildContext context, List<Map> songs) {
  return Navigator.of(
    context,
    rootNavigator: !desktopPanels.value,
  ).push(MaterialPageRoute<void>(builder: (_) => LyricsGamePage(songs: songs)));
}

/// The last sound of a line, for rhymes: the final syllable of an Amharic
/// line (each Ethiopic letter is one), the last two letters otherwise.
String rhymeKey(String line) {
  final words = line
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}\s]', unicode: true), '')
      .trim()
      .split(RegExp(r'\s+'));
  final last = words.isEmpty ? '' : words.last;
  if (last.isEmpty) return '';
  final runes = last.runes.toList();
  final isEthiopic = runes.last >= 0x1200 && runes.last <= 0x139F;
  final take = isEthiopic ? 1 : min(2, runes.length);
  return String.fromCharCodes(runes.sublist(runes.length - take));
}

/// A line left blank: its words in order, a bank of tiles (those words
/// and a few from elsewhere in the song, shuffled), and the tiles placed so
/// far.
class _Blank {
  _Blank(this.words, this.bank);

  final List<String> words;
  final List<String> bank;

  /// Indexes into [bank], in the order they were tapped.
  final placed = <int>[];

  /// Set once every slot is filled.
  bool? right;

  bool get answered => right != null;
}

/// Sing along: the song plays from start to finish with its lyrics on
/// screen, a handful of lines left blank. Before each blank it stops and
/// the line is built word by word from a bank of tiles, Duolingo style.
/// Once full it checks itself (green, or red with the real line) and the
/// song carries on.
class LyricsGamePage extends StatefulWidget {
  const LyricsGamePage({super.key, required this.songs});

  final List<Map> songs;

  @override
  State<LyricsGamePage> createState() => _LyricsGamePageState();
}

class _LyricsGamePageState extends State<LyricsGamePage> {
  final _player = AudioPlayer();
  final _subs = <StreamSubscription<Object?>>[];
  final _random = Random();
  final _scroll = ScrollController();
  final _lineKeys = <GlobalKey>[];

  int _songIndex = -1;
  Map? _song;
  List<LyricLine> _lines = const [];
  Map<int, _Blank> _blanks = const {};

  /// The line being sung, and the blank waiting for an answer (if any).
  int _currentLine = -1;
  int? _asking;
  bool _loading = true;
  bool _finished = false;
  bool _resumeMain = false;

  @override
  void initState() {
    super.initState();
    // The game has the speakers to itself; the song paused here resumes
    // when it closes.
    _resumeMain = audioHandler.playbackState.valueOrNull?.playing ?? false;
    if (_resumeMain) unawaited(audioHandler.pause());
    _subs
      ..add(_player.positionStream.listen(_onPosition))
      ..add(
        _player.processingStateStream.listen((state) {
          if (state == ProcessingState.completed && !_loading) {
            unawaited(_nextSong());
          }
        }),
      );
    unawaited(_nextSong());
  }

  @override
  void dispose() {
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    unawaited(_player.dispose());
    _scroll.dispose();
    if (_resumeMain) unawaited(audioHandler.play());
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Songs
  // -------------------------------------------------------------------------

  /// Finds the next song with time-synced lyrics and plays it from the top.
  Future<void> _nextSong() async {
    setState(() {
      _loading = true;
      _asking = null;
      _currentLine = -1;
    });
    await _player.stop();
    while (++_songIndex < widget.songs.length) {
      final song = widget.songs[_songIndex];
      final lyrics = await fetchSongLyrics(
        artist: '${song['artist'] ?? ''}',
        title: '${song['title'] ?? ''}',
        videoId: '${song['ytid'] ?? ''}',
        duration: song['duration'] is num
            ? Duration(seconds: (song['duration'] as num).toInt())
            : null,
      ).catchError((_) => null);
      final lines = (lyrics?.lines ?? const <LyricLine>[])
          .where((l) => l.text.trim().isNotEmpty)
          .toList();
      final blanks = _makeBlanks(lines);
      if (blanks.isEmpty) continue;
      final id = '${song['ytid']}';
      registerSongHintFrom(song);
      final url = await fetchSongStreamUrl(id, false);
      if (url == null || !mounted) continue;
      try {
        final uri = Uri.parse(url);
        await _player.setAudioSource(
          AudioSource.uri(
            uri,
            headers: uri.host.endsWith('googlevideo.com')
                ? streamPlaybackHeaders(id)
                : null,
          ),
        );
      } catch (_) {
        continue;
      }
      if (!mounted) return;
      _lineKeys
        ..clear()
        ..addAll(List.generate(lines.length, (_) => GlobalKey()));
      setState(() {
        _song = song;
        _lines = lines;
        _blanks = blanks;
        _loading = false;
      });
      if (_scroll.hasClients) _scroll.jumpTo(0);
      unawaited(_player.play());
      return;
    }
    if (mounted) {
      setState(() {
        _loading = false;
        _finished = true;
      });
    }
  }

  static List<String> _words(String line) =>
      line.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();

  /// Up to fifteen blanks spread through the song (fewer in short ones),
  /// never two in a row. Each line's tiles are its own words plus up to
  /// three words from other lines, so it takes listening to get right.
  Map<int, _Blank> _makeBlanks(List<LyricLine> lines) {
    if (lines.length < 6) return const {};
    final texts = [for (final l in lines) l.text.trim()];
    final count = min(15, max(2, lines.length ~/ 3));
    final out = <int, _Blank>{};
    final step = (lines.length - 2) / count;
    for (var n = 0; n < count; n++) {
      final i = min(lines.length - 1, 2 + (n * step).round());
      if (out.containsKey(i) || out.containsKey(i - 1)) continue;
      final words = _words(texts[i]);
      if (words.length < 2) continue;
      final own = words.toSet();
      final extra = {
        for (final t in texts)
          for (final w in _words(t))
            if (!own.contains(w)) w,
      }.toList()..shuffle(_random);
      final bank = [...words, ...extra.take(min(3, words.length))]
        ..shuffle(_random);
      out[i] = _Blank(words, bank);
    }
    return out;
  }

  // -------------------------------------------------------------------------
  // Playing along
  // -------------------------------------------------------------------------

  void _onPosition(Duration position) {
    if (_loading || _asking != null || _lines.isEmpty) return;
    // Stop just before an unanswered blank.
    for (final entry in _blanks.entries) {
      if (entry.value.answered) continue;
      final at = _lines[entry.key].time - const Duration(milliseconds: 200);
      if (position >= at && position < _lines[entry.key].time + _gap) {
        unawaited(_player.pause());
        unawaited(HapticFeedback.mediumImpact());
        setState(() {
          _asking = entry.key;
          _currentLine = entry.key;
        });
        _scrollTo(entry.key);
        return;
      }
    }
    var line = -1;
    for (var i = 0; i < _lines.length; i++) {
      if (_lines[i].time <= position) line = i;
    }
    if (line != _currentLine) {
      setState(() => _currentLine = line);
      if (line >= 0) _scrollTo(line);
    }
  }

  static const _gap = Duration(seconds: 2);

  void _scrollTo(int index) {
    final context = _lineKeys[index].currentContext;
    if (context == null) return;
    unawaited(
      Scrollable.ensureVisible(
        context,
        alignment: 0.35,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  /// Plays from line [index]. Tapping a blank asks it right away; blanks
  /// jumped past stay blank until the song comes back to them.
  void _jumpTo(int index) {
    unawaited(HapticFeedback.selectionClick());
    setState(() {
      _asking = null;
      _currentLine = index;
    });
    final at = _lines[index].time;
    unawaited(_player.seek(at).then((_) => _player.play()));
  }

  /// Puts bank tile [tile] into the next empty slot; a full line checks
  /// itself.
  void _place(int tile) {
    final index = _asking;
    if (index == null) return;
    final blank = _blanks[index]!;
    if (blank.answered || blank.placed.contains(tile)) return;
    unawaited(HapticFeedback.selectionClick());
    setState(() => blank.placed.add(tile));
    if (blank.placed.length < blank.words.length) return;

    final built = [for (final t in blank.placed) blank.bank[t]].join(' ');
    final right = built == blank.words.join(' ');
    unawaited(
      right ? HapticFeedback.lightImpact() : HapticFeedback.heavyImpact(),
    );
    setState(() => blank.right = right);
    // A moment to see the answer (longer to read the right line), then the
    // song goes on.
    Future.delayed(Duration(milliseconds: right ? 1000 : 2200), () {
      if (!mounted || _asking != index) return;
      setState(() => _asking = null);
      unawaited(_player.play());
    });
  }

  /// Sends a placed word back to the bank.
  void _unplace(int slot) {
    final index = _asking;
    if (index == null) return;
    final blank = _blanks[index]!;
    if (blank.answered || slot >= blank.placed.length) return;
    unawaited(HapticFeedback.selectionClick());
    setState(() => blank.placed.removeAt(slot));
  }

  // -------------------------------------------------------------------------
  // Screen
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Guess the lyrics')),
      body: SafeArea(
        top: false,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _finished
            ? _finishedView(scheme)
            : Column(
                children: [
                  _header(scheme),
                  Expanded(child: _lyrics(scheme)),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    child: _asking == null
                        ? const SizedBox(width: double.infinity)
                        : _choices(scheme, _asking!),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _header(ColorScheme scheme) {
    final song = _song!;
    final image = [song['highResImage'], song['image'], song['lowResImage']]
        .map((e) => '${e ?? ''}')
        .firstWhere((e) => e.startsWith('http'), orElse: () => '');
    final hasNext = _songIndex + 1 < widget.songs.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 12, 12),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: 64,
              height: 64,
              child: image.isEmpty
                  ? ColoredBox(color: scheme.surfaceContainerHigh)
                  : Image(
                      image: CachedNetworkImageProvider(image),
                      fit: BoxFit.cover,
                    ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${song['title'] ?? ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: muzikaHeading(20, color: scheme.onSurface),
                ),
                const SizedBox(height: 2),
                Text(
                  '${song['artist'] ?? ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: muzikaBody(14, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          if (hasNext)
            IconButton(
              tooltip: 'Next song',
              icon: const Icon(Icons.skip_next_rounded, size: 30),
              onPressed: () => unawaited(_nextSong()),
            ),
        ],
      ),
    );
  }

  Widget _lyrics(ColorScheme scheme) {
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 160),
      itemCount: _lines.length,
      itemBuilder: (context, i) {
        final blank = _blanks[i];
        final sung = i < _currentLine;
        final current = i == _currentLine;
        final base = muzikaHeading(
          22,
          color: current
              ? scheme.onSurface
              : scheme.onSurfaceVariant.withValues(alpha: sung ? 0.55 : 0.8),
        ).copyWith(height: 1.3);

        Widget child;
        if (blank == null) {
          child = Text(_lines[i].text.trim(), style: base);
        } else if (!blank.answered) {
          // A gap the width of a line, until it is answered.
          child = Container(
            height: 30,
            margin: const EdgeInsets.symmetric(vertical: 2),
            decoration: BoxDecoration(
              color: current
                  ? scheme.onSurface.withValues(alpha: 0.18)
                  : scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(8),
            ),
          );
        } else {
          final right = blank.right!;
          child = Text(
            _lines[i].text.trim(),
            style: base.copyWith(
              color: right ? const Color(0xFF43A047) : const Color(0xFFE53935),
            ),
          );
        }
        // Tap a line to jump there.
        return GestureDetector(
          key: _lineKeys[i],
          behavior: HitTestBehavior.opaque,
          onTap: () => _jumpTo(i),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: child,
          ),
        );
      },
    );
  }

  /// The line being built (placed words, empty slots) above the bank of
  /// tiles; used tiles leave a grey gap where they were.
  Widget _choices(ColorScheme scheme, int index) {
    final blank = _blanks[index]!;
    const green = Color(0xFF2E7D32);
    const red = Color(0xFFC62828);

    Widget tile(
      String word, {
      VoidCallback? onTap,
      bool used = false,
      Color? fill,
      Color? ink,
    }) {
      return Padding(
        padding: const EdgeInsets.all(4),
        child: Material(
          color: used ? scheme.surfaceContainerHighest : fill ?? scheme.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: used ? Colors.transparent : scheme.outlineVariant,
              width: 1.5,
            ),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              // A used tile keeps its size, with the word hidden.
              child: Opacity(
                opacity: used ? 0 : 1,
                child: Text(
                  word,
                  style: muzikaBody(
                    16,
                    weight: 600,
                    color: ink ?? scheme.onSurface,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    final slotColor = blank.right == null
        ? null
        : blank.right!
        ? green
        : red;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The line being built, on a ruled area like Duolingo's.
          Container(
            constraints: const BoxConstraints(minHeight: 58),
            width: double.infinity,
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
            ),
            child: Wrap(
              children: [
                for (final (slot, t) in blank.placed.indexed)
                  tile(
                    blank.bank[t],
                    onTap: () => _unplace(slot),
                    fill: slotColor,
                    ink: slotColor == null ? null : Colors.white,
                  ),
              ],
            ),
          ),
          if (blank.right == false) ...[
            const SizedBox(height: 10),
            Text(
              blank.words.join(' '),
              style: muzikaBody(
                16,
                weight: 700,
                color: const Color(0xFF43A047),
              ),
            ),
          ],
          const SizedBox(height: 14),
          Center(
            child: Wrap(
              alignment: WrapAlignment.center,
              children: [
                for (final (t, word) in blank.bank.indexed)
                  tile(
                    word,
                    used: blank.placed.contains(t),
                    onTap: blank.placed.contains(t) || blank.answered
                        ? null
                        : () => _place(t),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget _finishedView(ColorScheme scheme) {
    final asked = _blanks.values.where((b) => b.answered).length;
    final right = _blanks.values.where((b) => b.right ?? false).length;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _song == null
                  ? 'No synced lyrics for this song yet.'
                  : asked == 0
                  ? 'Song finished'
                  : '$right of $asked lines right',
              textAlign: TextAlign.center,
              style: muzikaHeading(24, color: scheme.onSurface),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 12,
              children: [
                if (_song != null)
                  OutlinedButton(
                    onPressed: () {
                      setState(() {
                        _finished = false;
                        _songIndex = -1;
                      });
                      unawaited(_nextSong());
                    },
                    child: const Text('Play again'),
                  ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Done'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
