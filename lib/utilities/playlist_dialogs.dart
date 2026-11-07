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
import 'package:muzika/extensions/l10n.dart';
import 'package:muzika/services/playlists_manager.dart';
import 'package:muzika/utilities/flutter_toast.dart';
import 'package:muzika/utilities/playlist_image_picker.dart';
import 'package:muzika/widgets/muzika_playlist_picker.dart';

void showCreatePlaylistDialog(
  BuildContext context, {
  dynamic songToAdd,
  List<dynamic>? songsToAdd,
}) {
  var id = '';
  var customPlaylistName = '';
  var isYouTubeMode = songToAdd == null && songsToAdd == null;
  String? imageUrl;
  String? imageBase64;

  showDialog(
    context: context,
    builder: (BuildContext context) {
      return StatefulBuilder(
        builder: (context, dialogSetState) {
          final colorScheme = Theme.of(context).colorScheme;

          Future<void> _pickImage() async {
            final result = await pickImage();
            if (result != null) {
              dialogSetState(() {
                imageBase64 = result;
                imageUrl = null;
              });
            }
          }

          Widget _imagePreview() {
            return buildImagePreview(
              imageBase64: imageBase64,
              imageUrl: imageUrl,
            );
          }

          return AlertDialog(
            icon: Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(
                FluentIcons.add_24_filled,
                color: colorScheme.primary,
                size: 32,
              ),
            ),
            title: Text(
              context.l10n!.addPlaylist,
              style: TextStyle(
                color: colorScheme.onSurface,
                fontWeight: FontWeight.w600,
                fontSize: 20,
              ),
              textAlign: TextAlign.center,
            ),
            titleTextStyle: TextStyle(
              color: colorScheme.onSurface,
              fontWeight: FontWeight.w600,
              fontSize: 20,
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (songToAdd == null && songsToAdd == null)
                    Container(
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      padding: const EdgeInsets.all(4),
                      child: Row(
                        children: [
                          Expanded(
                            child: GestureDetector(
                              onTap: () {
                                dialogSetState(() {
                                  isYouTubeMode = true;
                                  id = '';
                                  customPlaylistName = '';
                                  imageUrl = null;
                                  imageBase64 = null;
                                });
                              },
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 200),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                                decoration: BoxDecoration(
                                  color: isYouTubeMode
                                      ? colorScheme.primaryContainer
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      FluentIcons.globe_20_filled,
                                      size: 20,
                                      color: isYouTubeMode
                                          ? colorScheme.onPrimaryContainer
                                          : colorScheme.onSurfaceVariant,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      'YouTube',
                                      style: TextStyle(
                                        color: isYouTubeMode
                                            ? colorScheme.onPrimaryContainer
                                            : colorScheme.onSurfaceVariant,
                                        fontWeight: isYouTubeMode
                                            ? FontWeight.w600
                                            : FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          Expanded(
                            child: GestureDetector(
                              onTap: () {
                                dialogSetState(() {
                                  isYouTubeMode = false;
                                  id = '';
                                  customPlaylistName = '';
                                  imageUrl = null;
                                  imageBase64 = null;
                                });
                              },
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 200),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                                decoration: BoxDecoration(
                                  color: !isYouTubeMode
                                      ? colorScheme.primaryContainer
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      FluentIcons.person_20_filled,
                                      size: 20,
                                      color: !isYouTubeMode
                                          ? colorScheme.onPrimaryContainer
                                          : colorScheme.onSurfaceVariant,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      context.l10n!.custom,
                                      style: TextStyle(
                                        color: !isYouTubeMode
                                            ? colorScheme.onPrimaryContainer
                                            : colorScheme.onSurfaceVariant,
                                        fontWeight: !isYouTubeMode
                                            ? FontWeight.w600
                                            : FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 20),
                  if (isYouTubeMode)
                    TextField(
                      decoration: InputDecoration(
                        labelText: context.l10n!.youtubePlaylistLinkOrId,
                        prefixIcon: Icon(
                          FluentIcons.link_20_regular,
                          color: colorScheme.onSurfaceVariant,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        filled: true,
                        fillColor: colorScheme.surfaceContainerLow,
                      ),
                      onChanged: (value) {
                        id = value;
                      },
                    )
                  else ...[
                    TextField(
                      decoration: InputDecoration(
                        labelText: context.l10n!.customPlaylistName,
                        prefixIcon: Icon(
                          FluentIcons.text_field_20_regular,
                          color: colorScheme.onSurfaceVariant,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        filled: true,
                        fillColor: colorScheme.surfaceContainerLow,
                      ),
                      autofocus: true,
                      onChanged: (value) {
                        customPlaylistName = value;
                      },
                    ),
                    if (imageBase64 == null) ...[
                      const SizedBox(height: 12),
                      TextField(
                        decoration: InputDecoration(
                          labelText: context.l10n!.customPlaylistImgUrl,
                          prefixIcon: Icon(
                            FluentIcons.image_20_regular,
                            color: colorScheme.onSurfaceVariant,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          filled: true,
                          fillColor: colorScheme.surfaceContainerLow,
                        ),
                        onChanged: (value) {
                          imageUrl = value;
                          imageBase64 = null;
                          dialogSetState(() {});
                        },
                      ),
                    ],
                    const SizedBox(height: 12),
                    if (imageUrl == null) ...[
                      buildImagePickerRow(
                        context,
                        _pickImage,
                        imageBase64 != null,
                      ),
                      _imagePreview(),
                    ],
                  ],
                ],
              ),
            ),
            actionsAlignment: MainAxisAlignment.center,
            actions: <Widget>[
              OutlinedButton(
                onPressed: () => Navigator.pop(context),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: colorScheme.outline),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(context.l10n!.cancel),
              ),
              FilledButton.icon(
                onPressed: () async {
                  if (isYouTubeMode && id.isNotEmpty) {
                    final result = await addUserPlaylist(id, context);
                    if (context.mounted) showToast(context, result);
                    if (!context.mounted) return;
                    Navigator.pop(context);
                  } else if (!isYouTubeMode && customPlaylistName.isNotEmpty) {
                    final (result, newPlaylistId) = createCustomPlaylist(
                      customPlaylistName.trim(),
                      imageBase64 ?? imageUrl,
                      context,
                    );
                    if (songToAdd != null) {
                      if (context.mounted) {
                        final addResult = addSongInCustomPlaylist(
                          context,
                          newPlaylistId,
                          songToAdd,
                        );
                        showToast(context, addResult);
                      }
                    } else if (songsToAdd != null && songsToAdd.isNotEmpty) {
                      if (context.mounted) {
                        final addResult = addSongsInCustomPlaylist(
                          context,
                          newPlaylistId,
                          songsToAdd,
                        );
                        showToast(context, addResult);
                      }
                    } else {
                      if (context.mounted) showToast(context, result);
                    }
                    if (!context.mounted) return;
                    Navigator.pop(context);
                  } else {
                    showToast(
                      context,
                      '${context.l10n!.provideIdOrNameError}.',
                    );
                  }
                },
                icon: const Icon(FluentIcons.add_20_filled),
                label: Text(context.l10n!.add),
              ),
            ],
          );
        },
      );
    },
  );
}

/// Muzika: the design's "Save to playlist" sheet replaces the old dialog.
void showAddToPlaylistDialog(
  BuildContext context, {
  dynamic song,
  List<dynamic>? songs,
}) {
  unawaited(
    showMuzikaPlaylistPicker(
      context,
      song: song is Map ? song : null,
      songs: songs,
    ),
  );
}
