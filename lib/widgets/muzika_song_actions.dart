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

import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muzika/main.dart' show audioHandler;
import 'package:muzika/services/common_services.dart';
import 'package:muzika/services/desktop_panels.dart';
import 'package:muzika/services/listening_stats.dart';
import 'package:muzika/services/muzika_downloads.dart';
import 'package:muzika/services/playlists_manager.dart';
import 'package:muzika/services/router_service.dart';
import 'package:muzika/theme/muzika_tokens.dart';
import 'package:muzika/utilities/flutter_toast.dart';
import 'package:muzika/utilities/playlist_dialogs.dart';
import 'package:muzika/utilities/song_credits.dart';

// ---------------------------------------------------------------------------
// "+" : one tap saves to your most-listened playlist, hold adds to the queue.
// ---------------------------------------------------------------------------

/// Saves [song] to the playlist the user listens to most (Liked Songs when
/// there is no playlist yet) and offers "Change" in the snack bar.
Future<void> saveToFavorite(BuildContext context, Map song) async {
  unawaited(HapticFeedback.lightImpact());
  final title = (song['title'] ?? '').toString();
  final ytid = (song['ytid'] ?? '').toString();
  final playlist = ListeningStats.instance.favoritePlaylist();

  if (playlist == null) {
    final alreadyLiked = isSongAlreadyLiked(ytid);
    if (!alreadyLiked) await updateSongLikeStatus(ytid, true, songData: song);
    if (!context.mounted) return;
    showToastWithButton(
      context,
      alreadyLiked ? '“$title” is in Liked Songs' : 'Saved to Liked Songs',
      'Change',
      () {
        if (!alreadyLiked) {
          unawaited(updateSongLikeStatus(ytid, false, songData: song));
        }
        showAddToPlaylistDialog(context, song: song);
      },
      duration: const Duration(seconds: 4),
    );
    return;
  }

  final name = (playlist['title'] ?? 'playlist').toString();
  final playlistId = (playlist['ytid'] ?? '').toString();
  final songs = playlist['list'] as List? ?? const [];
  final already = songs.any((s) => s is Map && '${s['ytid']}' == ytid);
  if (!already) addSongInCustomPlaylist(context, playlistId, song);
  final added = !already;
  showToastWithButton(
    context,
    added ? 'Saved to $name' : '“$title” is already in $name',
    'Change',
    () {
      if (added) removeSongFromPlaylist(playlist, song);
      showAddToPlaylistDialog(context, song: song);
    },
    duration: const Duration(seconds: 4),
  );
}

Future<void> addToQueueWithToast(BuildContext context, Map song) async {
  unawaited(HapticFeedback.mediumImpact());
  await audioHandler.addToQueue(song);
  if (context.mounted) {
    showToast(
      context,
      'Added “${song['title'] ?? ''}” to queue',
      duration: const Duration(seconds: 2),
    );
  }
}

/// The round "+" of the design.
class MuzikaAddButton extends StatefulWidget {
  const MuzikaAddButton({
    super.key,
    required this.song,
    this.size = 22,
    this.offerTip = true,
  });

  final Map song;
  final double size;

  /// Lets this button host the one-time "tap / hold" tip if no other button
  /// has claimed it.
  final bool offerTip;

  @override
  State<MuzikaAddButton> createState() => _MuzikaAddButtonState();
}

class _MuzikaAddButtonState extends State<MuzikaAddButton> {
  late final bool _tip = widget.offerTip && MuzikaFirstTimeTip.claim();

