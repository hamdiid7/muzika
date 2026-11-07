package et.muzika.app

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import ca.psiphon.PsiphonTunnel
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Runs the Psiphon tunnel in-process and exposes it to Dart.
 *
 * Psiphon opens a local HTTP proxy (127.0.0.1:<port>); the Dart side points
 * every HttpClient at it, so API calls and audio share one exit IP.
 *
 * The tunnel is a process-wide singleton: it keeps running while audio plays
 * in the background, and a re-created Activity re-attaches to it.
 */
class PsiphonBridge private constructor(private val appContext: Context) :
    PsiphonTunnel.HostService {

    companion object {
        private const val TAG = "MuzikaTunnel"
        private const val CONFIG_ASSET = "psiphon_config.json"

        @Volatile private var instance: PsiphonBridge? = null

        fun attach(context: Context, messenger: BinaryMessenger): PsiphonBridge {
            val bridge = instance ?: synchronized(this) {
                instance ?: PsiphonBridge(context.applicationContext).also { instance = it }
            }
            bridge.bind(messenger)
            return bridge
        }
    }

    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private var tunnel: PsiphonTunnel? = null
    private var sink: EventChannel.EventSink? = null

    @Volatile private var httpPort = 0
    @Volatile private var connected = false

    private fun bind(messenger: BinaryMessenger) {
        MethodChannel(messenger, "muzika/tunnel").setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> result.success(start())
                "stop" -> {
                    stop()
                    result.success(null)
                }
                "status" -> result.success(
                    mapOf("connected" to connected, "httpPort" to httpPort)
                )
                else -> result.notImplemented()
            }
        }
        EventChannel(messenger, "muzika/tunnel/events").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    sink = events
                    // Replay the current state to a newly attached Dart side.
                    if (connected && httpPort > 0) {
                        emit(mapOf("type" to "connected", "httpPort" to httpPort))
                    }
                }

                override fun onCancel(arguments: Any?) {
                    sink = null
                }
            },
        )
    }

    private fun hasConfig(): Boolean =
        runCatching { appContext.assets.open(CONFIG_ASSET).close() }.isSuccess

    private fun start(): String {
        if (!hasConfig()) return "no_config"
        if (connected && httpPort > 0) {
            emit(mapOf("type" to "connected", "httpPort" to httpPort))
            return "connected"
        }
        worker.execute {
            try {
                val t = tunnel ?: PsiphonTunnel.newPsiphonTunnel(this).also { tunnel = it }
                t.startTunneling("")
            } catch (e: Exception) {
                Log.e(TAG, "startTunneling failed", e)
                emit(mapOf("type" to "error", "message" to (e.message ?: "start failed")))
            }
        }
        return "starting"
    }

    private fun stop() {
        connected = false
        httpPort = 0
        worker.execute { runCatching { tunnel?.stop() } }
    }

    private fun emit(event: Map<String, Any?>) {
        main.post { sink?.success(event) }
    }

    // --- PsiphonTunnel.HostService ---

    override fun getContext(): Context = appContext

    override fun getPsiphonConfig(): String =
        appContext.assets.open(CONFIG_ASSET).bufferedReader().use { it.readText() }

    override fun onDiagnosticMessage(message: String) {
        Log.d(TAG, message)
    }

    override fun onListeningHttpProxyPort(port: Int) {
        httpPort = port
    }

    override fun onConnecting() {
        connected = false
        emit(mapOf("type" to "connecting"))
    }

    override fun onConnected() {
        connected = true
        emit(mapOf("type" to "connected", "httpPort" to httpPort))
    }

    override fun onExiting() {
        connected = false
        emit(mapOf("type" to "stopped"))
    }
}
