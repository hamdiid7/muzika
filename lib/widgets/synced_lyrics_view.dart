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

import 'package:audio_service/audio_service.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:material_ui/material_ui.dart';
import 'package:muzika/main.dart' show audioHandler;
import 'package:muzika/models/position_data.dart';
import 'package:muzika/services/synced_lyrics.dart';
import 'package:muzika/theme/muzika_tokens.dart';
import 'package:muzika/utilities/flutter_toast.dart';
import 'package:muzika/widgets/muzika_shimmer.dart';

/// Lyrics for the playing song. Synced lyrics follow playback: the current
/// line is highlighted and kept in view, and tapping a line seeks to it.
/// The lyrics page's ✏️ (beside Share): each tap asks the lyrics showing
/// to be timed by hand.
final lyricsEditRequests = ValueNotifier<int>(0);

class SyncedLyricsView extends StatefulWidget {
  const SyncedLyricsView({
    super.key,
    required this.metadata,
    this.fontSize = 22,
    this.padding = const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
    this.editButton = true,
  });

  final MediaItem metadata;
  final double fontSize;
  final EdgeInsets padding;

  /// A ✏️ over the lyrics themselves; off where the page has its own
  /// ([lyricsEditRequests]).
  final bool editButton;

  @override
  State<SyncedLyricsView> createState() => _SyncedLyricsViewState();
}

class _SyncedLyricsViewState extends State<SyncedLyricsView> {
  String? _key;
  late Future<SongLyrics?> _future;

  /// The lyrics showing, for the page's ✏️.
  SongLyrics? _shown;

  @override
  void initState() {
    super.initState();
    _load();
    lyricsEditRequests.addListener(_editRequested);
    lyricsRefreshed.addListener(_reload);
  }

  @override
  void dispose() {
    lyricsEditRequests.removeListener(_editRequested);
    lyricsRefreshed.removeListener(_reload);
    super.dispose();
  }

  /// Better lyrics came in behind the plain ones showing: load again.
  void _reload() {
    if (!mounted || _editTexts != null || _shifting) return;
    setState(() {
      _key = null;
      _load();
    });
  }

  void _editRequested() {
    final lyrics = _shown;
    if (lyrics != null && mounted) _startEditing(lyrics);
  }

  @override
  void didUpdateWidget(SyncedLyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _load();
  }

  void _load() {
    final m = widget.metadata;
    final key = '${m.artist}|${m.title}';
    if (key == _key) return;
    _key = key;
    _future = fetchSongLyrics(
      artist: m.artist ?? '',
      title: m.title,
      album: m.album,
      duration: m.duration,
      videoId: m.extras?['ytid']?.toString(),
    );
  }

  /// Timing the lyrics by hand: each line as it's touched.
  List<String>? _editTexts;
  List<Duration?> _editTimes = const [];

  /// Saved timing goes to LRCLIB too, for everyone (and every app using
  /// it); a toast says when it's there.
  void _publish(SongLyrics saved) {
    final m = widget.metadata;
    showToast(
      context,
      'Saved. Sharing the timing on LRCLIB…',
      icon: FluentIcons.cloud_arrow_up_20_regular,
    );
    unawaited(
      publishToLrclib(
        artist: m.artist ?? '',
        title: m.title,
        album: m.album,
        duration: m.duration,
        lines: saved.lines ?? const [],
      ).then((ok) {
        if (!mounted) return;
        showToast(
          context,
          ok
              ? 'Shared on LRCLIB: everyone gets these lyrics now'
              : "Saved here; LRCLIB didn't take it this time",
          icon: ok ? null : FluentIcons.warning_20_regular,
        );
      }),
    );
  }

  /// Synced lyrics that run early or late: the line heard now is touched,
  /// and every line moves by the same amount.
  bool _shifting = false;

  /// No lyrics anywhere: the user pastes the words, then times them line
  /// by line from the start (saved, and shared on LRCLIB).
  Future<void> _addLyrics() async {
    final controller = TextEditingController();
    final words = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Add lyrics'),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: controller,
            autofocus: true,
            maxLines: 12,
            minLines: 6,
            decoration: const InputDecoration(
              hintText: 'Paste the words, one line per line of the song',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialog).pop(controller.text),
            child: const Text('Time them'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || words == null || words.trim().isEmpty) return;
    _startEditing(SongLyrics(plain: words.trim(), source: 'you'));
  }

