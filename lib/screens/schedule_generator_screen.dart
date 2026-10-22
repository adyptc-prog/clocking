import 'package:flutter/material.dart';

import '../l10n.dart';
import '../src/models.dart';
import '../src/schedule_gen.dart';
import '../src/store.dart';
import '../src/ui.dart';
import 'schedule_screen.dart';

// ─── Generatorul de grafic: selecția managerului → graficul pe perioadă ──────
class ScheduleGeneratorScreen extends StatefulWidget {
  final DateTime month;
  const ScheduleGeneratorScreen({super.key, required this.month});

  @override
  State<ScheduleGeneratorScreen> createState() => _ScheduleGeneratorScreenState();
}

class _ScheduleGeneratorScreenState extends State<ScheduleGeneratorScreen> {
  final _store = Store.instance;

  late Set<String> _selected;
  late DateTime _from;
  late DateTime _to;
  PatternKind _kind = PatternKind.fixed;

  // Program fix
  final Set<int> _weekdays = {1, 2, 3, 4, 5};
  String? _fixedShift;

  // Ture rotative
  int _rotationCount = 2;
  List<String?> _rotation = [null, null, null];
  int _rotateEvery = 7;

  // Ciclu continuu
  List<String> _cycle = [];
  String? _preset;

  // Decalarea angajaților între ei (ture rotative / ciclu).
  bool _stagger = false;

  final Set<DateTime> _daysOff = {};
  final List<LeaveChoice> _leaves = [];
  bool _holidays = true;

  @override
  void initState() {
    super.initState();
    _selected = _store.activeEmployees.map((e) => e.id).toSet();
    _from = DateTime(widget.month.year, widget.month.month, 1);
    _to = DateTime(widget.month.year, widget.month.month + 1, 0);
    final ids = _store.shifts.map((s) => s.id).toList();
    String? pick(String id, int fallback) =>
        ids.contains(id) ? id : (ids.length > fallback ? ids[fallback] : (ids.isEmpty ? null : ids.first));
    _fixedShift = pick('s1', 0);
    _rotation = [pick('s2', 0), pick('s3', 0), pick('s4', 0)];
    _applyPreset(CyclePreset.presets.first);
  }

  void _applyPreset(CyclePreset p) {
    final ids = _store.shifts.map((s) => s.id).toSet();
    _preset = p.name;
    // Turele presetului (zi/noapte 12h, gardă 24h) există dacă n-au fost șterse.
    _cycle = [
      for (final c in p.cycle)
        if (c == DayCode.off || ids.contains(c)) c,
    ];
  }

  String _label(String code) {
    if (code == DayCode.off) return DayCode.short(code);
    return _store.shiftMap[code]?.shortLabel ?? '?';
  }

  ScheduleRequest _request(int employeeIndex, String employeeId) {
    final offset = _stagger ? employeeIndex : 0;
    return ScheduleRequest(
      kind: _kind,
      from: _from,
      to: _to,
      weekdays: _weekdays,
      shiftId: _fixedShift ?? '',
      rotationShifts: _rotation.take(_rotationCount).whereType<String>().toList(),
      rotateEveryDays: _rotateEvery,
      startOffset: offset,
      cycle: _cycle,
      extraDaysOff: _daysOff,
      leaves: [
        for (final l in _leaves)
          if (l.employee.id == employeeId) leaveRangeOf(l),
      ],
      legalHolidays: _holidays,
    );
  }

