import 'models.dart';

// ─── Logica scanării (pură, testabilă) ────────────────────────────────────────

// Id-ul și secretul din codul QR al unui angajat, sau null dacă nu e un cod
// Clocking.
({String id, String secret})? parseQr(String raw) {
  final parts = raw.trim().split(':');
  if (parts.length != 3 || parts[0] != Employee.qrPrefix) return null;
  if (parts[1].isEmpty || parts[2].isEmpty) return null;
  return (id: parts[1], secret: parts[2]);
}

enum ScanOutcome {
  clockIn,
  clockOut,
  // Același angajat scanat din nou în câteva minute — ignorat.
  duplicate,
}

// Durata maximă a unei ture deschise: cu tura din grafic, durata ei + 4 ore
// (o gardă de 24h închisă a doua zi rămâne „ieșire”); fără grafic, 16 ore.
// Peste ea, o intrare fără ieșire e considerată uitată, iar scanarea
// următoare e o intrare nouă.
Duration maxOpenDuration(Shift? scheduledShift) => scheduledShift == null
    ? const Duration(hours: 16)
    : Duration(minutes: scheduledShift.durationMinutes + 4 * 60);

// Ce înseamnă o scanare nouă, după ultimul pontaj (neșters) al angajatului.
ScanOutcome decideScan({
  required Punch? last,
  required DateTime now,
  required Duration duplicateWindow,
  required Duration maxOpen,
}) {
  if (last == null) return ScanOutcome.clockIn;
  final since = now.difference(last.at);
  if (!since.isNegative && since < duplicateWindow) return ScanOutcome.duplicate;
  if (last.isIn && since <= maxOpen) return ScanOutcome.clockOut;
  return ScanOutcome.clockIn;
}
