import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../license_service.dart';

typedef SyncQueueEntry = ({String id, String msg});

// ─── Sincronizare bidirecțională prin SMS cu telefonul partener ───────────────
// Mesajele (vezi SyncCodec) sunt semnate nativ cu codul de împerechere
// (SyncAuth.kt) și primite de SmsSyncReceiver.kt, care le pune într-o coadă
// citită de aici.
class SyncService {
  static const _ch = MethodChannel('clocking/sms');
  static const partnerKey = 'sync_partner_phone';
  static const secretKey = 'sync_secret';
  static const minCodeLength = 8;

  static String? _partnerPhone;
  static String? _pairingCode;

  @visibleForTesting
  static bool? debugIsAndroid;
  static bool get isSupported => debugIsAndroid ?? Platform.isAndroid;

  // Activă doar cu număr ȘI cod de împerechere — fără cod, partenerul ar
  // respinge toate mesajele (sunt semnate).
  static bool get isActive =>
      _partnerPhone != null && _partnerPhone!.isNotEmpty && isValidCode(_pairingCode);
  static String? get partnerPhone => _partnerPhone;
  static String? get pairingCode =>
      _pairingCode == null ? null : formatCode(_pairingCode!);

  // Identic cu SyncAuth.normalizeCode din Kotlin.
  static String normalizeCode(String? code) =>
      (code ?? '').toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

  static bool isValidCode(String? code) =>
      normalizeCode(code).length >= minCodeLength;

  // „K7QM2XPA” → „K7QM-2XPA”, ușor de citit și de tastat pe celălalt telefon.
  static String formatCode(String code) {
    final n = normalizeCode(code);
    final groups = <String>[];
    for (var i = 0; i < n.length; i += 4) {
      groups.add(n.substring(i, min(i + 4, n.length)));
    }
    return groups.join('-');
  }

  // Fără caractere ușor de confundat (0/O, 1/I/L).
  static String generateCode() {
    const alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
    final r = Random.secure();
    return formatCode(
        List.generate(minCodeLength, (_) => alphabet[r.nextInt(alphabet.length)]).join());
  }

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _partnerPhone = prefs.getString(partnerKey);
    _pairingCode = prefs.getString(secretKey);
  }

  static Future<void> setPartner(String phone, String code) async {
    _partnerPhone = phone.trim();
    _pairingCode = normalizeCode(code);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(partnerKey, _partnerPhone!);
    await prefs.setString(secretKey, _pairingCode!);
  }

  static Future<void> clearPartner() async {
    _partnerPhone = null;
    _pairingCode = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(partnerKey);
    await prefs.remove(secretKey);
  }

  // ── Permisiunea SMS ─────────────────────────────────────────────────────────
  static Future<bool> hasSmsPermission() async {
    if (!isSupported) return false;
    try {
      return await Permission.sms.isGranted;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> requestSmsPermission() async {
    if (!isSupported) return false;
    try {
      return (await Permission.sms.request()).isGranted;
    } catch (_) {
      return false;
    }
  }

  // ── Trimitere ───────────────────────────────────────────────────────────────
  // Semnarea și trimiterea se fac nativ (SmsSyncReceiver.sendSigned).
  static Future<bool> send(String msg) async {
    if (!isActive || !isSupported) return false;
    try {
      return await _ch.invokeMethod<bool>('sendSync', {'message': msg}) ?? false;
    } catch (_) {
      return false;
    }
  }

  // Trimite mesajele pe rând, cu pauză între SMS-uri (limitele operatorului).
  static Future<void> sendAll(List<String> messages,
      {void Function(int done, int total)? onProgress}) async {
    for (var i = 0; i < messages.length; i++) {
      await send(messages[i]);
      onProgress?.call(i + 1, messages.length);
      if (i < messages.length - 1) {
        await Future<void>.delayed(const Duration(milliseconds: 1500));
      }
    }
  }

  // Licența cumpărată merge pe ambele telefoane sincronizate. La împerechere,
  // telefonul cu licență o trimite („L”), iar cel fără licență o cere („R”).
  static Future<void> sendLicenseHandshake() async {
    if (!isActive) return;
    final status = await LicenseService.shareWithPartner();
    if (status == 'no_license') await send('CLK:R:');
  }

  // ── Coada mesajelor primite ─────────────────────────────────────────────────
  static Future<List<SyncQueueEntry>> getPendingMessages() async {
    if (!isSupported) return [];
    try {
      final raw = await _ch.invokeMethod<String>('getSyncMessages') ?? '[]';
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .map<SyncQueueEntry?>((e) {
            if (e is! Map) return null;
            final id = e['id'] as String?;
            final msg = e['msg'] as String?;
            if (id == null || id.isEmpty) return null;
            return (id: id, msg: msg ?? '');
          })
          .whereType<SyncQueueEntry>()
          .toList();
    } catch (_) {
      return [];
    }
  }

  // Scoate din coadă doar intrările procesate — nu și pe cele sosite între timp.
  static Future<void> ackMessages(List<String> ids) async {
    if (!isSupported || ids.isEmpty) return;
    try {
      await _ch.invokeMethod<void>('ackSyncMessages', {'ids': ids});
    } catch (_) {}
  }

  // ── Starea SMS-urilor (eșecuri, Xiaomi) ─────────────────────────────────────
  static Future<({DateTime failedAt, String phone, String reason})?> pendingFailure() async {
    if (!isSupported) return null;
    try {
      final r = await _ch.invokeMethod<Map<Object?, Object?>>('getSmsFailure');
      if (r == null) return null;
      return (
        failedAt: DateTime.fromMillisecondsSinceEpoch((r['failedAt'] as int?) ?? 0),
        phone: (r['phone'] as String?) ?? '',
        reason: (r['reason'] as String?) ?? '',
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> dismissFailure() async {
    if (!isSupported) return;
    try {
      await _ch.invokeMethod<void>('dismissSmsFailure');
    } catch (_) {}
  }

  // Xiaomi: fără „Pornire automată” SMS-urile partenerului nu sunt primite cu
  // aplicația închisă.
  static Future<bool> autostartBlocked() async {
    if (!isSupported) return false;
    try {
      return await _ch.invokeMethod<String>('getAutostartState') == 'denied';
    } catch (_) {
      return false;
    }
  }

  static Future<void> openAutostartSettings() async {
    try {
      await _ch.invokeMethod<bool>('openAutostartSettings');
    } catch (_) {}
  }
}

// ─── Dispozitivul de scanare: ecran aprins, semnal sonor ──────────────────────
class DeviceService {
  static const _ch = MethodChannel('clocking/device');

  static Future<void> keepScreenOn(bool on) async {
    try {
      await _ch.invokeMethod<void>('keepScreenOn', {'on': on});
    } catch (_) {}
  }

  static Future<void> beep({required bool ok}) async {
    try {
      await _ch.invokeMethod<void>('beep', {'ok': ok});
    } catch (_) {}
  }
}
