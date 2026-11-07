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
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:flutter/services.dart';
import 'package:muzika/screens/daily_story_page.dart';
import 'package:muzika/services/story_reminder.dart';
import 'package:muzika/widgets/muzika_logo.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muzika/screens/story_viewer_page.dart';
import 'package:muzika/services/deezer_catalog.dart' show deezerArtistPhoto;
import 'package:muzika/services/desktop_panels.dart';
import 'package:muzika/services/muzika_home.dart';
import 'package:muzika/utilities/image_size.dart';
import 'package:muzika/theme/muzika_tokens.dart';

/// The videos already watched as stories (their bubbles go grey).
final storiesSeen = ValueNotifier<Set<String>>({
  ...((Hive.box('settings').get('storiesSeen') as List?) ?? const []).map(
    (e) => '$e',
  ),
});

void markStorySeen(String videoId) {
  if (storiesSeen.value.contains(videoId)) return;
  final seen = {...storiesSeen.value, videoId};
  // The last few hundred are enough: older videos leave the lists.
  storiesSeen.value = seen.length > 300
      ? seen.skip(seen.length - 300).toSet()
      : seen;
  unawaited(
    Hive.box('settings').put('storiesSeen', storiesSeen.value.toList()),
  );
}

/// An artist's round photo (their page, the player); with the story ring
/// when they've put something out in the last four weeks ([artistStory]),
/// and then a tap opens that story. Grey once watched. Without a story a
/// tap does [onTap] (the player opens the artist). With no [image], the
/// artist's photo from Deezer.
class ArtistStoryAvatar extends StatefulWidget {
  const ArtistStoryAvatar({
    super.key,
    required this.name,
    this.image,
    this.size = 96,
    this.onTap,
  });

  final String name;
  final String? image;
  final double size;
  final VoidCallback? onTap;

  @override
  State<ArtistStoryAvatar> createState() => _ArtistStoryAvatarState();
}

class _ArtistStoryAvatarState extends State<ArtistStoryAvatar> {
  late Future<HomeStory?> _story;
  late Future<String?> _photo;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(ArtistStoryAvatar old) {
    super.didUpdateWidget(old);
    if (old.name != widget.name || old.image != widget.image) _load();
  }

