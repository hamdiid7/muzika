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

import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muzika/widgets/no_artwork_cube.dart';

class SongArtworkWidget extends StatelessWidget {
  const SongArtworkWidget({
    super.key,
    required this.size,
    required this.metadata,
    this.borderRadius = 10.0,
    this.errorWidgetIconSize = 20.0,
  });
  final double size;
  final MediaItem metadata;
  final double borderRadius;
  final double errorWidgetIconSize;

  ImageProvider? get _provider {
    final uri = metadata.artUri;
    if (uri == null) return null;
    if (uri.scheme == 'file') {
      final path = metadata.extras?['artWorkPath']?.toString();
      return FileImage(
        File(path != null && path.isNotEmpty ? path : uri.toFilePath()),
      );
    }
    return CachedNetworkImageProvider(uri.toString());
  }

  @override
  Widget build(BuildContext context) {
    final provider = _provider;
    if (provider == null) {
      return NullArtworkWidget(iconSize: errorWidgetIconSize, size: size);
    }
    return SizedBox(
      width: size,
      height: size,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Image(
            image: provider,
            fit: BoxFit.cover,
            // Keeps the old cover until the new one is ready, and a cover
            // already in memory shows on the first frame.
            gaplessPlayback: true,
            errorBuilder: (_, _, _) =>
                NullArtworkWidget(iconSize: errorWidgetIconSize, size: size),
          ),
        ),
      ),
    );
  }
}
