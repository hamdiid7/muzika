package et.muzika.app

import android.os.Build
import android.os.Bundle
import androidx.core.view.WindowCompat
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : AudioServiceActivity() {
    private var tunnel: PsiphonBridge? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // Aligns the Flutter view vertically with the window.
        WindowCompat.setDecorFitsSystemWindows(window, false)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // Avoid a flicker before the matching Flutter frame is drawn.
            splashScreen.setOnExitAnimationListener { view -> view.remove() }
        }

        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        tunnel = PsiphonBridge.attach(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        SmartCrop.attach(flutterEngine.dartExecutor.binaryMessenger)
    }
}
