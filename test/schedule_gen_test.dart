import 'package:flutter_test/flutter_test.dart';

import 'package:clocking/src/models.dart';
import 'package:clocking/src/schedule_gen.dart';

void main() {
  group('program fix', () {
    test('luni–vineri tura aleasă, weekend liber', () {
      final r = generateSchedule(ScheduleRequest(
        kind: PatternKind.fixed,
        from: DateTime(2026, 11, 2), // luni
        to: DateTime(2026, 11, 8),
        shiftId: 's1',
      ));
      expect(r.length, 7);
      expect(r[DateTime(2026, 11, 2)], 's1');
      expect(r[DateTime(2026, 11, 6)], 's1');
      expect(r[DateTime(2026, 11, 7)], DayCode.off);
      expect(r[DateTime(2026, 11, 8)], DayCode.off);
    });

    test('zile lucrătoare alese (inclusiv sâmbătă)', () {
      final r = generateSchedule(ScheduleRequest(
        kind: PatternKind.fixed,
        from: DateTime(2026, 11, 2),
        to: DateTime(2026, 11, 8),
        shiftId: 's1',
        weekdays: {2, 4, 6},
      ));
      expect([for (var d = 2; d <= 8; d++) r[DateTime(2026, 11, d)]],
          ['L', 's1', 'L', 's1', 'L', 's1', 'L']);
    });

    test('interval invers: nimic generat', () {
      expect(
          generateSchedule(ScheduleRequest(
              kind: PatternKind.fixed, from: DateTime(2026, 11, 8), to: DateTime(2026, 11, 2), shiftId: 's1')),
          isEmpty);
    });
  });

  group('ture rotative', () {
    test('săptămânal: schimbarea cade lunea, chiar dacă intervalul începe miercuri', () {
      final r = generateSchedule(ScheduleRequest(
        kind: PatternKind.rotating,
        from: DateTime(2026, 11, 4), // miercuri
        to: DateTime(2026, 11, 13),
        rotationShifts: ['s2', 's3'],
        rotateEveryDays: 7,
      ));
      expect(r[DateTime(2026, 11, 4)], 's2');
      expect(r[DateTime(2026, 11, 6)], 's2'); // vineri
      expect(r[DateTime(2026, 11, 7)], DayCode.off); // sâmbătă
      expect(r[DateTime(2026, 11, 9)], 's3'); // luni — săptămână nouă
      expect(r[DateTime(2026, 11, 13)], 's3');
    });

    test('3 ture, decalaj: al doilea angajat începe cu tura următoare', () {
      ScheduleRequest req(int offset) => ScheduleRequest(
            kind: PatternKind.rotating,
            from: DateTime(2026, 11, 2),
            to: DateTime(2026, 11, 22),
            rotationShifts: ['s2', 's3', 's4'],
            startOffset: offset,
          );
      final a = generateSchedule(req(0));
      final b = generateSchedule(req(1));
      expect([a[DateTime(2026, 11, 2)], a[DateTime(2026, 11, 9)], a[DateTime(2026, 11, 16)]], ['s2', 's3', 's4']);
      expect([b[DateTime(2026, 11, 2)], b[DateTime(2026, 11, 9)], b[DateTime(2026, 11, 16)]], ['s3', 's4', 's2']);
    });

    test('rotație la 2 zile', () {
      final r = generateSchedule(ScheduleRequest(
        kind: PatternKind.rotating,
        from: DateTime(2026, 11, 2),
        to: DateTime(2026, 11, 5),
        rotationShifts: ['s2', 's3'],
        rotateEveryDays: 2,
      ));
      expect([for (var d = 2; d <= 5; d++) r[DateTime(2026, 11, d)]], ['s2', 's2', 's3', 's3']);
    });
  });

  group('cicluri continue', () {
    test('12/24: zi, noapte, liber — inclusiv în weekend', () {
      final r = generateSchedule(ScheduleRequest(
        kind: PatternKind.cycle,
        from: DateTime(2026, 11, 1),
        to: DateTime(2026, 11, 7),
        cycle: CyclePreset.presets.firstWhere((p) => p.name == '12/24').cycle,
      ));
      expect([for (var d = 1; d <= 7; d++) r[DateTime(2026, 11, d)]], ['s5', 's6', 'L', 's5', 's6', 'L', 's5']);
    });

    test('24/72 cu decalaj de o zi', () {
      final r = generateSchedule(ScheduleRequest(
        kind: PatternKind.cycle,
        from: DateTime(2026, 11, 1),
        to: DateTime(2026, 11, 5),
        cycle: CyclePreset.presets.firstWhere((p) => p.name == '24/72').cycle,
        startOffset: 1,
      ));
      expect([for (var d = 1; d <= 5; d++) r[DateTime(2026, 11, d)]], ['L', 'L', 'L', 's7', 'L']);
    });

    test('trecerea la ora de iarnă nu strică ciclul', () {
      // 25 octombrie 2026: ora de iarnă în România.
      final r = generateSchedule(ScheduleRequest(
        kind: PatternKind.cycle,
        from: DateTime(2026, 10, 23),
        to: DateTime(2026, 10, 28),
        cycle: const ['s5', 's6', 'L'],
      ));
      expect(r.length, 6);
      expect([for (var d = 23; d <= 28; d++) r[DateTime(2026, 10, d)]], ['s5', 's6', 'L', 's5', 's6', 'L']);
    });
  });

  group('zile libere, concedii, sărbători', () {
    test('concediul are prioritate față de tură și sărbătoare', () {
      final r = generateSchedule(ScheduleRequest(
        kind: PatternKind.fixed,
        from: DateTime(2026, 11, 23),
        to: DateTime(2026, 12, 4),
        shiftId: 's1',
        legalHolidays: true,
        leaves: [LeaveRange(DateTime(2026, 11, 30), DateTime(2026, 12, 2), DayCode.vacation)],
        extraDaysOff: {DateTime(2026, 11, 27)},
      ));
      expect(r[DateTime(2026, 11, 27)], DayCode.off);
      expect(r[DateTime(2026, 11, 30)], DayCode.vacation); // Sf. Andrei, dar în concediu
      expect(r[DateTime(2026, 12, 1)], DayCode.vacation);
      expect(r[DateTime(2026, 12, 2)], DayCode.vacation);
      expect(r[DateTime(2026, 12, 3)], 's1');
    });

    test('sărbătorile legale apar ca SL', () {
      final r = generateSchedule(ScheduleRequest(
        kind: PatternKind.fixed,
        from: DateTime(2026, 12, 24),
        to: DateTime(2026, 12, 28),
        shiftId: 's1',
        weekdays: {1, 2, 3, 4, 5, 6, 7},
        legalHolidays: true,
      ));
      expect(r[DateTime(2026, 12, 24)], 's1');
      expect(r[DateTime(2026, 12, 25)], DayCode.holiday);
      expect(r[DateTime(2026, 12, 26)], DayCode.holiday);
      expect(r[DateTime(2026, 12, 27)], 's1');
    });

    test('Paștele ortodox', () {
      expect(orthodoxEaster(2025), DateTime(2025, 4, 20));
      expect(orthodoxEaster(2026), DateTime(2026, 4, 12));
      expect(orthodoxEaster(2027), DateTime(2027, 5, 2));
    });

    test('sărbătorile mobile din 2026', () {
      final h = romanianHolidays(2026);
      expect(h, contains(DateTime(2026, 4, 10))); // Vinerea Mare
      expect(h, contains(DateTime(2026, 4, 13))); // a doua zi de Paște
      expect(h, contains(DateTime(2026, 5, 31))); // Rusalii
      expect(h, contains(DateTime(2026, 6, 1)));
      // A doua zi de Rusalii cade pe 1 iunie (Ziua Copilului) — o singură zi.
      expect(h.length, 16);
    });
  });
}
