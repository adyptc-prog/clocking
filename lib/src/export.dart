import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import '../l10n.dart';
import 'models.dart';
import 'report.dart';

// ─── Exporturi: PDF (fontul Roboto inclus — diacritice, fără internet) și CSV ─

Future<pw.ThemeData> _theme() async {
  final regular = pw.Font.ttf(await rootBundle.load('assets/fonts/Roboto-Regular.ttf'));
  final bold = pw.Font.ttf(await rootBundle.load('assets/fonts/Roboto-Bold.ttf'));
  return pw.ThemeData.withFont(base: regular, bold: bold);
}

PdfColor _c(int argb) => PdfColor.fromInt(argb);

Future<File> _write(String name, List<int> bytes) async {
  final dir = Directory('${(await getTemporaryDirectory()).path}/exports');
  await dir.create(recursive: true);
  final f = File('${dir.path}/$name');
  await f.writeAsBytes(bytes, flush: true);
  return f;
}

Future<void> shareFile(File f, {required String subject}) async {
  await SharePlus.instance.share(ShareParams(
    files: [XFile(f.path)],
    subject: subject,
  ));
}

String _stamp(DateTime d) =>
    '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';

// Numele de fișier fără diacritice și spații.
String _slug(String s) {
  const from = 'ăâîșşțţĂÂÎȘŞȚŢ';
  const to = 'aaisstt' 'AAISSTT';
  final b = StringBuffer();
  for (final ch in s.split('')) {
    final i = from.indexOf(ch);
    b.write(i >= 0 ? to[i] : ch);
  }
  return b.toString().replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_').replaceAll(RegExp(r'^_|_$'), '');
}

pw.Widget _header(String title, String subtitle, String company) => pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(title, style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
            pw.Text(company.isEmpty ? 'Clocking' : company,
                style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
          ],
        ),
        pw.SizedBox(height: 2),
        pw.Text(subtitle, style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
        pw.SizedBox(height: 8),
      ],
    );

pw.Widget _footer(pw.Context ctx) => pw.Container(
      alignment: pw.Alignment.centerRight,
      margin: const pw.EdgeInsets.only(top: 6),
      child: pw.Text(
        '${tr('Generat', 'Generated')} ${fmtDateTime(DateTime.now())} · Clocking · ${ctx.pageNumber}/${ctx.pagesCount}',
        style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
      ),
    );

// ─── Textele unui rând de raport ──────────────────────────────────────────────
String scheduleLabel(DayRow r) {
  if (r.shift != null) return '${r.shift!.name} ${r.shift!.hoursLabel}';
  if (r.code.isEmpty) return '';
  return DayCode.label(r.code);
}

String statusLabel(DayRow r) => switch (r.status) {
      DayStatus.present => tr('Prezent', 'Present'),
      DayStatus.absent => tr('Absent', 'Absent'),
      DayStatus.scheduled => tr('Programat', 'Scheduled'),
      DayStatus.leave => DayCode.label(r.code),
      DayStatus.off => tr('Liber', 'Day off'),
      DayStatus.holiday => tr('Sărbătoare', 'Holiday'),
      DayStatus.unscheduled => '',
    };

String notesLabel(DayRow r) => [
      if (r.sessions.any((s) => s.ongoing)) tr('în desfășurare', 'in progress'),
      if (r.incomplete) tr('pontaj incomplet', 'incomplete record'),
      if (r.edited) tr('corectat manual', 'edited by manager'),
      if (r.status == DayStatus.present && DayCode.isLeave(r.code))
        tr('lucrat în concediu', 'worked on leave'),
      if (r.status == DayStatus.present && (r.code == DayCode.off || r.code == DayCode.holiday))
        tr('lucrat în zi liberă', 'worked on a day off'),
    ].join(', ');

String sessionsIn(DayRow r) =>
    r.sessions.map((s) => s.start == null ? '—' : fmtTime(s.start!)).join('\n');

