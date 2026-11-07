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
import 'package:hive_flutter/hive_flutter.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muzika/services/playlists_manager.dart';
import 'package:muzika/utilities/flutter_toast.dart';

/// How Muzika clears and deletes: no "are you sure?". It's done at once and
/// a bar says so, with Undo for five seconds. [undo] puts back what was
/// taken out of the lists; [commit] is the part that can't be taken back
/// (files erased, stats wiped), run only once the bar has gone without
/// Undo.
void doWithUndo(
  BuildContext context,
  String message, {
  VoidCallback? undo,
  Future<void> Function()? commit,
}) {
  var undone = false;
  final bar = showMuzikaMessage(
    context,
    message,
    icon: FluentIcons.delete_20_regular,
    actionLabel: 'Undo',
    onAction: () {
      undone = true;
      undo?.call();
    },
    duration: const Duration(seconds: 5),
  );
  unawaited(
    bar.closed.then((_) async {
      if (!undone && commit != null) await commit();
    }),
  );
}

/// The library's playlists, folders and pins as they are now: calling the
/// result puts them all back (in memory and on disk), for Undo after a
/// playlist or folder is removed.
VoidCallback keepLibraryForUndo() {
  Object? copy(Object? v) => v is Map
      ? {for (final e in v.entries) e.key: copy(e.value)}
      : v is List
      ? [for (final e in v) copy(e)]
      : v;
  final kept = <(ValueNotifier<dynamic>, String, Object?)>[
    (userPlaylists, 'playlists', copy(userPlaylists.value)),
    (userCustomPlaylists, 'customPlaylists', copy(userCustomPlaylists.value)),
    (userLikedPlaylists, 'likedPlaylists', copy(userLikedPlaylists.value)),
    (userPlaylistFolders, 'playlistFolders', copy(userPlaylistFolders.value)),
    (pinnedPlaylistIds, 'pinnedPlaylistIds', copy(pinnedPlaylistIds.value)),
    (
      syncedPlaylistDetails,
      'playlistDetails',
      copy(syncedPlaylistDetails.value),
    ),
  ];
  return () {
    final box = Hive.box('user');
    for (final (notifier, key, value) in kept) {
      final list = value! as List;
      notifier.value = notifier is ValueNotifier<List<String>>
          ? List<String>.from(list)
          : List<Map>.from(list);
      unawaited(box.put(key, list));
    }
  };
}
