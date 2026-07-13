import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/board_service.dart';
import '../theme/app_theme.dart';
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
              if (item != null) _StatusMenu(item: item),
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
          _pending.add(PendingAttachment(
            name: f.name,
            bytes: f.bytes!,
            contentType: _contentType(f.name),
          ));
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
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed to send: $e')));
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
    final board = context.read<BoardService>();
    final muted = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Wrap(
        spacing: 12,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          StatusChip(status: item.status),
          Text(repoShortName(item.repoId),
              style: TextStyle(fontSize: 12, color: muted)),
          Text('updated ${relativeTime(item.updatedAt)}',
              style: TextStyle(fontSize: 12, color: muted)),
          _dropdown(
            'model',
            item.model ?? 'default',
            modelOptions,
            (v) => board.setModelEffort(item.id,
                model: v == 'default' ? null : v,
                effortLevel: item.effortLevel),
          ),
          _dropdown(
            'effort',
            item.effortLevel ?? 'default',
            effortOptions,
            (v) => board.setModelEffort(item.id,
                model: item.model, effortLevel: v == 'default' ? null : v),
          ),
        ],
      ),
    );
  }

  Widget _dropdown(String label, String value, List<String> options,
      ValueChanged<String> onChanged) {
    return DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        value: value,
        isDense: true,
        style: const TextStyle(fontSize: 12),
        items: [
          for (final o in options)
            DropdownMenuItem(value: o, child: Text('$label: $o')),
        ],
        onChanged: (v) => v == null ? null : onChanged(v),
      ),
    );
  }
}

class _StatusMenu extends StatelessWidget {
  const _StatusMenu({required this.item});

  final ActionItem item;

  @override
  Widget build(BuildContext context) {
    final board = context.read<BoardService>();
    return PopupMenuButton<String>(
      tooltip: 'Change status',
      icon: Icon(
        Icons.flag_outlined,
        color: AppTheme.statusColor(item.status, Theme.of(context).colorScheme),
      ),
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
        return ListView.builder(
          reverse: true,
          padding: const EdgeInsets.symmetric(vertical: 12),
          itemCount: messages.length,
          itemBuilder: (context, i) =>
              _MessageBubble(message: messages[messages.length - 1 - i]),
        );
      },
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});

  final ThreadMessage message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isAgent = message.author == 'agent';
    final accent = isAgent ? scheme.secondary : scheme.primary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(isAgent ? Icons.smart_toy_outlined : Icons.person_outline,
                  size: 14, color: accent),
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
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurface.withValues(alpha: 0.45),
                ),
              ),
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
                  SelectableText(message.text,
                      style: const TextStyle(fontSize: 14, height: 1.45)),
                if (message.attachments.isNotEmpty) ...[
                  if (message.text.isNotEmpty) const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final a in message.attachments)
                        AttachmentView(attachment: a),
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
                        label: Text(a.name,
                            style: const TextStyle(fontSize: 12)),
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
