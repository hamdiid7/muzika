import 'package:collection/collection.dart';
import 'package:html/parser.dart' as parser;

import '../../channels/channel_video.dart';
import '../../channels/video_type.dart';
import '../../exceptions/exceptions.dart';
import '../../extensions/helpers_extension.dart';
import '../../retry.dart';
import '../../videos/videos.dart';
import '../models/initial_data.dart';
import '../models/youtube_page.dart';
import '../youtube_http_client.dart';

///
class ChannelUploadPage extends YoutubePage<_InitialData> {
  ///
  final String channelId;

  final VideoType type;

  late final List<ChannelVideo> uploads = initialData.uploads;

  /// InitialData
  ChannelUploadPage.id(this.channelId, this.type, super.initialData)
      : super.fromInitialData();

  ///
  Future<ChannelUploadPage?> nextPage(YoutubeHttpClient httpClient) async {
    if (initialData.token.isEmpty) {
      return null;
    }

    final data = await httpClient.sendContinuation('browse', initialData.token);
    return ChannelUploadPage.id(channelId, type, _InitialData(data, type));
  }

  ///
  static Future<ChannelUploadPage> get(
    YoutubeHttpClient httpClient,
    String channelId,
    String sorting,
    VideoType type,
  ) {
    final url =
        'https://www.youtube.com/channel/$channelId/${type.name}?view=0&sort=$sorting&flow=grid';
    return retry(httpClient, () async {
      final raw = await httpClient.getString(url);
      final page = ChannelUploadPage.parse(raw, channelId, type);
      // Muzika: YouTube ignores `sort=` now and lists the newest first; the
      // Popular / Oldest order is a chip on the page that loads by a
      // continuation token.
      final label = switch (sorting) {
        'p' => 'Popular',
        'da' => 'Oldest',
        _ => null,
      };
      final token = label == null ? null : _chipToken(page.initialData.root, label);
      if (token == null) return page;
      final data = await httpClient.sendContinuation('browse', token);
      return ChannelUploadPage.id(channelId, type, _InitialData(data, type));
    });
  }

  /// The continuation token behind the chip labelled [label], if any.
  static String? _chipToken(dynamic node, String label) {
    if (node is Map) {
      final chip = node['chipViewModel'];
      if (chip is Map && chip['text'] == label) return _firstToken(chip);
      for (final value in node.values) {
        final token = _chipToken(value, label);
        if (token != null) return token;
      }
    } else if (node is List) {
      for (final value in node) {
        final token = _chipToken(value, label);
        if (token != null) return token;
      }
    }
    return null;
  }

  static String? _firstToken(dynamic node) {
    if (node is Map) {
      final command = node['continuationCommand'];
      if (command is Map && command['token'] is String) {
        return command['token'] as String;
      }
      for (final value in node.values) {
        final token = _firstToken(value);
        if (token != null) return token;
      }
    } else if (node is List) {
      for (final value in node) {
        final token = _firstToken(value);
        if (token != null) return token;
      }
    }
    return null;
  }

  ///
  ChannelUploadPage.parse(String raw, this.channelId, this.type)
      : super(parser.parse(raw), (root) => _InitialData(root, type));
}

class _InitialData extends InitialData {
  _InitialData(super.root, this.type);

  final VideoType type;

  late final JsonMap? continuationContext = getContinuationContext();

  late final String token = continuationContext?.getT<String>('token') ??
      continuationContext?.getT<String>('continuation') ??
      '';

  late final List<ChannelVideo> uploads = _getUploads();

  List<ChannelVideo> _getUploads() {
    final content = getContentContext();
    if (content.isEmpty) {
      return const <ChannelVideo>[];
    }
    return content.map(_parseContent).nonNulls.toList();
  }