String sessionsOut(DayRow r) => r.sessions
    .map((s) => s.end == null ? (s.ongoing ? '…' : '—') : fmtTime(s.end!))
    .join('\n');

String _min(int m) => m == 0 ? '' : fmtDuration(Duration(minutes: m));

// ─── Raport PDF ───────────────────────────────────────────────────────────────
Future<File> reportPdf(List<EmployeeReport> reports,
    {required DateTime from, required DateTime to, required String company}) async {
  final doc = pw.Document(theme: await _theme());
  final period = '${fmtDate(from)} – ${fmtDate(to)}';
  final wd = weekdayShortNames();
  for (final rep in reports) {
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4.landscape,
      margin: const pw.EdgeInsets.all(24),
      maxPages: 100,
      header: (_) => _header(
          '${tr('Raport pontaj', 'Time report')} · ${rep.employee.name}',
          [period, if (rep.employee.role.isNotEmpty) rep.employee.role].join(' · '),
          company),
      footer: _footer,
      build: (_) => [
        _summaryTable(rep),
        pw.SizedBox(height: 10),
        pw.TableHelper.fromTextArray(
          headerStyle: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold),
          cellStyle: const pw.TextStyle(fontSize: 8),
          headerDecoration: const pw.BoxDecoration(color: PdfColors.teal50),
          cellAlignment: pw.Alignment.centerLeft,
          headers: [
            tr('Data', 'Date'),
            tr('Program', 'Schedule'),
            tr('Intrare', 'In'),
            tr('Ieșire', 'Out'),
            tr('Lucrat', 'Worked'),
            tr('Întârziere', 'Late'),
            tr('Plecat devreme', 'Left early'),
            tr('Peste program', 'Overtime'),
            tr('Stare', 'Status'),
            tr('Observații', 'Notes'),
          ],
          data: [
            for (final r in rep.rows)
              [
                '${wd[r.day.weekday - 1]} ${fmtDate(r.day)}',
                scheduleLabel(r),
                sessionsIn(r),
                sessionsOut(r),
                r.worked == Duration.zero ? '' : fmtDuration(r.worked),
                _min(r.lateMinutes),
                _min(r.earlyMinutes),
                _min(r.overtimeMinutes),
                statusLabel(r),
                notesLabel(r),
              ],
          ],
        ),
      ],
    ));
  }
  if (reports.isEmpty) {
    doc.addPage(pw.Page(build: (_) => pw.Text(tr('Niciun angajat.', 'No employees.'))));
  }
  final who = reports.length == 1 ? _slug(reports.first.employee.name) : tr('toti', 'all');
  return _write('pontaj_${who}_${_stamp(from)}_${_stamp(to)}.pdf', await doc.save());
}

pw.Widget _summaryTable(EmployeeReport rep) {
  final leaves = rep.leaveDays.entries
      .map((e) => '${DayCode.label(e.key)}: ${e.value}')
      .join(', ');
  final cells = <List<String>>[
    [tr('Ore lucrate', 'Hours worked'), fmtDuration(Duration(minutes: rep.workedMinutes))],
    if (rep.flexible) ...[
      [tr('Normă (program flexibil)', 'Norm (flexible hours)'), fmtDuration(Duration(minutes: rep.normMinutes!))],
      [tr('Față de normă', 'Vs. norm'),
          '${rep.normDiffMinutes > 0 ? '+' : ''}${fmtDuration(Duration(minutes: rep.normDiffMinutes))}'],
    ] else
      [tr('Ore programate', 'Scheduled hours'), fmtDuration(Duration(minutes: rep.scheduledMinutes))],
    [tr('Zile prezent', 'Days present'), '${rep.daysPresent}'],
    [tr('Absențe', 'Absences'), '${rep.absences}'],
    [tr('Întârzieri', 'Late arrivals'), '${rep.lateCount} (${fmtDuration(Duration(minutes: rep.lateMinutes))})'],
    [tr('Plecări devreme', 'Early departures'), fmtDuration(Duration(minutes: rep.earlyMinutes))],
    [tr('Ore peste program', 'Overtime'), fmtDuration(Duration(minutes: rep.overtimeMinutes))],
    [tr('Pontaje incomplete', 'Incomplete records'), '${rep.incompleteCount}'],
    if (leaves.isNotEmpty) [tr('Concedii (zile)', 'Leave (days)'), leaves],
  ];
  return pw.Wrap(
    spacing: 6,
    runSpacing: 6,
    children: [
      for (final c in cells)
        pw.Container(
          padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: PdfColors.teal200),
            borderRadius: pw.BorderRadius.circular(4),
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(c[0], style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey700)),
              pw.Text(c[1], style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
            ],
          ),
        ),
    ],
  );
}

