import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';

import '../models/models.dart';

/// All Firestore/Storage access, scoped under the shared-database-safe
/// `dev-loop/` root (see docs/design.md).
class BoardService {
  final _db = FirebaseFirestore.instance;
  final _storage = FirebaseStorage.instance;

  CollectionReference<Map<String, dynamic>> get _items =>
      _db.collection('dev-loop/app/items');
  CollectionReference<Map<String, dynamic>> get _repos =>
      _db.collection('dev-loop/app/repos');
  DocumentReference<Map<String, dynamic>> get _schedule =>
      _db.doc('dev-loop/app/meta/schedule');

  Stream<List<ActionItem>> items() => _items
      .orderBy('updatedAt', descending: true)
      .snapshots()
      .map((s) => [for (final d in s.docs) ActionItem.fromDoc(d)]);

  Stream<ActionItem?> item(String id) => _items
      .doc(id)
      .snapshots()
      .map((d) => d.exists ? ActionItem.fromDoc(d) : null);

  Stream<List<ThreadMessage>> messages(String itemId) => _items
      .doc(itemId)
      .collection('messages')
      .orderBy('createdAt')
      .snapshots()
      .map((s) => [for (final d in s.docs) ThreadMessage.fromDoc(d)]);

  Stream<List<RepoInfo>> repos() => _repos
      .snapshots()
      .map((s) => [for (final d in s.docs) RepoInfo.fromDoc(d)]);

  Stream<RepoInfo?> repo(String id) => _repos
      .doc(id)
      .snapshots()
      .map((d) => d.exists ? RepoInfo.fromDoc(d) : null);

  Stream<ScheduleInfo> schedule() =>
      _schedule.snapshots().map((d) => ScheduleInfo.fromMap(d.data()));

  Future<String> createItem({
    required String title,
    required String repoId,
    String? model,
    String? effortLevel,
    String? firstMessage,
    List<PendingAttachment> attachments = const [],
  }) async {
    final ref = _items.doc();
    await ref.set({
      'title': title,
      'repoId': repoId,
      'status': 'open',
      'model': model,
      'effortLevel': effortLevel,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
      'lastAgentRunAt': null,
      'messageCount': 0,
    });
    if (firstMessage != null && firstMessage.trim().isNotEmpty ||
        attachments.isNotEmpty) {
      await postMessage(ref.id, firstMessage ?? '', attachments: attachments);
    }
    return ref.id;
  }

  Future<void> setStatus(String itemId, String status) => _items.doc(itemId).update({
        'status': status,
        'updatedAt': FieldValue.serverTimestamp(),
      });

  Future<void> setModelEffort(String itemId,
          {String? model, String? effortLevel}) =>
      _items.doc(itemId).update({
        'model': model,
        'effortLevel': effortLevel,
        'updatedAt': FieldValue.serverTimestamp(),
      });

  Future<void> postMessage(
    String itemId,
    String text, {
    String author = 'user',
    List<PendingAttachment> attachments = const [],
  }) async {
    final msgRef = _items.doc(itemId).collection('messages').doc();
    final uploaded = <Attachment>[];
    for (final a in attachments) {
      final path = 'dev-loop/attachments/$itemId/${msgRef.id}/${a.name}';
      await _storage.ref(path).putData(
            a.bytes,
            SettableMetadata(contentType: a.contentType),
          );
      uploaded.add(Attachment(
        name: a.name,
        storagePath: path,
        contentType: a.contentType,
        size: a.bytes.length,
      ));
    }
    await msgRef.set({
      'author': author,
      'text': text,
      'attachments': [for (final a in uploaded) a.toMap()],
      'createdAt': FieldValue.serverTimestamp(),
    });
    final updates = <String, dynamic>{
      'messageCount': FieldValue.increment(1),
      'updatedAt': FieldValue.serverTimestamp(),
    };
    // A user reply re-queues an item the agent had handed back: bump it out of
    // needs-review/completed so the next scheduled run picks it up again.
    // (closed is terminal — the user reopens that one deliberately.)
    if (author == 'user') {
      final current = (await _items.doc(itemId).get()).data()?['status'];
      if (current == 'needs-review' || current == 'completed') {
        updates['status'] = 'open';
      }
    }
    await _items.doc(itemId).update(updates);
  }

  /// Edits the text of an existing message and stamps `editedAt`. Used for the
  /// app user's own messages; the agent picks up the new text on its next run.
  Future<void> editMessage(String itemId, String messageId, String text) =>
      _items.doc(itemId).collection('messages').doc(messageId).update({
        'text': text,
        'editedAt': FieldValue.serverTimestamp(),
      });

  Future<String> downloadUrl(Attachment a) =>
      _storage.ref(a.storagePath).getDownloadURL();

  Future<void> clearRemovedRepo(String repoId) => _repos.doc(repoId).delete();
}

class PendingAttachment {
  final String name;
  final Uint8List bytes;
  final String contentType;

  PendingAttachment({
    required this.name,
    required this.bytes,
    required this.contentType,
  });
}
