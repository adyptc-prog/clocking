import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:clocking/src/models.dart';
import 'package:clocking/src/store.dart';

// Două telefoane simulate: ce trimite unul se aplică pe celălalt.
Future<Store> _phone(List<String> outbox) async {
  final s = Store.forTest();
  s.outgoing = (m) async => outbox.add(m);
  await s.load();
  return s;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('prima pornire: turele implicite, fără angajați', () async {
    final s = await _phone([]);
    expect(s.employees, isEmpty);
    expect(s.shifts.map((x) => x.id), containsAll(['s1', 's5', 's6', 's7']));
  });

  test('angajat nou: salvat, cu cod QR, trimis partenerului', () async {
    final out = <String>[];
    final s = await _phone(out);
    final e = await s.addEmployee(name: '  Ion Popescu ', role: 'Asistent');
    expect(e.name, 'Ion Popescu');
    expect(e.qrSecret.length, 8);
    expect(out.single, startsWith('CLK:E:'));

    final again = await _phone([]);
    expect(again.employees.single.name, 'Ion Popescu');
  });

  test('regenerarea codului QR îl schimbă', () async {
    final s = await _phone([]);
    final e = await s.addEmployee(name: 'Ana');
    final r = await s.regenerateQr(e);
    expect(r.qrSecret, isNot(e.qrSecret));
    expect(s.employeeById(e.id)!.qrPayload, r.qrPayload);
  });

  test('ștergerea ascunde angajatul, dar păstrează marcajul pentru sincronizare', () async {
    final s = await _phone([]);
    final e = await s.addEmployee(name: 'Ana');
    await s.deleteEmployee(e);
    expect(s.employees, isEmpty);
    expect(s.employeeById(e.id), isNull);
    expect(s.allEmployeeRecords.single.deleted, isTrue);
  });

  test('pontaje pe luni; corectura care schimbă luna mută pontajul', () async {
    final s = await _phone([]);
    final p = await s.addPunch(employeeId: 'e1', at: DateTime(2026, 10, 31, 22), type: PunchType.clockIn);
    expect((await s.punchesBetween(DateTime(2026, 10, 31), DateTime(2026, 10, 31))).length, 1);
    await s.updatePunch(p.copyWith(at: DateTime(2026, 11, 1, 6)));
    expect(await s.punchesBetween(DateTime(2026, 10, 1), DateTime(2026, 10, 31)), isEmpty);
    expect((await s.punchesBetween(DateTime(2026, 11, 1), DateTime(2026, 11, 1))).single.id, p.id);

    final prefs = await SharedPreferences.getInstance();
    expect(jsonDecode(prefs.getString('punches_2026-10')!), isEmpty);
  });

  test('ultimul pontaj, și din luna trecută', () async {
    final s = await _phone([]);
    await s.addPunch(employeeId: 'e1', at: DateTime(2026, 10, 31, 19), type: PunchType.clockIn);
    final last = await s.lastPunch('e1', DateTime(2026, 11, 1, 7));
    expect(last?.at, DateTime(2026, 10, 31, 19));
  });

  test('graficul: zile scrise pe lună, citite înapoi', () async {
    final out = <String>[];
    final s = await _phone(out);
    await s.setScheduleDays('e1', {
      DateTime(2026, 11, 30): 's1',
      DateTime(2026, 12, 1): DayCode.holiday,
    });
    expect(out.where((m) => m.startsWith('CLK:G:')).length, 2); // două luni
    await s.ensureSchedules(DateTime(2026, 11, 1), DateTime(2026, 12, 31));
    expect(s.scheduleCode('e1', DateTime(2026, 11, 30)), 's1');
    expect(s.scheduleCode('e1', DateTime(2026, 11, 29)), DayCode.none);
    expect(s.scheduleCode('e1', DateTime(2026, 12, 1)), DayCode.holiday);
    expect(s.scheduledShift('e1', DateTime(2026, 11, 30))?.id, 's1');
  });

  group('sincronizare', () {
    test('tot ce face un telefon ajunge pe celălalt', () async {
      final outA = <String>[];
      final a = await _phone(outA);
      final e = await a.addEmployee(name: 'Maria');
      await a.addPunch(employeeId: e.id, at: DateTime(2026, 11, 3, 8), type: PunchType.clockIn);
      await a.setScheduleDays(e.id, {DateTime(2026, 11, 3): 's1'});
      final shifts = List.of(a.shifts)..add(Shift(id: a.nextShiftId(), name: 'Seară', start: 1080, end: 1320));
      await a.saveShifts(shifts);
      await a.saveSettings(companyName: 'Cabinet Dr. Ionescu', lateToleranceMinutes: 10, duplicateWindowMinutes: 5);

      // Al doilea telefon are propriile preferințe.
      SharedPreferences.setMockInitialValues({});
      final b = await _phone([]);
      for (final m in outA) {
        expect(await b.applyRemote(m), isTrue, reason: m);
      }
      expect(b.employees.single.name, 'Maria');
      expect(b.employees.single.qrPayload, e.qrPayload);
      expect((await b.punchesBetween(DateTime(2026, 11, 3), DateTime(2026, 11, 3))).length, 1);
      await b.ensureSchedules(DateTime(2026, 11, 1), DateTime(2026, 11, 30));
      expect(b.scheduleCode(e.id, DateTime(2026, 11, 3)), 's1');
      expect(b.shifts.last.name, 'Seară');
      expect(b.companyName, 'Cabinet Dr. Ionescu');
      expect(b.lateToleranceMinutes, 10);

      // Același mesaj primit de două ori nu schimbă nimic.
      for (final m in outA) {
        expect(await b.applyRemote(m), isFalse, reason: m);
      }
    });

    test('versiunea mai veche nu suprascrie una mai nouă', () async {
      final outA = <String>[];
      final a = await _phone(outA);
      final e = await a.addEmployee(name: 'Vechi');
      final oldMsg = outA.last;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await a.updateEmployee(e.copyWith(name: 'Nou'));
      final newMsg = outA.last;

      SharedPreferences.setMockInitialValues({});
      final b = await _phone([]);
      await b.applyRemote(newMsg);
      expect(await b.applyRemote(oldMsg), isFalse);
      expect(b.employees.single.name, 'Nou');
    });

    test('ștergerea unui pontaj se propagă', () async {
      final outA = <String>[];
      final a = await _phone(outA);
      final p = await a.addPunch(employeeId: 'e1', at: DateTime(2026, 11, 3, 8), type: PunchType.clockIn);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await a.deletePunch(p);

      SharedPreferences.setMockInitialValues({});
      final b = await _phone([]);
      for (final m in outA) {
        await b.applyRemote(m);
      }
      expect(await b.punchesBetween(DateTime(2026, 11, 3), DateTime(2026, 11, 3)), isEmpty);
    });

    test('sincronizarea inițială: setări, ture, angajați, grafic, pontaje în loturi', () async {
      final a = await _phone([]);
      final e = await a.addEmployee(name: 'Maria');
      final now = DateTime.now();
      for (var i = 0; i < 8; i++) {
        await a.addPunch(employeeId: e.id, at: DateTime(now.year, now.month, 1, 8 + i), type: PunchType.clockIn);
      }
      await a.setScheduleDays(e.id, {DateTime(now.year, now.month, 1): 's1'});
      final msgs = await a.initialSyncMessages(now);
      expect(msgs.first, startsWith('CLK:H:'));
      expect(msgs.where((m) => m.startsWith('CLK:E:')).length, 1);
      expect(msgs.where((m) => m.startsWith('CLK:G:')).length, 1);
      expect(msgs.where((m) => m.startsWith('CLK:B:')).length, 2); // 6 + 2
      expect(msgs.last, SyncCodec.end);

      SharedPreferences.setMockInitialValues({});
      final b = await _phone([]);
      for (final m in msgs) {
        await b.applyRemote(m);
      }
      expect((await b.punchesBetween(DateTime(now.year, now.month, 1), DateTime(now.year, now.month, 1))).length, 8);
    });

    test('mesajele corupte sau necunoscute sunt ignorate', () async {
      final b = await _phone([]);
      for (final m in ['CLK:E:{nu e json', 'CLK:Q:{}', 'PEN:A:{}', 'CLK:', '']) {
        expect(await b.applyRemote(m), isFalse, reason: m);
      }
    });
  });

  test('PIN-ul managerului: salvat ca hash, verificat, eliminat', () async {
    final s = await _phone([]);
    expect(s.hasPin, isFalse);
    await s.setPin('1234');
    expect(s.checkPin('1234'), isTrue);
    expect(s.checkPin('0000'), isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('manager_pin'), isNot(contains('1234')));
    await s.setPin(null);
    expect(s.hasPin, isFalse);
  });
}
