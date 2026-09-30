import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../models/settings.dart';
import '../theme.dart' as th;

/// First-run guided tour: hand-rolled coach marks, no new dependencies.
///
/// Shows once after onboarding (see [GuidedTour.shouldShow]), as a
/// transparent route over the main shell: dimmed scrim, a rounded cutout
/// with a ring around the highlighted target, and a caption card with
/// Next / Back / Skip controls. Finishing or skipping always marks the
/// tour seen via [onFinish], so the UI can never be stranded mid-tour.

/// One coach-mark step.
class TourStep {
  /// Key of the widget to spotlight. Null = centered card, no cutout.
  final GlobalKey? targetKey;

  /// Main-shell tab to select while this step is shown.
  final int tab;

  /// String keys (must exist in both `_en` and `_ur`).
  final String titleKey;
  final String bodyKey;
  final String? hintKey;

  const TourStep({
    this.targetKey,
    required this.tab,
    required this.titleKey,
    required this.bodyKey,
    this.hintKey,
  });
}

class GuidedTour {
  /// Auto-show exactly once: onboarding done, tour not yet seen.
  static bool shouldShow(AppSettings s) =>
      s.onboardingDone && !s.tourSeen;

  /// Pushes the tour as a transparent route. [onFinish] must persist
  /// `tourSeen`; it is called exactly once however the tour ends
  /// (Done, Skip, or system back).
  static Future<void> show(
    BuildContext context, {
    required List<TourStep> steps,
    required Strings strings,
    ValueChanged<int>? onStep,
    required VoidCallback onFinish,
  }) {
    return Navigator.of(context).push(PageRouteBuilder(
      opaque: false,
      barrierDismissible: false,
      transitionDuration: const Duration(milliseconds: 220),
      reverseTransitionDuration: const Duration(milliseconds: 150),
      pageBuilder: (_, __, ___) => _TourPage(
        steps: steps,
        strings: strings,
        onStep: onStep,
        onDone: onFinish,
      ),
      transitionsBuilder: (_, anim, __, child) =>
          FadeTransition(opacity: anim, child: child),
    ));
  }
}

class _TourPage extends StatefulWidget {
  final List<TourStep> steps;
  final Strings strings;
  final ValueChanged<int>? onStep;
  final VoidCallback onDone;

  const _TourPage({
    required this.steps,
    required this.strings,
    this.onStep,
    required this.onDone,
  });

  @override
  State<_TourPage> createState() => _TourPageState();
}

class _TourPageState extends State<_TourPage> {
  int _i = 0;
  Rect? _target;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    // Announce the initial step only after this route has finished
    // mounting. Calling onStep synchronously here would mark the host
    // (e.g. MainShell's tab switch) dirty while the framework is still
    // building this route — a setState-during-build red screen, exactly
    // what build 15 hit on device.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onStep?.call(0);
    });
  }

  /// Resolve the current target's screen rect. Guarded by equality so it
  /// is safe to re-run after every build (rotation, resize, tab switch).
  void _locate() {
    final key = widget.steps[_i].targetKey;
    Rect? r;
    final ctx = key?.currentContext;
    if (ctx != null) {
      final box = ctx.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) {
        r = box.localToGlobal(Offset.zero) & box.size;
      }
    }
    if (r != _target && mounted) setState(() => _target = r);
  }

  void _go(int i) {
    if (i < 0 || i >= widget.steps.length) return;
    widget.onStep?.call(i);
    setState(() {
      _i = i;
      _target = null;
    });
  }

  /// The single exit path: Done, Skip, and system back all come here.
  void _finish() {
    if (_finished) return;
    _finished = true;
    widget.onDone();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    // Re-locate after every build; _locate no-ops when nothing moved.
    WidgetsBinding.instance.addPostFrameCallback((_) => _locate());
    final dark = Theme.of(context).brightness == Brightness.dark;
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        // System back: the route already popped — just record completion.
        if (didPop && !_finished) {
          _finished = true;
          widget.onDone();
        }
      },
      child: Material(
        type: MaterialType.transparency,
        child: Stack(
          children: [
            // Scrim: absorbs every tap so nothing under the tour can be
            // touched by accident. RenderCustomPaint hit-tests its full
            // size, so one GestureDetector is enough.
            Positioned.fill(
              child: GestureDetector(
                onTap: () {},
                child: CustomPaint(
                  painter: _ScrimPainter(
                    cutout: _target,
                    scrim: Colors.black
                        .withValues(alpha: dark ? 0.74 : 0.60),
                    ring: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            ),
            _positionedCard(context),
          ],
        ),
      ),
    );
  }

  /// Caption card: below the target when there is room, above it
  /// otherwise, centered when there is no target. Always clamped to the
  /// screen with 8pt-grid margins; body scrolls on very small screens.
  Widget _positionedCard(BuildContext context) {
    const margin = th.Gap.x2;
    final screen = MediaQuery.sizeOf(context);
    final pad = MediaQuery.paddingOf(context);
    final r = _target;

    Widget card = AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: Container(
        key: ValueKey(_i),
        child: _TourCard(
          step: widget.steps[_i],
          index: _i,
          total: widget.steps.length,
          strings: widget.strings,
          onSkip: _finish,
          onBack: _i > 0 ? () => _go(_i - 1) : null,
          onNext: _i < widget.steps.length - 1
              ? () => _go(_i + 1)
              : _finish,
          isLast: _i == widget.steps.length - 1,
        ),
      ),
    );

    if (r == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(th.Gap.x3),
          child: ConstrainedBox(
            constraints: BoxConstraints(
                maxWidth: 420,
                maxHeight: screen.height - pad.vertical - th.Gap.x4),
            child: card,
          ),
        ),
      );
    }
    final above = r.top - pad.top - margin;
    final below = screen.height - r.bottom - pad.bottom - margin;
    if (below >= above) {
      final maxH = (below - 12).clamp(120.0, screen.height);
      return Positioned(
        top: r.bottom + 12,
        left: margin,
        right: margin,
        child:
            ConstrainedBox(constraints: BoxConstraints(maxHeight: maxH), child: card),
      );
    }
    final maxH = (above - 12).clamp(120.0, screen.height);
    return Positioned(
      bottom: screen.height - r.top + 12,
      left: margin,
      right: margin,
      child:
          ConstrainedBox(constraints: BoxConstraints(maxHeight: maxH), child: card),
    );
  }
}

