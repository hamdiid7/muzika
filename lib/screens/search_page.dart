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
import 'dart:math';

import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muzika/utilities/undo.dart';
import 'package:muzika/widgets/settings_icon_button.dart';
import 'package:muzika/services/analytics.dart';
import 'package:muzika/database/radio_stations.db.dart';
import 'package:muzika/extensions/l10n.dart';
import 'package:muzika/main.dart';
import 'package:muzika/models/radio_model.dart';
import 'package:muzika/services/catalog_relay.dart';
import 'package:muzika/services/common_services.dart';
import 'package:muzika/services/data_manager.dart';
import 'package:muzika/services/deezer_catalog.dart';
import 'package:muzika/services/itunes_catalog.dart';
import 'package:muzika/services/playlists_manager.dart';
import 'package:muzika/services/router_service.dart';
import 'package:muzika/theme/muzika_tokens.dart';
import 'package:muzika/utilities/app_utils.dart';
import 'package:muzika/utilities/flutter_toast.dart';
import 'package:muzika/widgets/muzika_shimmer.dart';
import 'package:muzika/widgets/muzika_song_row.dart';
import 'package:youtube_music_explode_dart/youtube_music_explode_dart.dart'
    show MusicTopResult, MusicTopResultKind;

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  _SearchPageState createState() => _SearchPageState();
}

// Global ValueNotifier for search history to make it reactive
final ValueNotifier<List> searchHistoryNotifier = ValueNotifier<List>(
  Hive.box('user').get('searchHistory', defaultValue: []),
);

/// Set by other screens (e.g. Home mood chips) to run a search when the
/// Search tab is shown.
final ValueNotifier<String?> pendingSearchQuery = ValueNotifier<String?>(null);

/// Keys typed between tapping Search and its box taking focus (a moment on
/// a slow phone, while the tab fades in): kept, then put in the box.
final _earlyKeys = StringBuffer();
bool _catchingKeys = false;

bool _catchKey(KeyEvent event) {
  final c = event.character;
  if (event is KeyDownEvent && c != null && c.isNotEmpty) {
    if (c.codeUnitAt(0) >= 0x20) _earlyKeys.write(c);
  }
  return false;
}

/// From the Search tab's tap: keys are kept until the box has focus (two
/// seconds at most).
void catchEarlySearchKeys() {
  if (_catchingKeys) return;
  _catchingKeys = true;
  _earlyKeys.clear();
  HardwareKeyboard.instance.addHandler(_catchKey);
  Future<void>.delayed(const Duration(seconds: 2), takeEarlySearchKeys);
}

/// What was caught, and the catching stops.
String takeEarlySearchKeys() {
  if (!_catchingKeys) return '';
  _catchingKeys = false;
  HardwareKeyboard.instance.removeHandler(_catchKey);
  final keys = _earlyKeys.toString();
  _earlyKeys.clear();
  return keys;
}

