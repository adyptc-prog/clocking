package app.sayitapp.clocking

import android.content.Intent
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Build
import android.provider.DocumentsContract
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        const val SMS_CHANNEL     = "clocking/sms"
        const val LICENSE_CHANNEL = "clocking/license"
        const val BACKUP_CHANNEL  = "clocking/backup"
        const val DEVICE_CHANNEL  = "clocking/device"
        private const val PICK_LICENSE_REQUEST_CODE = 8021
        private const val PICK_BACKUP_FOLDER_REQUEST_CODE = 8022
        private const val PICK_RESTORE_BACKUP_REQUEST_CODE = 8023
    }

    // Licență cu businessId + expirare (format identic cu Fidelio)
    private var pendingLicensePickResult: MethodChannel.Result? = null

    // Backup: selectoarele de folder / fișier așteaptă rezultatul activității
    private var pendingBackupFolderResult: MethodChannel.Result? = null
    private var pendingBackupDestination: String = "phone"
    private var pendingRestoreResult: MethodChannel.Result? = null
    private var pendingRestoreKeepPartners: Boolean = true
    @Volatile
    private var lastPickedRestoreUri: android.net.Uri? = null

    private var toneGenerator: ToneGenerator? = null

    // ── Lifecycle ────────────────────────────────────────────────────────────────
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            PICK_BACKUP_FOLDER_REQUEST_CODE -> { handleBackupFolderResult(resultCode, data); return }
            PICK_RESTORE_BACKUP_REQUEST_CODE -> { handleRestoreResult(resultCode, data); return }
        }
        if (requestCode != PICK_LICENSE_REQUEST_CODE) return

        val result = pendingLicensePickResult ?: return
        pendingLicensePickResult = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            result.error("LICENSE_PICK_CANCELLED", tr("Nu a fost selectat niciun fișier de licență.", "No license file was selected."), null)
            return
        }

        try {
            val content = contentResolver.openInputStream(uri)?.use {
                it.reader(Charsets.UTF_8).readText()
            } ?: throw IllegalStateException(tr("Fișierul de licență nu a putut fi citit.", "Could not read license file."))
            result.success(LicenseStore.importLicense(this, content).toMap(uri.toString()))
        } catch (error: Exception) {
            result.error("LICENSE_PICK_FAILED", error.message ?: error.toString(), null)
        }
    }

    override fun onDestroy() {
        toneGenerator?.release()
        toneGenerator = null
        super.onDestroy()
    }

    // ── Flutter Engine ───────────────────────────────────────────────────────────
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        AppLang.sync(applicationContext)
        ClockingBackupWorker.schedule(applicationContext)

        // ── Canal Backup ──────────────────────────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BACKUP_CHANNEL)
            .setMethodCallHandler { call, result ->
                AppLang.sync(applicationContext)
                when (call.method) {
                    "getStatus" -> runInBackground(result, "BACKUP_STATUS_FAILED") {
                        BackupManager.status(this)
                    }
                    "pickFolder" -> pickBackupFolder(call.argument<String>("destination") ?: "phone", result)
                    "createBackup" -> runInBackground(result, "BACKUP_CREATE_FAILED") {
                        BackupManager.createBackup(this, auto = false)
                    }
                    "listBackups" -> runInBackground(result, "BACKUP_LIST_FAILED") {
                        BackupManager.listBackups(this)
                    }
                    "restoreBackup" -> {
                        val id = call.argument<String>("id")
                            ?: run { result.error("ARG", "missing id", null); return@setMethodCallHandler }
                        val keep = call.argument<Boolean>("keepSyncPartners") ?: true
                        val password = call.argument<String>("password")
                        runInBackground(result, "BACKUP_RESTORE_FAILED") {
                            BackupManager.restoreFromDocumentId(this, id, keep, password); null
                        }
                    }
                    "pickAndRestoreBackup" -> pickAndRestoreBackup(
                        call.argument<Boolean>("keepSyncPartners") ?: true, result
                    )
                    // Fișierul ales anterior era criptat: reîncercăm cu parola,
                    // fără să-l mai cerem din nou utilizatorului.
                    "retryPickedRestore" -> {
                        val uri = lastPickedRestoreUri
                            ?: run { result.error("ARG", "no picked backup", null); return@setMethodCallHandler }
                        val keep = call.argument<Boolean>("keepSyncPartners") ?: true
                        val password = call.argument<String>("password")
                        runInBackground(result, "BACKUP_RESTORE_FAILED") {
                            BackupManager.restoreFromUri(this, uri, keep, password)
                            lastPickedRestoreUri = null
                            null
                        }
                    }
                    "setPassword" -> {
                        val password = call.argument<String>("password")
                            ?: run { result.error("ARG", "missing password", null); return@setMethodCallHandler }
                        runInBackground(result, "BACKUP_PASSWORD_INVALID") {
                            BackupPassword.set(this, password)
                            BackupManager.status(this)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // ── Canal SMS (sincronizare cu telefonul partener) ────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SMS_CHANNEL)
            .setMethodCallHandler { call, result ->
                AppLang.sync(applicationContext)
                when (call.method) {
                    // Mesaj de sincronizare către partener, semnat cu codul de
                    // împerechere (SyncAuth). false = fără partener sau fără
                    // cod — nu s-a trimis nimic.
                    "sendSync" -> {
                        val message = call.argument<String>("message")
                            ?: run { result.error("ARG", "missing message", null); return@setMethodCallHandler }
                        result.success(SmsSyncReceiver.sendSigned(this, message))
                    }

                    "getSyncMessages" -> result.success(SmsSyncReceiver.snapshot(this))

                    "ackSyncMessages" -> {
                        val ids = call.argument<List<String>>("ids") ?: emptyList()
                        SmsSyncReceiver.acknowledge(this, ids)
                        result.success(null)
                    }

                    "getAutostartState" -> result.success(BackgroundStart.autostartState(this))

                    "openAutostartSettings" -> result.success(BackgroundStart.openAutostartSettings(this))

                    "getSmsFailure" -> result.success(SmsStatus.pendingFailure(this))

                    "dismissSmsFailure" -> {
                        SmsStatus.dismiss(this)
                        result.success(null)
                    }

                    else -> result.notImplemented()
                }
            }

        // ── Canal Licență ─────────────────────────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LICENSE_CHANNEL)
            .setMethodCallHandler { call, result ->
                AppLang.sync(applicationContext)
                when (call.method) {
                    "getBusinessId" -> result.success(LicenseStore.getOrCreateBusinessId(this))
                    "checkLicense" -> {
                        val map = LicenseStore.check(this).toMap(null)
                        // Trial-ul, calculat cu același ceas protejat ca licența.
                        val start = Entitlement.trialStartMs(this)
                        val now = LicenseStore.effectiveNow(this)
                        map["trialActive"] = Entitlement.isTrialActive(start, now)
                        map["trialDaysLeft"] = Entitlement.trialDaysLeft(start, now)
                        result.success(map)
                    }
                    "pickLicenseFile" -> pickLicenseFile(result)
                    // Trimite licența partenerului, dacă are voie:
                    // "sent" | "no_license" | "not_owner" | "other_partner" |
                    // "no_partner" (fără partener sau cod de împerechere).
                    "shareLicenseWithPartner" -> result.success(shareLicenseWithPartner())
                    "getLicenseShareInfo" -> result.success(LicenseStore.shareInfo(this))
                    "consumePartnerNotice" -> result.success(LicenseStore.consumePartnerNotice(this))

                    else -> result.notImplemented()
                }
            }

        // ── Canal Dispozitiv (ecranul de scanare) ─────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DEVICE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Telefonul de la intrare rămâne cu ecranul aprins cât timp
                    // e deschis ecranul de scanare.
                    "keepScreenOn" -> {
                        if (call.argument<Boolean>("on") == true) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                        result.success(null)
                    }
                    // Semnal sonor la scanare: scurt (acceptat) sau dublu (respins).
                    "beep" -> {
                        beep(call.argument<Boolean>("ok") ?: true)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun beep(ok: Boolean) {
        try {
            val tg = toneGenerator ?: ToneGenerator(AudioManager.STREAM_NOTIFICATION, 90)
                .also { toneGenerator = it }
            if (ok) {
                tg.startTone(ToneGenerator.TONE_PROP_BEEP, 150)
            } else {
                tg.startTone(ToneGenerator.TONE_PROP_NACK, 400)
            }
        } catch (e: Exception) {
            Diag.e("beep failed", e)
        }
    }

    private fun shareLicenseWithPartner(): String {
        if (!SmsSyncReceiver.isPaired(this)) return "no_partner"
        val (decision, license) = LicenseStore.shareTo(this, SmsSyncReceiver.partnerPhone(this))
        if (license == null) {
            return when (decision) {
                ShareDecision.NOT_OWNER -> "not_owner"
                ShareDecision.OTHER_PARTNER -> "other_partner"
                else -> "no_license"
            }
        }
        SmsSyncReceiver.sendSigned(this, SmsSyncReceiver.LICENSE_PREFIX + license)
        return "sent"
    }

    // ── Licență (verificarea, stocarea și preluarea de la partener sunt în
    // LicenseStore) ─────────────────────────────────────────────────────────────
    private fun pickLicenseFile(result: MethodChannel.Result) {
        if (pendingLicensePickResult != null) {
            result.error("LICENSE_PICK_BUSY", tr("Un selector de licență este deja deschis.", "A license picker is already open."), null)
            return
        }

        pendingLicensePickResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("application/json", "text/*", "application/octet-stream"))
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivityForResult(intent, PICK_LICENSE_REQUEST_CODE)
    }

    // ── Backup ───────────────────────────────────────────────────────────────────
    // Operațiile pe fișiere (stick USB) nu blochează interfața.
    private fun runInBackground(result: MethodChannel.Result, errorCode: String, work: () -> Any?) {
        Thread {
            try {
                val value = work()
                runOnUiThread { result.success(value) }
            } catch (e: BackupManager.PasswordException) {
                runOnUiThread { result.error(e.code, e.message, null) }
            } catch (e: Exception) {
                runOnUiThread { result.error(errorCode, e.message ?: e.toString(), null) }
            }
        }.start()
    }

    private fun pickBackupFolder(destination: String, result: MethodChannel.Result) {
        if (pendingBackupFolderResult != null) {
            result.error("BACKUP_PICK_BUSY", tr("Un selector de folder este deja deschis.", "A backup folder picker is already open."), null)
            return
        }
        pendingBackupFolderResult = result
        pendingBackupDestination = destination
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            // Memoria telefonului: pornim din Documents, unde backup-ul
            // supraviețuiește dezinstalării aplicației.
            if (destination == "phone" && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                putExtra(
                    DocumentsContract.EXTRA_INITIAL_URI,
                    DocumentsContract.buildDocumentUri(
                        "com.android.externalstorage.documents", "primary:Documents"
                    )
                )
            }
        }
        startActivityForResult(intent, PICK_BACKUP_FOLDER_REQUEST_CODE)
    }

    private fun handleBackupFolderResult(resultCode: Int, data: Intent?) {
        val result = pendingBackupFolderResult ?: return
        pendingBackupFolderResult = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            result.error("BACKUP_PICK_CANCELLED", tr("Nu a fost selectat niciun folder de backup.", "No backup folder was selected."), null)
            return
        }
        runInBackground(result, "BACKUP_PICK_FAILED") {
            BackupManager.setFolder(this, uri, pendingBackupDestination)
            BackupManager.status(this)
        }
    }

    private fun pickAndRestoreBackup(keepSyncPartners: Boolean, result: MethodChannel.Result) {
        if (pendingRestoreResult != null) {
            result.error("RESTORE_PICK_BUSY", tr("Un selector de backup este deja deschis.", "A backup picker is already open."), null)
            return
        }
        pendingRestoreResult = result
        pendingRestoreKeepPartners = keepSyncPartners
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivityForResult(intent, PICK_RESTORE_BACKUP_REQUEST_CODE)
    }

    private fun handleRestoreResult(resultCode: Int, data: Intent?) {
        val result = pendingRestoreResult ?: return
        pendingRestoreResult = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            result.error("RESTORE_PICK_CANCELLED", tr("Nu a fost selectat niciun fișier de backup.", "No backup file was selected."), null)
            return
        }
        val keep = pendingRestoreKeepPartners
        lastPickedRestoreUri = uri
        runInBackground(result, "BACKUP_RESTORE_FAILED") {
            BackupManager.restoreFromUri(this, uri, keep)
            lastPickedRestoreUri = null
            null
        }
    }
}
