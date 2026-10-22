import 'models.dart';

// ─── Calculul raportului de pontaj (pur, testabil) ────────────────────────────

// O prezență: intrare + ieșire. Lipsa uneia = pontaj incomplet (ieșire
// uitată, intrare uitată), cu excepția turei în desfășurare.
class WorkSession {
  final DateTime? start;
  final DateTime? end;
  final bool ongoing;
  final bool edited;

  const WorkSession(this.start, this.end, {this.ongoing = false, this.edited = false});

  bool get complete => start != null && end != null;
  bool get incomplete => !complete && !ongoing;
  Duration get duration => complete ? end!.difference(start!) : Duration.zero;
  DateTime get anchor => (start ?? end)!;
}

enum DayStatus { present, absent, scheduled, leave, off, holiday, unscheduled }

class DayRow {
  final DateTime day;
  final String code;
  final Shift? shift;
  final List<WorkSession> sessions;
  final int lateMinutes;
  final int earlyMinutes;
  final int overtimeMinutes;
  final DayStatus status;

  const DayRow({
    required this.day,
    required this.code,
    required this.shift,
    required this.sessions,
    required this.lateMinutes,
    required this.earlyMinutes,
    required this.overtimeMinutes,
    required this.status,
  });

  Duration get worked =>
      sessions.fold(Duration.zero, (sum, s) => sum + s.duration);
  bool get incomplete => sessions.any((s) => s.incomplete);
  bool get edited => sessions.any((s) => s.edited);
  int get scheduledMinutes => shift?.durationMinutes ?? 0;

  DateTime? get firstIn {
    final starts = sessions.map((s) => s.start).whereType<DateTime>().toList()..sort();
    return starts.isEmpty ? null : starts.first;
  }

  DateTime? get lastOut {
    final ends = sessions.map((s) => s.end).whereType<DateTime>().toList()..sort();
    return ends.isEmpty ? null : ends.last;
  }
}

class EmployeeReport {
  final Employee employee;
  final List<DayRow> rows;

  const EmployeeReport(this.employee, this.rows);

  int get workedMinutes => rows.fold(0, (s, r) => s + r.worked.inMinutes);
  int get scheduledMinutes => rows.fold(0, (s, r) => s + r.scheduledMinutes);
  int get daysPresent => rows.where((r) => r.status == DayStatus.present).length;
  int get absences => rows.where((r) => r.status == DayStatus.absent).length;
  int get lateCount => rows.where((r) => r.lateMinutes > 0).length;
  int get lateMinutes => rows.fold(0, (s, r) => s + r.lateMinutes);
  int get earlyMinutes => rows.fold(0, (s, r) => s + r.earlyMinutes);
  int get overtimeMinutes => rows.fold(0, (s, r) => s + r.overtimeMinutes);
  int get incompleteCount => rows.where((r) => r.incomplete).length;

  // Zilele de concediu, pe tip (CO, CM, CFP, AL).
  Map<String, int> get leaveDays {
    final out = <String, int>{};
    for (final r in rows) {
      if (DayCode.isLeave(r.code)) out[r.code] = (out[r.code] ?? 0) + 1;
    }
    return out;
  }
}

// Perechile intrare–ieșire, în ordine cronologică, din pontajele unui angajat.
List<WorkSession> buildSessions(
  List<Punch> punches, {
  required DateTime now,
  Duration maxOpen = const Duration(hours: 16),
}) {
  final sorted = punches.where((p) => !p.deleted).toList()
    ..sort((a, b) => a.at.compareTo(b.at));
  final out = <WorkSession>[];
  Punch? open;
  for (final p in sorted) {
    if (p.isIn) {
      if (open != null) {
        out.add(WorkSession(open.at, null, edited: open.source != PunchSource.scan));
      }
      open = p;
    } else if (open != null) {
      out.add(WorkSession(open.at, p.at,
          edited: open.source != PunchSource.scan || p.source != PunchSource.scan));
      open = null;
    } else {
      out.add(WorkSession(null, p.at, edited: p.source != PunchSource.scan));
    }
  }
  if (open != null) {
    final since = now.difference(open.at);
    out.add(WorkSession(open.at, null,
        ongoing: !since.isNegative && since <= maxOpen,
        edited: open.source != PunchSource.scan));
  }
  return out;
}

EmployeeReport buildEmployeeReport({
  required Employee employee,
  required List<Punch> punches,
  required String Function(DateTime day) scheduleCode,
  required Map<String, Shift> shifts,
  required DateTime from,
  required DateTime to,
  required int toleranceMinutes,
  required DateTime now,
}) {
  final sessions = buildSessions(
    punches.where((p) => p.employeeId == employee.id).toList(),
    now: now,
  );
  final byDay = <DateTime, List<WorkSession>>{};
  for (final s in sessions) {
    byDay.putIfAbsent(dayOf(s.anchor), () => []).add(s);
  }

  final today = dayOf(now);
  final rows = <DayRow>[];
  for (var d = dayOf(from); !d.isAfter(dayOf(to)); d = DateTime(d.year, d.month, d.day + 1)) {
    final code = scheduleCode(d);
    final shift = DayCode.isShift(code) ? shifts[code] : null;
    final daySessions = byDay[d] ?? const <WorkSession>[];
    final worked = daySessions.fold(0, (s, x) => s + x.duration.inMinutes);

    var late = 0;
    var early = 0;
    var overtime = 0;
    if (shift != null) {
      final shiftStart = d.add(Duration(minutes: shift.start));
      final shiftEnd = shiftStart.add(Duration(minutes: shift.durationMinutes));
      final starts = daySessions.map((s) => s.start).whereType<DateTime>().toList()..sort();
      final ends = daySessions.map((s) => s.end).whereType<DateTime>().toList()..sort();
      if (starts.isNotEmpty) {
        final diff = starts.first.difference(shiftStart).inMinutes;
        if (diff > toleranceMinutes) late = diff;
      }
      if (ends.isNotEmpty) {
        final diff = shiftEnd.difference(ends.last).inMinutes;
        if (diff > toleranceMinutes) early = diff;
      }
      final extra = worked - shift.durationMinutes;
      if (extra > toleranceMinutes) overtime = extra;
    } else if (code.isNotEmpty && !DayCode.isShift(code)) {
      // Lucru într-o zi liberă, de sărbătoare sau de concediu: tot e peste program.
      overtime = worked;
    }

    final DayStatus status;
    if (daySessions.isNotEmpty) {
      status = DayStatus.present;
    } else if (shift != null) {
      status = d.isBefore(today) ? DayStatus.absent : DayStatus.scheduled;
    } else if (DayCode.isLeave(code)) {
      status = DayStatus.leave;
    } else if (code == DayCode.holiday) {
      status = DayStatus.holiday;
    } else if (code == DayCode.off) {
      status = DayStatus.off;
    } else {
      status = DayStatus.unscheduled;
    }

    rows.add(DayRow(
      day: d,
      code: code,
      shift: shift,
      sessions: daySessions,
      lateMinutes: late,
      earlyMinutes: early,
      overtimeMinutes: overtime,
      status: status,
    ));
  }
  return EmployeeReport(employee, rows);
}
