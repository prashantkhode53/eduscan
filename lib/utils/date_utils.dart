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

/// Format a bare "HH:mm[:ss]" clock string stored in GMT/UTC → "hh:mm a" in IST.
///
/// Attendance `time_in` / `time_out` are PostgreSQL `TIME` columns written from
/// the server clock (UTC on Render), so they carry no date or zone. We add the
/// IST offset with hour-wraparound and render 12-hour time.
/// Returns "--:--" for null/empty input.
String fmtTimeOfDay(String? raw) {
  if (raw == null || raw.isEmpty) return '--:--';
  final parts = raw.split(':');
  if (parts.length < 2) return raw;
  final h = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  if (h == null || m == null) return raw;

  // Add IST offset (+5:30) with wraparound into the next day.
  final total = (h * 60 + m + _ist.inMinutes) % (24 * 60);
  final istH  = total ~/ 60;
  final istM  = total % 60;

  final ampm = istH >= 12 ? 'PM' : 'AM';
  final h12  = istH % 12 == 0 ? 12 : istH % 12;
  return '${h12.toString().padLeft(2, '0')}:${istM.toString().padLeft(2, '0')} $ampm';
}

/// Format a DateTime that is already in UTC → "dd-MM-yyyy" in IST.
String fmtDateFromUtc(DateTime utc) {
  return DateFormat('dd-MM-yyyy').format(utc.toUtc().add(_ist));
}

/// Format a DateTime that is already in UTC → "dd-MM-yyyy hh:mm a" in IST.
String fmtDateTimeFromUtc(DateTime utc) {
  return DateFormat('dd-MM-yyyy hh:mm a').format(utc.toUtc().add(_ist));
}
