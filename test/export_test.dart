import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:clocking/src/export.dart';
import 'package:clocking/src/models.dart';
import 'package:clocking/src/report.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('clocking_export');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tmp.path,
    );
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  final emp = Employee(
    id: 'e1',
    name: 'Ștefan Țăranu',
    role: 'Asistent',
    qrSecret: 'ABCDEFGH',
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
  );
  final shifts = {for (final s in Shift.defaults()) s.id: s};

  EmployeeReport report() => buildEmployeeReport(
        employee: emp,
        punches: [
          Punch(id: 'a', employeeId: 'e1', at: DateTime(2026, 11, 2, 8, 10), type: PunchType.clockIn, updatedAt: DateTime(2026)),
          Punch(id: 'b', employeeId: 'e1', at: DateTime(2026, 11, 2, 16), type: PunchType.clockOut, updatedAt: DateTime(2026)),
        ],
        scheduleCode: (d) => d.day == 2 ? 's1' : (d.day == 3 ? DayCode.vacation : ''),
        shifts: shifts,
        from: DateTime(2026, 11, 1),
        to: DateTime(2026, 11, 30),
        toleranceMinutes: 5,
        now: DateTime(2026, 12, 1),
      );

  test('raportul PDF se generează cu diacritice', () async {
    final f = await reportPdf([report()], from: DateTime(2026, 11, 1), to: DateTime(2026, 11, 30), company: 'Cabinet Ișalnița');
    expect(f.existsSync(), isTrue);
    expect(f.path, endsWith('pontaj_Stefan_Taranu_20261101_20261130.pdf'));
    expect(utf8.decode(f.readAsBytesSync().sublist(0, 5), allowMalformed: true), '%PDF-');
  });

  test('raportul CSV: BOM, separator „;”, totaluri', () async {
    final f = await reportCsv([report()], from: DateTime(2026, 11, 1), to: DateTime(2026, 11, 30));
    final bytes = f.readAsBytesSync();
    expect(bytes.sublist(0, 3), [0xEF, 0xBB, 0xBF]); // BOM: Excel citește UTF-8
    final text = utf8.decode(bytes);
    final lines = text.trim().split('\r\n');
    expect(lines.first.split(';').first, 'Angajat');
    final day2 = lines.firstWhere((l) => l.contains('02.11.2026'));
    expect(day2, contains('08:10'));
    expect(day2, contains('7:50'));
    expect(day2.split(';')[6], '10'); // întârziere 10 min
    expect(text, contains('CO 1'));
  });

  test('graficul și cardurile QR se generează', () async {
    final pdf = await schedulePdf(
      month: DateTime(2026, 11),
      employees: [emp],
      code: (_, d) => d.weekday <= 5 ? 's1' : DayCode.off,
      shifts: shifts.values.toList(),
      company: '',
    );
    expect(pdf.lengthSync(), greaterThan(1000));
    final csv = await scheduleCsv(
      month: DateTime(2026, 11),
      employees: [emp],
      code: (_, d) => d.weekday <= 5 ? 's1' : DayCode.off,
      shifts: shifts.values.toList(),
    );
    final row = utf8.decode(csv.readAsBytesSync()).split('\r\n')[1];
    expect(row, startsWith('Ștefan Țăranu;'));
    expect(row, endsWith('168:00')); // 21 de zile lucrătoare × 8h
    final cards = await qrCardsPdf([emp], company: 'Test');
    expect(cards.path, endsWith('qr_Stefan_Taranu.pdf'));
  });
}
