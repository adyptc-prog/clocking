import 'dart:math';

import '../l10n.dart';

// ─── Modele de date ───────────────────────────────────────────────────────────
// Toate înregistrările sincronizate au un id stabil și „updatedAt”: la
// sincronizare câștigă versiunea mai nouă, iar ștergerile se păstrează ca
// marcaje (deleted), ca o adăugare întârziată prin SMS să nu readucă o
// înregistrare ștearsă.

final _rnd = Random.secure();

// Id scurt (SMS-urile de sincronizare îl poartă în fiecare mesaj).
String newId() {
  const alphabet = 'abcdefghijkmnpqrstuvwxyz23456789';
  return List.generate(10, (_) => alphabet[_rnd.nextInt(alphabet.length)]).join();
}

// Secretul din codul QR: fără el, un QR făcut „acasă” cu id-ul angajatului
// nu e acceptat. Fără caractere ușor de confundat.
String newQrSecret() {
  const alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  return List.generate(8, (_) => alphabet[_rnd.nextInt(alphabet.length)]).join();
}

DateTime _ms(Object? v) =>
    DateTime.fromMillisecondsSinceEpoch((v as num?)?.toInt() ?? 0);

// ─── Angajat ──────────────────────────────────────────────────────────────────
class Employee {
  final String id;
  final String name;
  final String role;
  final String phone;
  final String note;
  final bool active;
  final String qrSecret;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool deleted;

  const Employee({
    required this.id,
    required this.name,
    this.role = '',
    this.phone = '',
    this.note = '',
    this.active = true,
    required this.qrSecret,
    required this.createdAt,
    required this.updatedAt,
    this.deleted = false,
  });

  static const qrPrefix = 'CLK1';

  // Conținutul codului QR al angajatului.
  String get qrPayload => '$qrPrefix:$id:$qrSecret';

  Employee copyWith({
    String? name,
    String? role,
    String? phone,
    String? note,
    bool? active,
    String? qrSecret,
    DateTime? updatedAt,
    bool? deleted,
  }) =>
      Employee(
        id: id,
        name: name ?? this.name,
        role: role ?? this.role,
        phone: phone ?? this.phone,
        note: note ?? this.note,
        active: active ?? this.active,
        qrSecret: qrSecret ?? this.qrSecret,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        deleted: deleted ?? this.deleted,
      );

  // Chei scurte — același format pentru stocare și pentru SMS-uri.
  Map<String, dynamic> toJson() => {
        'i': id,
        'n': name,
        if (role.isNotEmpty) 'r': role,
        if (phone.isNotEmpty) 'p': phone,
        if (note.isNotEmpty) 'o': note,
        if (!active) 'a': 0,
        'q': qrSecret,
        'c': createdAt.millisecondsSinceEpoch,
        'u': updatedAt.millisecondsSinceEpoch,
        if (deleted) 'x': 1,
      };

  factory Employee.fromJson(Map<String, dynamic> j) => Employee(
        id: j['i'] as String,
        name: (j['n'] as String?) ?? '',
        role: (j['r'] as String?) ?? '',
        phone: (j['p'] as String?) ?? '',
        note: (j['o'] as String?) ?? '',
        active: j['a'] != 0,
        qrSecret: (j['q'] as String?) ?? '',
        createdAt: _ms(j['c']),
        updatedAt: _ms(j['u']),
        deleted: j['x'] == 1,
      );
}

// ─── Pontaj (o intrare sau o ieșire) ──────────────────────────────────────────
enum PunchType { clockIn, clockOut }

// Sursa pontajului: scanare, adăugat manual de manager, sau scanare corectată
// de manager (oră / tip schimbat) — rapoartele le marchează diferit.
class PunchSource {
  static const scan = 's';
  static const manual = 'm';
  static const corrected = 'c';
}

class Punch {
  final String id;
  final String employeeId;
  final DateTime at;
  final PunchType type;
  final String source;
  final String note;
  final DateTime updatedAt;
  final bool deleted;

  const Punch({
    required this.id,
    required this.employeeId,
    required this.at,
    required this.type,
    this.source = PunchSource.scan,
    this.note = '',
    required this.updatedAt,
    this.deleted = false,
  });

  bool get isIn => type == PunchType.clockIn;

  Punch copyWith({
    DateTime? at,
    PunchType? type,
    String? source,
    String? note,
    DateTime? updatedAt,
    bool? deleted,
  }) =>
      Punch(
        id: id,
        employeeId: employeeId,
        at: at ?? this.at,
        type: type ?? this.type,
        source: source ?? this.source,
        note: note ?? this.note,
        updatedAt: updatedAt ?? this.updatedAt,
        deleted: deleted ?? this.deleted,
      );

