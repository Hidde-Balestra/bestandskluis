package nl.hiddebalestra.bestandskluis

import android.content.Intent
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
class MainActivity : FlutterFragmentActivity() {
    private var channel: MethodChannel? = null
    private val main = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
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
        const val CHANNEL = "bestandskluis/systeem"
        const val ACTION_STOP_FTP = "nl.hiddebalestra.bestandskluis.STOP_FTP"
        private const val HANDLED = "bestandskluis.verwerkt"
    }
}
