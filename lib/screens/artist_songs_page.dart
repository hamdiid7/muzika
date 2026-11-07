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
import 'package:material_ui/material_ui.dart';
import 'package:muzika/main.dart' show audioHandler;
import 'package:muzika/services/deezer_catalog.dart';
import 'package:muzika/theme/muzika_tokens.dart';
import 'package:muzika/widgets/mini_player_bottom_space.dart';
import 'package:muzika/widgets/muzika_song_row.dart';

/// A Deezer artist's songs, most played first, ten at a time: the first ten
/// show as soon as they come (not after every album has been read), and
/// "See more" brings the next ten.
class ArtistSongsPage extends StatefulWidget {
  const ArtistSongsPage({
    super.key,
    required this.artistId,
    required this.name,
  });

  /// The Deezer artist ("deezer-artist-…").
  final String artistId;
  final String name;

  @override
  State<ArtistSongsPage> createState() => _ArtistSongsPageState();
}

class _ArtistSongsPageState extends State<ArtistSongsPage> {
  static const _page = 10;

  final _songs = <Map>[];
  int _total = 0;
  bool _loading = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_more());
  }

  Future<void> _more() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final page = await deezerArtistSongsPage(
        widget.artistId,
        index: _songs.length,
        limit: _page,
      );
      if (!mounted) return;
      final seen = {for (final s in _songs) s['ytid']};
      setState(() {
        _songs.addAll(page.songs.where((s) => seen.add(s['ytid'])));
        _total = page.total;
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool get _hasMore => _songs.length < _total;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.name,
          style: muzikaHeading(20, color: scheme.onSurface),
        ),
      ),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Row(
                children: [
                  Text(
                    'All songs',
                    style: muzikaHeading(24, color: scheme.onSurface),
                  ),
                  const Spacer(),
                  MuzikaRoundButton(
                    icon: FluentIcons.play_24_filled,
                    filled: true,
                    tooltip: 'Play',
                    onPressed: () {
                      if (_songs.isEmpty) return;
                      unawaited(
                        audioHandler.addPlaylistToQueue(
                          List<Map>.from(_songs),
                          replace: true,
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
          SliverList.builder(
            itemCount: _songs.length,
            itemBuilder: (context, i) =>
                MuzikaSongRow(song: _songs[i], queue: _songs, index: i),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Center(
                child: _loading
                    ? const CircularProgressIndicator()
                    : _failed
                    ? TextButton(
                        onPressed: () => unawaited(_more()),
                        child: const Text("Couldn't load: try again"),
                      )
                    : _hasMore
                    ? FilledButton.tonal(
                        onPressed: () => unawaited(_more()),
                        child: const Text('See more'),
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          ),
          const SliverToBoxAdapter(child: MiniPlayerBottomSpace()),
        ],
      ),
    );
  }
}
