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

import 'package:material_ui/material_ui.dart';
import 'package:muzika/services/tunnel_service.dart';
import 'package:muzika/widgets/custom_bar.dart';

/// Settings row showing how Muzika reaches YouTube, with a picker for the
/// tunnel mode (built-in Psiphon, manual HTTP proxy, or direct).
class TunnelTile extends StatelessWidget {
  const TunnelTile({super.key, this.borderRadius = BorderRadius.zero});

  final BorderRadius borderRadius;

  static String modeLabel(TunnelMode mode) => switch (mode) {
    TunnelMode.psiphon => 'Built-in tunnel (Psiphon)',
    TunnelMode.manual => 'Manual proxy',
    TunnelMode.off => 'Direct connection',
  };

  static String statusLabel(TunnelState s) => switch (s.status) {
    TunnelStatus.connected => s.proxy == null ? 'Connected' : 'Connected',
    TunnelStatus.connecting => 'Connecting…',
    TunnelStatus.off => 'Not tunneled',
    TunnelStatus.unavailable => s.message ?? 'Unavailable',
    TunnelStatus.error => s.message ?? 'Error',
  };

  @override
  Widget build(BuildContext context) {
    final tunnel = TunnelService.instance;
    return ValueListenableBuilder<TunnelState>(
      valueListenable: tunnel.state,
      builder: (context, state, _) {
        return ValueListenableBuilder<TunnelMode>(
          valueListenable: tunnel.mode,
          builder: (context, mode, _) {
            return CustomBar(
              'Connection',
              Icons.shield_outlined,
              description: '${modeLabel(mode)} · ${statusLabel(state)}',
              borderRadius: borderRadius,
              trailing: _StatusDot(status: state.status),
              onTap: () => _showPicker(context),
            );
          },
        );
      },
    );
  }

  Future<void> _showPicker(BuildContext context) async {
    final tunnel = TunnelService.instance;
    final picked = await showModalBottomSheet<TunnelMode>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: RadioGroup<TunnelMode>(
          groupValue: tunnel.mode.value,
          onChanged: (v) => Navigator.pop(context, v),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final m in TunnelMode.values)
                if (m != TunnelMode.psiphon || TunnelService.hasBuiltInTunnel)
                  RadioListTile<TunnelMode>(
                    value: m,
                    title: Text(modeLabel(m)),
                    subtitle: Text(switch (m) {
                      TunnelMode.psiphon =>
                        'Recommended in Ethiopia. Search, audio and images all '
                            'go through the tunnel.',
                      TunnelMode.manual =>
                        'Use your own HTTP proxy (host:port).',
                      TunnelMode.off =>
                        'Catalog and art still come through the Muzika relay.',
                    }),
                  ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !context.mounted) return;

    if (picked == TunnelMode.manual) {
      final controller = TextEditingController(text: tunnel.manualProxy.value);
      final proxy = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('HTTP proxy'),
          content: TextField(
            controller: controller,
            autofocus: true,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(hintText: '203.0.113.5:8080'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('Save'),
            ),
          ],
        ),
      );
      if (proxy == null) return;
      await tunnel.setMode(TunnelMode.manual, proxy: proxy);
    } else {
      await tunnel.setMode(picked);
    }
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.status});

  final TunnelStatus status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      TunnelStatus.connected => const Color(0xFF2E9E5B),
      TunnelStatus.connecting => const Color(0xFFE0A100),
      TunnelStatus.error => Theme.of(context).colorScheme.error,
      _ => Theme.of(context).colorScheme.outline,
    };
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}
