import 'package:cloud_firestore/cloud_firestore.dart';

const itemStatuses = [
  'open',
  'in-progress',
  'needs-review',
  'completed',
  'closed',
];

DateTime? _ts(dynamic v) => v is Timestamp ? v.toDate() : null;

class ActionItem {
  final String id;
  final String title;
  final String repoId;
  final String status;
  final String? model;
  final String? effortLevel;
  final String? requestedProvider;
  final String? requestedModel;
  final String? requestedEffort;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? lastAgentRunAt;
  final int messageCount;
  final bool archived;
  final DateTime? archivedAt;
  final double? order;
  final String? lastRunId;

  ActionItem({
    required this.id,
    required this.title,
    required this.repoId,
    required this.status,
    this.model,
    this.effortLevel,
    this.requestedProvider,
    this.requestedModel,
    this.requestedEffort,
    this.createdAt,
    this.updatedAt,
    this.lastAgentRunAt,
    this.messageCount = 0,
    this.archived = false,
    this.archivedAt,
    this.order,
    this.lastRunId,
  });

  factory ActionItem.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? {};
    return ActionItem(
      id: doc.id,
      title: d['title'] ?? '(untitled)',
      repoId: d['repoId'] ?? '',
      status: d['status'] ?? 'open',
      model: d['model'],
      effortLevel: d['effortLevel'],
      requestedProvider: d['requestedProvider'],
      requestedModel: d['requestedModel'] ?? d['model'],
      requestedEffort: d['requestedEffort'] ?? d['effortLevel'],
      createdAt: _ts(d['createdAt']),
      updatedAt: _ts(d['updatedAt']),
      lastAgentRunAt: _ts(d['lastAgentRunAt']),
      messageCount: (d['messageCount'] ?? 0) as int,
      archived: d['archived'] == true,
      archivedAt: _ts(d['archivedAt']),
      order: (d['order'] as num?)?.toDouble(),
      lastRunId: d['lastRunId'],
    );
  }
}

class RoutingTarget {
  final String targetId;
  final String adapter;
  final String location;
  final List<String> models;
  final List<String> effortLevels;

  const RoutingTarget({
    required this.targetId,
    required this.adapter,
    required this.location,
    required this.models,
    required this.effortLevels,
  });

  factory RoutingTarget.fromMap(Map<String, dynamic> map) => RoutingTarget(
    targetId: map['targetId'] ?? '',
    adapter: map['adapter'] ?? '',
    location: map['location'] ?? '',
    models: [
      for (final value in (map['models'] as List? ?? [])) value.toString(),
    ],
    effortLevels: [
      for (final value in (map['effortLevels'] as List? ?? []))
        value.toString(),
    ],
  );
}

class RoutingCatalog {
  final String catalogVersion;
  final List<RoutingTarget> targets;

  const RoutingCatalog({required this.catalogVersion, required this.targets});

  factory RoutingCatalog.fromMap(Map<String, dynamic>? map) => RoutingCatalog(
    catalogVersion: map?['catalogVersion'] ?? '',
    targets: [
      for (final target in (map?['targets'] as List? ?? []))
        RoutingTarget.fromMap(Map<String, dynamic>.from(target)),
    ],
  );

  RoutingTarget? target(String? targetId) {
    if (targetId == null) return null;
    for (final target in targets) {
      if (target.targetId == targetId) return target;
    }
    return null;
  }

  RoutingTarget? targetForAdapter(String? adapter) {
    if (adapter == null) return null;
    for (final target in targets) {
      if (target.adapter == adapter) return target;
    }
    return null;
  }

  List<String> get providers =>
      targets.map((target) => target.adapter).toSet().toList(growable: false);

  List<String> modelsForProvider(String? adapter) => targets
      .where((target) => adapter == null || target.adapter == adapter)
      .expand((target) => target.models)
      .toSet()
      .toList(growable: false);

  List<String> effortsForProvider(String? adapter) => targets
      .where((target) => adapter == null || target.adapter == adapter)
      .expand((target) => target.effortLevels)
      .toSet()
      .toList(growable: false);
}

/// Whether [item] belongs on the board for the current archived toggle:
/// archived items only appear in the archived view, active items only in the
/// default view. Archiving is orthogonal to `status`.
bool matchesArchivedView(ActionItem item, {required bool showArchived}) =>
    item.archived == showArchived;

/// Whether [item] is included by a literal set of selected statuses.
///
/// In particular, an empty selection matches nothing; callers represent the
/// unfiltered/show-all state by selecting every value in [itemStatuses].
bool matchesStatusFilter(ActionItem item, Set<String> selectedStatuses) =>
    selectedStatuses.contains(item.status);

/// The manual board position to sort by: the explicit `order` field once an
/// item has been dragged (or created after this feature shipped), falling
/// back to creation time for older items that predate manual ordering so
/// they still render in a stable, sensible position until someone drags
/// them.
double effectiveOrder(ActionItem item) =>
    item.order ?? (item.createdAt?.millisecondsSinceEpoch.toDouble() ?? 0);

class Attachment {
  final String name;
  final String storagePath;
  final String contentType;
  final int size;

  Attachment({
    required this.name,
    required this.storagePath,
    required this.contentType,
    required this.size,
  });

  bool get isImage => contentType.startsWith('image/');
  bool get isSvg =>
      contentType == 'image/svg+xml' || name.toLowerCase().endsWith('.svg');

  factory Attachment.fromMap(Map<String, dynamic> m) => Attachment(
    name: m['name'] ?? 'file',
    storagePath: m['storagePath'] ?? '',
    contentType: m['contentType'] ?? 'application/octet-stream',
    size: (m['size'] ?? 0) as int,
  );

