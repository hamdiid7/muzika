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
import 'package:muzika/services/artist_service.dart';
import 'package:muzika/services/deezer_catalog.dart';
import 'package:muzika/theme/muzika_tokens.dart';
import 'package:muzika/widgets/mini_player_bottom_space.dart';
import 'package:muzika/widgets/muzika_song_row.dart';

/// Every song of a Deezer artist. Their most played come first, as soon as
/// they arrive; then the rest of every album and single, read in the
/// background. (Deezer's own "top" list alone holds only the songs that
/// were played there: a few for many Ethiopian artists.)
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
  final _songs = <Map>[];
  final _ids = <String>{};
  final _names = <String>{};

  /// The rest of the albums are still being read.
  bool _loading = true;

  /// Nothing at all could be read.
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  String _name(Map song) => '${song['title'] ?? ''}'
      .toLowerCase()
      .replaceAll(RegExp(r'\(.*?\)|\[.*?\]'), '')
      .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '');

  /// Adds the songs not already listed (the same song can be on an album
  /// and a single, or in the top list and an album).
  void _add(Iterable<Map> songs) {
    for (final song in songs) {
      final id = '${song['ytid'] ?? ''}';
      final name = _name(song);
      if (id.isEmpty || _ids.contains(id)) continue;
      if (name.isNotEmpty && _names.contains(name)) continue;
      _ids.add(id);
      if (name.isNotEmpty) _names.add(name);
      _songs.add(song);
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    // The most played, quickly.
    final top = deezerArtistSongsPage(widget.artistId, limit: 25)
        .then((page) {
          if (!mounted) return;
          setState(() => _add(page.songs));
        })
        .catchError((_) {});
    // Every album's songs, which takes longer.
    final all = () async {
      final profile = await getArtistProfile(
        widget.artistId,
        preferredName: widget.name,
      );
      if (profile == null) return;
      final catalog = await getArtistCatalogFromProfile(profile);
      final list = (catalog?['list'] as List? ?? const []).whereType<Map>();
      await top;
      if (!mounted) return;
      setState(() => _add(list));
    }().catchError((_) {});
    await Future.wait([top, all]);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _failed = _songs.isEmpty;
    });
  }

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
                    _loading || _songs.isEmpty
                        ? 'All songs'
                        : 'All ${_songs.length} songs',
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
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            _songs.isEmpty
                                ? 'Loading songs…'
                                : 'Loading the rest of the albums…',
                            style: muzikaBody(
                              14,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      )
                    : _failed
                    ? TextButton(
                        onPressed: () => unawaited(_load()),
                        child: const Text("Couldn't load: try again"),
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
