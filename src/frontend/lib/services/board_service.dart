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

  /// Forces a one-off fetch of the board items straight from the server,
  /// bypassing Firestore's local cache. The live [items] stream already keeps
  /// the board current, so this exists purely to back the pull-to-refresh
  /// affordance — it re-primes the snapshot after being offline/backgrounded
  /// and lets the callback await a real server round-trip.
  Future<void> refresh() async {
    try {
      await _items
          .orderBy('updatedAt', descending: true)
          .get(const GetOptions(source: Source.server));
    } catch (_) {
      // Best-effort: the live [items] stream keeps the board current even
      // if this forced server round-trip fails (e.g. while offline).
    }
  }

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

  /// Order value that places a new item at the end of the manual order:
  /// one gap-step past the current highest `order` (or fallback creation-time
  /// position, for older items that predate manual ordering).
  Future<double> _nextOrder() async {
    final snap = await _items.get();
    var top = 0.0;
    for (final doc in snap.docs) {
      final item = ActionItem.fromDoc(doc);
      final value = effectiveOrder(item);
      if (value > top) top = value;
    }
    return top + _orderGap;
  }

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
      'order': await _nextOrder(),
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

  /// Archiving is an orthogonal flag to `status`: an archived item keeps its
  /// status but drops out of the default board view.
  Future<void> archiveItem(String itemId) => _items.doc(itemId).update({
        'archived': true,
        'archivedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

  Future<void> unarchiveItem(String itemId) => _items.doc(itemId).update({
        'archived': false,
        'archivedAt': null,
        'updatedAt': FieldValue.serverTimestamp(),
      });

  /// Archive every completed, not-yet-archived item in one batch. Returns the
  /// number of items archived.
  Future<int> archiveCompleted() async {
    final snap =
        await _items.where('status', isEqualTo: 'completed').get();
    final batch = _db.batch();
    var count = 0;
    for (final doc in snap.docs) {
      if (doc.data()['archived'] == true) continue;
      batch.update(doc.reference, {
        'archived': true,
        'archivedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      count++;
    }
    if (count > 0) await batch.commit();
    return count;
  }

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

  /// Gap between two adjacent items' `order` values. Reordering picks a
  /// value halfway between the moved item's new neighbors, so most drags
  /// never touch any document but the one moved.
  static const _orderGap = 1000.0;

  /// Applies a drag-and-drop move reported by a `ReorderableListView`.
  ///
  /// [displayed] is the list exactly as shown to the user *for the scope
  /// being reordered* (the flat list view, or a single kanban column) —
  /// already sorted by [effectiveOrder] — so [oldIndex]/[newIndex] line up
  /// with Flutter's reporting. [allItems] is every active (non-archived)
  /// item on the whole board, across every status, also sorted by
  /// [effectiveOrder] — it's only consulted for the renumber fallback below,
  /// to find the true board-wide neighbors bounding [displayed], since
  /// `order` is one field shared by every view (the flat list *and* each
  /// kanban column), not scoped to whatever subset is on screen.
  ///
  /// The moved item's new `order` is the midpoint between its new
  /// neighbors' order values, so this only writes the one document in the
  /// common case. If the neighbors are numerically adjacent (no room left
  /// for a midpoint — only happens after many reorders land in the same
  /// spot), [displayed] is renumbered with fresh, evenly-spaced values
  /// strictly inside the gap bounded by its nearest board-wide neighbors —
  /// never by resetting to small absolute indices, which would collide
  /// with (or fall inside the range of) untouched items elsewhere on the
  /// board that this drag never touched.
  Future<void> reorderItem(
    List<ActionItem> displayed,
    int oldIndex,
    int newIndex, {
    required List<ActionItem> allItems,
  }) async {
    final list = [...displayed];
    final moved = list.removeAt(oldIndex);
    final insertAt = oldIndex < newIndex ? newIndex - 1 : newIndex;
    list.insert(insertAt, moved);

    final before = insertAt > 0 ? effectiveOrder(list[insertAt - 1]) : null;
    final after =
        insertAt < list.length - 1 ? effectiveOrder(list[insertAt + 1]) : null;

    double newOrder;
    if (before == null && after == null) {
      newOrder = _orderGap;
    } else if (before == null) {
      newOrder = after! - _orderGap;
    } else if (after == null) {
      newOrder = before + _orderGap;
    } else if (after - before > 1.0) {
      newOrder = (before + after) / 2;
    } else {
      await _renumberWithinBounds(list, allItems);
      return;
    }
    await _items.doc(moved.id).update({
      'order': newOrder,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Renumbers [scope] (a subsequence of one status/column, already in its
  /// intended new order) with fresh, evenly-spaced `order` values, strictly
  /// bounded by the nearest board-wide items outside [scope] — i.e. items
  /// of *other* statuses that this drag didn't touch. This never resets
  /// [scope] to absolute indices like `(i+1)*1000`, since those would very
  /// likely collide with (or land inside the range of) some other status's
  /// existing values — new items and past renumbers both hand out order
  /// values from that same small-integer-multiples-of-1000 sequence.
  Future<void> _renumberWithinBounds(
    List<ActionItem> scope,
    List<ActionItem> allItems,
  ) async {
    final scopeIds = scope.map((i) => i.id).toSet();
    final otherOrders = [
      for (final i in allItems)
        if (!scopeIds.contains(i.id)) effectiveOrder(i)
    ];
    final newOrders = renumberedOrders(
      scopeOrders: [for (final i in scope) effectiveOrder(i)],
      otherOrders: otherOrders,
      gap: _orderGap,
    );

    final batch = _db.batch();
    for (var i = 0; i < scope.length; i++) {
      batch.update(_items.doc(scope[i].id), {
        'order': newOrders[i],
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }
    await batch.commit();
  }
}

/// Pure order-math for the renumber fallback, factored out of
/// [BoardService] so it can be unit-tested without touching Firestore.
///
/// [scopeOrders] are the current [effectiveOrder] values of the items being
/// renumbered, in their intended new sequence (index 0 = first). [otherOrders]
/// are every *other* active item's [effectiveOrder] on the whole board — items
/// of other statuses/columns that this drag didn't touch. Returns fresh,
/// evenly-spaced values (same length and order as [scopeOrders]) strictly
/// between the nearest bounding values in [otherOrders], so the result can
/// never collide with or fall inside another status's untouched range. When
/// there's no bounding neighbor on a side (the scope already sits at that
/// extreme of the whole board), the bound extends past the scope's own
/// current min/max instead of resetting to small absolute numbers.
List<double> renumberedOrders({
  required List<double> scopeOrders,
  required List<double> otherOrders,
  double gap = 1000.0,
}) {
  assert(scopeOrders.isNotEmpty);
  final scopeMin = scopeOrders.reduce((a, b) => a < b ? a : b);
  final scopeMax = scopeOrders.reduce((a, b) => a > b ? a : b);
  final sortedOthers = [...otherOrders]..sort();

  // The nearest other-status value at or below the scope's current range,
  // and the nearest one at or above it — the two real neighbors this
  // renumber must not collide with or cross.
  double? before;
  double? after;
  for (final v in sortedOthers) {
    if (v <= scopeMin) {
      before = v;
    } else if (after == null && v >= scopeMax) {
      after = v;
    }
  }

  final span = gap * (scopeOrders.length + 1);
  final lowerBound = before ?? (scopeMin - span);
  final upperBound = after ?? (scopeMax + span);

  final step = (upperBound - lowerBound) / (scopeOrders.length + 1);
  return [
    for (var i = 0; i < scopeOrders.length; i++) lowerBound + step * (i + 1),
  ];
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