  Map<String, dynamic> toJson() => {
        'i': id,
        'e': employeeId,
        't': at.millisecondsSinceEpoch,
        'k': isIn ? 'i' : 'o',
        if (source != PunchSource.scan) 's': source,
        if (note.isNotEmpty) 'o': note,
        'u': updatedAt.millisecondsSinceEpoch,
        if (deleted) 'x': 1,
      };

  factory Punch.fromJson(Map<String, dynamic> j) => Punch(
        id: j['i'] as String,
        employeeId: j['e'] as String,
        at: _ms(j['t']),
        type: j['k'] == 'o' ? PunchType.clockOut : PunchType.clockIn,
        source: (j['s'] as String?) ?? PunchSource.scan,
        note: (j['o'] as String?) ?? '',
        updatedAt: _ms(j['u']),
        deleted: j['x'] == 1,
      );
}

// ─── Tură ─────────────────────────────────────────────────────────────────────
// Orele sunt minute de la miezul nopții. Sfârșitul ≤ începutul înseamnă că
// tura trece de miezul nopții (ex. 22:00–06:00); egale = tură de 24 de ore.
class Shift {
  final String id;
  final String name;
  final int start;
  final int end;
  final int color;

  const Shift({
    required this.id,
    required this.name,
    required this.start,
    required this.end,
    this.color = 0,
  });

  int get durationMinutes {
    final d = end - start;
    return d > 0 ? d : d + 24 * 60;
  }

  bool get crossesMidnight => end <= start;

  // Codul scurt afișat în celulele graficului.
  String get shortLabel {
    // Ture create din program (numite după ore, ex. „09–17”): „9-17”.
    if (RegExp(r'^\d').hasMatch(name.trim())) return '${start ~/ 60}-${(end % 1440) ~/ 60}';
    final words = name.trim().split(RegExp(r'\s+'));
    if (words.length >= 2 && RegExp(r'^\d+h?$').hasMatch(words.last)) {
      return '${words.first[0].toUpperCase()}${words.last.replaceAll('h', '')}';
    }
    if (words.length >= 2) {
      return '${words[0][0]}${words[1][0]}'.toUpperCase();
    }
    final n = name.trim();
    return n.length <= 3 ? n.toUpperCase() : n.substring(0, 2).toUpperCase();
  }

  String get hoursLabel => '${fmtMinutes(start)}–${fmtMinutes(end)}';

  Shift copyWith({String? name, int? start, int? end, int? color}) => Shift(
        id: id,
        name: name ?? this.name,
        start: start ?? this.start,
        end: end ?? this.end,
        color: color ?? this.color,
      );

  Map<String, dynamic> toJson() =>
      {'i': id, 'n': name, 's': start, 'e': end, 'c': color};

  factory Shift.fromJson(Map<String, dynamic> j) => Shift(
        id: j['i'] as String,
        name: (j['n'] as String?) ?? '',
        start: (j['s'] as num?)?.toInt() ?? 0,
        end: (j['e'] as num?)?.toInt() ?? 0,
        color: (j['c'] as num?)?.toInt() ?? 0,
      );

  // Turele implicite, create la prima pornire în limba aleasă atunci.
  static List<Shift> defaults() => [
        Shift(id: 's1', name: tr('Normal', 'Regular'), start: 8 * 60, end: 16 * 60, color: 0),
        Shift(id: 's2', name: tr('Tura 1', 'Shift 1'), start: 6 * 60, end: 14 * 60, color: 1),
        Shift(id: 's3', name: tr('Tura 2', 'Shift 2'), start: 14 * 60, end: 22 * 60, color: 2),
        Shift(id: 's4', name: tr('Tura 3', 'Shift 3'), start: 22 * 60, end: 6 * 60, color: 3),
        Shift(id: 's5', name: tr('Zi 12h', 'Day 12h'), start: 7 * 60, end: 19 * 60, color: 4),
        Shift(id: 's6', name: tr('Noapte 12h', 'Night 12h'), start: 19 * 60, end: 7 * 60, color: 5),
        Shift(id: 's7', name: tr('Gardă 24h', 'Duty 24h'), start: 8 * 60, end: 8 * 60, color: 6),
      ];
}

String fmtMinutes(int m) {
  final mm = m % (24 * 60);
  return '${(mm ~/ 60).toString().padLeft(2, '0')}:${(mm % 60).toString().padLeft(2, '0')}';
}

// ─── Codurile zilelor din grafic (în afara turelor) ───────────────────────────
// O zi din grafic e fie id-ul unei ture, fie unul din codurile de mai jos,
// fie '' (neprogramat).
class DayCode {
  static const none = '';
  static const off = 'L';           // liber
  static const vacation = 'CO';     // concediu de odihnă
  static const medical = 'CM';      // concediu medical
  static const unpaid = 'CFP';      // concediu fără plată
  static const holiday = 'SL';      // sărbătoare legală
  static const other = 'AL';        // alt motiv (învoire etc.)