  List<JsonMap> getContentContext() {
    List<JsonMap>? context;
    if (root.containsKey('contents')) {
      final tabs = root.getJson<List<dynamic>>(
        'contents/twoColumnBrowseResultsRenderer/tabs',
      );
      final selectedTab = tabs
          ?.map((e) => e['tabRenderer'])
          .cast<JsonMap>()
          .firstWhereOrNull((e) => e['selected'] as bool? ?? false);
      var render = selectedTab?.getJson<JsonMap>('content');

      if (render != null) {
        if (render.containsKey('sectionListRenderer')) {
          final sectionContents = render.getJson<List<dynamic>>(
            'sectionListRenderer/contents',
          );
          final firstSection = sectionContents?.firstOrNull as JsonMap?;
          render = firstSection
              ?.getJson<List<dynamic>>(
                'itemSectionRenderer/contents',
              )
              ?.firstOrNull as JsonMap?;

          if (render?.containsKey('gridRenderer') ?? false) {
            context = render
                ?.getJson<List<dynamic>>('gridRenderer/items')
                ?.cast<JsonMap>();
          } else if (render?.containsKey('messageRenderer') ?? false) {
            // Workaround for no-videos.
            context = const [];
          }
        } else if (render.containsKey('richGridRenderer')) {
          context = render
                  .getJson<List<dynamic>>('richGridRenderer/contents')
                  ?.cast<JsonMap>() ??
              const [];
        }
      }
    }
    if (context == null && root.containsKey('onResponseReceivedActions')) {
      // A next page appends items; a chip (Popular, Oldest) reloads them.
      for (final action in root
              .getJson<List<dynamic>>('onResponseReceivedActions')
              ?.whereType<JsonMap>() ??
          const <JsonMap>[]) {
        final items = action.getJson<List<dynamic>>(
              'appendContinuationItemsAction/continuationItems',
            ) ??
            action.getJson<List<dynamic>>(
              'reloadContinuationItemsCommand/continuationItems',
            );
        if (items != null &&
            items.any((e) => e is Map && e['richItemRenderer'] != null)) {
          context = items.cast<JsonMap>();
          break;
        }
      }
    }
    if (context == null) {
      throw FatalFailureException('Failed to get initial data context.', 0);
    }
    return context;
  }

  JsonMap? getContinuationContext() {
    final contentContext = getContentContext();
    final continuationItem = contentContext
        .firstWhereOrNull((e) => e['continuationItemRenderer'] != null);
    final continuationItemRenderer =
        continuationItem?.getJson<JsonMap>('continuationItemRenderer');
    if (continuationItemRenderer != null) {
      final command = continuationItemRenderer.getJson<JsonMap>(
        'continuationEndpoint/continuationCommand',
      );
      if (command != null) {
        return command;
      }
    }
    if (root.containsKey('contents')) {
      final tabs = root.getJson<List<dynamic>>(
        'contents/twoColumnBrowseResultsRenderer/tabs',
      );
      final selectedTab = tabs
          ?.map((e) => e['tabRenderer'])
          .cast<JsonMap>()
          .firstWhereOrNull((e) => e['selected'] as bool? ?? false);
      final sectionContents = selectedTab?.getJson<List<dynamic>>(
        'content/sectionListRenderer/contents',
      );
      final firstSection = sectionContents?.firstOrNull as JsonMap?;
      final firstContentBlock = firstSection
          ?.getJson<List<dynamic>>(
            'itemSectionRenderer/contents',
          )
          ?.firstOrNull as JsonMap?;
      final items =
          firstContentBlock?.getJson<List<dynamic>>('gridRenderer/items');
      final continuationItemFromGrid =
          items?.firstWhereOrNull((e) => e['continuationItemRenderer'] != null)
              as JsonMap?;
      return continuationItemFromGrid?.getJson<JsonMap>(
        'continuationItemRenderer/continuationEndpoint/continuationCommand',
      );
    }
    if (root.containsKey('onResponseReceivedActions')) {
      final actions = root
              .getJson<List<dynamic>>('onResponseReceivedActions')
              ?.whereType<JsonMap>() ??
          const <JsonMap>[];
      final continuationItems = actions
          .map((a) =>
              a.getJson<List<dynamic>>(
                  'appendContinuationItemsAction/continuationItems') ??
              a.getJson<List<dynamic>>(
                  'reloadContinuationItemsCommand/continuationItems'))
          .whereType<List<dynamic>>()
          .lastOrNull;
      final continuationItemFromAction = continuationItems?.firstWhereOrNull(
          (e) => e['continuationItemRenderer'] != null) as JsonMap?;
      return continuationItemFromAction?.getJson<JsonMap>(
        'continuationItemRenderer/continuationEndpoint/continuationCommand',
      );
    }
    return null;
  }

