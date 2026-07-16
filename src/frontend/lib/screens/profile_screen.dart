import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/board_service.dart';
import '../state/app_state.dart';
import '../widgets/widgets.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  String _repoSearch = '';

  String _scheduleLabel(DateTime run) =>
      DateFormat('h:mm a').format(run.toLocal());

  List<ScheduledSession> _sortedSessionTimes(List<ScheduledSession> sessions) {
    final unique = <String, ScheduledSession>{};
    for (final session in sessions) {
      final local = session.startsAt.toLocal();
      final key = '${session.kind}:${local.hour}:${local.minute}';
      unique.putIfAbsent(key, () => session);
    }
    return unique.values.toList()..sort((a, b) {
      final aLocal = a.startsAt.toLocal();
      final bLocal = b.startsAt.toLocal();
      return (aLocal.hour * 60 + aLocal.minute).compareTo(
        bLocal.hour * 60 + bLocal.minute,
      );
    });
  }

  bool _isNextSession(ScheduledSession session, ScheduledSession? nextSession) {
    if (nextSession == null || session.kind != nextSession.kind) return false;
    final local = session.startsAt.toLocal();
    final nextLocal = nextSession.startsAt.toLocal();
    return local.hour == nextLocal.hour && local.minute == nextLocal.minute;
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final board = context.read<BoardService>();
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('PROFILE')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              CircleAvatar(
                backgroundColor: scheme.primary.withValues(alpha: 0.15),
                child: Icon(Icons.person, color: scheme.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      app.user?.displayName ?? 'tiago',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      app.user?.email ?? '',
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.logout, size: 16),
                label: const Text('Log out'),
                onPressed: () async {
                  await app.signOut();
                  if (context.mounted) Navigator.of(context).pop();
                },
              ),
            ],
          ),
          const SizedBox(height: 24),
          Text(
            'SETTINGS',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              letterSpacing: 1.5,
              color: scheme.primary,
            ),
          ),
          const SizedBox(height: 8),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.brightness_6_outlined),
                  const SizedBox(width: 12),
                  const Expanded(child: Text('Appearance')),
                  DropdownButton<ThemeMode>(
                    value: app.themeMode,
                    underline: const SizedBox.shrink(),
                    onChanged: (mode) {
                      if (mode != null) app.setThemeMode(mode);
                    },
                    items: const [
                      DropdownMenuItem(
                        value: ThemeMode.system,
                        child: Text('System'),
                      ),
                      DropdownMenuItem(
                        value: ThemeMode.light,
                        child: Text('Light'),
                      ),
                      DropdownMenuItem(
                        value: ThemeMode.dark,
                        child: Text('Dark'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'LOCAL AUTOMATION',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              letterSpacing: 1.5,
              color: scheme.primary,
            ),
          ),
          const SizedBox(height: 8),
          StreamBuilder<ScheduleInfo>(
            stream: board.schedule(),
            builder: (context, snap) {
              final schedule = snap.data;
              if (schedule == null || schedule.times.isEmpty) {
                return const Text('No schedule published yet.');
              }
              final nextSession = schedule.nextSessions.isEmpty
                  ? null
                  : schedule.nextSessions.first;
              final sessionTimes = _sortedSessionTimes(schedule.nextSessions);
              final nextRun = schedule.nextRunsAt.isEmpty
                  ? null
                  : schedule.nextRunsAt.first;
              final runTimes =
                  schedule.nextRunsAt
                      .map((run) => run.toLocal())
                      .fold(<String, DateTime>{}, (unique, run) {
                        unique.putIfAbsent(
                          '${run.hour}:${run.minute}',
                          () => run,
                        );
                        return unique;
                      })
                      .values
                      .toList()
                    ..sort(
                      (a, b) => (a.hour * 60 + a.minute).compareTo(
                        b.hour * 60 + b.minute,
                      ),
                    );
              return Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          if (sessionTimes.isNotEmpty)
                            for (final session in sessionTimes)
                              Tooltip(
                                message:
                                    '${_isNextSession(session, nextSession) ? 'Next · ' : ''}'
                                    '${session.isSelfHealing ? 'Self-healing session' : 'Dev-loop session'}',
                                child: Chip(
                                  backgroundColor:
                                      _isNextSession(session, nextSession)
                                      ? scheme.primaryContainer
                                      : null,
                                  avatar: Icon(
                                    session.isSelfHealing
                                        ? Icons.healing
                                        : Icons.alarm,
                                    size: 14,
                                  ),
                                  label: Text(
                                    _scheduleLabel(session.startsAt),
                                    style: _isNextSession(session, nextSession)
                                        ? const TextStyle(
                                            fontWeight: FontWeight.w600,
                                          )
                                        : null,
                                  ),
                                ),
                              )
                          else
                            for (final label
                                in runTimes.isEmpty
                                    ? (schedule.times.toList()..sort())
                                    : runTimes.map(_scheduleLabel))
                              Chip(
                                avatar: const Icon(Icons.alarm, size: 14),
                                label: Text(
                                  label,
                                  style:
                                      nextRun != null &&
                                          label == _scheduleLabel(nextRun)
                                      ? const TextStyle(
                                          fontWeight: FontWeight.w600,
                                        )
                                      : null,
                                ),
                                backgroundColor:
                                    nextRun != null &&
                                        label == _scheduleLabel(nextRun)
                                    ? scheme.primaryContainer
                                    : null,
                              ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        runTimes.isEmpty && sessionTimes.isEmpty
                            ? 'scheduler times · ${schedule.timezone}'
                            : 'local times · scheduled in ${schedule.timezone}',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'managed by ${schedule.scheduler} · router: '
                        '${schedule.routerAvailable ? 'online' : schedule.routerReason ?? 'unknown'}',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                      if (schedule.providers.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          'workers: ${schedule.providers.map((provider) => '${provider.adapter} '
                              '${!provider.enabled
                                  ? 'disabled'
                                  : provider.available
                                  ? 'online'
                                  : provider.reason ?? 'unavailable'}').join(' · ')}',
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurface.withValues(alpha: 0.6),
                          ),
                        ),
                      ],
                      const SizedBox(height: 4),
                      Text(
                        'last start: ${relativeTime(schedule.lastRunAt)} · '
                        'last finish: ${relativeTime(schedule.lastFinishedAt)}',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                      if (schedule.lastOutcome != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          '${schedule.lastOutcome}: ${schedule.lastSummary ?? ''}',
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurface.withValues(alpha: 0.6),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 24),
          Text(
            'REPOS',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              letterSpacing: 1.5,
              color: scheme.primary,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            decoration: const InputDecoration(
              hintText: 'Search repos…',
              prefixIcon: Icon(Icons.search, size: 20),
              isDense: true,
              contentPadding: EdgeInsets.symmetric(vertical: 10),
            ),
            onChanged: (v) => setState(() => _repoSearch = v),
          ),
          const SizedBox(height: 8),
          StreamBuilder<List<RepoInfo>>(
            stream: board.repos(),
            builder: (context, snap) {
              if (!snap.hasData) {
                return const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final q = _repoSearch.trim().toLowerCase();
              final repos =
                  snap.data!
                      .where(
                        (r) =>
                            q.isEmpty ||
                            r.path.toLowerCase().contains(q) ||
                            r.name.toLowerCase().contains(q),
                      )
                      .toList()
                    ..sort((a, b) => a.path.compareTo(b.path));
              if (repos.isEmpty) return const Text('No repos found.');
              return Column(
                children: [
                  for (final repo in repos)
                    ListTile(
                      dense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                      leading: Icon(
                        repo.host == 'gitlab' ? Icons.merge_type : Icons.code,
                        size: 18,
                        color: repo.status == 'removed'
                            ? scheme.error
                            : scheme.onSurface.withValues(alpha: 0.6),
                      ),
                      title: Text(
                        repo.path.isEmpty ? repo.name : repo.path,
                        style: TextStyle(
                          fontSize: 13,
                          decoration: repo.status == 'removed'
                              ? TextDecoration.lineThrough
                              : null,
                        ),
                      ),
                      subtitle: repo.remote == null
                          ? null
                          : Text(
                              repo.remote!,
                              style: const TextStyle(fontSize: 11),
                              overflow: TextOverflow.ellipsis,
                            ),
                      trailing: repo.status == 'removed'
                          ? IconButton(
                              tooltip: 'Clear removed repo',
                              icon: const Icon(Icons.close, size: 16),
                              onPressed: () => board.clearRemovedRepo(repo.id),
                            )
                          : null,
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
