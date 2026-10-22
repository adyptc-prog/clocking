package app.sayitapp.clocking

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.provider.Telephony
import org.json.JSONArray
import org.json.JSONObject

/**
 * Ascultă SMS-urile primite și stochează în coadă pe cele cu prefix CLK:
 * (mesaje de sincronizare trimise de celălalt telefon Clocking). Mesajele
 * trebuie să vină de la partenerul configurat ȘI să fie semnate cu codul de
 * împerechere (vezi SyncAuth) — celelalte sunt ignorate.
 *
 * Flutter citește coada la pornire, periodic și la revenire în foreground via
 * MethodChannel "clocking/sms" → getSyncMessages / ackSyncMessages.
 */
class SmsSyncReceiver : BroadcastReceiver() {

    companion object {
        const val SYNC_PREFIX = "CLK:"
        const val PREFS_NAME  = "SyncQueue"
        const val QUEUE_KEY   = "queue"

        // Licența se împarte între cele două telefoane sincronizate: „L” poartă
        // fișierul de licență semnat, „R” e cererea unui telefon fără licență
        // (trimisă când își configurează partenerul după ce celălalt a făcut-o
        // deja — altfel licența trimisă atunci ar fi fost ignorată).
        const val LICENSE_PREFIX         = "CLK:L:"
        const val LICENSE_REQUEST_PREFIX = "CLK:R:"

        const val PARTNER_PHONE_KEY = "flutter.sync_partner_phone"
        const val SECRET_KEY        = "flutter.sync_secret"

        private val QUEUE_LOCK = Any()

        /**
         * Adaugă un mesaj primit de la partener în coadă. Fiecare intrare are
         * un „id” unic, ca Flutter să confirme (și să scoată din coadă) exact
         * intrările procesate — nu și pe cele sosite între timp.
         */
        fun enqueue(context: Context, msg: String) {
            synchronized(QUEUE_LOCK) {
                val prefs = queuePrefs(context)
                val arr = readQueue(prefs)
                arr.put(JSONObject().put("id", newEntryId()).put("msg", msg))
                prefs.edit().putString(QUEUE_KEY, arr.toString()).commit()
            }
        }

        /** Coada, ca JSON, pentru Flutter. */
        fun snapshot(context: Context): String = synchronized(QUEUE_LOCK) {
            readQueue(queuePrefs(context)).toString()
        }

        /** Scoate din coadă doar intrările procesate de Flutter. */
        fun acknowledge(context: Context, ids: Collection<String>) {
            if (ids.isEmpty()) return
            val done = ids.toSet()
            synchronized(QUEUE_LOCK) {
                val prefs = queuePrefs(context)
                val arr = readQueue(prefs)
                val remaining = JSONArray()
                for (i in 0 until arr.length()) {
                    val entry = arr.optJSONObject(i)
                    if (entry != null && entry.optString("id") in done) continue
                    remaining.put(arr.opt(i))
                }
                prefs.edit().putString(QUEUE_KEY, remaining.toString()).commit()
            }
        }

        private fun flutterPrefs(context: Context): SharedPreferences =
            context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)

        fun partnerPhone(context: Context): String =
            flutterPrefs(context).getString(PARTNER_PHONE_KEY, null)?.trim().orEmpty()

        fun pairingCode(context: Context): String? =
            flutterPrefs(context).getString(SECRET_KEY, null)

        /** Partener și cod valid configurate — altfel nu se trimite nimic. */
        fun isPaired(context: Context): Boolean =
            partnerPhone(context).isNotEmpty() && SyncAuth.isValidCode(pairingCode(context))

        /**
         * Trimite [message] (ex. „CLK:P:{...}”) partenerului, semnat cu codul
         * de împerechere. Fără partener sau fără cod valid nu trimite nimic
         * (partenerul l-ar respinge oricum).
         */
        fun sendSigned(context: Context, message: String): Boolean {
            if (!isPaired(context)) return false
            SmsSender.send(context, partnerPhone(context), SyncAuth.sign(pairingCode(context)!!, message))
            return true
        }

        private fun queuePrefs(context: Context): SharedPreferences =
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

        // JSON corupt = coadă goală, nu excepție (altfel nimic nu mai intră).
        private fun readQueue(prefs: SharedPreferences): JSONArray = try {
            JSONArray(prefs.getString(QUEUE_KEY, "[]") ?: "[]")
        } catch (_: Exception) {
            JSONArray()
        }

        private fun newEntryId(): String = java.util.UUID.randomUUID().toString()
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return

        val pdus = Telephony.Sms.Intents.getMessagesFromIntent(intent)
            ?: return

        // Grupăm PDU-urile pe expeditor și concatenăm corpul
        // (SMS multipart: toate segmentele sosesc în același broadcast)
        val bySender = mutableMapOf<String, StringBuilder>()
        for (sms in pdus) {
            val sender = sms.originatingAddress ?: continue
            val body   = sms.messageBody        ?: continue
            bySender.getOrPut(sender) { StringBuilder() }.append(body)
        }

        for ((sender, sb) in bySender) handleSms(context, sender, sb.toString())
    }

    // internal: apelat direct de teste.
    internal fun handleSms(context: Context, sender: String, rawBody: String) {
        if (!rawBody.startsWith(SYNC_PREFIX)) return
        AppLang.sync(context)

        // Doar de la partenerul configurat ȘI semnat cu codul de împerechere —
        // altfel oricine ne știe numărul (sau falsifică numărul partenerului)
        // ar putea adăuga sau șterge angajați și pontaje.
        val body = if (Phones.sameNumber(sender, partnerPhone(context))) {
            SyncAuth.verify(pairingCode(context), rawBody)
        } else {
            null
        }
        if (body == null) {
            Diag.w("sync message rejected: unknown sender or invalid signature")
            return
        }

        if (body.startsWith(LICENSE_PREFIX)) {
            try {
                val decision = LicenseStore.adoptFromPartner(
                    context, body.removePrefix(LICENSE_PREFIX)
                )
                Diag.i("license from partner: $decision")
            } catch (e: Exception) {
                Diag.e("license from partner FAILED", e)
            }
            return
        }
        if (body.startsWith(LICENSE_REQUEST_PREFIX)) {
            // Doar telefonul care a importat licența, și doar partenerului ei.
            val (decision, license) = LicenseStore.shareTo(context, sender)
            Diag.i("license request from partner: $decision")
            if (license != null) sendSigned(context, LICENSE_PREFIX + license)
            return
        }

        enqueue(context, body)
    }
}
