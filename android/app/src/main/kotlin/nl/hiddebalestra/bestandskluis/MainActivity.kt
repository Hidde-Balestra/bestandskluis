package nl.hiddebalestra.bestandskluis

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

// FlutterFragmentActivity is nodig voor de vingerafdrukprompt.
class MainActivity : FlutterFragmentActivity(), SensorEventListener {
    private var channel: MethodChannel? = null
    private val main = Handler(Looper.getMainLooper())

    // Automatisch vergrendelen (instellingen uit Dart).
    private var lockOnScreenOff = false
    private var lockOnFaceDown = false
    private var faceDownSince = 0L
    private var screenReceiver: BroadcastReceiver? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel = ch
        active = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "vergrendelInstellingen" -> {
                    val a = call.arguments as? Map<*, *>
                    lockOnScreenOff = a?.get("schermUit") == true
                    lockOnFaceDown = a?.get("omdraaien") == true
                    updateScreenReceiver()
                    updateSensor()
                    result.success(null)
                }
                "widgetBijwerken" -> {
                    VaultWidget.refresh(this)
                    result.success(null)
                }
                // Schermafbeeldingen blokkeren en inhoud verbergen in "recente apps".
                "beveiligScherm" -> {
                    if (call.arguments == true) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    }
                    result.success(null)
                }
                "startServerDienst" -> {
                    val i = Intent(this, FtpService::class.java)
                        .putExtra(FtpService.EXTRA_TEXT, call.arguments as? String)
                    if (Build.VERSION.SDK_INT >= 26) startForegroundService(i) else startService(i)
                    result.success(null)
                }
                "stopServerDienst" -> {
                    stopService(Intent(this, FtpService::class.java))
                    result.success(null)
                }
                "videoMiniatuur" -> {
                    val args = call.arguments as? Map<*, *>
                    if (args == null) result.success(null)
                    else VideoThumbs.make(args) { result.success(it) }
                }
                "naarAchtergrond" -> {
                    moveTaskToBack(true)
                    result.success(null)
                }
                // Het intent waarmee de app is gestart (delen, ftp-link).
                "binnenkomend" -> readIntent(intent) { result.success(it) }
                else -> result.notImplemented()
            }
        }
    }

    // --- Vergrendelen bij scherm uit / omdraaien ----------------------------

    private fun updateScreenReceiver() {
        if (lockOnScreenOff && screenReceiver == null) {
            val r = object : BroadcastReceiver() {
                override fun onReceive(c: Context, i: Intent) {
                    if (i.action == Intent.ACTION_SCREEN_OFF) lockAll("scherm")
                }
            }
            val filter = IntentFilter(Intent.ACTION_SCREEN_OFF)
            if (Build.VERSION.SDK_INT >= 33) {
                registerReceiver(r, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                registerReceiver(r, filter)
            }
            screenReceiver = r
        } else if (!lockOnScreenOff && screenReceiver != null) {
            try {
                unregisterReceiver(screenReceiver)
            } catch (_: Exception) {
            }
            screenReceiver = null
        }
    }

    private fun sensors() = getSystemService(Context.SENSOR_SERVICE) as SensorManager

    private fun updateSensor() {
        val sm = sensors()
        sm.unregisterListener(this)
        faceDownSince = 0L
        if (lockOnFaceDown && hasWindowFocus()) {
            sm.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)?.let {
                sm.registerListener(this, it, SensorManager.SENSOR_DELAY_NORMAL)
            }
        }
    }

    override fun onResume() {
        super.onResume()
        if (lockOnFaceDown) {
            sensors().getDefaultSensor(Sensor.TYPE_ACCELEROMETER)?.let {
                sensors().registerListener(this, it, SensorManager.SENSOR_DELAY_NORMAL)
            }
        }
    }

    override fun onPause() {
        sensors().unregisterListener(this)
        faceDownSince = 0L
        super.onPause()
    }

    override fun onDestroy() {
        screenReceiver?.let {
            try {
                unregisterReceiver(it)
            } catch (_: Exception) {
            }
        }
        screenReceiver = null
        if (active == channel) active = null
        super.onDestroy()
    }

    // Scherm naar beneden (z ≈ -9,8 m/s²) gedurende 0,8 s: vergrendelen.
    override fun onSensorChanged(e: SensorEvent) {
        val z = e.values[2]
        val now = System.currentTimeMillis()
        if (z < -8.5f) {
            if (faceDownSince == 0L) {
                faceDownSince = now
            } else if (now - faceDownSince > 800) {
                faceDownSince = Long.MAX_VALUE / 2 // één keer per keer omdraaien
                lockAll("omgedraaid")
            }
        } else if (z > -6f) {
            faceDownSince = 0L
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        readIntent(intent) { data ->
            if (data != null) channel?.invokeMethod("binnenkomend", data)
        }
    }

    /** Leest een gedeeld bestand of ftp-link uit [intent] (één keer). */
    private fun readIntent(intent: Intent?, done: (Map<String, Any?>?) -> Unit) {
        if (intent == null || intent.getBooleanExtra(HANDLED, false)) {
            done(null)
            return
        }
        intent.putExtra(HANDLED, true)
        when (intent.action) {
            ACTION_STOP_FTP -> done(mapOf("soort" to "stopFtp"))
            VaultWidget.ACTION_OPEN_VAULT -> done(mapOf("soort" to "openKluis"))
            Intent.ACTION_VIEW -> {
                val uri = intent.data
                if (uri != null && (uri.scheme == "ftp" || uri.scheme == "ftps")) {
                    done(mapOf("soort" to "ftp", "url" to uri.toString()))
                } else {
                    done(null)
                }
            }
            Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE -> {
                val uris = sharedUris(intent)
                if (uris.isEmpty()) {
                    done(null)
                    return
                }
                // Kopiëren kan even duren: niet op de hoofdthread.
                Thread {
                    val paths = copyToCache(uris)
                    main.post { done(mapOf("soort" to "bestanden", "paden" to paths)) }
                }.start()
            }
            else -> done(null)
        }
    }

    @Suppress("DEPRECATION")
    private fun sharedUris(intent: Intent): List<Uri> {
        val out = mutableListOf<Uri>()
        if (intent.action == Intent.ACTION_SEND) {
            val u = if (Build.VERSION.SDK_INT >= 33) {
                intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
            }
            if (u != null) out.add(u)
        } else {
            val list = if (Build.VERSION.SDK_INT >= 33) {
                intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
            }
            if (list != null) out.addAll(list)
        }
        return out
    }

    /** Kopieert gedeelde bestanden naar de cache (die de app zelf opruimt). */
    private fun copyToCache(uris: List<Uri>): List<String> {
        val dir = File(cacheDir, "bestandskluis/binnen/${System.currentTimeMillis()}")
        dir.mkdirs()
        val paths = mutableListOf<String>()
        for ((i, uri) in uris.withIndex()) {
            try {
                val name = (displayName(uri) ?: "bestand_$i")
                    .replace("/", "_").replace("\\", "_")
                var f = File(dir, name)
                var n = 1
                while (f.exists()) {
                    f = File(dir, "${n++}_$name")
                }
                contentResolver.openInputStream(uri)?.use { input ->
                    f.outputStream().use { input.copyTo(it) }
                }
                if (f.exists()) paths.add(f.absolutePath)
            } catch (_: Exception) {
            }
        }
        return paths
    }

    private fun displayName(uri: Uri): String? {
        if (uri.scheme == "file") return uri.lastPathSegment
        return try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
        } catch (_: Exception) {
            null
        }
    }

    companion object {
        /** Kanaal van de draaiende app (voor de widget). */
        @Volatile
        var active: MethodChannel? = null

        /** Alle kluizen vergrendelen in de draaiende app (als die draait). */
        fun lockAll(reason: String) {
            val ch = active ?: return
            Handler(Looper.getMainLooper()).post { ch.invokeMethod("vergrendelAlles", reason) }
        }

        const val CHANNEL = "bestandskluis/systeem"
        const val ACTION_STOP_FTP = "nl.hiddebalestra.bestandskluis.STOP_FTP"
        private const val HANDLED = "bestandskluis.verwerkt"
    }
}
