import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../models/models.dart';

typedef AttachmentUrlResolver = Future<String> Function(Attachment attachment);

/// A full-screen, route-backed gallery for image attachments in one thread.
class AttachmentGallery extends StatefulWidget {
  const AttachmentGallery({
    super.key,
    required this.attachments,
    required this.initialIndex,
    required this.resolveUrl,
  }) : assert(attachments.length > 0),
       assert(initialIndex >= 0 && initialIndex < attachments.length);

  final List<Attachment> attachments;
  final int initialIndex;
  final AttachmentUrlResolver resolveUrl;

  @override
  State<AttachmentGallery> createState() => _AttachmentGalleryState();
}

class _AttachmentGalleryState extends State<AttachmentGallery> {
  static const _minScale = 1.0;
  static const _maxScale = 5.0;
  static const _zoomStep = 1.5;

  late final PageController _pageController;
  late final List<TransformationController> _transformControllers;
  late final List<Future<String>> _urls;
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _pageController = PageController(initialPage: _index);
    _transformControllers = [
      for (var i = 0; i < widget.attachments.length; i++)
        TransformationController(),
    ];
    _urls = [
      for (final attachment in widget.attachments)
        widget.resolveUrl(attachment),
    ];
  }

  @override
  void dispose() {
    _pageController.dispose();
    for (final controller in _transformControllers) {
      controller.dispose();
    }
    super.dispose();
  }

  bool get _hasPrevious => _index > 0;
  bool get _hasNext => _index < widget.attachments.length - 1;

  void _showPrevious() {
    if (_hasPrevious) _goTo(_index - 1);
  }

  void _showNext() {
    if (_hasNext) _goTo(_index + 1);
  }

  void _goTo(int index) {
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  void _zoomBy(double factor) {
    final controller = _transformControllers[_index];
    final currentScale = controller.value.getMaxScaleOnAxis();
    final targetScale = (currentScale * factor).clamp(_minScale, _maxScale);
    if (targetScale <= _minScale + 0.001) {
      controller.value = Matrix4.identity();
      return;
    }
    final appliedFactor = targetScale / currentScale;
    if ((appliedFactor - 1).abs() < 0.001) return;

    final size = MediaQuery.sizeOf(context);
    final center = Offset(size.width / 2, size.height / 2);
    final centeredZoom = Matrix4.identity()
      ..translateByDouble(center.dx, center.dy, 0, 1)
      ..scaleByDouble(appliedFactor, appliedFactor, 1, 1)
      ..translateByDouble(-center.dx, -center.dy, 0, 1);
    controller.value = centeredZoom..multiply(controller.value);
  }

  void _resetZoom() {
    _transformControllers[_index].value = Matrix4.identity();
  }

  @override
  Widget build(BuildContext context) {
    final attachment = widget.attachments[_index];
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): _showPrevious,
        const SingleActivator(LogicalKeyboardKey.arrowRight): _showNext,
        const SingleActivator(LogicalKeyboardKey.equal): () =>
            _zoomBy(_zoomStep),
        const SingleActivator(LogicalKeyboardKey.equal, shift: true): () =>
            _zoomBy(_zoomStep),
        const SingleActivator(LogicalKeyboardKey.numpadAdd): () =>
            _zoomBy(_zoomStep),
        const SingleActivator(LogicalKeyboardKey.minus): () =>
            _zoomBy(1 / _zoomStep),
        const SingleActivator(LogicalKeyboardKey.numpadSubtract): () =>
            _zoomBy(1 / _zoomStep),
      },
      child: Focus(
        autofocus: true,
        child: Semantics(
          label: 'Image gallery',
          child: Scaffold(
            backgroundColor: Colors.black,
            appBar: AppBar(
              backgroundColor: Colors.black.withValues(alpha: 0.72),
              foregroundColor: Colors.white,
              leading: IconButton(
                tooltip: 'Close gallery',
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              ),
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    attachment.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 16),
                  ),
                  Text(
                    '${_index + 1} of ${widget.attachments.length}',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.72),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            body: Stack(
              fit: StackFit.expand,
              children: [
                PageView.builder(
                  controller: _pageController,
                  // InteractiveViewer's scale recognizer owns one-finger
                  // drags even at 1x. Gallery pages detect those raw pointer
                  // swipes explicitly; disabling PageView's competing drag
                  // recognizer also guarantees a zoomed image keeps the same
                  // gesture for panning.
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: widget.attachments.length,
                  onPageChanged: (index) => setState(() => _index = index),
                  itemBuilder: (context, index) => _GalleryPage(
                    attachment: widget.attachments[index],
                    url: _urls[index],
                    transformationController: _transformControllers[index],
                    onSwipePrevious: _showPrevious,
                    onSwipeNext: _showNext,
                  ),
                ),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: SafeArea(
                    minimum: const EdgeInsets.all(16),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.72),
                        borderRadius: BorderRadius.circular(32),
                      ),
                      child: AnimatedBuilder(
                        animation: _transformControllers[_index],
                        builder: (context, _) {
                          final scale = _transformControllers[_index].value
                              .getMaxScaleOnAxis();
                          final isIdentity = _isIdentityTransform(
                            _transformControllers[_index].value,
                          );
                          return Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: 'Previous image',
                                color: Colors.white,
                                onPressed: _hasPrevious ? _showPrevious : null,
                                icon: const Icon(Icons.chevron_left),
                              ),
                              IconButton(
                                tooltip: 'Zoom out',
                                color: Colors.white,
                                onPressed: scale > _minScale + 0.01
                                    ? () => _zoomBy(1 / _zoomStep)
                                    : null,
                                icon: const Icon(Icons.zoom_out),
                              ),
                              IconButton(
                                tooltip: 'Reset zoom',
                                color: Colors.white,
                                onPressed: isIdentity ? null : _resetZoom,
                                icon: const Icon(Icons.fit_screen),
                              ),
                              IconButton(
                                tooltip: 'Zoom in',
                                color: Colors.white,
                                onPressed: scale < _maxScale - 0.01
                                    ? () => _zoomBy(_zoomStep)
                                    : null,
                                icon: const Icon(Icons.zoom_in),
                              ),
                              IconButton(
                                tooltip: 'Next image',
                                color: Colors.white,
                                onPressed: _hasNext ? _showNext : null,
                                icon: const Icon(Icons.chevron_right),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _GalleryPage extends StatefulWidget {
  const _GalleryPage({
    required this.attachment,
    required this.url,
    required this.transformationController,
    required this.onSwipePrevious,
    required this.onSwipeNext,
  });

  final Attachment attachment;
  final Future<String> url;
  final TransformationController transformationController;
  final VoidCallback onSwipePrevious;
  final VoidCallback onSwipeNext;

  @override
  State<_GalleryPage> createState() => _GalleryPageState();
}

class _GalleryPageState extends State<_GalleryPage> {
  static const _swipeThreshold = 48.0;
  static const _minimumHorizontalRatio = 1.2;

  int? _swipePointer;
  Offset _swipeDelta = Offset.zero;
  bool _swipeEligible = false;

  void _onPointerDown(PointerDownEvent event) {
    if (_swipePointer != null) {
      // A second pointer means this is a pinch, not gallery navigation.
      _swipeEligible = false;
      return;
    }
    _swipePointer = event.pointer;
    _swipeDelta = Offset.zero;
    _swipeEligible =
        widget.transformationController.value.getMaxScaleOnAxis() <= 1.001;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.pointer == _swipePointer && _swipeEligible) {
      _swipeDelta += event.delta;
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    if (event.pointer != _swipePointer) return;
    final scale = widget.transformationController.value.getMaxScaleOnAxis();
    final isHorizontal =
        _swipeDelta.dx.abs() >= _swipeThreshold &&
        _swipeDelta.dx.abs() >= _swipeDelta.dy.abs() * _minimumHorizontalRatio;
    final shouldNavigate = _swipeEligible && scale <= 1.001 && isHorizontal;
    final deltaX = _swipeDelta.dx;
    _clearSwipe();
    if (!shouldNavigate) return;
    if (deltaX < 0) {
      widget.onSwipeNext();
    } else {
      widget.onSwipePrevious();
    }
  }

  void _clearSwipe() {
    _swipePointer = null;
    _swipeDelta = Offset.zero;
    _swipeEligible = false;
  }

  void _normalizeMinimumScale() {
    final matrix = widget.transformationController.value;
    if (matrix.getMaxScaleOnAxis() <= 1.001 && !_isIdentityTransform(matrix)) {
      widget.transformationController.value = Matrix4.identity();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: (_) => _clearSwipe(),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 88),
        child: InteractiveViewer(
          transformationController: widget.transformationController,
          minScale: _AttachmentGalleryState._minScale,
          maxScale: _AttachmentGalleryState._maxScale,
          onInteractionEnd: (_) => _normalizeMinimumScale(),
          child: Center(
            child: FutureBuilder<String>(
              future: widget.url,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Semantics(
                    liveRegion: true,
                    child: const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.broken_image_outlined,
                          color: Colors.white70,
                          size: 48,
                        ),
                        SizedBox(height: 12),
                        Text(
                          'Could not load image',
                          style: TextStyle(color: Colors.white70),
                        ),
                      ],
                    ),
                  );
                }
                if (!snapshot.hasData) {
                  return const CircularProgressIndicator(
                    color: Colors.white,
                    semanticsLabel: 'Loading image',
                  );
                }
                if (widget.attachment.isSvg) {
                  return SvgPicture.network(
                    snapshot.data!,
                    fit: BoxFit.contain,
                    semanticsLabel: widget.attachment.name,
                    placeholderBuilder: (context) => const _ImageLoading(),
                    errorBuilder: (context, error, stackTrace) =>
                        const _ImageDisplayError(),
                  );
                }
                return Image.network(
                  snapshot.data!,
                  fit: BoxFit.contain,
                  semanticLabel: widget.attachment.name,
                  loadingBuilder: (context, child, progress) =>
                      progress == null ? child : const _ImageLoading(),
                  errorBuilder: (context, error, stackTrace) =>
                      const _ImageDisplayError(),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

bool _isIdentityTransform(Matrix4 matrix) {
  final identity = Matrix4.identity().storage;
  final values = matrix.storage;
  for (var i = 0; i < values.length; i++) {
    if ((values[i] - identity[i]).abs() > 0.001) return false;
  }
  return true;
}

class _ImageLoading extends StatelessWidget {
  const _ImageLoading();

  @override
  Widget build(BuildContext context) => const CircularProgressIndicator(
    color: Colors.white,
    semanticsLabel: 'Loading image',
  );
}

class _ImageDisplayError extends StatelessWidget {
  const _ImageDisplayError();

  @override
  Widget build(BuildContext context) => const Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(Icons.broken_image_outlined, color: Colors.white70, size: 48),
      SizedBox(height: 12),
      Text('Could not display image', style: TextStyle(color: Colors.white70)),
    ],
  );
}
