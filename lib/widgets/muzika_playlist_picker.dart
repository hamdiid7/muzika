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
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muzika/services/common_services.dart';
import 'package:muzika/services/desktop_panels.dart';
import 'package:muzika/services/listening_stats.dart';
import 'package:muzika/services/playlists_manager.dart';
import 'package:muzika/theme/muzika_tokens.dart';
import 'package:muzika/widgets/muzika_song_row.dart';

/// "Save to playlist" in the Muzika style (design: Playlist Creation): a
/// rounded sheet with a name field that creates a playlist on Enter, then
/// your playlists as rows whose round button turns into a check when the
/// song is in them. Tapping a row toggles it; nothing needs confirming.
Future<void> showMuzikaPlaylistPicker(
  BuildContext context, {
  Map? song,
  List<dynamic>? songs,
}) {
  final items = <Map>[if (song != null) song, ...?songs?.whereType<Map>()];
  if (items.isEmpty) return Future.value();
  return showModalBottomSheet<void>(
    context: context,
    // Wide Windows layout: the sheet opens in the part it came from.
    useRootNavigator: !desktopPanels.value,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _PlaylistPicker(songs: items),
  );
}

/// A small rounded sheet with one name field, in the same style as the
/// player's "Save to playlist" sheet. Used by Library for new playlists and
/// folders. [onSubmit] gets the trimmed name.
Future<void> showMuzikaNameSheet(
  BuildContext context, {
  required String title,
  required String hint,
  required ValueChanged<String> onSubmit,
}) {
  return showModalBottomSheet<void>(
    context: context,
    // Wide Windows layout: the sheet opens in the part it came from.
    useRootNavigator: !desktopPanels.value,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _NameSheet(title: title, hint: hint, onSubmit: onSubmit),
  );
}

class _NameSheet extends StatefulWidget {
  const _NameSheet({
    required this.title,
    required this.hint,
    required this.onSubmit,
  });

  final String title;
  final String hint;
  final ValueChanged<String> onSubmit;

  @override
  State<_NameSheet> createState() => _NameSheetState();
}

