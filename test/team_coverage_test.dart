import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:clocking/src/models.dart';
import 'package:clocking/src/schedule_gen.dart';
import 'package:clocking/src/store.dart';

// Cabinet: tura de la 8 și tura de la 11, câte 8 ore.
const _at8 = Shift(id: 'a8', name: '08-16', start: 8 * 60, end: 16 * 60);
const _at11 = Shift(id: 'a11', name: '11-19', start: 11 * 60, end: 19 * 60);
final _shifts = {
  for (final s in [...Shift.defaults(), _at8, _at11]) s.id: s,
};
final _nov = DateTime(2026, 11);
final _days = [for (var d = 1; d <= 30; d++) DateTime(2026, 11, d)];

WorkProgram _team(List<String> shifts, List<int> min,
        {int restTo = -1, Set<int> weekdays = const {1, 2, 3, 4, 5}, bool workHolidays = false}) =>
    WorkProgram(
      kind: PatternKind.rotating,
      weekdays: weekdays,
      shifts: shifts,
      anchor: DateTime(2026, 11, 1),
      workHolidays: workHolidays,
      team: 'T1',
      minStaff: min,
      restTo: restTo,
      updatedAt: DateTime(2026),
    );

TeamMonth _run(WorkProgram rule, List<String> members, {Map<String, Map<DateTime, String>> exceptions = const {}}) =>
    generateTeamMonth(
      rule: rule,
      members: members,
      month: _nov,
      exceptions: {for (final m in members) m: exceptions[m] ?? const {}},
      dailyMinutes: {for (final m in members) m: 480},
      shifts: _shifts,
    );

int _count(TeamMonth t, DateTime d, String shift) => t.days.values.where((m) => m[d] == shift).length;

int _hours(TeamMonth t, String m) => plannedMinutes(t.days[m]!.values, _shifts) ~/ 60;