  static const leaves = [vacation, medical, unpaid, other];
  static const nonShift = [off, vacation, medical, unpaid, holiday, other];

  static bool isShift(String code) =>
      code.isNotEmpty && !nonShift.contains(code);

  static bool isLeave(String code) => leaves.contains(code);

  static String label(String code) => switch (code) {
        off => tr('Liber', 'Day off'),
        vacation => tr('Concediu de odihnă', 'Annual leave'),
        medical => tr('Concediu medical', 'Sick leave'),
        unpaid => tr('Concediu fără plată', 'Unpaid leave'),
        holiday => tr('Sărbătoare legală', 'Public holiday'),
        other => tr('Alt motiv / învoire', 'Other / time off'),
        _ => tr('Neprogramat', 'Not scheduled'),
      };

  // Codul scurt din celulă — în engleză, prescurtările englezești.
  static String short(String code) => switch (code) {
        off => tr('L', 'O'),
        vacation => tr('CO', 'AL'),
        medical => tr('CM', 'SL'),
        unpaid => tr('CFP', 'UL'),
        holiday => tr('SL', 'PH'),
        other => tr('AM', 'OT'),
        _ => '',
      };
}

// ─── Date calendaristice (zile locale, fără oră) ──────────────────────────────
DateTime dayOf(DateTime d) => DateTime(d.year, d.month, d.day);

String monthKey(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}';

DateTime monthFromKey(String key) {
  final p = key.split('-');
  return DateTime(int.parse(p[0]), int.parse(p[1]));
}

int daysInMonth(DateTime d) => DateTime(d.year, d.month + 1, 0).day;

// Lunile (cheile) atinse de intervalul [from, to].
List<String> monthsBetween(DateTime from, DateTime to) {
  final out = <String>[];
  var m = DateTime(from.year, from.month);
  final last = DateTime(to.year, to.month);
  while (!m.isAfter(last)) {
    out.add(monthKey(m));
    m = DateTime(m.year, m.month + 1);
  }
  return out;
}

String fmtDate(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

String fmtTime(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

String fmtDateTime(DateTime d) => '${fmtDate(d)} ${fmtTime(d)}';

// „7:30” — durată în ore și minute.
String fmtDuration(Duration d) {
  final neg = d.isNegative;
  final m = d.inMinutes.abs();
  return '${neg ? '-' : ''}${m ~/ 60}:${(m % 60).toString().padLeft(2, '0')}';
}

List<String> weekdayShortNames() => tr('L,Ma,Mi,J,V,S,D', 'Mo,Tu,We,Th,Fr,Sa,Su').split(',');

List<String> monthNames() => tr(
        'Ianuarie,Februarie,Martie,Aprilie,Mai,Iunie,Iulie,August,Septembrie,Octombrie,Noiembrie,Decembrie',
        'January,February,March,April,May,June,July,August,September,October,November,December')
    .split(',');

String fmtMonth(DateTime d) => '${monthNames()[d.month - 1]} ${d.year}';

// ─── Culori (comune ecranelor și PDF-urilor) ──────────────────────────────────
const kShiftPalette = <int>[
  0xFF0EA5E9, // albastru
  0xFF22C55E, // verde
  0xFFF59E0B, // portocaliu
  0xFF6366F1, // indigo
  0xFFEAB308, // galben
  0xFF1E3A8A, // bleumarin
  0xFFDC2626, // roșu
  0xFF14B8A6, // turcoaz
  0xFFA855F7, // mov
  0xFF64748B, // gri
];

int shiftColor(Shift s) => kShiftPalette[s.color % kShiftPalette.length];

int dayCodeColor(String code) => switch (code) {
      DayCode.off => 0xFFE2E8F0,
      DayCode.vacation => 0xFFBBF7D0,
      DayCode.medical => 0xFFFECACA,
      DayCode.unpaid => 0xFFFED7AA,
      DayCode.holiday => 0xFFE9D5FF,
      DayCode.other => 0xFFFDE68A,
      _ => 0xFFFFFFFF,
    };

// Text negru sau alb, după luminozitatea fundalului.
bool isDarkColor(int argb) {
  final r = (argb >> 16) & 0xFF;
  final g = (argb >> 8) & 0xFF;
  final b = argb & 0xFF;
  return (0.299 * r + 0.587 * g + 0.114 * b) < 150;
}

// Numărul de zile din intervalul [from, to], inclusiv capetele (robust la
// trecerea la ora de vară).
int calendarDays(DateTime from, DateTime to) =>
    DateTime.utc(to.year, to.month, to.day)
        .difference(DateTime.utc(from.year, from.month, from.day))
        .inDays +
    1;