// ─── Raport CSV (Excel: „;” și BOM UTF-8) ─────────────────────────────────────
String _csvCell(String v) {
  final s = v.replaceAll('\n', ' / ');
  return s.contains(RegExp('[;"\n]')) ? '"${s.replaceAll('"', '""')}"' : s;
}

String _csv(List<List<String>> rows) =>
    '﻿${rows.map((r) => r.map(_csvCell).join(';')).join('\r\n')}\r\n';

Future<File> reportCsv(List<EmployeeReport> reports,
    {required DateTime from, required DateTime to}) async {
  final rows = <List<String>>[
    [
      tr('Angajat', 'Employee'),
      tr('Data', 'Date'),
      tr('Program', 'Schedule'),
      tr('Intrare', 'In'),
      tr('Ieșire', 'Out'),
      tr('Ore lucrate', 'Hours worked'),
      tr('Întârziere (min)', 'Late (min)'),
      tr('Plecat devreme (min)', 'Left early (min)'),
      tr('Peste program (min)', 'Overtime (min)'),
      tr('Stare', 'Status'),
      tr('Observații', 'Notes'),
    ],
  ];
  for (final rep in reports) {
    for (final r in rep.rows) {
      rows.add([
        rep.employee.name,
        fmtDate(r.day),
        scheduleLabel(r),
        sessionsIn(r),
        sessionsOut(r),
        r.worked == Duration.zero ? '' : fmtDuration(r.worked),
        r.lateMinutes == 0 ? '' : '${r.lateMinutes}',
        r.earlyMinutes == 0 ? '' : '${r.earlyMinutes}',
        r.overtimeMinutes == 0 ? '' : '${r.overtimeMinutes}',
        statusLabel(r),
        notesLabel(r),
      ]);
    }
  }
  rows.add([]);
  rows.add([
    tr('Angajat', 'Employee'),
    tr('Ore lucrate', 'Hours worked'),
    tr('Ore programate / normă', 'Scheduled hours / norm'),
    tr('Zile prezent', 'Days present'),
    tr('Absențe', 'Absences'),
    tr('Întârzieri', 'Late arrivals'),
    tr('Întârzieri (min)', 'Late (min)'),
    tr('Plecat devreme (min)', 'Left early (min)'),
    tr('Peste program (min)', 'Overtime (min)'),
    tr('Pontaje incomplete', 'Incomplete records'),
    tr('Concedii (zile)', 'Leave (days)'),
  ]);
  for (final rep in reports) {
    rows.add([
      rep.employee.name,
      fmtDuration(Duration(minutes: rep.workedMinutes)),
      fmtDuration(Duration(minutes: rep.flexible ? rep.normMinutes! : rep.scheduledMinutes)),
      '${rep.daysPresent}',
      '${rep.absences}',
      '${rep.lateCount}',
      '${rep.lateMinutes}',
      '${rep.earlyMinutes}',
      '${rep.overtimeMinutes}',
      '${rep.incompleteCount}',
      rep.leaveDays.entries.map((e) => '${DayCode.short(e.key)} ${e.value}').join(', '),
    ]);
  }
  final who = reports.length == 1 ? _slug(reports.first.employee.name) : tr('toti', 'all');
  return _write('pontaj_${who}_${_stamp(from)}_${_stamp(to)}.csv', utf8.encode(_csv(rows)));
}