  void _startEditing(SongLyrics lyrics) {
    if (lyrics.isSynced) {
      setState(() => _shifting = true);
      return;
    }
    // Plain lyrics: every line untimed until touched, from the song's
    // start.
    setState(() {
      _editTexts = [
        for (final l in (lyrics.plain ?? '').split('\n'))
          if (l.trim().isNotEmpty) l.trim(),
      ];
      _editTimes = List.filled(_editTexts!.length, null);
    });
    unawaited(audioHandler.seek(Duration.zero));
    unawaited(audioHandler.play());
  }

  /// Moves every line (and word) so line [index] falls on now.
  Future<void> _shiftTo(SongLyrics lyrics, int index) async {
    final lines = lyrics.lines!;
    var now =
        audioHandler.playbackState.value.position - _SyncEditorState._reaction;
    if (now.isNegative) now = Duration.zero;
    final by = now - lines[index].time;
    Duration moved(Duration t) {
      final m = t + by;
      return m.isNegative ? Duration.zero : m;
    }

    final m = widget.metadata;
    final saved = await saveTimedLyrics(
      artist: m.artist ?? '',
      title: m.title,
      lines: [
        for (final l in lines)
          LyricLine(
            moved(l.time),
            l.text,
            words: l.words == null
                ? null
                : [for (final w in l.words!) LyricWord(moved(w.time), w.text)],
          ),
      ],
      plain: lyrics.plain,
    );
    if (!mounted) return;
    setState(() {
      _shifting = false;
      _future = Future.value(saved);
    });
    _publish(saved);
  }

