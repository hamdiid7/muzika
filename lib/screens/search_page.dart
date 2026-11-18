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
import 'package:muzika/services/muzika_downloads.dart';
import 'package:muzika/services/playlists_manager.dart';
import 'package:muzika/services/router_service.dart';
import 'package:muzika/services/settings_manager.dart';
import 'package:muzika/theme/muzika_tokens.dart';
import 'package:muzika/utilities/app_utils.dart';
import 'package:muzika/utilities/ethiopic_latin.dart';
import 'package:muzika/utilities/flutter_toast.dart';
import 'package:muzika/widgets/muzika_shimmer.dart';
import 'package:muzika/widgets/muzika_song_actions.dart'
    show addToQueueWithToast;
import 'package:muzika/widgets/muzika_song_row.dart';
import 'package:muzika/widgets/overflow_menu_button.dart';
import 'package:muzika/widgets/popup_menu_item.dart';
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

  /// What the last finished search was for, and whether a part of it broke
  /// on the way: with nothing found, the page says so instead of going back
  /// to Recent.
  String? _searchedQuery;
  bool _searchFailed = false;

  /// An Ethiopic search is also run in Latin letters; this is that spelling.
  String? _alsoSearched;

  /// Songs · Artists · Albums · Playlists; null shows them all.
  String? _filter;

  /// The suggested search under the arrow keys, or -1.
  int _highlight = -1;

  /// What scrolls under the box; a new search starts at its top.
  final ScrollController _resultsScroll = ScrollController();

  /// The box's hint goes round these while it is empty.
  static const _hints = [
    'Songs, artists or albums',
    'Try “Aster Aweke”',
    'Try “Tizita”',
    'Try “Teddy Afro”',
    'Try “Ethio jazz”',
  ];
  int _hint = 0;
  Timer? _hintTimer;

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
    song: song,
    onTap: () {
      _inputNode.unfocus();
      unawaited(audioHandler.addPlaylistToQueue([song], replace: true));
    },
  );

  void _onTyped(String value) {
    setState(() => _highlight = -1);
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
    // Offline: no suggestions to fetch; the user's own songs show as they
    // type.
    if (offlineMode.value) return;
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
    _highlight = -1;
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
    _hintTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!mounted || _searchBar.text.isNotEmpty) return;
      setState(() => _hint = (_hint + 1) % _hints.length);
    });
  }

  /// Esc empties the box; the arrows walk the suggested searches (Enter
  /// then runs the one they are on).
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      if (_searchBar.text.isEmpty) return KeyEventResult.ignored;
      _searchBar.clear();
      _onTyped('');
      return KeyEventResult.handled;
    }
    final count = _suggestionsList.length;
    if (count == 0) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.arrowDown) {
      setState(() => _highlight = (_highlight + 1) % count);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      setState(() => _highlight = _highlight <= 0 ? count - 1 : _highlight - 1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _onSubmitted() {
    final picked = _highlight >= 0 && _highlight < _suggestionsList.length
        ? _suggestionsList[_highlight]
        : null;
    unawaited(_submitSearch(picked));
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
    _hintTimer?.cancel();
    _resultsScroll.dispose();
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
      _searchedQuery = null;
      _searchFailed = false;
      _alsoSearched = null;
      _filter = null;
      _fetchingSongs.value = false;
      if (mounted) setState(() {});
      return;
    }
    // Offline: the user's own saved songs, nothing from the internet.
    if (offlineMode.value) {
      _songsSearchResult = _libraryMatches(query, max: 200);
      _artistsSearchResult = [];
      _albumsSearchResult = [];
      _playlistsSearchResult = [];
      _radioStationsSearchResult = [];
      _topResult = null;
      _alsoSearched = null;
      _filter = null;
      _searchedQuery = query;
      _searchFailed = false;
      _fetchingSongs.value = false;
      if (mounted) setState(() {});
      return;
    }
    _fetchingSongs.value = true;
    if (_resultsScroll.hasClients) _resultsScroll.jumpTo(0);
    _searchedQuery = null;
    _searchFailed = false;
    _filter = null;
    var failed = false;

    // Ethiopic letters: the same search again in Latin ones, where most of
    // the catalog's names are, and both lists as one.
    final latin = ethiopicToLatin(query);
    _alsoSearched = latin == null || latin.isEmpty || latin == query
        ? null
        : latin;
    Future<List> also(Future<List> Function(String) run) async {
      final spelled = _alsoSearched;
      if (spelled == null) return run(query);
      Future<List> second() async {
        try {
          return await run(spelled);
        } catch (_) {
          return const [];
        }
      }

      final (first, more) = await (run(query), second()).wait;
      final seen = <String>{};
      return [
        for (final item in [...first, ...more])
          if (item is! Map || seen.add('${item['ytid'] ?? item['title']}'))
            item,
      ];
    }

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
      final artistsFuture = also(searchArtists);

      Future<void> publishSongs() async {
        try {
          var songs = await also(fetchSongsList);
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
          failed = true;
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
          failed = true;
          logger.log(
            'Error while searching online artists',
            error: e,
            stackTrace: stackTrace,
          );
        }
      }

      Future<void> publishAlbums() async {
        try {
          final albums = await also(
            (q) async => useItunesCatalog
                ? await _deezerOrAppleAlbums(q)
                : await getPlaylists(query: q, type: 'album'),
          );
          if (!mounted || requestId != _latestSearchRequest) return;
          setState(() => _albumsSearchResult = albums);
        } catch (e, stackTrace) {
          failed = true;
          logger.log(
            'Error while searching online albums',
            error: e,
            stackTrace: stackTrace,
          );
        }
      }

      Future<void> publishPlaylists() async {
        try {
          final playlists = await also(
            (q) async => useItunesCatalog
                ? await deezerSearchPlaylists(q)
                : await getPlaylists(query: q, type: 'playlist'),
          );
          if (!mounted || requestId != _latestSearchRequest) return;
          setState(() => _playlistsSearchResult = playlists);
        } catch (e, stackTrace) {
          failed = true;
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
      failed = true;
      logger.log(
        'Error while searching online songs',
        error: e,
        stackTrace: stackTrace,
      );
    } finally {
      if (requestId == _latestSearchRequest) {
        _searchedQuery = query;
        _searchFailed = failed;
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

    final nothingFound =
        _songsSearchResult.isEmpty &&
        _artistsSearchResult.isEmpty &&
        _albumsSearchResult.isEmpty &&
        _playlistsSearchResult.isEmpty &&
        _radioStationsSearchResult.isEmpty &&
        _topResult == null;
    // A finished search with nothing to show, and nothing typed since.
    final showNoResults =
        nothingFound &&
        _searchedQuery != null &&
        _searchedQuery == _searchBar.text.trim() &&
        _suggestionsList.isEmpty &&
        _liveArtists.isEmpty &&
        _liveSongs.isEmpty &&
        _libraryMatches(_searchBar.text, max: 1).isEmpty;

    // Muzika: Search is a tab page of its own (no sliding sheet).
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // One line: the tab bar already says this is Search.
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 14, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Focus(
                      canRequestFocus: false,
                      skipTraversal: true,
                      onKeyEvent: _onKey,
                      child: TextField(
                        controller: _searchBar,
                        focusNode: _inputNode,
                        textInputAction: TextInputAction.search,
                        style: muzikaBody(16, color: scheme.onSurface),
                        decoration: InputDecoration(
                          hintText: _hints[_hint],
                          hintStyle: muzikaBody(
                            16,
                            color: scheme.onSurfaceVariant,
                          ),
                          prefixIcon: const Icon(
                            FluentIcons.search_24_regular,
                            size: 20,
                          ),
                          suffixIcon: _searchBar.text.isEmpty
                              ? null
                              : IconButton(
                                  icon: const Icon(
                                    FluentIcons.dismiss_20_regular,
                                  ),
                                  onPressed: () {
                                    _searchBar.clear();
                                    unawaited(search());
                                  },
                                ),
                          filled: true,
                          fillColor: scheme.brightness == Brightness.dark
                              ? scheme.surfaceContainerHigh
                              : const Color(0xFFE6E6EA),
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 11,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                        ),
                        onChanged: _onTyped,
                        onSubmitted: (_) => _onSubmitted(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                controller: _resultsScroll,
                padding: const EdgeInsets.only(bottom: 32),
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                children: [
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
                  else if (showNoResults)
                    _buildNoResults()
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
                              for (final entry in recent)
                                _recentResultRow(entry),
                            // Nothing typed and nothing opened before: what the
                            // box is for.
                            if (!typing &&
                                recent.isEmpty &&
                                _searchBar.text.isEmpty)
                              _buildStartHint(),
                            // What matches so far: the user's own songs, then
                            // artists, then songs from everywhere.
                            for (final song in mine) _librarySongRow(song),
                            for (final artist in _liveArtists)
                              _entityRow(
                                title: '${artist['title'] ?? ''}',
                                subtitle: 'Artist',
                                image:
                                    (artist['image'] ?? artist['lowResImage'])
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
                                song: song,
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
                            for (final (i, query) in _suggestionsList.indexed)
                              _suggestionRow(i, query),
                          ],
                        );
                      },
                    )
                  else
                    ..._buildSearchResults(context),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// A suggested search: what was typed in grey, what it adds in bold. A tap
  /// runs it; the arrow puts it in the box to go on typing.
  Widget _suggestionRow(int index, String query) {
    final scheme = Theme.of(context).colorScheme;
    final typed = _searchBar.text;
    final shared =
        typed.isNotEmpty && query.toLowerCase().startsWith(typed.toLowerCase())
        ? typed.length
        : 0;
    return ListTile(
      contentPadding: const EdgeInsets.only(left: 20, right: 8),
      tileColor: index == _highlight ? scheme.surfaceContainerHigh : null,
      leading: Icon(
        FluentIcons.search_24_regular,
        color: scheme.onSurfaceVariant,
      ),
      title: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: query.substring(0, shared),
              style: muzikaBody(16, color: scheme.onSurfaceVariant),
            ),
            TextSpan(
              text: query.substring(shared),
              style: muzikaBody(
                16,
                weight: shared == 0 ? 400 : 700,
                color: scheme.onSurface,
              ),
            ),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        tooltip: 'Edit this search',
        icon: Icon(
          FluentIcons.arrow_up_left_20_regular,
          color: scheme.onSurfaceVariant,
        ),
        onPressed: () {
          _searchBar.text = '$query ';
          _searchBar.selection = TextSelection.collapsed(
            offset: _searchBar.text.length,
          );
          _inputNode.requestFocus();
          _onTyped(_searchBar.text);
        },
      ),
      onTap: () => _submitSearch(query),
    );
  }

  /// Before anything is typed, with no Recent to show.
  Widget _buildStartHint() {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 72, 32, 0),
      child: Column(
        children: [
          Icon(
            FluentIcons.search_24_regular,
            size: 34,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(height: 14),
          Text(
            'Find any song',
            textAlign: TextAlign.center,
            style: muzikaBody(17, weight: 700, color: scheme.onSurface),
          ),
          const SizedBox(height: 6),
          Text(
            'Search by title, artist or album.',
            textAlign: TextAlign.center,
            style: muzikaBody(14, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  /// The search came back empty. Whether nothing matches or the line broke
  /// can't always be told apart, so it can be tried again either way.
  Widget _buildNoResults() {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 72, 32, 0),
      child: Column(
        children: [
          Icon(
            _searchFailed
                ? FluentIcons.wifi_off_24_regular
                : FluentIcons.music_note_off_2_24_regular,
            size: 34,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(height: 14),
          Text(
            _searchFailed
                ? 'Couldn’t search right now'
                : 'No results for “${_searchedQuery ?? ''}”',
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: muzikaBody(17, weight: 700, color: scheme.onSurface),
          ),
          const SizedBox(height: 6),
          Text(
            _searchFailed
                ? 'Check your connection and try again.'
                : 'Check the spelling, try fewer words, or try again if '
                      'your connection dropped.',
            textAlign: TextAlign.center,
            style: muzikaBody(14, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 18),
          OutlinedButton.icon(
            onPressed: () => unawaited(search()),
            icon: const Icon(FluentIcons.arrow_clockwise_20_regular),
            label: const Text('Try again'),
          ),
        ],
      ),
    );
  }

  /// Hold or right-click a song: queue it without stopping what's playing.
  void _showSongMenu(Map song) {
    final scheme = Theme.of(context).colorScheme;
    showMuzikaMenu<String>(
      context,
      title: '${song['title'] ?? ''}',
      items: [
        buildPopupMenuItem<String>(
          value: 'next',
          icon: Icons.playlist_play_rounded,
          label: 'Play next',
          colorScheme: scheme,
        ),
        buildPopupMenuItem<String>(
          value: 'queue',
          icon: Icons.queue_music_rounded,
          label: 'Add to queue',
          colorScheme: scheme,
        ),
      ],
      onSelected: (value) async {
        if (value == 'queue') {
          await addToQueueWithToast(context, song);
          return;
        }
        await audioHandler.playNext(song);
        if (mounted) {
          showToast(context, '“${song['title'] ?? ''}” will play next');
        }
      },
    );
  }

  /// Songs · Artists · Albums · Playlists: the picked one white with a small
  /// x (tap it again for everything), as on an artist's page.
  Widget _filterChips(List<(String, String)> chips) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 60,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
        itemCount: chips.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final (key, label) = chips[i];
          final active = key == _filter;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            decoration: BoxDecoration(
              color: active ? scheme.onSurface : scheme.surfaceContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => setState(() => _filter = active ? null : key),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        style: muzikaBody(
                          14,
                          weight: 600,
                          color: active ? scheme.surface : scheme.onSurface,
                        ),
                      ),
                      if (active) ...[
                        const SizedBox(width: 6),
                        Icon(
                          FluentIcons.dismiss_16_regular,
                          size: 14,
                          color: scheme.surface,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          );
        },
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
    Map? song,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      onLongPress: song == null ? null : () => _showSongMenu(song),
      onSecondaryTap: song == null ? null : () => _showSongMenu(song),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
        child: Row(
          children: [
            MuzikaCover(
              song: {'lowResImage': image, 'image': image},
              size: 44,
              radius: circular ? 22 : 8,
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
      song: kind == 'song' ? item : null,
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

  /// How close [name] is to what was typed, in Ethiopic or in its Latin
  /// spelling.
  double _closeness(String name) {
    final query = _searchBar.text.trim();
    final spelled = _alsoSearched;
    return spelled == null
        ? _similarity(query, name)
        : max(_similarity(query, name), _similarity(spelled, name));
  }

  /// Songs by the artist that was typed lead; then the songs whose title,
  /// or artist and title together, are closest. Equally close songs keep
  /// the catalog's order.
  List<Map> _rankSongs(List<Map> songs) {
    int score(Map song) {
      final artist = '${song['artist'] ?? ''}';
      final title = '${song['title'] ?? ''}';
      final byArtist = _closeness(artist);
      final value = byArtist >= 0.85
          ? 2 + byArtist
          : max(_closeness(title), _closeness('$artist $title'));
      return (value * 10).round();
    }

    final ranked =
        [for (final (i, song) in songs.indexed) (i, score(song), song)]..sort(
          (a, b) => a.$2 != b.$2 ? b.$2.compareTo(a.$2) : a.$1.compareTo(b.$1),
        );
    return [for (final entry in ranked) entry.$3];
  }

  /// The sign a song of the user's own carries in the results.
  IconData _libraryMark(Map song) {
    final id = '${song['ytid'] ?? ''}';
    if (isSongAlreadyLiked(id)) return FluentIcons.heart_16_filled;
    if (isSongDownloaded(id)) return FluentIcons.arrow_circle_down_16_filled;
    return FluentIcons.library_16_regular;
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

    double closeness(String name) => _closeness(name);
    final candidates = <({String kind, Map item, double score})>[
      for (final a in _artistsSearchResult.take(2))
        (
          kind: 'artist',
          item: a,
          score: closeness('${a['title'] ?? ''}') + 0.05,
        ),
      for (final a in _albumsSearchResult.whereType<Map>().take(2))
        (
          kind: 'album',
          item: a,
          score: closeness('${a['title'] ?? ''}') + 0.02,
        ),
      for (final s in _songsSearchResult.whereType<Map>().take(3))
        (kind: 'song', item: s, score: closeness('${s['title']}')),
    ];
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) => b.score.compareTo(a.score));
    final best = candidates.first;
    return best.score >= 0.6 ? (kind: best.kind, item: best.item) : null;
  }

  List<Widget> _buildSearchResults(BuildContext context) {
    final top = _resolveTopResult();
    // The best match has no card of its own any more: it stays in its list,
    // and only decides which kind of result comes first.
    bool notTop(Object? item) => true;

    // The user's own songs lead the list, then the rest, closest first.
    final mine = _libraryMatches(_searchBar.text);
    String same(Map song) =>
        _norm('${song['title'] ?? ''} ${song['artist'] ?? ''}');
    final mineIds = {for (final song in mine) '${song['ytid']}'};
    final mineNames = {for (final song in mine) same(song)};
    final songs = <Map>[
      ...mine,
      ..._rankSongs(
        _songsSearchResult
            .whereType<Map>()
            .where(notTop)
            .where(
              (song) =>
                  !mineIds.contains('${song['ytid']}') &&
                  !mineNames.contains(same(song)),
            )
            .take(maxSongsInList)
            .toList(),
      ),
    ];
    final artists = _artistsSearchResult
        .where(notTop)
        .where((a) => (a['ytid'] ?? a['title'] ?? '').toString().isNotEmpty)
        .take(12)
        .toList();

    final songsSection = <Widget>[
      if (songs.isNotEmpty) _sectionTitle(context.l10n!.songs),
      for (final (i, song) in songs.indexed)
        MuzikaSongRow(
          key: listItemKey('search_song', i, song),
          // Just this song: the queue then fills with songs like it, not
          // with the other results (songs that only share its name).
          song: song,
          dense: true,
          showAddButton: false,
          showDownloadButton: false,
          showMoreButton: true,
          mark: i < mine.length ? _libraryMark(song) : null,
          onSelect: () => _rememberResult('song', song),
        ),
    ];

    final scheme = Theme.of(context).colorScheme;
    final artistsSection = <Widget>[
      if (artists.isNotEmpty) _sectionTitle(context.l10n!.artists),
      if (artists.isNotEmpty)
        SizedBox(
          height: 108,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
            itemCount: artists.length,
            separatorBuilder: (_, _) => const SizedBox(width: 14),
            itemBuilder: (context, i) {
              final artist = artists[i];
              final image = artist['image']?.toString();
              return InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => _openArtist(
                  (artist['ytid'] ?? artist['title']).toString(),
                  artist,
                ),
                child: SizedBox(
                  width: 76,
                  child: Column(
                    children: [
                      MuzikaCover(
                        song: {'lowResImage': image, 'image': image},
                        size: 68,
                        radius: 34,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        artist['title']?.toString() ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: muzikaBody(12.5, color: scheme.onSurface),
                      ),
                    ],
                  ),
                ),
              );
            },
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

    final chips = [
      if (songsSection.isNotEmpty) ('songs', context.l10n!.songs),
      if (artistsSection.isNotEmpty) ('artists', context.l10n!.artists),
      if (albums.isNotEmpty) ('albums', context.l10n!.albums),
      if (playlists.isNotEmpty) ('playlists', context.l10n!.playlists),
    ];
    if (!chips.any((chip) => chip.$1 == _filter)) _filter = null;
    final picked = switch (_filter) {
      'songs' => songsSection,
      'artists' => artistsSection,
      'albums' => albums,
      'playlists' => playlists,
      _ => null,
    };

    final widgets = <Widget>[...ordered];

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
    return [
      if (offlineMode.value)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
          child: Text(
            'Offline: searching your saved songs only',
            style: muzikaBody(
              13,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      if (_alsoSearched != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
          child: Text(
            'Also searching “$_alsoSearched”',
            style: muzikaBody(13, color: scheme.onSurfaceVariant),
          ),
        ),
      if (chips.length > 1) _filterChips(chips),
      // One kind picked: its rows alone, without their title.
      if (picked != null) ...picked.skip(1) else ...widgets,
    ];
  }
}
