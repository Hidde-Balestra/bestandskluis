package nl.hiddebalestra.bestandskluis

import android.graphics.Bitmap
import android.media.MediaDataSource
import android.media.MediaMetadataRetriever
import android.os.Build
import android.os.Handler
import android.os.Looper
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.util.concurrent.Executors
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlin.math.max
import kotlin.math.min

/**
 * Miniaturen van video's, ook van versleutelde video's in een kluis.
 *
 * Een versleutelde video wordt niet als bestand ontsleuteld: [EncryptedSource]
 * ontsleutelt alleen de blokken die Android leest, in het geheugen.
 */
object VideoThumbs {
    private val pool = Executors.newFixedThreadPool(2)
    private val main = Handler(Looper.getMainLooper())

    fun make(args: Map<*, *>, done: (Map<String, Any?>?) -> Unit) {
        pool.execute {
            val r = try {
                run(args)
            } catch (_: Throwable) {
                null
            }
            main.post { done(r) }
        }
    }

    private fun run(a: Map<*, *>): Map<String, Any?>? {
        val path = a["pad"] as String
        val width = (a["breedte"] as Number).toInt()
        val key = a["sleutel"] as? ByteArray
        val header = a["kop"] as? ByteArray
        val mmr = MediaMetadataRetriever()
        var source: EncryptedSource? = null
        try {
            if (key != null && header != null) {
                source = EncryptedSource(File(path), key, header)
                mmr.setDataSource(source)
            } else {
                mmr.setDataSource(path)
            }
            val duration = mmr.extractMetadata(
                MediaMetadataRetriever.METADATA_KEY_DURATION
            )?.toLongOrNull() ?: 0L
            // Eén seconde in de video (zwart beginbeeld vermijden).
            val at = if (duration > 2000) 1_000_000L else 0L
            val frame: Bitmap = (if (Build.VERSION.SDK_INT >= 27) {
                mmr.getScaledFrameAtTime(
                    at, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, width, width
                )
            } else {
                mmr.getFrameAtTime(at, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
            }) ?: return null
            val scaled = if (frame.width > width) {
                val h = max(1, frame.height * width / frame.width)
                Bitmap.createScaledBitmap(frame, width, h, true)
            } else {
                frame
            }
            val out = ByteArrayOutputStream()
            scaled.compress(Bitmap.CompressFormat.JPEG, 82, out)
            return mapOf("jpg" to out.toByteArray(), "duur" to duration)
        } finally {
            try {
                mmr.release()
            } catch (_: Throwable) {
            }
            source?.close()
        }
    }
}

/**
 * Leest een kluisbestand (formaat BKV1) en ontsleutelt alleen de gevraagde
 * blokken: AES-256-GCM per blok, nonce = bloknummer (64-bit big-endian in
 * de laatste 8 bytes), AAD = kop (24 bytes) + "laatste blok"-vlag.
 * [key] is de bestandssleutel (al afgeleid in Dart).
 */
class EncryptedSource(
    file: File,
    private val key: ByteArray,
    private val header: ByteArray,
) : MediaDataSource() {
    private val raf = RandomAccessFile(file, "r")
    private val total = raf.length()
    private val chunk = ByteBuffer.wrap(header, 4, 4).int
    private val chunks: Long =
        if (total <= HEADER) 0 else (total - HEADER + chunk + TAG - 1) / (chunk + TAG)
    private val plainSize: Long = max(0L, total - HEADER - chunks * TAG)
    private val cipher = Cipher.getInstance("AES/GCM/NoPadding")
    private val spec = SecretKeySpec(key, "AES")
    private var cachedIndex = -1L
    private var cached = ByteArray(0)

    override fun getSize(): Long = plainSize

    @Synchronized
    override fun readAt(position: Long, buffer: ByteArray, offset: Int, size: Int): Int {
        if (position >= plainSize) return -1
        if (size <= 0) return 0
        val index = position / chunk
        if (index != cachedIndex) load(index)
        val within = (position - index * chunk).toInt()
        val n = min(size, cached.size - within)
        if (n <= 0) return -1
        System.arraycopy(cached, within, buffer, offset, n)
        return n
    }

    private fun load(index: Long) {
        val pos = HEADER + index * (chunk + TAG)
        val last = index == chunks - 1
        val len = if (last) (total - pos).toInt() else chunk + TAG
        val data = ByteArray(len)
        raf.seek(pos)
        raf.readFully(data)
        val nonce = ByteArray(12)
        for (i in 0 until 8) nonce[4 + i] = (index shr (8 * (7 - i))).toByte()
        cipher.init(Cipher.DECRYPT_MODE, spec, GCMParameterSpec(TAG * 8, nonce))
        cipher.updateAAD(header)
        cipher.updateAAD(byteArrayOf(if (last) 1 else 0))
        cached = cipher.doFinal(data)
        cachedIndex = index
    }

    override fun close() {
        try {
            raf.close()
        } catch (_: Throwable) {
        }
    }

    companion object {
        private const val HEADER = 24L
        private const val TAG = 16
    }
}