void main() {
  group('cabinet: minim la 8, restul la 11', () {
    final nurses = ['n1', 'n2', 'n3', 'n4'];

    test('în fiecare zi lucrătoare e exact minimul la 8, ceilalți la 11, prin rotație', () {
      final t = _run(_team(['a8', 'a11'], [1, 0], restTo: 1), nurses);
      expect(t.gaps, isEmpty);
      for (final d in _days) {
        final working = d.weekday <= 5 && d.day != 30; // 30 nov e sărbătoare
        expect(_count(t, d, 'a8'), working ? 1 : 0, reason: '$d');
        expect(_count(t, d, 'a11'), working ? 3 : 0, reason: '$d');
      }
      // Fiecare asistentă își face norma (20 de zile × 8h) și prinde tura de la 8 de 5 ori.
      for (final n in nurses) {
        expect(_hours(t, n), 160);
        expect(t.days[n]!.values.where((c) => c == 'a8').length, 5);
      }
      expect(t.days['n1']![DateTime(2026, 11, 30)], DayCode.holiday);
      expect(t.days['n1']![DateTime(2026, 11, 7)], DayCode.off);
    });

    test('minim 2 la 8; concediul unei asistente nu lasă tura de la 8 descoperită', () {
      final leave = {for (var d = 9; d <= 13; d++) DateTime(2026, 11, d): DayCode.vacation};
      final t = _run(_team(['a8', 'a11'], [2, 0], restTo: 1), nurses, exceptions: {'n2': leave});
      expect(t.gaps, isEmpty);
      for (var d = 9; d <= 13; d++) {
        expect(_count(t, DateTime(2026, 11, d), 'a8'), 2);
        expect(_count(t, DateTime(2026, 11, d), 'a11'), 1);
        expect(t.days['n2']!.containsKey(DateTime(2026, 11, d)), isFalse); // concediul rămâne
      }
      expect(_hours(t, 'n2'), 120);
    });
  });

  group('hotel: 4 recepționeri, zi și noapte de 12h, cel puțin unul pe fiecare tură', () {
    final reception = ['r1', 'r2', 'r3', 'r4'];
    final rule = _team(['s5', 's6'], [1, 1], weekdays: {1, 2, 3, 4, 5, 6, 7}, workHolidays: true);

    void checkRest(TeamMonth t, String m) {
      final work = _days.where((d) => DayCode.isShift(t.days[m]![d] ?? '')).toList();
      for (var i = 1; i < work.length; i++) {
        final a = _shifts[t.days[m]![work[i - 1]]]!;
        final b = _shifts[t.days[m]![work[i]]]!;
        final end = DateTime(work[i - 1].year, 11, work[i - 1].day, 0, a.start).add(Duration(minutes: a.durationMinutes));
        final start = DateTime(2026, 11, work[i].day, 0, b.start);
        expect(start.difference(end).inHours, greaterThanOrEqualTo(24), reason: '$m ${work[i]}');
      }
    }

    test('fiecare zi și noapte acoperite, cu 24h libere după fiecare tură', () {
      final t = _run(rule, reception);
      expect(t.gaps, isEmpty);
      for (final d in _days) {
        expect(_count(t, d, 's5'), greaterThanOrEqualTo(1), reason: '$d');
        expect(_count(t, d, 's6'), greaterThanOrEqualTo(1), reason: '$d');
      }
      for (final r in reception) {
        checkRest(t, r);
        // 60 de ture pe lună împărțite egal: 15 × 12h.
        expect(_hours(t, r), inInclusiveRange(168, 192), reason: r);
      }
    });

    test('cu un recepționer în concediu o săptămână, ceilalți trei tot acoperă turele', () {
      final leave = {for (var d = 9; d <= 15; d++) DateTime(2026, 11, d): DayCode.vacation};
      final t = _run(rule, reception, exceptions: {'r3': leave});
      expect(t.gaps, isEmpty);
      for (final d in _days) {
        expect(_count(t, d, 's5'), 1, reason: '$d');
        expect(_count(t, d, 's6'), 1, reason: '$d');
      }
      for (final r in reception) {
        checkRest(t, r);
      }
      // Cel cu concediu lucrează mai puțin; diferența la ceilalți e la zilele libere.
      expect(_hours(t, 'r3'), lessThan(_hours(t, 'r1')));
    });

    test('doi recepționeri nu pot acoperi zi și noapte: zilele lipsă sunt raportate', () {
      final t = _run(rule, ['r1', 'r2']);
      expect(t.gaps, isNotEmpty);
      expect(t.gaps.every((g) => g.missing == 1), isTrue);
    });

    test('6 recepționeri: peste minim lucrează doar cât să-și facă norma', () {
      final six = [...reception, 'r5', 'r6'];
      final t = _run(rule, six);
      expect(t.gaps, isEmpty);
      for (final r in six) {
        expect(_hours(t, r), inInclusiveRange(144, 168), reason: r); // norma = 160h
      }
    });
  });

  test('condiția se salvează și se citește înapoi', () {
    final p = _team(['s5', 's6'], [1, 2], restTo: 1);
    final r = WorkProgram.fromJson(p.toJson());
    expect(r.isTeam, isTrue);
    expect(r.team, 'T1');
    expect(r.minStaff, [1, 2]);
    expect(r.restTo, 1);
    final plain = WorkProgram.fromJson(p.copyWith(team: '').toJson());
    expect(plain.isTeam, isFalse);
  });

  test('în aplicație: echipa se generează împreună și păstrează excepțiile', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    final s = Store.forTest();
    await s.load();
    final a = await s.addEmployee(name: 'Ana');
    final b = await s.addEmployee(name: 'Bia');
    final rule = _team(['s1', 's2'], [1, 0], restTo: 1);
    await s.setProgram(a.id, rule);
    await s.setProgram(b.id, rule);
    await s.setScheduleDays(a.id, {DateTime(2026, 11, 3): DayCode.medical});
    expect(s.teamOf('T1').length, 2);

    await s.generateMonthFor([a, b], _nov);
    expect(s.lastCoverageGaps, isEmpty);
    expect(s.scheduleCode(a.id, DateTime(2026, 11, 3)), DayCode.medical);
    expect(s.scheduleCode(b.id, DateTime(2026, 11, 3)), 's1'); // Bia singură: ia minimul
    for (var d = 2; d <= 6; d++) {
      final codes = {s.scheduleCode(a.id, DateTime(2026, 11, d)), s.scheduleCode(b.id, DateTime(2026, 11, d))};
      expect(codes.contains('s1'), isTrue, reason: '$d');
    }
  });
}