  String? _validate() {
    if (_selected.isEmpty) return tr('Alege cel puțin un angajat.', 'Choose at least one employee.');
    if (_to.isBefore(_from)) return tr('Perioada nu e validă.', 'The period is not valid.');
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
    }
    return null;
  }

  Future<void> _generate() async {
    final error = _validate();
    if (error != null) {
      showSnack(context, error, color: Colors.red.shade700);
      return;
    }
    final ok = await confirmDialog(
      context,
      title: tr('Generezi graficul?', 'Generate the schedule?'),
      message: tr(
          'Zilele ${fmtDate(_from)} – ${fmtDate(_to)} ale celor ${_selected.length} angajați aleși '
              'vor fi înlocuite. Restul zilelor rămân neschimbate.',
          'Days ${fmtDate(_from)} – ${fmtDate(_to)} of the ${_selected.length} chosen employees '
              'will be replaced. All other days stay unchanged.'),
      confirm: tr('Generează', 'Generate'),
    );
    if (!ok) return;
    final employees = _store.activeEmployees.where((e) => _selected.contains(e.id)).toList();
    for (var i = 0; i < employees.length; i++) {
      final days = generateSchedule(_request(i, employees[i].id));
      await _store.setScheduleDays(employees[i].id, days);
    }
    if (!mounted) return;
    showSnack(context, tr('Grafic generat pentru ${employees.length} angajați.',
        'Schedule generated for ${employees.length} ${employees.length == 1 ? 'employee' : 'employees'}.'));
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
          initialValue: value,
          isExpanded: true,
          decoration: InputDecoration(labelText: label ?? tr('Tura', 'Shift'), border: const OutlineInputBorder()),
          items: [
            for (final s in shifts)
              DropdownMenuItem(value: s.id, child: Text('${s.name} · ${s.hoursLabel}')),
          ],
          onChanged: onChanged,
        );

    return Scaffold(
      appBar: AppBar(title: Text(tr('Generează grafic', 'Generate schedule'))),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(
            icon: const Icon(Icons.auto_awesome),
            label: Text(tr('Generează', 'Generate')),
            onPressed: _generate,
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
                ActionChip(
                  label: Text(_selected.length == employees.length ? tr('Niciunul', 'None') : tr('Toți', 'All')),
                  onPressed: () => setState(() {
                    _selected = _selected.length == employees.length
                        ? {}
                        : employees.map((e) => e.id).toSet();
                  }),
                ),
                for (final e in employees)
                  FilterChip(
                    label: Text(e.name),
                    selected: _selected.contains(e.id),
                    onSelected: (v) => setState(() => v ? _selected.add(e.id) : _selected.remove(e.id)),
                  ),
              ],
            ),
          ]),
          section(tr('Perioada', 'Period'), [
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () async {
                      final d = await pickDate(context, _from);
                      if (d != null) setState(() => _from = dayOf(d));
                    },
                    child: Text('${tr('De la', 'From')} ${fmtDate(_from)}'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () async {
                      final d = await pickDate(context, _to);
                      if (d != null) setState(() => _to = dayOf(d));
                    },
                    child: Text('${tr('Până la', 'To')} ${fmtDate(_to)}'),
                  ),
                ),
              ],
            ),
          ]),
          section(tr('Tipul programului', 'Schedule type'), [
            SegmentedButton<PatternKind>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(value: PatternKind.fixed, label: Text(tr('Fix', 'Fixed'))),
                ButtonSegment(value: PatternKind.rotating, label: Text(tr('Ture rotative', 'Rotating'))),
                ButtonSegment(value: PatternKind.cycle, label: Text(tr('Ciclu', 'Cycle'))),
              ],
              selected: {_kind},
              onSelectionChanged: (s) => setState(() => _kind = s.first),
            ),
            const SizedBox(height: 12),
            ...switch (_kind) {
              PatternKind.fixed => [
                  Text(tr('Aceeași tură în zilele alese (ex. luni–vineri 08–16).',
                      'The same shift on the chosen days (e.g. Monday–Friday 08–16).'),
                      style: TextStyle(color: Colors.grey.shade700, fontSize: 13)),
                  const SizedBox(height: 10),
                  shiftDropdown(_fixedShift, (v) => setState(() => _fixedShift = v)),
                  const SizedBox(height: 10),
                  weekdayPicker(),
                ],
              PatternKind.rotating => [
                  Text(tr('Turele se schimbă prin rotație (ex. o săptămână dimineața, una după-amiaza).',
                      'Shifts change in rotation (e.g. one week mornings, one week afternoons).'),
                      style: TextStyle(color: Colors.grey.shade700, fontSize: 13)),
                  const SizedBox(height: 10),
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
                    decoration: InputDecoration(
                        labelText: tr('Schimbarea turei', 'Shift change'), border: const OutlineInputBorder()),
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
                ],
              PatternKind.cycle => [
                  Text(tr('Ciclu continuu, inclusiv în weekend (ex. 12/24: zi, noapte, liber).',
                      'Continuous cycle, weekends included (e.g. 12/24: day, night, off).'),
                      style: TextStyle(color: Colors.grey.shade700, fontSize: 13)),
                  const SizedBox(height: 10),
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
                      if (_cycle.isEmpty)
                        Text(tr('gol', 'empty'), style: TextStyle(color: Colors.grey.shade500)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(tr('Adaugă în secvență:', 'Add to the sequence:'), style: const TextStyle(fontSize: 13)),
                  const SizedBox(height: 6),
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
                        avatar: DayChip(label: _label(DayCode.off), color: dayCodeColor(DayCode.off), width: 24, height: 20),
                        label: Text(DayCode.label(DayCode.off)),
                        onPressed: () => setState(() {
                          _cycle.add(DayCode.off);
                          _preset = null;
                        }),
                      ),
                    ],
                  ),
                ],
            },
            if (_kind != PatternKind.fixed && _selected.length > 1) ...[
              const SizedBox(height: 8),
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
            ],
          ]),
          section(tr('Zile libere și concedii', 'Days off and leave'), [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tr('Sărbători legale (România)', 'Public holidays (Romania)')),
              subtitle: Text(tr('Marcate „SL”, libere pentru toți.', 'Marked “PH”, off for everyone.')),
              value: _holidays,
              onChanged: (v) => setState(() => _holidays = v),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final d in (_daysOff.toList()..sort()))
                  InputChip(
                    label: Text(fmtDate(d)),
                    onDeleted: () => setState(() => _daysOff.remove(d)),
                  ),
                ActionChip(
                  avatar: const Icon(Icons.add, size: 18),
                  label: Text(tr('Zi liberă pentru toți', 'Day off for everyone')),
                  onPressed: () async {
                    final d = await pickDate(context, _from);
                    if (d != null) setState(() => _daysOff.add(dayOf(d)));
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
            for (var i = 0; i < _leaves.length; i++)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: DayChip(label: DayCode.short(_leaves[i].code), color: dayCodeColor(_leaves[i].code)),
                title: Text(_leaves[i].employee.name),
                subtitle: Text('${DayCode.label(_leaves[i].code)} · ${fmtDate(_leaves[i].from)} – ${fmtDate(_leaves[i].to)}'),
                trailing: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() => _leaves.removeAt(i)),
                ),
              ),
            OutlinedButton.icon(
              icon: const Icon(Icons.beach_access_outlined),
              label: Text(tr('Adaugă concediu pentru un angajat', 'Add leave for an employee')),
              onPressed: () async {
                final chosen = employees.where((e) => _selected.contains(e.id)).toList();
                if (chosen.isEmpty) return;
                final r = await showLeaveDialog(context, chosen);
                if (r != null) setState(() => _leaves.add(r));
              },
            ),
          ]),
        ],
      ),
    );
  }
}
