package nl.r1a.mapidx

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.net.Uri
import androidx.core.app.ActivityCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileNotFoundException
import java.io.FileOutputStream

/**
 * Where the phone is, over `android.location.LocationManager`.
 *
 * Hand-written rather than `geolocator`, which pulls
 * `com.google.android.gms:play-services-location` in. LocationManager is AOSP,
 * and all this needs of it is a fix now and then to sort hits by distance.
 *
 * The permission is asked for on the first `start`, never at launch.
 */
private const val CHANNEL = "nl.r1a.mapidx/here"
private const val FIXES = "nl.r1a.mapidx/here/fixes"
private const val PICKER = "nl.r1a.mapidx/picker"
private const val REQUEST = 4711
private const val PICK_REQUEST = 4712

private val PERMISSIONS =
    arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)

class MainActivity : FlutterActivity(), LocationListener {
    private var fixes: EventChannel.EventSink? = null
    private var asking: MethodChannel.Result? = null
    private var picking: MethodChannel.Result? = null
    private var listening = false

    private val locations by lazy { getSystemService(LOCATION_SERVICE) as LocationManager }

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        val messenger = engine.dartExecutor.binaryMessenger

        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" ->
                    if (granted()) {
                        result.success(listen())
                    } else {
                        // One request at a time: a second tap while the system
                        // dialog is up must not leave the first call unanswered
                        asking?.success(false)
                        asking = result
                        ActivityCompat.requestPermissions(this, PERMISSIONS, REQUEST)
                    }
                "stop" -> {
                    unlisten()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(messenger, PICKER).setMethodCallHandler { call, result ->
            when (call.method) {
                "pick" -> {
                    picking?.success(null)
                    picking = result
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        // Anything that sqlite3 will read; the Lviv index is
                        // an .sqlite, but Downloads hands us MIME
                        // application/octet-stream for unknown types
                        type = "*/*"
                    }
                    try {
                        startActivityForResult(intent, PICK_REQUEST)
                    } catch (_: Exception) {
                        picking = null
                        result.success(null)
                    }
                }
                "import" -> {
                    val src = call.argument<String>("uri")
                    val name = call.argument<String>("name") ?: "index.sqlite"
                    if (src == null) {
                        result.error("bad_args", "uri missing", null)
                        return@setMethodCallHandler
                    }
                    try {
                        result.success(copy(Uri.parse(src), name))
                    } catch (e: Exception) {
                        result.error("import_failed", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, FIXES).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                    fixes = sink
                }

                override fun onCancel(arguments: Any?) {
                    fixes = null
                }
            }
        )
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != PICK_REQUEST) return
        val pending = picking ?: return
        picking = null
        pending.success(
            if (resultCode == Activity.RESULT_OK) data?.data?.toString() else null
        )
    }

    private fun copy(src: Uri, name: String): String {
        val dir = File(filesDir, "index").apply { if (!exists()) mkdirs() }
        val dst = File(dir, name)
        contentResolver.openInputStream(src).use { input ->
            if (input == null) throw FileNotFoundException(src.toString())
            FileOutputStream(dst).use { output -> input.copyTo(output) }
        }
        return dst.absolutePath
    }

    private fun granted() =
        PERMISSIONS.any {
            ActivityCompat.checkSelfPermission(this, it) == PackageManager.PERMISSION_GRANTED
        }

    /** True if anything is now feeding the stream */
    private fun listen(): Boolean {
        if (listening) return true
        // Both providers, because the one that answers first differs indoors
        // and out, and a distance from either beats no distance
        val providers =
            listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER).filter {
                locations.allProviders.contains(it)
            }
        if (providers.isEmpty()) return false
        try {
            for (provider in providers) {
                locations.requestLocationUpdates(provider, 5000L, 25f, this)
                locations.getLastKnownLocation(provider)?.let(::onLocationChanged)
            }
        } catch (_: SecurityException) {
            return false
        }
        listening = true
        return true
    }

    private fun unlisten() {
        if (!listening) return
        locations.removeUpdates(this)
        listening = false
    }

    override fun onLocationChanged(fix: Location) {
        fixes?.success(mapOf("lat" to fix.latitude, "lon" to fix.longitude))
    }

    override fun onRequestPermissionsResult(
        code: Int,
        permissions: Array<out String>,
        results: IntArray,
    ) {
        super.onRequestPermissionsResult(code, permissions, results)
        if (code != REQUEST) return
        val waiting = asking ?: return
        asking = null
        waiting.success(granted() && listen())
    }

    override fun onDestroy() {
        unlisten()
        super.onDestroy()
    }

    override fun onPause() {
        unlisten()
        super.onPause()
    }

    override fun onResume() {
        super.onResume()
        if (fixes != null && granted()) listen()
    }
}
