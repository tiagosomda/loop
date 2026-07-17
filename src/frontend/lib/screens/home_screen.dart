import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/board_service.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/brand_logo.dart';
import '../widgets/widgets.dart';
import 'item_screen.dart';
import 'new_item_sheet.dart';
import 'profile_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final Set<String> _selectedIds = {};

  bool get _selectionMode => _selectedIds.isNotEmpty;

  void _setSelected(String itemId, bool selected) {
    setState(() {
      if (selected) {
        _selectedIds.add(itemId);
      } else {
        _selectedIds.remove(itemId);
      }
    });
  }

  void _clearSelection() => setState(_selectedIds.clear);

  void _toggleAllVisible(List<ActionItem> visibleItems) {
    final visibleIds = visibleItems.map((item) => item.id).toSet();
    final allSelected =
        visibleIds.isNotEmpty && visibleIds.every(_selectedIds.contains);
    setState(() {
      if (allSelected) {
        _selectedIds.removeAll(visibleIds);
      } else {
        _selectedIds.addAll(visibleIds);
      }
    });
  }

  Future<void> _changeSelectedStatus(BoardService board, String status) async {
    final count = _selectedIds.length;
    try {
      await board.setStatuses(_selectedIds, status);
      if (!mounted) return;
      _clearSelection();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$count item${count == 1 ? '' : 's'} → $status'),
        ),
      );
    } catch (error) {
      if (mounted) _showActionError(context, 'change status', error);
    }
  }

  Future<void> _archiveSelected(BoardService board, AppState app) async {
    final count = _selectedIds.length;
    try {
      if (app.showArchived) {
        await board.unarchiveItems(_selectedIds);
      } else {
        await board.archiveItems(
          _selectedIds,
          closeItems: app.archiveClosesItems,
        );
      }
      if (!mounted) return;
      _clearSelection();
      final verb = app.showArchived ? 'Restored' : 'Archived';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$verb $count item${count == 1 ? '' : 's'}')),
      );
    } catch (error) {
      if (mounted) {
        _showActionError(
          context,
          app.showArchived ? 'restore items' : 'archive items',
          error,
        );
      }
    }
  }

  Future<void> _deleteSelected(BoardService board) async {
    final ids = Set<String>.of(_selectedIds);
    final confirmed = await _confirmDelete(context, ids.length);
    if (!confirmed || !mounted) return;
    try {
      await board.deleteItems(ids);
      if (!mounted) return;
      _clearSelection();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Deleted ${ids.length} item${ids.length == 1 ? '' : 's'}',
          ),
        ),
      );
    } catch (error) {
      if (mounted) _showActionError(context, 'delete items', error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final board = context.read<BoardService>();

    return StreamBuilder<List<ActionItem>>(
      stream: board.items(),
      builder: (context, snap) {
        if (snap.hasError) {
          return Scaffold(body: Center(child: Text('Error: ${snap.error}')));
        }
        if (!snap.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final items = _filtered(snap.data!, app);
        // The renumber fallback needs the *whole* active board (every
        // status, ignoring search/repo filters) to find the real
        // neighbors bounding whatever subset is being reordered — a
        // single kanban column or the filtered list are just subsets of
        // this. See BoardService.reorderItem.
        final allActive = [
          for (final i in snap.data!)
            if (!i.archived) i,
        ]..sort((a, b) => effectiveOrder(a).compareTo(effectiveOrder(b)));
        return Scaffold(
          appBar: _selectionMode
              ? AppBar(
                  leading: IconButton(
                    tooltip: 'Cancel selection',
                    icon: const Icon(Icons.close),
                    onPressed: _clearSelection,
                  ),
                  title: Text('${_selectedIds.length} selected'),
                  actions: [
                    IconButton(
                      tooltip: 'Select all visible items',
                      icon: const Icon(Icons.select_all),
                      onPressed: () => _toggleAllVisible(items),
                    ),
                    PopupMenuButton<String>(
                      tooltip: 'Change status',
                      icon: const Icon(Icons.flag_outlined),
                      onSelected: (status) =>
                          _changeSelectedStatus(board, status),
                      itemBuilder: (context) => [
                        for (final status in itemStatuses)
                          PopupMenuItem(value: status, child: Text(status)),
                      ],
                    ),
                    IconButton(
                      tooltip: app.showArchived ? 'Unarchive' : 'Archive',
                      icon: Icon(
                        app.showArchived
                            ? Icons.unarchive_outlined
                            : Icons.archive_outlined,
                      ),
                      onPressed: () => _archiveSelected(board, app),
                    ),
                    IconButton(
                      tooltip: 'Delete',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => _deleteSelected(board),
                    ),
                  ],
                )
              : AppBar(
                  title: StreamBuilder<ScheduleInfo>(
                    stream: board.schedule(),
                    builder: (context, snapshot) => BrandTitle(
                      scheduleTimes:
                          snapshot.data?.viewerLocalTimes ?? const [],
                    ),
                  ),
                  actions: [
                    IconButton(
                      tooltip: 'Profile',
                      icon: const Icon(Icons.person_outline),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const ProfileScreen(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                ),
          // Hidden in the archive and during selection, where the toolbar
          // actions are the primary affordance.
          floatingActionButton: app.showArchived || _selectionMode
              ? null
              : FloatingActionButton(
                  tooltip: 'New action item',
                  onPressed: () => openNewItemScreen(context),
                  child: const Icon(Icons.add),
                ),
          body: Column(
            children: [
              _BoardControls(app: app),
              // Explicit refresh affordance, on top of RefreshIndicator's own
              // pull animation: RefreshIndicator's swipe-triggered spinner
              // lives inside a ReorderableListView's Scrollable, and a
              // pull-to-refresh that resolves in a handful of milliseconds
              // (a warm local cache, or an offline round-trip that fails
              // fast) can complete before the user perceives it at all. This
              // slim bar is driven by BoardService.isRefreshing directly, so
              // it's always a visible, unambiguous confirmation regardless
              // of gesture recognition or how quickly the fetch resolves.
              ValueListenableBuilder<bool>(
                valueListenable: board.isRefreshing,
                builder: (context, refreshing, _) => AnimatedSwitcher(
                  duration: const Duration(milliseconds: 150),
                  child: refreshing
                      ? const LinearProgressIndicator(
                          key: ValueKey('refreshing'),
                          minHeight: 2,
                        )
                      : const SizedBox(height: 2, key: ValueKey('idle')),
                ),
              ),
              Expanded(
                child: switch (app.boardView) {
                  BoardView.list => _ListView(
                    items: items,
                    showArchived: app.showArchived,
                    selectedIds: _selectedIds,
                    onSelectionChanged: _setSelected,
                    onRefresh: board.refresh,
                    onReorder: (i, j) =>
                        board.reorderItem(items, i, j, allItems: allActive),
                  ),
                  BoardView.kanban => _KanbanView(
                    items: items,
                    statuses: [
                      for (final status in itemStatuses)
                        if (app.statusFilter.contains(status)) status,
                    ],
                    reorderEnabled: !app.showArchived && !_selectionMode,
                    selectedIds: _selectedIds,
                    onSelectionChanged: _setSelected,
                    onRefresh: board.refresh,
                    onReorder: (column, i, j) =>
                        board.reorderItem(column, i, j, allItems: allActive),
                  ),
                  BoardView.projects => _ProjectView(
                    items: items,
                    reorderEnabled: !app.showArchived && !_selectionMode,
                    selectedIds: _selectedIds,
                    onSelectionChanged: _setSelected,
                    onRefresh: board.refresh,
                    onReorder: (project, i, j) =>
                        board.reorderItem(project, i, j, allItems: allActive),
                  ),
                },
              ),
            ],
          ),
        );
      },
    );
  }

  List<ActionItem> _filtered(List<ActionItem> items, AppState app) {
    var result = items.where((i) {
      // Archiving is orthogonal to status: hide archived items from the default
      // board, and in the archived view show only archived ones.
      if (!matchesArchivedView(i, showArchived: app.showArchived)) return false;
      if (!matchesStatusFilter(i, app.statusFilter)) {
        return false;
      }
      if (app.repoFilter != null && i.repoId != app.repoFilter) return false;
      final q = app.search.trim().toLowerCase();
      if (q.isNotEmpty &&
          !i.title.toLowerCase().contains(q) &&
          !i.repoId.toLowerCase().contains(q)) {
        return false;
      }
      return true;
    }).toList();
    // Manual order is the only ordering now — no more sort-by-field menu.
    // Items are picked up by the scheduled agent in this same order (see
    // src/backend/devloop/run.py), so what you see here is what runs next.
    result.sort((a, b) => effectiveOrder(a).compareTo(effectiveOrder(b)));
    return result;
  }
}

void _showActionError(BuildContext context, String action, Object error) {
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text('Failed to $action: $error')));
}

Future<bool> _confirmDelete(BuildContext context, int count) async {
  return await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Delete ${count == 1 ? 'item' : '$count items'}?'),
          content: const Text(
            'This permanently deletes the item, its conversation, run history, '
            'and uploaded attachments. This cannot be undone.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete'),
            ),
          ],
        ),
      ) ??
      false;
}