class _NameSheetState extends State<_NameSheet> {
  final _name = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _name.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    unawaited(HapticFeedback.lightImpact());
    widget.onSubmit(name);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: const [0, 0.5],
            colors: dark
                ? [scheme.surfaceContainer, scheme.surfaceContainerLow]
                : [const Color(0xFFF3F3F5), scheme.surface],
          ),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  margin: const EdgeInsets.only(top: 12, bottom: 14),
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
                child: Text(
                  widget.title,
                  style: muzikaHeading(20, color: scheme.onSurface),
                ),
              ),
              _NameField(
                controller: _name,
                focusNode: _focus,
                saveState: '',
                hint: widget.hint,
                onSubmit: _submit,
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlaylistPicker extends StatefulWidget {
  const _PlaylistPicker({required this.songs});

  final List<Map> songs;

  @override
  State<_PlaylistPicker> createState() => _PlaylistPickerState();
}

class _PlaylistPickerState extends State<_PlaylistPicker> {
  final _name = TextEditingController();
  final _focus = FocusNode();

  /// '' idle, 'saving', 'saved'.
  String _saveState = '';

  /// Playlists created in this sheet go first, in creation order.
  final List<String> _createdHere = [];

  late final List<String> _order = _initialOrder();

  bool get _single => widget.songs.length == 1;
  Map get _song => widget.songs.first;

  @override
  void dispose() {
    _name.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Most-listened playlist first, then the rest as the library has them.
  List<String> _initialOrder() {
    final favorite = ListeningStats.instance.favoritePlaylist()?['ytid'];
    final ids = [for (final p in getUserCustomPlaylists()) '${p['ytid']}'];
    if (favorite != null && ids.remove('$favorite')) ids.insert(0, '$favorite');
    return ids;
  }

  List<Map> _playlists() {
    final byId = {for (final p in getUserCustomPlaylists()) '${p['ytid']}': p};
    return [
      for (final id in [..._createdHere.reversed, ..._order])
        if (byId.containsKey(id)) byId.remove(id)!,
      ...byId.values, // created elsewhere while the sheet was open
    ];
  }

  bool _contains(Map playlist) {
    final ids = {
      for (final s in playlist['list'] as List? ?? const [])
        if (s is Map) '${s['ytid']}',
    };
    return widget.songs.every((s) => ids.contains('${s['ytid']}'));
  }

  void _toggle(Map playlist) {
    unawaited(HapticFeedback.selectionClick());
    final id = '${playlist['ytid']}';
    if (_contains(playlist)) {
      for (final s in widget.songs) {
        removeSongFromPlaylist(playlist, s);
      }
    } else if (_single) {
      addSongInCustomPlaylist(context, id, _song);
    } else {
      addSongsInCustomPlaylist(context, id, widget.songs);
    }
    setState(() {});
  }

  void _toggleLiked() {
    unawaited(HapticFeedback.selectionClick());
    final ytid = '${_song['ytid']}';
    unawaited(
      updateSongLikeStatus(ytid, !isSongAlreadyLiked(ytid), songData: _song),
    );
  }

  Future<void> _create() async {
    final name = _name.text.trim();
    if (name.isEmpty || _saveState == 'saving') return;
    setState(() => _saveState = 'saving');
    final (_, id) = createCustomPlaylist(name, null, context);
    if (_single) {
      addSongInCustomPlaylist(context, id, _song);
    } else {
      addSongsInCustomPlaylist(context, id, widget.songs);
    }
    _createdHere.add(id);
    _name.clear();
    unawaited(HapticFeedback.lightImpact());
    await Future<void>.delayed(const Duration(milliseconds: 450));
    if (!mounted) return;
    setState(() => _saveState = 'saved');
    await Future<void>.delayed(const Duration(milliseconds: 1400));
    if (mounted && _saveState == 'saved') setState(() => _saveState = '');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final media = MediaQuery.of(context);
    final maxHeight = media.size.height * 0.78;

    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: const [0, 0.5],
              colors: dark
                  ? [scheme.surfaceContainer, scheme.surfaceContainerLow]
                  : [const Color(0xFFF3F3F5), scheme.surface],
            ),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    margin: const EdgeInsets.only(top: 12, bottom: 14),
                    width: 38,
                    height: 4,
                    decoration: BoxDecoration(
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
                  child: Text(
                    _single
                        ? 'Save “${_song['title'] ?? ''}”'
                        : 'Save ${widget.songs.length} songs',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: muzikaHeading(20, color: scheme.onSurface),
                  ),
                ),
                _NameField(
                  controller: _name,
                  focusNode: _focus,
                  saveState: _saveState,
                  onSubmit: _create,
                ),
                const SizedBox(height: 10),
                Flexible(
                  child: AnimatedBuilder(
                    animation: Listenable.merge([
                      userCustomPlaylists,
                      userPlaylistFolders,
                      userLikedSongsList,
                    ]),
                    builder: (context, _) {
                      final playlists = _playlists();
                      return ListView(
                        shrinkWrap: true,
                        padding: const EdgeInsets.only(bottom: 16),
                        children: [
                          if (_single)
                            _PickerRow(
                              title: 'Liked Songs',
                              subtitle:
                                  '${userLikedSongsList.value.length} songs',
                              cover: const _IconCover(
                                icon: FluentIcons.heart_24_filled,
                              ),
                              selected: isSongAlreadyLiked(_song['ytid']),
                              onTap: _toggleLiked,
                            ),
                          for (final playlist in playlists)
                            _PickerRow(
                              title: '${playlist['title'] ?? ''}',
                              subtitle: _subtitle(playlist),
                              cover: _PlaylistCover(playlist: playlist),
                              selected: _contains(playlist),
                              onTap: () => _toggle(playlist),
                            ),
                          if (playlists.isEmpty)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                              child: Text(
                                'Name a playlist above and press Enter to '
                                'create it.',
                                style: muzikaBody(
                                  13.5,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _subtitle(Map playlist) {
    final count = (playlist['list'] as List? ?? const []).length;
    final minutes =
        ListeningStats.instance.favoritePlaylist()?['ytid'] == playlist['ytid']
        ? ' · Most played'
        : '';
    return '$count ${count == 1 ? 'song' : 'songs'}$minutes';
  }
}

/// The grey name field of the design, with "Saving…" on the right.
class _NameField extends StatelessWidget {
  const _NameField({
    required this.controller,
    required this.focusNode,
    required this.saveState,
    required this.onSubmit,
    this.hint = 'New playlist',
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String saveState;
  final VoidCallback onSubmit;
  final String hint;

  static const _accent = Color(0xFF2F80ED);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        height: 52,
        padding: const EdgeInsets.only(left: 16, right: 14),
        decoration: BoxDecoration(
          color: dark ? scheme.surfaceContainerHigh : const Color(0xFFE6E6EA),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(
              FluentIcons.add_24_regular,
              size: 20,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                textInputAction: TextInputAction.done,
                textCapitalization: TextCapitalization.sentences,
                style: muzikaBody(16, color: scheme.onSurface),
                cursorColor: scheme.onSurface,
                decoration: InputDecoration(
                  isCollapsed: true,
                  border: InputBorder.none,
                  hintText: hint,
                  hintStyle: muzikaBody(16, color: scheme.onSurfaceVariant),
                ),
                onSubmitted: (_) => onSubmit(),
              ),
            ),
            ListenableBuilder(
              listenable: controller,
              builder: (context, _) {
                final label = switch (saveState) {
                  'saving' => 'Saving…',
                  'saved' => 'Saved',
                  _ when controller.text.trim().isNotEmpty => 'Create',
                  _ => '',
                };
                return AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  child: GestureDetector(
                    key: ValueKey(label),
                    onTap: label == 'Create' ? onSubmit : null,
                    child: Text(
                      label,
                      style: muzikaBody(14, weight: 500, color: _accent),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _PickerRow extends StatelessWidget {
  const _PickerRow({
    required this.title,
    required this.subtitle,
    required this.cover,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final Widget cover;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Row(
          children: [
            cover,
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: muzikaBody(16, weight: 500, color: scheme.onSurface),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: 1,
                    style: muzikaBody(12.5, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected
                    ? scheme.onSurface
                    : (scheme.brightness == Brightness.dark
                          ? scheme.surfaceContainerHighest
                          : const Color(0xFFE2E2E6)),
              ),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 160),
                transitionBuilder: (child, a) =>
                    ScaleTransition(scale: a, child: child),
                child: Icon(
                  selected
                      ? FluentIcons.checkmark_24_regular
                      : FluentIcons.add_24_regular,
                  key: ValueKey(selected),
                  size: 22,
                  color: selected ? scheme.surface : scheme.onSurface,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A playlist's cover: its own image, else its first song's art.
class _PlaylistCover extends StatelessWidget {
  const _PlaylistCover({required this.playlist});

  final Map playlist;

  @override
  Widget build(BuildContext context) {
    final image = playlist['image']?.toString();
    final songs = playlist['list'] as List? ?? const [];
    final first = songs.whereType<Map>().firstOrNull;
    if ((image == null || image.isEmpty) && first == null) {
      return const _IconCover(icon: FluentIcons.music_note_2_24_regular);
    }
    return MuzikaCover(
      song: (image != null && image.isNotEmpty)
          ? {'image': image, 'lowResImage': image}
          : first!,
      size: 52,
    );
  }
}

class _IconCover extends StatelessWidget {
  const _IconCover({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        color: scheme.onSurface,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(icon, color: scheme.surface, size: 24),
    );
  }
}