  /// In Liked Songs or one of your playlists already.
  bool _saved() {
    final ytid = '${widget.song['ytid'] ?? ''}';
    if (ytid.isEmpty) return false;
    if (isSongAlreadyLiked(ytid)) return true;
    // Playlists in folders too ("dink midirs" may live in one).
    return getUserCustomPlaylists().any(
      (p) => (p['list'] as List? ?? const []).any(
        (s) => s is Map && '${s['ytid']}' == ytid,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = widget.size;
    // A check mark once it's saved (tap to change where); "+" until then.
    final button = ListenableBuilder(
      listenable: Listenable.merge([
        userCustomPlaylists,
        userPlaylistFolders,
        userLikedSongsList,
      ]),
      builder: (context, _) {
        final saved = _saved();
        // As big as the download icon beside it ([size] px), in the same
        // 40 px tap area.
        return InkResponse(
          radius: 20,
          onTap: () => saved
              ? showAddToPlaylistDialog(context, song: widget.song)
              : saveToFavorite(context, widget.song),
          onLongPress: () => addToQueueWithToast(context, widget.song),
          // Right-click (Windows) does what a long press does.
          onSecondaryTap: () => addToQueueWithToast(context, widget.song),
          child: SizedBox(
            width: 40,
            height: 40,
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: size,
                height: size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: saved ? scheme.onSurface : Colors.transparent,
                  border: saved
                      ? null
                      : Border.all(color: scheme.onSurfaceVariant, width: 1.6),
                ),
                child: Icon(
                  saved
                      ? FluentIcons.checkmark_16_filled
                      : FluentIcons.add_16_regular,
                  size: size * 0.62,
                  color: saved ? scheme.surface : scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        );
      },
    );
    return Semantics(
      hint: 'Tap to save to your top playlist, hold to add to queue',
      child: _tip ? MuzikaFirstTimeTip(child: button) : button,
    );
  }
}

/// Heart that likes / unlikes the song and follows the liked list.
class MuzikaLikeButton extends StatelessWidget {
  const MuzikaLikeButton({super.key, required this.song, this.size = 22});

  final Map song;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ytid = (song['ytid'] ?? '').toString();
    return ValueListenableBuilder<List>(
      valueListenable: userLikedSongsList,
      builder: (context, _, _) {
        final liked = isSongAlreadyLiked(ytid);
        return IconButton(
          tooltip: liked ? 'Unlike' : 'Like',
          visualDensity: VisualDensity.compact,
          onPressed: () {
            unawaited(HapticFeedback.selectionClick());
            unawaited(updateSongLikeStatus(ytid, !liked, songData: song));
          },
          icon: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            transitionBuilder: (child, a) =>
                ScaleTransition(scale: a, child: child),
            child: Icon(
              liked
                  ? FluentIcons.heart_24_filled
                  : FluentIcons.heart_24_regular,
              key: ValueKey(liked),
              size: size,
              color: liked ? scheme.onSurface : scheme.onSurfaceVariant,
            ),
          ),
        );
      },
    );
  }
}

/// Download arrow → a ring filling up while the song saves → a check once
/// it is in Offline. Songs played for a while save on their own, so most
/// rows the user has heard already show the check.
class MuzikaDownloadButton extends StatelessWidget {
  const MuzikaDownloadButton({super.key, required this.song, this.size = 22});

