package et.muzika.app

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Stand-in used when the app is built without Psiphon (the default, which
 * keeps the APK ~30 MB smaller). Answers the same channels so the Dart side
 * simply reports the tunnel as unavailable. Build with
 * `--android-project-arg muzikaPsiphon=true` to get the real bridge.
 */
class PsiphonBridge private constructor() {
    companion object {
        fun attach(context: Context, messenger: BinaryMessenger): PsiphonBridge {
            MethodChannel(messenger, "muzika/tunnel").setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> result.success("not_included")
                    "stop" -> result.success(null)
                    else -> result.notImplemented()
                }
            }
            EventChannel(messenger, "muzika/tunnel/events").setStreamHandler(
                object : EventChannel.StreamHandler {
                    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {}
                    override fun onCancel(arguments: Any?) {}
                },
            )
            return PsiphonBridge()
        }
    }
}
