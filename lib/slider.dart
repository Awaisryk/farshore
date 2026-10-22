import 'package:flutter/material.dart';

/// Keep the value-indicator portal inside the slider's own accessibility tree.
/// Flutter 3.47 can otherwise serialize an orphan node during incremental route
/// updates, corrupting the desktop accessibility bridge (flutter/flutter#190357).
/// The stable semantics boundary also keeps enabled-state updates connected when
/// a slider's route is covered by another dialog.
class FarshoreSlider extends StatelessWidget {
  const FarshoreSlider({super.key, required this.child});
  final Slider child;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    explicitChildNodes: true,
    child: Overlay.wrap(
      alwaysSizeToContent: true,
      clipBehavior: Clip.none,
      child: child,
    ),
  );
}
