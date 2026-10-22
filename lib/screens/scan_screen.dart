import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../l10n.dart';
import '../src/models.dart';
import '../src/scan_logic.dart';
import '../src/store.dart';
import '../src/sync_service.dart';
import '../src/ui.dart';

// ─── Ecranul de pontaj (telefonul / tableta de la intrare) ───────────────────
// Angajatul arată codul QR (printat sau pe telefonul lui) camerei. Scanarea
// alternează intrare / ieșire; imediat după scanare se poate corecta tipul.
class ScanScreen extends StatefulWidget {
  // Camera pornește doar cât timp ecranul e vizibil (tab-ul activ).
  final bool active;

  const ScanScreen({super.key, required this.active});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

enum _ResultKind { clockIn, clockOut, duplicate, error }

class _ScanResult {
  final _ResultKind kind;
  final String title;
  final String subtitle;
  final Punch? punch;
  const _ScanResult(this.kind, this.title, this.subtitle, {this.punch});
}

class _ScanScreenState extends State<ScanScreen> with WidgetsBindingObserver {
  final _store = Store.instance;
  MobileScannerController? _controller;
  bool _front = false;

  bool _busy = false;
  String? _lastRaw;
  DateTime _lastRawAt = DateTime.fromMillisecondsSinceEpoch(0);
  _ScanResult? _result;
  Timer? _resultTimer;
  Timer? _clockTimer;
  DateTime _now = DateTime.now();
  List<Punch> _recent = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _front = _store.cameraFront;
    _controller = _newController();
    _store.addListener(_onStoreChanged);
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
    _loadRecent();
    if (widget.active) DeviceService.keepScreenOn(true);
  }

  MobileScannerController _newController() => MobileScannerController(
        facing: _front ? CameraFacing.front : CameraFacing.back,
        formats: const [BarcodeFormat.qrCode],
        autoStart: widget.active,
      );

