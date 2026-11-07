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

import 'dart:io';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muzika/services/analytics.dart';
import 'package:muzika/main.dart' show logger;
import 'package:muzika/services/desktop_panels.dart';
import 'package:muzika/theme/muzika_tokens.dart';
import 'package:muzika/widgets/muzika_logo.dart';
import 'package:muzika/utilities/flutter_toast.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Song menus and the player use the same preview and image export as lyrics.
Future<void> showSongShare(BuildContext context, Map song) {
  final title = '${song['title'] ?? 'Unknown song'}';
  final artist = '${song['artist'] ?? ''}';
  return Navigator.of(context, rootNavigator: !desktopPanels.value).push<void>(
    MaterialPageRoute(
      builder: (_) => MuzikaSharePage(
        fileName: 'muzika_song',
        shareText:
            '$title${artist.isEmpty ? '' : ' – $artist'}\n'
            'https://muzika.pages.dev',
        card: _SongCard(song: Map.of(song)),
      ),
    ),
  );
}

/// An artist's page as a card to share: their round photo over a blurred
/// copy of it, their name and fans, Muzika underneath.
Future<void> showArtistShare(
  BuildContext context, {
  required String name,
  String? image,
  String? fans,
}) {
  track('share_artist', {'artist': name});
  return Navigator.of(context, rootNavigator: !desktopPanels.value).push<void>(
    MaterialPageRoute(
      builder: (_) => MuzikaSharePage(
        fileName: 'muzika_artist',
        shareText: '$name on Muzika\nhttps://muzika.pages.dev',
        card: _ArtistCard(name: name, image: image, fans: fans),
      ),
    ),
  );
}

class _ArtistCard extends StatelessWidget {
  const _ArtistCard({required this.name, this.image, this.fans});

  final String name;
  final String? image;
  final String? fans;

