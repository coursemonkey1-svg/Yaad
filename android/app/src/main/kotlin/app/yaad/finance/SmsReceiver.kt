package app.yaad.finance

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import android.util.Log
import org.json.JSONObject
import java.io.File

/**
 * Manifest-declared SMS receiver. It ONLY queues messages when the user
 * has explicitly opted in (flag in app-private SharedPreferences, written
 * by Dart when the toggle flips). When opted out it returns immediately
 * without reading anything.
 *
 * Queued messages are drained by Dart on next app open and parsed
 * on-device. Nothing ever leaves the phone.
 */
class SmsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return
        val prefs =
            context.getSharedPreferences("yaad_capture", Context.MODE_PRIVATE)
        if (!prefs.getBoolean("sms_enabled", false)) return

        try {
            val messages = Telephony.Sms.Intents.getMessagesFromIntent(intent)
            val sender = messages.firstOrNull()?.originatingAddress ?: return
            val body = messages.joinToString("") { it.messageBody ?: "" }
            if (body.isBlank()) return
            val obj = JSONObject()
                .put("sender", sender)
                .put("body", body)
                .put("timestamp", System.currentTimeMillis())
            File(context.filesDir, "sms_queue.jsonl")
                .appendText(obj.toString() + "\n")
        } catch (e: Exception) {
            Log.w("YaadSms", "failed to queue sms", e)
        }
    }
}