  void _load() {
    _story = artistStory(widget.name).catchError((_) => null);
    final image = widget.image;
    _photo = image != null && image.isNotEmpty
        ? Future.value(image)
        : deezerArtistPhoto(widget.name).catchError((_) => null);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = widget.size;
    // Thinner ring on a small photo.
    final ringWidth = size < 50 ? 2.0 : 3.5;
    final gap = size < 50 ? 1.5 : 3.0;
    final photo = FutureBuilder<String?>(
      future: _photo,
      builder: (context, snapshot) {
        final url = snapshot.data;
        return ClipOval(
          child: url == null || url.isEmpty
              ? ColoredBox(
                  color: scheme.surfaceContainerHigh,
                  child: SizedBox(width: size, height: size),
                )
              : CachedNetworkImage(
                  imageUrl: sizedImageUrl(
                    url,
                    size * MediaQuery.devicePixelRatioOf(context),
                  ),
                  width: size,
                  height: size,
                  fit: BoxFit.cover,
                ),
        );
      },
    );
    return FutureBuilder<HomeStory?>(
      future: _story,
      builder: (context, snapshot) {
        final story = snapshot.data;
        if (story == null) {
          return GestureDetector(
            onTap: widget.onTap,
            child: SizedBox(width: size, height: size, child: photo),
          );
        }
        return ValueListenableBuilder<Set<String>>(
          valueListenable: storiesSeen,
          builder: (context, seen, _) {
            final watched = seen.contains(story.video.id);
            return Tooltip(
              message: 'Story',
              child: GestureDetector(
                onTap: () {
                  // Home's own list when it's one of them, so the rest
                  // follow; else this one alone.
                  final all = pickedHomeStories;
                  final at = all.indexWhere(
                    (s) => s.video.id == story.video.id,
                  );
                  unawaited(
                    at >= 0
                        ? openStories(context, all, at)
                        : openStories(context, [story], 0),
                  );
                },
                child: Container(
                  width: size,
                  height: size,
                  padding: EdgeInsets.all(ringWidth),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: watched
                        ? null
                        : const LinearGradient(
                            begin: Alignment.bottomLeft,
                            end: Alignment.topRight,
                            colors: StoryRow._ring,
                          ),
                    border: watched
                        ? Border.all(color: scheme.outlineVariant, width: 1.5)
                        : null,
                  ),
                  child: Container(
                    padding: EdgeInsets.all(gap),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: scheme.surface,
                    ),
                    child: photo,
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// Everyone on a song (the player's "Rihanna, Drake"), as Instagram shows a
/// collab post: their round photos overlapping, each ringed when that
/// artist has a story. One artist: just their photo. Several: a tap lists
/// them in a sheet (a ringed photo plays the story, the name opens the
/// artist through [onArtist]).
class CollabArtistAvatars extends StatelessWidget {
  const CollabArtistAvatars({
    super.key,
    required this.names,
    required this.onArtist,
    this.size = 26,
  });

  final List<String> names;
  final void Function(String name) onArtist;
  final double size;

  /// "Rihanna, Drake & Future feat. Tems" → the four of them.
  static List<String> split(String artists) {
    final seen = <String>{};
    return [
      for (final n in artists.split(
        RegExp(r',|&| x | and | feat\.? | ft\.? ', caseSensitive: false),
      ))
        if (n.trim().isNotEmpty && seen.add(n.trim().toLowerCase())) n.trim(),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final shown = names.take(3).toList();
    if (shown.isEmpty) return const SizedBox.shrink();
    if (shown.length == 1) {
      return ArtistStoryAvatar(
        key: ValueKey(shown.first),
        name: shown.first,
        size: size,
        onTap: () => onArtist(shown.first),
      );
    }
    final step = size * 0.62;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _sheet(context),
      child: SizedBox(
        width: size + step * (shown.length - 1),
        height: size,
        child: AbsorbPointer(
          child: Stack(
            children: [
              // The last drawn first, so the first artist sits on top.
              for (var i = shown.length - 1; i >= 0; i--)
                Positioned(
                  left: step * i,
                  child: ArtistStoryAvatar(
                    key: ValueKey(shown[i]),
                    name: shown[i],
                    size: size,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _sheet(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return showModalBottomSheet<void>(
      context: context,
      useRootNavigator: !desktopPanels.value,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                'Artists on this song',
                style: muzikaHeading(18, color: scheme.onSurface),
              ),
            ),
            for (final name in names)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                // A ringed photo plays their story.
                leading: ArtistStoryAvatar(
                  key: ValueKey('sheet $name'),
                  name: name,
                  size: 44,
                  onTap: () {
                    Navigator.of(sheet).pop();
                    onArtist(name);
                  },
                ),
                title: Text(
                  name,
                  style: muzikaBody(16, weight: 600, color: scheme.onSurface),
                ),
                trailing: Icon(
                  FluentIcons.chevron_right_24_regular,
                  color: scheme.onSurfaceVariant,
                ),
                onTap: () {
                  Navigator.of(sheet).pop();
                  onArtist(name);
                },
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

/// Instagram's row of stories, at the top of Home. First Muzika's own
/// (the logo): the day in music once it's ready at 9 pm, else Settings.
/// Then one bubble per artist with something new (all their new songs play
/// in a row), the ones not watched yet first, each with a coloured ring
/// until it's watched.
class StoryRow extends StatelessWidget {
  const StoryRow({super.key, required this.future});

  final Future<List<HomeStory>> future;

  static const _ring = [
    Color(0xFFFEDA75),
    Color(0xFFFA7E1E),
    Color(0xFFD62976),
    Color(0xFF962FBF),
  ];

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<HomeStory>>(
      future: future,
      builder: (context, snapshot) {
        final stories = snapshot.data ?? const <HomeStory>[];
        return ValueListenableBuilder<Set<String>>(
          valueListenable: storiesSeen,
          builder: (context, seen, _) {
            // The artists' runs, unwatched ones first (else as picked).
            final groups = <String, List<HomeStory>>{};
            for (final s in stories) {
              (groups[storyArtistKey(s)] ??= []).add(s);
            }
            bool watched(List<HomeStory> g) =>
                g.every((s) => seen.contains(s.video.id));
            final runs = [
              ...groups.values.where((g) => !watched(g)),
              ...groups.values.where(watched),
            ];
            // The viewer gets them in that order, so it carries on from
            // one artist to the next.
            final ordered = [for (final g in runs) ...g];
            return SizedBox(
              height: 104,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                // Lined up with the title and the shelves (20 on the left).
                padding: const EdgeInsets.symmetric(horizontal: 20),
                itemCount: runs.length + 1,
                // No gap for Muzika's own while it isn't there.
                separatorBuilder: (_, i) => SizedBox(
                  width: i == 0 && !StoryReminder.isAvailable ? 0 : 12,
                ),
                itemBuilder: (context, i) {
                  if (i == 0) return const _MuzikaBubble();
                  final run = runs[i - 1];
                  final start = ordered.indexOf(run.first);
                  // Opens at their first one not watched yet.
                  final unseen = run.indexWhere(
                    (s) => !seen.contains(s.video.id),
                  );
                  // The artist's own photo (Deezer's), else one from
                  // their stories that isn't a video's picture.
                  final photo =
                      storyArtistPhotos[storyArtistKey(run.first)] ??
                      run
                          .map((s) => s.video.photo)
                          .firstWhere(
                            (p) => p.isNotEmpty && !p.contains('i.ytimg.com'),
                            orElse: () => run.first.video.photo,
                          );
                  return _Bubble(
                    photo: photo,
                    label: run.first.video.artist,
                    watched: watched(run),
                    count: run.length,
                    onTap: () => openStories(
                      context,
                      ordered,
                      start + (unseen < 0 ? 0 : unseen),
                    ),
                  );
                },
              ),
            );
          },
        );
      },
    );
  }
}

/// One round bubble of the row: a ringed photo, its name under it, and how
/// many stories it holds when more than one.
class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.photo,
    required this.label,
    required this.watched,
    required this.onTap,
    this.count = 1,
    this.child,
  });

  final String photo;
  final String label;
  final bool watched;
  final int count;
  final VoidCallback onTap;

  /// In place of the photo (Muzika's logo).
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(40),
      onTap: onTap,
      child: SizedBox(
        width: 74,
        child: Column(
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 70,
                  height: 70,
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: watched
                        ? null
                        : const LinearGradient(
                            begin: Alignment.bottomLeft,
                            end: Alignment.topRight,
                            colors: StoryRow._ring,
                          ),
                    border: watched
                        ? Border.all(color: scheme.outlineVariant, width: 1.5)
                        : null,
                  ),
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: scheme.surface,
                    ),
                    child:
                        child ??
                        CircleAvatar(
                          backgroundColor: scheme.surfaceContainerHigh,
                          backgroundImage: photo.isEmpty
                              ? null
                              : CachedNetworkImageProvider(photo),
                        ),
                  ),
                ),
                if (count > 1)
                  Positioned(
                    right: -2,
                    bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: watched
                            ? scheme.surfaceContainerHighest
                            : const Color(0xFFD62976),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: scheme.surface, width: 2),
                      ),
                      child: Text(
                        '$count',
                        style: muzikaBody(
                          11,
                          weight: 700,
                          color: watched ? scheme.onSurface : Colors.white,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: muzikaBody(
                12,
                color: watched ? scheme.onSurfaceVariant : scheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Muzika's own story, first in the row: "Your day", today's day in music,
/// from 9 pm (once something was played). Ringed until watched; a tap
/// plays it. Not there the rest of the day.
class _MuzikaBubble extends StatefulWidget {
  const _MuzikaBubble();

  @override
  State<_MuzikaBubble> createState() => _MuzikaBubbleState();
}

class _MuzikaBubbleState extends State<_MuzikaBubble> {
  Timer? _clock;
  bool _ready = StoryReminder.isReady;
  bool _there = StoryReminder.isAvailable;

  @override
  void initState() {
    super.initState();
    // 9 pm can arrive while Home is open.
    _clock = Timer.periodic(const Duration(minutes: 1), (_) => _update());
    StoryReminder.seen.addListener(_update);
    StoryReminder.openRequested.addListener(_openFromNotification);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _openFromNotification(),
    );
  }

  @override
  void dispose() {
    _clock?.cancel();
    StoryReminder.seen.removeListener(_update);
    StoryReminder.openRequested.removeListener(_openFromNotification);
    super.dispose();
  }

  void _update() {
    final ready = StoryReminder.isReady;
    final there = StoryReminder.isAvailable;
    if (mounted && (ready != _ready || there != _there)) {
      setState(() {
        _ready = ready;
        _there = there;
      });
    }
  }

  void _openFromNotification() {
    if (!mounted || !StoryReminder.openRequested.value) return;
    StoryReminder.openRequested.value = false;
    _openStory();
  }

  void _openStory() {
    StoryReminder.markSeen();
    unawaited(openDailyStory(context));
  }

  @override
  Widget build(BuildContext context) {
    if (!_there) return const SizedBox.shrink();
    return _Bubble(
      photo: '',
      label: 'Your day',
      watched: !_ready,
      onTap: _openStory,
      // The app's icon: the white logo on near-black.
      child: const CircleAvatar(
        backgroundColor: Color(0xFF191919),
        child: Padding(
          padding: EdgeInsets.all(12),
          child: MuzikaLogo(height: 22, color: Colors.white),
        ),
      ),
    );
  }
}
