import 'package:flutter/material.dart';

import '../l10n.dart';
import '../src/models.dart';
import '../src/schedule_gen.dart';
import '../src/store.dart';
import '../src/ui.dart';

// ─── Programele de lucru: ce program are fiecare angajat ──────────────────────
class WorkProgramsScreen extends StatefulWidget {
  const WorkProgramsScreen({super.key});

  @override
  State<WorkProgramsScreen> createState() => _WorkProgramsScreenState();
}

class _WorkProgramsScreenState extends State<WorkProgramsScreen> {
  final _store = Store.instance;

  Future<void> _edit(Set<String> ids) async {
    await Navigator.of(context).push(MaterialPageRoute<bool>(
      builder: (_) => WorkProgramEditor(employeeIds: ids),
    ));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final employees = _store.activeEmployees;
    final shifts = _store.shiftMap;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Programe de lucru', 'Work programs'))),
      floatingActionButton: employees.isEmpty
          ? null
          : FloatingActionButton.extended(
              icon: const Icon(Icons.group_outlined),
              label: Text(tr('Program pentru mai mulți', 'Program for several')),
              onPressed: () => _edit(employees.map((e) => e.id).toSet()),
            ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 88),
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              tr('Alege programul fiecărui angajat o singură dată. Apoi, în „Grafic”, butonul '
                  '„Generează grafic” completează singur luna, păstrând excepțiile (concedii, zile libere).',
                  'Choose each employee\'s program once. Then, in “Schedule”, the “Generate schedule” '
                  'button fills in the month by itself, keeping the exceptions (leave, days off).'),
              style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
            ),
          ),
          for (final e in employees)
            ListTile(
              leading: Icon(
                _store.programOf(e.id) == null ? Icons.help_outline : Icons.event_repeat,
                color: _store.programOf(e.id) == null ? Colors.orange.shade800 : kTeal,
              ),
              title: Text(e.name),
              subtitle: Text(_store.programOf(e.id)?.describe(shifts) ??
                  tr('Fără program — nu intră în generare', 'No program — not generated')),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _edit({e.id}),
            ),
        ],
      ),
    );
  }
}

// ─── Editorul programului (pentru unul sau mai mulți angajați) ────────────────
class WorkProgramEditor extends StatefulWidget {
  final Set<String> employeeIds;
  const WorkProgramEditor({super.key, required this.employeeIds});

  @override
  State<WorkProgramEditor> createState() => _WorkProgramEditorState();
}

class _WorkProgramEditorState extends State<WorkProgramEditor> {
  final _store = Store.instance;

  late Set<String> _selected;
  PatternKind _kind = PatternKind.fixed;
  Set<int> _weekdays = {1, 2, 3, 4, 5};
  String? _fixedShift;
  int _rotationCount = 2;
  List<String?> _rotation = [null, null, null];
  int _rotateEvery = 7;
  List<String> _cycle = [];
  String? _preset;
  Set<String> _normShifts = {};
  DateTime _anchor = dayOf(DateTime.now());
  int _dailyHours = 8;
  bool _workHolidays = false;
  bool _stagger = true;

  @override
  void initState() {
    super.initState();
    _selected = Set.of(widget.employeeIds);
    final ids = _store.shifts.map((s) => s.id).toList();
    String? pick(String id) => ids.contains(id) ? id : (ids.isEmpty ? null : ids.first);
    _fixedShift = pick('s1');
    _rotation = [pick('s2'), pick('s3'), pick('s4')];
    _normShifts = {if (pick('s1') != null) pick('s1')!};
    _anchor = DateTime(_anchor.year, _anchor.month, 1);
    _applyPreset(CyclePreset.presets.first);

    // Un singur angajat cu program: formularul pornește de la programul lui.
    final existing = widget.employeeIds.length == 1 ? _store.programOf(widget.employeeIds.first) : null;
    if (existing != null) {
      _kind = existing.kind;
      _weekdays = Set.of(existing.weekdays);
      _anchor = existing.anchor;
      _dailyHours = existing.dailyMinutes ~/ 60;
      _workHolidays = existing.workHolidays;
      switch (existing.kind) {
        case PatternKind.fixed:
          _fixedShift = existing.shiftId;
        case PatternKind.rotating:
          _rotationCount = existing.shifts.length.clamp(2, 3);
          _rotation = [...existing.shifts.map<String?>((s) => s), null, null, null].take(3).toList();
          _rotateEvery = existing.rotateEveryDays;
        case PatternKind.cycle:
          _cycle = List.of(existing.cycle);
          _preset = null;
        case PatternKind.norm:
          _normShifts = Set.of(existing.shifts);
      }
    }
  }

