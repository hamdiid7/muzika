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
import 'dart:ui' show ImageFilter;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart';
import 'package:muzika/services/analytics.dart';
import 'package:muzika/main.dart' show audioHandler;
import 'package:muzika/services/deezer_catalog.dart' show deezerArtistPhoto;
import 'package:muzika/services/muzika_home.dart';
import 'package:muzika/services/router_service.dart';
import 'package:muzika/services/story_cache.dart';
import 'package:muzika/utilities/image_size.dart';
import 'package:muzika/services/youtube_canvas.dart';
import 'package:muzika/services/youtube_trending.dart';
import 'package:muzika/theme/muzika_tokens.dart';
import 'package:muzika/widgets/discover_video_card.dart' show ClipActions;
import 'package:muzika/widgets/story_row.dart';

/// "JISOO", "Lady Gaga and Doechii", "A, B and C".
String _names(List<String> names) => switch (names.length) {
  0 => '',
  1 => names.first,
  _ => '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}',
};

/// The story's artists' photos side by side, overlapping (at most three):
/// the first is the uploader's channel photo, the others come from Deezer.
class _CollabAvatars extends StatelessWidget {
  const _CollabAvatars({required this.video});

  final TrendingVideo video;

  static const _size = 32.0;
  static const _step = 20.0;

  @override
  Widget build(BuildContext context) {
    final names = video.collaborators.take(3).toList();
    Widget ring(Widget child) => Container(
      width: _size,
      height: _size,
      padding: const EdgeInsets.all(1.5),
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.black,
      ),
      child: ClipOval(child: child),
    );
    Widget initial(String name) => ColoredBox(
      color: Colors.white24,
      child: Center(
        child: Text(
          name.isEmpty ? '?' : name[0].toUpperCase(),
          style: muzikaBody(13, weight: 700, color: Colors.white),
        ),
      ),
    );
    return SizedBox(
      width: _size + _step * (names.length - 1).clamp(0, 2),
      height: _size,
      child: Stack(
        children: [
          // The last drawn first, so the main artist sits on top.
          for (var i = names.length - 1; i >= 0; i--)
            Positioned(
              left: _step * i,
              child: ring(
                i == 0
                    ? CachedNetworkImage(
                        imageUrl: video.photo,
                        fit: BoxFit.cover,
                        errorWidget: (_, _, _) => initial(names[i]),
                      )
                    : FutureBuilder<String?>(
                        future: _photoOf(names[i]),
                        builder: (context, snapshot) {
                          final photo = snapshot.data;
                          if (photo == null) return initial(names[i]);
                          return CachedNetworkImage(
                            imageUrl: sizedImageUrl(photo, 96),
                            fit: BoxFit.cover,
                            errorWidget: (_, _, _) => initial(names[i]),
                          );
                        },
                      ),
              ),
            ),
        ],
      ),
    );
  }

  static final _photos = <String, Future<String?>>{};

  static Future<String?> _photoOf(String name) =>
      _photos[name.toLowerCase()] ??= deezerArtistPhoto(name)
          .catchError((_) => null);
}

/// Opens the stories at [start], over everything (on a wide window as a
/// phone-shaped card in the middle).
Future<void> openStories(
  BuildContext context,
  List<HomeStory> stories,
  int start,
) {
  track('story_opened', {
    'artist': stories[start].video.artist,
    'count': stories.length,
  });
  return Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.black87,
      transitionDuration: const Duration(milliseconds: 250),
      reverseTransitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (_, _, _) =>
          StoryViewerPage(stories: stories, initial: start),
      transitionsBuilder: (_, animation, _, child) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: Tween(begin: 0.94, end: 1.0).animate(
            CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
          ),
          child: child,
        ),
      ),
    ),
  );
}

/// The stories, one artist after another: 10 seconds of each one's new
/// music video with its sound, a third of the way in. Tap the right side
/// for the next, the left for the one before; swipe sideways to change
/// artist, hold to pause, swipe down to close. The music playing pauses
/// meanwhile and comes back after.
class StoryViewerPage extends StatefulWidget {
  const StoryViewerPage({
    super.key,
    required this.stories,
    required this.initial,
  });

  final List<HomeStory> stories;
  final int initial;

  @override
  State<StoryViewerPage> createState() => _StoryViewerPageState();
}