  @override
  void didUpdateWidget(ScanScreen old) {
    super.didUpdateWidget(old);
    if (old.active == widget.active) return;
    DeviceService.keepScreenOn(widget.active);
    if (widget.active) {
      unawaited(_controller?.start().catchError((_) {}));
      _loadRecent();
    } else {
      unawaited(_controller?.stop().catchError((_) {}));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _controller;
    if (c == null || !widget.active) return;
    if (state == AppLifecycleState.resumed) {
      unawaited(c.start().catchError((_) {}));
    } else if (state == AppLifecycleState.paused) {
      unawaited(c.stop().catchError((_) {}));
    }
  }

  // Camera din față / din spate schimbată din setări.
  void _onStoreChanged() {
    if (_store.cameraFront != _front) {
      _front = _store.cameraFront;
      final old = _controller;
      setState(() => _controller = _newController());
      unawaited(old?.dispose());
    }
    _loadRecent();
  }

  Future<void> _loadRecent() async {
    final now = DateTime.now();
    final list = await _store.punchesBetween(now, now);
    if (!mounted) return;
    setState(() => _recent = list.reversed.take(8).toList());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _store.removeListener(_onStoreChanged);
    _resultTimer?.cancel();
    _clockTimer?.cancel();
    _controller?.dispose();
    DeviceService.keepScreenOn(false);
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    for (final b in capture.barcodes) {
      final raw = b.rawValue;
      if (raw != null && raw.isNotEmpty) {
        _handle(raw);
        return;
      }
    }
  }

  Future<void> _handle(String raw) async {
    final now = DateTime.now();
    // Același cod ținut în fața camerei e detectat de mai multe ori pe secundă.
    if (_busy || (raw == _lastRaw && now.difference(_lastRawAt) < const Duration(seconds: 5))) {
      return;
    }
    _busy = true;
    _lastRaw = raw;
    _lastRawAt = now;
    try {
      final qr = parseQr(raw);
      final emp = qr == null ? null : _store.employeeById(qr.id);
      if (qr == null) {
        _show(_ScanResult(_ResultKind.error, tr('Cod necunoscut', 'Unknown code'),
            tr('Acesta nu este un cod de pontaj Clocking.', 'This is not a Clocking time card code.')));
        return;
      }
      if (emp == null || emp.qrSecret != qr.secret) {
        _show(_ScanResult(_ResultKind.error, tr('Cod invalid', 'Invalid code'),
            tr('Codul a fost înlocuit sau angajatul nu mai există. Cere managerului un cod nou.',
                'The code was replaced or the employee no longer exists. Ask the manager for a new code.')));
        return;
      }
      if (!emp.active) {
        _show(_ScanResult(_ResultKind.error, emp.name,
            tr('Angajat inactiv — pontajul nu a fost înregistrat.', 'Inactive employee — the clocking was not recorded.')));
        return;
      }

      await _store.ensureSchedules(now.subtract(const Duration(days: 2)), now);
      final last = await _store.lastPunch(emp.id, now);
      final openShift = last != null && last.isIn ? _store.scheduledShift(emp.id, dayOf(last.at)) : null;
      final outcome = decideScan(
        last: last,
        now: now,
        duplicateWindow: Duration(minutes: _store.duplicateWindowMinutes),
        maxOpen: maxOpenDuration(openShift),
      );
      if (outcome == ScanOutcome.duplicate) {
        _show(_ScanResult(
          _ResultKind.duplicate,
          emp.name,
          last!.isIn
              ? tr('Ai pontat deja intrarea la ${fmtTime(last.at)}.', 'You already clocked in at ${fmtTime(last.at)}.')
              : tr('Ai pontat deja ieșirea la ${fmtTime(last.at)}.', 'You already clocked out at ${fmtTime(last.at)}.'),
        ));
        return;
      }
      final type = outcome == ScanOutcome.clockIn ? PunchType.clockIn : PunchType.clockOut;
      final punch = await _store.addPunch(employeeId: emp.id, at: now, type: type);
      _show(_resultFor(emp, punch));
    } finally {
      _busy = false;
    }
  }

  _ScanResult _resultFor(Employee emp, Punch p) => p.isIn
      ? _ScanResult(_ResultKind.clockIn, tr('Bun venit, ${emp.name}!', 'Welcome, ${emp.name}!'),
          tr('INTRARE · ${fmtTime(p.at)}', 'CLOCK IN · ${fmtTime(p.at)}'),
          punch: p)
      : _ScanResult(_ResultKind.clockOut, tr('La revedere, ${emp.name}!', 'Goodbye, ${emp.name}!'),
          tr('IEȘIRE · ${fmtTime(p.at)}', 'CLOCK OUT · ${fmtTime(p.at)}'),
          punch: p);

  void _show(_ScanResult r) {
    final ok = r.kind == _ResultKind.clockIn || r.kind == _ResultKind.clockOut;
    if (_store.scanSound) DeviceService.beep(ok: ok);
    HapticFeedback.mediumImpact();
    _resultTimer?.cancel();
    setState(() => _result = r);
    _resultTimer = Timer(Duration(seconds: ok ? 7 : 5), () {
      if (mounted) setState(() => _result = null);
    });
    if (ok) _loadRecent();
  }

  // Intrare ↔ ieșire, pentru o scanare tocmai înregistrată greșit.
  Future<void> _flip() async {
    final p = _result?.punch;
    if (p == null) return;
    final emp = _store.employeeById(p.employeeId);
    if (emp == null) return;
    final updated = await _store.updatePunch(p.copyWith(
      type: p.isIn ? PunchType.clockOut : PunchType.clockIn,
      source: PunchSource.corrected,
    ));
    _show(_resultFor(emp, updated));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final wide = c.maxWidth > c.maxHeight && c.maxWidth > 700;
      final camera = _cameraArea();
      final side = _sidePanel();
      if (wide) {
        return Row(children: [
          Expanded(flex: 3, child: camera),
          SizedBox(width: 340, child: side),
        ]);
      }
      return Column(children: [
        Expanded(child: camera),
        SizedBox(height: 220, child: side),
      ]);
    });
  }

  Widget _cameraArea() {
    final controller = _controller;
    return Container(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (controller != null)
            MobileScanner(
              key: ObjectKey(controller),
              controller: controller,
              onDetect: _onDetect,
              errorBuilder: (context, error) => _cameraError(error),
            ),
          IgnorePointer(
            child: Center(
              child: Container(
                width: 230,
                height: 230,
                decoration: BoxDecoration(
                  border: Border.all(color: kAmber, width: 4),
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
            ),
          ),
          Positioned(
            top: 12,
            left: 12,
            right: 12,
            child: _clockBanner(),
          ),
          if (_result != null)
            Positioned(left: 12, right: 12, bottom: 12, child: _resultCard(_result!)),
        ],
      ),
    );
  }

  Widget _cameraError(MobileScannerException error) {
    final denied = error.errorCode == MobileScannerErrorCode.permissionDenied;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.no_photography_outlined, color: Colors.white70, size: 48),
            const SizedBox(height: 12),
            Text(
              denied
                  ? tr('Aplicația nu are acces la cameră. Permite accesul din Setări → Aplicații → Clocking → Permisiuni.',
                      'The app has no camera access. Allow it in Settings → Apps → Clocking → Permissions.')
                  : tr('Camera nu poate fi pornită.', 'The camera cannot be started.'),
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
              onPressed: () => _controller?.start().catchError((_) {}),
              child: Text(tr('Reîncearcă', 'Try again')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _clockBanner() {
    final wd = tr('Luni,Marți,Miercuri,Joi,Vineri,Sâmbătă,Duminică',
            'Monday,Tuesday,Wednesday,Thursday,Friday,Saturday,Sunday')
        .split(',');
    final hh = _now.hour.toString().padLeft(2, '0');
    final mm = _now.minute.toString().padLeft(2, '0');
    final ss = _now.second.toString().padLeft(2, '0');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Text('$hh:$mm',
              style: const TextStyle(color: Colors.white, fontSize: 34, fontWeight: FontWeight.bold)),
          Text(':$ss', style: const TextStyle(color: Colors.white70, fontSize: 20)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '${wd[_now.weekday - 1]}\n${fmtDate(_now)}',
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
          IconButton(
            tooltip: tr('Schimbă camera', 'Switch camera'),
            icon: const Icon(Icons.cameraswitch_outlined, color: Colors.white),
            onPressed: () => _store.setCameraFront(!_store.cameraFront),
          ),
        ],
      ),
    );
  }

  Widget _resultCard(_ScanResult r) {
    final (Color bg, IconData icon) = switch (r.kind) {
      _ResultKind.clockIn => (Colors.green.shade700, Icons.login),
      _ResultKind.clockOut => (Colors.blue.shade700, Icons.logout),
      _ResultKind.duplicate => (Colors.orange.shade800, Icons.info_outline),
      _ResultKind.error => (Colors.red.shade700, Icons.error_outline),
    };
    return Material(
      color: bg,
      elevation: 6,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(icon, color: Colors.white, size: 44),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(r.title,
                      style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(r.subtitle, style: const TextStyle(color: Colors.white, fontSize: 16)),
                ],
              ),
            ),
            if (r.punch != null)
              TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white,
                  backgroundColor: Colors.white24,
                ),
                onPressed: _flip,
                child: Text(r.punch!.isIn
                    ? tr('E ieșire', 'It\'s an exit')
                    : tr('E intrare', 'It\'s an entry')),
              ),
          ],
        ),
      ),
    );
  }

  Widget _sidePanel() {
    return Container(
      color: Colors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(tr('Pontaje de azi', 'Today\'s clockings'),
                style: const TextStyle(fontWeight: FontWeight.w600, color: kTealDark)),
          ),
          Expanded(
            child: _recent.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        _store.activeEmployees.isEmpty
                            ? tr('Adaugă angajații din tab-ul „Angajați”, apoi printează codurile QR.',
                                'Add the employees in the “Employees” tab, then print the QR codes.')
                            : tr('Arată codul QR camerei pentru a ponta intrarea sau ieșirea.',
                                'Show the QR code to the camera to clock in or out.'),
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey.shade600),
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: _recent.length,
                    itemBuilder: (_, i) {
                      final p = _recent[i];
                      final e = _store.employeeById(p.employeeId);
                      return ListTile(
                        dense: true,
                        leading: Icon(p.isIn ? Icons.login : Icons.logout,
                            color: p.isIn ? Colors.green.shade700 : Colors.blue.shade700),
                        title: Text(e?.name ?? '?'),
                        trailing: Text(
                          '${p.isIn ? tr('Intrare', 'In') : tr('Ieșire', 'Out')} ${fmtTime(p.at)}',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