  void _applyPreset(CyclePreset p) {
    final ids = _store.shifts.map((s) => s.id).toSet();
    _preset = p.name;
    _cycle = [for (final c in p.cycle) if (c == DayCode.off || ids.contains(c)) c];
  }

  String? _validate() {
    if (_selected.isEmpty) return tr('Alege cel puțin un angajat.', 'Choose at least one employee.');
    switch (_kind) {
      case PatternKind.fixed:
        if (_fixedShift == null) return tr('Alege tura.', 'Choose the shift.');
        if (_weekdays.isEmpty) return tr('Alege zilele lucrătoare.', 'Choose the working days.');
      case PatternKind.rotating:
        if (_rotation.take(_rotationCount).any((s) => s == null)) {
          return tr('Alege toate turele rotației.', 'Choose all shifts of the rotation.');
        }
        if (_weekdays.isEmpty) return tr('Alege zilele lucrătoare.', 'Choose the working days.');
      case PatternKind.cycle:
        if (!_cycle.any(DayCode.isShift)) {
          return tr('Ciclul trebuie să conțină cel puțin o tură.', 'The cycle must contain at least one shift.');
        }
      case PatternKind.norm:
        if (_normShifts.isEmpty) return tr('Alege cel puțin o tură.', 'Choose at least one shift.');
        if (_weekdays.isEmpty) return tr('Alege zilele în care poate lucra.', 'Choose the days they can work.');
    }
    return null;
  }

