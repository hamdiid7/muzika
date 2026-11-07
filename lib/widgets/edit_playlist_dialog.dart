import 'dart:async';

import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muzika/extensions/l10n.dart';
import 'package:muzika/services/desktop_panels.dart';
import 'package:muzika/theme/muzika_tokens.dart';

/// Edit a playlist's name in the Muzika bottom sheet (the same
/// look as "New playlist"); the edited playlist, or null when dismissed.
Future<Map?> showEditPlaylistSheet(BuildContext context, Map playlistData) {
  return showModalBottomSheet<Map?>(
    context: context,
    // Wide Windows layout: the sheet opens in the part it came from.
    useRootNavigator: !desktopPanels.value,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => EditPlaylistDialog(playlistData: playlistData),
  );
}

class EditPlaylistDialog extends StatefulWidget {
  const EditPlaylistDialog({super.key, required this.playlistData});

  final Map playlistData;

  @override
  State<EditPlaylistDialog> createState() => _EditPlaylistDialogState();
}

class _EditPlaylistDialogState extends State<EditPlaylistDialog> {
  late final TextEditingController _title = TextEditingController(
    text: widget.playlistData['title']?.toString() ?? '',
  );

  /// The picture it had stays as it is.
  late final String? _image = widget.playlistData['image']?.toString();

  static const _accent = Color(0xFF2F80ED);

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  void _save() {
    final name = _title.text.trim();
    if (name.isEmpty) return;
    unawaited(HapticFeedback.lightImpact());
    Navigator.pop(context, {
      'ytid': widget.playlistData['ytid'],
      'title': name,
      'source': widget.playlistData['source'] ?? 'user-created',
      if (_image != null && _image.isNotEmpty) 'image': _image,
      'list': widget.playlistData['list'],
      if (widget.playlistData['createdAt'] != null)
        'createdAt': widget.playlistData['createdAt'],
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: const [0, 0.5],
            colors: dark
                ? [scheme.surfaceContainer, scheme.surfaceContainerLow]
                : [const Color(0xFFF3F3F5), scheme.surface],
          ),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  margin: const EdgeInsets.only(top: 12, bottom: 14),
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                child: Text(
                  context.l10n!.editPlaylist,
                  style: muzikaHeading(20, color: scheme.onSurface),
                ),
              ),
              // The grey name box with Save on the right, as in New playlist.
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Container(
                  height: 52,
                  padding: const EdgeInsets.only(left: 16, right: 14),
                  decoration: BoxDecoration(
                    color: dark
                        ? scheme.surfaceContainerHigh
                        : const Color(0xFFE6E6EA),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        FluentIcons.edit_24_regular,
                        size: 20,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: _title,
                          textInputAction: TextInputAction.done,
                          textCapitalization: TextCapitalization.sentences,
                          style: muzikaBody(16, color: scheme.onSurface),
                          cursorColor: scheme.onSurface,
                          decoration: InputDecoration(
                            isCollapsed: true,
                            border: InputBorder.none,
                            hintText: context.l10n!.customPlaylistName,
                            hintStyle: muzikaBody(
                              16,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          onSubmitted: (_) => _save(),
                        ),
                      ),
                      ListenableBuilder(
                        listenable: _title,
                        builder: (context, _) => GestureDetector(
                          onTap: _title.text.trim().isEmpty ? null : _save,
                          child: Text(
                            'Save',
                            style: muzikaBody(
                              14,
                              weight: 500,
                              color: _title.text.trim().isEmpty
                                  ? scheme.onSurfaceVariant
                                  : _accent,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}
