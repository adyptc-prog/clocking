import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'backup_screen.dart';
import 'l10n.dart';
import 'license_screen.dart';
import 'license_service.dart';
import 'screens/attendance_screen.dart';
import 'screens/employees_screen.dart';
import 'screens/reports_screen.dart';
import 'screens/scan_screen.dart';
import 'screens/schedule_screen.dart';
import 'screens/settings_screen.dart';
import 'src/store.dart';
import 'src/sync_service.dart';
import 'src/ui.dart';
import 'src/theme.dart';

// ─── Punct de intrare ─────────────────────────────────────────────────────────
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppLang.load();
  await AppTheme.load();
  runApp(const ClockingApp());
}

class ClockingApp extends StatelessWidget {
  const ClockingApp({super.key});

  @override
  Widget build(BuildContext context) {
    // La schimbarea limbii, aplicația se reconstruiește de la ecranul
    // principal (cheia se schimbă), ca toate textele să apară în limba nouă.
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppTheme.mode,
      builder: (context, mode, _) => ValueListenableBuilder<String>(
        valueListenable: AppLang.code,
        builder: (context, lang, _) => _buildApp(lang, mode),
      ),
    );
  }

  Widget _buildApp(String lang, ThemeMode mode) {
    return MaterialApp(
      key: ValueKey(lang),
      locale: Locale(lang),
      supportedLocales: const [Locale('ro'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      title: 'Clocking',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: mode,
      home: const HomePage(),
    );
  }
}

// ─── Ecranul principal: pontaj + zona managerului (protejată cu PIN) ──────────
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final _store = Store.instance;
  int _tab = 0;
  bool _unlocked = false;
  Timer? _lockTimer;
  Timer? _syncTimer;
  String _appVersion = '';
  ({DateTime failedAt, String phone, String reason})? _smsFailure;

  // Zona managerului se blochează singură după 5 minute fără atingeri.
  static const _autoLock = Duration(minutes: 5);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _store.outgoing = SyncService.send;
    _init();
  }

  Future<void> _init() async {
    await _store.load();
    await LicenseService.load();
    await SyncService.load();
    final info = await PackageInfo.fromPlatform();
    if (mounted) setState(() => _appVersion = info.version);
    await _processSyncQueue();
    _syncTimer = Timer.periodic(const Duration(seconds: 20), (_) => _processSyncQueue());
    await _checkLicenseFromPartner();
    await _warnLicenseExpiry();
    await _checkSmsFailure();
    // Notificările: backup-ul automat eșuat.
    try {
      if (SyncService.isSupported && !await Permission.notification.isGranted) {
        await Permission.notification.request();
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _lockTimer?.cancel();
    _syncTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _processSyncQueue();
      _checkLicenseFromPartner();
      _checkSmsFailure();
    } else if (state == AppLifecycleState.paused) {
      _lock();
    }
  }

  // ── Sincronizare: mesajele primite de la partener ───────────────────────────
  bool _syncBusy = false;
  bool _restoring = false;

  Future<void> _processSyncQueue() async {
    if (_syncBusy || _restoring || !_store.loaded) return;
    _syncBusy = true;
    try {
      final entries = await SyncService.getPendingMessages();
      if (entries.isEmpty) return;
      for (final e in entries) {
        if (e.msg.isNotEmpty) await _store.applyRemote(e.msg);
      }
      await SyncService.ackMessages([for (final e in entries) e.id]);
    } finally {
      _syncBusy = false;
    }
  }

  Future<void> _checkSmsFailure() async {
    final f = await SyncService.pendingFailure();
    if (mounted) setState(() => _smsFailure = f);
  }

  // ── Licență ─────────────────────────────────────────────────────────────────
  Future<void> _checkLicenseFromPartner() async {
    if (!await LicenseService.consumePartnerNotice()) return;
    await LicenseService.checkNewLicense();
    if (!mounted) return;
    setState(() {});
    showSnack(context, tr('Licența a fost primită de la telefonul partener.', 'The license was received from the partner phone.'),
        color: Colors.green.shade700);
  }

  Future<void> _warnLicenseExpiry() async {
    if (!await LicenseService.shouldWarnExpiryToday() || !mounted) return;
    final days = LicenseService.newLicenseDaysUntilExpiry ?? 0;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(days <= 1
          ? tr('Licența expiră mâine! Reînnoiește-o pentru a evita întreruperile.', 'The license expires tomorrow! Renew it to avoid interruptions.')
          : tr('Licența expiră în $days zile. Reînnoiește-o pentru a evita întreruperile.', 'The license expires in $days days. Renew it to avoid interruptions.')),
      backgroundColor: Colors.orange.shade800,
      duration: const Duration(seconds: 6),
      action: SnackBarAction(label: tr('Detalii', 'Details'), textColor: Colors.white, onPressed: _openLicense),
    ));
  }

  Future<LicenseShareOutcome?> _shareLicense() async {
    if (!await _ensureSmsPermission()) return null;
    final status = await LicenseService.shareWithPartner();
    return (
      sent: status == 'sent' ? 1 : 0,
      refused: status == 'not_owner' || status == 'other_partner' ? status : null,
    );
  }

  Future<void> _openLicense() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => LicenseScreen(onShareWithPartners: SyncService.isActive ? _shareLicense : null),
    ));
    if (mounted) setState(() {});
  }

  // ── PIN / blocare ───────────────────────────────────────────────────────────
  bool get _managerOpen => !_store.hasPin || _unlocked;

  void _lock() {
    _lockTimer?.cancel();
    if (_unlocked && mounted) setState(() => _unlocked = false);
  }

  void _touch() {
    if (!_unlocked) return;
    _lockTimer?.cancel();
    _lockTimer = Timer(_autoLock, () {
      if (mounted) setState(() => _unlocked = false);
    });
  }

  Future<bool> _unlock() async {
    if (_managerOpen) return true;
    final pin = await askPin(context, title: tr('PIN manager', 'Manager PIN'));
    if (pin == null) return false;
    if (!_store.checkPin(pin)) {
      if (mounted) showSnack(context, tr('PIN greșit.', 'Wrong PIN.'), color: Colors.red.shade700);
      return false;
    }
    setState(() => _unlocked = true);
    _touch();
    return true;
  }

  Future<void> _selectTab(int i) async {
    if (i != 0 && !await _unlock()) return;
    setState(() => _tab = i);
  }

  Future<void> _openManager(Widget Function() page) async {
    if (!await _unlock() || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page()));
    if (mounted) setState(() {});
  }

  // ── Sincronizare cu telefonul partener ──────────────────────────────────────
  Future<bool> _ensureSmsPermission() async {
    if (await SyncService.hasSmsPermission()) return true;
    if (await SyncService.requestSmsPermission()) return true;
    if (mounted) {
      showSnack(context, tr('Fără permisiunea SMS, sincronizarea nu funcționează.', 'Without the SMS permission, sync does not work.'),
          color: Colors.red.shade700);
    }
    return false;
  }

  Future<void> _showSyncDialog() async {
    final phoneCtrl = TextEditingController(text: SyncService.partnerPhone ?? '');
    final codeCtrl = TextEditingController();
    String? codeError;
    final autostartBlocked = await SyncService.autostartBlocked();
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDs) => AlertDialog(
          title: Row(
            children: [
              Icon(SyncService.isActive ? Icons.sync : Icons.sync_disabled,
                  color: SyncService.isActive ? Colors.green.shade600 : Colors.grey, size: 22),
              const SizedBox(width: 8),
              Expanded(child: Text(tr('Sincronizare cu al doilea telefon', 'Sync with a second phone'))),
            ],
          ),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (SyncService.isActive) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: tintBg(context, Colors.green),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.green.shade200),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.check_circle_outline, color: toneFg(context, Colors.green), size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              tr('Sincronizare activă cu:\n${SyncService.partnerPhone}', 'Sync active with:\n${SyncService.partnerPhone}'),
                              style: TextStyle(color: toneFg(context, Colors.green), fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      tr('Fiecare pontaj, angajat, grafic și setare se trimite automat prin SMS.',
                          'Every clocking, employee, schedule and setting is sent automatically by SMS.'),
                      style: TextStyle(fontSize: 12, color: mutedText(context)),
                    ),
                    const SizedBox(height: 8),
                    SelectableText(
                      tr('Cod de împerechere: ${SyncService.pairingCode ?? ''}', 'Pairing code: ${SyncService.pairingCode ?? ''}'),
                      style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                    ),
                  ] else ...[
                    Text(
                      tr('Ex.: telefonul de la intrare scanează, iar managerul vede pontajele pe telefonul lui. '
                          'Sau două intrări, câte un telefon la fiecare.',
                          'E.g. the entrance phone scans and the manager sees the clockings on their own phone. '
                          'Or two entrances, one phone at each.'),
                      style: TextStyle(fontSize: 12, color: mutedText(context)),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: phoneCtrl,
                      keyboardType: TextInputType.phone,
                      decoration: InputDecoration(
                        labelText: tr('Numărul celuilalt telefon *', 'The other phone\'s number *'),
                        hintText: '+40712345678',
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.phone_outlined),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: codeCtrl,
                      textCapitalization: TextCapitalization.characters,
                      decoration: InputDecoration(
                        labelText: tr('Cod de împerechere *', 'Pairing code *'),
                        hintText: tr('ex. K7QM-2XPA', 'e.g. K7QM-2XPA'),
                        helperText: tr('Același cod pe ambele telefoane. Generează-l pe unul și tastează-l pe celălalt.',
                            'The same code on both phones. Generate it on one and type it on the other.'),
                        helperMaxLines: 2,
                        errorText: codeError,
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.key_outlined),
                        suffixIcon: IconButton(
                          icon: const Icon(Icons.casino_outlined),
                          tooltip: tr('Generează cod', 'Generate code'),
                          onPressed: () => setDs(() {
                            codeCtrl.text = SyncService.generateCode();
                            codeError = null;
                          }),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: tintBg(context, Colors.blue),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: tintBg(context, Colors.blue)),
                      ),
                      child: Text(
                        tr('La prima sincronizare se trimit prin SMS angajații, turele, graficul și '
                            'pontajele din ultimele două luni. Apoi fiecare modificare se trimite automat.\n\n'
                            'Configurează sincronizarea și pe celălalt telefon, cu același cod — mesajele '
                            'cu alt cod sunt ignorate. SMS-urile se taxează conform abonamentului.',
                            'On the first sync, the employees, shifts, schedule and the clockings of the '
                            'last two months are sent by SMS. After that every change is sent automatically.\n\n'
                            'Set up sync on the other phone as well, with the same code — messages '
                            'with another code are ignored. SMS are charged according to your plan.'),
                        style: TextStyle(fontSize: 11, color: toneFg(context, Colors.blue)),
                      ),
                    ),
                  ],
                  if (autostartBlocked) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: tintBg(context, Colors.orange),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            tr('Pe acest telefon (Xiaomi) activează „Pornire automată” pentru Clocking, '
                                'altfel SMS-urile partenerului nu sunt primite cu aplicația închisă.',
                                'On this phone (Xiaomi) enable “Autostart” for Clocking, otherwise the '
                                'partner\'s SMS are not received while the app is closed.'),
                            style: TextStyle(fontSize: 11, color: toneFg(context, Colors.orange)),
                          ),
                          TextButton(
                            onPressed: SyncService.openAutostartSettings,
                            child: Text(tr('Deschide setarea', 'Open the setting')),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            if (SyncService.isActive)
              TextButton.icon(
                icon: const Icon(Icons.sync_disabled, color: Colors.red, size: 18),
                label: Text(tr('Desincronizează', 'Stop syncing'), style: const TextStyle(color: Colors.red)),
                onPressed: () async {
                  await SyncService.clearPartner();
                  if (ctx.mounted) Navigator.pop(ctx);
                  setState(() {});
                },
              ),
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Închide', 'Close'))),
            if (!SyncService.isActive)
              FilledButton.icon(
                icon: const Icon(Icons.sync, size: 18),
                label: Text(tr('Sincronizează', 'Sync')),
                onPressed: () async {
                  final phone = phoneCtrl.text.trim();
                  if (phone.isEmpty) return;
                  if (!SyncService.isValidCode(codeCtrl.text)) {
                    setDs(() => codeError = tr('Minim ${SyncService.minCodeLength} litere/cifre.',
                        'At least ${SyncService.minCodeLength} letters/digits.'));
                    return;
                  }
                  if (!await _ensureSmsPermission()) return;
                  await SyncService.setPartner(phone, codeCtrl.text);
                  if (ctx.mounted) Navigator.pop(ctx);
                  setState(() {});
                  _performInitialSync();
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _performInitialSync() async {
    final messages = await _store.initialSyncMessages(DateTime.now());
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(
      content: Text(tr('Se trimite sincronizarea inițială (${messages.length} SMS-uri)...',
          'Sending the initial sync (${messages.length} SMS)...')),
      duration: Duration(seconds: messages.length * 2 + 3),
    ));
    await SyncService.sendLicenseHandshake();
    await SyncService.sendAll(messages);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(tr('Sincronizare inițială trimisă!', 'Initial sync sent!'))));
  }

  // ── Backup ──────────────────────────────────────────────────────────────────
  Future<void> _openBackup() => _openManager(() => BackupScreen(
        onBeforeRestore: () async {
          _restoring = true;
          while (_syncBusy) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        },
        onRestored: (ok) async {
          await _store.reload();
          await SyncService.load();
          await LicenseService.checkNewLicense();
          _restoring = false;
          if (mounted) setState(() {});
        },
      ));

  // ── Limba ───────────────────────────────────────────────────────────────────
  Future<void> _showLanguageDialog() async {
    final chosen = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(tr('Limba aplicației', 'App language')),
        children: [
          for (final (code, name) in const [('ro', 'Română'), ('en', 'English')])
            ListTile(
              leading: Icon(AppLang.code.value == code ? Icons.radio_button_checked : Icons.radio_button_unchecked),
              title: Text(name),
              onTap: () => Navigator.pop(ctx, code),
            ),
        ],
      ),
    );
    if (chosen == null || chosen == AppLang.code.value) return;
    await AppLang.set(chosen);
  }

  void _showAbout() {
    showAboutDialog(
      context: context,
      applicationName: 'Clocking',
      applicationVersion: _appVersion,
      applicationIcon: Image.asset('assets/icon/icon.png', width: 48, height: 48),
      applicationLegalese: '© 2026 Adrian Petcu — Volt Academy\nAGPL-3.0-or-later',
      children: [
        const SizedBox(height: 12),
        Text(tr(
            'Pontaj cu coduri QR, grafic de lucru și rapoarte. Totul rămâne pe telefon: fără '
                'internet, fără server, fără conturi.\n\nCod sursă: github.com/adyptc-prog/clocking\n'
                'Licențe: voltacademy.app/clocking.html',
            'Time clock with QR codes, work schedules and reports. Everything stays on the phone: '
                'no internet, no server, no accounts.\n\nSource code: github.com/adyptc-prog/clocking\n'
                'Licenses: voltacademy.app/clocking.html')),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final titles = [
      tr('Pontaj', 'Clock in'),
      tr('Prezență', 'Attendance'),
      tr('Angajați', 'Employees'),
      tr('Grafic', 'Schedule'),
      tr('Rapoarte', 'Reports'),
    ];
    final company = _store.companyName;
    final locked = _store.hasPin && !_unlocked;

    return Listener(
      onPointerDown: (_) => _touch(),
      child: Scaffold(
        appBar: AppBar(
          toolbarHeight: 64,
          flexibleSpace: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: isDarkTheme(context)
                    ? const [Color(0xFF0F1A19), Color(0xFF123A35)]
                    : const [Color(0xFF0B3D38), Color(0xFF0F766E)],
              ),
            ),
          ),
          titleSpacing: 12,
          title: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(11),
                  border: Border.all(color: const Color(0x55D4A537), width: 1.2),
                  image: const DecorationImage(image: AssetImage('assets/icon/icon.png'), fit: BoxFit.cover),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(company.isEmpty ? 'Clocking' : company,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: 0.2)),
                    Text(titles[_tab].toUpperCase(),
                        style: const TextStyle(
                            fontSize: 11, color: Color(0xFFE9C46A), fontWeight: FontWeight.w600, letterSpacing: 1.4)),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            if (SyncService.isActive)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Tooltip(
                  message: tr('Sincronizat cu ${SyncService.partnerPhone}', 'Synced with ${SyncService.partnerPhone}'),
                  child: const Icon(Icons.sync, size: 20),
                ),
              ),
            IconButton(
              tooltip: tr('Limba', 'Language'),
              icon: const Icon(Icons.language),
              onPressed: _showLanguageDialog,
            ),
            if (_store.hasPin)
              IconButton(
                tooltip: locked ? tr('Deblochează', 'Unlock') : tr('Blochează', 'Lock'),
                icon: Icon(locked ? Icons.lock_outline : Icons.lock_open),
                onPressed: () async {
                  if (locked) {
                    await _unlock();
                  } else {
                    _lock();
                    setState(() => _tab = 0);
                  }
                },
              ),
            PopupMenuButton<String>(
              onSelected: (v) async {
                switch (v) {
                  case 'sync':
                    if (await _unlock()) await _showSyncDialog();
                  case 'backup':
                    await _openBackup();
                  case 'license':
                    await _openManager(() => LicenseScreen(
                        onShareWithPartners: SyncService.isActive ? _shareLicense : null));
                  case 'settings':
                    await _openManager(() => const SettingsScreen());
                  case 'about':
                    _showAbout();
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'sync', child: ListTile(leading: const Icon(Icons.sync), title: Text(tr('Sincronizare', 'Sync')))),
                PopupMenuItem(value: 'backup', child: ListTile(leading: const Icon(Icons.backup_outlined), title: Text(tr('Backup', 'Backup')))),
                PopupMenuItem(value: 'license', child: ListTile(leading: const Icon(Icons.verified_user_outlined), title: Text(tr('Licență', 'License')))),
                PopupMenuItem(value: 'settings', child: ListTile(leading: const Icon(Icons.settings_outlined), title: Text(tr('Setări', 'Settings')))),
                PopupMenuItem(value: 'about', child: ListTile(leading: const Icon(Icons.info_outline), title: Text(tr('Despre', 'About')))),
              ],
            ),
          ],
        ),
        body: !_store.loaded
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  if (_smsFailure != null) _smsFailureBanner(),
                  if (!LicenseService.isLicensed && _tab != 0) _trialBanner(),
                  Expanded(
                    child: IndexedStack(
                      index: _tab,
                      children: [
                        ScanScreen(active: _tab == 0),
                        _tab == 1 ? const AttendanceScreen() : const SizedBox(),
                        _tab == 2 ? const EmployeesScreen() : const SizedBox(),
                        _tab == 3 ? const ScheduleScreen() : const SizedBox(),
                        _tab == 4 ? const ReportsScreen() : const SizedBox(),
                      ],
                    ),
                  ),
                ],
              ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: _selectTab,
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          destinations: [
            NavigationDestination(icon: const Icon(Icons.qr_code_scanner), label: titles[0]),
            NavigationDestination(icon: Icon(locked ? Icons.lock_outline : Icons.fact_check_outlined), label: titles[1]),
            NavigationDestination(icon: Icon(locked ? Icons.lock_outline : Icons.badge_outlined), label: titles[2]),
            NavigationDestination(icon: Icon(locked ? Icons.lock_outline : Icons.calendar_month_outlined), label: titles[3]),
            NavigationDestination(icon: Icon(locked ? Icons.lock_outline : Icons.assessment_outlined), label: titles[4]),
          ],
        ),
      ),
    );
  }

  Widget _trialBanner() {
    final active = LicenseService.isTrialActive;
    return Material(
      color: active ? tintBg(context, Colors.orange) : tintBg(context, Colors.red),
      child: InkWell(
        onTap: _openLicense,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(active ? Icons.lock_open_outlined : Icons.lock_outline,
                  size: 16, color: active ? Colors.orange.shade800 : Colors.red.shade700),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  active
                      ? tr('Trial · ${LicenseService.trialDaysLeft} zile rămase', 'Trial · ${LicenseService.trialDaysLeft} days left')
                      : tr('Trial expirat — activează licența', 'Trial expired — activate the license'),
                  style: TextStyle(fontSize: 12, color: active ? Colors.orange.shade900 : Colors.red.shade800),
                ),
              ),
              if (_appVersion.isNotEmpty)
                Text('v$_appVersion', style: TextStyle(fontSize: 11, color: mutedText(context))),
            ],
          ),
        ),
      ),
    );
  }

  Widget _smsFailureBanner() {
    final f = _smsFailure!;
    return Material(
      color: tintBg(context, Colors.red),
      child: ListTile(
        dense: true,
        leading: Icon(Icons.sms_failed_outlined, color: toneFg(context, Colors.red)),
        title: Text(tr('Un SMS de sincronizare nu a putut fi trimis', 'A sync SMS could not be sent'),
            style: TextStyle(color: toneFg(context, Colors.red), fontWeight: FontWeight.w600)),
        subtitle: Text(f.reason),
        trailing: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () async {
            await SyncService.dismissFailure();
            setState(() => _smsFailure = null);
          },
        ),
      ),
    );
  }
}