  Future<void> _save() async {
    final error = _validate();
    if (error != null) {
      showSnack(context, error, color: Colors.red.shade700);
      return;
    }
    final employees = _store.activeEmployees.where((e) => _selected.contains(e.id)).toList();
    final base = WorkProgram(
      kind: _kind,
      weekdays: Set.of(_weekdays),
      shiftId: _fixedShift ?? '',
      shifts: switch (_kind) {
        PatternKind.rotating => _rotation.take(_rotationCount).whereType<String>().toList(),
        PatternKind.norm => _store.shifts.map((s) => s.id).where(_normShifts.contains).toList(),
        _ => const <String>[],
      },
      rotateEveryDays: _rotateEvery,
      cycle: List.of(_cycle),
      anchor: _anchor,
      dailyMinutes: _dailyHours * 60,
      workHolidays: _workHolidays,
      updatedAt: DateTime.now(),
    );
    for (var i = 0; i < employees.length; i++) {
      final stagger = _stagger && employees.length > 1 ? i : 0;
      final p = switch (_kind) {
        // Ciclul fiecărui angajat începe cu o zi mai târziu.
        PatternKind.cycle => base.copyWith(anchor: DateTime(_anchor.year, _anchor.month, _anchor.day + stagger)),
        // Fiecare angajat începe rotația cu altă tură.
        PatternKind.rotating => base.copyWith(rotationOffset: stagger),
        _ => base,
      };
      await _store.setProgram(employees[i].id, p);
    }
    if (!mounted) return;
    showSnack(context, tr('Program salvat pentru ${employees.length} angajați. Generează graficul din „Grafic”.',
        'Program saved for ${employees.length} ${employees.length == 1 ? 'employee' : 'employees'}. Generate the schedule in “Schedule”.'));
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final employees = _store.activeEmployees;
    final shifts = _store.shifts;
    final wd = weekdayShortNames();

    Widget section(String title, List<Widget> children) => Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w700, color: kTealDark)),
                const SizedBox(height: 8),
                ...children,
              ],
            ),
          ),
        );

    Widget hint(String text) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(text, style: TextStyle(color: Colors.grey.shade700, fontSize: 13)),
        );

    Widget weekdayPicker() => Wrap(
          spacing: 6,
          children: [
            for (var d = 1; d <= 7; d++)
              FilterChip(
                label: Text(wd[d - 1]),
                selected: _weekdays.contains(d),
                onSelected: (v) => setState(() => v ? _weekdays.add(d) : _weekdays.remove(d)),
              ),
          ],
        );

    Widget shiftDropdown(String? value, ValueChanged<String?> onChanged, {String? label}) =>
        DropdownButtonFormField<String>(
          initialValue: shifts.any((s) => s.id == value) ? value : null,
          isExpanded: true,
          decoration: InputDecoration(labelText: label ?? tr('Tura', 'Shift'), border: const OutlineInputBorder()),
          items: [
            for (final s in shifts) DropdownMenuItem(value: s.id, child: Text('${s.name} · ${s.hoursLabel}')),
          ],
          onChanged: onChanged,
        );

    Widget anchorPicker(String label) => OutlinedButton.icon(
          icon: const Icon(Icons.event),
          label: Text('$label: ${fmtDate(_anchor)}'),
          onPressed: () async {
            final d = await pickDate(context, _anchor);
            if (d != null) setState(() => _anchor = dayOf(d));
          },
        );

    return Scaffold(
      appBar: AppBar(title: Text(tr('Program de lucru', 'Work program'))),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(
            icon: const Icon(Icons.save_outlined),
            label: Text(tr('Salvează programul', 'Save the program')),
            onPressed: _save,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          section(tr('Angajați', 'Employees'), [
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final e in employees)
                  FilterChip(
                    label: Text(e.name),
                    selected: _selected.contains(e.id),
                    onSelected: (v) => setState(() => v ? _selected.add(e.id) : _selected.remove(e.id)),
                  ),
              ],
            ),
          ]),
          section(tr('Tipul programului', 'Program type'), [
            DropdownButtonFormField<PatternKind>(
              initialValue: _kind,
              isExpanded: true,
              decoration: const InputDecoration(border: OutlineInputBorder()),
              items: [
                DropdownMenuItem(value: PatternKind.fixed, child: Text(tr('Program fix (ex. L–V 08–16)', 'Fixed hours (e.g. Mon–Fri 08–16)'))),
                DropdownMenuItem(value: PatternKind.rotating, child: Text(tr('Ture rotative (2 sau 3 ture)', 'Rotating shifts (2 or 3)'))),
                DropdownMenuItem(value: PatternKind.cycle, child: Text(tr('Ciclu continuu (12/24, 24/72...)', 'Continuous cycle (12/24, 24/72...)'))),
                DropdownMenuItem(value: PatternKind.norm, child: Text(tr('Normă lunară automată', 'Automatic monthly norm'))),
              ],
              onChanged: (v) => setState(() => _kind = v ?? _kind),
            ),
            const SizedBox(height: 12),
            ...switch (_kind) {
              PatternKind.fixed => [
                  hint(tr('Aceeași tură în zilele alese.', 'The same shift on the chosen days.')),
                  shiftDropdown(_fixedShift, (v) => setState(() => _fixedShift = v)),
                  const SizedBox(height: 10),
                  weekdayPicker(),
                ],
              PatternKind.rotating => [
                  hint(tr('Turele se schimbă prin rotație (ex. o săptămână dimineața, una după-amiaza).',
                      'Shifts change in rotation (e.g. one week mornings, one week afternoons).')),
                  SegmentedButton<int>(
                    segments: [
                      ButtonSegment(value: 2, label: Text(tr('2 ture', '2 shifts'))),
                      ButtonSegment(value: 3, label: Text(tr('3 ture', '3 shifts'))),
                    ],
                    selected: {_rotationCount},
                    onSelectionChanged: (s) => setState(() => _rotationCount = s.first),
                  ),
                  const SizedBox(height: 10),
                  for (var i = 0; i < _rotationCount; i++) ...[
                    shiftDropdown(_rotation[i], (v) => setState(() => _rotation[i] = v),
                        label: tr('Tura ${i + 1} din rotație', 'Rotation shift ${i + 1}')),
                    const SizedBox(height: 8),
                  ],
                  DropdownButtonFormField<int>(
                    initialValue: _rotateEvery,
                    decoration: InputDecoration(labelText: tr('Schimbarea turei', 'Shift change'), border: const OutlineInputBorder()),
                    items: [
                      for (final n in const [1, 2, 3, 4, 5, 6, 7, 14])
                        DropdownMenuItem(
                          value: n,
                          child: Text(n == 7
                              ? tr('Săptămânal (luni)', 'Weekly (Monday)')
                              : n == 14
                                  ? tr('La două săptămâni', 'Every two weeks')
                                  : tr('La fiecare $n ${n == 1 ? 'zi' : 'zile'}', 'Every $n ${n == 1 ? 'day' : 'days'}')),
                        ),
                    ],
                    onChanged: (v) => setState(() => _rotateEvery = v ?? 7),
                  ),
                  const SizedBox(height: 10),
                  weekdayPicker(),
                  const SizedBox(height: 10),
                  anchorPicker(tr('Rotația începe din', 'Rotation starts on')),
                ],
              PatternKind.cycle => [
                  hint(tr('Ciclu continuu, inclusiv în weekend. Continuă singur de la o lună la alta.',
                      'Continuous cycle, weekends included. It carries on by itself from one month to the next.')),
                  Wrap(
                    spacing: 6,
                    children: [
                      for (final p in CyclePreset.presets)
                        ChoiceChip(
                          label: Text(p.name),
                          selected: _preset == p.name,
                          onSelected: (_) => setState(() => _applyPreset(p)),
                        ),
                      ChoiceChip(
                        label: Text(tr('Personalizat', 'Custom')),
                        selected: _preset == null,
                        onSelected: (_) => setState(() => _preset = null),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(tr('Secvența (atinge o zi ca s-o scoți):', 'Sequence (tap a day to remove it):'),
                      style: const TextStyle(fontSize: 13)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      for (var i = 0; i < _cycle.length; i++)
                        InkWell(
                          onTap: () => setState(() {
                            _cycle.removeAt(i);
                            _preset = null;
                          }),
                          child: dayCodeChip(_cycle[i], _store.shiftMap),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final s in shifts)
                        ActionChip(
                          avatar: DayChip(label: s.shortLabel, color: shiftColor(s), width: 24, height: 20),
                          label: Text(s.name),
                          onPressed: () => setState(() {
                            _cycle.add(s.id);
                            _preset = null;
                          }),
                        ),
                      ActionChip(
                        avatar: DayChip(label: DayCode.short(DayCode.off), color: dayCodeColor(DayCode.off), width: 24, height: 20),
                        label: Text(DayCode.label(DayCode.off)),
                        onPressed: () => setState(() {
                          _cycle.add(DayCode.off);
                          _preset = null;
                        }),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  anchorPicker(tr('Prima zi a ciclului', 'First day of the cycle')),
                ],
              PatternKind.norm => [
                  hint(tr('Aplicația pune singură în fiecare lună atâtea ture cât să acopere norma legală '
                      '(zilele lucrătoare × norma zilnică, minus concediile), cu zile libere între ele. '
                      'Potrivit pentru gărzi, ture de 12h sau program flexibil.',
                      'Each month the app places enough shifts to cover the legal norm (working days × '
                      'daily norm, minus leave), with days off in between. Good for duties, 12h shifts '
                      'or flexible hours.')),
                  Text(tr('Turele folosite (pe rând):', 'Shifts used (in turn):'), style: const TextStyle(fontSize: 13)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final s in shifts)
                        FilterChip(
                          avatar: DayChip(label: s.shortLabel, color: shiftColor(s), width: 24, height: 20),
                          label: Text('${s.name} ${s.hoursLabel}'),
                          selected: _normShifts.contains(s.id),
                          onSelected: (v) => setState(() => v ? _normShifts.add(s.id) : _normShifts.remove(s.id)),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(tr('Zilele în care poate lucra:', 'Days they can work:'), style: const TextStyle(fontSize: 13)),
                  const SizedBox(height: 6),
                  weekdayPicker(),
                ],
            },
            if (_kind != PatternKind.fixed && _kind != PatternKind.norm && _selected.length > 1)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(tr('Decalează angajații', 'Stagger the employees')),
                subtitle: Text(_kind == PatternKind.rotating
                    ? tr('Fiecare angajat începe cu altă tură, ca turele să fie acoperite.',
                        'Each employee starts with a different shift, so all shifts are covered.')
                    : tr('Fiecare angajat începe ciclul cu o zi mai târziu.',
                        'Each employee starts the cycle one day later.')),
                value: _stagger,
                onChanged: (v) => setState(() => _stagger = v),
              ),
          ]),
          section(tr('Norma și sărbătorile', 'Norm and holidays'), [
            DropdownButtonFormField<int>(
              initialValue: _dailyHours,
              decoration: InputDecoration(
                labelText: tr('Norma zilnică', 'Daily norm'),
                helperText: tr('Norma lunară = zilele lucrătoare din lună × norma zilnică.',
                    'Monthly norm = working days in the month × daily norm.'),
                border: const OutlineInputBorder(),
              ),
              items: [
                for (final h in const [8, 7, 6, 5, 4, 2])
                  DropdownMenuItem(
                    value: h,
                    child: Text(h == 8
                        ? tr('8 ore (normă întreagă)', '8 hours (full time)')
                        : tr('$h ore (timp parțial)', '$h hours (part time)')),
                  ),
              ],
              onChanged: (v) => setState(() => _dailyHours = v ?? 8),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tr('Lucrează și în sărbătorile legale', 'Works on public holidays too')),
              subtitle: Text(tr('Pentru servicii continue (gărzi, pază). Altfel sărbătorile sunt libere (SL).',
                  'For continuous services (duties, security). Otherwise holidays are off (PH).')),
              value: _workHolidays,
              onChanged: (v) => setState(() => _workHolidays = v),
            ),
          ]),
        ],
      ),
    );
  }
}
