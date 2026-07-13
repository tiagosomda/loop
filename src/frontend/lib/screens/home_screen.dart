import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../main.dart';
import '../models/models.dart';
import '../services/board_service.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/brand_logo.dart';
import '../widgets/widgets.dart';
import 'item_screen.dart';
import 'new_item_sheet.dart';
import 'profile_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final board = context.read<BoardService>();

    return Scaffold(
      appBar: AppBar(
        title: StreamBuilder<ScheduleInfo>(
          stream: board.schedule(),
          builder: (context, snapshot) => BrandTitle(
            scheduleTimes: snapshot.data?.times ?? const [],
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'New action item',
            icon: const Icon(Icons.add),
            onPressed: () => openNewItemScreen(context),
          ),
          IconButton(
            tooltip: app.showArchived
                ? 'Back to active board'
                : 'View archived items',
            icon: Icon(app.showArchived
                ? Icons.unarchive_outlined
                : Icons.archive_outlined),
            onPressed: app.toggleShowArchived,
          ),
          if (!app.showArchived)
            PopupMenuButton<String>(
              tooltip: 'Board actions',
              icon: const Icon(Icons.more_vert),
              onSelected: (v) {
                if (v == 'archive-completed') {
                  _archiveCompleted(context, board);
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'archive-completed',
                  child: Row(
                    children: [
                      Icon(Icons.archive_outlined, size: 18),
                      SizedBox(width: 10),
                      Text('Archive completed'),
                    ],
                  ),
                ),
              ],
            ),
          const ThemeToggleButton(),
          IconButton(
            tooltip: 'Profile',
            icon: const Icon(Icons.person_outline),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ProfileScreen()),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: StreamBuilder<List<ActionItem>>(
        stream: board.items(),
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(child: Text('Error: ${snap.error}'));
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final items = _filtered(snap.data!, app);
          // The renumber fallback needs the *whole* active board (every
          // status, ignoring search/repo filters) to find the real
          // neighbors bounding whatever subset is being reordered — a
          // single kanban column or the filtered list are just subsets of
          // this. See BoardService.reorderItem.
          final allActive = [
            for (final i in snap.data!)
              if (!i.archived) i
          ]..sort((a, b) => effectiveOrder(a).compareTo(effectiveOrder(b)));
          return Column(
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
                child: app.boardView == BoardView.list
                    ? _ListView(
                        items: items,
                        showArchived: app.showArchived,
                        onRefresh: board.refresh,
                        onReorder: (i, j) => board.reorderItem(
                          items,
                          i,
                          j,
                          allItems: allActive,
                        ),
                      )
                    : _KanbanView(
                        items: items,
                        onRefresh: board.refresh,
                        onReorder: (column, i, j) => board.reorderItem(
                          column,
                          i,
                          j,
                          allItems: allActive,
                        ),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _archiveCompleted(
      BuildContext context, BoardService board) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Archive completed items'),
        content: const Text(
          'Archive every item currently marked completed? They stay searchable '
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
      final n = await board.archiveCompleted();
      messenger.showSnackBar(SnackBar(
        content: Text(n == 0
            ? 'No completed items to archive'
            : 'Archived $n completed item${n == 1 ? '' : 's'}'),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed to archive: $e')));
    }
  }

  List<ActionItem> _filtered(List<ActionItem> items, AppState app) {
    var result = items.where((i) {
      // Archiving is orthogonal to status: hide archived items from the default
      // board, and in the archived view show only archived ones.
      if (!matchesArchivedView(i, showArchived: app.showArchived)) return false;
      if (app.statusFilter.isNotEmpty && !app.statusFilter.contains(i.status)) {
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

class _BoardControls extends StatelessWidget {
  const _BoardControls({required this.app});

  final AppState app;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: const InputDecoration(
                    hintText: 'Search items…',
                    prefixIcon: Icon(Icons.search, size: 20),
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(vertical: 10),
                  ),
                  onChanged: app.setSearch,
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                tooltip: app.boardView == BoardView.list
                    ? 'Switch to kanban view'
                    : 'Switch to list view',
                icon: Icon(
                  app.boardView == BoardView.list
                      ? Icons.view_kanban_outlined
                      : Icons.view_agenda_outlined,
                ),
                onPressed: app.cycleBoardView,
              ),
            ],
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 34,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final status in itemStatuses)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: FilterChip(
                      label: Text(status, style: const TextStyle(fontSize: 12)),
                      selected: app.statusFilter.contains(status),
                      selectedColor: AppTheme.statusColor(
                        status,
                        Theme.of(context).colorScheme,
                      ).withValues(alpha: 0.2),
                      onSelected: (_) => app.toggleStatusFilter(status),
                    ),
                  ),
              ],
            ),
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
    this.showArchived = false,
  });

  final List<ActionItem> items;
  final Future<void> Function() onRefresh;
  final void Function(int oldIndex, int newIndex) onReorder;
  final bool showArchived;

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
                    constraints: BoxConstraints(minHeight: constraints.maxHeight),
                    child: Center(
                      child: Text(showArchived
                          ? 'No archived items'
                          : 'No action items — add one with +'),
                    ),
                  ),
                ],
              ),
            )
          // Archived items are a static, no-fuss history — manual order only
          // governs the active board (and, in turn, agent pickup order), so
          // reordering is disabled here.
          : showArchived
              ? ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.only(top: 4, bottom: 24),
                  itemCount: items.length,
                  itemBuilder: (context, i) => ItemCard(
                    item: items[i],
                    onTap: () => openItem(context, items[i].id),
                  ),
                )
              : ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.only(top: 4, bottom: 24),
                  itemCount: items.length,
                  onReorderItem: onReorder,
                  proxyDecorator: dragProxyDecorator,
                  itemBuilder: (context, i) => ItemCard(
                    key: ValueKey(items[i].id),
                    item: items[i],
                    onTap: () => openItem(context, items[i].id),
                    dragHandle: DragHandle(index: i),
                  ),
                ),
    );
  }
}