  @override
  Widget build(BuildContext context) {
    final url = image;
    final photo = url == null || !url.startsWith('http')
        ? null
        : CachedNetworkImageProvider(url);
    return AspectRatio(
      aspectRatio: 4 / 5,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            return Stack(
              fit: StackFit.expand,
              children: [
                const ColoredBox(color: Color(0xFF212121)),
                if (photo != null)
                  ImageFiltered(
                    imageFilter: ui.ImageFilter.blur(sigmaX: 28, sigmaY: 28),
                    child: Image(
                      image: photo,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    ),
                  ),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x55000000), Color(0xDD000000)],
                    ),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.all(width * 0.07),
                  child: Column(
                    children: [
                      const Spacer(),
                      Container(
                        width: width * 0.56,
                        height: width * 0.56,
                        padding: const EdgeInsets.all(4),
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white24,
                        ),
                        child: ClipOval(
                          child: photo == null
                              ? const ColoredBox(
                                  color: Color(0xFF363636),
                                  child: Icon(
                                    Icons.person_rounded,
                                    color: Colors.white70,
                                    size: 64,
                                  ),
                                )
                              : Image(image: photo, fit: BoxFit.cover),
                        ),
                      ),
                      SizedBox(height: width * 0.06),
                      Text(
                        name,
                        maxLines: 2,
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                        style: muzikaHeading(
                          width * 0.085,
                          weight: 800,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        [
                          'Artist',
                          if (fans != null && fans!.isNotEmpty) fans!,
                        ].join(' · '),
                        style: muzikaBody(width * 0.044, color: Colors.white70),
                      ),
                      const Spacer(),
                      Row(
                        children: [
                          const MuzikaLogo(height: 16, color: Colors.white),
                          const SizedBox(width: 6),
                          Text(
                            'Muzika',
                            style: muzikaHeading(
                              width * 0.043,
                              color: Colors.white,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            'muzika.pages.dev',
                            style: muzikaBody(
                              width * 0.034,
                              color: Colors.white70,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _SongCard extends StatelessWidget {
  const _SongCard({required this.song});

  final Map song;

  ImageProvider? get _cover {
    final path = song['artworkPath']?.toString();
    if (path != null && path.isNotEmpty && File(path).existsSync()) {
      return FileImage(File(path));
    }
    final url = (song['highResImage'] ?? song['image'] ?? song['lowResImage'])
        ?.toString();
    if (url == null || url.isEmpty) return null;
    final uri = Uri.tryParse(url);
    if (uri?.scheme == 'file') return FileImage(File(uri!.toFilePath()));
    if (uri?.scheme != 'http' && uri?.scheme != 'https') return null;
    return CachedNetworkImageProvider(url);
  }

  @override
  Widget build(BuildContext context) {
    final cover = _cover;
    return AspectRatio(
      aspectRatio: 4 / 5,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            return Stack(
              fit: StackFit.expand,
              children: [
                const ColoredBox(color: Color(0xFF212121)),
                if (cover != null)
                  ImageFiltered(
                    imageFilter: ui.ImageFilter.blur(sigmaX: 28, sigmaY: 28),
                    child: Image(
                      image: cover,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    ),
                  ),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x66000000), Color(0xDD000000)],
                    ),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.all(width * 0.07),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Center(
                          child: AspectRatio(
                            aspectRatio: 1,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: ColoredBox(
                                color: const Color(0xFF363636),
                                child: cover == null
                                    ? const Icon(
                                        Icons.music_note_rounded,
                                        color: Colors.white70,
                                        size: 64,
                                      )
                                    : Image(
                                        image: cover,
                                        fit: BoxFit.cover,
                                        errorBuilder: (_, _, _) => const Icon(
                                          Icons.music_note_rounded,
                                          color: Colors.white70,
                                          size: 64,
                                        ),
                                      ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      SizedBox(height: width * 0.055),
                      Text(
                        '${song['title'] ?? 'Unknown song'}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: muzikaHeading(
                          width * 0.075,
                          weight: 800,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        '${song['artist'] ?? ''}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: muzikaBody(width * 0.044, color: Colors.white70),
                      ),
                      SizedBox(height: width * 0.065),
                      Row(
                        children: [
                          const MuzikaLogo(height: 16, color: Colors.white),
                          const SizedBox(width: 6),
                          Text(
                            'Muzika',
                            style: muzikaHeading(
                              width * 0.043,
                              color: Colors.white,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            'muzika.pages.dev',
                            style: muzikaBody(
                              width * 0.034,
                              color: Colors.white70,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Renders the widget behind [key] (a RepaintBoundary) to a PNG and opens the
/// system share sheet with it. Every shareable Muzika card goes through here.
Future<void> shareWidgetImage(
  GlobalKey key, {
  required String fileName,
  String? text,
}) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 3);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  final dir = await getTemporaryDirectory();
  final file = File(
    '${dir.path}/${fileName}_${DateTime.now().millisecondsSinceEpoch}.png',
  );
  await file.writeAsBytes(png!.buffer.asUint8List());
  await SharePlus.instance.share(
    ShareParams(
      files: [XFile(file.path, mimeType: 'image/png')],
      text: text,
    ),
  );
}

/// A full page showing [card] with a floating share button underneath.
class MuzikaSharePage extends StatefulWidget {
  const MuzikaSharePage({
    super.key,
    required this.card,
    required this.fileName,
    this.shareText,
  });

  final Widget card;
  final String fileName;
  final String? shareText;

  @override
  State<MuzikaSharePage> createState() => _MuzikaSharePageState();
}

class _MuzikaSharePageState extends State<MuzikaSharePage> {
  final _key = GlobalKey();
  bool _sharing = false;

  Future<void> _share() async {
    if (_sharing) return;
    setState(() => _sharing = true);
    try {
      await shareWidgetImage(
        _key,
        fileName: widget.fileName,
        text: widget.shareText,
      );
    } catch (e, st) {
      logger.log('Sharing failed', error: e, stackTrace: st);
      if (mounted) showToast(context, 'Couldn’t share');
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: RepaintBoundary(key: _key, child: widget.card),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: scheme.onSurface,
                    foregroundColor: scheme.surface,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: const StadiumBorder(),
                  ),
                  onPressed: _sharing ? null : _share,
                  icon: const Icon(Icons.ios_share_rounded, size: 20),
                  label: Text(
                    _sharing ? 'Sharing…' : 'Share',
                    style: muzikaBody(16, weight: 700),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
