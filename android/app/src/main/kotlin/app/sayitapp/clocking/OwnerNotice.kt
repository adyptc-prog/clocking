package app.sayitapp.clocking

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import java.util.concurrent.atomic.AtomicInteger

/**
 * Notificări pentru manager despre ce s-a întâmplat fără el (de ex. backup-ul
 * automat eșuat) — altfel ar afla doar deschizând ecranul respectiv.
 */
object OwnerNotice {

    const val CHANNEL_ID = "clocking_alerts"
    private const val ID_BASE = 950_000_000
    private val counter = AtomicInteger((System.currentTimeMillis() % 1_000_000).toInt())

    /** Canalul notificărilor aplicației. */
    fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                tr("Alerte Clocking", "Clocking alerts"),
                NotificationManager.IMPORTANCE_HIGH,
            ).apply { enableVibration(true) }
        )
    }

    fun show(context: Context, title: String, body: String) {
        try {
            AppLang.sync(context)
            ensureChannel(context)
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val iconRes = context.resources.getIdentifier("ic_launcher", "mipmap", context.packageName)
            val icon = if (iconRes != 0) iconRes else android.R.drawable.ic_dialog_info
            val open = context.packageManager.getLaunchIntentForPackage(context.packageName)
                ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(context, CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context).setPriority(Notification.PRIORITY_HIGH)
            }
            builder.setSmallIcon(icon)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(Notification.BigTextStyle().bigText(body))
                .setAutoCancel(true)
            if (open != null) builder.setContentIntent(PendingIntent.getActivity(context, 0, open, flags))
            nm.notify(ID_BASE + counter.incrementAndGet() % 1_000_000, builder.build())
        } catch (e: Exception) {
            // Fără permisiunea de notificări (Android 13+) — nu blocăm restul.
            Diag.e("OwnerNotice failed", e)
        }
    }
}
