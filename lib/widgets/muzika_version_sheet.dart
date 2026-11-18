/*
 *     Copyright (C) 2026 Valeri Gokadze
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
import 'package:muzika/constants/clients.dart';
import 'package:muzika/main.dart' show audioHandler;
import 'package:muzika/services/common_services.dart';
import 'package:muzika/services/desktop_panels.dart';
import 'package:muzika/services/muzika_downloads.dart';
import 'package:muzika/services/proxy_manager.dart' show ytClient;
import 'package:muzika/theme/muzika_tokens.dart';
import 'package:muzika/utilities/flutter_toast.dart';

/// "Wrong version?": the YouTube uploads found for [song], to pick the right
/// recording when the one playing is an AI copy, a cover or another edit.
/// The pick is kept for good; a channel can be blocked for every song.
Future<void> showVersionPicker(BuildContext context, Map song) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    // Wide Windows layout: the sheet opens in the part it came from.
    useRootNavigator: !desktopPanels.value,
    builder: (_) => _VersionSheet(song: song, outer: context),
  );
}

String _length(Duration? d) {
  if (d == null) return '';
  final s = d.inSeconds;
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = (s % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$sec' : '$m:$sec';
}

class _VersionSheet extends StatefulWidget {
  const _VersionSheet({required this.song, required this.outer});

  final Map song;

  /// Where the toast shows once the sheet has closed.
  final BuildContext outer;

  @override
  State<_VersionSheet> createState() => _VersionSheetState();
}

class _VersionSheetState extends State<_VersionSheet> {
  late final String _songId = '${widget.song['ytid'] ?? ''}';
  late final String _current = currentVersionOf(_songId);
  late final Future<List<SongVersion>> _versions = findSongVersions(
    ytClient,
    widget.song,
  );

  Future<void> _use(SongVersion version) async {
    Navigator.of(context).pop();
    chooseSongVersion(_songId, version);
    await invalidateSongStreamCache(_songId);
    // A saved copy of the old version would keep playing: save the new one.
    final downloaded = isSongDownloaded(_songId);
    if (isSongAlreadyOffline(_songId)) await removeSongFromOffline(_songId);
    final playing = '${audioHandler.currentSong?['ytid'] ?? ''}' == _songId;
    if (widget.outer.mounted) {
      showToast(
        widget.outer,
        playing
            ? 'Playing the version from ${version.author}'
            : 'This song now plays the version from ${version.author}',
        icon: FluentIcons.checkmark_circle_20_regular,
      );
    }
    if (playing) await audioHandler.reloadCurrentSong();
    if (downloaded) unawaited(downloadSong(widget.song));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = scheme.onSurfaceVariant;
    final title = '${widget.song['title'] ?? ''}';
    final artist = '${widget.song['artist'] ?? ''}';
    final songLength = songLengthOf(widget.song);
    final albumLength = songLength == null
        ? ''
        : ' · album track ${_length(songLength)}';
    final maxHeight = MediaQuery.sizeOf(context).height * 0.8;

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 2),
              child: Text(
                'Pick the right version',
                style: muzikaBody(17, weight: 700),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Text(
                '$title · $artist$albumLength',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: muzikaBody(12.5, color: muted),
              ),
            ),
            Flexible(
              child: FutureBuilder<List<SongVersion>>(
                future: _versions,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Padding(
                      padding: EdgeInsets.all(28),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  final found = snap.data ?? const <SongVersion>[];
                  final close = found.where((v) => v.close).toList();
                  final other = found.where((v) => !v.close).toList();
                  return ListView(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    children: [
                      if (found.isEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                          child: Text(
                            'No other uploads of this song found.',
                            style: muzikaBody(14, color: muted),
                          ),
                        ),
                      for (final v in close) _row(v, scheme),
                      if (other.isNotEmpty) ...[
                        if (close.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
                            child: Text(
                              'Other results',
                              style: muzikaBody(
                                13,
                                weight: 600,
                                color: muted,
                              ),
                            ),
                          ),
                        for (final v in other) _row(v, scheme),
                      ],
                    ],
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _row(SongVersion v, ColorScheme scheme) {
    final muted = scheme.onSurfaceVariant;
    final playing = v.id == _current;
    final details = [
      v.author,
      _length(v.duration),
      if (v.views != null) v.views!,
    ].where((s) => s.isNotEmpty).join(' · ');
    return InkWell(
      onTap: playing ? null : () => _use(v),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(5),
              child: Image.network(
                'https://i.ytimg.com/vi/${v.id}/mqdefault.jpg',
                width: 72,
                height: 40,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Container(
                  width: 72,
                  height: 40,
                  color: scheme.surfaceContainerHigh,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    v.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: muzikaBody(14.5, weight: 500),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    details,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: muzikaBody(12, color: muted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            if (playing)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '${audioHandler.currentSong?['ytid'] ?? ''}' == _songId
                      ? 'Playing'
                      : 'Current',
                  style: muzikaBody(11.5, weight: 500, color: muted),
                ),
              )
            else
              Icon(FluentIcons.circle_20_regular, size: 20, color: muted),
          ],
        ),
      ),
    );
  }
}
