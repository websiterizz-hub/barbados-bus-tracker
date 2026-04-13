import 'dart:math' as math;

import '../models/app_models.dart';

/// Formats a non-negative duration as hours, minutes, and seconds (e.g. `1h 4m 2s`, `14m 05s`, `45s`).
String formatDurationHms(int totalSeconds) {
  final s = math.max(0, totalSeconds);
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = s % 60;
  if (h > 0) {
    return '${h}h ${m}m ${sec}s';
  }
  if (m > 0) {
    return '${m}m ${sec.toString().padLeft(2, '0')}s';
  }
  return '${sec}s';
}

/// Prefer numeric ETA as H/M/S for tracking; otherwise API labels (e.g. clock text).
String formatArrivalEtaForDisplay(Arrival arrival) {
  if (arrival.confidenceState == 'tracking') {
    final sec = arrival.watchEtaSeconds ?? arrival.etaSeconds;
    if (sec > 0) {
      return formatDurationHms(sec);
    }
  }
  return arrival.watchEtaLabel ?? arrival.etaLabel;
}
