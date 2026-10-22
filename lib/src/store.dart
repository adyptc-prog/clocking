import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

// ─── Stocarea datelor (SharedPreferences, ca restul aplicațiilor) ─────────────
// Chei:
//   employees            — lista angajaților (inclusiv cei șterși, ca marcaje)
//   punches_<AAAA-LL>    — pontajele unei luni
//   schedule_<AAAA-LL>   — graficul unei luni: {idAngajat: {d: [...], u: ms}}
//   shifts               — turele: {u: ms, l: [...]}
//   company_name, late_tolerance_min, duplicate_window_min, settings_updated
//                        — setări comune, sincronizate cu partenerul
//   manager_pin, camera_front, scan_sound — setări ale acestui telefon
//
// Orice modificare locală produce un mesaj de sincronizare (outgoing), trimis
// prin SMS partenerului; mesajele partenerului se aplică prin applyRemote.

typedef ScheduleEntry = ({List<String> days, DateTime updatedAt});

class Store extends ChangeNotifier {
  Store._();
  static final Store instance = Store._();

  // Testele creează instanțe separate.
  @visibleForTesting
  factory Store.forTest() => Store._();

  // Mesajele de sincronizare de trimis partenerului.
  Future<void> Function(String msg)? outgoing;

  SharedPreferences? _prefs;
  bool _loaded = false;
  bool get loaded => _loaded;

  List<Employee> _employees = [];
  List<Shift> _shifts = [];
  DateTime _shiftsUpdated = DateTime.fromMillisecondsSinceEpoch(0);
  final Map<String, List<Punch>> _punches = {};
  final Map<String, Map<String, ScheduleEntry>> _schedules = {};

  String companyName = '';
  int lateToleranceMinutes = 5;
  int duplicateWindowMinutes = 2;
  DateTime _settingsUpdated = DateTime.fromMillisecondsSinceEpoch(0);

  String? _pinHash;
  bool cameraFront = false;
  bool scanSound = true;

  Future<SharedPreferences> get _p async =>
      _prefs ??= await SharedPreferences.getInstance();

  // ── Încărcare ───────────────────────────────────────────────────────────────
  Future<void> load() async {
    final prefs = await _p;
    _punches.clear();
    _schedules.clear();
    _employees = _decodeList(prefs.getString('employees'), Employee.fromJson);

    final shiftsRaw = prefs.getString('shifts');
    if (shiftsRaw == null) {
      _shifts = Shift.defaults();
      _shiftsUpdated = DateTime.fromMillisecondsSinceEpoch(0);
      await _saveShifts();
    } else {
      final j = jsonDecode(shiftsRaw) as Map<String, dynamic>;
      _shifts = (j['l'] as List)
          .map((e) => Shift.fromJson(e as Map<String, dynamic>))
          .toList();
      _shiftsUpdated = DateTime.fromMillisecondsSinceEpoch((j['u'] as num?)?.toInt() ?? 0);
    }

    companyName = prefs.getString('company_name') ?? '';
    lateToleranceMinutes = prefs.getInt('late_tolerance_min') ?? 5;
    duplicateWindowMinutes = prefs.getInt('duplicate_window_min') ?? 2;
    _settingsUpdated = DateTime.fromMillisecondsSinceEpoch(prefs.getInt('settings_updated') ?? 0);
    _pinHash = prefs.getString('manager_pin');
    cameraFront = prefs.getBool('camera_front') ?? false;
    scanSound = prefs.getBool('scan_sound') ?? true;
    _loaded = true;
    notifyListeners();
  }

  // După o restaurare nativă: cache-ul SharedPreferences din Dart e vechi.
  Future<void> reload() async {
    final prefs = await _p;
    await prefs.reload();
    await load();
  }

