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

import 'package:hive_flutter/hive_flutter.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muzika/services/itunes_catalog.dart';
import 'package:muzika/services/router_service.dart';

/// A clip picked elsewhere (an artist's Clips row, Liked clips) for the
/// Clips tab to show first; the feed carries on after it.
final clipRequest = ValueNotifier<AppleClip?>(null);

/// Opens the Clips tab on [clip].
void openClip(AppleClip clip) {
  clipRequest.value = clip;
  NavigationManager.router.go(NavigationManager.discoverPath);
}

// ---------------------------------------------------------------------------
// Liked clips
// ---------------------------------------------------------------------------

const _likedKey = 'likedClips';

/// Clips liked in the Clips tab, newest first (shown in Liked songs).
final likedClips = ValueNotifier<List<AppleClip>>(_readLiked());

List<AppleClip> _readLiked() {
  final raw = Hive.box('user').get(_likedKey);
  if (raw is! List) return [];
  return [
    for (final e in raw)
      if (e is Map && e['song'] is Map && e['url'] is String)
        (
          song: _plain(e['song']) as Map<String, dynamic>,
          url: e['url'] as String,
        ),
  ];
}

/// Hive gives maps back as Map<dynamic, dynamic>, all the way down.
Object? _plain(Object? v) => switch (v) {
  final Map m => <String, dynamic>{
    for (final e in m.entries) '${e.key}': _plain(e.value),
  },
  final List l => [for (final e in l) _plain(e)],
  _ => v,
};

bool isClipLiked(String ytid) =>
    likedClips.value.any((c) => '${c.song['ytid']}' == ytid);

/// Keeps or forgets [clip] as liked.
void setClipLiked(AppleClip clip, bool liked) {
  final id = '${clip.song['ytid']}';
  final list = [
    if (liked) clip,
    ...likedClips.value.where((c) => '${c.song['ytid']}' != id),
  ].take(200).toList();
  likedClips.value = list;
  unawaited(
    Hive.box('user').put(_likedKey, [
      for (final c in list) {'song': c.song, 'url': c.url},
    ]),
  );
}
