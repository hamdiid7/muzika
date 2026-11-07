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
import 'dart:io';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muzika/main.dart' show audioHandler, logger;

/// The main colour of the playing song's cover, or null. The theme mixes a
/// trace of it into the backgrounds so the app quietly takes on the song.
final coverTint = ValueNotifier<Color?>(null);

String? _lastArt;

/// Follows the playing song and updates [coverTint].
void startCoverTint() {
  audioHandler.mediaItem.listen((item) {
    final art = item?.artUri?.toString();
    if (art == null || art == _lastArt) return;
    _lastArt = art;
    unawaited(_update(item!.artUri!));
  });
}

Future<void> _update(Uri art) async {
  final color = await imageColor(art);
  if (color != null && art.toString() == _lastArt) coverTint.value = color;
}

final _colors = <String, Future<Color?>>{};

/// The main colour of the picture at [art] (also a playlist's cover), or
/// null; worked out once per picture.
Future<Color?> imageColor(Uri art) =>
    _colors[art.toString()] ??= _readColor(art);

Future<Color?> _readColor(Uri art) async {
  try {
    final base = art.scheme == 'file'
        ? FileImage(File(art.toFilePath())) as ImageProvider
        : CachedNetworkImageProvider(art.toString());
    final provider = ResizeImage(base, width: 24, height: 24);
    final completer = Completer<ui.Image>();
    final stream = provider.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        completer.complete(info.image);
        stream.removeListener(listener);
      },
      onError: (e, _) {
        if (!completer.isCompleted) completer.completeError(e);
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
    final image = await completer.future.timeout(const Duration(seconds: 10));
    final data = await image.toByteData();
    if (data == null) return null;

    // The cover's main colour: colourful pixels grouped by hue (24 groups,
    // a group helped by its neighbours), then the average of the biggest
    // group. Averaging every pixel mixed e.g. blue, yellow and pink into a
    // green that isn't on the cover at all.
    final weight = List<double>.filled(24, 0);
    final sums = List.generate(24, (_) => [0.0, 0.0, 0.0]);
    var pixels = 0;
    for (var i = 0; i + 3 < data.lengthInBytes; i += 4) {
      final pr = data.getUint8(i), pg = data.getUint8(i + 1);
      final pb = data.getUint8(i + 2);
      pixels++;
      final hsl = HSLColor.fromColor(Color.fromARGB(255, pr, pg, pb));
      final w = hsl.saturation * (1 - (hsl.lightness - 0.5).abs() * 2);
      if (w < 0.15) continue;
      final group = (hsl.hue / 15).floor() % 24;
      weight[group] += w;
      sums[group][0] += pr * w;
      sums[group][1] += pg * w;
      sums[group][2] += pb * w;
    }
    var best = -1;
    var bestWeight = 0.0;
    for (var i = 0; i < 24; i++) {
      final w = weight[i] + (weight[(i + 23) % 24] + weight[(i + 1) % 24]) / 2;
      if (w > bestWeight) {
        bestWeight = w;
        best = i;
      }
    }
    // A black-and-white cover has no colour to give.
    if (best < 0 || weight[best] < pixels * 0.02) return null;
    final main = Color.fromARGB(
      255,
      (sums[best][0] / weight[best]).round(),
      (sums[best][1] / weight[best]).round(),
      (sums[best][2] / weight[best]).round(),
    );
    // Keep the hue, settle saturation and lightness so the tint is even.
    final hsl = HSLColor.fromColor(main);
    return hsl
        .withSaturation(hsl.saturation.clamp(0.25, 0.7))
        .withLightness(0.5)
        .toColor();
  } catch (e) {
    logger.log('Cover tint failed', error: e);
    return null;
  }
}

/// The page colour with more of [cover] (the mini player and the bottom bar
/// under it): near black in dark mode, near white in light mode, so the text
/// on it reads as before.
Color coverTinted(Color? cover, ColorScheme scheme, {double? amount}) {
  if (cover == null) return scheme.surface;
  return scheme.brightness == Brightness.dark
      ? Color.lerp(const Color(0xFF0A0A0A), cover, amount ?? 0.3)!
      : Color.lerp(Colors.white, cover, amount ?? 0.16)!;
}