/// Shows a confirmation dialog, then archives every currently-closed
/// item. Lives at top level (not on [HomeScreen]) so both the screen and
/// [_BoardControls] can trigger it.
Future<void> _archiveClosed(BuildContext context, BoardService board) async {
  final messenger = ScaffoldMessenger.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Archive closed items'),
      content: const Text(
        'Archive every item currently marked closed? They stay searchable '
        'in the archived view and can be restored anytime.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Archive'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;
  try {
    final n = await board.archiveClosed();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          n == 0
              ? 'No closed items to archive'
              : 'Archived $n closed item${n == 1 ? '' : 's'}',
        ),
      ),
    );
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Failed to archive: $e')));
  }
}

class _BoardControls extends StatefulWidget {
  const _BoardControls({required this.app});

  final AppState app;

  @override
  State<_BoardControls> createState() => _BoardControlsState();
}

class _BoardControlsState extends State<_BoardControls> {
  final _searchController = TextEditingController();
  bool _searchVisible = false;

  AppState get app => widget.app;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _toggleSearch() {
    setState(() => _searchVisible = !_searchVisible);
    if (!_searchVisible) {
      // Closing the search bar also clears whatever was typed — otherwise a
      // stale, invisible filter would keep hiding items with no way to tell
      // why the board looks empty.
      _searchController.clear();
      app.setSearch('');
    }
  }

