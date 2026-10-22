import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n.dart';
import '../src/export.dart';
import '../src/models.dart';
import '../src/store.dart';
import '../src/ui.dart';
import 'work_program_screen.dart';

// ─── Lista angajaților ────────────────────────────────────────────────────────
class EmployeesScreen extends StatefulWidget {
  const EmployeesScreen({super.key});

  @override
  State<EmployeesScreen> createState() => _EmployeesScreenState();
}

class _EmployeesScreenState extends State<EmployeesScreen> {
  final _store = Store.instance;

  @override
  void initState() {
    super.initState();
    _store.addListener(_changed);
  }

  @override
  void dispose() {
    _store.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _add() async {
    if (!await ensureLicensed(context)) return;
    if (!mounted) return;
    final e = await showEmployeeDialog(context);
    if (e == null || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => EmployeeDetailScreen(employeeId: e.id),
    ));
  }

  Future<void> _printAll() async {
    final list = _store.activeEmployees;
    if (list.isEmpty) return;
    final f = await qrCardsPdf(list, company: _store.companyName);
    await shareFile(f, subject: tr('Coduri QR angajați', 'Employee QR codes'));
  }

  @override
  Widget build(BuildContext context) {
    final employees = _store.employees;
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'add_employee',
        icon: const Icon(Icons.person_add_alt_1),
        label: Text(tr('Angajat nou', 'New employee')),
        onPressed: _add,
      ),
      body: employees.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.badge_outlined, size: 64, color: Colors.grey.shade400),
                    const SizedBox(height: 12),
                    Text(
                      tr('Adaugă angajații. Fiecare primește un cod QR pe care îl scanează '
                          'la venire și la plecare.',
                          'Add your employees. Each one gets a QR code to scan when '
                          'arriving and leaving.'),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.only(bottom: 88),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          tr('${_store.activeEmployees.length} activi din ${employees.length}',
                              '${_store.activeEmployees.length} active of ${employees.length}'),
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.print_outlined),
                        label: Text(tr('Printează toate codurile', 'Print all codes')),
                        onPressed: _printAll,
                      ),
                    ],
                  ),
                ),
                for (final e in employees)
                  ListTile(
                    leading: CircleAvatar(
                      backgroundColor: e.active ? kTeal : Colors.grey.shade400,
                      foregroundColor: Colors.white,
                      child: Text(e.name.isEmpty ? '?' : e.name.characters.first.toUpperCase()),
                    ),
                    title: Text(e.name,
                        style: TextStyle(color: e.active ? null : Colors.grey.shade600)),
                    subtitle: Text([
                      if (e.role.isNotEmpty) e.role,
                      if (!e.active) tr('inactiv', 'inactive'),
                    ].join(' · ')),
                    trailing: const Icon(Icons.qr_code_2),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => EmployeeDetailScreen(employeeId: e.id),
                    )),
                  ),
              ],
            ),
    );
  }
}

// Adăugare (existing == null) sau editare.
Future<Employee?> showEmployeeDialog(BuildContext context, {Employee? existing}) async {
  final name = TextEditingController(text: existing?.name ?? '');
  final role = TextEditingController(text: existing?.role ?? '');
  final phone = TextEditingController(text: existing?.phone ?? '');
  final note = TextEditingController(text: existing?.note ?? '');
  String? error;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDs) => AlertDialog(
        title: Text(existing == null ? tr('Angajat nou', 'New employee') : tr('Editează angajatul', 'Edit employee')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                autofocus: existing == null,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  labelText: tr('Nume și prenume *', 'Full name *'),
                  errorText: error,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: role,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: tr('Funcție (opțional)', 'Position (optional)'),
                  hintText: tr('ex. Asistentă', 'e.g. Nurse'),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: phone,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(
                  labelText: tr('Telefon (opțional)', 'Phone (optional)'),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: note,
                maxLines: 2,
                decoration: InputDecoration(
                  labelText: tr('Notă (opțional)', 'Note (optional)'),
                  border: const OutlineInputBorder(),
                ),
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
      ),
    ),
  );
  if (ok != true) return null;
  final store = Store.instance;
  if (existing == null) {
    return store.addEmployee(name: name.text, role: role.text, phone: phone.text, note: note.text);
  }
  return store.updateEmployee(existing.copyWith(
    name: name.text.trim(),
    role: role.text.trim(),
    phone: phone.text.trim(),
    note: note.text.trim(),
  ));
}

// ─── Fișa angajatului: codul QR și acțiunile ──────────────────────────────────
class EmployeeDetailScreen extends StatefulWidget {
  final String employeeId;
  const EmployeeDetailScreen({super.key, required this.employeeId});

  @override
  State<EmployeeDetailScreen> createState() => _EmployeeDetailScreenState();
}

