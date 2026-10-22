import 'package:flutter_test/flutter_test.dart';

import 'package:clocking/src/models.dart';
import 'package:clocking/src/report.dart';
import 'package:clocking/src/scan_logic.dart';

Punch _p(String emp, DateTime at, PunchType t, {String source = PunchSource.scan, bool deleted = false}) => Punch(
      id: '${emp}_${at.millisecondsSinceEpoch}_${t.name}',
      employeeId: emp,
      at: at,
      type: t,
      source: source,
      updatedAt: at,
      deleted: deleted,
    );

final _emp = Employee(
  id: 'e1',
  name: 'Ana Pop',
  qrSecret: 'ABCDEFGH',
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 1, 1),
);

const _day = Shift(id: 's1', name: 'Normal', start: 8 * 60, end: 16 * 60);
const _night = Shift(id: 's6', name: 'Noapte 12h', start: 19 * 60, end: 7 * 60);
const _guard = Shift(id: 's7', name: 'Gardă 24h', start: 8 * 60, end: 8 * 60);
final _shifts = {for (final s in [_day, _night, _guard]) s.id: s};

const _in = PunchType.clockIn;
const _out = PunchType.clockOut;

void main() {
  group('codul QR', () {
    test('conținutul codului se citește înapoi', () {
      final q = parseQr(_emp.qrPayload);
      expect(q?.id, 'e1');
      expect(q?.secret, 'ABCDEFGH');
    });

    test('codurile străine sunt respinse', () {
      for (final raw in ['', 'https://example.com', 'CLK1:e1', 'CLK2:e1:X', 'CLK1::X', 'CLK1:e1:']) {
        expect(parseQr(raw), isNull, reason: raw);
      }
    });
  });

  group('scanarea', () {
    final now = DateTime(2026, 11, 3, 16, 5);
    ScanOutcome decide(Punch? last, {Shift? shift}) => decideScan(
          last: last,
          now: now,
          duplicateWindow: const Duration(minutes: 2),
          maxOpen: maxOpenDuration(shift),
        );

    test('primul pontaj e intrare', () => expect(decide(null), ScanOutcome.clockIn));

    test('după intrare urmează ieșirea', () {
      expect(decide(_p('e1', DateTime(2026, 11, 3, 8), _in)), ScanOutcome.clockOut);
    });

    test('după ieșire urmează intrarea', () {
      expect(decide(_p('e1', DateTime(2026, 11, 3, 12), _out)), ScanOutcome.clockIn);
    });

    test('scanarea dublă în 2 minute e ignorată', () {
      expect(decide(_p('e1', DateTime(2026, 11, 3, 16, 4), _in)), ScanOutcome.duplicate);
      expect(decide(_p('e1', DateTime(2026, 11, 3, 16, 4), _out)), ScanOutcome.duplicate);
    });

    test('intrarea de ieri fără ieșire (uitată) — azi e o intrare nouă', () {
      final yesterday = _p('e1', DateTime(2026, 11, 2, 8), _in);
      expect(decide(yesterday), ScanOutcome.clockIn);
    });

    test('garda de 24h se închide a doua zi cu ieșire', () {
      final start = _p('e1', DateTime(2026, 11, 2, 8), _in);
      final next = DateTime(2026, 11, 3, 8, 10);
      ScanOutcome at(Shift? shift) => decideScan(
            last: start,
            now: next,
            duplicateWindow: const Duration(minutes: 2),
            maxOpen: maxOpenDuration(shift),
          );
      expect(at(_guard), ScanOutcome.clockOut);
      // Fără gardă în grafic, 24 de ore fără ieșire = ieșire uitată.
      expect(at(null), ScanOutcome.clockIn);
    });
  });

  group('raportul', () {
    EmployeeReport report(List<Punch> punches, Map<DateTime, String> schedule,
            {DateTime? from, DateTime? to, DateTime? now}) =>
        buildEmployeeReport(
          employee: _emp,
          punches: punches,
          scheduleCode: (d) => schedule[d] ?? '',
          shifts: _shifts,
          from: from ?? DateTime(2026, 11, 2),
          to: to ?? DateTime(2026, 11, 6),
          toleranceMinutes: 5,
          now: now ?? DateTime(2026, 11, 10),
        );

    test('ore lucrate, întârziere, plecare devreme, absență', () {
      final schedule = {for (var d = 2; d <= 6; d++) DateTime(2026, 11, d): 's1'};
      final r = report([
        _p('e1', DateTime(2026, 11, 2, 8, 0), _in),
        _p('e1', DateTime(2026, 11, 2, 16, 0), _out),
        // întârziere 20 min, plecat cu 30 min mai devreme
        _p('e1', DateTime(2026, 11, 3, 8, 20), _in),
        _p('e1', DateTime(2026, 11, 3, 15, 30), _out),
        // în toleranță (3 min)
        _p('e1', DateTime(2026, 11, 4, 8, 3), _in),
        _p('e1', DateTime(2026, 11, 4, 17, 0), _out),
        // 5 nov: absent; 6 nov: pauză de prânz
        _p('e1', DateTime(2026, 11, 6, 8, 0), _in),
        _p('e1', DateTime(2026, 11, 6, 12, 0), _out),
        _p('e1', DateTime(2026, 11, 6, 12, 30), _in),
        _p('e1', DateTime(2026, 11, 6, 16, 30), _out),
      ], schedule);

      final d3 = r.rows[1];
      expect(d3.lateMinutes, 20);
      expect(d3.earlyMinutes, 30);
      expect(r.rows[2].lateMinutes, 0);
      expect(r.rows[2].overtimeMinutes, 57); // 8:03–17:00 = 8h57
      expect(r.rows[3].status, DayStatus.absent);
      expect(r.rows[4].worked, const Duration(hours: 8));
      expect(r.rows[4].sessions.length, 2);

      expect(r.daysPresent, 4);
      expect(r.absences, 1);
      expect(r.lateCount, 1);
      expect(r.scheduledMinutes, 5 * 8 * 60);
      expect(r.workedMinutes, 8 * 60 + 7 * 60 + 10 + 8 * 60 + 57 + 8 * 60);
    });

    test('tura de noapte se raportează la ziua intrării', () {
      final r = report([
        _p('e1', DateTime(2026, 11, 2, 19, 0), _in),
        _p('e1', DateTime(2026, 11, 3, 7, 0), _out),
      ], {DateTime(2026, 11, 2): 's6', DateTime(2026, 11, 3): 'L'});
      expect(r.rows[0].worked, const Duration(hours: 12));
      expect(r.rows[0].overtimeMinutes, 0);
      expect(r.rows[1].status, DayStatus.off);
      expect(r.rows[1].worked, Duration.zero);
    });

    test('ieșire uitată = pontaj incomplet; tura de azi = în desfășurare', () {
      final r = report([
        _p('e1', DateTime(2026, 11, 2, 8, 0), _in),
        _p('e1', DateTime(2026, 11, 3, 8, 0), _in),
      ], const {}, now: DateTime(2026, 11, 3, 10));
      expect(r.rows[0].incomplete, isTrue);
      expect(r.rows[1].incomplete, isFalse);
      expect(r.rows[1].sessions.single.ongoing, isTrue);
      expect(r.incompleteCount, 1);
    });

    test('pontajele șterse nu contează, cele corectate sunt marcate', () {
      final r = report([
        _p('e1', DateTime(2026, 11, 2, 8, 0), _in, source: PunchSource.manual),
        _p('e1', DateTime(2026, 11, 2, 9, 0), _out, deleted: true),
        _p('e1', DateTime(2026, 11, 2, 16, 0), _out),
      ], const {});
      expect(r.rows[0].worked, const Duration(hours: 8));
      expect(r.rows[0].edited, isTrue);
    });

    test('concediile se numără pe tip; lucrul în zi liberă e peste program', () {
      final r = report([
        _p('e1', DateTime(2026, 11, 6, 9, 0), _in),
        _p('e1', DateTime(2026, 11, 6, 11, 0), _out),
      ], {
        DateTime(2026, 11, 2): DayCode.vacation,
        DateTime(2026, 11, 3): DayCode.vacation,
        DateTime(2026, 11, 4): DayCode.medical,
        DateTime(2026, 11, 6): DayCode.off,
      });
      expect(r.leaveDays, {DayCode.vacation: 2, DayCode.medical: 1});
      expect(r.rows[4].overtimeMinutes, 120);
      expect(r.absences, 0);
    });
  });

  test('program flexibil: orele din pontaj față de normă, fără întârzieri', () {
    final r = buildEmployeeReport(
      employee: _emp,
      punches: [
        _p('e1', DateTime(2026, 11, 2, 10, 0), _in),
        _p('e1', DateTime(2026, 11, 2, 20, 0), _out),
        _p('e1', DateTime(2026, 11, 3, 7, 0), _in),
        _p('e1', DateTime(2026, 11, 3, 13, 0), _out),
      ],
      scheduleCode: (_) => '',
      shifts: _shifts,
      from: DateTime(2026, 11, 2),
      to: DateTime(2026, 11, 3),
      toleranceMinutes: 5,
      now: DateTime(2026, 12, 1),
      flexibleDailyMinutes: 480,
    );
    expect(r.flexible, isTrue);
    expect(r.normMinutes, 16 * 60);
    expect(r.workedMinutes, 16 * 60);
    expect(r.normDiffMinutes, 0);
    expect(r.lateCount, 0);
    expect(r.absences, 0);
  });

  group('ture', () {
    test('durata turelor care trec de miezul nopții', () {
      expect(_day.durationMinutes, 480);
      expect(_night.durationMinutes, 720);
      expect(_guard.durationMinutes, 1440);
      expect(_night.crossesMidnight, isTrue);
    });

    test('etichete scurte', () {
      expect(_day.shortLabel, 'NO');
      expect(_night.shortLabel, 'N12');
      expect(const Shift(id: 'x', name: 'Tura 2', start: 0, end: 1).shortLabel, 'T2');
    });
  });
}
