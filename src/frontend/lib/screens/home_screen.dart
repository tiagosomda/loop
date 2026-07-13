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
          return Column(
            children: [
              _BoardControls(app: app),
              Expanded(
                child: app.boardView == BoardView.list
                    ? _ListView(items: items)
                    : _KanbanView(items: items),
              ),
            ],
          );
        },
      ),
    );
  }

  List<ActionItem> _filtered(List<ActionItem> items, AppState app) {
    var result = items.where((i) {
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
    result.sort((a, b) => switch (app.sortBy) {
          'created' => (b.createdAt ?? DateTime(0))
              .compareTo(a.createdAt ?? DateTime(0)),
          'title' => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
          _ => (b.updatedAt ?? DateTime(0)).compareTo(a.updatedAt ?? DateTime(0)),
        });
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
              PopupMenuButton<String>(
                tooltip: 'Sort',
                icon: const Icon(Icons.sort),
                onSelected: app.setSortBy,
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'updated', child: Text('Last modified')),
                  PopupMenuItem(value: 'created', child: Text('Created')),
                  PopupMenuItem(value: 'title', child: Text('Title')),
                ],
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
  const _ListView({required this.items});

  final List<ActionItem> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const Center(child: Text('No action items — add one with +'));
    }
    return ListView.builder(
      padding: const EdgeInsets.only(top: 4, bottom: 24),
      itemCount: items.length,
      itemBuilder: (context, i) => ItemCard(
        item: items[i],
        onTap: () => openItem(context, items[i].id),
      ),
    );
  }
}

class _KanbanView extends StatelessWidget {
  const _KanbanView({required this.items});

  final List<ActionItem> items;

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
                  child: ListView(
                    padding: const EdgeInsets.only(bottom: 8),
                    children: [
                      for (final item
                          in items.where((i) => i.status == status))
                        ItemCard(
                          item: item,
                          onTap: () => openItem(context, item.id),
                        ),
                    ],
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
