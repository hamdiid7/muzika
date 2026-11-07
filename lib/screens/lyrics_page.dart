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
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:audio_service/audio_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muzika/main.dart' show audioHandler;
import 'package:muzika/screens/lyrics_game_page.dart';
import 'package:muzika/services/cover_tint.dart';
import 'package:muzika/services/desktop_panels.dart';
import 'package:muzika/services/settings_manager.dart';
import 'package:muzika/services/synced_lyrics.dart';
import 'package:muzika/theme/muzika_tokens.dart';
import 'package:muzika/utilities/flutter_toast.dart';
import 'package:muzika/utilities/song_credits.dart';
import 'package:muzika/widgets/hold_for_speed.dart';
import 'package:muzika/widgets/muzika_player_options.dart';
import 'package:muzika/widgets/muzika_share.dart';
import 'package:muzika/widgets/song_artwork.dart';
import 'package:muzika/widgets/synced_lyrics_view.dart';

/// Lyrics of the playing song, sliding up over the player. Drag the top
/// down to close.
Future<void> openLyricsPage(BuildContext context) async {
  // The wide Windows layout: the right side turns to the lyrics.
  if (desktopPanels.value) {
    desktopLyricsOpen.value = true;
    return;
  }
  return showModalBottomSheet<void>(
    context: context,
    // Wide Windows layout: the sheet opens in the part it came from.
    useRootNavigator: !desktopPanels.value,
    useSafeArea: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _LyricsSheet(),
  );
}

/// The lyrics in the song's colour, as a panel (the wide Windows layout,
/// under the player): no handle and no song line above them.
class LyricsPanel extends StatelessWidget {
  const LyricsPanel({super.key});

  @override
  Widget build(BuildContext context) => const _LyricsSheet(embedded: true);
}

class _LyricsSheet extends StatelessWidget {
  const _LyricsSheet({this.embedded = false});

  final bool embedded;

  /// The song's colour (its cover's), deep enough for white words, as
  /// Spotify's lyrics: everything on the sheet turns white on it.
  static Color _songColor(Color cover) {
    final hsl = HSLColor.fromColor(cover);
    return hsl
        .withSaturation(hsl.saturation.clamp(0.35, 0.75))
        .withLightness(0.3)
        .toColor();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Color?>(
      valueListenable: coverTint,
      builder: (context, cover, _) {
        final base = Theme.of(context);
        if (cover == null) return _sheet(context);
        final color = _songColor(cover);
        return Theme(
          data: base.copyWith(
            colorScheme: base.colorScheme.copyWith(
              brightness: Brightness.dark,
              surface: color,
              onSurface: Colors.white,
              onSurfaceVariant: Colors.white70,
              surfaceContainerHigh: Colors.white.withValues(alpha: 0.14),
              surfaceContainerHighest: Colors.white.withValues(alpha: 0.2),
            ),
          ),
          child: Builder(builder: _sheet),
        );
      },
    );
  }

