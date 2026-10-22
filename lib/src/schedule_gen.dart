import 'models.dart';

// ─── Generatorul graficului de lucru ──────────────────────────────────────────
// Logică pură (fără Flutter/stocare), testabilă. Primește selecția
// managerului și întoarce codul fiecărei zile din interval: id-ul unei ture
// sau un DayCode (liber, concediu, sărbătoare).

enum PatternKind {
  // Aceleași zile din săptămână, aceeași tură (ex. L–V 08–16).
  fixed,
  // 2 sau 3 ture care se schimbă la fiecare N zile (ex. săptămânal).
  rotating,
  // Ciclu continuu de ture și zile libere (12/24, 12/48, 24/48, 24/72...).
  cycle,
}

class LeaveRange {
  final DateTime from;
  final DateTime to;
  final String code; // DayCode.vacation / medical / unpaid / other

  const LeaveRange(this.from, this.to, this.code);

  bool contains(DateTime day) =>
      !day.isBefore(dayOf(from)) && !day.isAfter(dayOf(to));
}

class ScheduleRequest {
  final PatternKind kind;
  final DateTime from;
  final DateTime to;

  // fixed + rotating: zilele lucrătoare (1 = luni ... 7 = duminică).
  final Set<int> weekdays;
  // fixed: tura.
  final String shiftId;
  // rotating: turele în ordinea rotației și la câte zile se schimbă.
  final List<String> rotationShifts;
  final int rotateEveryDays;
  // rotating: cu a câta tură din listă începe angajatul (pentru decalarea
  // angajaților între ei); cycle: din a câta zi a ciclului începe.
  final int startOffset;
  // cycle: secvența de zile — id-uri de ture sau DayCode.off.
  final List<String> cycle;

  final Set<DateTime> extraDaysOff;
  final List<LeaveRange> leaves;
  final bool legalHolidays;

  const ScheduleRequest({
    required this.kind,
    required this.from,
    required this.to,
    this.weekdays = const {1, 2, 3, 4, 5},
    this.shiftId = '',
    this.rotationShifts = const [],
    this.rotateEveryDays = 7,
    this.startOffset = 0,
    this.cycle = const [],
    this.extraDaysOff = const {},
    this.leaves = const [],
    this.legalHolidays = false,
  });
}

// Ciclurile uzuale; turele implicite: s5 = zi 12h, s6 = noapte 12h, s7 = 24h.
class CyclePreset {
  final String name;
  final List<String> cycle;
  const CyclePreset(this.name, this.cycle);

  static const presets = [
    CyclePreset('12/24', ['s5', 's6', DayCode.off]),
    CyclePreset('12/48', ['s5', 's6', DayCode.off, DayCode.off]),
    CyclePreset('24/48', ['s7', DayCode.off, DayCode.off]),
    CyclePreset('24/72', ['s7', DayCode.off, DayCode.off, DayCode.off]),
  ];
}

Map<DateTime, String> generateSchedule(ScheduleRequest r) {
  final out = <DateTime, String>{};
  final from = dayOf(r.from);
  final to = dayOf(r.to);
  if (to.isBefore(from)) return out;

  final holidays = r.legalHolidays
      ? {
          for (var y = from.year; y <= to.year; y++) ...romanianHolidays(y),
        }
      : const <DateTime>{};
  final daysOff = r.extraDaysOff.map(dayOf).toSet();

  // Rotația săptămânală pornește de luni, ca schimbarea de tură să cadă la
  // început de săptămână indiferent de ziua de start a intervalului.
  final rotationAnchor = r.rotateEveryDays == 7
      ? from.subtract(Duration(days: from.weekday - 1))
      : from;

  var i = 0;
  for (var d = from; !d.isAfter(to); d = DateTime(d.year, d.month, d.day + 1), i++) {
    String code;
    switch (r.kind) {
      case PatternKind.fixed:
        code = r.weekdays.contains(d.weekday) && r.shiftId.isNotEmpty
            ? r.shiftId
            : DayCode.off;
      case PatternKind.rotating:
        if (!r.weekdays.contains(d.weekday) || r.rotationShifts.isEmpty) {
          code = DayCode.off;
        } else {
          final every = r.rotateEveryDays < 1 ? 1 : r.rotateEveryDays;
          final block = _daysBetween(rotationAnchor, d) ~/ every;
          code = r.rotationShifts[(block + r.startOffset) % r.rotationShifts.length];
        }
      case PatternKind.cycle:
        code = r.cycle.isEmpty
            ? DayCode.off
            : r.cycle[(i + r.startOffset) % r.cycle.length];
    }

    // Prioritate: concediu > sărbătoare legală > zi liberă aleasă > tipar.
    final leave = r.leaves.where((l) => l.contains(d)).firstOrNull;
    if (leave != null) {
      code = leave.code;
    } else if (holidays.contains(d)) {
      code = DayCode.holiday;
    } else if (daysOff.contains(d)) {
      code = DayCode.off;
    }
    out[d] = code;
  }
  return out;
}

// Zile întregi între două date locale (robust la trecerea la ora de vară).
int _daysBetween(DateTime a, DateTime b) =>
    DateTime.utc(b.year, b.month, b.day)
        .difference(DateTime.utc(a.year, a.month, a.day))
        .inDays;

// ─── Sărbătorile legale din România (Codul muncii, art. 139) ──────────────────
Set<DateTime> romanianHolidays(int year) {
  final easter = orthodoxEaster(year);
  DateTime plus(int days) =>
      DateTime(easter.year, easter.month, easter.day + days);
  return {
    DateTime(year, 1, 1),
    DateTime(year, 1, 2),
    DateTime(year, 1, 6), // Boboteaza
    DateTime(year, 1, 7), // Sf. Ioan
    DateTime(year, 1, 24), // Unirea Principatelor
    plus(-2), // Vinerea Mare
    easter,
    plus(1),
    DateTime(year, 5, 1),
    DateTime(year, 6, 1),
    plus(49), // Rusalii
    plus(50),
    DateTime(year, 8, 15),
    DateTime(year, 11, 30),
    DateTime(year, 12, 1),
    DateTime(year, 12, 25),
    DateTime(year, 12, 26),
  };
}

// Paștele ortodox (algoritmul Meeus pentru calendarul iulian + 13 zile,
// valabil 1900–2099).
DateTime orthodoxEaster(int year) {
  final a = year % 4;
  final b = year % 7;
  final c = year % 19;
  final d = (19 * c + 15) % 30;
  final e = (2 * a + 4 * b - d + 34) % 7;
  final month = (d + e + 114) ~/ 31;
  final day = ((d + e + 114) % 31) + 1;
  return DateTime(year, month, day + 13);
}
