import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/board_service.dart';
import 'home_screen.dart';

/// Opens the full-screen "new action item" composer.
Future<void> openNewItemScreen(BuildContext context) {
  return Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => const NewItemScreen(),
      fullscreenDialog: true,
    ),
  );
}

class NewItemScreen extends StatefulWidget {
  const NewItemScreen({super.key});

  @override
  State<NewItemScreen> createState() => _NewItemScreenState();
}

class _NewItemScreenState extends State<NewItemScreen> {
  final _title = TextEditingController();
  final _message = TextEditingController();
  String? _repoId;
  String? _provider;
  String? _model;
  String? _effort;
  bool _customizeRouting = false;
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
    return Scaffold(
      appBar: AppBar(
        titleTextStyle: Theme.of(context).textTheme.titleMedium,
        leading: IconButton(
          tooltip: 'Close',
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: const Text('New action item'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          children: [
            TextField(
              controller: _title,
              autofocus: true,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: 'Title'),
            ),
            const SizedBox(height: 12),
            StreamBuilder<List<RepoInfo>>(
              stream: board.repos(),
              builder: (context, snap) {
                final repos =
                    (snap.data ?? [])
                        .where((r) => r.status == 'active')
                        .toList()
                      ..sort((a, b) => _repoLabel(a).compareTo(_repoLabel(b)));
                return _RepoAutocomplete(
                  repos: repos,
                  onSelected: (id) => setState(() => _repoId = id),
                );
              },
            ),
            const SizedBox(height: 12),
            StreamBuilder<RoutingCatalog>(
              stream: board.routingCatalog(),
              builder: (context, snapshot) => _RoutingPreferences(
                catalog:
                    snapshot.data ??
                    const RoutingCatalog(catalogVersion: '', targets: []),
                expanded: _customizeRouting,
                provider: _provider,
                model: _model,
                effort: _effort,
                onExpanded: (value) =>
                    setState(() => _customizeRouting = value),
                onProvider: (value) => setState(() {
                  _provider = value;
                  _model = null;
                }),
                onModel: (value) => setState(() => _model = value),
                onEffort: (value) => setState(() => _effort = value),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _message,
              minLines: 4,
              maxLines: 10,
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
            const SizedBox(height: 20),
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
          _pending.add(
            PendingAttachment(
              name: f.name,
              bytes: f.bytes!,
              contentType: 'application/octet-stream',
            ),
          );
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
        requestedProvider: _provider,
        requestedModel: _model,
        requestedEffort: _effort,
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to create: $e')));
      }
    }
  }
}

class _RoutingPreferences extends StatelessWidget {
  const _RoutingPreferences({
    required this.catalog,
    required this.expanded,
    required this.provider,
    required this.model,
    required this.effort,
    required this.onExpanded,
    required this.onProvider,
    required this.onModel,
    required this.onEffort,
  });

  final RoutingCatalog catalog;
  final bool expanded;
  final String? provider;
  final String? model;
  final String? effort;
  final ValueChanged<bool> onExpanded;
  final ValueChanged<String?> onProvider;
  final ValueChanged<String?> onModel;
  final ValueChanged<String?> onEffort;

  @override
  Widget build(BuildContext context) {
    final selected = catalog.targetForAdapter(provider);
    final models = selected?.models ?? const <String>[];
    final efforts = selected?.effortLevels ?? effortOptions.skip(1).toList();
    return ExpansionTile(
      key: const ValueKey('routing-preferences'),
      initiallyExpanded: expanded,
      onExpansionChanged: onExpanded,
      tilePadding: EdgeInsets.zero,
      childrenPadding: EdgeInsets.zero,
      title: const Text('Execution: Automatic'),
      subtitle: const Text('The local router will choose an available worker.'),
      children: [
        DropdownButtonFormField<String?>(
          key: ValueKey('provider-$provider'),
          initialValue: provider,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Provider'),
          items: [
            const DropdownMenuItem(value: null, child: Text('Auto')),
            for (final adapter in catalog.providers)
              DropdownMenuItem(value: adapter, child: Text(adapter)),
          ],
          onChanged: onProvider,
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String?>(
          key: ValueKey('model-$provider-$model'),
          initialValue: model,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Model'),
          items: [
            const DropdownMenuItem(value: null, child: Text('Auto')),
            for (final value in models)
              DropdownMenuItem(value: value, child: Text(value)),
          ],
          onChanged: selected == null ? null : onModel,
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String?>(
          key: ValueKey('effort-$provider-$effort'),
          initialValue: effort,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Effort'),
          items: [
            const DropdownMenuItem(value: null, child: Text('Auto')),
            for (final value in efforts)
              DropdownMenuItem(value: value, child: Text(value)),
          ],
          onChanged: onEffort,
        ),
        const SizedBox(height: 8),
        const Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'Codex workers run unattended with full access under your macOS user.',
            style: TextStyle(fontSize: 12),
          ),
        ),
      ],
    );
  }
}

String _repoLabel(RepoInfo r) => r.path.isEmpty ? r.name : r.path;

/// Type-to-filter repo picker built on Flutter's [Autocomplete]. Shows the
/// matching repos as the user types instead of forcing a long dropdown.
class _RepoAutocomplete extends StatelessWidget {
  const _RepoAutocomplete({required this.repos, required this.onSelected});

  final List<RepoInfo> repos;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Autocomplete<RepoInfo>(
      displayStringForOption: _repoLabel,
      optionsBuilder: (value) {
        final q = value.text.trim().toLowerCase();
        if (q.isEmpty) return repos;
        return repos.where(
          (r) =>
              _repoLabel(r).toLowerCase().contains(q) ||
              r.name.toLowerCase().contains(q) ||
              r.id.toLowerCase().contains(q),
        );
      },
      onSelected: (r) => onSelected(r.id),
      fieldViewBuilder: (context, controller, focusNode, onSubmit) {
        return TextField(
          controller: controller,
          focusNode: focusNode,
          decoration: InputDecoration(
            labelText: 'Repo',
            hintText: 'Search repos…',
            prefixIcon: const Icon(Icons.search, size: 20),
            suffixIcon: controller.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear, size: 18),
                    onPressed: () {
                      controller.clear();
                      onSelected(null);
                    },
                  ),
          ),
          onChanged: (_) => onSelected(null),
        );
      },
      optionsViewBuilder: (context, onSelect, options) {
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 8,
            color: Theme.of(context).cardColor,
            surfaceTintColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: Theme.of(context).dividerColor),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 280, maxWidth: 480),
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 4),
                shrinkWrap: true,
                children: [
                  for (final r in options)
                    ListTile(
                      dense: true,
                      title: Text(
                        _repoLabel(r),
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13),
                      ),
                      subtitle: r.remote == null
                          ? null
                          : Text(
                              r.remote!,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                color: scheme.onSurface.withValues(alpha: 0.6),
                              ),
                            ),
                      onTap: () => onSelect(r),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