  Future<void> _saveEditing(SongLyrics? lyrics) async {
    final texts = _editTexts;
    if (texts == null) return;
    // Untouched lines (plain lyrics) fall between their neighbours.
    final times = [..._editTimes];
    for (var i = 0; i < times.length; i++) {
      if (times[i] != null) continue;
      final before = i > 0 ? times[i - 1] : Duration.zero;
      var j = i + 1;
      while (j < times.length && times[j] == null) {
        j++;
      }
      final after = j < times.length
          ? times[j]!
          : (before ?? Duration.zero) + const Duration(seconds: 4);
      times[i] =
          (before ?? Duration.zero) +
          (after - (before ?? Duration.zero)) * (1 / (j - i + 1));
    }
    final m = widget.metadata;
    final saved = await saveTimedLyrics(
      artist: m.artist ?? '',
      title: m.title,
      lines: [
        for (var i = 0; i < texts.length; i++) LyricLine(times[i]!, texts[i]),
      ],
      // Pasted ones have no plain text of their own: the lines are it.
      plain: lyrics?.plain ?? texts.join('\n'),
    );
    if (!mounted) return;
    setState(() {
      _editTexts = null;
      _future = Future.value(saved);
    });
    _publish(saved);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<SongLyrics?>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const _LyricsSkeleton();
        }
        final lyrics = snapshot.data;
        _shown = lyrics;
        if (_shifting && lyrics != null && lyrics.isSynced) {
          return _ShiftPicker(
            lines: lyrics.lines!,
            fontSize: widget.fontSize,
            padding: widget.padding,
            onPick: (i) => unawaited(_shiftTo(lyrics, i)),
            onCancel: () => setState(() => _shifting = false),
          );
        }
        final texts = _editTexts;
        if (texts != null) {
          return _SyncEditor(
            texts: texts,
            times: _editTimes,
            fontSize: widget.fontSize,
            padding: widget.padding,
            onTime: (i, t) => setState(() => _editTimes[i] = t),
            onCancel: () => setState(() => _editTexts = null),
            onSave: () => unawaited(_saveEditing(lyrics)),
          );
        }
        if (lyrics == null) {
          return _Unavailable(
            scheme: scheme,
            onAdd: () => unawaited(_addLyrics()),
          );
        }
        // ✏️ at the top: time the lyrics by touching each line.
        Widget withEdit(Widget child) => !widget.editButton
            ? child
            : Stack(
                children: [
                  Positioned.fill(child: child),
                  // Left of where the lyrics panel's ✕ sits.
                  Positioned(
                    top: 4,
                    right: 60,
                    child: IconButton(
                      tooltip: 'Touch each line when you hear it',
                      icon: Icon(
                        FluentIcons.edit_24_regular,
                        color: scheme.onSurfaceVariant,
                      ),
                      onPressed: () => _startEditing(lyrics),
                    ),
                  ),
                ],
              );
        if (lyrics.isSynced) {
          return withEdit(
            _SyncedLines(
              lines: lyrics.lines!,
              source: lyrics.source,
              // Word by word only with real word times, and never for
              // LRCLIB's.
              wordByWord: lyrics.hasWordTimes && lyrics.source != 'LRCLIB',
              fontSize: widget.fontSize,
              padding: widget.padding,
            ),
          );
        }
        return withEdit(
          SingleChildScrollView(
            padding: widget.padding,
            child: Column(
              children: [
                Text(
                  lyrics.plain ?? '',
                  textAlign: TextAlign.center,
                  style: muzikaBody(
                    widget.fontSize * 0.8,
                    weight: 500,
                    color: scheme.onSurface,
                  ).copyWith(height: 1.6),
                ),
                _SourceLabel(source: lyrics.source, synced: false),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Timing lyrics by hand: the song plays on, and touching a line sets it to
/// that moment (a beat earlier, for the reaction). The line to touch next
/// is lit; Save keeps the timing for this song.
class _SyncEditor extends StatefulWidget {
  const _SyncEditor({
    required this.texts,
    required this.times,
    required this.fontSize,
    required this.padding,
    required this.onTime,
    required this.onCancel,
    required this.onSave,
  });

  final List<String> texts;
  final List<Duration?> times;
  final double fontSize;
  final EdgeInsets padding;
  final void Function(int index, Duration time) onTime;
  final VoidCallback onCancel;
  final VoidCallback onSave;

  @override
  State<_SyncEditor> createState() => _SyncEditorState();
}

class _SyncEditorState extends State<_SyncEditor> {
  /// The line to touch next.
  int _next = 0;
  late final List<GlobalKey> _keys = List.generate(
    widget.texts.length,
    (_) => GlobalKey(),
  );

  static const _reaction = Duration(milliseconds: 300);

  String _clock(Duration? t) {
    if (t == null) return '–:––';
    final s = t.inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  void _touch(int i) {
    final now = audioHandler.playbackState.value.position - _reaction;
    widget.onTime(i, now.isNegative ? Duration.zero : now);
    setState(() => _next = i + 1);
    final ctx = i + 1 < _keys.length ? _keys[i + 1].currentContext : null;
    if (ctx != null) {
      unawaited(
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.4,
          duration: const Duration(milliseconds: 250),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Material(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
            child: Row(
              children: [
                Icon(FluentIcons.hand_left_24_regular, color: scheme.onSurface),
                const SizedBox(width: 10),
                Expanded(
                  child: StreamBuilder<PositionData>(
                    stream: audioHandler.positionDataStream,
                    builder: (context, snapshot) => Text(
                      'Touch each line when you hear it  ·  '
                      '${_clock(snapshot.data?.position)}',
                      style: muzikaBody(
                        13.5,
                        weight: 600,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                ),
                TextButton(
                  onPressed: widget.onCancel,
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: widget.onSave,
                  child: const Text('Save'),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: widget.padding,
            scrollCacheExtent: const ScrollCacheExtent.pixels(100000),
            itemCount: widget.texts.length,
            itemBuilder: (context, i) {
              final isNext = i == _next;
              final time = widget.times[i];
              return InkWell(
                key: _keys[i],
                borderRadius: BorderRadius.circular(10),
                onTap: () => _touch(i),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    vertical: 8,
                    horizontal: 8,
                  ),
                  decoration: isNext
                      ? BoxDecoration(
                          color: scheme.onSurface.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(10),
                        )
                      : null,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 48,
                        child: Text(
                          _clock(time),
                          style: muzikaBody(12, color: scheme.onSurfaceVariant),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          widget.texts[i].isEmpty ? '♪' : widget.texts[i],
                          style: muzikaHeading(
                            widget.fontSize * 0.85,
                            weight: isNext ? 700 : 600,
                            color: isNext
                                ? scheme.onSurface
                                : scheme.onSurface.withValues(
                                    alpha: i < _next ? 0.45 : 0.6,
                                  ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _SyncedLines extends StatefulWidget {
  const _SyncedLines({
    required this.lines,
    required this.source,
    required this.wordByWord,
    required this.fontSize,
    required this.padding,
  });

  final List<LyricLine> lines;
  final String source;

  /// The line being sung lit word by word (else the whole line at once).
  final bool wordByWord;
  final double fontSize;
  final EdgeInsets padding;

  @override
  State<_SyncedLines> createState() => _SyncedLinesState();
}

class _SyncedLinesState extends State<_SyncedLines> {
  late final List<GlobalKey> _keys = List.generate(
    widget.lines.length,
    (_) => GlobalKey(),
  );
  StreamSubscription<PositionData>? _sub;
  int _current = -1;

  /// Pauses auto-scroll for a few seconds after the user scrolls by hand.
  DateTime _userScrolledAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _sub = audioHandler.positionDataStream.listen(
      (p) => _onPosition(p.position),
    );
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  int _indexAt(Duration position) {
    // Lines appear slightly early so the eye catches up with the voice.
    final t = position + const Duration(milliseconds: 250);
    var lo = 0;
    var hi = widget.lines.length - 1;
    var ans = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (widget.lines[mid].time <= t) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }

  void _onPosition(Duration position) {
    final i = _indexAt(position);
    if (i == _current || !mounted) return;
    setState(() => _current = i);
    if (DateTime.now().difference(_userScrolledAt).inSeconds < 4) return;
    final ctx = i >= 0 ? _keys[i].currentContext : null;
    if (ctx != null) {
      unawaited(
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.35,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutCubic,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return NotificationListener<UserScrollNotification>(
      onNotification: (_) {
        _userScrolledAt = DateTime.now();
        return false;
      },
      child: ListView.builder(
        padding: widget.padding,
        // Build every line so ensureVisible can find far-away ones.
        scrollCacheExtent: const ScrollCacheExtent.pixels(100000),
        itemCount: widget.lines.length + 1,
        itemBuilder: (context, i) {
          if (i == widget.lines.length) {
            return _SourceLabel(source: widget.source, synced: true);
          }
          final line = widget.lines[i];
          final isCurrent = i == _current;
          final isPast = i < _current;
          final text = line.text.isEmpty ? '♪' : line.text;
          return InkWell(
            key: _keys[i],
            borderRadius: BorderRadius.circular(8),
            onTap: () {
              _userScrolledAt = DateTime.fromMillisecondsSinceEpoch(0);
              unawaited(audioHandler.seek(line.time));
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
              child: AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 250),
                style: muzikaHeading(
                  widget.fontSize,
                  weight: isCurrent ? 700 : 600,
                  color: isCurrent
                      ? scheme.onSurface
                      : scheme.onSurface.withValues(
                          alpha: isPast ? 0.28 : 0.42,
                        ),
                ).copyWith(height: 1.3),
                child: isCurrent && widget.wordByWord
                    ? _SungLine(
                        line: line,
                        next: i + 1 < widget.lines.length
                            ? widget.lines[i + 1].time
                            : null,
                        dim: scheme.onSurface.withValues(alpha: 0.42),
                      )
                    : Text(text),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The line being sung, lit up word by word: with LRCLIB's word times when
/// the lyrics have them, else spread over the line by the words' length.
/// The position runs on between player updates, so the light moves smoothly.
class _SungLine extends StatefulWidget {
  const _SungLine({required this.line, required this.next, required this.dim});

  final LyricLine line;
  final Duration? next;
  final Color dim;

  @override
  State<_SungLine> createState() => _SungLineState();
}

class _SungLineState extends State<_SungLine>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  StreamSubscription<PositionData>? _sub;
  Duration _known = Duration.zero;
  DateTime _knownAt = DateTime.now();
  late List<LyricWord> _words;
  late List<Duration> _ends;

  @override
  void initState() {
    super.initState();
    _plan();
    _known = audioHandler.playbackState.value.position;
    _sub = audioHandler.positionDataStream.listen((p) {
      _known = p.position;
      _knownAt = DateTime.now();
    });
    _ticker = createTicker((_) => setState(() {}))..start();
  }

  @override
  void didUpdateWidget(covariant _SungLine old) {
    super.didUpdateWidget(old);
    if (!identical(old.line, widget.line)) _plan();
  }

  /// Each word's start and end. Without word times, the line is sung over
  /// about 80 ms a letter, never past the next line.
  void _plan() {
    final line = widget.line;
    final real = line.words;
    final gap =
        (widget.next ?? line.time + const Duration(seconds: 5)) - line.time;
    if (real != null && real.isNotEmpty) {
      _words = real;
      final last = real.last;
      _ends = [
        for (var i = 1; i < real.length; i++) real[i].time,
        last.time +
            Duration(
              milliseconds: (last.text.trim().length * 90).clamp(250, 900),
            ),
      ];
      return;
    }
    final parts = RegExp(r'\S+\s*').allMatches(line.text).map((m) => m[0]!);
    final letters = parts.fold<int>(0, (n, w) => n + w.trim().length);
    var span = Duration(milliseconds: letters * 80);
    if (span < const Duration(milliseconds: 600)) {
      span = const Duration(milliseconds: 600);
    }
    if (gap > Duration.zero && span > gap * 0.92) span = gap * 0.92;
    _words = [];
    _ends = [];
    var done = 0;
    for (final w in parts) {
      final start = line.time + span * (done / (letters == 0 ? 1 : letters));
      done += w.trim().length;
      _words.add(LyricWord(start, w));
      _ends.add(line.time + span * (done / (letters == 0 ? 1 : letters)));
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    unawaited(_sub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style;
    final lit = style.color ?? Colors.white;
    final playing = audioHandler.playbackState.value.playing;
    final now =
        _known +
        (playing ? DateTime.now().difference(_knownAt) : Duration.zero) +
        const Duration(milliseconds: 120);
    return Text.rich(
      TextSpan(
        children: [
          for (var i = 0; i < _words.length; i++)
            TextSpan(
              text: _words[i].text,
              style: TextStyle(
                color: Color.lerp(
                  widget.dim,
                  lit,
                  _progress(now, _words[i].time, _ends[i]),
                ),
              ),
            ),
        ],
      ),
    );
  }

  double _progress(Duration now, Duration start, Duration end) {
    if (now <= start) return 0;
    if (now >= end) return 1;
    final t =
        (now - start).inMicroseconds /
        (end - start).inMicroseconds.clamp(1, 1 << 40);
    return Curves.easeOut.transform(t.clamp(0.0, 1.0));
  }
}

class _SourceLabel extends StatelessWidget {
  const _SourceLabel({required this.source, required this.synced});

  final String source;
  final bool synced;

  @override
  Widget build(BuildContext context) {
    if (source.isEmpty) return const SizedBox(height: 24);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 28, bottom: 12),
      child: Text(
        synced ? 'Synced lyrics by $source' : 'Lyrics by $source',
        textAlign: TextAlign.center,
        style: muzikaBody(12, color: scheme.onSurfaceVariant),
      ),
    );
  }
}

class _Unavailable extends StatelessWidget {
  const _Unavailable({required this.scheme, this.onAdd});

  final ColorScheme scheme;

  /// "Add lyrics": paste them, then time them.
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            FluentIcons.text_quote_24_regular,
            size: 44,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text(
            'Lyrics aren’t available for this song yet.',
            textAlign: TextAlign.center,
            style: muzikaBody(16, weight: 500, color: scheme.onSurfaceVariant),
          ),
          if (onAdd != null) ...[
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(FluentIcons.add_24_regular),
              label: const Text('Add lyrics'),
            ),
            const SizedBox(height: 6),
            Text(
              'Paste the words, then touch each line when you hear it.\n'
              'Everyone gets them after you save.',
              textAlign: TextAlign.center,
              style: muzikaBody(13, color: scheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}

/// Lyric-shaped shimmer bars while the lyrics load.
class _LyricsSkeleton extends StatelessWidget {
  const _LyricsSkeleton();

  @override
  Widget build(BuildContext context) {
    const widths = [0.7, 0.55, 0.8, 0.45, 0.65, 0.5, 0.75, 0.4];
    return MuzikaShimmer(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(28, 28, 28, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final w in widths)
              Padding(
                padding: const EdgeInsets.only(bottom: 22),
                child: FractionallySizedBox(
                  widthFactor: w,
                  child: const MuzikaSkeletonBox(height: 18),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Synced lyrics running early or late: touch the line heard now, and every
/// line moves by the same amount (kept for this song).
class _ShiftPicker extends StatelessWidget {
  const _ShiftPicker({
    required this.lines,
    required this.fontSize,
    required this.padding,
    required this.onPick,
    required this.onCancel,
  });

  final List<LyricLine> lines;
  final double fontSize;
  final EdgeInsets padding;
  final void Function(int index) onPick;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Material(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
            child: Row(
              children: [
                Icon(FluentIcons.hand_left_24_regular, color: scheme.onSurface),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Touch the line you hear now: all the lyrics move to it',
                    style: muzikaBody(
                      13.5,
                      weight: 600,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
                TextButton(onPressed: onCancel, child: const Text('Cancel')),
              ],
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: padding,
            itemCount: lines.length,
            itemBuilder: (context, i) => InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => onPick(i),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                child: Text(
                  lines[i].text.isEmpty ? '♪' : lines[i].text,
                  style: muzikaHeading(
                    fontSize * 0.85,
                    weight: 600,
                    color: scheme.onSurface.withValues(alpha: 0.8),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
