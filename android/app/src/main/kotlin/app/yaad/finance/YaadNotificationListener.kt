package app.yaad.finance

import android.content.Context
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import org.json.JSONObject
import java.io.File

/**
 * Notification listener for bank transaction alerts. Runs only when the
 * user opts in (system notification-access grant + in-app toggle); the
 * flag lives in app-private SharedPreferences and is checked before any
 * notification content is touched.
 *
 * Only notifications that look like money alerts are queued (amount +
 * money words). Dart parses them on-device on next app open.
 */
class YaadNotificationListener : NotificationListenerService() {

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        val prefs =
            getSharedPreferences("yaad_capture", Context.MODE_PRIVATE)
        if (!prefs.getBoolean("notification_enabled", false)) return

        try {
            val extras = sbn.notification.extras
            val title =
                extras.getCharSequence("android.title")?.toString() ?: ""
            val text =
                extras.getCharSequence("android.text")?.toString() ?: ""
            val bigText =
                extras.getCharSequence("android.bigText")?.toString() ?: ""
            val body = listOf(title, text, bigText)
                .filter { it.isNotBlank() }
                .joinToString("\n")
            if (body.isBlank() || !looksLikeMoneyAlert(body)) return

            val obj = JSONObject()
                .put("package", sbn.packageName)
                .put("body", body)
                .put("timestamp", sbn.postTime)
            File(filesDir, "notif_queue.jsonl")
                .appendText(obj.toString() + "\n")
        } catch (e: Exception) {
            Log.w("YaadNotif", "failed to queue notification", e)
        }
    }

    private fun looksLikeMoneyAlert(body: String): Boolean {
        val hasAmount = Regex("(?i)\\b(PKR|Rs\\.?)\\b").containsMatchIn(body) &&
            Regex("[\\d,]+\\.\\d{2}").containsMatchIn(body)
        val hasMoneyWord =
            Regex("(?i)debit|credit|withdraw|deposit|paid|received|transfer|transaction|balance")
                .containsMatchIn(body)
        return hasAmount && hasMoneyWord
    }
}