class _StoryViewerPageState extends State<StoryViewerPage>
    with SingleTickerProviderStateMixin {
  /// How long each story plays.
  static const _length = Duration(seconds: 10);

  late final _pages = PageController(initialPage: widget.initial);
  late int _index = widget.initial;

  // Only the 10 s slice is wanted, not mpv's usual 32 MB read-ahead.
  final _player = mk.Player(
    configuration: const mk.PlayerConfiguration(bufferSize: 6 * 1024 * 1024),
  );
  late final _view = VideoController(_player);
  late final _progress = AnimationController(vsync: this, duration: _length)
    ..addStatusListener((status) {
      if (status == AnimationStatus.completed) _next();
    });

  bool _ready = false;
  int _token = 0;
  late final bool _musicWasPlaying = audioHandler.playbackState.value.playing;

  /// A song was started from a story: the old one doesn't come back.
  bool _playedSong = false;

  @override
  void initState() {
    super.initState();
    if (_musicWasPlaying) unawaited(audioHandler.pause());
    // Once on screen: starting it marks it seen, which redraws Home's row.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_show(_index));
    });
  }

  @override
  void dispose() {
    _token++;
    _progress.dispose();
    _pages.dispose();
    unawaited(_player.dispose());
    if (_musicWasPlaying && !_playedSong) unawaited(audioHandler.play());
    super.dispose();
  }

  /// Where a story's 10 s start: a third of the way into its video.
  Duration _startOf(TrendingVideo v) =>
      sliceStart(v.length ?? Duration.zero, _length);

  /// Starts story [index]: its clip from disk (saved the first time it's
  /// shown, only those 10 s downloaded), else its video streamed. The next
  /// two are saved meanwhile, so they start at once.
  Future<void> _show(int index) async {
    final token = ++_token;
    _progress
      ..stop()
      ..reset();
    setState(() => _ready = false);
    final video = widget.stories[index].video;
    markStorySeen(video.id);
    unawaited(_player.stop());
    // A release with no video: its cover, and Deezer's 30 s of it.
    if (!video.isVideo) {
      await _player.open(
        mk.Media('${widget.stories[index].song['preview']}'),
        play: false,
      );
      if (!mounted || token != _token) return;
      await _player.play();
      // play() returns before the preview has come in: the 10 s count from
      // when it's heard.
      await _player.stream.position
          .firstWhere((p) => p > Duration.zero, orElse: () => Duration.zero)
          .timeout(const Duration(seconds: 15), onTimeout: () => Duration.zero);
      if (!mounted || token != _token) return;
      setState(() => _ready = true);
      unawaited(_progress.forward(from: 0));
      unawaited(_saveAhead(index));
      return;
    }
    // Saved before: from disk. Not yet: streamed now, and saved once it
    // plays, for next time (waiting for the save would hold it up).
    final clip = await savedStoryClip(video.id).catchError((_) => null);
    if (!mounted || token != _token) return;
    if (clip != null) {
      // Opened paused: picture and sound start together below.
      // Both files hold the story's 10 s but begin where their own pieces
      // do (the picture's and the sound's differ by a second or two): both
      // start at the story's own start.
      await _player.open(
        mk.Media(clip.video.uri.toString(), start: _startOf(video)),
        play: false,
      );
      if (clip.audio != null) {
        await _player.setAudioTrack(
          mk.AudioTrack.uri(clip.audio!.uri.toString()),
        );
      }
    } else {
      final streams = await youtubeStreamsFor(
        video.id,
        audio: true,
      ).catchError((_) => null);
      if (!mounted || token != _token) return;
      if (streams == null) {
        // Can't be played here: on to the next.
        return _next();
      }
      final native = _player.platform;
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
      // Opened paused: the sound (a small stream of its own) would
      // otherwise start while the picture is still on its way.
      await _player.open(
        mk.Media(
          streams.video,
          httpHeaders: streams.headers,
          start: _startOf(video),
        ),
        play: false,
      );
      if (streams.audio != null) {
        await _player.setAudioTrack(mk.AudioTrack.uri(streams.audio!));
      }
    }
    // Both start once the first frame is in and the start is buffered;
    // the 10 s are counted from then, not from the tap.
    await _player.stream.width
        .firstWhere((w) => (w ?? 0) > 0, orElse: () => 0)
        .timeout(const Duration(seconds: 20), onTimeout: () => 0);
    if (_player.state.buffering) {
      await _player.stream.buffering
          .firstWhere((b) => !b, orElse: () => false)
          .timeout(const Duration(seconds: 15), onTimeout: () => false);
    }
    if (!mounted || token != _token) return;
    await _player.play();
    if (!mounted || token != _token) return;
    setState(() => _ready = true);
    unawaited(_progress.forward(from: 0));
    unawaited(_saveAhead(index));
  }

  /// The artists on the story's song, in a sheet (the story waits): a tap
  /// closes the stories and opens that artist's page.
  Future<void> _showArtists(TrendingVideo video) async {
    _hold(true);
    final names = video.collaborators;
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 10, bottom: 6),
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white38,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
              child: Text(
                names.length > 1 ? 'Artists on this song' : 'Artist',
                style: muzikaHeading(18, color: Colors.white),
              ),
            ),
            for (final (i, name) in names.indexed)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                leading: SizedBox(
                  width: 44,
                  height: 44,
                  child: ClipOval(
                    child: i == 0
                        ? CachedNetworkImage(
                            imageUrl: video.photo,
                            fit: BoxFit.cover,
                          )
                        : FutureBuilder<String?>(
                            future: _CollabAvatars._photoOf(name),
                            builder: (context, snapshot) =>
                                snapshot.data == null
                                ? const ColoredBox(color: Colors.white24)
                                : CachedNetworkImage(
                                    imageUrl: sizedImageUrl(
                                      snapshot.data!,
                                      120,
                                    ),
                                    fit: BoxFit.cover,
                                  ),
                          ),
                  ),
                ),
                title: Text(
                  name,
                  style: muzikaBody(16, weight: 600, color: Colors.white),
                ),
                trailing: const Icon(
                  FluentIcons.chevron_right_24_regular,
                  color: Colors.white54,
                ),
                onTap: () => Navigator.of(sheet).pop(name),
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (picked == null) return _hold(false);
    Navigator.of(context).pop();
    unawaited(
      NavigationManager.router.push(
        '${NavigationManager.currentBasePath}/artist/'
        '${Uri.encodeComponent(picked)}',
        extra: {'title': picked},
      ),
    );
  }

  /// Saves this story's clip (when it streamed) and the next two, one after
  /// the other; those already saved cost nothing.
  Future<void> _saveAhead(int index) async {
    for (var i = index; i <= index + 2 && i < widget.stories.length; i++) {
      final video = widget.stories[i].video;
      if (!video.isVideo) continue;
      await storyClip(
        video.id,
        _startOf(video),
        _length,
      ).catchError((_) => null);
      if (!mounted) return;
    }
  }

  void _next() {
    if (!mounted) return;
    if (_index + 1 < widget.stories.length) {
      unawaited(
        _pages.nextPage(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        ),
      );
    } else {
      Navigator.of(context).pop();
    }
  }

  void _previous() {
    if (_index > 0) {
      unawaited(
        _pages.previousPage(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        ),
      );
    } else {
      unawaited(_show(_index));
    }
  }

  void _hold(bool on) {
    if (!_ready) return;
    if (on) {
      _progress.stop();
      unawaited(_player.pause());
    } else {
      unawaited(_progress.forward());
      unawaited(_player.play());
    }
  }

  /// Plays the story's song: the catalog's (its cover, the official
  /// audio), found when the stories were picked.
  void _play() {
    _playedSong = true;
    final song = widget.stories[_index].song;
    track('story_play', {
      'title': '${song['title'] ?? ''}',
      'artist': '${song['artist'] ?? ''}',
    });
    Navigator.of(context).pop();
    unawaited(audioHandler.addPlaylistToQueue([song], replace: true));
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final pages = PageView.builder(
      controller: _pages,
      itemCount: widget.stories.length,
      onPageChanged: (i) {
        _index = i;
        unawaited(_show(i));
      },
      itemBuilder: (context, i) => _page(i),
    );
    // A wide window shows the stories as a phone-shaped card.
    if (size.width > 700) {
      final height = size.height - 48;
      return Center(
        child: SizedBox(
          height: height,
          width: height * 9 / 16,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: Material(color: Colors.black, child: pages),
          ),
        ),
      );
    }
    return Material(
      color: Colors.black,
      child: SafeArea(child: pages),
    );
  }

  Widget _page(int i) {
    final story = widget.stories[i];
    final video = story.video;
    final active = i == _index;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (!video.isVideo)
          // A release with no video: its cover over a blurred copy of it,
          // as Instagram shows a song.
          Stack(
            fit: StackFit.expand,
            children: [
              ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                child: CachedNetworkImage(
                  imageUrl: video.thumbnail,
                  fit: BoxFit.cover,
                ),
              ),
              const ColoredBox(color: Colors.black26),
              Center(
                child: FractionallySizedBox(
                  widthFactor: 0.72,
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: CachedNetworkImage(
                        imageUrl: video.thumbnail,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          )
        else
          // The wide (16:9) still while the video loads: the usual one
          // carries black bars. Older uploads lack it: then the usual one.
          CachedNetworkImage(
            imageUrl: 'https://i.ytimg.com/vi/${video.id}/hq720.jpg',
            fit: BoxFit.cover,
            errorWidget: (_, _, _) => CachedNetworkImage(
              imageUrl: video.thumbnail,
              fit: BoxFit.cover,
            ),
          ),
        if (!video.isVideo)
          const SizedBox.shrink()
        else if (active && _ready)
          ClipRect(
            child: Transform.scale(
              // Pushes a wide video's black bars off the edge.
              scale: 1.3,
              child: Video(
                controller: _view,
                fit: BoxFit.cover,
                controls: NoVideoControls,
                fill: Colors.black,
              ),
            ),
          )
        else if (active)
          const Center(child: CircularProgressIndicator(color: Colors.white)),
        // Shades for the words at the top and the bottom.
        const IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: [0, 0.18, 0.6, 1],
                colors: [
                  Colors.black54,
                  Colors.transparent,
                  Colors.transparent,
                  Colors.black87,
                ],
              ),
            ),
          ),
        ),
        // Taps: right for the next, left for the one before; hold to
        // pause; down to close.
        // (Measured on the story itself: on a wide window it's a card in
        // the middle, much narrower than the page.)
        LayoutBuilder(
          builder: (context, box) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (details) {
              if (details.localPosition.dx < box.maxWidth / 3) {
                _previous();
              } else {
                _next();
              }
            },
            onLongPressStart: (_) => _hold(true),
            onLongPressEnd: (_) => _hold(false),
            onVerticalDragEnd: (details) {
              if ((details.primaryVelocity ?? 0) > 300) {
                Navigator.of(context).pop();
              }
            },
          ),
        ),
        Positioned(top: 0, left: 0, right: 0, child: _top(video, active)),
        Positioned(left: 0, right: 0, bottom: 0, child: _bottom(story, video)),
      ],
    );
  }

  /// One bar per story along the top, then who it's by and when.
  Widget _top(TrendingVideo video, bool active) {
    // One bar per story of this artist (theirs play in a row, then the
    // next artist's).
    final key = storyArtistKey(widget.stories[_index]);
    var first = _index;
    while (first > 0 && storyArtistKey(widget.stories[first - 1]) == key) {
      first--;
    }
    var end = _index + 1;
    while (end < widget.stories.length &&
        storyArtistKey(widget.stories[end]) == key) {
      end++;
    }
    final count = end - first;
    final at = _index - first;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 10, 4, 0),
      child: Column(
        children: [
          Row(
            children: [
              for (var j = 0; j < count; j++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 1.5),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: AnimatedBuilder(
                        animation: _progress,
                        builder: (_, _) => LinearProgressIndicator(
                          minHeight: 2.5,
                          value: j < at
                              ? 1
                              : j > at
                              ? 0
                              : (active ? _progress.value : 0),
                          color: Colors.white,
                          backgroundColor: Colors.white30,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              // As Instagram's collab posts: everyone's photo, overlapping,
              // and their names together; a tap lists them.
              Flexible(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => unawaited(_showArtists(video)),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _CollabAvatars(video: video),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          _names(video.collaborators),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: muzikaBody(
                            14,
                            weight: 700,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Text(
                '  ${video.ageLabel}',
                style: muzikaBody(13, color: Colors.white70),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Close',
                icon: const Icon(
                  FluentIcons.dismiss_24_regular,
                  color: Colors.white,
                ),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// As under a clip: the song's cover, title and artist (a tap plays it),
  /// and its buttons: save (long press: a playlist), like, download, share.
  Widget _bottom(HomeStory story, TrendingVideo video) {
    final song = story.song;
    final cover = '${song['lowResImage'] ?? song['image'] ?? video.thumbnail}';
    final album = '${song['album'] ?? ''}'.trim();
    final artist = video.credit;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 12, 18),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: _play,
              behavior: HitTestBehavior.opaque,
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: SizedBox(
                      width: 42,
                      height: 42,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          CachedNetworkImage(
                            imageUrl: cover,
                            fit: BoxFit.cover,
                            fadeInDuration: Duration.zero,
                          ),
                          const ColoredBox(color: Colors.black26),
                          const Icon(
                            FluentIcons.play_20_filled,
                            color: Colors.white,
                            size: 20,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          video.songTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: muzikaBody(
                            15,
                            weight: 700,
                            color: Colors.white,
                          ),
                        ),
                        Text(
                          [
                            artist,
                            if (album.isNotEmpty && album != video.songTitle)
                              album,
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: muzikaBody(13, color: Colors.white70),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          // The story waits while a button's sheet or dialog is open.
          Listener(
            onPointerDown: (_) => _hold(true),
            onPointerUp: (_) => unawaited(_resumeWhenBack()),
            child: ClipActions(song: song, color: Colors.white),
          ),
        ],
      ),
    );
  }

  /// Picks the story up again once whatever a button opened has closed.
  Future<void> _resumeWhenBack() async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    while (mounted && !(ModalRoute.of(context)?.isCurrent ?? true)) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    if (mounted) _hold(false);
  }
}
