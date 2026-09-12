import 'plan.dart';

/// Why `upkeep fix --apply` declined to touch anything.
class ApplyRefused implements Exception {
  const ApplyRefused(this.message, {this.hint});
  final String message;
  final String? hint;
}

/// What happened when a plan was applied.
class ApplyResult {
  const ApplyResult({
    required this.applied,
    this.verifiedWith,
    this.revertedBecause,
  });

  /// The changes that were made and kept.
  final List<AutomaticFix> applied;

  /// The command that confirmed the new pubspec resolves, when one ran.
  final String? verifiedWith;

  /// Set when `pub get` did not succeed and every file was restored.
  final String? revertedBecause;

  bool get wasReverted => revertedBecause != null;
}
