package app.yaad.finance

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.provider.Settings
import android.text.TextUtils
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File

/**
 * "yaad/capture" channel: opt-in flags, queue draining, and
 * notification-access checks for the SMS/notification capture (§6).
 */
object CaptureChannel {
    private const val CHANNEL = "yaad/capture"
    private const val PREFS = "yaad_capture"

    fun register(engine: FlutterEngine, context: Context) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setSmsEnabled" -> {
                        val on = call.argument<Boolean>("enabled") ?: false
                        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                            .edit().putBoolean("sms_enabled", on).apply()
                        result.success(null)
                    }
                    "setNotificationEnabled" -> {
                        val on = call.argument<Boolean>("enabled") ?: false
                        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                            .edit().putBoolean("notification_enabled", on)
                            .apply()
                        result.success(null)
                    }
                    "drainSmsQueue" ->
                        result.success(drain(context, "sms_queue.jsonl"))
                    "drainNotifQueue" ->
                        result.success(drain(context, "notif_queue.jsonl"))
                    "clearCaptureQueues" -> {
                        // Factory wipe: alerts queued before the wipe
                        // must not be imported if capture is ever
                        // turned on again afterwards.
                        for (name in listOf(
                            "sms_queue.jsonl", "notif_queue.jsonl")) {
                            val f = File(context.filesDir, name)
                            if (f.exists()) f.delete()
                        }
                        result.success(null)
                    }
                    "isNotificationAccessGranted" ->
                        result.success(isListenerEnabled(context))
                    "openNotificationSettings" -> {
                        try {
                            val intent = Intent(
                                Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            context.startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Reads queued items and clears the queue — each item drains once.
     *
     * The swap is atomic: the queue file is RENAMED aside first and the
     * copy is parsed. The writers (SMS receiver / notification
     * listener, other threads) append to the original path; the old
     * read-then-truncate version wiped any alert that was appended
     * between the read and the truncate without ever returning it —
     * a bank alert that demonstrably arrived simply never appeared.
     * After the rename, appends land in a fresh file for the next drain.
     */
    private fun drain(context: Context, name: String): List<Map<String, Any?>> {
        val out = mutableListOf<Map<String, Any?>>()
        val swapped = File(context.filesDir, "$name.draining")
        // A leftover swap file means a previous drain died between the
        // rename and the parse: its items were never returned, so
        // recover them first rather than dropping them.
        if (swapped.exists()) {
            parseInto(swapped, out)
            swapped.delete()
        }
        val file = File(context.filesDir, name)
        if (!file.exists()) return out
        if (!file.renameTo(swapped)) return out
        parseInto(swapped, out)
        swapped.delete()
        return out
    }

    private fun parseInto(file: File, out: MutableList<Map<String, Any?>>) {
        for (line in file.readLines()) {
            if (line.isBlank()) continue
            try {
                val o = JSONObject(line)
                val map = mutableMapOf<String, Any?>()
                val keys = o.keys()
                while (keys.hasNext()) {
                    val k = keys.next()
                    map[k] = o.opt(k)
                }
                out.add(map)
            } catch (_: Exception) {
                // Corrupt line: skip it.
            }
        }
    }

    private fun isListenerEnabled(context: Context): Boolean {
        val pkg = context.packageName
        val flat = Settings.Secure.getString(
            context.contentResolver, "enabled_notification_listeners")
        if (!TextUtils.isEmpty(flat)) {
            for (name in flat.split(":")) {
                val cn = ComponentName.unflattenFromString(name)
                if (cn != null && TextUtils.equals(pkg, cn.packageName)) {
                    return true
                }
            }
        }
        return false
    }
}
