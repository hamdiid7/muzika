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

import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:material_ui/material_ui.dart';
import 'package:muzika/screens/bottom_navigation_page.dart';

/// Where a message shows: just above the mini player and tab bar (the app
/// shell's messenger), except on full-screen pages of their own, like the
/// player, which show it at their own bottom.
ScaffoldMessengerState _messengerFor(BuildContext context) {
  final own = ScaffoldMessenger.maybeOf(context);
  final shell = BottomNavigationPage.shellMessengerKey.currentState;
  if (own != null &&
      (identical(own, shell) || Scaffold.maybeOf(context) != null)) {
    return own;
  }
  return shell ?? ScaffoldMessenger.of(context);
}

/// Muzika's one kind of message: a rounded bar just above the mini player
/// (or a full-screen page's own bottom), an icon, the text, and a button
/// when it helps ("Undo", "Open"). Every message in the app is this.
ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showMuzikaMessage(
  BuildContext context,
  String text, {
  IconData? icon,
  String? actionLabel,
  VoidCallback? onAction,
  Duration duration = const Duration(seconds: 3),
}) {
  final colorScheme = Theme.of(context).colorScheme;
  final messenger = _messengerFor(context)..hideCurrentSnackBar();
  return messenger.showSnackBar(
    SnackBar(
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      padding: EdgeInsets.fromLTRB(16, 10, actionLabel == null ? 16 : 6, 10),
      content: Row(
        children: [
          Icon(
            icon ?? FluentIcons.checkmark_circle_20_regular,
            color: colorScheme.onSecondaryContainer,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
        ],
      ),
      action: actionLabel == null
          ? null
          : SnackBarAction(label: actionLabel, onPressed: onAction ?? () {}),
      persist: false,
      duration: duration,
    ),
  );
}

void showToast(
  BuildContext context,
  String text, {
  Duration duration = const Duration(seconds: 3),
  IconData? icon,
}) {
  showMuzikaMessage(context, text, icon: icon, duration: duration);
}

void showToastWithButton(
  BuildContext context,
  String text,
  String buttonName,
  VoidCallback onPressedToast, {
  Duration duration = const Duration(seconds: 3),
  IconData? icon,
}) {
  showMuzikaMessage(
    context,
    text,
    icon: icon ?? FluentIcons.info_20_regular,
    actionLabel: buttonName,
    onAction: onPressedToast,
    duration: duration,
  );
}
