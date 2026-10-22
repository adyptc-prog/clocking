import 'package:flutter/material.dart';

import '../l10n.dart';
import '../src/models.dart';
import '../src/store.dart';
import '../src/ui.dart';

// ─── Turele: nume, ore, culoare ───────────────────────────────────────────────
class ShiftsScreen extends StatefulWidget {
  const ShiftsScreen({super.key});

  @override
  State<ShiftsScreen> createState() => _ShiftsScreenState();
}

class _ShiftsScreenState extends State<ShiftsScreen> {
  final _store = Store.instance;

  Future<void> _edit({Shift? existing}) async {
    final name = TextEditingController(text: existing?.name ?? '');
    var start = existing?.start ?? 8 * 60;
    var end = existing?.end ?? 16 * 60;
    var color = existing?.color ?? _store.shifts.length % kShiftPalette.length;
    String? error;

    TimeOfDay tod(int m) => TimeOfDay(hour: (m ~/ 60) % 24, minute: m % 60);

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDs) {
          final preview = Shift(id: '', name: name.text.isEmpty ? '?' : name.text, start: start, end: end, color: color);
          return AlertDialog(
            title: Text(existing == null ? tr('Tură nouă', 'New shift') : tr('Editează tura', 'Edit shift')),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: name,
                    textCapitalization: TextCapitalization.sentences,
                    onChanged: (_) => setDs(() {}),
                    decoration: InputDecoration(
                      labelText: tr('Nume', 'Name'),
                      hintText: tr('ex. Dimineață', 'e.g. Morning'),
                      errorText: error,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () async {
                            final t = await pickTime(ctx, tod(start));
                            if (t != null) setDs(() => start = t.hour * 60 + t.minute);
                          },
                          child: Text('${tr('Început', 'Start')} ${fmtMinutes(start)}'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () async {
                            final t = await pickTime(ctx, tod(end));
                            if (t != null) setDs(() => end = t.hour * 60 + t.minute);
                          },
                          child: Text('${tr('Sfârșit', 'End')} ${fmtMinutes(end)}'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    tr('Durata: ${fmtDuration(Duration(minutes: preview.durationMinutes))} h'
                        '${preview.crossesMidnight ? ' (trece de miezul nopții)' : ''}',
                        'Length: ${fmtDuration(Duration(minutes: preview.durationMinutes))} h'
                        '${preview.crossesMidnight ? ' (past midnight)' : ''}'),
                    style: TextStyle(color: Colors.grey.shade700, fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (var i = 0; i < kShiftPalette.length; i++)
                        InkWell(
                          onTap: () => setDs(() => color = i),
                          child: Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: Color(kShiftPalette[i]),
                              shape: BoxShape.circle,
                              border: Border.all(
                                  color: color == i ? Colors.black : Colors.transparent, width: 3),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Anulează', 'Cancel'))),
              FilledButton(
                onPressed: () {
                  if (name.text.trim().isEmpty) {
                    setDs(() => error = tr('Introdu numele.', 'Enter the name.'));
                    return;
                  }
                  Navigator.pop(ctx, true);
                },
                child: Text(tr('Salvează', 'Save')),
              ),
            ],
          );
        },
      ),
    );
    if (ok != true) return;
    final list = List.of(_store.shifts);
    if (existing == null) {
      list.add(Shift(id: _store.nextShiftId(), name: name.text.trim(), start: start, end: end, color: color));
    } else {
      final i = list.indexWhere((s) => s.id == existing.id);
      list[i] = existing.copyWith(name: name.text.trim(), start: start, end: end, color: color);
    }
    await _store.saveShifts(list);
    if (mounted) setState(() {});
  }

  Future<void> _delete(Shift s) async {
    final ok = await confirmDialog(
      context,
      title: tr('Ștergi tura „${s.name}”?', 'Delete the shift “${s.name}”?'),
      message: tr('Zilele din grafic cu această tură vor apărea ca „?” până le schimbi.',
          'Schedule days with this shift will show “?” until you change them.'),
      confirm: tr('Șterge', 'Delete'),
      destructive: true,
    );
    if (!ok) return;
    await _store.saveShifts(_store.shifts.where((x) => x.id != s.id).toList());
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final shifts = _store.shifts;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Ture și ore', 'Shifts and hours'))),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: Text(tr('Tură nouă', 'New shift')),
        onPressed: () => _edit(),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 88),
        children: [
          for (final s in shifts)
            ListTile(
              leading: DayChip(label: s.shortLabel, color: shiftColor(s)),
              title: Text(s.name),
              subtitle: Text('${s.hoursLabel} · ${fmtDuration(Duration(minutes: s.durationMinutes))} h'),
              onTap: () => _edit(existing: s),
              trailing: IconButton(
                icon: Icon(Icons.delete_outline, color: Colors.red.shade400),
                onPressed: () => _delete(s),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              tr('Turele sunt folosite de graficul de lucru și de rapoarte (întârzieri, plecări '
                  'devreme, ore peste program). Se sincronizează cu telefonul partener.',
                  'Shifts are used by the work schedule and by reports (late arrivals, early '
                  'departures, overtime). They sync with the partner phone.'),
              style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