void reloadSearchHistoryFromStorage() {
  searchHistoryNotifier.value = Hive.box('user')
      .get('searchHistory', defaultValue: []);
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _searchBar = TextEditingController();
  final FocusNode _inputNode = FocusNode();
  final ValueNotifier<bool> _fetchingSongs = ValueNotifier(false);
  int maxSongsInList = 15;
  List<dynamic> _songsSearchResult = [];
  List<Map<String, dynamic>> _artistsSearchResult = [];
  List<dynamic> _albumsSearchResult = [];
  List<dynamic> _playlistsSearchResult = [];
  List<RadioStation> _radioStationsSearchResult = [];
  MusicTopResult? _topResult;
  List<String> _suggestionsList = [];

  /// While typing: the artists and songs that match so far (as an artist's
  /// page filters its songs), above the suggested searches.
  List<Map<String, dynamic>> _liveArtists = [];
  List<Map<String, dynamic>> _liveSongs = [];
  Timer? _debounce;
  int _latestSuggestionRequest = 0;
  int _latestSearchRequest = 0;

  /// The user's own songs that match [query]: liked, downloaded, in their
  /// playlists, played lately; every word of it in the title or artist.
  List<Map> _libraryMatches(String query, {int max = 5}) {
    String plain(Object? s) => '$s'.toLowerCase();
    final words = plain(query).split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    if (words.isEmpty) return const [];
    final found = <Map>[];
    final seen = <String>{};
    for (final list in [
      userLikedSongsList.value,
      userOfflineSongs.value,
      for (final p in userCustomPlaylists.value)
        (p['list'] as List?) ?? const [],
      userRecentlyPlayed.value,
    ]) {
      for (final song in list.whereType<Map>()) {
        final id = '${song['ytid'] ?? ''}';
        if (id.isEmpty || seen.contains(id)) continue;
        final text = plain('${song['title'] ?? ''} ${song['artist'] ?? ''}');
        if (!words.every(text.contains)) continue;
        seen.add(id);
        found.add(song);
        if (found.length == max) return found;
      }
    }
    return found;
  }

  Widget _librarySongRow(Map song) => _entityRow(
    title: '${song['title'] ?? ''}',
    subtitle: 'In your library · ${song['artist'] ?? ''}',
    image: (song['lowResImage'] ?? song['image'])?.toString(),
    circular: false,
    trailing: Icon(
      FluentIcons.library_20_regular,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
    onTap: () {
      _inputNode.unfocus();
      unawaited(audioHandler.addPlaylistToQueue([song], replace: true));
    },
  );

  void _onTyped(String value) {
    setState(() {});
    _debounce?.cancel();
    final query = value;
    final requestId = ++_latestSuggestionRequest;
    // An emptied field goes back to recently opened results.
    if (query.isEmpty) {
      _liveArtists = [];
      _liveSongs = [];
      unawaited(search());
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      final (suggestions, artists, songs) = await (
        getSearchSuggestions(query),
        deezerSearchArtists(
          query,
          limit: 3,
        ).catchError((_) => <Map<String, dynamic>>[]),
        deezerSearchSongs(query).catchError((_) => <Map<String, dynamic>>[]),
      ).wait;
      if (!mounted ||
          requestId != _latestSuggestionRequest ||
          _searchBar.text != query) {
        return;
      }
      setState(() {
        _suggestionsList = List.from(suggestions);
        _liveArtists = artists;
        _liveSongs = songs.take(4).toList();
      });
    });
  }

  Future<void> _submitSearch([String? query]) async {
    if (query != null) {
      _searchBar.text = query;
      _searchBar.selection = TextSelection.fromPosition(
        TextPosition(offset: _searchBar.text.length),
      );
    }

    _latestSuggestionRequest++;
    _debounce?.cancel();
    _suggestionsList = [];
    _liveArtists = [];
    _liveSongs = [];
    if (mounted) setState(() {});

    await search();
    _inputNode.unfocus();
  }

  /// Focus, tried again each frame for a second: the tab is still fading
  /// in when it's asked for.
  void _focusSoon([int tries = 0]) {
    if (!mounted || _inputNode.hasFocus || tries > 60) return;
    _inputNode.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusSoon(tries + 1));
  }

  /// Focused: what was typed before the box was ready goes in it.
  void _onFocus() {
    if (!_inputNode.hasFocus) return;
    final early = takeEarlySearchKeys();
    if (early.isEmpty) return;
    _searchBar.text += early;
    _searchBar.selection = TextSelection.collapsed(
      offset: _searchBar.text.length,
    );
    _onTyped(_searchBar.text);
  }

  @override
  void initState() {
    super.initState();
    _inputNode.addListener(_onFocus);
    pendingSearchQuery.addListener(_consumePendingQuery);
    WidgetsBinding.instance.addPostFrameCallback((_) => _consumePendingQuery());
  }

  void _consumePendingQuery() {
    final query = pendingSearchQuery.value;
    if (query == null || !mounted) return;
    pendingSearchQuery.value = null;
    if (query.isEmpty) {
      // The cursor at the end of what's there, ready to type.
      _searchBar.selection = TextSelection.collapsed(
        offset: _searchBar.text.length,
      );
      _focusSoon();
    } else {
      unawaited(_submitSearch(query));
    }
  }

  @override
  void dispose() {
    pendingSearchQuery.removeListener(_consumePendingQuery);
    _inputNode.removeListener(_onFocus);
    _searchBar.dispose();
    _inputNode.dispose();
    _fetchingSongs.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  /// Albums from Deezer, with Apple's that Deezer doesn't have.
  Future<List> _deezerOrAppleAlbums(String query) async {
    final (deezer, apple) = await (
      deezerSearchAlbums(query).catchError((_) => <Map<String, dynamic>>[]),
      itunesSearchAlbums(query).catchError((_) => <Map<String, dynamic>>[]),
    ).wait;
    return mergeCatalogResults(query, deezer, apple);
  }

  Future<void> search() async {
    final query = _searchBar.text.trim();
    final requestId = ++_latestSearchRequest;

    if (query.isEmpty) {
      _songsSearchResult = [];
      _artistsSearchResult = [];
      _albumsSearchResult = [];
      _playlistsSearchResult = [];
      _radioStationsSearchResult = [];
      _topResult = null;
      _suggestionsList = [];
      _liveArtists = [];
      _liveSongs = [];
      _fetchingSongs.value = false;
      if (mounted) setState(() {});
      return;
    }
    _fetchingSongs.value = true;

    _songsSearchResult = [];
    _artistsSearchResult = [];
    _albumsSearchResult = [];
    _playlistsSearchResult = [];
    _topResult = null;
    _radioStationsSearchResult = radioStationsDB
        .where(
          (station) =>
              station.name.toLowerCase().contains(query.toLowerCase()) ||
              (station.genre?.toLowerCase().contains(query.toLowerCase()) ??
                  false),
        )
        .toList();
    if (mounted) setState(() {});

    try {
      final artistsFuture = searchArtists(query);

      Future<void> publishSongs() async {
        try {
          var songs = await fetchSongsList(query);
          if (!mounted || requestId != _latestSearchRequest) return;

          if (songs.isEmpty) {
            final artists = await artistsFuture;
            if (!mounted || requestId != _latestSearchRequest) return;
            if (_artistsSearchResult.isEmpty) {
              _artistsSearchResult = artists
                  .whereType<Map>()
                  .map(Map<String, dynamic>.from)
                  .toList();
            }
            if (_artistsSearchResult.isNotEmpty) {
              songs = await _fetchSongsForResolvedArtist(query);
            }
          }

          if (!mounted || requestId != _latestSearchRequest) return;
          track('search', {'query': query, 'songs': songs.length});
          setState(() => _songsSearchResult = songs);
        } catch (e, stackTrace) {
          logger.log(
            'Error while searching online songs',
            error: e,
            stackTrace: stackTrace,
          );
        }
      }

      Future<void> publishArtists() async {
        try {
          final artists = await artistsFuture;
          if (!mounted || requestId != _latestSearchRequest) return;
          setState(() {
            _artistsSearchResult = artists
                .whereType<Map>()
                .map(Map<String, dynamic>.from)
                .toList();
          });
        } catch (e, stackTrace) {
          logger.log(
            'Error while searching online artists',
            error: e,
            stackTrace: stackTrace,
          );
        }
      }

      Future<void> publishAlbums() async {
        try {
          final albums = useItunesCatalog
              ? await _deezerOrAppleAlbums(query)
              : await getPlaylists(query: query, type: 'album');
          if (!mounted || requestId != _latestSearchRequest) return;
          setState(() => _albumsSearchResult = albums);
        } catch (e, stackTrace) {
          logger.log(
            'Error while searching online albums',
            error: e,
            stackTrace: stackTrace,
          );
        }
      }

      Future<void> publishPlaylists() async {
        try {
          final playlists = useItunesCatalog
              ? await deezerSearchPlaylists(query)
              : await getPlaylists(query: query, type: 'playlist');
          if (!mounted || requestId != _latestSearchRequest) return;
          setState(() => _playlistsSearchResult = playlists);
        } catch (e, stackTrace) {
          logger.log(
            'Error while searching online playlists',
            error: e,
            stackTrace: stackTrace,
          );
        }
      }

      await Future.wait([
        publishSongs(),
        publishArtists(),
        publishAlbums(),
        publishPlaylists(),
      ]);
    } catch (e, stackTrace) {
      logger.log(
        'Error while searching online songs',
        error: e,
        stackTrace: stackTrace,
      );
    } finally {
      if (requestId == _latestSearchRequest) {
        _fetchingSongs.value = false;
        if (mounted) setState(() {});
      }
    }
  }

  Future<List<dynamic>> _fetchSongsForResolvedArtist(String query) async {
    final artistName = _artistsSearchResult.first['title']?.toString().trim();
    if (artistName == null || artistName.isEmpty) return [];

    final fallbackQueries = <String>{
      if (artistName.toLowerCase() != query.trim().toLowerCase()) artistName,
      '$artistName songs',
      '$artistName music',
    };

    for (final fallbackQuery in fallbackQueries) {
      final songs = await fetchSongsList(fallbackQuery);
      if (songs.isNotEmpty) return songs;
    }

    return [];
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final showHistory =
        _suggestionsList.isNotEmpty ||
        (_inputNode.hasFocus &&
            _libraryMatches(_searchBar.text, max: 1).isNotEmpty) ||
        _liveArtists.isNotEmpty ||
        _liveSongs.isNotEmpty ||
        (_songsSearchResult.isEmpty &&
            _artistsSearchResult.isEmpty &&
            _albumsSearchResult.isEmpty &&
            _playlistsSearchResult.isEmpty &&
            _radioStationsSearchResult.isEmpty &&
            _topResult == null);

    // Muzika: Search is a tab page of its own (no sliding sheet).
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
              child: Row(
                children: [
                  const SettingsIconButton(),
                  Text(
                    context.l10n!.search,
                    style: muzikaHeading(29, color: scheme.onSurface),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: TextField(
                controller: _searchBar,
                focusNode: _inputNode,
                textInputAction: TextInputAction.search,
                style: muzikaBody(16, color: scheme.onSurface),
                decoration: InputDecoration(
                  hintText: 'Songs, artists or albums',
                  hintStyle: muzikaBody(16, color: scheme.onSurfaceVariant),
                  prefixIcon: const Icon(
                    FluentIcons.search_24_regular,
                    size: 20,
                  ),
                  suffixIcon: _searchBar.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(FluentIcons.dismiss_20_regular),
                          onPressed: () {
                            _searchBar.clear();
                            unawaited(search());
                          },
                        ),
                  filled: true,
                  fillColor: scheme.brightness == Brightness.dark
                      ? scheme.surfaceContainerHigh
                      : const Color(0xFFE6E6EA),
                  contentPadding: const EdgeInsets.symmetric(vertical: 14),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
                onChanged: _onTyped,
                onSubmitted: (_) => _submitSearch(),
              ),
            ),
            if (_fetchingSongs.value &&
                _songsSearchResult.isEmpty &&
                _topResult == null &&
                _suggestionsList.isEmpty &&
                _liveArtists.isEmpty &&
                _liveSongs.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: MuzikaSkeletonRows(count: 8),
              )
            else if (showHistory)
              ValueListenableBuilder<List>(
                valueListenable: searchHistoryNotifier,
                builder: (context, history, _) {
                  final recent = history
                      .whereType<Map>()
                      .where(
                        (entry) =>
                            entry['item'] is Map &&
                            const [
                              'song',
                              'artist',
                              'album',
                              'playlist',
                              'radio',
                            ].contains(entry['kind']),
                      )
                      .toList();
                  final mine = _searchBar.text.trim().isEmpty
                      ? const <Map>[]
                      : _libraryMatches(_searchBar.text);
                  final typing =
                      _suggestionsList.isNotEmpty ||
                      _liveArtists.isNotEmpty ||
                      _liveSongs.isNotEmpty ||
                      mine.isNotEmpty;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (!typing && recent.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(right: 12),
                          child: Row(
                            children: [
                              Expanded(child: _sectionTitle('Recent')),
                              Padding(
                                padding: const EdgeInsets.only(top: 14),
                                child: TextButton(
                                  onPressed: _clearRecent,
                                  child: const Text('Clear'),
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (!typing)
                        for (final entry in recent) _recentResultRow(entry),
                      // What matches so far: the user's own songs, then
                      // artists, then songs from everywhere.
                      for (final song in mine) _librarySongRow(song),
                      for (final artist in _liveArtists)
                        _entityRow(
                          title: '${artist['title'] ?? ''}',
                          subtitle: 'Artist',
                          image: (artist['image'] ?? artist['lowResImage'])
                              ?.toString(),
                          circular: true,
                          onTap: () {
                            _rememberResult('artist', artist);
                            _openArtist(
                              '${artist['ytid'] ?? artist['title']}',
                              artist,
                            );
                          },
                        ),
                      for (final song in _liveSongs)
                        _entityRow(
                          title: '${song['title'] ?? ''}',
                          subtitle: 'Song · ${song['artist'] ?? ''}',
                          image: (song['lowResImage'] ?? song['image'])
                              ?.toString(),
                          circular: false,
                          trailing: const SizedBox.shrink(),
                          onTap: () {
                            _rememberResult('song', song);
                            _inputNode.unfocus();
                            unawaited(
                              audioHandler.addPlaylistToQueue([
                                song,
                              ], replace: true),
                            );
                          },
                        ),
                      for (final query in _suggestionsList)
                        ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 20,
                          ),
                          leading: Icon(
                            FluentIcons.search_24_regular,
                            color: scheme.onSurfaceVariant,
                          ),
                          title: Text(
                            query,
                            style: muzikaBody(16, color: scheme.onSurface),
                          ),
                          onTap: () => _submitSearch(query),
                        ),
                    ],
                  );
                },
              )
            else
              ..._buildSearchResults(context),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 20, 20, 6),
    child: Text(
      text,
      style: muzikaHeading(20, color: Theme.of(context).colorScheme.onSurface),
    ),
  );

  Widget _entityRow({
    required String title,
    required String subtitle,
    required String? image,
    required bool circular,
    required VoidCallback onTap,
    Widget? trailing,
  }) {
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
            trailing ??
                Icon(
                  FluentIcons.chevron_right_20_regular,
                  color: scheme.onSurfaceVariant,
                ),
          ],
        ),
      ),
    );
  }

  /// Empties Recent at once; a bar offers Undo for five seconds.
  void _clearRecent() {
    final before = searchHistoryNotifier.value;
    searchHistoryNotifier.value = [];
    doWithUndo(
      context,
      'Recent searches cleared',
      undo: () => searchHistoryNotifier.value = before,
      commit: () async => deleteData('user', 'searchHistory'),
    );
  }

  void _rememberResult(String kind, Map item) {
    final id = (item['ytid'] ?? item['id'] ?? item['title'])?.toString();
    if (id == null || id.isEmpty) return;
    final key = '$kind:$id';
    final updated = <Map>[
      {'key': key, 'kind': kind, 'item': Map<String, dynamic>.from(item)},
      for (final entry in searchHistoryNotifier.value.whereType<Map>())
        if (entry['key'] != key && entry['item'] is Map) entry,
    ].take(30).toList();
    searchHistoryNotifier.value = updated;
    unawaited(addOrUpdateData<List>('user', 'searchHistory', updated));
  }

  Widget _recentResultRow(Map entry) {
    final kind = entry['kind'].toString();
    final item = Map<String, dynamic>.from(entry['item'] as Map);
    final subtitle = switch (kind) {
      'song' =>
        'Song${'${item['artist'] ?? ''}'.isEmpty ? '' : ' · ${item['artist']}'}',
      'artist' => 'Artist',
      'album' => 'Album',
      'playlist' => 'Playlist',
      _ => 'Radio',
    };
    return _entityRow(
      title: '${item['title'] ?? item['name'] ?? ''}',
      subtitle: subtitle,
      image: (item['image'] ?? item['lowResImage'])?.toString(),
      circular: kind == 'artist',
      trailing: IconButton(
        tooltip: 'Remove from recent',
        icon: const Icon(FluentIcons.dismiss_20_regular, size: 20),
        onPressed: () {
          final updated = List.from(searchHistoryNotifier.value)
            ..removeWhere(
              (value) => value is Map && value['key'] == entry['key'],
            );
          searchHistoryNotifier.value = updated;
          unawaited(addOrUpdateData<List>('user', 'searchHistory', updated));
        },
      ),
      onTap: () {
        switch (kind) {
          case 'artist':
            _openArtist('${item['ytid'] ?? item['title']}', item);
          case 'album' || 'playlist':
            _openCollection(item, kind: kind);
          case 'radio':
            unawaited(_playRadio(RadioStation.fromMap(item)));
          default:
            _rememberResult('song', item);
            unawaited(audioHandler.addPlaylistToQueue([item], replace: true));
        }
      },
    );
  }

  void _openArtist(String id, Map artist) {
    _rememberResult('artist', artist);
    context.push(
      '${NavigationManager.searchPath}/artist/${Uri.encodeComponent(id)}',
      extra: artist,
    );
  }

  void _openCollection(Map item, {String kind = 'album'}) {
    _rememberResult(kind, item);
    context.push(NavigationManager.albumPath(context, '${item['ytid']}'));
  }

  Future<void> _playRadio(RadioStation station) async {
    _rememberResult('radio', station.toMap());
    final ok = await audioHandler.playRadioStream(
      id: station.id,
      name: station.name,
      streamUrl: station.streamUrl,
      image: station.image,
      genre: station.genre,
    );
    if (!ok && mounted) {
      showToast(context, context.l10n!.failedPlayingRadio);
    }
  }

  /// Folds case and punctuation so "Bezuayehu  Demissie!" and
  /// "bezuayehu demissie" compare equal.
  static String _norm(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
      .trim();

  /// 0–1 similarity between the query and a name: exact 1, prefix 0.9,
  /// otherwise word-by-word edit-distance closeness (copes with typos).
  static double _similarity(String query, String name) {
    final q = _norm(query);
    final n = _norm(name);
    if (q.isEmpty || n.isEmpty) return 0;
    if (q == n) return 1;
    if (n.startsWith(q) || q.startsWith(n)) return 0.9;
    final qWords = q.split(' ');
    final nWords = n.split(' ');
    var total = 0.0;
    for (final w in qWords) {
      var best = 0.0;
      for (final v in nWords) {
        final longest = w.length > v.length ? w.length : v.length;
        final sim = 1 - _editDistance(w, v) / longest;
        if (sim > best) best = sim;
      }
      total += best;
    }
    return total / qWords.length;
  }

  static int _editDistance(String a, String b) {
    var prev = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 1; i <= a.length; i++) {
      final cur = List<int>.filled(b.length + 1, 0)..[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        cur[j] = min(min(prev[j] + 1, cur[j - 1] + 1), prev[j - 1] + cost);
      }
      prev = cur;
    }
    return prev[b.length];
  }

  /// YouTube Music's own top result or, when the relay gave none, the
  /// artist, album or song whose name is closest to what was typed.
  ({String kind, Map item})? _resolveTopResult() {
    final top = _topResult;
    if (top != null) {
      final image = squareArt(top.thumbnailUrl, 544);
      switch (top.kind) {
        case MusicTopResultKind.artist:
          return (
            kind: 'artist',
            item: {'ytid': top.id, 'title': top.title, 'image': image},
          );
        case MusicTopResultKind.album:
        case MusicTopResultKind.playlist:
          return (
            kind: top.kind == MusicTopResultKind.album ? 'album' : 'playlist',
            item: {
              'ytid': top.id,
              'title': top.title,
              'subtitle': top.subtitle,
              'image': image,
            },
          );
        case MusicTopResultKind.song:
          final song = _songsSearchResult.whereType<Map>().firstWhere(
            (s) => s['ytid'] == top.id,
            orElse: () => {
              'ytid': top.id,
              'title': top.title,
              'artist': (top.subtitle ?? '')
                  .split('•')
                  .map((p) => p.trim())
                  .where((p) => p.isNotEmpty && p != 'Song')
                  .firstOrNull,
              'image': image,
              'lowResImage': image,
            },
          );
          return (kind: 'song', item: song);
      }
    }

    final query = _searchBar.text.trim();
    final candidates = <({String kind, Map item, double score})>[
      for (final a in _artistsSearchResult.take(2))
        (
          kind: 'artist',
          item: a,
          score: _similarity(query, '${a['title'] ?? ''}') + 0.05,
        ),
      for (final a in _albumsSearchResult.whereType<Map>().take(2))
        (
          kind: 'album',
          item: a,
          score: _similarity(query, '${a['title'] ?? ''}') + 0.02,
        ),
      for (final s in _songsSearchResult.whereType<Map>().take(3))
        (kind: 'song', item: s, score: _similarity(query, '${s['title']}')),
    ];
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) => b.score.compareTo(a.score));
    final best = candidates.first;
    return best.score >= 0.6 ? (kind: best.kind, item: best.item) : null;
  }

  Widget _topResultCard(({String kind, Map item}) top) {
    final scheme = Theme.of(context).colorScheme;
    final item = top.item;
    final subtitle = switch (top.kind) {
      'artist' => 'Artist',
      'album' => (item['subtitle'] ?? 'Album').toString(),
      'playlist' => (item['subtitle'] ?? 'Playlist').toString(),
      _ => 'Song · ${item['artist'] ?? ''}',
    };
    void open() {
      switch (top.kind) {
        case 'artist':
          _openArtist('${item['ytid']}', item);
        case 'album' || 'playlist':
          _openCollection(item, kind: top.kind);
        default:
          _rememberResult('song', item);
          unawaited(audioHandler.addPlaylistToQueue([item], replace: true));
      }
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
      child: Material(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: open,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                MuzikaCover(
                  song: item,
                  size: 84,
                  radius: top.kind == 'artist' ? 42 : 10,
                  highRes: true,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${item['title'] ?? ''}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: muzikaHeading(20, color: scheme.onSurface),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: muzikaBody(14, color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                if (top.kind == 'song')
                  MuzikaRoundButton(
                    icon: FluentIcons.play_24_filled,
                    filled: true,
                    tooltip: context.l10n!.play,
                    onPressed: open,
                  )
                else
                  Icon(
                    FluentIcons.chevron_right_20_regular,
                    color: scheme.onSurfaceVariant,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildSearchResults(BuildContext context) {
    final top = _resolveTopResult();
    final topId = top?.item['ytid']?.toString();
    bool notTop(Object? item) =>
        item is! Map || item['ytid']?.toString() != topId;

    final songs = _songsSearchResult
        .whereType<Map>()
        .where(notTop)
        .take(maxSongsInList)
        .toList();
    final artists = _artistsSearchResult
        .where(notTop)
        .where((a) => (a['ytid'] ?? a['title'] ?? '').toString().isNotEmpty)
        .take(3)
        .toList();

    final songsSection = <Widget>[
      if (songs.isNotEmpty) _sectionTitle(context.l10n!.songs),
      for (final (i, song) in songs.indexed)
        MuzikaSongRow(
          key: listItemKey('search_song', i, song),
          // Just this song: the queue then fills with songs like it, not
          // with the other results (songs that only share its name).
          song: song,
          onSelect: () => _rememberResult('song', song),
        ),
    ];

    final artistsSection = <Widget>[
      if (artists.isNotEmpty) _sectionTitle(context.l10n!.artists),
      for (final artist in artists)
        _entityRow(
          title: artist['title']?.toString() ?? '',
          subtitle: 'Artist',
          image: artist['image']?.toString(),
          circular: true,
          onTap: () => _openArtist(
            (artist['ytid'] ?? artist['title']).toString(),
            artist,
          ),
        ),
    ];

    List<Widget> collectionSection(List items, String title, String kind) {
      final visible = items
          .whereType<Map>()
          .where(notTop)
          .where((i) => (i['ytid']?.toString() ?? '').isNotEmpty)
          .take(maxSongsInList)
          .toList();
      return [
        if (visible.isNotEmpty) _sectionTitle(title),
        for (final item in visible)
          _entityRow(
            title: item['title']?.toString() ?? '',
            subtitle: (item['subtitle'] ?? kind).toString(),
            image: (item['lowResImage'] ?? item['image'])?.toString(),
            circular: false,
            onTap: () => _openCollection(item, kind: kind.toLowerCase()),
          ),
      ];
    }

    final albums = collectionSection(
      _albumsSearchResult,
      context.l10n!.albums,
      'Album',
    );
    final playlists = collectionSection(
      _playlistsSearchResult,
      context.l10n!.playlists,
      'Playlist',
    );

    // The kind of the top result decides which section follows it.
    final ordered = switch (top?.kind) {
      'artist' => [...artistsSection, ...songsSection, ...albums, ...playlists],
      'album' => [...albums, ...songsSection, ...artistsSection, ...playlists],
      'playlist' => [
        ...playlists,
        ...songsSection,
        ...artistsSection,
        ...albums,
      ],
      _ => [...songsSection, ...artistsSection, ...albums, ...playlists],
    };

    final mine = _libraryMatches(_searchBar.text);
    final widgets = <Widget>[
      // The user's own songs lead: what they have before everything else.
      if (mine.isNotEmpty) ...[
        _sectionTitle('In your library'),
        for (final song in mine) _librarySongRow(song),
      ],
      // The best match leads the rest, without a label.
      if (top != null) ...[const SizedBox(height: 8), _topResultCard(top)],
      ...ordered,
    ];

    if (_radioStationsSearchResult.isNotEmpty) {
      widgets.add(_sectionTitle(context.l10n!.radioStations));
      for (final station in _radioStationsSearchResult.take(maxSongsInList)) {
        widgets.add(
          _entityRow(
            title: station.name,
            subtitle: station.genre ?? 'Radio',
            image: station.image,
            circular: false,
            onTap: () => unawaited(_playRadio(station)),
          ),
        );
      }
    }
    return widgets;
  }
}