// ─── Grafic de lucru PDF / CSV ────────────────────────────────────────────────
String cellLabel(String code, Map<String, Shift> shifts) {
  if (DayCode.isShift(code)) return shifts[code]?.shortLabel ?? '?';
  return DayCode.short(code);
}

Future<File> schedulePdf({
  required DateTime month,
  required List<Employee> employees,
  required String Function(String employeeId, DateTime day) code,
  required List<Shift> shifts,
  required String company,
}) async {
  final doc = pw.Document(theme: await _theme());
  final days = daysInMonth(month);
  final shiftMap = {for (final s in shifts) s.id: s};
  final wd = weekdayShortNames();
  final used = <String>{};

  pw.Widget cell(String text, {int? bg, bool bold = false, double size = 7}) => pw.Container(
        alignment: pw.Alignment.center,
        padding: const pw.EdgeInsets.symmetric(vertical: 3),
        color: bg == null ? null : _c(bg),
        child: pw.Text(text,
            style: pw.TextStyle(
              fontSize: size,
              fontWeight: bold ? pw.FontWeight.bold : null,
              color: bg != null && isDarkColor(bg) ? PdfColors.white : PdfColors.black,
            )),
      );

  final header = pw.TableRow(children: [
    cell(tr('Angajat', 'Employee'), bold: true),
    for (var d = 1; d <= days; d++)
      () {
        final date = DateTime(month.year, month.month, d);
        final weekend = date.weekday >= 6;
        return pw.Column(children: [
          cell('$d', bold: true, bg: weekend ? 0xFFE2E8F0 : null),
          cell(wd[date.weekday - 1], size: 6, bg: weekend ? 0xFFE2E8F0 : null),
        ]);
      }(),
    cell(tr('Ore', 'Hours'), bold: true),
  ]);

  final rows = <pw.TableRow>[header];
  for (final e in employees) {
    var minutes = 0;
    final cells = <pw.Widget>[
      pw.Padding(
        padding: const pw.EdgeInsets.all(3),
        child: pw.Text(e.name, style: const pw.TextStyle(fontSize: 7)),
      ),
    ];
    for (var d = 1; d <= days; d++) {
      final c = code(e.id, DateTime(month.year, month.month, d));
      if (c.isNotEmpty) used.add(c);
      final shift = DayCode.isShift(c) ? shiftMap[c] : null;
      if (shift != null) minutes += shift.durationMinutes;
      cells.add(cell(cellLabel(c, shiftMap),
          bg: shift != null ? shiftColor(shift) : (c.isEmpty ? null : dayCodeColor(c))));
    }
    cells.add(cell(fmtDuration(Duration(minutes: minutes)), bold: true));
    rows.add(pw.TableRow(children: cells));
  }

  final legend = <pw.Widget>[
    for (final s in shifts.where((s) => used.contains(s.id)))
      _legendItem(s.shortLabel, '${s.name} ${s.hoursLabel}', shiftColor(s)),
    for (final c in DayCode.nonShift.where(used.contains))
      _legendItem(DayCode.short(c), DayCode.label(c), dayCodeColor(c)),
  ];

  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4.landscape,
    margin: const pw.EdgeInsets.all(20),
    header: (_) => _header(tr('Grafic de lucru', 'Work schedule'), fmtMonth(month), company),
    footer: _footer,
    build: (_) => [
      pw.Table(
        border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
        columnWidths: {
          0: const pw.FixedColumnWidth(90),
          for (var d = 1; d <= days; d++) d: const pw.FlexColumnWidth(),
          days + 1: const pw.FixedColumnWidth(30),
        },
        children: rows,
      ),
      pw.SizedBox(height: 10),
      pw.Wrap(spacing: 10, runSpacing: 4, children: legend),
    ],
  ));
  return _write('grafic_${monthKey(month)}.pdf', await doc.save());
}

