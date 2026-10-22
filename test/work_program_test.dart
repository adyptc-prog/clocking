import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:clocking/src/models.dart';
import 'package:clocking/src/schedule_gen.dart';
import 'package:clocking/src/store.dart';

final _shifts = {for (final s in Shift.defaults()) s.id: s};
final _nov = DateTime(2026, 11);

WorkProgram _p(PatternKind kind,
        {Set<int> weekdays = const {1, 2, 3, 4, 5},
        String shiftId = 's1',
        List<String> shifts = const [],
        List<String> cycle = const [],
        DateTime? anchor,
        bool workHolidays = false,
        int dailyMinutes = 480}) =>
    WorkProgram(
      kind: kind,
      weekdays: weekdays,
      shiftId: shiftId,
      shifts: shifts,
      cycle: cycle,
      anchor: anchor ?? DateTime(2026, 11, 1),
      workHolidays: workHolidays,
      dailyMinutes: dailyMinutes,
      updatedAt: DateTime(2026),
    );

void main() {
  group('norma lunară', () {
    test('noiembrie 2026: 20 de zile lucrătoare (30 nov e sărbătoare) = 160h', () {
      expect(monthNormMinutes(_nov, 480), 160 * 60);
      expect(monthNormMinutes(DateTime(2026, 12), 480), 21 * 8 * 60);
      expect(monthNormMinutes(_nov, 240), 80 * 60); // timp parțial 4h
    });

    test('concediul din zilele lucrătoare scade norma', () {
      final exceptions = {
        for (var d = 2; d <= 8; d++) DateTime(2026, 11, d): DayCode.vacation, // 5 zile lucrătoare + weekend
      };
      expect(monthTargetMinutes(_nov, 480, exceptions), 120 * 60);
    });
  });

  group('generarea lunii după program', () {
    test('program fix L–V: acoperă exact norma, sărbătoarea e SL', () {
      final m = generateMonth(program: _p(PatternKind.fixed), month: _nov, exceptions: const {}, shifts: _shifts);
      expect(m.length, 30);
      expect(m[DateTime(2026, 11, 2)], 's1');
      expect(m[DateTime(2026, 11, 7)], DayCode.off);
      expect(m[DateTime(2026, 11, 30)], DayCode.holiday);
      expect(plannedMinutes(m.values, _shifts), monthNormMinutes(_nov, 480));
    });

    test('excepțiile nu se ating', () {
      final exceptions = {DateTime(2026, 11, 3): DayCode.medical, DateTime(2026, 11, 4): DayCode.off};
      final m = generateMonth(program: _p(PatternKind.fixed), month: _nov, exceptions: exceptions, shifts: _shifts);
      expect(m.containsKey(DateTime(2026, 11, 3)), isFalse);
      expect(m.containsKey(DateTime(2026, 11, 4)), isFalse);
      expect(m.length, 28);
    });

    test('normă automată cu ture de 12h: aproape de normă, cu zi liberă după fiecare tură', () {
      final m = generateMonth(
        program: _p(PatternKind.norm, shifts: ['s5'], weekdays: {1, 2, 3, 4, 5, 6, 7}),
        month: _nov,
        exceptions: const {},
        shifts: _shifts,
      );
      final work = (m.entries.where((e) => e.value == 's5').map((e) => e.key).toList()..sort());
      expect(work.length, 13); // 13 × 12h = 156h, cel mai aproape de 160h fără a o depăși cu >6h
      for (var i = 1; i < work.length; i++) {
        expect(work[i].difference(work[i - 1]).inHours, greaterThanOrEqualTo(47), reason: '${work[i]}');
      }
      expect((plannedMinutes(m.values, _shifts) - 160 * 60).abs(), lessThanOrEqualTo(6 * 60));
    });

    test('normă automată cu ture de 8h în L–V: exact norma', () {
      final m = generateMonth(program: _p(PatternKind.norm, shifts: ['s1']), month: _nov, exceptions: const {}, shifts: _shifts);
      expect(plannedMinutes(m.values, _shifts), 160 * 60);
    });

    test('normă automată: concediile scad turele, iar angajații decalați nu încep în aceeași zi', () {
      final exceptions = {for (var d = 9; d <= 13; d++) DateTime(2026, 11, d): DayCode.vacation};
      final program = _p(PatternKind.norm, shifts: ['s7'], weekdays: {1, 2, 3, 4, 5, 6, 7}, workHolidays: true);
      final a = generateMonth(program: program, month: _nov, exceptions: exceptions, shifts: _shifts, staggerIndex: 0, staggerCount: 2);
      final b = generateMonth(program: program, month: _nov, exceptions: exceptions, shifts: _shifts, staggerIndex: 1, staggerCount: 2);
      int hours(Map<DateTime, String> m) => plannedMinutes(m.values, _shifts) ~/ 60;
      expect(hours(a), 120); // 160h − 5 zile CO × 8h = 120h = 5 gărzi de 24h
      DateTime first(Map<DateTime, String> m) =>
          (m.entries.where((e) => e.value == 's7').map((e) => e.key).toList()..sort()).first;
      expect(first(a), isNot(first(b)));
    });

    test('ciclul continuă corect în luna următoare', () {
      final program = _p(PatternKind.cycle, cycle: const ['s5', 's6', DayCode.off, DayCode.off], workHolidays: true);
      final dec = generateMonth(program: program, month: DateTime(2026, 12), exceptions: const {}, shifts: _shifts);
      // 1 decembrie e la 30 de zile după 1 noiembrie: 30 % 4 = 2 → liber.
      expect(dec[DateTime(2026, 12, 1)], DayCode.off);
      expect(dec[DateTime(2026, 12, 3)], 's5');
      expect(dec[DateTime(2026, 12, 4)], 's6');
    });

    test('rotația săptămânală continuă de la o lună la alta', () {
      final program = _p(PatternKind.rotating, shifts: const ['s2', 's3'], anchor: DateTime(2026, 11, 2));
      expect(patternCode(program, DateTime(2026, 11, 2)), 's2');
      expect(patternCode(program, DateTime(2026, 11, 9)), 's3');
      expect(patternCode(program, DateTime(2026, 12, 7)), 's3'); // a 5-a săptămână după
      expect(patternCode(program, DateTime(2026, 10, 26)), 's3'); // și înainte de început
    });
  });

  test('programul se salvează și se citește înapoi', () {
    final p = _p(PatternKind.norm, shifts: ['s5', 's6'], weekdays: {1, 3, 5}, workHolidays: true, dailyMinutes: 360);
    final r = WorkProgram.fromJson(p.toJson());
    expect(r.kind, PatternKind.norm);
    expect(r.shifts, ['s5', 's6']);
    expect(r.weekdays, {1, 3, 5});
    expect(r.workHolidays, isTrue);
    expect(r.dailyMinutes, 360);
    expect(r.anchor, DateTime(2026, 11, 1));
  });

  group('program flexibil', () {
    test('fără ture: zilele rămân libere de grafic, doar sărbătorile sunt marcate', () {
      final m = generateMonth(program: _p(PatternKind.flexible), month: _nov, exceptions: const {}, shifts: _shifts);
      expect(m[DateTime(2026, 11, 2)], DayCode.none);
      expect(m[DateTime(2026, 11, 30)], DayCode.holiday);
      expect(plannedMinutes(m.values, _shifts), 0);
    });

    test('norma pe o perioadă scade concediile', () {
      String code(DateTime d) => d.day == 3 ? DayCode.vacation : '';
      expect(periodNormMinutes(DateTime(2026, 11, 2), DateTime(2026, 11, 8), 480, code), 4 * 480);
    });
  });

  group('în aplicație', () {
    test('ora de început și durata aleasă devin ture, refolosite la aceleași ore', () async {
      SharedPreferences.setMockInitialValues({});
      final s = Store.forTest();
      await s.load();
      final a = await s.ensureShift(9 * 60, 8 * 60);
      expect(s.shiftMap[a]!.hoursLabel, '09:00–17:00');
      expect(s.shiftMap[a]!.shortLabel, '9-17');
      expect(await s.ensureShift(9 * 60, 8 * 60), a);
      expect(await s.ensureShift(8 * 60, 8 * 60), 's1'); // „Normal” 08–16 există deja
      final night = await s.ensureShift(19 * 60, 12 * 60);
      expect(s.shiftMap[night]!.durationMinutes, 720);
      expect(s.shiftMap[night]!.crossesMidnight, isTrue);
    });

    TestWidgetsFlutterBinding.ensureInitialized();
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('generarea păstrează excepțiile și se sincronizează cu partenerul', () async {
      final out = <String>[];
      final s = Store.forTest();
      s.outgoing = (m) async => out.add(m);
      await s.load();
      final ana = await s.addEmployee(name: 'Ana');
      await s.setProgram(ana.id, _p(PatternKind.fixed));
      await s.setScheduleDays(ana.id, {DateTime(2026, 11, 3): DayCode.vacation});

      final summary = await s.generateMonthFor([ana], _nov);
      expect(s.scheduleCode(ana.id, DateTime(2026, 11, 3)), DayCode.vacation);
      expect(s.isException(ana.id, DateTime(2026, 11, 3)), isTrue);
      expect(s.scheduleCode(ana.id, DateTime(2026, 11, 2)), 's1');
      expect(s.isException(ana.id, DateTime(2026, 11, 2)), isFalse);
      expect(summary[ana.id], (target: 152 * 60, planned: 152 * 60));

      // A doua generare (după schimbarea programului) nu atinge concediul.
      await s.setProgram(ana.id, _p(PatternKind.fixed, shiftId: 's2'));
      await s.generateMonthFor([ana], _nov);
      expect(s.scheduleCode(ana.id, DateTime(2026, 11, 3)), DayCode.vacation);
      expect(s.scheduleCode(ana.id, DateTime(2026, 11, 2)), 's2');

      // Telefonul partener primește programul și graficul.
      SharedPreferences.setMockInitialValues({});
      final b = Store.forTest();
      await b.load();
      for (final m in out) {
        await b.applyRemote(m);
      }
      expect(b.programOf(ana.id)?.shiftId, 's2');
      await b.ensureSchedules(_nov, DateTime(2026, 11, 30));
      expect(b.scheduleCode(ana.id, DateTime(2026, 11, 2)), 's2');
      expect(b.isException(ana.id, DateTime(2026, 11, 3)), isTrue);
    });
  });
}
