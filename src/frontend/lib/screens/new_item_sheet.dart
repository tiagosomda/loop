import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/board_service.dart';
import 'home_screen.dart';

Future<void> showNewItemSheet(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => const _NewItemSheet(),
  );
}

class _NewItemSheet extends StatefulWidget {
  const _NewItemSheet();

  @override
  State<_NewItemSheet> createState() => _NewItemSheetState();
}

class _NewItemSheetState extends State<_NewItemSheet> {
  final _title = TextEditingController();
  final _message = TextEditingController();
  String? _repoId;
  String _model = 'default';
  String _effort = 'default';
  final List<PendingAttachment> _pending = [];
  bool _saving = false;

  @override
  void dispose() {
    _title.dispose();
    _message.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final board = context.read<BoardService>();
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('New action item',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 16),
            TextField(
              controller: _title,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Title'),
            ),
            const SizedBox(height: 12),
            StreamBuilder<List<RepoInfo>>(
              stream: board.repos(),
              builder: (context, snap) {
                final repos = (snap.data ?? [])
                    .where((r) => r.status == 'active')
                    .toList()
                  ..sort((a, b) => a.id.compareTo(b.id));
                return DropdownButtonFormField<String>(
                  initialValue: _repoId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Repo'),
                  items: [
                    for (final r in repos)
                      DropdownMenuItem(
                        value: r.id,
                        child: Text(r.path.isEmpty ? r.name : r.path,
                            overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (v) => setState(() => _repoId = v),
                );
              },
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _model,
                    decoration: const InputDecoration(labelText: 'Model'),
                    items: [
                      for (final m in modelOptions)
                        DropdownMenuItem(value: m, child: Text(m)),
                    ],
                    onChanged: (v) => setState(() => _model = v ?? 'default'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _effort,
                    decoration: const InputDecoration(labelText: 'Effort'),
                    items: [
                      for (final e in effortOptions)
                        DropdownMenuItem(value: e, child: Text(e)),
                    ],
                    onChanged: (v) => setState(() => _effort = v ?? 'default'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _message,
              minLines: 3,
              maxLines: 8,
              decoration: const InputDecoration(
                labelText: 'Description / first message',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final a in _pending)
                  InputChip(
                    label: Text(a.name, style: const TextStyle(fontSize: 12)),
                    onDeleted: () => setState(() => _pending.remove(a)),
                  ),
                TextButton.icon(
                  icon: const Icon(Icons.attach_file, size: 16),
                  label: const Text('Attach'),
                  onPressed: _pickFiles,
                ),
              ],
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _saving ? null : () => _create(board),
              child: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Create'),
            ),
          ],
        ),
      ),
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
            contentType: 'application/octet-stream',
          ));
        }
      }
    });
  }

  Future<void> _create(BoardService board) async {
    final title = _title.text.trim();
    if (title.isEmpty || _repoId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Title and repo are required')),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      final id = await board.createItem(
        title: title,
        repoId: _repoId!,
        model: _model == 'default' ? null : _model,
        effortLevel: _effort == 'default' ? null : _effort,
        firstMessage: _message.text.trim(),
        attachments: List.of(_pending),
      );
      if (mounted) {
        Navigator.of(context).pop();
        openItem(context, id);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed to create: $e')));
      }
    }
  }
}