  Widget _sheet(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      height: embedded ? null : MediaQuery.sizeOf(context).height,
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: embedded
            ? BorderRadius.circular(16)
            : const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: StreamBuilder<MediaItem?>(
        stream: audioHandler.mediaItem,
        initialData: audioHandler.mediaItem.valueOrNull,
        builder: (context, snapshot) {
          final item = snapshot.data;
          if (item == null) return const SizedBox.shrink();
          final credits = songCredits(item.title, item.artist ?? '');
          return Column(
            children: [
              if (!embedded) ...[
                Container(
                  margin: const EdgeInsets.only(top: 10, bottom: 6),
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 8, 4),
                  child: Row(
                    children: [
                      // Tap the song to close the lyrics.
                      Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => Navigator.of(context).maybePop(),
                          child: Row(
                            children: [
                              SongArtworkWidget(
                                metadata: item,
                                size: 44,
                                borderRadius: 6,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      credits.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: muzikaBody(
                                        15,
                                        weight: 700,
                                        color: scheme.onSurface,
                                      ),
                                    ),
                                    Text(
                                      credits.artist,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: muzikaBody(
                                        13,
                                        color: scheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      // Game mode (Settings): sing along to this song.
                      ValueListenableBuilder<bool>(
                        valueListenable: gameMode,
                        builder: (context, on, _) => on
                            ? IconButton(
                                tooltip: 'Lyrics game',
                                onPressed: () => openLyricsGame(context, [
                                  currentSongMap(item),
                                ]),
                                icon: Icon(
                                  Icons.sports_esports_outlined,
                                  color: scheme.onSurface,
                                ),
                              )
                            : const SizedBox.shrink(),
                      ),
                      // Time the lyrics by hand: plain ones line by line
                      // from the start, synced ones moved to the line heard.
                      IconButton(
                        tooltip: 'Touch the line when you hear it',
                        onPressed: () => lyricsEditRequests.value++,
                        icon: Icon(
                          FluentIcons.edit_24_regular,
                          color: scheme.onSurface,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Share lyrics',
                        onPressed: () => showLyricsPicker(context, item),
                        icon: Icon(
                          Icons.ios_share_rounded,
                          color: scheme.onSurface,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              Expanded(
                // Lines fade in at the top and out at the bottom.
                child: ShaderMask(
                  blendMode: BlendMode.dstIn,
                  shaderCallback: (rect) => const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: [0, 0.1, 0.86, 1],
                    colors: [
                      Colors.transparent,
                      Colors.black,
                      Colors.black,
                      Colors.transparent,
                    ],
                  ).createShader(rect),
                  // Hold the right side for 2×.
                  child: HoldForSpeed(
                    expand: true,
                    child: SyncedLyricsView(
                      metadata: item,
                      // The header's ✏️ when it shows; else one over the lyrics.
                      editButton: embedded,
                      fontSize: embedded ? 20 : 25,
                      // Lines start under the cover above.
                      padding: const EdgeInsets.fromLTRB(16, 40, 16, 120),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Sharing, step 1: pick up to five lines (picked lines turn bold).
// ---------------------------------------------------------------------------

Future<void> showLyricsPicker(BuildContext context, MediaItem item) {
  return showModalBottomSheet<void>(
    context: context,
    // Wide Windows layout: the sheet opens in the part it came from.
    useRootNavigator: !desktopPanels.value,
    useSafeArea: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _LinePicker(item: item),
  );
}

class _LinePicker extends StatefulWidget {
  const _LinePicker({required this.item});

  final MediaItem item;

  @override
  State<_LinePicker> createState() => _LinePickerState();
}

class _LinePickerState extends State<_LinePicker> {
  static const _maxLines = 5;

  late final Future<List<String>> _lines = _loadLines();
  final _selected = <int>{};

  Future<List<String>> _loadLines() async {
    final m = widget.item;
    final lyrics = await fetchSongLyrics(
      artist: m.artist ?? '',
      title: m.title,
      album: m.album,
      duration: m.duration,
      videoId: m.extras?['ytid']?.toString(),
    );
    if (lyrics == null) return const [];
    final raw = lyrics.isSynced
        ? lyrics.lines!.map((l) => l.text)
        : (lyrics.plain ?? '').split('\n');
    return [
      for (final l in raw)
        if (l.trim().isNotEmpty) l.trim(),
    ];
  }

  int get _first => _selected.reduce(min);
  int get _last => _selected.reduce(max);

  /// Lines are picked as one unbroken run: after the first, only the line
  /// just before or just after the run can be added.
  bool _canPick(int i) =>
      _selected.isEmpty ||
      _selected.contains(i) ||
      (_selected.length < _maxLines && (i == _first - 1 || i == _last + 1));

  void _toggle(int i) {
    if (!_canPick(i)) {
      if (_selected.length >= _maxLines) {
        showToast(context, 'Up to $_maxLines lines');
      }
      return;
    }
    unawaited(HapticFeedback.selectionClick());
    setState(() {
      if (!_selected.contains(i)) {
        _selected.add(i);
      } else if (i == _first || i == _last) {
        _selected.remove(i);
      } else {
        // A line in the middle starts the run over from there.
        _selected
          ..clear()
          ..add(i);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bottom = MediaQuery.viewPaddingOf(context).bottom;
    return Container(
      height: MediaQuery.sizeOf(context).height,
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: FutureBuilder<List<String>>(
        future: _lines,
        builder: (context, snapshot) {
          final lines = snapshot.data ?? const <String>[];
          return Stack(
            children: [
              Column(
                children: [
                  Container(
                    margin: const EdgeInsets.only(top: 10, bottom: 12),
                    width: 38,
                    height: 4,
                    decoration: BoxDecoration(
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        _selected.isEmpty
                            ? 'Tap up to $_maxLines lines'
                            : '${_selected.length} of $_maxLines',
                        style: muzikaHeading(20, color: scheme.onSurface),
                      ),
                    ),
                  ),
                  Expanded(
                    child: snapshot.connectionState != ConnectionState.done
                        ? const Center(child: CircularProgressIndicator())
                        : lines.isEmpty
                        ? Center(
                            child: Text(
                              'No lyrics for this song yet.',
                              style: muzikaBody(
                                15,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          )
                        : ListView.builder(
                            padding: EdgeInsets.only(bottom: 120 + bottom),
                            itemCount: lines.length,
                            itemBuilder: (context, i) {
                              final on = _selected.contains(i);
                              final open = _canPick(i);
                              return InkWell(
                                onTap: () => _toggle(i),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 24,
                                    vertical: 9,
                                  ),
                                  child: AnimatedDefaultTextStyle(
                                    duration: const Duration(milliseconds: 160),
                                    style: muzikaHeading(
                                      21,
                                      weight: on ? 800 : 400,
                                      color: on
                                          ? scheme.onSurface
                                          : scheme.onSurfaceVariant.withValues(
                                              alpha: open ? 0.7 : 0.25,
                                            ),
                                    ).copyWith(height: 1.3),
                                    child: Text(lines[i]),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
              // Floating "Next" at the bottom, once a line is picked.
              Positioned(
                left: 24,
                right: 24,
                bottom: 20 + bottom,
                child: AnimatedSlide(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  offset: _selected.isEmpty ? const Offset(0, 2) : Offset.zero,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: scheme.onSurface,
                      foregroundColor: scheme.surface,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: const StadiumBorder(),
                    ),
                    onPressed: _selected.isEmpty
                        ? null
                        : () {
                            final picked = [
                              for (final i in _selected.toList()..sort())
                                lines[i],
                            ];
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => MuzikaSharePage(
                                  fileName: 'muzika_lyrics',
                                  shareText:
                                      '“${widget.item.title}” by '
                                      '${widget.item.artist ?? ''} · '
                                      'muzika.pages.dev',
                                  card: _LyricsCard(
                                    item: widget.item,
                                    lines: picked,
                                  ),
                                ),
                              ),
                            );
                          },
                    child: Text('Next', style: muzikaBody(16, weight: 700)),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Sharing, step 2: the card (shown on MuzikaSharePage).
// ---------------------------------------------------------------------------

/// The shared image: the cover blurred behind, the picked lines in bold, the
/// song underneath and muzika.pages.dev.
class _LyricsCard extends StatelessWidget {
  const _LyricsCard({required this.item, required this.lines});

  final MediaItem item;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final art = item.artUri;
    final cover = art == null
        ? null
        : (art.scheme == 'file'
              ? FileImage(File(art.toFilePath())) as ImageProvider
              : CachedNetworkImageProvider(art.toString()));
    return AspectRatio(
      aspectRatio: 4 / 5,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: Color(0xFF212121)),
            if (cover != null)
              ImageFiltered(
                imageFilter: ui.ImageFilter.blur(sigmaX: 28, sigmaY: 28),
                child: Image(image: cover, fit: BoxFit.cover),
              ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x99000000), Color(0xDD000000)],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 20, 22, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'muzika.pages.dev',
                    style: muzikaHeading(14, color: Colors.white70),
                  ),
                  const Spacer(),
                  for (final line in lines)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        line,
                        style: muzikaHeading(
                          lines.length > 3 ? 19 : 23,
                          weight: 800,
                          color: Colors.white,
                        ).copyWith(height: 1.25),
                      ),
                    ),
                  const Spacer(),
                  Row(
                    children: [
                      if (cover != null)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: Image(
                            image: cover,
                            width: 40,
                            height: 40,
                            fit: BoxFit.cover,
                          ),
                        ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              songCredits(item.title, item.artist ?? '').title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: muzikaBody(
                                14,
                                weight: 700,
                                color: Colors.white,
                              ),
                            ),
                            Text(
                              songCredits(item.title, item.artist ?? '').artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: muzikaBody(12.5, color: Colors.white70),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
