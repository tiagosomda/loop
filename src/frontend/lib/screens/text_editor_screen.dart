import 'package:flutter/material.dart';

/// Opens a route-level multiline editor and returns its trimmed contents when
/// the user saves. Returning `null` means the edit was cancelled.
Future<String?> openTextEditorScreen(
  BuildContext context, {
  required String title,
  required String initialText,
  required String saveLabel,
  String? hintText,
  String? notice,
  bool allowEmpty = true,
}) {
  // Release the field on the previous route before starting the transition.
  // Otherwise iOS can finish closing that field's input connection after the
  // editor has already tried to open its own, leaving the editor focused but
  // with no keyboard.
  FocusScope.of(context).unfocus();
  return Navigator.of(context).push<String>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => TextEditorScreen(
        title: title,
        initialText: initialText,
        saveLabel: saveLabel,
        hintText: hintText,
        notice: notice,
        allowEmpty: allowEmpty,
      ),
    ),
  );
}

/// A dedicated editing surface with no parent scroll view competing with text
/// selection gestures. The text field owns all vertical dragging on the page.
class TextEditorScreen extends StatefulWidget {
  const TextEditorScreen({
    super.key,
    required this.title,
    required this.initialText,
    required this.saveLabel,
    this.hintText,
    this.notice,
    this.allowEmpty = true,
  });

  final String title;
  final String initialText;
  final String saveLabel;
  final String? hintText;
  final String? notice;
  final bool allowEmpty;

  @override
  State<TextEditorScreen> createState() => _TextEditorScreenState();
}

class _TextEditorScreenState extends State<TextEditorScreen> {
  late final TextEditingController _controller;
  final FocusNode _focusNode = FocusNode();
  Animation<double>? _routeAnimation;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText)
      ..selection = TextSelection.collapsed(offset: widget.initialText.length);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animation = ModalRoute.of(context)?.animation;
    if (identical(animation, _routeAnimation)) return;
    _routeAnimation?.removeStatusListener(_handleRouteAnimation);
    _routeAnimation = animation;
    if (animation == null || animation.status == AnimationStatus.completed) {
      _requestFocus();
    } else {
      animation.addStatusListener(_handleRouteAnimation);
    }
  }

  void _handleRouteAnimation(AnimationStatus status) {
    if (status == AnimationStatus.completed) _requestFocus();
  }

  void _requestFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _routeAnimation?.removeStatusListener(_handleRouteAnimation);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleTextStyle: Theme.of(context).textTheme.titleMedium,
        leading: IconButton(
          tooltip: 'Cancel',
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(widget.title),
        actions: [
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _controller,
            builder: (context, value, _) {
              final text = value.text.trim();
              return TextButton(
                key: const ValueKey('text-editor-save'),
                onPressed: widget.allowEmpty || text.isNotEmpty
                    ? () => Navigator.of(context).pop(_controller.text.trim())
                    : null,
                child: Text(widget.saveLabel),
              );
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (widget.notice case final notice?)
              Container(
                key: const ValueKey('text-editor-notice'),
                width: double.infinity,
                margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.errorContainer.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  notice,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                ),
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: TextField(
                  key: const ValueKey('text-editor-field'),
                  controller: _controller,
                  focusNode: _focusNode,
                  expands: true,
                  minLines: null,
                  maxLines: null,
                  textAlignVertical: TextAlignVertical.top,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    hintText: widget.hintText,
                    alignLabelWithHint: true,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
