import 'package:flutter/material.dart';

import '../l10n.dart';
import '../src/export.dart';
import '../src/models.dart';
import '../src/schedule_gen.dart';
import '../src/store.dart';
import '../src/ui.dart';
import 'schedule_generator_screen.dart';
import 'shifts_screen.dart';

// ─── Graficul de lucru pe o lună (angajați × zile) ────────────────────────────
class ScheduleScreen extends StatefulWidget {
  const ScheduleScreen({super.key});

  @override
  State<ScheduleScreen> createState() => _ScheduleScreenState();
}

class _ScheduleScreenState extends State<ScheduleScreen> {
  final _store = Store.instance;
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  bool _loading = true;

  static const _cellW = 38.0;
  static const _cellH = 40.0;
  static const _nameW = 116.0;

  @override
  void initState() {
    super.initState();
    _store.addListener(_changed);
    _load();
  }

  @override
  void dispose() {
    _store.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    await _store.ensureSchedules(_month, DateTime(_month.year, _month.month + 1, 0));
    if (mounted) setState(() => _loading = false);
  }

  void _shiftMonth(int delta) {
    setState(() {
      _month = DateTime(_month.year, _month.month + delta);
      _loading = true;
    });
    _load();
  }

  Future<void> _editCell(Employee e, DateTime day) async {
    final shifts = _store.shifts;
    final current = _store.scheduleCode(e.id, day);
    final chosen = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: Text('${e.name} · ${weekdayShortNames()[day.weekday - 1]} ${fmtDate(day)}',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
            for (final s in shifts)
              ListTile(
                leading: DayChip(label: s.shortLabel, color: shiftColor(s)),
                title: Text(s.name),
                subtitle: Text(s.hoursLabel),
                trailing: current == s.id ? const Icon(Icons.check, color: kTeal) : null,
                onTap: () => Navigator.pop(ctx, s.id),
              ),
            const Divider(),
            for (final c in DayCode.nonShift)
              ListTile(
                leading: DayChip(label: DayCode.short(c), color: dayCodeColor(c)),
                title: Text(DayCode.label(c)),
                trailing: current == c ? const Icon(Icons.check, color: kTeal) : null,
                onTap: () => Navigator.pop(ctx, c),
              ),
            ListTile(
              leading: const DayChip(label: '', color: 0xFFFFFFFF, outlined: true),
              title: Text(tr('Golește ziua', 'Clear the day')),
              onTap: () => Navigator.pop(ctx, DayCode.none),
            ),
          ],
        ),
      ),
    );
    if (chosen == null || chosen == current) return;
    await _store.setScheduleDays(e.id, {day: chosen});
  }

  Future<void> _generate() async {
    if (!await ensureLicensed(context)) return;
    if (!mounted) return;
    final done = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => ScheduleGeneratorScreen(month: _month),
    ));
    if (done == true) _load();
  }

  Future<void> _addLeave() async {
    if (!await ensureLicensed(context)) return;
    if (!mounted) return;
    final employees = _store.activeEmployees;
    if (employees.isEmpty) return;
    final r = await showLeaveDialog(context, employees);
    if (r == null) return;
    final days = <DateTime, String>{};
    for (var d = dayOf(r.from); !d.isAfter(dayOf(r.to)); d = DateTime(d.year, d.month, d.day + 1)) {
      days[d] = r.code;
    }
    await _store.setScheduleDays(r.employee.id, days);
    if (mounted) {
      showSnack(context, tr('${DayCode.label(r.code)}: ${r.employee.name}, ${days.length} zile.',
          '${DayCode.label(r.code)}: ${r.employee.name}, ${days.length} ${days.length == 1 ? 'day' : 'days'}.'));
    }
  }

  Future<void> _export(bool pdf) async {
    if (!await ensureLicensed(context)) return;
    final employees = _store.activeEmployees;
    final f = pdf
        ? await schedulePdf(
            month: _month,
            employees: employees,
            code: _store.scheduleCode,
            shifts: _store.shifts,
            company: _store.companyName,
          )
        : await scheduleCsv(
            month: _month,
            employees: employees,
            code: _store.scheduleCode,
            shifts: _store.shifts,
          );
    await shareFile(f, subject: tr('Grafic de lucru · ${fmtMonth(_month)}', 'Work schedule · ${fmtMonth(_month)}'));
  }

  @override
  Widget build(BuildContext context) {
    final employees = _store.activeEmployees;
    return Column(
      children: [
        Material(
          color: Colors.white,
          elevation: 1,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Row(
              children: [
                IconButton(icon: const Icon(Icons.chevron_left), onPressed: () => _shiftMonth(-1)),
                Expanded(
                  child: Text(fmtMonth(_month),
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                ),
                IconButton(icon: const Icon(Icons.chevron_right), onPressed: () => _shiftMonth(1)),
                PopupMenuButton<String>(
                  onSelected: (v) async {
                    switch (v) {
                      case 'shifts':
                        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ShiftsScreen()));
                      case 'pdf':
                        await _export(true);
                      case 'csv':
                        await _export(false);
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(value: 'shifts', child: ListTile(leading: const Icon(Icons.schedule), title: Text(tr('Ture și ore', 'Shifts and hours')))),
                    PopupMenuItem(value: 'pdf', child: ListTile(leading: const Icon(Icons.picture_as_pdf_outlined), title: Text(tr('Exportă PDF', 'Export PDF')))),
                    PopupMenuItem(value: 'csv', child: ListTile(leading: const Icon(Icons.table_chart_outlined), title: Text(tr('Exportă CSV (Excel)', 'Export CSV (Excel)')))),
                  ],
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  icon: const Icon(Icons.auto_awesome),
                  label: Text(tr('Generează grafic', 'Generate schedule')),
                  onPressed: employees.isEmpty ? null : _generate,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.beach_access_outlined),
                  label: Text(tr('Concediu', 'Leave')),
                  onPressed: employees.isEmpty ? null : _addLeave,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : employees.isEmpty
                  ? Center(child: Text(tr('Adaugă mai întâi angajații.', 'Add the employees first.')))
                  : _grid(employees),
        ),
      ],
    );
  }

  Widget _grid(List<Employee> employees) {
    final days = daysInMonth(_month);
    final shifts = _store.shiftMap;
    final wd = weekdayShortNames();
    final today = dayOf(DateTime.now());

    Widget dayHeader(int d) {
      final date = DateTime(_month.year, _month.month, d);
      final weekend = date.weekday >= 6;
      return Container(
        width: _cellW,
        height: _cellH,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: date == today ? kAmber.withValues(alpha: 0.5) : (weekend ? Colors.grey.shade200 : null),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('$d', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
            Text(wd[date.weekday - 1], style: TextStyle(fontSize: 10, color: Colors.grey.shade700)),
          ],
        ),
      );
    }

    int monthMinutes(Employee e) {
      var m = 0;
      for (var d = 1; d <= days; d++) {
        final c = _store.scheduleCode(e.id, DateTime(_month.year, _month.month, d));
        if (DayCode.isShift(c)) m += shifts[c]?.durationMinutes ?? 0;
      }
      return m;
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: 8, bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Coloana fixă cu numele.
              Column(
                children: [
                  SizedBox(width: _nameW, height: _cellH),
                  for (final e in employees)
                    Container(
                      width: _nameW,
                      height: _cellH,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      alignment: Alignment.centerLeft,
                      decoration: BoxDecoration(
                        border: Border(top: BorderSide(color: Colors.grey.shade300)),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                          Text('${fmtDuration(Duration(minutes: monthMinutes(e)))} h',
                              style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
                        ],
                      ),
                    ),
                ],
              ),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [for (var d = 1; d <= days; d++) dayHeader(d)]),
                      for (final e in employees)
                        Container(
                          decoration: BoxDecoration(
                            border: Border(top: BorderSide(color: Colors.grey.shade300)),
                          ),
                          child: Row(
                            children: [
                              for (var d = 1; d <= days; d++)
                                InkWell(
                                  onTap: () => _editCell(e, DateTime(_month.year, _month.month, d)),
                                  child: Padding(
                                    padding: const EdgeInsets.all(2),
                                    child: dayCodeChip(
                                      _store.scheduleCode(e.id, DateTime(_month.year, _month.month, d)),
                                      shifts,
                                      width: _cellW - 4,
                                      height: _cellH - 4,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(
              spacing: 12,
              runSpacing: 6,
              children: [
                for (final s in _store.shifts)
                  _legend(DayChip(label: s.shortLabel, color: shiftColor(s), width: 28, height: 22),
                      '${s.name} ${s.hoursLabel}'),
                for (final c in DayCode.nonShift)
                  _legend(DayChip(label: DayCode.short(c), color: dayCodeColor(c), width: 28, height: 22),
                      DayCode.label(c)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Text(
              tr('Atinge o zi pentru a o modifica. Graficul se sincronizează cu telefonul partener.',
                  'Tap a day to change it. The schedule syncs with the partner phone.'),
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _legend(Widget chip, String label) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [chip, const SizedBox(width: 4), Text(label, style: const TextStyle(fontSize: 12))],
      );
}

// ─── Concediu pentru un angajat ───────────────────────────────────────────────
typedef LeaveChoice = ({Employee employee, DateTime from, DateTime to, String code});

Future<LeaveChoice?> showLeaveDialog(BuildContext context, List<Employee> employees,
    {Employee? initial}) {
  var emp = initial ?? employees.first;
  var from = dayOf(DateTime.now());
  var to = from;
  var code = DayCode.vacation;
  return showDialog<LeaveChoice>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDs) => AlertDialog(
        title: Text(tr('Concediu / zile libere', 'Leave / days off')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<Employee>(
                initialValue: emp,
                decoration: InputDecoration(labelText: tr('Angajat', 'Employee'), border: const OutlineInputBorder()),
                items: [for (final e in employees) DropdownMenuItem(value: e, child: Text(e.name))],
                onChanged: (v) => setDs(() => emp = v ?? emp),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: code,
                decoration: InputDecoration(labelText: tr('Tip', 'Type'), border: const OutlineInputBorder()),
                items: [
                  for (final c in [...DayCode.leaves, DayCode.off])
                    DropdownMenuItem(value: c, child: Text(DayCode.label(c))),
                ],
                onChanged: (v) => setDs(() => code = v ?? code),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () async {
                        final d = await pickDate(ctx, from);
                        if (d != null) {
                          setDs(() {
                            from = dayOf(d);
                            if (to.isBefore(from)) to = from;
                          });
                        }
                      },
                      child: Text('${tr('De la', 'From')} ${fmtDate(from)}'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () async {
                        final d = await pickDate(ctx, to);
                        if (d != null) {
                          setDs(() {
                            to = dayOf(d);
                            if (to.isBefore(from)) from = to;
                          });
                        }
                      },
                      child: Text('${tr('Până la', 'To')} ${fmtDate(to)}'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                tr('${calendarDays(from, to)} zile calendaristice.',
                    '${calendarDays(from, to)} calendar days.'),
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Anulează', 'Cancel'))),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, (employee: emp, from: from, to: to, code: code)),
            child: Text(tr('Salvează', 'Save')),
          ),
        ],
      ),
    ),
  );
}

// Folosit de generator: aceleași intervale de concediu, ca LeaveRange.
LeaveRange leaveRangeOf(LeaveChoice c) => LeaveRange(c.from, c.to, c.code);
