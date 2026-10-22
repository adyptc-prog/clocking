import '../l10n.dart';
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
  // Normă lunară automată: turele alese se distribuie în lună cât să acopere
  // norma legală de ore, cu zile libere între ele.
  norm,
  // Program flexibil: fără grafic; orele se socotesc doar din pontaj și se
  // compară cu norma.
  flexible,
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
      case PatternKind.norm:
        // Norma lunară are nevoie de luna întreagă — vezi generateMonth.
        code = DayCode.off;
      case PatternKind.flexible:
        code = DayCode.none;
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

// ─── Programul de lucru al unui angajat ───────────────────────────────────────
// Salvat la angajat; „Generează grafic” completează luna după el. Zilele
// marcate ca excepții (concedii, zile libere puse de manager) nu se ating.
class WorkProgram {
  final PatternKind kind;
  // fixed / rotating / norm: zilele în care poate lucra (1 = luni ... 7 = duminică).
  final Set<int> weekdays;
  // fixed: tura.
  final String shiftId;
  // rotating: turele în ordinea rotației; norm: turele folosite, pe rând.
  final List<String> shifts;
  final int rotateEveryDays;
  final int rotationOffset;
  // cycle: secvența de zile (ture și DayCode.off).
  final List<String> cycle;
  // Ziua de început a ciclului / rotației — ciclul continuă de la o lună la alta.
  final DateTime anchor;
  // Norma zilnică (8h normă întreagă; 6h, 4h la timp parțial).
  final int dailyMinutes;
  // Lucrează și în sărbătorile legale (servicii continue). Altfel ziua e SL.
  final bool workHolidays;
  final DateTime updatedAt;

  const WorkProgram({
    required this.kind,
    this.weekdays = const {1, 2, 3, 4, 5},
    this.shiftId = '',
    this.shifts = const [],
    this.rotateEveryDays = 7,
    this.rotationOffset = 0,
    this.cycle = const [],
    required this.anchor,
    this.dailyMinutes = 8 * 60,
    this.workHolidays = false,
    required this.updatedAt,
  });