  static List<T> _decodeList<T>(String? raw, T Function(Map<String, dynamic>) f) {
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => f(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _send(String msg) async {
    final out = outgoing;
    if (out != null) await out(msg);
  }

  // ── Angajați ────────────────────────────────────────────────────────────────
  // Angajații vizibili (nu cei șterși), activi întâi, apoi alfabetic.
  List<Employee> get employees {
    final list = _employees.where((e) => !e.deleted).toList()
      ..sort((a, b) {
        if (a.active != b.active) return a.active ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    return list;
  }

  List<Employee> get activeEmployees => employees.where((e) => e.active).toList();

  // Toți angajații, inclusiv cei șterși (pentru sincronizarea inițială).
  List<Employee> get allEmployeeRecords => List.unmodifiable(_employees);

  Employee? employeeById(String id) {
    for (final e in _employees) {
      if (e.id == id) return e.deleted ? null : e;
    }
    return null;
  }

  Future<void> _saveEmployees() async {
    final prefs = await _p;
    await prefs.setString(
        'employees', jsonEncode(_employees.map((e) => e.toJson()).toList()));
  }

  void _putEmployee(Employee e) {
    final i = _employees.indexWhere((x) => x.id == e.id);
    if (i == -1) {
      _employees.add(e);
    } else {
      _employees[i] = e;
    }
  }

  Future<Employee> addEmployee({
    required String name,
    String role = '',
    String phone = '',
    String note = '',
  }) async {
    final now = DateTime.now();
    final e = Employee(
      id: newId(),
      name: name.trim(),
      role: role.trim(),
      phone: phone.trim(),
      note: note.trim(),
      qrSecret: newQrSecret(),
      createdAt: now,
      updatedAt: now,
    );
    _putEmployee(e);
    await _saveEmployees();
    notifyListeners();
    await _send(SyncCodec.employee(e));
    return e;
  }

  Future<Employee> updateEmployee(Employee e) async {
    final updated = e.copyWith(updatedAt: DateTime.now());
    _putEmployee(updated);
    await _saveEmployees();
    notifyListeners();
    await _send(SyncCodec.employee(updated));
    return updated;
  }

  // Codul QR vechi (pierdut / copiat) nu mai e acceptat.
  Future<Employee> regenerateQr(Employee e) =>
      updateEmployee(e.copyWith(qrSecret: newQrSecret()));

  // Ștergerea păstrează un marcaj (sincronizare); pontajele rămân în rapoarte
  // doar cât timp angajatul există — de aceea UI-ul recomandă dezactivarea.
  Future<void> deleteEmployee(Employee e) async {
    await updateEmployee(e.copyWith(deleted: true, active: false));
  }

  // ── Pontaje ─────────────────────────────────────────────────────────────────
  Future<List<Punch>> _month(String key) async {
    final cached = _punches[key];
    if (cached != null) return cached;
    final prefs = await _p;
    final list = _decodeList(prefs.getString('punches_$key'), Punch.fromJson);
    _punches[key] = list;
    return list;
  }

  Future<void> _saveMonth(String key) async {
    final prefs = await _p;
    final list = _punches[key] ?? const <Punch>[];
    await prefs.setString(
        'punches_$key', jsonEncode(list.map((p) => p.toJson()).toList()));
  }

  // Pontajele (neșterse) din intervalul [from, to] (zile întregi).
  Future<List<Punch>> punchesBetween(DateTime from, DateTime to,
      {String? employeeId}) async {
    final start = dayOf(from);
    final end = dayOf(to).add(const Duration(days: 1));
    final out = <Punch>[];
    for (final key in monthsBetween(start, end)) {
      for (final p in await _month(key)) {
        if (p.deleted) continue;
        if (employeeId != null && p.employeeId != employeeId) continue;
        if (p.at.isBefore(start) || !p.at.isBefore(end)) continue;
        out.add(p);
      }
    }
    out.sort((a, b) => a.at.compareTo(b.at));
    return out;
  }

  // Ultimul pontaj al angajatului (luna curentă sau cea trecută).
  Future<Punch?> lastPunch(String employeeId, DateTime now) async {
    final list = await punchesBetween(
        DateTime(now.year, now.month - 1, 1), now.add(const Duration(days: 1)),
        employeeId: employeeId);
    return list.isEmpty ? null : list.last;
  }

  // Înlocuiește pontajul cu același id — și dacă și-a schimbat luna (corectură).
  Future<void> _putPunch(Punch p) async {
    final key = monthKey(p.at);
    for (final k in {
      monthKey(DateTime(p.at.year, p.at.month - 1)),
      key,
      monthKey(DateTime(p.at.year, p.at.month + 1)),
    }) {
      final list = await _month(k);
      final before = list.length;
      list.removeWhere((x) => x.id == p.id);
      if (k != key && list.length != before) await _saveMonth(k);
    }
    (await _month(key)).add(p);
    await _saveMonth(key);
  }

  Future<Punch?> _findPunch(String id, DateTime near) async {
    for (final k in {
      monthKey(DateTime(near.year, near.month - 1)),
      monthKey(near),
      monthKey(DateTime(near.year, near.month + 1)),
    }) {
      for (final p in await _month(k)) {
        if (p.id == id) return p;
      }
    }
    return null;
  }

  Future<Punch> addPunch({
    required String employeeId,
    required DateTime at,
    required PunchType type,
    String source = PunchSource.scan,
    String note = '',
  }) async {
    final p = Punch(
      id: newId(),
      employeeId: employeeId,
      at: at,
      type: type,
      source: source,
      note: note,
      updatedAt: DateTime.now(),
    );
    await _putPunch(p);
    notifyListeners();
    await _send(SyncCodec.punch(p));
    return p;
  }

  Future<Punch> updatePunch(Punch p) async {
    final updated = p.copyWith(updatedAt: DateTime.now());
    await _putPunch(updated);
    notifyListeners();
    await _send(SyncCodec.punch(updated));
    return updated;
  }

  Future<void> deletePunch(Punch p) =>
      updatePunch(p.copyWith(deleted: true));

  // ── Ture ────────────────────────────────────────────────────────────────────
  List<Shift> get shifts => List.unmodifiable(_shifts);
  Map<String, Shift> get shiftMap => {for (final s in _shifts) s.id: s};

  Future<void> _saveShifts() async {
    final prefs = await _p;
    await prefs.setString('shifts', jsonEncode({
      'u': _shiftsUpdated.millisecondsSinceEpoch,
      'l': _shifts.map((s) => s.toJson()).toList(),
    }));
  }

  Future<void> saveShifts(List<Shift> shifts) async {
    _shifts = List.of(shifts);
    _shiftsUpdated = DateTime.now();
    await _saveShifts();
    notifyListeners();
    await _send(SyncCodec.shifts(_shifts, _shiftsUpdated));
  }

  // Id nou pentru o tură adăugată de manager.
  String nextShiftId() {
    var n = 1;
    final ids = _shifts.map((s) => s.id).toSet();
    while (ids.contains('s$n')) {
      n++;
    }
    return 's$n';
  }

  // ── Grafic ──────────────────────────────────────────────────────────────────
  Future<Map<String, ScheduleEntry>> _scheduleMonth(String key) async {
    final cached = _schedules[key];
    if (cached != null) return cached;
    final prefs = await _p;
    final out = <String, ScheduleEntry>{};
    final raw = prefs.getString('schedule_$key');
    if (raw != null) {
      try {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        for (final e in j.entries) {
          final v = e.value as Map<String, dynamic>;
          out[e.key] = (
            days: (v['d'] as List).map((x) => x as String).toList(),
            updatedAt: DateTime.fromMillisecondsSinceEpoch((v['u'] as num?)?.toInt() ?? 0),
          );
        }
      } catch (_) {}
    }
    _schedules[key] = out;
    return out;
  }

  Future<void> _saveScheduleMonth(String key) async {
    final prefs = await _p;
    final m = _schedules[key] ?? const <String, ScheduleEntry>{};
    await prefs.setString('schedule_$key', jsonEncode({
      for (final e in m.entries)
        e.key: {'d': e.value.days, 'u': e.value.updatedAt.millisecondsSinceEpoch},
    }));
  }

  // Încarcă graficele lunilor din interval — scheduleCode le citește sincron.
  Future<void> ensureSchedules(DateTime from, DateTime to) async {
    for (final key in monthsBetween(from, to)) {
      await _scheduleMonth(key);
    }
  }

  // Codul zilei din grafic (după ensureSchedules pentru luna respectivă).
  String scheduleCode(String employeeId, DateTime day) {
    final entry = _schedules[monthKey(day)]?[employeeId];
    if (entry == null || day.day > entry.days.length) return DayCode.none;
    return entry.days[day.day - 1];
  }

  Shift? scheduledShift(String employeeId, DateTime day) {
    final code = scheduleCode(employeeId, day);
    return DayCode.isShift(code) ? shiftMap[code] : null;
  }

  // Scrie zilele date în graficul angajatului (luni întregi sincronizate).
  Future<void> setScheduleDays(String employeeId, Map<DateTime, String> days) async {
    if (days.isEmpty) return;
    final byMonth = <String, Map<int, String>>{};
    for (final e in days.entries) {
      byMonth.putIfAbsent(monthKey(e.key), () => {})[e.key.day] = e.value;
    }
    final now = DateTime.now();
    for (final m in byMonth.entries) {
      final month = await _scheduleMonth(m.key);
      final len = daysInMonth(monthFromKey(m.key));
      final current = List<String>.of(month[employeeId]?.days ?? const []);
      while (current.length < len) {
        current.add(DayCode.none);
      }
      for (final d in m.value.entries) {
        current[d.key - 1] = d.value;
      }
      month[employeeId] = (days: current, updatedAt: now);
      await _saveScheduleMonth(m.key);
      await _send(SyncCodec.schedule(employeeId, m.key, current, now));
    }
    notifyListeners();
  }

  // ── Setări ──────────────────────────────────────────────────────────────────
  Future<void> saveSettings({
    required String companyName,
    required int lateToleranceMinutes,
    required int duplicateWindowMinutes,
  }) async {
    this.companyName = companyName.trim();
    this.lateToleranceMinutes = lateToleranceMinutes;
    this.duplicateWindowMinutes = duplicateWindowMinutes;
    _settingsUpdated = DateTime.now();
    await _saveSettings();
    notifyListeners();
    await _send(SyncCodec.settings(this));
  }

  Future<void> _saveSettings() async {
    final prefs = await _p;
    await prefs.setString('company_name', companyName);
    await prefs.setInt('late_tolerance_min', lateToleranceMinutes);
    await prefs.setInt('duplicate_window_min', duplicateWindowMinutes);
    await prefs.setInt('settings_updated', _settingsUpdated.millisecondsSinceEpoch);
  }

  Future<void> setCameraFront(bool v) async {
    cameraFront = v;
    await (await _p).setBool('camera_front', v);
    notifyListeners();
  }

  Future<void> setScanSound(bool v) async {
    scanSound = v;
    await (await _p).setBool('scan_sound', v);
    notifyListeners();
  }

  // ── PIN manager (doar pe acest telefon) ─────────────────────────────────────
  bool get hasPin => _pinHash != null;

  static String _hashPin(String pin) =>
      sha256.convert(utf8.encode('clocking-pin|$pin')).toString();

  bool checkPin(String pin) => _pinHash != null && _hashPin(pin) == _pinHash;

  Future<void> setPin(String? pin) async {
    final prefs = await _p;
    if (pin == null || pin.isEmpty) {
      _pinHash = null;
      await prefs.remove('manager_pin');
    } else {
      _pinHash = _hashPin(pin);
      await prefs.setString('manager_pin', _pinHash!);
    }
    notifyListeners();
  }

  // ── Sincronizare: mesajele partenerului ─────────────────────────────────────
  // Întoarce true dacă s-a schimbat ceva. Versiunea mai nouă câștigă, deci
  // mesajele sosite în altă ordine sau de două ori nu strică datele.
  Future<bool> applyRemote(String msg) async {
    try {
      final kind = SyncCodec.kindOf(msg);
      final body = msg.length > SyncCodec.headerLength
          ? msg.substring(SyncCodec.headerLength)
          : '';
      switch (kind) {
        case 'E':
          final e = Employee.fromJson(jsonDecode(body) as Map<String, dynamic>);
          final cur = _employees.where((x) => x.id == e.id).firstOrNull;
          if (cur != null && !e.updatedAt.isAfter(cur.updatedAt)) return false;
          _putEmployee(e);
          await _saveEmployees();
          notifyListeners();
          return true;
        case 'P':
          final changed = await _applyRemotePunch(
              Punch.fromJson(jsonDecode(body) as Map<String, dynamic>));
          if (changed) notifyListeners();
          return changed;
        case 'B':
          var changed = false;
          for (final j in jsonDecode(body) as List) {
            if (await _applyRemotePunch(Punch.fromJson(j as Map<String, dynamic>))) {
              changed = true;
            }
          }
          if (changed) notifyListeners();
          return changed;
        case 'G':
          final j = jsonDecode(body) as Map<String, dynamic>;
          final key = j['m'] as String;
          final empId = j['e'] as String;
          final updated = DateTime.fromMillisecondsSinceEpoch((j['u'] as num).toInt());
          final month = await _scheduleMonth(key);
          final cur = month[empId];
          if (cur != null && !updated.isAfter(cur.updatedAt)) return false;
          month[empId] = (days: (j['d'] as String).split(','), updatedAt: updated);
          await _saveScheduleMonth(key);
          notifyListeners();
          return true;
        case 'H':
          final j = jsonDecode(body) as Map<String, dynamic>;
          var changed = false;
          if (j['l'] != null) {
            final u = DateTime.fromMillisecondsSinceEpoch((j['u'] as num).toInt());
            if (u.isAfter(_shiftsUpdated)) {
              _shifts = (j['l'] as List)
                  .map((e) => Shift.fromJson(e as Map<String, dynamic>))
                  .toList();
              _shiftsUpdated = u;
              await _saveShifts();
              changed = true;
            }
          }
          if (j['su'] != null) {
            final u = DateTime.fromMillisecondsSinceEpoch((j['su'] as num).toInt());
            if (u.isAfter(_settingsUpdated)) {
              companyName = (j['n'] as String?) ?? companyName;
              lateToleranceMinutes = (j['t'] as num?)?.toInt() ?? lateToleranceMinutes;
              duplicateWindowMinutes = (j['d'] as num?)?.toInt() ?? duplicateWindowMinutes;
              _settingsUpdated = u;
              await _saveSettings();
              changed = true;
            }
          }
          if (changed) notifyListeners();
          return changed;
      }
    } catch (_) {
      // SMS corupt sau format necunoscut — ignorat.
    }
    return false;
  }

  Future<bool> _applyRemotePunch(Punch p) async {
    final cur = await _findPunch(p.id, p.at);
    if (cur != null && !p.updatedAt.isAfter(cur.updatedAt)) return false;
    await _putPunch(p);
    return true;
  }

  // Mesajele sincronizării inițiale: setări și ture, angajații, graficele
  // lunii curente și ale următoarei, pontajele lunii curente și ale celei
  // trecute (câte 6 într-un SMS).
  Future<List<String>> initialSyncMessages(DateTime now) async {
    final out = <String>[
      SyncCodec.settings(this),
      SyncCodec.shifts(_shifts, _shiftsUpdated),
      for (final e in _employees) SyncCodec.employee(e),
    ];
    for (final m in [DateTime(now.year, now.month), DateTime(now.year, now.month + 1)]) {
      final key = monthKey(m);
      final month = await _scheduleMonth(key);
      for (final e in month.entries) {
        out.add(SyncCodec.schedule(e.key, key, e.value.days, e.value.updatedAt));
      }
    }
    final punches = <Punch>[
      ...await _month(monthKey(DateTime(now.year, now.month - 1))),
      ...await _month(monthKey(now)),
    ];
    for (var i = 0; i < punches.length; i += 6) {
      out.add(SyncCodec.batch(punches.sublist(i, (i + 6).clamp(0, punches.length))));
    }
    out.add(SyncCodec.end);
    return out;
  }

  DateTime get settingsUpdated => _settingsUpdated;
}

// ─── Formatul mesajelor de sincronizare ───────────────────────────────────────
//   CLK:E:{angajat}   CLK:P:{pontaj}   CLK:B:[pontaje]
//   CLK:G:{e: angajat, m: AAAA-LL, d: "s1,s1,L,...", u: ms}  — graficul unei luni
//   CLK:H:{ture și/sau setări}        CLK:Z:  — sfârșitul sincronizării inițiale
// (CLK:L: / CLK:R: — licența — și semnătura CLK:S: sunt tratate nativ.)
class SyncCodec {
  static const prefix = 'CLK:';
  static const headerLength = 6; // „CLK:X:”
  static const end = 'CLK:Z:';

  static String? kindOf(String msg) =>
      msg.length >= headerLength && msg.startsWith(prefix) && msg[5] == ':'
          ? msg[4]
          : null;

  static String employee(Employee e) => 'CLK:E:${jsonEncode(e.toJson())}';
  static String punch(Punch p) => 'CLK:P:${jsonEncode(p.toJson())}';
  static String batch(List<Punch> ps) =>
      'CLK:B:${jsonEncode(ps.map((p) => p.toJson()).toList())}';
  static String schedule(String employeeId, String month, List<String> days, DateTime updatedAt) =>
      'CLK:G:${jsonEncode({'e': employeeId, 'm': month, 'd': days.join(','), 'u': updatedAt.millisecondsSinceEpoch})}';
  static String shifts(List<Shift> shifts, DateTime updatedAt) =>
      'CLK:H:${jsonEncode({'u': updatedAt.millisecondsSinceEpoch, 'l': shifts.map((s) => s.toJson()).toList()})}';
  static String settings(Store s) => 'CLK:H:${jsonEncode({
        'su': s.settingsUpdated.millisecondsSinceEpoch,
        'n': s.companyName,
        't': s.lateToleranceMinutes,
        'd': s.duplicateWindowMinutes,
      })}';
}