  void _openStatusFilterSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Row(
                children: [
                  Text(
                    'Filter by status',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
            ListenableBuilder(
              listenable: app,
              builder: (context, _) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final status in itemStatuses)
                    CheckboxListTile(
                      value: app.statusFilter.contains(status),
                      onChanged: (_) => app.toggleStatusFilter(status),
                      controlAffinity: ListTileControlAffinity.trailing,
                      secondary: Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppTheme.statusColor(
                            status,
                            Theme.of(context).colorScheme,
                          ),
                        ),
                      ),
                      title: Text(status),
                    ),
                  const Divider(height: 1),
                  CheckboxListTile(
                    value: app.statusFilter.length == itemStatuses.length,
                    onChanged: (selected) =>
                        app.setAllStatusesSelected(selected ?? false),
                    controlAffinity: ListTileControlAffinity.trailing,
                    secondary: const Icon(Icons.select_all),
                    title: const Text('All statuses'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _openArchiveSheet(BoardService board) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Row(
                children: [
                  Text(
                    'Archive',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
            ListTile(
              leading: Icon(
                app.showArchived
                    ? Icons.view_list_outlined
                    : Icons.inventory_2_outlined,
              ),
              title: Text(
                app.showArchived ? 'Show active board' : 'Show archived items',
              ),
              subtitle: Text(
                app.showArchived
                    ? 'Return to items currently in the workflow'
                    : 'Browse items that have been archived',
              ),
              onTap: () {
                Navigator.of(sheetContext).pop();
                app.toggleShowArchived();
              },
            ),
            ListTile(
              leading: const Icon(Icons.archive_outlined),
              title: const Text('Archive all closed items'),
              subtitle: const Text('Move every closed item out of the board'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _archiveClosed(context, board);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final board = context.read<BoardService>();
    final statusFilterIsActive = app.statusFilter.length != itemStatuses.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(
        children: [
          // A single compact row of icon controls — search toggle, status
          // filter, archive actions, and a right-aligned board-view toggle
          // — so everything fits on a narrow phone width without the
          // horizontal-scroll overflow the old chip row had.
          Row(
            children: [
              IconButton(
                tooltip: _searchVisible ? 'Hide search' : 'Search items',
                icon: Icon(_searchVisible ? Icons.search_off : Icons.search),
                onPressed: _toggleSearch,
              ),
              Semantics(
                selected: statusFilterIsActive,
                child: IconButton(
                  tooltip: statusFilterIsActive
                      ? 'Filter by status (active)'
                      : 'Filter by status',
                  // A color shift quietly communicates that the board is
                  // filtered without resembling a notification badge.
                  icon: Icon(
                    Icons.filter_list,
                    color: statusFilterIsActive
                        ? Theme.of(context).colorScheme.primary
                        : null,
                  ),
                  onPressed: _openStatusFilterSheet,
                ),
              ),
              IconButton(
                tooltip: 'Archive options',
                icon: Icon(
                  app.showArchived
                      ? Icons.inventory_2
                      : Icons.inventory_2_outlined,
                ),
                onPressed: () => _openArchiveSheet(board),
              ),
              const Spacer(),
              IconButton(
                tooltip: switch (app.boardView) {
                  BoardView.list => 'Switch to kanban view',
                  BoardView.kanban => 'Switch to project view',
                  BoardView.projects => 'Switch to list view',
                },
                icon: Icon(switch (app.boardView) {
                  BoardView.list => Icons.view_kanban_outlined,
                  BoardView.kanban => Icons.folder_copy_outlined,
                  BoardView.projects => Icons.view_agenda_outlined,
                }),
                onPressed: app.cycleBoardView,
              ),
            ],
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 150),
            crossFadeState: _searchVisible
                ? CrossFadeState.showFirst
                : CrossFadeState.showSecond,
            firstChild: Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: TextField(
                controller: _searchController,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'Search items…',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    tooltip: 'Clear search',
                    onPressed: _toggleSearch,
                  ),
                ),
                onChanged: app.setSearch,
              ),
            ),
            secondChild: const SizedBox(width: double.infinity, height: 0),
          ),
        ],
      ),
    );
  }
}

class _ListView extends StatelessWidget {
  const _ListView({
    required this.items,
    required this.onRefresh,
    required this.onReorder,
    required this.selectedIds,
    required this.onSelectionChanged,
    this.showArchived = false,
  });

  final List<ActionItem> items;
  final Future<void> Function() onRefresh;
  final void Function(int oldIndex, int newIndex) onReorder;
  final bool showArchived;
  final Set<String> selectedIds;
  final void Function(String itemId, bool selected) onSelectionChanged;

  @override
  Widget build(BuildContext context) {
    // Wrap in a RefreshIndicator so the primary board supports pull-to-refresh.
    // AlwaysScrollableScrollPhysics keeps the pull gesture working even when the
    // list is short or empty, so the empty state can be refreshed too.
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: items.isEmpty
          ? LayoutBuilder(
              builder: (context, constraints) => ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                    ),
                    child: Center(
                      child: Text(
                        showArchived
                            ? 'No archived items'
                            : 'No action items — add one with the + button',
                      ),
                    ),
                  ),
                ],
              ),
            )
          // Archived items are a static, no-fuss history — manual order only
          // governs the active board (and, in turn, agent pickup order), so
          // reordering is disabled here.
          : showArchived || selectedIds.isNotEmpty
          ? ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.only(top: 4, bottom: 24),
              itemCount: items.length,
              itemBuilder: (context, i) => _ActionableItemCard(
                item: items[i],
                selected: selectedIds.contains(items[i].id),
                selectionMode: selectedIds.isNotEmpty,
                onSelectionChanged: (selected) =>
                    onSelectionChanged(items[i].id, selected),
              ),
            )
          : ReorderableListView.builder(
              buildDefaultDragHandles: false,
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.only(top: 4, bottom: 24),
              itemCount: items.length,
              onReorderItem: onReorder,
              proxyDecorator: dragProxyDecorator,
              itemBuilder: (context, i) => _ActionableItemCard(
                key: ValueKey(items[i].id),
                item: items[i],
                dragHandle: DragHandle(index: i),
                selected: selectedIds.contains(items[i].id),
                selectionMode: selectedIds.isNotEmpty,
                onSelectionChanged: (selected) =>
                    onSelectionChanged(items[i].id, selected),
              ),
            ),
    );
  }
}