class _KanbanView extends StatelessWidget {
  const _KanbanView({
    required this.items,
    required this.onRefresh,
    required this.onReorder,
  });

  final List<ActionItem> items;
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
        for (final status in itemStatuses)
          Container(
            width: width,
            margin: const EdgeInsets.only(right: 8),
            decoration: BoxDecoration(
              color: scheme.surface.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(AppTheme.radius),
              border: Border.all(
                color: AppTheme.statusColor(status, scheme)
                    .withValues(alpha: 0.25),
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
                    child: Builder(builder: (context) {
                      final column =
                          items.where((i) => i.status == status).toList();
                      return ReorderableListView.builder(
                        buildDefaultDragHandles: false,
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.only(bottom: 8),
                        itemCount: column.length,
                        onReorderItem: (i, j) => onReorder(column, i, j),
                        proxyDecorator: dragProxyDecorator,
                        itemBuilder: (context, i) => ItemCard(
                          key: ValueKey(column[i].id),
                          item: column[i],
                          onTap: () => openItem(context, column[i].id),
                          dragHandle: DragHandle(index: i),
                        ),
                      );
                    }),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

void openItem(BuildContext context, String itemId) {
  Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => ItemScreen(itemId: itemId)),
  );
}

/// Grab handle for manual reordering: a small grip glyph that only the
/// handle itself starts a drag from, so the rest of the card stays tappable.
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
        child: Padding(
          // Generous hit target — a bare icon is too small to grab reliably,
          // especially on touch.
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
          child: Icon(
            Icons.drag_indicator,
            size: 20,
            color: scheme.onSurface.withValues(alpha: 0.35),
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
Widget dragProxyDecorator(Widget child, int index, Animation<double> animation) {
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