  final Map song;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ytid = (song['ytid'] ?? '').toString();
    return ValueListenableBuilder<Map<String, double>>(
      valueListenable: downloadProgress,
      builder: (context, progress, _) => ValueListenableBuilder<List>(
        valueListenable: userOfflineSongs,
        builder: (context, _, _) {
          // Only real downloads get the check; cached songs keep the arrow
          // (tapping it keeps them for good, without downloading again).
          final saved = isSongDownloaded(ytid);
          final p = progress[ytid];
          final Widget icon;
          if (p != null) {
            icon = SizedBox(
              key: const ValueKey('loading'),
              width: size,
              height: size,
              child: CircularProgressIndicator(
                value: p <= 0 ? null : p,
                strokeWidth: 2.4,
                strokeCap: StrokeCap.round,
                color: scheme.onSurface,
                backgroundColor: scheme.surfaceContainerHighest,
              ),
            );
          } else {
            icon = Icon(
              saved
                  ? FluentIcons.arrow_circle_down_24_filled
                  : FluentIcons.arrow_download_24_regular,
              key: ValueKey(saved),
              size: size,
              color: saved ? scheme.onSurface : scheme.onSurfaceVariant,
            );
          }
          return IconButton(
            tooltip: saved
                ? 'Downloaded'
                : (p != null ? 'Downloading…' : 'Download'),
            visualDensity: VisualDensity.compact,
            onPressed: saved || p != null || ytid.isEmpty
                ? null
                : () {
                    unawaited(HapticFeedback.selectionClick());
                    unawaited(downloadSong(song));
                  },
            icon: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              transitionBuilder: (child, a) =>
                  ScaleTransition(scale: a, child: child),
              child: icon,
            ),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Artist links
// ---------------------------------------------------------------------------

/// Opens the artist of [song]. From the full player (a root route) the player
/// closes first and the artist opens in the Home tab.
void openArtistFor(BuildContext context, Map song, {bool fromPlayer = false}) {
  final name = (song['artist'] ?? '')
      .toString()
      .split(RegExp(r',|&| x | feat\.?'))
      .first
      .trim();
  final id = song['artistId']?.toString() ?? '';
  final key = id.isNotEmpty ? id : name;
  if (key.isEmpty) return;
  final extra = <String, dynamic>{'title': name, if (id.isNotEmpty) 'ytid': id};
  // The player is a page of its own only on a phone; on the wide Windows
  // layout it sits beside the page, so there's nothing to close.
  if (fromPlayer) {
    if (!desktopPanels.value) Navigator.of(context).pop();
    unawaited(
      NavigationManager.router.push(
        '${NavigationManager.currentBasePath}/artist/${Uri.encodeComponent(key)}',
        extra: extra,
      ),
    );
  } else {
    unawaited(
      context.push(NavigationManager.artistPath(context, key), extra: extra),
    );
  }
}

/// Artist line, with any "feat." artists from the title added. In the full
/// player each artist opens their own page when tapped.
class MuzikaArtistLink extends StatefulWidget {
  const MuzikaArtistLink({
    super.key,
    required this.song,
    required this.style,
    this.text,
    this.fromPlayer = false,
  });

  final Map song;
  final TextStyle style;

  /// Defaults to the song's artist.
  final String? text;
  final bool fromPlayer;

  @override
  State<MuzikaArtistLink> createState() => _MuzikaArtistLinkState();
}

class _MuzikaArtistLinkState extends State<MuzikaArtistLink> {
  final _taps = <TapGestureRecognizer>[];

  void _clearTaps() {
    for (final t in _taps) {
      t.dispose();
    }
    _taps.clear();
  }

  @override
  void dispose() {
    _clearTaps();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final song = widget.song;
    final label = songCredits(
      (song['title'] ?? '').toString(),
      widget.text ?? (song['artist'] ?? '').toString(),
    ).artist;
    _clearTaps();
    if (!widget.fromPlayer || label.isEmpty) {
      return Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: widget.style,
      );
    }
    // Each name a link; the separators between them as they were.
    final spans = <InlineSpan>[];
    final names = artistNames(label);
    var rest = label;
    for (final (i, name) in names.indexed) {
      final at = rest.indexOf(name);
      if (at < 0) continue;
      if (at > 0) spans.add(TextSpan(text: rest.substring(0, at)));
      final tap = TapGestureRecognizer()
        ..onTap = () => openArtistFor(
          context,
          // The first is the song's own artist (with its id); others by name.
          i == 0 ? song : {'artist': name},
          fromPlayer: true,
        );
      _taps.add(tap);
      spans.add(TextSpan(text: name, recognizer: tap));
      rest = rest.substring(at + name.length);
    }
    if (rest.isNotEmpty) spans.add(TextSpan(text: rest));
    return Text.rich(
      TextSpan(children: spans),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: widget.style,
    );
  }
}

// ---------------------------------------------------------------------------
// First-time tip
// ---------------------------------------------------------------------------

/// A small dark bubble pointing at [child], shown once per install the first
/// time a song row with actions appears: what tap, hold and ♥ do.
class MuzikaFirstTimeTip extends StatefulWidget {
  const MuzikaFirstTimeTip({super.key, required this.child});

  final Widget child;

  static const _seenKey = 'tipSongActionsSeen';
  static bool _claimed = false;

  /// True for exactly one widget, and only until the tip has been seen.
  static bool claim() {
    if (_claimed) return false;
    final seen =
        Hive.box('settings').get(_seenKey, defaultValue: false) == true;
    if (seen) {
      _claimed = true;
      return false;
    }
    _claimed = true;
    return true;
  }

  @override
  State<MuzikaFirstTimeTip> createState() => _MuzikaFirstTimeTipState();
}

class _MuzikaFirstTimeTipState extends State<MuzikaFirstTimeTip>
    with SingleTickerProviderStateMixin {
  final _link = LayerLink();
  final _portal = OverlayPortalController();
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (!mounted) return;
      _portal.show();
      unawaited(_fade.forward());
      unawaited(Hive.box('settings').put(MuzikaFirstTimeTip._seenKey, true));
      _hideTimer = Timer(const Duration(seconds: 7), _hide);
    });
  }

  Future<void> _hide() async {
    _hideTimer?.cancel();
    if (!mounted || !_portal.isShowing) return;
    await _fade.reverse();
    if (mounted) _portal.hide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: (context) => CompositedTransformFollower(
          link: _link,
          targetAnchor: Alignment.bottomRight,
          followerAnchor: Alignment.topRight,
          offset: const Offset(4, 8),
          child: Align(
            alignment: Alignment.topRight,
            child: FadeTransition(
              opacity: _fade,
              child: GestureDetector(
                onTap: _hide,
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 250),
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
                  decoration: BoxDecoration(
                    color: scheme.onSurface,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.18),
                        blurRadius: 16,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: DefaultTextStyle(
                    style: muzikaBody(13, color: scheme.surface),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      spacing: 4,
                      children: [
                        Text(
                          'Quick tips',
                          style: muzikaBody(
                            13,
                            weight: 700,
                            color: scheme.surface,
                          ),
                        ),
                        const Text('Tap +  to save to your top playlist'),
                        const Text('Hold +  to add to the queue'),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        child: widget.child,
      ),
    );
  }
}