class _KanbanView extends StatelessWidget {
  const _KanbanView({
    required this.items,
    required this.statuses,
    required this.reorderEnabled,
    required this.selectedIds,
    required this.onSelectionChanged,
    required this.onRefresh,
    required this.onReorder,
  });

  final List<ActionItem> items;
  final List<String> statuses;
  final bool reorderEnabled;
  final Set<String> selectedIds;
  final void Function(String itemId, bool selected) onSelectionChanged;
  final Future<void> Function() onRefresh;
  // Manual order applies within each status column too — dragging a card up
  // or down a column reorders it only among that column's items, so a card
  // never has to be dragged across a full board to reach the right spot.
  final void Function(List<ActionItem> column, int oldIndex, int newIndex)
  onReorder;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Size columns to the viewport so a single column reads well in portrait
    // while still leaving a peek of the next one to signal horizontal scroll.
    final width = (MediaQuery.of(context).size.width - 24).clamp(240.0, 320.0);
    return ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
      children: [
        for (final status in statuses)
          Container(
            width: width,
            margin: const EdgeInsets.only(right: 8),
            decoration: BoxDecoration(
              color: scheme.surface.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(AppTheme.radius),
              border: Border.all(
                color: AppTheme.statusColor(
                  status,
                  scheme,
                ).withValues(alpha: 0.25),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                  child: Row(
                    children: [
                      StatusChip(status: status),
                      const SizedBox(width: 8),
                      Text(
                        '${items.where((i) => i.status == status).length}',
                        style: TextStyle(
                          color: scheme.onSurface.withValues(alpha: 0.5),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  // The outer kanban list scrolls horizontally, so a vertical
                  // pull-to-refresh has to live on each column's own vertical
                  // list. AlwaysScrollableScrollPhysics keeps the gesture live
                  // even for short/empty columns.
                  child: RefreshIndicator(
                    onRefresh: onRefresh,
                    child: Builder(
                      builder: (context) {
                        final column = items
                            .where((i) => i.status == status)
                            .toList();
                        if (!reorderEnabled) {
                          return ListView.builder(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: const EdgeInsets.only(bottom: 8),
                            itemCount: column.length,
                            itemBuilder: (context, i) => _ActionableItemCard(
                              item: column[i],
                              selected: selectedIds.contains(column[i].id),
                              selectionMode: selectedIds.isNotEmpty,
                              onSelectionChanged: (selected) =>
                                  onSelectionChanged(column[i].id, selected),
                            ),
                          );
                        }
                        return ReorderableListView.builder(
                          buildDefaultDragHandles: false,
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.only(bottom: 8),
                          itemCount: column.length,
                          onReorderItem: (i, j) => onReorder(column, i, j),
                          proxyDecorator: dragProxyDecorator,
                          itemBuilder: (context, i) => _ActionableItemCard(
                            key: ValueKey(column[i].id),
                            item: column[i],
                            dragHandle: DragHandle(index: i),
                            selected: selectedIds.contains(column[i].id),
                            selectionMode: selectedIds.isNotEmpty,
                            onSelectionChanged: (selected) =>
                                onSelectionChanged(column[i].id, selected),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// A project-first board: each repository gets a horizontally scrollable
/// column, with the same manual ordering semantics as the status columns.
/// This makes it easy to scan one codebase's full workflow without losing the
/// status context carried by each card's status chip.
class _ProjectView extends StatelessWidget {
  const _ProjectView({
    required this.items,
    required this.reorderEnabled,
    required this.selectedIds,
    required this.onSelectionChanged,
    required this.onRefresh,
    required this.onReorder,
  });

  final List<ActionItem> items;
  final bool reorderEnabled;
  final Set<String> selectedIds;
  final void Function(String itemId, bool selected) onSelectionChanged;
  final Future<void> Function() onRefresh;
  final void Function(List<ActionItem> project, int oldIndex, int newIndex)
  onReorder;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final width = (MediaQuery.of(context).size.width - 24).clamp(260.0, 360.0);
    final projectIds = <String>[];
    for (final item in items) {
      if (!projectIds.contains(item.repoId)) projectIds.add(item.repoId);
    }

    return ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
      children: [
        for (final projectId in projectIds)
          Builder(
            builder: (context) {
              final project = items
                  .where((item) => item.repoId == projectId)
                  .toList();
              return Container(
                width: width,
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  color: scheme.surface.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(AppTheme.radius),
                  border: Border.all(
                    color: scheme.primary.withValues(alpha: 0.2),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                      child: Row(
                        children: [
                          Icon(
                            Icons.folder_outlined,
                            size: 18,
                            color: scheme.primary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              repoShortName(projectId),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Text(
                            '${project.length}',
                            style: TextStyle(
                              color: scheme.onSurface.withValues(alpha: 0.5),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: RefreshIndicator(
                        onRefresh: onRefresh,
                        child: reorderEnabled
                            ? ReorderableListView.builder(
                                buildDefaultDragHandles: false,
                                physics: const AlwaysScrollableScrollPhysics(),
                                padding: const EdgeInsets.only(bottom: 8),
                                itemCount: project.length,
                                onReorderItem: (i, j) =>
                                    onReorder(project, i, j),
                                proxyDecorator: dragProxyDecorator,
                                itemBuilder: (context, i) =>
                                    _ActionableItemCard(
                                      key: ValueKey(project[i].id),
                                      item: project[i],
                                      dragHandle: DragHandle(index: i),
                                      selected: selectedIds.contains(
                                        project[i].id,
                                      ),
                                      selectionMode: selectedIds.isNotEmpty,
                                      onSelectionChanged: (selected) =>
                                          onSelectionChanged(
                                            project[i].id,
                                            selected,
                                          ),
                                    ),
                              )
                            : ListView.builder(
                                physics: const AlwaysScrollableScrollPhysics(),
                                padding: const EdgeInsets.only(bottom: 8),
                                itemCount: project.length,
                                itemBuilder: (context, i) =>
                                    _ActionableItemCard(
                                      item: project[i],
                                      selected: selectedIds.contains(
                                        project[i].id,
                                      ),
                                      selectionMode: selectedIds.isNotEmpty,
                                      onSelectionChanged: (selected) =>
                                          onSelectionChanged(
                                            project[i].id,
                                            selected,
                                          ),
                                    ),
                              ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
      ],
    );
  }
}

/// Board card with Gmail-style selection and two-way swipe affordances. A
/// swipe intentionally settles back into place after opening its action sheet,
/// because both directions offer a choice rather than one destructive default.
class _ActionableItemCard extends StatelessWidget {
  const _ActionableItemCard({
    super.key,
    required this.item,
    required this.selected,
    required this.selectionMode,
    required this.onSelectionChanged,
    this.dragHandle,
  });

  final ActionItem item;
  final bool selected;
  final bool selectionMode;
  final ValueChanged<bool> onSelectionChanged;
  final Widget? dragHandle;

  @override
  Widget build(BuildContext context) {
    return Dismissible(
      key: ValueKey('swipe-${item.id}'),
      direction: selectionMode
          ? DismissDirection.none
          : DismissDirection.horizontal,
      confirmDismiss: selectionMode
          ? null
          : (direction) async {
              if (direction == DismissDirection.startToEnd) {
                await _showStatusActions(context);
              } else {
                await _showArchiveActions(context);
              }
              return false;
            },
      background: _swipeBackground(
        context,
        alignment: Alignment.centerLeft,
        color: Colors.green,
        icon: Icons.task_alt,
        label: 'Complete · close',
      ),
      secondaryBackground: _swipeBackground(
        context,
        alignment: Alignment.centerRight,
        color: Colors.red,
        icon: Icons.archive_outlined,
        label: item.archived ? 'Restore · delete' : 'Archive · delete',
      ),
      child: ItemCard(
        item: item,
        dragHandle: dragHandle,
        selected: selected,
        selectionMode: selectionMode,
        onSelectionChanged: onSelectionChanged,
        onTap: () => openItem(context, item.id),
      ),
    );
  }

  Widget _swipeBackground(
    BuildContext context, {
    required Alignment alignment,
    required Color color,
    required IconData icon,
    required String label,
  }) {
    final onColor =
        ThemeData.estimateBrightnessForColor(color) == Brightness.dark
        ? Colors.white
        : Colors.black;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 20),
      alignment: alignment,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(AppTheme.radius),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: onColor),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(color: onColor, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Future<void> _showStatusActions(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text(
                'Change status',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.task_alt),
              title: const Text('Mark completed'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _setStatus(context, 'completed');
              },
            ),
            ListTile(
              leading: const Icon(Icons.check_circle_outline),
              title: const Text('Mark closed'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _setStatus(context, 'closed');
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _showArchiveActions(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                item.archived ? 'Archived item' : 'Item actions',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            ListTile(
              leading: Icon(
                item.archived
                    ? Icons.unarchive_outlined
                    : Icons.archive_outlined,
              ),
              title: Text(item.archived ? 'Unarchive' : 'Archive'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _toggleArchive(context);
              },
            ),
            ListTile(
              leading: Icon(
                Icons.delete_outline,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                'Delete permanently',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _delete(context);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _setStatus(BuildContext context, String status) async {
    try {
      await context.read<BoardService>().setStatus(item.id, status);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Item marked $status')));
      }
    } catch (error) {
      if (context.mounted) _showActionError(context, 'change status', error);
    }
  }

  Future<void> _toggleArchive(BuildContext context) async {
    final board = context.read<BoardService>();
    final app = context.read<AppState>();
    try {
      if (item.archived) {
        await board.unarchiveItem(item.id);
      } else {
        await board.archiveItem(item.id, closeItem: app.archiveClosesItems);
      }
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(item.archived ? 'Item restored' : 'Item archived'),
          ),
        );
      }
    } catch (error) {
      if (context.mounted) {
        _showActionError(
          context,
          item.archived ? 'restore item' : 'archive item',
          error,
        );
      }
    }
  }

  Future<void> _delete(BuildContext context) async {
    if (!await _confirmDelete(context, 1) || !context.mounted) return;
    try {
      await context.read<BoardService>().deleteItem(item.id);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Item deleted')));
      }
    } catch (error) {
      if (context.mounted) _showActionError(context, 'delete item', error);
    }
  }
}

void openItem(BuildContext context, String itemId) {
  Navigator.of(
    context,
  ).push(MaterialPageRoute(builder: (_) => ItemScreen(itemId: itemId)));
}

/// Grab handle for manual reordering. The glyph stays visually compact, while
/// its full 48×48 touch target starts dragging immediately on movement so it
/// is easy to grab without accidentally long-pressing the card to select it.
class DragHandle extends StatelessWidget {
  const DragHandle({super.key, required this.index});

  final int index;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ReorderableDragStartListener(
      index: index,
      child: MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: SizedBox.square(
          dimension: 48,
          child: Center(
            child: Icon(
              Icons.drag_indicator,
              size: 24,
              color: scheme.onSurface.withValues(alpha: 0.35),
            ),
          ),
        ),
      ),
    );
  }
}

/// Visual feedback for the card currently being dragged: lifted off the
/// list with a cyan glow and a slight tilt, echoing the board's sci-fi
/// accent color so a drag in progress reads as unmistakably different from
/// a static card.
Widget dragProxyDecorator(
  Widget child,
  int index,
  Animation<double> animation,
) {
  return AnimatedBuilder(
    animation: animation,
    builder: (context, _) {
      final t = Curves.easeOut.transform(animation.value);
      final scheme = Theme.of(context).colorScheme;
      return Transform.scale(
        scale: 1 + 0.03 * t,
        child: Transform.rotate(
          angle: 0.01 * t,
          child: Material(
            color: Colors.transparent,
            elevation: 12 * t,
            shadowColor: scheme.primary.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(AppTheme.radius),
            child: child,
          ),
        ),
      );
    },
    child: child,
  );
}
