import 'package:intl/intl.dart';

const _ist = Duration(hours: 5, minutes: 30);

/// Parse an ISO-8601 string from the API (always GMT/UTC) and return IST DateTime.
DateTime _toIst(String raw) {
  // If the string has no timezone indicator, treat it as UTC.
  final dt = DateTime.parse(raw);
  final utc = dt.isUtc ? dt : dt.toUtc();
  return utc.add(_ist);
}

/// Format a GMT/UTC ISO-8601 date-time string → "dd-MM-yyyy" in IST.
/// Returns "--" for null/empty input.
String fmtDate(String? raw) {
  if (raw == null || raw.isEmpty) return '--';
  try {
    // DATE-only strings (e.g. "2026-06-14") have no time component.
    // Append T00:00:00Z so they parse as midnight UTC.
    final normalized = raw.length <= 10 ? '${raw}T00:00:00Z' : raw;
    return DateFormat('dd-MM-yyyy').format(_toIst(normalized));
  } catch (_) {
    return raw.length >= 10 ? raw.substring(0, 10) : raw;
  }
}

/// Format a GMT/UTC ISO-8601 date-time string → "dd-MM-yyyy hh:mm a" in IST.
/// Returns "--" for null/empty input.
String fmtDateTime(String? raw) {
  if (raw == null || raw.isEmpty) return '--';
  try {
    final normalized = raw.length <= 10 ? '${raw}T00:00:00Z' : raw;
    return DateFormat('dd-MM-yyyy hh:mm a').format(_toIst(normalized));
  } catch (_) {
    return raw;
  }
}

/// Format a DateTime that is already in UTC → "dd-MM-yyyy" in IST.
String fmtDateFromUtc(DateTime utc) {
  return DateFormat('dd-MM-yyyy').format(utc.toUtc().add(_ist));
}

/// Format a DateTime that is already in UTC → "dd-MM-yyyy hh:mm a" in IST.
String fmtDateTimeFromUtc(DateTime utc) {
  return DateFormat('dd-MM-yyyy hh:mm a').format(utc.toUtc().add(_ist));
}
