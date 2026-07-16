import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/models.dart';
import '../services/board_service.dart';
import '../theme/app_theme.dart';

class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.status, this.compact = false});

  final String status;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final color = AppTheme.statusColor(status, Theme.of(context).colorScheme);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 10, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Text(
        status,
        style: TextStyle(
          color: color,
          fontSize: compact ? 11 : 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

String relativeTime(DateTime? time) {
  if (time == null) return '—';
  final diff = DateTime.now().difference(time);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inHours < 1) return '${diff.inMinutes}m ago';
  if (diff.inDays < 1) return '${diff.inHours}h ago';
  if (diff.inDays < 7) return '${diff.inDays}d ago';
  return DateFormat('yyyy-MM-dd').format(time);
}

String repoShortName(String repoId) =>
    repoId.split('__').isEmpty ? repoId : repoId.split('__').last;

class ItemCard extends StatelessWidget {
  const ItemCard({
    super.key,
    required this.item,
    required this.onTap,
    this.dragHandle,
    this.selectionMode = false,
    this.selected = false,
    this.onSelectionChanged,
  });

  final ActionItem item;
  final VoidCallback onTap;
  final bool selectionMode;
  final bool selected;
  final ValueChanged<bool>? onSelectionChanged;

  /// Drag handle for manual reordering (typically a
  /// `ReorderableDragStartListener`-wrapped icon). Null when the card is
  /// shown somewhere reordering doesn't apply (e.g. the archived view).
  final Widget? dragHandle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: selectionMode
            ? () => onSelectionChanged?.call(!selected)
            : onTap,
        onLongPress: onSelectionChanged == null
            ? null
            : () => onSelectionChanged?.call(true),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (selectionMode) ...[
                    Checkbox(
                      value: selected,
                      visualDensity: VisualDensity.compact,
                      onChanged: (value) =>
                          onSelectionChanged?.call(value ?? false),
                    ),
                    const SizedBox(width: 4),
                  ] else if (dragHandle != null) ...[
                    dragHandle!,
                    const SizedBox(width: 4),
                  ],
                  Expanded(
                    child: Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  StatusChip(status: item.status, compact: true),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _meta(
                    Icons.folder_outlined,
                    repoShortName(item.repoId),
                    scheme,
                  ),
                  _meta(Icons.schedule, relativeTime(item.updatedAt), scheme),
                  if (item.messageCount > 0)
                    _meta(
                      Icons.chat_bubble_outline,
                      '${item.messageCount}',
                      scheme,
                    ),
                  if (item.model != null && item.model != 'default')
                    _meta(Icons.memory, item.model!, scheme),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _meta(IconData icon, String label, ColorScheme scheme) {
    final color = scheme.onSurface.withValues(alpha: 0.6);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 12, color: color)),
      ],
    );
  }
}

/// Renders an attachment: inline preview for images, download chip otherwise.
class AttachmentView extends StatelessWidget {
  const AttachmentView({super.key, required this.attachment, this.onOpenImage});

  final Attachment attachment;
  final VoidCallback? onOpenImage;

  @override
  Widget build(BuildContext context) {
    final board = context.read<BoardService>();
    return FutureBuilder<String>(
      future: board.downloadUrl(attachment),
      builder: (context, snap) {
        if (!snap.hasData) {
          return Chip(
            avatar: const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            label: Text(attachment.name),
          );
        }
        final url = snap.data!;
        if (attachment.isImage) {
          return Semantics(
            button: true,
            excludeSemantics: true,
            label: 'Open ${attachment.name} in image gallery',
            child: Tooltip(
              message: 'Open ${attachment.name}',
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: onOpenImage,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxHeight: 240,
                      maxWidth: 320,
                    ),
                    child: attachment.isSvg
                        ? SvgPicture.network(
                            url,
                            fit: BoxFit.contain,
                            semanticsLabel: attachment.name,
                          )
                        : Image.network(
                            url,
                            fit: BoxFit.contain,
                            semanticLabel: attachment.name,
                          ),
                  ),
                ),
              ),
            ),
          );
        }
        return ActionChip(
          avatar: const Icon(Icons.attach_file, size: 16),
          label: Text(attachment.name),
          onPressed: () => launchUrl(Uri.parse(url)),
        );
      },
    );
  }
}