class _TourCard extends StatelessWidget {
  final TourStep step;
  final int index;
  final int total;
  final Strings strings;
  final VoidCallback onSkip;
  final VoidCallback? onBack;
  final VoidCallback onNext;
  final bool isLast;

  const _TourCard({
    required this.step,
    required this.index,
    required this.total,
    required this.strings,
    required this.onSkip,
    required this.onBack,
    required this.onNext,
    required this.isLast,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = strings;
    return Card(
      elevation: 8,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(th.Radius.card)),
      child: Padding(
        padding: const EdgeInsets.all(th.Gap.x2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(t.get(step.titleKey),
                style: const TextStyle(
                    fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: th.Gap.x1),
            Flexible(
              child: SingleChildScrollView(
                child: Text(t.get(step.bodyKey),
                    style: Theme.of(context).textTheme.bodyMedium),
              ),
            ),
            if (step.hintKey != null) ...[
              const SizedBox(height: th.Gap.x1 + 4),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.lightbulb_outline,
                      size: 18, color: cs.primary),
                  const SizedBox(width: th.Gap.x1),
                  Expanded(
                    child: Text(t.get(step.hintKey!),
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: cs.onSurfaceVariant)),
                  ),
                ],
              ),
            ],
            const SizedBox(height: th.Gap.x2),
            Row(
              children: [
                TextButton(onPressed: onSkip, child: Text(t.get('tourSkip'))),
                const Spacer(),
                if (onBack != null)
                  TextButton(
                      onPressed: onBack, child: Text(t.get('tourBack'))),
                const SizedBox(width: th.Gap.x1),
                FilledButton(
                  onPressed: onNext,
                  child: Text(isLast ? t.get('tourDone') : t.get('tourNext')),
                ),
              ],
            ),
            const SizedBox(height: th.Gap.x1),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ...List.generate(
                  total,
                  (d) => Container(
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: d == index
                          ? cs.primary
                          : cs.outlineVariant,
                    ),
                  ),
                ),
                const SizedBox(width: th.Gap.x1),
                Text(
                  t
                      .get('tourStepOf')
                      .replaceFirst('{i}', '${index + 1}')
                      .replaceFirst('{n}', '$total'),
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Dimmed scrim with a rounded-rectangle cutout + accent ring around it.
class _ScrimPainter extends CustomPainter {
  final Rect? cutout;
  final Color scrim;
  final Color ring;

  _ScrimPainter({
    required this.cutout,
    required this.scrim,
    required this.ring,
  });

  static const _pad = 10.0;
  static const _radius = 18.0;

  @override
  void paint(Canvas canvas, Size size) {
    final full = Path()..addRect(Offset.zero & size);
    final c = cutout;
    if (c == null) {
      canvas.drawPath(full, Paint()..color = scrim);
      return;
    }
    final hole = Path()
      ..addRRect(RRect.fromRectAndRadius(
          c.inflate(_pad), const Radius.circular(_radius)));
    canvas.drawPath(
      Path.combine(PathOperation.difference, full, hole),
      Paint()..color = scrim,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          c.inflate(_pad), const Radius.circular(_radius)),
      Paint()
        ..color = ring
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
  }

  @override
  bool shouldRepaint(covariant _ScrimPainter old) =>
      old.cutout != cutout || old.scrim != scrim || old.ring != ring;
}