  ChannelVideo? _parseContent(JsonMap? content) {
    if (content == null) {
      return null;
    }

    Map<String, dynamic>? video;
    bool isLockup = false;
    if (content.containsKey('gridVideoRenderer')) {
      video = content.getJson<JsonMap>('gridVideoRenderer');
    } else if (content.containsKey('richItemRenderer')) {
      video = content.getJson<JsonMap>(
        'richItemRenderer/content/${type.youtubeRenderText}',
      );
      if (video == null && type == VideoType.normal) {
        video = content
            .getJson<JsonMap>('richItemRenderer/content/lockupViewModel');
        if (video != null &&
            video['contentType'] == 'LOCKUP_CONTENT_TYPE_VIDEO') {
          isLockup = true;
        } else {
          video = null;
        }
      }
      if (type == VideoType.shorts && video != null) {
        return ChannelVideo(
            VideoId(video.getJson<String>(
                'onTap/innertubeCommand/reelWatchEndpoint/videoId')!),
            video.getJson<String>('overlayMetadata/primaryText/content')!,
            Duration.zero,
            video.getJson<String>('thumbnail/sources/0/url') ??
                video.getJson<String>(
                    'thumbnailViewModel/thumbnailViewModel/image/sources/0/url') ??
                '',
            '',
            _views(video
                .getJson<String>('overlayMetadata/secondaryText/content')));
      }
    }

    if (video == null) {
      return null;
    }

    if (isLockup) {
      // Muzika: YouTube's 2026 lockup puts the title, the length badge and
      // the views under lockupMetadataViewModel and contentImage; the older
      // paths are kept as fallbacks.
      String? badge() {
        final overlays = video!.getJson<List<dynamic>>(
                'contentImage/thumbnailViewModel/overlays') ??
            const [];
        for (final overlay in overlays.whereType<Map>()) {
          final badges = (overlay['thumbnailBottomOverlayViewModel']
                  as Map?)?['badges'] as List? ??
              (overlay['thumbnailOverlayBadgeViewModel']
                  as Map?)?['thumbnailBadges'] as List? ??
              const [];
          for (final b in badges.whereType<Map>()) {
            final text = (b['thumbnailBadgeViewModel'] as Map?)?['text'];
            if (text is String && text.contains(':')) return text;
          }
        }
        return null;
      }

      const meta = 'metadata/lockupMetadataViewModel';
      const parts =
          '$meta/metadata/contentMetadataViewModel/metadataRows/0/metadataParts';
      return ChannelVideo(
        VideoId(video.getJson<String>(
                'rendererContext/commandContext/onTap/innertubeCommand/watchEndpoint/videoId') ??
            video.getT<String>('contentId')!),
        video.getJson<String>('$meta/title/content') ??
            video.getJson<String>('metadata/primaryText/content') ??
            '',
        (badge() ??
                    video.getJson<String>(
                        'imageOverlays/0/thumbnailOverlayTimeStatusRenderer/text/simpleText'))
                ?.toDuration() ??
            Duration.zero,
        video.getJson<String>(
                'contentImage/thumbnailViewModel/image/sources/0/url') ??
            video.getJson<String>(
                'thumbnailViewModel/thumbnailViewModel/image/sources/0/url') ??
            '',
        video.getJson<String>('$parts/1/text/content') ??
            video.getJson<String>('metadata/metadataParts/1/text/content') ??
            '',
        _views(video.getJson<String>('$parts/0/text/content') ??
            video.getJson<String>('metadata/metadataText/content')),
      );
    }

    return ChannelVideo(
      VideoId(video.getT<String>('videoId')!),
      video.getJson<String>('title/simpleText') ??
          video
              .getJson<List<dynamic>>('title/runs')
              ?.map((e) => (e as Map)['text'])
              .join() ??
          '',
      (video.getJson<List<dynamic>>('thumbnailOverlays')?.firstOrNull
                  as JsonMap?)
              ?.getJson<String>(
                'thumbnailOverlayTimeStatusRenderer/text/simpleText',
              )
              ?.toDuration() ??
          Duration.zero,
      (video.getJson<List<dynamic>>('thumbnail/thumbnails')?.last as JsonMap?)
              ?.getT<String>('url') ??
          '',
      video.getJson<String>('publishedTimeText/simpleText') ?? '',
      _views(video.getJson<String>('viewCountText/simpleText')),
    );
  }
}

//

/// Muzika: "878M views", "1.8B views", "12,345 views", "12K views" as a
/// number (the digits alone made 878M into 878).
int _views(String? text) {
  if (text == null) return 0;
  final m = RegExp(r'([\d.,]+)\s*([KMB])?', caseSensitive: false)
      .firstMatch(text);
  if (m == null) return 0;
  final unit = m.group(2)?.toUpperCase();
  if (unit == null) {
    return int.tryParse(m.group(1)!.replaceAll(RegExp(r'[^\d]'), '')) ?? 0;
  }
  final value = double.tryParse(m.group(1)!.replaceAll(',', '.')) ?? 0;
  final times = switch (unit) {
    'K' => 1e3,
    'M' => 1e6,
    _ => 1e9,
  };
  return (value * times).round();
}
