import 'package:flutter/material.dart';

import '../l10n.dart';
import '../src/export.dart';
import '../src/models.dart';
import '../src/store.dart';
import '../src/ui.dart';
import 'work_program_screen.dart';
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
              title: Text(tr('Lasă ziua generatorului', 'Leave the day to the generator')),
              subtitle: Text(tr('Șterge excepția; la generare ziua se completează după program.',
                  'Removes the exception; generating fills the day from the program.')),
              onTap: () => Navigator.pop(ctx, DayCode.none),
            ),
          ],
        ),
      ),
    );
    if (chosen == null) return;
    // Ziua aleasă de mână e o excepție: generatorul n-o mai schimbă.
    await _store.setScheduleDays(e.id, {day: chosen});
  }

  Future<void> _programs() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const WorkProgramsScreen()));
    if (mounted) setState(() {});
  }

  // Un singur buton: luna se completează după programul fiecărui angajat.
  Future<void> _generate() async {
    if (!await ensureLicensed(context)) return;
    if (!mounted) return;
    final employees = _store.activeEmployees;
    final withProgram = employees.where((e) => _store.programOf(e.id) != null).toList();
    if (withProgram.isEmpty) {
      final open = await confirmDialog(
        context,
        title: tr('Niciun program de lucru', 'No work programs'),
        message: tr('Alege mai întâi programul fiecărui angajat (fix, ture, ciclu sau normă lunară). '
            'Îl alegi o singură dată; apoi graficul se generează lunar dintr-un buton.',
            'First choose each employee\'s program (fixed, shifts, cycle or monthly norm). You choose it '
            'once; then the schedule is generated each month with one button.'),
        confirm: tr('Programe de lucru', 'Work programs'),
      );
      if (open) await _programs();
      return;
    }
    if (!mounted) return;
    final ok = await confirmDialog(
      context,
      title: tr('Generezi graficul pentru ${fmtMonth(_month)}?', 'Generate the schedule for ${fmtMonth(_month)}?'),
      message: tr('Luna se completează după programul fiecărui angajat (${withProgram.length} din ${employees.length}). '
          'Excepțiile marcate (concedii, zile libere, schimbări făcute de tine) rămân neschimbate.',
          'The month is filled in from each employee\'s program (${withProgram.length} of ${employees.length}). '
          'Marked exceptions (leave, days off, your own changes) stay unchanged.'),
      confirm: tr('Generează', 'Generate'),
    );
    if (!ok) return;
    final summary = await _store.generateMonthFor(withProgram, _month);
    if (!mounted) return;
    final missing = employees.where((e) => _store.programOf(e.id) == null).toList();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Grafic generat · ${fmtMonth(_month)}', 'Schedule generated · ${fmtMonth(_month)}')),
        content: SizedBox(
          width: 420,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final e in withProgram) _summaryTile(e.name, summary[e.id]!),
              if (missing.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    tr('Fără program (negenerați): ${missing.map((e) => e.name).join(', ')}',
                        'No program (not generated): ${missing.map((e) => e.name).join(', ')}'),
                    style: TextStyle(color: Colors.orange.shade900, fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('OK', 'OK')))],
      ),
    );
  }

  Widget _summaryTile(String name, ({int target, int planned}) s) {
    final diff = s.planned - s.target;
    final color = diff.abs() <= 60
        ? Colors.green.shade700
        : (diff > 0 ? Colors.orange.shade800 : Colors.red.shade700);
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(name),
      subtitle: Text(tr(
          'Normă ${fmtDuration(Duration(minutes: s.target))} h · programat ${fmtDuration(Duration(minutes: s.planned))} h',
          'Norm ${fmtDuration(Duration(minutes: s.target))} h · scheduled ${fmtDuration(Duration(minutes: s.planned))} h')),
      trailing: Text(
        diff == 0 ? '✓' : '${diff > 0 ? '+' : ''}${fmtDuration(Duration(minutes: diff))}',
        style: TextStyle(color: color, fontWeight: FontWeight.bold),
      ),
    );
  }

  // Zile libere, concedii, învoiri — pentru unul sau mai mulți angajați.
  Future<void> _addException() async {
    final employees = _store.activeEmployees;
    if (employees.isEmpty) return;
    final r = await showExceptionDialog(context, employees, _month);
    if (r == null) return;
    final days = <DateTime, String>{
      for (var d = dayOf(r.from); !d.isAfter(dayOf(r.to)); d = DateTime(d.year, d.month, d.day + 1))
        if (r.weekdays.contains(d.weekday)) d: r.code,
    };
    for (final e in r.employees) {
      await _store.setScheduleDays(e.id, days);
    }
    if (mounted) {
      showSnack(context, tr('${DayCode.label(r.code)}: ${r.employees.length} angajați, ${days.length} zile.',
          '${DayCode.label(r.code)}: ${r.employees.length} ${r.employees.length == 1 ? 'employee' : 'employees'}, ${days.length} ${days.length == 1 ? 'day' : 'days'}.'));
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.event_repeat),
                      label: Text(tr('Programe', 'Programs')),
                      onPressed: employees.isEmpty ? null : _programs,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.beach_access_outlined),
                      label: Text(tr('Excepții', 'Exceptions')),
                      onPressed: employees.isEmpty ? null : _addException,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              FilledButton.icon(
                icon: const Icon(Icons.auto_awesome),
                label: Text(tr('Generează grafic · ${fmtMonth(_month)}', 'Generate schedule · ${fmtMonth(_month)}')),
                onPressed: employees.isEmpty ? null : _generate,
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
                          () {
                            // Orele programate față de norma lunii (după concedii).
                            final sum = _store.monthSummary(e.id, _month);
                            final diff = sum.planned - sum.target;
                            return Text(
                              '${fmtDuration(Duration(minutes: sum.planned))}/${fmtDuration(Duration(minutes: sum.target))} h',
                              style: TextStyle(
                                fontSize: 10,
                                color: sum.planned == 0
                                    ? Colors.grey.shade600
                                    : diff.abs() <= 60
                                        ? Colors.green.shade700
                                        : Colors.orange.shade800,
                              ),
                            );
                          }(),
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
                                      exception: _store.isException(e.id, DateTime(_month.year, _month.month, d)),
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
              tr('Sub nume: ore programate / norma lunii. Zilele cu chenar negru sunt excepții '
                  '(puse de tine) și nu se schimbă la generare. Atinge o zi pentru a o modifica.',
                  'Under each name: scheduled hours / the month\'s norm. Days with a black border are '
                  'exceptions (set by you) and are kept when generating. Tap a day to change it.'),
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

// ─── Excepții: zile libere, concedii, învoiri, pentru unul sau mai mulți ─────
typedef ExceptionChoice = ({
  List<Employee> employees,
  DateTime from,
  DateTime to,
  String code,
  Set<int> weekdays,
});

Future<ExceptionChoice?> showExceptionDialog(BuildContext context, List<Employee> employees, DateTime month) {
  final selected = <String>{};
  final now = dayOf(DateTime.now());
  var from = now.year == month.year && now.month == month.month ? now : DateTime(month.year, month.month, 1);
  var to = from;
  var code = DayCode.vacation;
  final weekdays = <int>{1, 2, 3, 4, 5, 6, 7};
  String? error;
  final wd = weekdayShortNames();
  return showDialog<ExceptionChoice>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDs) => AlertDialog(
        title: Text(tr('Excepții', 'Exceptions')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                tr('Zile libere, concedii sau învoiri. Rămân neschimbate când generezi graficul.',
                    'Days off, leave or time off. They stay unchanged when you generate the schedule.'),
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
              ),
              const SizedBox(height: 10),
              Text(tr('Angajați', 'Employees'), style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  ActionChip(
                    label: Text(selected.length == employees.length ? tr('Niciunul', 'None') : tr('Toți', 'All')),
                    onPressed: () => setDs(() {
                      if (selected.length == employees.length) {
                        selected.clear();
                      } else {
                        selected.addAll(employees.map((e) => e.id));
                      }
                    }),
                  ),
                  for (final e in employees)
                    FilterChip(
                      label: Text(e.name),
                      selected: selected.contains(e.id),
                      onSelected: (v) => setDs(() => v ? selected.add(e.id) : selected.remove(e.id)),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: code,
                decoration: InputDecoration(labelText: tr('Tip', 'Type'), border: const OutlineInputBorder()),
                items: [
                  for (final c in [DayCode.off, ...DayCode.leaves])
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
              Text(tr('Doar în zilele:', 'Only on:'), style: const TextStyle(fontSize: 12)),
              Wrap(
                spacing: 4,
                children: [
                  for (var d = 1; d <= 7; d++)
                    FilterChip(
                      visualDensity: VisualDensity.compact,
                      label: Text(wd[d - 1]),
                      selected: weekdays.contains(d),
                      onSelected: (v) => setDs(() => v ? weekdays.add(d) : weekdays.remove(d)),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                tr('${calendarDays(from, to)} zile calendaristice.', '${calendarDays(from, to)} calendar days.'),
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(error!, style: TextStyle(color: Colors.red.shade700)),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Anulează', 'Cancel'))),
          FilledButton(
            onPressed: () {
              if (selected.isEmpty) {
                setDs(() => error = tr('Alege cel puțin un angajat.', 'Choose at least one employee.'));
                return;
              }
              if (weekdays.isEmpty) {
                setDs(() => error = tr('Alege cel puțin o zi a săptămânii.', 'Choose at least one weekday.'));
                return;
              }
              Navigator.pop(ctx, (
                employees: employees.where((e) => selected.contains(e.id)).toList(),
                from: from,
                to: to,
                code: code,
                weekdays: Set.of(weekdays),
              ));
            },
            child: Text(tr('Salvează', 'Save')),
          ),
        ],
      ),
    ),
  );
}