pw.Widget _legendItem(String short, String label, int color) => pw.Row(
      mainAxisSize: pw.MainAxisSize.min,
      children: [
        pw.Container(
          width: 18,
          padding: const pw.EdgeInsets.symmetric(vertical: 2),
          alignment: pw.Alignment.center,
          color: _c(color),
          child: pw.Text(short,
              style: pw.TextStyle(
                  fontSize: 7,
                  color: isDarkColor(color) ? PdfColors.white : PdfColors.black)),
        ),
        pw.SizedBox(width: 4),
        pw.Text(label, style: const pw.TextStyle(fontSize: 8)),
      ],
    );

Future<File> scheduleCsv({
  required DateTime month,
  required List<Employee> employees,
  required String Function(String employeeId, DateTime day) code,
  required List<Shift> shifts,
}) async {
  final days = daysInMonth(month);
  final shiftMap = {for (final s in shifts) s.id: s};
  final rows = <List<String>>[
    [tr('Angajat', 'Employee'), for (var d = 1; d <= days; d++) '$d', tr('Ore', 'Hours')],
  ];
  for (final e in employees) {
    var minutes = 0;
    final row = <String>[e.name];
    for (var d = 1; d <= days; d++) {
      final c = code(e.id, DateTime(month.year, month.month, d));
      final shift = DayCode.isShift(c) ? shiftMap[c] : null;
      if (shift != null) minutes += shift.durationMinutes;
      row.add(shift != null ? '${shift.shortLabel} ${shift.hoursLabel}' : DayCode.short(c));
    }
    row.add(fmtDuration(Duration(minutes: minutes)));
    rows.add(row);
  }
  return _write('grafic_${monthKey(month)}.csv', utf8.encode(_csv(rows)));
}

// ─── Carduri QR de printat ────────────────────────────────────────────────────
Future<File> qrCardsPdf(List<Employee> employees, {required String company}) async {
  final doc = pw.Document(theme: await _theme());
  pw.Widget card(Employee e) => pw.Container(
        margin: const pw.EdgeInsets.all(6),
        padding: const pw.EdgeInsets.all(10),
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: PdfColors.grey500, width: 0.8),
          borderRadius: pw.BorderRadius.circular(8),
        ),
        child: pw.Column(
          mainAxisAlignment: pw.MainAxisAlignment.center,
          children: [
            pw.Text(company.isEmpty ? 'Clocking' : company,
                style: const pw.TextStyle(fontSize: 8, color: PdfColors.teal800)),
            pw.SizedBox(height: 6),
            pw.BarcodeWidget(
              barcode: pw.Barcode.qrCode(),
              data: e.qrPayload,
              width: 120,
              height: 120,
              drawText: false,
            ),
            pw.SizedBox(height: 8),
            pw.Text(e.name,
                textAlign: pw.TextAlign.center,
                style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
            if (e.role.isNotEmpty)
              pw.Text(e.role, style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
            pw.SizedBox(height: 4),
            pw.Text(tr('Scanează la intrare și la ieșire', 'Scan when you arrive and when you leave'),
                style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey600)),
          ],
        ),
      );

  const perPage = 6;
  for (var i = 0; i < employees.length; i += perPage) {
    final chunk = employees.sublist(i, (i + perPage).clamp(0, employees.length));
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(24),
      build: (_) => pw.GridView(
        crossAxisCount: 2,
        childAspectRatio: 1.15,
        children: [for (final e in chunk) card(e)],
      ),
    ));
  }
  final name = employees.length == 1 ? 'qr_${_slug(employees.first.name)}.pdf' : 'qr_angajati.pdf';
  return _write(name, await doc.save());
}
