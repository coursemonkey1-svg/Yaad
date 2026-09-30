package app.yaad.finance

import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

// Must extend FlutterFragmentActivity (not FlutterActivity): local_auth's
// authenticate() needs a FragmentActivity to show its prompt. With
// FlutterActivity the PlatformException was swallowed and the app silently
// unlocked.
class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        CaptureChannel.register(flutterEngine, this)
    }
}