  Map<String, dynamic> toMap() => {
    'name': name,
    'storagePath': storagePath,
    'contentType': contentType,
    'size': size,
  };
}

class ThreadMessage {
  final String id;
  final String author; // "user" | "agent"
  final String text;
  final List<Attachment> attachments;
  final DateTime? createdAt;
  final DateTime? editedAt;
  final String kind;
  final String? runId;
  final String? routingState;
  final String? provider;
  final String? model;
  final String? effort;

  ThreadMessage({
    required this.id,
    required this.author,
    required this.text,
    required this.attachments,
    this.createdAt,
    this.editedAt,
    this.kind = 'message',
    this.runId,
    this.routingState,
    this.provider,
    this.model,
    this.effort,
  });

  factory ThreadMessage.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? {};
    return ThreadMessage(
      id: doc.id,
      author: d['author'] ?? 'user',
      text: d['text'] ?? '',
      attachments: [
        for (final a in (d['attachments'] as List? ?? []))
          Attachment.fromMap(Map<String, dynamic>.from(a)),
      ],
      createdAt: _ts(d['createdAt']),
      editedAt: _ts(d['editedAt']),
      kind: d['kind'] ?? 'message',
      runId: d['runId'],
      routingState: d['state'],
      provider: d['provider'],
      model: d['model'],
      effort: d['effort'],
    );
  }
}

class AgentRun {
  final String id;
  final String state;
  final String targetId;
  final String provider;
  final String model;
  final String effort;

  const AgentRun({
    required this.id,
    required this.state,
    required this.targetId,
    required this.provider,
    required this.model,
    required this.effort,
  });

  factory AgentRun.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? {};
    return AgentRun(
      id: doc.id,
      state: data['state'] ?? '',
      targetId: data['targetId'] ?? '',
      provider: data['provider'] ?? '',
      model: data['model'] ?? '',
      effort: data['effort'] ?? '',
    );
  }
}

String routingAssignmentSummary(AgentRun run) =>
    'Assigned: ${run.provider} · ${run.model} · ${run.effort}';

String routingEventLabel(ThreadMessage message) {
  final assignment = [
    message.provider,
    message.model,
    message.effort,
  ].whereType<String>().join(' · ');
  final action = message.routingState == 'resumed' ? 'Resumed' : 'Routed to';
  return assignment.isEmpty ? action : '$action $assignment';
}

/// The image attachments available to a thread gallery, in reading order.
///
/// Messages are supplied oldest-first by the thread query.
/// Keeping that order, followed by each message's attachment order, makes
/// previous/next navigation predictable even when a thread has several image
/// uploads spread across replies.
List<Attachment> imageAttachmentsInThread(Iterable<ThreadMessage> messages) => [
  for (final message in messages)
    if (message.kind == 'message')
      for (final attachment in message.attachments)
        if (attachment.isImage) attachment,
];

class RepoInfo {
  final String id;
  final String name;
  final String path;
  final String? remote;
  final String? host;
  final String status; // "active" | "removed"
  final DateTime? lastSeenAt;

  RepoInfo({
    required this.id,
    required this.name,
    required this.path,
    this.remote,
    this.host,
    required this.status,
    this.lastSeenAt,
  });

  factory RepoInfo.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? {};
    return RepoInfo(
      id: doc.id,
      name: d['name'] ?? doc.id,
      path: d['path'] ?? '',
      remote: d['remote'],
      host: d['host'],
      status: d['status'] ?? 'active',
      lastSeenAt: _ts(d['lastSeenAt']),
    );
  }
}

class ScheduleInfo {
  final List<String> times;
  final DateTime? lastRunAt;
  final DateTime? lastFinishedAt;
  final DateTime? updatedAt;
  final String scheduler;
  final String? lastOutcome;
  final String? lastSummary;
  final bool routerAvailable;
  final String? routerReason;
  final List<ProviderHealth> providers;

  ScheduleInfo({
    required this.times,
    this.lastRunAt,
    this.lastFinishedAt,
    this.updatedAt,
    this.scheduler = 'launchd',
    this.lastOutcome,
    this.lastSummary,
    this.routerAvailable = false,
    this.routerReason,
    this.providers = const [],
  });

  factory ScheduleInfo.fromMap(Map<String, dynamic>? d) => ScheduleInfo(
    times: [for (final t in (d?['times'] as List? ?? [])) t.toString()],
    lastRunAt: _ts(d?['lastRunAt']),
    lastFinishedAt: _ts(d?['lastFinishedAt']),
    updatedAt: _ts(d?['updatedAt']),
    scheduler: d?['scheduler'] ?? 'launchd',
    lastOutcome: d?['lastOutcome'],
    lastSummary: d?['lastSummary'],
    routerAvailable: d?['routerHealth']?['available'] == true,
    routerReason: d?['routerHealth']?['reason'],
    providers: [
      for (final provider in (d?['providers'] as List? ?? []))
        ProviderHealth.fromMap(Map<String, dynamic>.from(provider)),
    ],
  );
}

class ProviderHealth {
  final String targetId;
  final String adapter;
  final bool enabled;
  final bool available;
  final String? reason;

  const ProviderHealth({
    required this.targetId,
    required this.adapter,
    required this.enabled,
    required this.available,
    this.reason,
  });

  factory ProviderHealth.fromMap(Map<String, dynamic> map) {
    final availability = Map<String, dynamic>.from(
      map['availability'] as Map? ?? const {},
    );
    return ProviderHealth(
      targetId: map['targetId'] ?? '',
      adapter: map['adapter'] ?? '',
      enabled: map['enabled'] == true,
      available: availability['available'] == true,
      reason: availability['reason'],
    );
  }
}
