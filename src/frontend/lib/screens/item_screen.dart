import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/models.dart';
import '../services/board_service.dart';
import '../widgets/attachment_gallery.dart';
import '../widgets/widgets.dart';

class ItemScreen extends StatefulWidget {
  const ItemScreen({super.key, required this.itemId});

  final String itemId;

  @override
  State<ItemScreen> createState() => _ItemScreenState();
}

class _ItemScreenState extends State<ItemScreen> {
  final _composer = TextEditingController();
  final List<PendingAttachment> _pending = [];
  bool _sending = false;

  @override
  void dispose() {
    _composer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final board = context.read<BoardService>();
    return StreamBuilder<ActionItem?>(
      stream: board.item(widget.itemId),
      builder: (context, snap) {
        final item = snap.data;
        return Scaffold(
          appBar: AppBar(
            titleTextStyle: Theme.of(context).textTheme.titleMedium,
            title: Text(item?.title ?? '…'),
            actions: [
              if (item != null) _ArchiveButton(item: item),
              if (item != null) _RepoLinkButton(repoId: item.repoId),
              const SizedBox(width: 8),
            ],
          ),
          body: item == null
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    _ItemHeader(item: item),
                    const Divider(height: 1),
                    Expanded(child: _Thread(itemId: item.id)),
                    _Composer(
                      controller: _composer,
                      pending: _pending,
                      sending: _sending,
                      onAttach: _pickFiles,
                      onRemoveAttachment: (a) =>
                          setState(() => _pending.remove(a)),
                      onSend: () => _send(board),
                    ),
                  ],
                ),
        );
      },
    );
  }

  Future<void> _pickFiles() async {
    final result = await FilePicker.pickFiles(
      allowMultiple: true,
      withData: true,
    );
    if (result == null) return;
    setState(() {
      for (final f in result.files) {
        if (f.bytes != null) {
          _pending.add(
            PendingAttachment(
              name: f.name,
              bytes: f.bytes!,
              contentType: _contentType(f.name),
            ),
          );
        }
      }
    });
  }

  String _contentType(String name) {
    final ext = name.split('.').last.toLowerCase();
    const map = {
      'png': 'image/png',
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'gif': 'image/gif',
      'webp': 'image/webp',
      'svg': 'image/svg+xml',
      'pdf': 'application/pdf',
      'txt': 'text/plain',
      'md': 'text/markdown',
      'json': 'application/json',
    };
    return map[ext] ?? 'application/octet-stream';
  }

  Future<void> _send(BoardService board) async {
    final text = _composer.text.trim();
    if (text.isEmpty && _pending.isEmpty) return;
    setState(() => _sending = true);
    try {
      await board.postMessage(
        widget.itemId,
        text,
        attachments: List.of(_pending),
      );
      _composer.clear();
      _pending.clear();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to send: $e')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }
}

class _ItemHeader extends StatelessWidget {
  const _ItemHeader({required this.item});

  final ActionItem item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = scheme.onSurface.withValues(alpha: 0.6);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _StatusPill(item: item),
              const SizedBox(width: 10),
              Expanded(
                child: Row(
                  children: [
                    Icon(Icons.folder_outlined, size: 14, color: muted),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        repoShortName(item.repoId),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: muted),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Icon(Icons.schedule, size: 14, color: muted),
                    const SizedBox(width: 4),
                    Text(
                      'updated ${relativeTime(item.updatedAt)}',
                      style: TextStyle(fontSize: 12, color: muted),
                    ),
                  ],
                ),
              ),
              if (item.status == 'open')
                TextButton(
                  onPressed: () => _editRoutingPreferences(context, item),
                  child: const Text('Customize'),
                ),
            ],
          ),
          StreamBuilder<AgentRun?>(
            stream: context.read<BoardService>().latestRun(item),
            builder: (context, snapshot) {
              final run = snapshot.data;
              if (run == null) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  routingAssignmentSummary(run),
                  style: TextStyle(fontSize: 12, color: muted),
                ),
              );
            },
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(Icons.route_outlined, size: 14, color: muted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _requestedRoutingSummary(item),
                  style: TextStyle(fontSize: 12, color: muted),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

Future<void> _editRoutingPreferences(
  BuildContext context,
  ActionItem item,
) async {
  final board = context.read<BoardService>();
  var provider = item.requestedProvider;
  var model = item.requestedModel;
  var effort = item.requestedEffort;
  final result = await showDialog<List<String?>>(
    context: context,
    builder: (context) => StreamBuilder<RoutingCatalog>(
      stream: board.routingCatalog(),
      builder: (context, snapshot) {
        final catalog =
            snapshot.data ??
            const RoutingCatalog(catalogVersion: '', targets: []);
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final models = catalog.modelsForProvider(provider);
            final efforts = catalog.effortsForProvider(provider);
            return AlertDialog(
              title: const Text('Customize routing'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String?>(
                    initialValue: provider,
                    decoration: const InputDecoration(labelText: 'Provider'),
                    items: [
                      const DropdownMenuItem(value: null, child: Text('Auto')),
                      for (final value in catalog.providers)
                        DropdownMenuItem(value: value, child: Text(value)),
                    ],
                    onChanged: (value) => setDialogState(() {
                      provider = value;
                      if (!catalog.modelsForProvider(value).contains(model)) {
                        model = null;
                      }
                      if (!catalog.effortsForProvider(value).contains(effort)) {
                        effort = null;
                      }
                    }),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String?>(
                    key: ValueKey('edit-model-$provider-$model'),
                    initialValue: model,
                    decoration: const InputDecoration(labelText: 'Model'),
                    items: [
                      const DropdownMenuItem(value: null, child: Text('Auto')),
                      for (final value in models)
                        DropdownMenuItem(value: value, child: Text(value)),
                    ],
                    onChanged: models.isEmpty
                        ? null
                        : (value) => setDialogState(() => model = value),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String?>(
                    key: ValueKey('edit-effort-$provider-$effort'),
                    initialValue: effort,
                    decoration: const InputDecoration(labelText: 'Effort'),
                    items: [
                      const DropdownMenuItem(value: null, child: Text('Auto')),
                      for (final value in efforts)
                        DropdownMenuItem(value: value, child: Text(value)),
                    ],
                    onChanged: efforts.isEmpty
                        ? null
                        : (value) => setDialogState(() => effort = value),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () =>
                      Navigator.pop(context, [provider, model, effort]),
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    ),
  );
  if (result == null) return;
  await board.setRoutingPreferences(
    item.id,
    requestedProvider: result[0],
    requestedModel: result[1],
    requestedEffort: result[2],
  );
}

String _requestedRoutingSummary(ActionItem item) {
  final values = [
    item.requestedProvider,
    item.requestedModel,
    item.requestedEffort,
  ].whereType<String>().toList();
  return values.isEmpty
      ? 'Routing: Automatic'
      : 'Requested: ${values.join(' · ')}';
}

/// Tappable status chip in the item content — tapping it opens the same
/// status-change menu that used to live in the app bar.
class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.item});

  final ActionItem item;

  @override
  Widget build(BuildContext context) {
    final board = context.read<BoardService>();
    return PopupMenuButton<String>(
      tooltip: 'Change status',
      padding: EdgeInsets.zero,
      position: PopupMenuPosition.under,
      onSelected: (s) => board.setStatus(item.id, s),
      itemBuilder: (_) => [
        for (final s in itemStatuses)
          PopupMenuItem(
            value: s,
            child: Row(
              children: [
                if (s == item.status)
                  const Icon(Icons.check, size: 16)
                else
                  const SizedBox(width: 16),
                const SizedBox(width: 8),
                StatusChip(status: s, compact: true),
              ],
            ),
          ),
      ],
      child: StatusChip(status: item.status),
    );
  }
}

/// App-bar toggle to archive/unarchive this single item. Archiving hides it
/// from the default board without touching its status.
class _ArchiveButton extends StatelessWidget {
  const _ArchiveButton({required this.item});

  final ActionItem item;

  @override
  Widget build(BuildContext context) {
    final board = context.read<BoardService>();
    return IconButton(
      tooltip: item.archived ? 'Unarchive' : 'Archive',
      icon: Icon(
        item.archived ? Icons.unarchive_outlined : Icons.archive_outlined,
      ),
      onPressed: () async {
        final messenger = ScaffoldMessenger.of(context);
        if (item.archived) {
          await board.unarchiveItem(item.id);
          messenger.showSnackBar(
            const SnackBar(content: Text('Item unarchived')),
          );
        } else {
          await board.archiveItem(item.id);
          messenger.showSnackBar(
            const SnackBar(content: Text('Item archived')),
          );
        }
      },
    );
  }
}

/// App-bar icon linking out to the item's repo, replacing the old status
/// menu that used to live at the top right.
class _RepoLinkButton extends StatelessWidget {
  const _RepoLinkButton({required this.repoId});

  final String repoId;

  @override
  Widget build(BuildContext context) {
    final board = context.read<BoardService>();
    return StreamBuilder<RepoInfo?>(
      stream: board.repo(repoId),
      builder: (context, snap) {
        final remote = snap.data?.remote;
        return IconButton(
          tooltip: remote == null ? 'No repo remote' : 'Open repo',
          icon: const Icon(Icons.open_in_new),
          onPressed: remote == null
              ? null
              : () => launchUrl(Uri.parse(remote), webOnlyWindowName: '_blank'),
        );
      },
    );
  }
}

class _Thread extends StatelessWidget {
  const _Thread({required this.itemId});

  final String itemId;

  @override
  Widget build(BuildContext context) {
    final board = context.read<BoardService>();
    return StreamBuilder<List<ThreadMessage>>(
      stream: board.messages(itemId),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final messages = snap.data!;
        if (messages.isEmpty) {
          return const Center(child: Text('No messages yet.'));
        }
        final galleryAttachments = imageAttachmentsInThread(messages);
        return ListView.builder(
          reverse: true,
          padding: const EdgeInsets.symmetric(vertical: 12),
          itemCount: messages.length,
          itemBuilder: (context, i) {
            final index = messages.length - 1 - i;
            if (messages[index].kind == 'routing') {
              return _RoutingEventRow(message: messages[index]);
            }
            return _MessageBubble(
              itemId: itemId,
              message: messages[index],
              galleryAttachments: galleryAttachments,
              // "Replied to" = anything exists after it in the thread.
              hasSubsequent: index < messages.length - 1,
            );
          },
        );
      },
    );
  }
}

class _RoutingEventRow extends StatelessWidget {
  const _RoutingEventRow({required this.message});

  final ThreadMessage message;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: 0.6);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Expanded(child: Divider(color: color.withValues(alpha: 0.35))),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              routingEventLabel(message),
              style: TextStyle(fontSize: 12, color: color),
            ),
          ),
          Expanded(child: Divider(color: color.withValues(alpha: 0.35))),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.itemId,
    required this.message,
    required this.hasSubsequent,
    required this.galleryAttachments,
  });

  final String itemId;
  final ThreadMessage message;
  final bool hasSubsequent;
  final List<Attachment> galleryAttachments;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isAgent = message.author == 'agent';
    final accent = isAgent ? scheme.secondary : scheme.primary;
    final faint = scheme.onSurface.withValues(alpha: 0.45);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isAgent ? Icons.smart_toy_outlined : Icons.person_outline,
                size: 14,
                color: accent,
              ),
              const SizedBox(width: 6),
              Text(
                isAgent ? 'agent' : 'tiago',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: accent,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                relativeTime(message.createdAt),
                style: TextStyle(fontSize: 11, color: faint),
              ),
              if (message.editedAt != null) ...[
                const SizedBox(width: 6),
                Text('· edited', style: TextStyle(fontSize: 11, color: faint)),
              ],
              if (!isAgent) ...[
                const Spacer(),
                InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => _edit(context),
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Icon(Icons.edit_outlined, size: 15, color: faint),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: accent.withValues(alpha: 0.25)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (message.text.isNotEmpty)
                  SelectableText(
                    message.text,
                    style: const TextStyle(fontSize: 14, height: 1.45),
                  ),
                if (message.attachments.isNotEmpty) ...[
                  if (message.text.isNotEmpty) const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final a in message.attachments)
                        AttachmentView(
                          attachment: a,
                          onOpenImage: a.isImage
                              ? () => _openGallery(context, a)
                              : null,
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _openGallery(BuildContext context, Attachment attachment) {
    final initialIndex = galleryAttachments.indexOf(attachment);
    if (initialIndex < 0) return;
    final board = context.read<BoardService>();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (context) => AttachmentGallery(
          attachments: galleryAttachments,
          initialIndex: initialIndex,
          resolveUrl: board.downloadUrl,
        ),
      ),
    );
  }

  Future<void> _edit(BuildContext context) async {
    final board = context.read<BoardService>();
    final controller = TextEditingController(text: message.text);
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit message'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (hasSubsequent)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  'This message already has a reply, so the agent likely '
                  "won't pick up the edit — you can still make it.",
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            TextField(
              controller: controller,
              autofocus: true,
              minLines: 3,
              maxLines: 10,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (text == null || text.isEmpty || text == message.text) return;
    await board.editMessage(itemId, message.id, text);
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.pending,
    required this.sending,
    required this.onAttach,
    required this.onRemoveAttachment,
    required this.onSend,
  });

  final TextEditingController controller;
  final List<PendingAttachment> pending;
  final bool sending;
  final VoidCallback onAttach;
  final ValueChanged<PendingAttachment> onRemoveAttachment;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (pending.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final a in pending)
                      InputChip(
                        label: Text(
                          a.name,
                          style: const TextStyle(fontSize: 12),
                        ),
                        onDeleted: () => onRemoveAttachment(a),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  tooltip: 'Attach files',
                  icon: const Icon(Icons.attach_file),
                  onPressed: sending ? null : onAttach,
                ),
                Expanded(
                  child: TextField(
                    controller: controller,
                    minLines: 1,
                    maxLines: 6,
                    decoration: const InputDecoration(
                      hintText: 'Write a message…',
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  tooltip: 'Send',
                  icon: sending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send),
                  onPressed: sending ? null : onSend,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
