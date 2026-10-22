import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n.dart';
import '../license_screen.dart';
import '../license_service.dart';
import 'models.dart';

// ─── Elemente comune ale interfeței ───────────────────────────────────────────
const kTeal = Color(0xFF0F766E);
const kTealDark = Color(0xFF134E4A);
const kAmber = Color(0xFFFBBF24);

void showSnack(BuildContext context, String text, {Color? color, Duration? duration}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(text),
      backgroundColor: color,
      duration: duration ?? const Duration(seconds: 4),
    ));
}

Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirm,
  bool destructive = false,
}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Anulează', 'Cancel'))),
        FilledButton(
          style: destructive ? FilledButton.styleFrom(backgroundColor: Colors.red.shade700) : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirm),
        ),
      ],
    ),
  );
  return r ?? false;
}

// După trial, fără licență: adăugarea de angajați, graficul și rapoartele
// sunt blocate. Întoarce true dacă acțiunea poate continua.
Future<bool> ensureLicensed(BuildContext context) async {
  if (LicenseService.canAdd) return true;
  final open = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: Icon(Icons.lock_outline, color: Colors.red.shade700),
      title: Text(tr('Perioada de trial a expirat', 'The trial period has expired')),
      content: Text(tr(
          'Pontajul prin scanare continuă să funcționeze. Pentru a adăuga '
              'angajați, a genera grafice și rapoarte, activează licența.',
          'Clocking in by scanning keeps working. To add employees and to '
              'generate schedules and reports, activate the license.')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Închide', 'Close'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Licență', 'License'))),
      ],
    ),
  );
  if (open == true && context.mounted) {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const LicenseScreen()));
  }
  return false;
}

// Codul PIN (4–8 cifre). [confirm] cere introducerea de două ori.
Future<String?> askPin(BuildContext context,
    {required String title, bool confirm = false, String? message}) {
  final c1 = TextEditingController();
  final c2 = TextEditingController();
  String? error;
  return showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDs) {
        void submit() {
          final p = c1.text.trim();
          if (p.length < 4 || p.length > 8) {
            setDs(() => error = tr('PIN-ul are 4–8 cifre.', 'The PIN has 4–8 digits.'));
            return;
          }
          if (confirm && p != c2.text.trim()) {
            setDs(() => error = tr('PIN-urile nu coincid.', 'The PINs do not match.'));
            return;
          }
          Navigator.pop(ctx, p);
        }

        InputDecoration deco(String label, {String? err}) => InputDecoration(
              labelText: label,
              errorText: err,
              border: const OutlineInputBorder(),
              counterText: '',
            );
        return AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (message != null) ...[
                Text(message, style: const TextStyle(fontSize: 13)),
                const SizedBox(height: 12),
              ],
              TextField(
                controller: c1,
                autofocus: true,
                obscureText: true,
                maxLength: 8,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: deco(tr('PIN', 'PIN'), err: confirm ? null : error),
                onSubmitted: (_) => confirm ? null : submit(),
              ),
              if (confirm) ...[
                const SizedBox(height: 8),
                TextField(
                  controller: c2,
                  obscureText: true,
                  maxLength: 8,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: deco(tr('Repetă PIN-ul', 'Repeat the PIN'), err: error),
                  onSubmitted: (_) => submit(),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Anulează', 'Cancel'))),
            FilledButton(onPressed: submit, child: Text(tr('OK', 'OK'))),
          ],
        );
      },
    ),
  );
}

// Selector de dată, în limba aplicației.
Future<DateTime?> pickDate(BuildContext context, DateTime initial) => showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );

Future<TimeOfDay?> pickTime(BuildContext context, TimeOfDay initial) => showTimePicker(
      context: context,
      initialTime: initial,
      builder: (ctx, child) => MediaQuery(
        data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );

// Eticheta colorată a unei zile din grafic.
class DayChip extends StatelessWidget {
  final String label;
  final int color;
  final double width;
  final double height;
  final bool outlined;

  const DayChip({
    super.key,
    required this.label,
    required this.color,
    this.width = 34,
    this.height = 30,
    this.outlined = false,
  });

  @override
  Widget build(BuildContext context) => Container(
        width: width,
        height: height,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Color(color),
          borderRadius: BorderRadius.circular(4),
          border: outlined ? Border.all(color: Colors.black26) : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: isDarkColor(color) ? Colors.white : Colors.black87,
          ),
        ),
      );
}

// Chip-ul unei zile (cod din grafic).
Widget dayCodeChip(String code, Map<String, Shift> shifts, {double width = 34, double height = 30}) {
  if (DayCode.isShift(code)) {
    final s = shifts[code];
    if (s == null) return DayChip(label: '?', color: 0xFFFFFFFF, width: width, height: height, outlined: true);
    return DayChip(label: s.shortLabel, color: shiftColor(s), width: width, height: height);
  }
  if (code.isEmpty) {
    return DayChip(label: '', color: 0xFFFFFFFF, width: width, height: height, outlined: true);
  }
  return DayChip(label: DayCode.short(code), color: dayCodeColor(code), width: width, height: height);
}