class _EmployeeDetailScreenState extends State<EmployeeDetailScreen> {
  final _store = Store.instance;
  final _cardKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _store.addListener(_changed);
  }

  @override
  void dispose() {
    _store.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  // Cardul QR ca imagine — trimis angajatului (WhatsApp, SMS etc.) ca să-l
  // arate de pe telefon.
  Future<void> _shareImage(Employee e) async {
    final boundary = _cardKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) return;
    final image = await boundary.toImage(pixelRatio: 3);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) return;
    final dir = Directory('${(await getTemporaryDirectory()).path}/exports');
    await dir.create(recursive: true);
    final f = File('${dir.path}/qr_${e.id}.png');
    await f.writeAsBytes(data.buffer.asUint8List(), flush: true);
    await SharePlus.instance.share(ShareParams(
      files: [XFile(f.path)],
      text: tr('Codul tău de pontaj — arată-l la intrare și la ieșire.',
          'Your time card code — show it when you arrive and when you leave.'),
    ));
  }

  Future<void> _printCard(Employee e) async {
    final f = await qrCardsPdf([e], company: _store.companyName);
    await shareFile(f, subject: tr('Cod QR · ${e.name}', 'QR code · ${e.name}'));
  }

  Future<void> _regenerate(Employee e) async {
    final ok = await confirmDialog(
      context,
      title: tr('Generezi un cod nou?', 'Generate a new code?'),
      message: tr('Codul actual (printat sau trimis) nu va mai fi acceptat la scanare. '
          'Folosește când angajatul și-a pierdut codul.',
          'The current code (printed or sent) will no longer be accepted. '
          'Use it when the employee has lost the code.'),
      confirm: tr('Cod nou', 'New code'),
    );
    if (ok) await _store.regenerateQr(e);
  }

  Future<void> _delete(Employee e) async {
    final ok = await confirmDialog(
      context,
      title: tr('Ștergi angajatul?', 'Delete the employee?'),
      message: tr('${e.name} dispare din listă și din rapoarte. Dacă a plecat din firmă și vrei '
          'să-i păstrezi pontajele în rapoarte, dezactivează-l în loc să-l ștergi.',
          '${e.name} disappears from the list and from reports. If they left and you want '
          'to keep their records in reports, deactivate them instead.'),
      confirm: tr('Șterge', 'Delete'),
      destructive: true,
    );
    if (!ok) return;
    await _store.deleteEmployee(e);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final e = _store.employeeById(widget.employeeId);
    if (e == null) {
      return Scaffold(appBar: AppBar(), body: Center(child: Text(tr('Angajatul nu mai există.', 'The employee no longer exists.'))));
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(e.name),
        actions: [
          IconButton(
            tooltip: tr('Editează', 'Edit'),
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => showEmployeeDialog(context, existing: e),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: RepaintBoundary(
              key: _cardKey,
              child: Container(
                width: 300,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.grey.shade300),
                ),
                child: Column(
                  children: [
                    Text(_store.companyName.isEmpty ? 'Clocking' : _store.companyName,
                        style: const TextStyle(color: kTeal, fontSize: 13)),
                    const SizedBox(height: 8),
                    Opacity(
                      opacity: e.active ? 1 : 0.3,
                      child: QrImageView(
                        data: e.qrPayload,
                        size: 220,
                        backgroundColor: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(e.name,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.black)),
                    if (e.role.isNotEmpty)
                      Text(e.role, style: TextStyle(color: Colors.grey.shade700)),
                  ],
                ),
              ),
            ),
          ),
          if (!e.active)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                tr('Angajat inactiv — codul nu e acceptat la scanare.', 'Inactive employee — the code is not accepted when scanned.'),
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.red.shade700),
              ),
            ),
          const SizedBox(height: 16),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                icon: const Icon(Icons.print_outlined),
                label: Text(tr('Printează cardul (PDF)', 'Print the card (PDF)')),
                onPressed: () => _printCard(e),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.share_outlined),
                label: Text(tr('Trimite ca imagine', 'Send as image')),
                onPressed: () => _shareImage(e),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Card(
            child: Column(
              children: [
                if (e.phone.isNotEmpty)
                  ListTile(leading: const Icon(Icons.phone_outlined), title: Text(e.phone)),
                if (e.note.isNotEmpty)
                  ListTile(leading: const Icon(Icons.notes), title: Text(e.note)),
                ListTile(
                  leading: Icon(Icons.event_repeat,
                      color: _store.programOf(e.id) == null ? Colors.orange.shade800 : kTeal),
                  title: Text(tr('Program de lucru', 'Work program')),
                  subtitle: Text(_store.programOf(e.id)?.describe(_store.shiftMap) ??
                      tr('Nesetat — alege-l ca graficul să se genereze singur.',
                          'Not set — choose it so the schedule is generated by itself.')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => WorkProgramEditor(employeeIds: {e.id}),
                  )),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.how_to_reg_outlined),
                  title: Text(tr('Activ', 'Active')),
                  subtitle: Text(tr('Angajații inactivi nu pot ponta, dar pontajele lor rămân în rapoarte.',
                      'Inactive employees cannot clock in, but their records stay in reports.')),
                  value: e.active,
                  onChanged: (v) => _store.updateEmployee(e.copyWith(active: v)),
                ),
                ListTile(
                  leading: const Icon(Icons.autorenew),
                  title: Text(tr('Generează cod QR nou', 'Generate a new QR code')),
                  subtitle: Text(tr('Pentru un cod pierdut — cel vechi nu mai merge.', 'For a lost code — the old one stops working.')),
                  onTap: () => _regenerate(e),
                ),
                ListTile(
                  leading: Icon(Icons.delete_outline, color: Colors.red.shade400),
                  title: Text(tr('Șterge angajatul', 'Delete the employee'),
                      style: TextStyle(color: Colors.red.shade700)),
                  onTap: () => _delete(e),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            tr('Adăugat la ${fmtDate(e.createdAt)}', 'Added on ${fmtDate(e.createdAt)}'),
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
