import 'package:flutter/material.dart';

import '../l10n.dart';
import '../src/store.dart';
import '../src/ui.dart';
import 'shifts_screen.dart';

// ─── Setări ───────────────────────────────────────────────────────────────────
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _store = Store.instance;
  late final TextEditingController _company;
  late int _tolerance;
  late int _duplicate;

  @override
  void initState() {
    super.initState();
    _company = TextEditingController(text: _store.companyName);
    _tolerance = _store.lateToleranceMinutes;
    _duplicate = _store.duplicateWindowMinutes;
  }

  @override
  void dispose() {
    _company.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await _store.saveSettings(
      companyName: _company.text,
      lateToleranceMinutes: _tolerance,
      duplicateWindowMinutes: _duplicate,
    );
    if (mounted) showSnack(context, tr('Setări salvate.', 'Settings saved.'));
  }

  Future<void> _changePin() async {
    final pin = await askPin(context,
        title: _store.hasPin ? tr('PIN nou', 'New PIN') : tr('Setează PIN-ul managerului', 'Set the manager PIN'),
        confirm: true,
        message: tr('Cu PIN, pe telefonul de la intrare angajații văd doar ecranul de pontaj.',
            'With a PIN, employees only see the clocking screen on the entrance phone.'));
    if (pin == null) return;
    await _store.setPin(pin);
    if (mounted) {
      setState(() {});
      showSnack(context, tr('PIN salvat.', 'PIN saved.'));
    }
  }

  Future<void> _removePin() async {
    final ok = await confirmDialog(context,
        title: tr('Elimini PIN-ul?', 'Remove the PIN?'),
        message: tr('Oricine va putea deschide angajații, graficul și rapoartele.',
            'Anyone will be able to open employees, schedules and reports.'),
        confirm: tr('Elimină', 'Remove'),
        destructive: true);
    if (!ok) return;
    await _store.setPin(null);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    Widget minutes(String label, String help, int value, List<int> options, ValueChanged<int> onChanged) =>
        ListTile(
          title: Text(label),
          subtitle: Text(help),
          trailing: DropdownButton<int>(
            value: options.contains(value) ? value : options.first,
            items: [for (final o in options) DropdownMenuItem(value: o, child: Text('$o min'))],
            onChanged: (v) => setState(() => onChanged(v ?? value)),
          ),
        );

    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Setări', 'Settings')),
        actions: [
          TextButton(
            onPressed: _save,
            style: TextButton.styleFrom(foregroundColor: Colors.white),
            child: Text(tr('Salvează', 'Save')),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _company,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                labelText: tr('Numele firmei / cabinetului', 'Business name'),
                helperText: tr('Apare pe cardurile QR, în rapoarte și în grafic.', 'Shown on QR cards, reports and schedules.'),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          minutes(
            tr('Toleranță întârziere', 'Lateness tolerance'),
            tr('Sub această limită, venirea după începutul turei nu e întârziere.',
                'Arriving after the shift start within this limit is not late.'),
            _tolerance,
            const [0, 5, 10, 15, 20, 30],
            (v) => _tolerance = v,
          ),
          minutes(
            tr('Scanare dublă ignorată', 'Double scan ignored'),
            tr('O nouă scanare a aceluiași angajat în acest interval nu se înregistrează.',
                'Another scan by the same employee within this time is not recorded.'),
            _duplicate,
            const [1, 2, 5, 10, 15],
            (v) => _duplicate = v,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: FilledButton(onPressed: _save, child: Text(tr('Salvează', 'Save'))),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.schedule),
            title: Text(tr('Ture și ore', 'Shifts and hours')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ShiftsScreen())),
          ),
          const Divider(),
          ListTile(
            leading: Icon(_store.hasPin ? Icons.lock_outline : Icons.lock_open, color: kTeal),
            title: Text(_store.hasPin ? tr('PIN manager activ', 'Manager PIN active') : tr('Fără PIN manager', 'No manager PIN')),
            subtitle: Text(tr('Protejează angajații, graficul, rapoartele și setările.',
                'Protects employees, schedules, reports and settings.')),
            trailing: TextButton(
              onPressed: _changePin,
              child: Text(_store.hasPin ? tr('Schimbă', 'Change') : tr('Setează', 'Set')),
            ),
          ),
          if (_store.hasPin)
            ListTile(
              leading: const SizedBox(),
              title: Text(tr('Elimină PIN-ul', 'Remove the PIN'), style: TextStyle(color: Colors.red.shade700)),
              onTap: _removePin,
            ),
          const Divider(),
          SwitchListTile(
            secondary: const Icon(Icons.camera_front_outlined),
            title: Text(tr('Camera frontală pentru scanare', 'Front camera for scanning')),
            subtitle: Text(tr('Pentru o tabletă fixată pe perete, cu ecranul spre angajați.',
                'For a wall-mounted tablet facing the employees.')),
            value: _store.cameraFront,
            onChanged: (v) async {
              await _store.setCameraFront(v);
              setState(() {});
            },
          ),
          SwitchListTile(
            secondary: const Icon(Icons.volume_up_outlined),
            title: Text(tr('Semnal sonor la scanare', 'Sound on scan')),
            value: _store.scanSound,
            onChanged: (v) async {
              await _store.setScanSound(v);
              setState(() {});
            },
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              tr('Numele firmei, toleranța și turele se sincronizează cu telefonul partener; '
                  'PIN-ul, camera și sunetul sunt doar ale acestui telefon.',
                  'The business name, tolerance and shifts sync with the partner phone; '
                  'the PIN, camera and sound belong to this phone only.'),
              style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