  WorkProgram copyWith({DateTime? anchor, int? rotationOffset, DateTime? updatedAt}) => WorkProgram(
        kind: kind,
        weekdays: weekdays,
        shiftId: shiftId,
        shifts: shifts,
        rotateEveryDays: rotateEveryDays,
        rotationOffset: rotationOffset ?? this.rotationOffset,
        cycle: cycle,
        anchor: anchor ?? this.anchor,
        dailyMinutes: dailyMinutes,
        workHolidays: workHolidays,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toJson() => {
        'k': kind.name,
        'w': (weekdays.toList()..sort()),
        if (shiftId.isNotEmpty) 's': shiftId,
        if (shifts.isNotEmpty) 'l': shifts,
        'r': rotateEveryDays,
        if (rotationOffset != 0) 'o': rotationOffset,
        if (cycle.isNotEmpty) 'c': cycle,
        'a': '${monthKey(anchor)}-${anchor.day.toString().padLeft(2, '0')}',
        'm': dailyMinutes,
        if (workHolidays) 'h': 1,
        'u': updatedAt.millisecondsSinceEpoch,
      };

  factory WorkProgram.fromJson(Map<String, dynamic> j) {
    final a = ((j['a'] as String?) ?? '2026-01-01').split('-').map(int.parse).toList();
    return WorkProgram(
      kind: PatternKind.values.firstWhere((k) => k.name == j['k'], orElse: () => PatternKind.fixed),
      weekdays: ((j['w'] as List?) ?? const [1, 2, 3, 4, 5]).map((e) => (e as num).toInt()).toSet(),
      shiftId: (j['s'] as String?) ?? '',
      shifts: ((j['l'] as List?) ?? const []).map((e) => e as String).toList(),
      rotateEveryDays: (j['r'] as num?)?.toInt() ?? 7,
      rotationOffset: (j['o'] as num?)?.toInt() ?? 0,
      cycle: ((j['c'] as List?) ?? const []).map((e) => e as String).toList(),
      anchor: DateTime(a[0], a[1], a[2]),
      dailyMinutes: (j['m'] as num?)?.toInt() ?? 480,
      workHolidays: j['h'] == 1,
      updatedAt: DateTime.fromMillisecondsSinceEpoch((j['u'] as num?)?.toInt() ?? 0),
    );
  }

  // Descrierea scurtă, pentru liste.
  String describe(Map<String, Shift> shiftMap) {
    String name(String id) => id == DayCode.off ? DayCode.short(id) : (shiftMap[id]?.shortLabel ?? '?');
    final wd = weekdayShortNames();
    final days = (weekdays.toList()..sort()).map((d) => wd[d - 1]).join(' ');
    final hours = dailyMinutes == 480 ? '' : ' · ${tr('normă', 'norm')} ${dailyMinutes ~/ 60}h/${tr('zi', 'day')}';
    final fixed = shiftMap[shiftId];
    return switch (kind) {
      PatternKind.fixed => '${tr('Fix', 'Fixed')}: ${fixed?.name ?? '?'} ${fixed?.hoursLabel ?? ''} · $days$hours',
      PatternKind.rotating => '${tr('Ture rotative', 'Rotating')}: ${shifts.map(name).join(' → ')} · $days$hours',
      PatternKind.cycle => '${tr('Ciclu', 'Cycle')}: ${cycle.map(name).join(' ')} · ${tr('din', 'from')} ${fmtDate(anchor)}$hours',
      PatternKind.norm => '${tr('Normă lunară', 'Monthly norm')}: ${shifts.map(name).join(', ')} · $days$hours',
      PatternKind.flexible => '${tr('Flexibil — ore din pontaj', 'Flexible — hours from clockings')} · '
          '${tr('normă', 'norm')} ${dailyMinutes ~/ 60}h/${tr('zi', 'day')}',
    };
  }
}

int _floorMod(int a, int n) => ((a % n) + n) % n;

int _floorDiv(int a, int n) => (a - _floorMod(a, n)) ~/ n;

// Codul zilei după tiparul programului (fixed / rotating / cycle).
String patternCode(WorkProgram p, DateTime d) {
  switch (p.kind) {
    case PatternKind.fixed:
      return p.weekdays.contains(d.weekday) && p.shiftId.isNotEmpty ? p.shiftId : DayCode.off;
    case PatternKind.rotating:
      if (!p.weekdays.contains(d.weekday) || p.shifts.isEmpty) return DayCode.off;
      final every = p.rotateEveryDays < 1 ? 1 : p.rotateEveryDays;
      final anchor = every == 7 ? p.anchor.subtract(Duration(days: p.anchor.weekday - 1)) : p.anchor;
      final block = _floorDiv(_daysBetween(anchor, d), every);
      return p.shifts[_floorMod(block + p.rotationOffset, p.shifts.length)];
    case PatternKind.cycle:
      if (p.cycle.isEmpty) return DayCode.off;
      return p.cycle[_floorMod(_daysBetween(p.anchor, d), p.cycle.length)];
    case PatternKind.norm:
      return DayCode.off;
    case PatternKind.flexible:
      return DayCode.none;
  }
}

bool _isWorkingDay(DateTime d, Set<DateTime> holidays) =>
    d.weekday <= 5 && !holidays.contains(d);

// Norma lunară legală: zilele lucrătoare (luni–vineri, fără sărbători legale)
// × norma zilnică.
int monthNormMinutes(DateTime month, int dailyMinutes) {
  final holidays = romanianHolidays(month.year);
  var n = 0;
  for (var day = 1; day <= daysInMonth(month); day++) {
    if (_isWorkingDay(DateTime(month.year, month.month, day), holidays)) n++;
  }
  return n * dailyMinutes;
}

// Norma lunii după concedii: fiecare zi de concediu căzută într-o zi
// lucrătoare scade o normă zilnică.
int monthTargetMinutes(DateTime month, int dailyMinutes, Map<DateTime, String> exceptions) {
  final holidays = romanianHolidays(month.year);
  var leave = 0;
  for (final e in exceptions.entries) {
    if (DayCode.isLeave(e.value) && _isWorkingDay(e.key, holidays)) leave++;
  }
  final t = monthNormMinutes(month, dailyMinutes) - leave * dailyMinutes;
  return t < 0 ? 0 : t;
}

// Norma pe intervalul [from, to]: zilele lucrătoare × norma zilnică, minus
// zilele de concediu căzute în zile lucrătoare.
int periodNormMinutes(DateTime from, DateTime to, int dailyMinutes, String Function(DateTime) code) {
  final holidays = <DateTime>{
    for (var y = from.year; y <= to.year; y++) ...romanianHolidays(y),
  };
  var n = 0;
  for (var d = dayOf(from); !d.isAfter(dayOf(to)); d = DateTime(d.year, d.month, d.day + 1)) {
    if (_isWorkingDay(d, holidays) && !DayCode.isLeave(code(d))) n++;
  }
  return n * dailyMinutes;
}

// Orele programate dintr-o lună de grafic.
int plannedMinutes(Iterable<String> codes, Map<String, Shift> shifts) =>
    codes.fold(0, (s, c) => s + (DayCode.isShift(c) ? (shifts[c]?.durationMinutes ?? 0) : 0));

// Generează luna după program. [exceptions] = zilele marcate de manager, care
// nu se ating; întoarce codurile tuturor celorlalte zile din lună.
// [staggerIndex]/[staggerCount] decalează angajații cu normă automată între
// ei, ca să nu lucreze toți în aceleași zile.
Map<DateTime, String> generateMonth({
  required WorkProgram program,
  required DateTime month,
  required Map<DateTime, String> exceptions,
  required Map<String, Shift> shifts,
  int staggerIndex = 0,
  int staggerCount = 1,
}) {
  final holidays = romanianHolidays(month.year);
  final out = <DateTime, String>{};
  final free = [
    for (var day = 1; day <= daysInMonth(month); day++) DateTime(month.year, month.month, day),
  ].where((d) => !exceptions.containsKey(d)).toList();
  bool holidayOff(DateTime d) => holidays.contains(d) && !program.workHolidays;

  // Flexibil: fără ture; doar sărbătorile rămân marcate.
  if (program.kind == PatternKind.flexible) {
    for (final d in free) {
      out[d] = holidayOff(d) ? DayCode.holiday : DayCode.none;
    }
    return out;
  }

  if (program.kind != PatternKind.norm) {
    for (final d in free) {
      out[d] = holidayOff(d) ? DayCode.holiday : patternCode(program, d);
    }
    return out;
  }

  // Normă automată: zilele disponibile, apoi câte ture încap în normă.
  final avail = <DateTime>[];
  for (final d in free) {
    if (holidayOff(d)) {
      out[d] = DayCode.holiday;
    } else if (!program.weekdays.contains(d.weekday)) {
      out[d] = DayCode.off;
    } else {
      avail.add(d);
    }
  }
  final used = program.shifts.map((id) => shifts[id]).whereType<Shift>().toList();
  if (used.isEmpty || avail.isEmpty) {
    for (final d in avail) {
      out[d] = DayCode.off;
    }
    return out;
  }
  final target = monthTargetMinutes(month, program.dailyMinutes, exceptions);
  final seq = <Shift>[];
  var total = 0;
  while (seq.length < avail.length) {
    final s = used[seq.length % used.length];
    // Tura se adaugă dacă totalul rămâne cel mult o jumătate de tură peste normă.
    if (total + s.durationMinutes - target > s.durationMinutes ~/ 2) break;
    seq.add(s);
    total += s.durationMinutes;
  }
  // După o tură lungă (12h+) sau de noapte, ziua următoare e liberă.
  final minGap = used.any((s) => s.durationMinutes >= 12 * 60 || s.crossesMidnight) ? 2 : 1;
  final offset = staggerCount > 1 ? staggerIndex / staggerCount : 0.0;
  final chosen = <DateTime, String>{};
  DateTime? prev;
  var idx = 0;
  for (var j = 0; j < seq.length; j++) {
    final ideal = ((j + offset) * avail.length / seq.length).floor();
    if (idx < ideal) idx = ideal;
    while (idx < avail.length && prev != null && _daysBetween(prev, avail[idx]) < minGap) {
      idx++;
    }
    if (idx >= avail.length) break;
    chosen[avail[idx]] = seq[j].id;
    prev = avail[idx];
    idx++;
  }
  for (final d in avail) {
    out[d] = chosen[d] ?? DayCode.off;
  }
  return out;
}
