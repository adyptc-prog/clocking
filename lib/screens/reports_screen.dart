import 'package:flutter/material.dart';

import '../l10n.dart';
import '../src/export.dart';
import '../src/models.dart';
import '../src/report.dart';
import '../src/store.dart';
import '../src/ui.dart';

// ─── Rapoarte: perioadă aleasă, un angajat sau toți ───────────────────────────
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

enum _Preset { thisMonth, lastMonth, thisWeek, lastWeek, custom }

class _ReportsScreenState extends State<ReportsScreen> {
  final _store = Store.instance;
  _Preset _preset = _Preset.thisMonth;
  late DateTime _from;
  late DateTime _to;
  String? _employeeId; // null = toți
  List<EmployeeReport>? _reports;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _applyPreset(_Preset.thisMonth);
  }

  void _applyPreset(_Preset p) {
    final now = dayOf(DateTime.now());
    final monday = now.subtract(Duration(days: now.weekday - 1));
    switch (p) {
      case _Preset.thisMonth:
        _from = DateTime(now.year, now.month, 1);
        _to = DateTime(now.year, now.month + 1, 0);
      case _Preset.lastMonth:
        _from = DateTime(now.year, now.month - 1, 1);
        _to = DateTime(now.year, now.month, 0);
      case _Preset.thisWeek:
        _from = monday;
        _to = DateTime(monday.year, monday.month, monday.day + 6);
      case _Preset.lastWeek:
        _from = DateTime(monday.year, monday.month, monday.day - 7);
        _to = DateTime(monday.year, monday.month, monday.day - 1);
      case _Preset.custom:
        break;
    }
    _preset = p;
    _reports = null;
  }

  Future<void> _pickRange() async {
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      initialDateRange: DateTimeRange(start: _from, end: _to),
    );
    if (r == null) return;
    setState(() {
      _preset = _Preset.custom;
      _from = dayOf(r.start);
      _to = dayOf(r.end);
      _reports = null;
    });
  }

  Future<List<EmployeeReport>?> _build() async {
    if (!await ensureLicensed(context)) return null;
    setState(() => _busy = true);
    try {
      // Pontajele din ziua următoare: ieșirea unei ture de noapte.
      final punches = await _store.punchesBetween(_from, _to.add(const Duration(days: 1)));
      await _store.ensureSchedules(_from, _to);
      final employees = _employeeId == null
          ? _store.employees
          : [?_store.employeeById(_employeeId!)];
      final now = DateTime.now();
      final reports = [
        for (final e in employees)
          buildEmployeeReport(
            employee: e,
            punches: punches,
            scheduleCode: (d) => _store.scheduleCode(e.id, d),
            shifts: _store.shiftMap,
            from: _from,
            to: _to,
            toleranceMinutes: _store.lateToleranceMinutes,
            now: now,
          ),
      ];
      // Toți: fără angajații inactivi care n-au nimic în perioadă.
      final shown = _employeeId == null
          ? reports.where((r) => r.employee.active || r.workedMinutes > 0 || r.incompleteCount > 0).toList()
          : reports;
      if (mounted) setState(() => _reports = shown);
      return shown;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export(bool pdf) async {
    final reports = _reports ?? await _build();
    if (reports == null) return;
    setState(() => _busy = true);
    try {
      final f = pdf
          ? await reportPdf(reports, from: _from, to: _to, company: _store.companyName)
          : await reportCsv(reports, from: _from, to: _to);
      await shareFile(f, subject: tr('Raport pontaj ${fmtDate(_from)} – ${fmtDate(_to)}',
          'Time report ${fmtDate(_from)} – ${fmtDate(_to)}'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final employees = _store.employees;
    final labels = {
      _Preset.thisMonth: tr('Luna aceasta', 'This month'),
      _Preset.lastMonth: tr('Luna trecută', 'Last month'),
      _Preset.thisWeek: tr('Săptămâna aceasta', 'This week'),
      _Preset.lastWeek: tr('Săptămâna trecută', 'Last week'),
    };
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final e in labels.entries)
                      ChoiceChip(
                        label: Text(e.value),
                        selected: _preset == e.key,
                        onSelected: (_) => setState(() => _applyPreset(e.key)),
                      ),
                    ChoiceChip(
                      avatar: const Icon(Icons.date_range, size: 18),
                      label: Text(tr('Alege perioada', 'Choose period')),
                      selected: _preset == _Preset.custom,
                      onSelected: (_) => _pickRange(),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text('${fmtDate(_from)} – ${fmtDate(_to)}',
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                const SizedBox(height: 12),
                DropdownButtonFormField<String?>(
                  initialValue: _employeeId,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: tr('Angajat', 'Employee'), border: const OutlineInputBorder()),
                  items: [
                    DropdownMenuItem(value: null, child: Text(tr('Toți angajații', 'All employees'))),
                    for (final e in employees) DropdownMenuItem(value: e.id, child: Text(e.name)),
                  ],
                  onChanged: (v) => setState(() {
                    _employeeId = v;
                    _reports = null;
                  }),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  icon: const Icon(Icons.assessment_outlined),
                  label: Text(tr('Generează raportul', 'Generate the report')),
                  onPressed: _busy || employees.isEmpty ? null : _build,
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.picture_as_pdf_outlined),
                        label: const Text('PDF'),
                        onPressed: _busy || employees.isEmpty ? null : () => _export(true),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.table_chart_outlined),
                        label: const Text('CSV (Excel)'),
                        onPressed: _busy || employees.isEmpty ? null : () => _export(false),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (_busy) const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
        if (_reports != null && !_busy) ...[
          if (_reports!.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Center(child: Text(tr('Nimic de raportat în perioada aleasă.', 'Nothing to report for the chosen period.'))),
            ),
          for (final r in _reports!) _ReportCard(report: r),
        ],
      ],
    );
  }
}

class _ReportCard extends StatelessWidget {
  final EmployeeReport report;
  const _ReportCard({required this.report});

  @override
  Widget build(BuildContext context) {
    final r = report;
    Widget stat(String label, String value, {Color? color}) => Container(
          width: 108,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: (color ?? kTeal).withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: TextStyle(fontSize: 11, color: Colors.grey.shade700)),
              Text(value, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color ?? kTealDark)),
            ],
          ),
        );
    final leaves = r.leaveDays;
    final wd = weekdayShortNames();
    final visibleRows = r.rows.where((d) =>
        d.sessions.isNotEmpty || d.status == DayStatus.absent || DayCode.isLeave(d.code)).toList();

    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: ExpansionTile(
        shape: const Border(),
        title: Text(r.employee.name, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(tr(
            '${fmtDuration(Duration(minutes: r.workedMinutes))} h lucrate · ${r.daysPresent} zile',
            '${fmtDuration(Duration(minutes: r.workedMinutes))} h worked · ${r.daysPresent} days')),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              stat(tr('Ore lucrate', 'Hours worked'), fmtDuration(Duration(minutes: r.workedMinutes))),
              stat(tr('Ore programate', 'Scheduled'), fmtDuration(Duration(minutes: r.scheduledMinutes))),
              stat(tr('Peste program', 'Overtime'), fmtDuration(Duration(minutes: r.overtimeMinutes))),
              stat(tr('Zile prezent', 'Days present'), '${r.daysPresent}'),
              stat(tr('Absențe', 'Absences'), '${r.absences}', color: r.absences > 0 ? Colors.red.shade700 : null),
              stat(tr('Întârzieri', 'Late'), '${r.lateCount} · ${fmtDuration(Duration(minutes: r.lateMinutes))}',
                  color: r.lateCount > 0 ? Colors.orange.shade800 : null),
              stat(tr('Plecat devreme', 'Left early'), fmtDuration(Duration(minutes: r.earlyMinutes)),
                  color: r.earlyMinutes > 0 ? Colors.orange.shade800 : null),
              stat(tr('Incomplete', 'Incomplete'), '${r.incompleteCount}',
                  color: r.incompleteCount > 0 ? Colors.orange.shade800 : null),
              for (final l in leaves.entries) stat(DayCode.label(l.key), '${l.value}', color: Colors.green.shade800),
            ],
          ),
          const SizedBox(height: 8),
          if (visibleRows.isEmpty)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(tr('Fără pontaje în perioadă.', 'No clockings in the period.'),
                  style: TextStyle(color: Colors.grey.shade600)),
            ),
          for (final d in visibleRows)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: SizedBox(
                width: 64,
                child: Text('${wd[d.day.weekday - 1]} ${d.day.day.toString().padLeft(2, '0')}.${d.day.month.toString().padLeft(2, '0')}',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
              title: Text(d.sessions.isEmpty
                  ? statusLabel(d)
                  : '${sessionsIn(d).replaceAll('\n', ', ')} → ${sessionsOut(d).replaceAll('\n', ', ')}'),
              subtitle: Text([
                if (d.worked > Duration.zero) '${fmtDuration(d.worked)} h',
                if (d.lateMinutes > 0) tr('întârziere ${d.lateMinutes} min', 'late ${d.lateMinutes} min'),
                if (d.earlyMinutes > 0) tr('plecat devreme ${d.earlyMinutes} min', 'left early ${d.earlyMinutes} min'),
                if (d.overtimeMinutes > 0) tr('+${fmtDuration(Duration(minutes: d.overtimeMinutes))} peste program', '+${fmtDuration(Duration(minutes: d.overtimeMinutes))} overtime'),
                if (notesLabel(d).isNotEmpty) notesLabel(d),
              ].join(' · ')),
              trailing: d.shift != null ? Text(d.shift!.hoursLabel, style: const TextStyle(fontSize: 11)) : null,
            ),
        ],
      ),
    );
  }
}
