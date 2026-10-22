import 'package:flutter/material.dart';

import '../l10n.dart';
import '../src/models.dart';
import '../src/report.dart';
import '../src/store.dart';
import '../src/ui.dart';

// ─── Prezența pe o zi: cine a venit, cine lipsește, corecturi manuale ─────────
class AttendanceScreen extends StatefulWidget {
  const AttendanceScreen({super.key});

  @override
  State<AttendanceScreen> createState() => _AttendanceScreenState();
}

class _AttendanceScreenState extends State<AttendanceScreen> {
  final _store = Store.instance;
  DateTime _day = dayOf(DateTime.now());
  Map<String, List<Punch>> _byEmployee = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _store.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    _store.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    // O tură de noapte începută ieri și terminată azi apare la ziua intrării.
    final punches = await _store.punchesBetween(_day, _day.add(const Duration(days: 1)));
    await _store.ensureSchedules(_day, _day);
    final map = <String, List<Punch>>{};
    for (final p in punches) {
      map.putIfAbsent(p.employeeId, () => []).add(p);
    }
    if (!mounted) return;
    setState(() {
      _byEmployee = map;
      _loading = false;
    });
  }

  void _shiftDay(int delta) {
    setState(() => _day = DateTime(_day.year, _day.month, _day.day + delta));
    _load();
  }

  // Sesiunile care încep în ziua aleasă.
  List<WorkSession> _sessions(String employeeId) =>
      buildSessions(_byEmployee[employeeId] ?? const [], now: DateTime.now())
          .where((s) => dayOf(s.anchor) == _day)
          .toList();

  @override
  Widget build(BuildContext context) {
    final employees = _store.employees.where((e) => e.active).toList();
    final isToday = _day == dayOf(DateTime.now());
    final shifts = _store.shiftMap;
    var present = 0;
    for (final e in employees) {
      if (_sessions(e.id).isNotEmpty) present++;
    }

    return Column(
      children: [
        Material(
          color: Colors.white,
          elevation: 1,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Row(
              children: [
                IconButton(icon: const Icon(Icons.chevron_left), onPressed: () => _shiftDay(-1)),
                Expanded(
                  child: InkWell(
                    onTap: () async {
                      final d = await pickDate(context, _day);
                      if (d != null) {
                        setState(() => _day = dayOf(d));
                        _load();
                      }
                    },
                    child: Column(
                      children: [
                        Text(
                          isToday ? tr('Azi', 'Today') : weekdayShortNames()[_day.weekday - 1],
                          style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                        ),
                        Text(fmtDate(_day),
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                ),
                IconButton(icon: const Icon(Icons.chevron_right), onPressed: () => _shiftDay(1)),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: Row(
            children: [
              Icon(Icons.groups_outlined, color: kTeal, size: 20),
              const SizedBox(width: 6),
              Text(tr('Prezenți: $present din ${employees.length}', 'Present: $present of ${employees.length}'),
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ],
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : employees.isEmpty
                  ? Center(child: Text(tr('Niciun angajat activ.', 'No active employees.')))
                  : ListView.separated(
                      padding: const EdgeInsets.only(bottom: 80),
                      itemCount: employees.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final e = employees[i];
                        final sessions = _sessions(e.id);
                        final code = _store.scheduleCode(e.id, _day);
                        return ListTile(
                          leading: _statusIcon(sessions, code),
                          title: Text(e.name),
                          subtitle: Text(_describe(sessions, code, shifts)),
                          trailing: dayCodeChip(code, shifts),
                          onTap: () => _openDay(e),
                        );
                      },
                    ),
        ),
      ],
    );
  }

  Widget _statusIcon(List<WorkSession> sessions, String code) {
    if (sessions.any((s) => s.ongoing)) {
      return Icon(Icons.radio_button_checked, color: Colors.green.shade600);
    }
    if (sessions.any((s) => s.incomplete)) {
      return Icon(Icons.warning_amber_rounded, color: Colors.orange.shade800);
    }
    if (sessions.isNotEmpty) return Icon(Icons.check_circle, color: Colors.blue.shade600);
    if (DayCode.isShift(code) && _day.isBefore(dayOf(DateTime.now()))) {
      return Icon(Icons.cancel, color: Colors.red.shade600);
    }
    return Icon(Icons.radio_button_unchecked, color: Colors.grey.shade400);
  }

  String _describe(List<WorkSession> sessions, String code, Map<String, Shift> shifts) {
    if (sessions.isEmpty) {
      if (DayCode.isShift(code)) {
        final s = shifts[code];
        return tr('Nu a pontat · programat ${s?.hoursLabel ?? ''}', 'No clocking · scheduled ${s?.hoursLabel ?? ''}');
      }
      return code.isEmpty ? tr('Nu a pontat', 'No clocking') : DayCode.label(code);
    }
    final parts = sessions.map((s) {
      final a = s.start == null ? '—' : fmtTime(s.start!);
      final b = s.end == null ? (s.ongoing ? tr('acum', 'now') : '—') : fmtTime(s.end!);
      return '$a–$b';
    }).join(', ');
    final worked = sessions.fold(Duration.zero, (d, s) => d + s.duration);
    return '$parts · ${fmtDuration(worked)} h';
  }

  Future<void> _openDay(Employee e) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => DayPunchesScreen(employee: e, day: _day),
    ));
    _load();
  }
}

// ─── Pontajele unui angajat într-o zi: adăugare, corectare, ștergere ──────────
class DayPunchesScreen extends StatefulWidget {
  final Employee employee;
  final DateTime day;

  const DayPunchesScreen({super.key, required this.employee, required this.day});

  @override
  State<DayPunchesScreen> createState() => _DayPunchesScreenState();
}

class _DayPunchesScreenState extends State<DayPunchesScreen> {
  final _store = Store.instance;
  List<Punch> _punches = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await _store.punchesBetween(widget.day, widget.day, employeeId: widget.employee.id);
    if (mounted) setState(() => _punches = list);
  }

  Future<void> _edit({Punch? existing}) async {
    var type = existing?.type ??
        (_punches.isNotEmpty && _punches.last.isIn ? PunchType.clockOut : PunchType.clockIn);
    var time = existing == null
        ? TimeOfDay.fromDateTime(DateTime.now())
        : TimeOfDay.fromDateTime(existing.at);
    var date = existing == null ? widget.day : dayOf(existing.at);
    final note = TextEditingController(text: existing?.note ?? '');

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDs) => AlertDialog(
          title: Text(existing == null ? tr('Adaugă pontaj', 'Add clocking') : tr('Corectează pontajul', 'Edit clocking')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<PunchType>(
                segments: [
                  ButtonSegment(value: PunchType.clockIn, icon: const Icon(Icons.login), label: Text(tr('Intrare', 'In'))),
                  ButtonSegment(value: PunchType.clockOut, icon: const Icon(Icons.logout), label: Text(tr('Ieșire', 'Out'))),
                ],
                selected: {type},
                onSelectionChanged: (s) => setDs(() => type = s.first),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.event),
                      label: Text(fmtDate(date)),
                      onPressed: () async {
                        final d = await pickDate(ctx, date);
                        if (d != null) setDs(() => date = dayOf(d));
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.schedule),
                      label: Text('${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}'),
                      onPressed: () async {
                        final t = await pickTime(ctx, time);
                        if (t != null) setDs(() => time = t);
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: note,
                decoration: InputDecoration(
                  labelText: tr('Motiv / notă (opțional)', 'Reason / note (optional)'),
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Anulează', 'Cancel'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Salvează', 'Save'))),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final at = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    if (existing == null) {
      await _store.addPunch(
        employeeId: widget.employee.id,
        at: at,
        type: type,
        source: PunchSource.manual,
        note: note.text.trim(),
      );
    } else {
      await _store.updatePunch(existing.copyWith(
        at: at,
        type: type,
        note: note.text.trim(),
        source: existing.source == PunchSource.manual ? PunchSource.manual : PunchSource.corrected,
      ));
    }
    await _load();
  }

  Future<void> _delete(Punch p) async {
    final ok = await confirmDialog(
      context,
      title: tr('Ștergi pontajul?', 'Delete the clocking?'),
      message: '${p.isIn ? tr('Intrare', 'In') : tr('Ieșire', 'Out')} ${fmtDateTime(p.at)}',
      confirm: tr('Șterge', 'Delete'),
      destructive: true,
    );
    if (!ok) return;
    await _store.deletePunch(p);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.employee.name} · ${fmtDate(widget.day)}'),
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: Text(tr('Pontaj manual', 'Manual clocking')),
        onPressed: () => _edit(),
      ),
      body: _punches.isEmpty
          ? Center(child: Text(tr('Niciun pontaj în această zi.', 'No clockings on this day.')))
          : ListView(
              padding: const EdgeInsets.only(bottom: 80),
              children: [
                for (final p in _punches)
                  ListTile(
                    leading: Icon(p.isIn ? Icons.login : Icons.logout,
                        color: p.isIn ? Colors.green.shade700 : Colors.blue.shade700),
                    title: Text('${p.isIn ? tr('Intrare', 'In') : tr('Ieșire', 'Out')} · ${fmtTime(p.at)}'),
                    subtitle: Text([
                      switch (p.source) {
                        PunchSource.manual => tr('adăugat manual', 'added manually'),
                        PunchSource.corrected => tr('corectat', 'edited'),
                        _ => tr('scanare', 'scan'),
                      },
                      if (p.note.isNotEmpty) p.note,
                    ].join(' · ')),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(icon: const Icon(Icons.edit_outlined), onPressed: () => _edit(existing: p)),
                        IconButton(
                          icon: Icon(Icons.delete_outline, color: Colors.red.shade400),
                          onPressed: () => _delete(p),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}
