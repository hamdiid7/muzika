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

import 'package:cached_network_image/cached_network_image.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muzika/services/clip_requests.dart';
import 'package:muzika/services/itunes_catalog.dart';
import 'package:muzika/theme/muzika_tokens.dart';
import 'package:muzika/widgets/shelf_arrows.dart';

/// A "Clips" heading and a row of tall clip covers that scrolls sideways
/// (an artist's clips, Liked clips). A tap opens the Clips tab on that clip.
class ClipsShelf extends StatelessWidget {
  const ClipsShelf({super.key, required this.clips, this.title = 'Clips'});

  final List<AppleClip> clips;
  final String title;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (clips.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
          child: Text(title, style: muzikaHeading(20, color: scheme.onSurface)),
        ),
        SizedBox(
          height: 226,
          child: ShelfArrows(
            pictureHeight: 180,
            builder: (controller) => ListView.separated(
              controller: controller,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              itemCount: clips.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (context, i) {
                final clip = clips[i];
                final cover = [clip.song['image'], clip.song['lowResImage']]
                    .map((e) => '${e ?? ''}')
                    .firstWhere((e) => e.startsWith('http'), orElse: () => '');
                return GestureDetector(
                  onTap: () => openClip(clip),
                  child: SizedBox(
                    width: 120,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: SizedBox(
                            width: 120,
                            height: 180,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                if (cover.isEmpty)
                                  ColoredBox(color: scheme.surfaceContainerHigh)
                                else
                                  CachedNetworkImage(
                                    imageUrl: cover,
                                    fit: BoxFit.cover,
                                  ),
                                const Align(
                                  alignment: Alignment.bottomLeft,
                                  child: Padding(
                                    padding: EdgeInsets.all(8),
                                    child: Icon(
                                      FluentIcons.play_24_filled,
                                      size: 20,
                                      color: Colors.white,
                                      shadows: [
                                        Shadow(
                                          color: Colors.black54,
                                          blurRadius: 6,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '${clip.song['title'] ?? ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: muzikaBody(
                            13.5,
                            weight: 600,
                            color: scheme.onSurface,
                          ),
                        ),
                        Text(
                          '${clip.song['artist'] ?? ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: muzikaBody(12, color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
