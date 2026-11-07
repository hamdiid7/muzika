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

import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muzika/theme/muzika_tokens.dart';
import 'package:muzika/widgets/muzika_song_row.dart';

/// The pill that labels a section on the Artist, Album and Playlist sheets.
class MuzikaChip extends StatelessWidget {
  const MuzikaChip(this.label, {super.key, this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Material(
          color: scheme.onSurface,
          shape: const StadiumBorder(),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 4,
                children: [
                  Text(
                    label,
                    style: muzikaBody(13, weight: 600, color: scheme.surface),
                  ),
                  if (onTap != null)
                    Icon(
                      FluentIcons.chevron_right_16_regular,
                      size: 14,
                      color: scheme.surface,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class MuzikaDivider extends StatelessWidget {
  const MuzikaDivider({super.key});

  @override
  Widget build(BuildContext context) => Divider(
    height: 1,
    indent: 20,
    endIndent: 20,
    color: Theme.of(context).colorScheme.outlineVariant,
  );
}

/// An artist, album or playlist in a list: cover, title, kind, chevron.
class MuzikaEntityRow extends StatelessWidget {
  const MuzikaEntityRow({
    super.key,
    required this.title,
    required this.subtitle,
    required this.image,
    required this.onTap,
    this.circular = false,
  });

  MuzikaEntityRow.artist({
    super.key,
    required Map artist,
    required this.onTap,
    this.subtitle = 'Artist',
  }) : title = artist['title']?.toString() ?? '',
       image = artist['image']?.toString(),
       circular = true;

  final String title;
  final String subtitle;
  final String? image;
  final bool circular;
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
            MuzikaCover(
              song: {'lowResImage': image, 'image': image},
              radius: circular ? 28 : 8,
            ),
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
                    overflow: TextOverflow.ellipsis,
                    style: muzikaBody(12.5, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            Icon(
              FluentIcons.chevron_right_20_regular,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}
