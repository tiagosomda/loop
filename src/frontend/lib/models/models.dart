import 'package:cloud_firestore/cloud_firestore.dart';

const itemStatuses = [
  'open',
  'in-progress',
  'needs-review',
  'completed',
  'closed',
];

const modelOptions = ['default', 'haiku', 'sonnet', 'opus', 'fable'];
const effortOptions = ['default', 'low', 'medium', 'high', 'max'];

DateTime? _ts(dynamic v) => v is Timestamp ? v.toDate() : null;

class ActionItem {
  final String id;
  final String title;
  final String repoId;
  final String status;
  final String? model;
  final String? effortLevel;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? lastAgentRunAt;
  final int messageCount;

  ActionItem({
    required this.id,
    required this.title,
    required this.repoId,
    required this.status,
    this.model,
    this.effortLevel,
    this.createdAt,
    this.updatedAt,
    this.lastAgentRunAt,
    this.messageCount = 0,
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
      createdAt: _ts(d['createdAt']),
      updatedAt: _ts(d['updatedAt']),
      lastAgentRunAt: _ts(d['lastAgentRunAt']),
      messageCount: (d['messageCount'] ?? 0) as int,
    );
  }
}

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

  ThreadMessage({
    required this.id,
    required this.author,
    required this.text,
    required this.attachments,
    this.createdAt,
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
    );
  }
}

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
  final DateTime? updatedAt;

  ScheduleInfo({required this.times, this.lastRunAt, this.updatedAt});

  factory ScheduleInfo.fromMap(Map<String, dynamic>? d) => ScheduleInfo(
        times: [for (final t in (d?['times'] as List? ?? [])) t.toString()],
        lastRunAt: _ts(d?['lastRunAt']),
        updatedAt: _ts(d?['updatedAt']),
      );
}
