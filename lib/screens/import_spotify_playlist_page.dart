import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muzika/services/analytics.dart';
import 'package:muzika/extensions/l10n.dart';
import 'package:muzika/main.dart' show logger;
import 'package:muzika/services/deezer_catalog.dart';
import 'package:muzika/services/itunes_catalog.dart';
import 'package:muzika/services/playlists_manager.dart';
import 'package:muzika/services/spotify_link.dart';
import 'package:muzika/utilities/flutter_toast.dart';
import 'package:muzika/utilities/url_launcher.dart';
import 'package:muzika/widgets/mini_player.dart';

/// A CSV row and its original position, used to preserve playlist order.
typedef _ImportRow = ({int index, String title, String artist});

class ImportSpotifyPlaylistPage extends StatefulWidget {
  const ImportSpotifyPlaylistPage({super.key});

  @override
  State<ImportSpotifyPlaylistPage> createState() =>
      _ImportSpotifyPlaylistPageState();
}

class _ImportSpotifyPlaylistPageState extends State<ImportSpotifyPlaylistPage> {
  // Shared across page instances so navigating away and reopening the page
  // can't spawn a second import running concurrently with the first.
  static bool _importRunning = false;

  // Limit concurrency and leave a short pause between batches.
  static const _batchSize = 12;
  static const _batchPause = Duration(milliseconds: 150);

  final _csvController = TextEditingController();
  final _playlistNameController = TextEditingController();
  bool _isImporting = false;
  String? _fileName;
  int _processedCount = 0;
  int _totalCount = 0;

  @override
  void dispose() {
    _csvController.dispose();
    _playlistNameController.dispose();
    _linkController.dispose();
    super.dispose();
  }

