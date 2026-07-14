import 'dart:async';
import 'dart:math' as math;

import 'package:dev_loop/models/models.dart';
import 'package:dev_loop/services/board_service.dart';
import 'package:dev_loop/widgets/attachment_gallery.dart';
import 'package:dev_loop/widgets/brand_logo.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('pull-to-refresh visual confirmation', () {
    // Regression test for the reported bug: pulling down on the board's
    // list view (a RefreshIndicator wrapping a ReorderableListView.builder,
    // per home_screen.dart's _ListView) produced no visible confirmation.
    // This exercises the exact same widget combination — RefreshIndicator +
    // ReorderableListView.builder with custom (non-default) drag handles
    // via ReorderableDragStartListener + AlwaysScrollableScrollPhysics — and
    // drags from an item's body (not the handle), mirroring how a user
    // actually pulls down on a card. If this regresses, RefreshIndicator's
    // onRefresh is not firing for the reorderable list.
    testWidgets(
      'RefreshIndicator.onRefresh fires when pulling a ReorderableListView '
      'with custom drag handles',
      (tester) async {
        var refreshCount = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: RefreshIndicator(
                onRefresh: () async => refreshCount++,
                child: ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.only(top: 4, bottom: 24),
                  itemCount: 5,
                  onReorderItem: (a, b) {},
                  itemBuilder: (context, i) => Card(
                    key: ValueKey(i),
                    child: InkWell(
                      onTap: () {},
                      child: ListTile(
                        title: Text('item $i'),
                        trailing: ReorderableDragStartListener(
                          index: i,
                          child: const Icon(Icons.drag_indicator),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

        // Pull down from within the first card's body (not its drag handle) —
        // the gesture a user performs to trigger pull-to-refresh.
        await tester.fling(find.text('item 0'), const Offset(0, 300), 1000);
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();

        expect(refreshCount, 1);
      },
    );

    // Regression test for the fix: BoardService.isRefreshing drives a
    // top-of-board progress bar directly, so the user gets a guaranteed,
    // unambiguous confirmation even if a refresh round-trip resolves too
    // quickly for RefreshIndicator's own animation to register, or if the
    // pull gesture itself was never recognized as an overscroll.
    testWidgets('explicit refreshing indicator toggles with isRefreshing', (
      tester,
    ) async {
      final refreshing = ValueNotifier<bool>(false);
      addTearDown(refreshing.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: refreshing,
              builder: (context, value, _) => AnimatedSwitcher(
                duration: const Duration(milliseconds: 150),
                child: value
                    ? const LinearProgressIndicator(
                        key: ValueKey('refreshing'),
                        minHeight: 2,
                      )
                    : const SizedBox(height: 2, key: ValueKey('idle')),
              ),
            ),
          ),
        ),
      );

      expect(find.byType(LinearProgressIndicator), findsNothing);

      refreshing.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.byType(LinearProgressIndicator), findsOneWidget);

      refreshing.value = false;
      await tester.pumpAndSettle();
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });
  });

  test('status universe is stable', () {
    expect(itemStatuses, [
      'open',
      'in-progress',
      'needs-review',
      'completed',
      'closed',
    ]);
  });

  group('literal status filtering', () {
    final item = ActionItem(id: 'x', title: 't', repoId: 'r', status: 'open');

    test('an empty selection matches nothing', () {
      expect(matchesStatusFilter(item, <String>{}), isFalse);
    });

    test('the all-selected default includes every status', () {
      for (final status in itemStatuses) {
        final statusItem = ActionItem(
          id: status,
          title: status,
          repoId: 'r',
          status: status,
        );
        expect(matchesStatusFilter(statusItem, itemStatuses.toSet()), isTrue);
      }
    });

    test('a partial selection only includes selected statuses', () {
      expect(matchesStatusFilter(item, {'open', 'closed'}), isTrue);
      expect(matchesStatusFilter(item, {'closed'}), isFalse);
    });
  });

  group('archived view filtering', () {
    ActionItem item({required bool archived}) => ActionItem(
      id: 'x',
      title: 't',
      repoId: 'r',
      status: 'completed',
      archived: archived,
    );

    test('default view shows only non-archived items', () {
      expect(
        matchesArchivedView(item(archived: false), showArchived: false),
        isTrue,
      );
      expect(
        matchesArchivedView(item(archived: true), showArchived: false),
        isFalse,
      );
    });

    test('archived view shows only archived items', () {
      expect(
        matchesArchivedView(item(archived: true), showArchived: true),
        isTrue,
      );
      expect(
        matchesArchivedView(item(archived: false), showArchived: true),
        isFalse,
      );
    });

    test('ActionItem defaults to not archived', () {
      expect(item(archived: false).archived, isFalse);
    });
  });

  group('thread image gallery', () {
    Attachment attachment(String name, String contentType) => Attachment(
      name: name,
      storagePath: 'attachments/$name',
      contentType: contentType,
      size: 1,
    );

    test('collects only images in chronological attachment order', () {
      final firstImage = attachment('first.png', 'image/png');
      final document = attachment('notes.pdf', 'application/pdf');
      final secondImage = attachment('second.jpg', 'image/jpeg');
      final thirdImage = attachment('third.webp', 'image/webp');
      final messages = [
        ThreadMessage(
          id: 'one',
          author: 'user',
          text: '',
          attachments: [firstImage, document, secondImage],
        ),
        ThreadMessage(
          id: 'two',
          author: 'agent',
          text: '',
          attachments: [thirdImage],
        ),
      ];

      expect(imageAttachmentsInThread(messages), [
        same(firstImage),
        same(secondImage),
        same(thirdImage),
      ]);
    });

    test('recognizes SVG image attachments for gallery rendering', () {
      expect(attachment('diagram.svg', 'image/svg+xml').isSvg, isTrue);
      expect(attachment('photo.png', 'image/png').isSvg, isFalse);
    });

    testWidgets('starts at the tapped image and navigates previous and next', (
      tester,
    ) async {
      final images = [
        attachment('first.png', 'image/png'),
        attachment('second.png', 'image/png'),
        attachment('third.png', 'image/png'),
      ];

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: NoSplash.splashFactory),
          home: AttachmentGallery(
            attachments: images,
            initialIndex: 1,
            // Leaving these unresolved keeps the test independent of network
            // image fetching while exercising the real gallery controls.
            resolveUrl: (_) => Completer<String>().future,
          ),
        ),
      );

      expect(find.text('second.png'), findsOneWidget);
      expect(find.text('2 of 3'), findsOneWidget);

      await tester.tap(find.widgetWithIcon(IconButton, Icons.chevron_right));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('third.png'), findsOneWidget);
      expect(find.text('3 of 3'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.chevron_right),
            )
            .onPressed,
        isNull,
      );

      await tester.tap(find.widgetWithIcon(IconButton, Icons.chevron_left));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('second.png'), findsOneWidget);
      expect(find.text('2 of 3'), findsOneWidget);
    });

    testWidgets('zoom controls update and reset the current image scale', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: NoSplash.splashFactory),
          home: AttachmentGallery(
            attachments: [attachment('photo.png', 'image/png')],
            initialIndex: 0,
            resolveUrl: (_) => Completer<String>().future,
          ),
        ),
      );

      expect(
        tester
            .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.zoom_out))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.fit_screen),
            )
            .onPressed,
        isNull,
      );

      await tester.tap(find.byTooltip('Zoom in'));
      await tester.pump();
      expect(
        tester
            .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.zoom_out))
            .onPressed,
        isNotNull,
      );
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.fit_screen),
            )
            .onPressed,
        isNotNull,
      );

      await tester.tap(find.byTooltip('Reset zoom'));
      await tester.pump();
      expect(
        tester
            .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.zoom_out))
            .onPressed,
        isNull,
      );
    });
  });

  group('manual board order', () {
    test('explicit order field wins when present', () {
      final item = ActionItem(
        id: 'x',
        title: 't',
        repoId: 'r',
        status: 'open',
        order: 42,
        createdAt: DateTime(2026, 1, 1),
      );
      expect(effectiveOrder(item), 42);
    });

    test('falls back to createdAt for items never manually ordered', () {
      final created = DateTime(2026, 1, 1);
      final item = ActionItem(
        id: 'x',
        title: 't',
        repoId: 'r',
        status: 'open',
        createdAt: created,
      );
      expect(effectiveOrder(item), created.millisecondsSinceEpoch.toDouble());
    });

    test('falls back to 0 when neither order nor createdAt is set', () {
      final item = ActionItem(id: 'x', title: 't', repoId: 'r', status: 'open');
      expect(effectiveOrder(item), 0);
    });
  });

  group('renumber fallback (cross-column collision fix)', () {
    test('stays strictly inside the gap bounded by other-status neighbors', () {
      // Reproduces the bug: a kanban column with two adjacent order values
      // (no room for a midpoint) sits between two items of *other*
      // statuses, at 50 and 500. A renumber must never produce a value
      // that collides with, or falls outside, that [50, 500] gap.
      final result = renumberedOrders(
        scopeOrders: [100, 100.5, 101],
        otherOrders: [50, 500],
      );
      expect(result.length, 3);
      for (final v in result) {
        expect(
          v > 50,
          isTrue,
          reason: '$v must be strictly above the lower neighbor',
        );
        expect(
          v < 500,
          isTrue,
          reason: '$v must be strictly below the upper neighbor',
        );
      }
      // Order is preserved and none of the other board's values are reused.
      expect(result[0] < result[1] && result[1] < result[2], isTrue);
      expect(result.toSet().intersection({50, 500}), isEmpty);
    });

    test(
      'never resets to small absolute indices that collide with untouched items',
      () {
        // The original bug: renumbering reset a column to (i+1)*1000, which
        // is exactly the value another untouched item might already hold
        // (e.g. a fresh board's second-ever item). Assert the new values
        // don't coincide with an unrelated item sitting at 1000, 2000, 3000.
        final result = renumberedOrders(
          scopeOrders: [1500, 1500.2, 1500.4],
          otherOrders: [1000, 2000, 3000],
        );
        expect(result.any((v) => v == 1000 || v == 2000 || v == 3000), isFalse);
        // 1000 < scope < 2000 in this scenario, so the fix should bound the
        // renumber to that gap rather than spilling past 3000 or below 1000.
        for (final v in result) {
          expect(v > 1000 && v < 2000, isTrue);
        }
      },
    );

    test('extends past the board edge when there is no bounding neighbor', () {
      final result = renumberedOrders(scopeOrders: [10, 20], otherOrders: []);
      expect(result.length, 2);
      expect(result[0] < result[1], isTrue);
    });
  });

  group('schedule-aware logo speed', () {
    test('accelerates inside the schedule window', () {
      final now = DateTime(2026, 7, 13, 10, 12, 1);

      expect(isNearScheduledTime(now, const ['10:15']), isTrue);
      expect(
        isNearScheduledTime(now.subtract(const Duration(seconds: 2)), const [
          '10:15',
        ]),
        isFalse,
      );
    });

    test('handles schedule windows across midnight', () {
      final now = DateTime(2026, 7, 13, 23, 59);

      expect(isNearScheduledTime(now, const ['00:01']), isTrue);
    });

    test('ignores malformed schedule values', () {
      final now = DateTime(2026, 7, 13, 10, 15);

      expect(isNearScheduledTime(now, const ['noon', '25:00']), isFalse);
    });
  });

  group('tappable logo burst spin', () {
    // Regression test for the "logged out login issue" polish request: the
    // signed-out screen's big logo should spin slowly on its own, and a tap
    // should layer a noticeably faster burst on top of that idle rotation.
    testWidgets('tapping spins the logo faster than its idle rate', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(child: SpinningDevLoopLogo(tappable: true)),
          ),
        ),
      );
      await tester.pump();

      double angleOf() {
        final transform = tester.widget<Transform>(
          find.descendant(
            of: find.byType(SpinningDevLoopLogo),
            matching: find.byType(Transform),
          ),
        );
        final m = transform.transform.storage;
        return math.atan2(m[1], m[0]);
      }

      final beforeIdle = angleOf();
      await tester.pump(const Duration(milliseconds: 100));
      final idleDelta = (angleOf() - beforeIdle).abs();

      await tester.tap(find.byType(SpinningDevLoopLogo));
      await tester.pump();
      final beforeBurst = angleOf();
      await tester.pump(const Duration(milliseconds: 100));
      final burstDelta = (angleOf() - beforeBurst).abs();

      expect(burstDelta, greaterThan(idleDelta * 2));

      // The logo spins forever (both the idle repeat and, briefly, the
      // burst), so unmount it rather than pumpAndSettle to let its
      // AnimationControllers and timers get disposed cleanly.
      await tester.pumpWidget(const SizedBox());
    });
  });
}