  Future<void> _chooseFile() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv'],
    );
    if (result.isEmpty || !mounted) return;

    final file = result.single;
    final path = file.path;
    if (path == null) return;
    _csvController.text = await File(path).readAsString();
    if (!mounted) return;
    setState(() => _fileName = file.name);
  }

  final _linkController = TextEditingController();
  bool _readingLink = false;

  /// A Spotify playlist or album link: its songs (the first
  /// [spotifyLinkLimit]) are read and imported, the playlist named after it.
  Future<void> _importLink() async {
    if (_isImporting || _readingLink) return;
    if (_importRunning) {
      showToast(context, context.l10n!.spotifyPlaylistAlreadyImporting);
      return;
    }
    final link = _linkController.text.trim();
    if (parseSpotifyLink(link) == null) {
      showToast(context, 'Paste a Spotify playlist or album link');
      return;
    }
    setState(() => _readingLink = true);
    final list = await spotifyListFromLink(link).catchError((_) => null);
    if (!mounted) return;
    setState(() => _readingLink = false);
    if (list == null) {
      showToast(
        context,
        "Couldn't read that list: is it public? (Liked Songs can't be "
        'read from a link: use the CSV below)',
      );
      return;
    }
    final name = _playlistNameController.text.trim().isNotEmpty
        ? _playlistNameController.text.trim()
        : (list.name.isEmpty ? 'From Spotify' : list.name);
    _playlistNameController.text = name;
    if (list.songs.length >= spotifyLinkLimit) {
      showToast(
        context,
        'Spotify shows the first $spotifyLinkLimit songs of a link: for the '
        'rest of a longer playlist, use the CSV below',
      );
    }
    await _importRows([
      for (final (i, song) in list.songs.indexed)
        (index: i, title: song.title, artist: song.artist),
    ], name);
  }

  Future<void> _importPlaylist() async {
    if (_isImporting) return;
    if (_importRunning) {
      showToast(context, context.l10n!.spotifyPlaylistAlreadyImporting);
      return;
    }
    final playlistName = _playlistNameController.text.trim();
    if (playlistName.isEmpty) {
      showToast(context, context.l10n!.enterPlaylistName);
      return;
    }
    final records = _parseCsv(_csvController.text);
    if (records.length < 2) {
      showToast(context, context.l10n!.spotifyPlaylistEmpty);
      return;
    }

    final headers = records.first
        .map((header) => header.replaceFirst('\ufeff', '').trim().toLowerCase())
        .toList();
    bool isNameColumn(String header) =>
        !header.contains('id') &&
        !header.contains('uri') &&
        !header.contains('url') &&
        !header.contains('genre');
    final songIndex = headers.indexWhere(
      (header) =>
          (header.contains('song') || header.contains('track')) &&
          isNameColumn(header),
    );
    final artistIndex = headers.indexWhere(
      (header) => header.contains('artist') && isNameColumn(header),
    );
    if (songIndex == -1 || artistIndex == -1) {
      showToast(context, context.l10n!.spotifyPlaylistInvalid);
      return;
    }

    final songs = records.skip(1).where((row) {
      return row.length > songIndex &&
          row.length > artistIndex &&
          row[songIndex].trim().isNotEmpty;
    }).toList();
    if (songs.isEmpty) {
      showToast(context, context.l10n!.spotifyPlaylistEmpty);
      return;
    }

    final rows = songs.indexed
        .map(
          (entry) => (
            index: entry.$1,
            title: entry.$2[songIndex].trim(),
            artist: entry.$2[artistIndex].trim(),
          ),
        )
        .toList();
    await _importRows(rows, playlistName);
  }

  /// Finds [rows] in the catalog and saves the ones found as a playlist
  /// called [playlistName] (from a CSV file or a Spotify link).
  Future<void> _importRows(List<_ImportRow> rows, String playlistName) async {
    _importRunning = true;
    setState(() {
      _isImporting = true;
      _processedCount = 0;
      _totalCount = rows.length;
    });

    // Key results by their CSV position so retry results remain ordered.
    final foundByIndex = <int, Map>{};
    List<_ImportRow> missingRows;
    var rateLimited = false;
    try {
      final firstPass = await _searchBatch(
        rows,
        onProgress: (n) {
          if (mounted) setState(() => _processedCount += n);
        },
      );
      foundByIndex.addAll(firstPass.found);
      missingRows = firstPass.missing;
      rateLimited = firstPass.rateLimited;

      // Retry misses once, unless the service is actively rate-limiting us.
      if (!rateLimited && missingRows.isNotEmpty) {
        // Include the retry work in the progress total.
        if (mounted) setState(() => _totalCount += missingRows.length);
        final retryPass = await _searchBatch(
          missingRows,
          onProgress: (n) {
            if (mounted) setState(() => _processedCount += n);
          },
        );
        foundByIndex.addAll(retryPass.found);
        missingRows = retryPass.missing;
        rateLimited = retryPass.rateLimited;
      }
    } finally {
      _importRunning = false;
    }

    final foundSongs = [
      for (final row in rows)
        if (foundByIndex[row.index] case final song?) song,
    ];

    track('spotify_import', {
      'songs': rows.length,
      'found': foundSongs.length,
      'rate_limited': rateLimited,
    });
    if (!mounted) return;
    final (_, playlistId) = createCustomPlaylist(playlistName, null, context);
    addSongsInCustomPlaylist(context, playlistId, foundSongs);
    setState(() => _isImporting = false);

    final resultText = rateLimited
        ? '${context.l10n!.spotifyPlaylistImportFailed}\n${context.l10n!.spotifyPlaylistImportResult(foundSongs.length, rows.length)}'
        : context.l10n!.spotifyPlaylistImportResult(
            foundSongs.length,
            rows.length,
          );
    if (missingRows.isNotEmpty) {
      final missingText = missingRows
          .map((row) => '${row.title} - ${row.artist}')
          .join('\n');
      await Clipboard.setData(ClipboardData(text: missingText));
      if (mounted) {
        showToastWithButton(
          context,
          '$resultText\n${context.l10n!.spotifyPlaylistMissingSongs}',
          context.l10n!.copy,
          () => Clipboard.setData(ClipboardData(text: missingText)),
          duration: const Duration(seconds: 8),
          icon: FluentIcons.warning_24_regular,
        );
      }
    } else {
      showToast(context, resultText);
    }
  }

  /// Resolves [rows] in batches and stops when rate limiting is detected.
  /// Results are keyed by the rows' original positions for retry merging.
  Future<({Map<int, Map> found, List<_ImportRow> missing, bool rateLimited})>
  _searchBatch(
    List<_ImportRow> rows, {
    required void Function(int processedCount) onProgress,
  }) async {
    final found = <int, Map>{};
    final missing = <_ImportRow>[];
    for (var i = 0; i < rows.length; i += _batchSize) {
      final batch = rows.skip(i).take(_batchSize).toList();
      final batchResults = await Future.wait(
        batch.map((row) async {
          final (match, wasRateLimited) = await _findSongWithRetry(
            '${row.title} ${row.artist}',
            expectedArtist: row.artist,
            expectedTitle: row.title,
          );
          return (row, match, wasRateLimited);
        }),
      );
      var batchRateLimited = false;
      for (final (row, match, wasRateLimited) in batchResults) {
        if (wasRateLimited) batchRateLimited = true;
        if (match == null) {
          missing.add(row);
        } else {
          found[row.index] = match;
        }
      }
      onProgress(batchResults.length);
      if (batchRateLimited) {
        missing.addAll(rows.skip(i + _batchSize));
        return (found: found, missing: missing, rateLimited: true);
      }
      await Future.delayed(_batchPause);
    }
    return (found: found, missing: missing, rateLimited: false);
  }

  /// Returns the best match for [query], or `null` if none was found.
  /// The second value is `true` when YouTube is actively rate-limiting this
  /// device, so the caller can stop the whole import instead of retrying
  /// every remaining song for minutes on end.
  Future<(Map<String, dynamic>?, bool)> _findSongWithRetry(
    String query, {
    String? expectedArtist,
    String? expectedTitle,
  }) async {
    // Deezer's catalog (the relay to YouTube Music is gone), Apple when
    // Deezer doesn't have the song. Its audio is found when it first plays.
    const maxAttempts = 2;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        final title = expectedTitle ?? query;
        final artist = expectedArtist ?? '';
        final song = await deezerFindSong(title, artist);
        if (song != null) return (song, false);
        final apple = (await itunesSearchSongs('$title $artist'))
            .where((s) => _sameArtist('${s['artist']}', artist))
            .firstOrNull;
        return (apple, false);
      } catch (e, stackTrace) {
        if (attempt == maxAttempts - 1) {
          logger.log(
            'Error searching import match for "$query"',
            error: e,
            stackTrace: stackTrace,
          );
          return (null, false);
        }
        await Future.delayed(Duration(milliseconds: 500 * (attempt + 1)));
      }
    }
    return (null, false);
  }

  bool _sameArtist(String found, String wanted) {
    String k(String s) =>
        s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');
    final a = k(found);
    final b = k(wanted.split(',').first);
    return b.isEmpty || a.contains(b) || b.contains(a);
  }

  List<List<String>> _parseCsv(String input) {
    final rows = <List<String>>[];
    var row = <String>[];
    var field = StringBuffer();
    var quoted = false;

    for (var index = 0; index < input.length; index++) {
      final character = input[index];
      if (character == '"') {
        if (quoted && index + 1 < input.length && input[index + 1] == '"') {
          field.write('"');
          index++;
        } else {
          quoted = !quoted;
        }
      } else if (character == ',' && !quoted) {
        row.add(field.toString());
        field = StringBuffer();
      } else if ((character == '\n' || character == '\r') && !quoted) {
        if (character == '\r' &&
            index + 1 < input.length &&
            input[index + 1] == '\n') {
          index++;
        }
        row.add(field.toString());
        field = StringBuffer();
        if (row.any((value) => value.trim().isNotEmpty)) rows.add(row);
        row = <String>[];
      } else {
        field.write(character);
      }
    }
    if (field.isNotEmpty || row.isNotEmpty) {
      row.add(field.toString());
      if (row.any((value) => value.trim().isNotEmpty)) rows.add(row);
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n!.importSpotifyPlaylistTitle)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Paste a Spotify link',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            const Text(
              'Open a playlist or album in Spotify, tap Share › Copy link, '
              'and paste it here. Public lists only, up to '
              '$spotifyLinkLimit songs each.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _linkController,
              enabled: !_isImporting && !_readingLink,
              decoration: InputDecoration(
                hintText: 'https://open.spotify.com/playlist/…',
                prefixIcon: const Icon(FluentIcons.link_24_regular),
                filled: true,
                fillColor: colorScheme.surfaceContainerHigh,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
              onSubmitted: (_) => _importLink(),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _isImporting || _readingLink ? null : _importLink,
              icon: _readingLink
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(FluentIcons.arrow_download_24_regular),
              label: const Text('Import from link'),
            ),
            const SizedBox(height: 28),
            Text(
              'Or a CSV file (longer playlists, Liked Songs)',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(context.l10n!.importSpotifyPlaylistInstructions),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () => launchURL(
                Uri.parse('https://www.chosic.com/spotify-playlist-exporter/'),
              ),
              icon: const Icon(FluentIcons.open_24_regular),
              label: Text(context.l10n!.openChosicExporter),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _isImporting ? null : _chooseFile,
              icon: const Icon(FluentIcons.document_add_24_regular),
              label: Text(_fileName ?? context.l10n!.chooseCsvFile),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _playlistNameController,
              enabled: !_isImporting,
              decoration: InputDecoration(
                labelText: '${context.l10n!.playlistName} *',
                hintText: context.l10n!.spotifyPlaylistNameHint,
                filled: true,
                fillColor: colorScheme.surfaceContainerHigh,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _csvController,
              enabled: !_isImporting,
              minLines: 10,
              maxLines: 18,
              decoration: InputDecoration(
                labelText: context.l10n!.pasteCsv,
                hintText: context.l10n!.spotifyCsvHint,
                alignLabelWithHint: true,
                filled: true,
                fillColor: colorScheme.surfaceContainerHigh,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _isImporting ? null : _importPlaylist,
              icon: _isImporting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(FluentIcons.arrow_upload_24_regular),
              label: Text(
                _isImporting
                    ? context.l10n!.spotifyPlaylistImporting
                    : context.l10n!.importPlaylist,
              ),
            ),
            if (_isImporting && _totalCount > 0) ...[
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: _processedCount / _totalCount,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                context.l10n!.spotifyPlaylistProgress(
                  _processedCount,
                  _totalCount,
                ),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: MiniPlayer.playerHeight + 24),
          ],
        ),
      ),
    );
  }
}
