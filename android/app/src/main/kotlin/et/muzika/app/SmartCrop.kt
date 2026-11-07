package et.muzika.app

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetectorOptions
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import kotlin.math.min

/**
 * Auto framing for the Clips feed (see lib/services/clip_framing.dart).
 *
 * Reads frames of a clip already downloaded to the phone (two a second),
 * finds every face in each with ML Kit (on the phone, offline) and the cuts
 * between shots (a sharp change of colours). Dart turns this into the crop
 * path; nothing is kept here.
 */
object SmartCrop {
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    fun attach(messenger: BinaryMessenger) {
        MethodChannel(messenger, "muzika/smart_crop").setMethodCallHandler { call, result ->
            if (call.method != "analyze") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val path = call.argument<String>("path")
            if (path == null) {
                result.error("args", "no path", null)
                return@setMethodCallHandler
            }
            val perSecond = call.argument<Number>("perSecond")?.toInt() ?: 2
            worker.execute {
                try {
                    val analysis = analyze(path, perSecond)
                    main.post { result.success(analysis) }
                } catch (e: Throwable) {
                    main.post { result.error("failed", e.message, null) }
                }
            }
        }
    }

    private const val SAMPLE_W = 480

    /** Colour change that counts as a cut (0 same picture, 1 nothing alike). */
    private const val CUT = 0.45f

    private fun analyze(path: String, perSecond: Int): Map<String, Any> {
        val retriever = MediaMetadataRetriever()
        val detector = FaceDetection.getClient(
            FaceDetectorOptions.Builder()
                .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_FAST)
                .setMinFaceSize(0.06f)
                .build(),
        )
        try {
            retriever.setDataSource(path)
            val width = retriever.extractMetadata(
                MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH,
            )?.toIntOrNull() ?: 1920
            val height = retriever.extractMetadata(
                MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT,
            )?.toIntOrNull() ?: 1080
            val lengthMs = retriever.extractMetadata(
                MediaMetadataRetriever.METADATA_KEY_DURATION,
            )?.toLongOrNull() ?: 30_000L
            val sampleH = SAMPLE_W * height / width

            val step = 1000L / perSecond.coerceIn(1, 10)
            val samples = mutableListOf<Map<String, Any>>()
            val cuts = mutableListOf<Long>()
            var previous: FloatArray? = null
            var previousAt = 0L
            var t = 0L
            while (t < lengthMs) {
                val frame = frameAt(retriever, t, sampleH)
                if (frame != null) {
                    val colours = histogram(frame)
                    val before = previous
                    if (before != null && difference(before, colours) > CUT) {
                        cuts.add(refineCut(retriever, previousAt, t, before, sampleH))
                    }
                    val faces = Tasks.await(detector.process(InputImage.fromBitmap(frame, 0)))
                    samples.add(
                        mapOf(
                            "t" to t,
                            // Each face: its centre (0..1 of the width) and its
                            // size (0..1 of the frame's area).
                            "faces" to faces
                                .filter { it.boundingBox.width() > frame.width * 0.03 }
                                .map {
                                    listOf(
                                        (it.boundingBox.exactCenterX() / frame.width).toDouble(),
                                        (it.boundingBox.width().toDouble() * it.boundingBox.height()) /
                                            (frame.width.toDouble() * frame.height),
                                    )
                                },
                        ),
                    )
                    previous = colours
                    previousAt = t
                    frame.recycle()
                }
                t += step
            }
            return mapOf(
                "width" to width,
                "height" to height,
                "length" to lengthMs,
                "samples" to samples,
                "cuts" to cuts,
            )
        } finally {
            detector.close()
            retriever.release()
        }
    }

    private fun frameAt(retriever: MediaMetadataRetriever, ms: Long, h: Int): Bitmap? {
        val us = ms * 1000
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                retriever.getScaledFrameAtTime(us, MediaMetadataRetriever.OPTION_CLOSEST, SAMPLE_W, h)
            } else {
                retriever.getFrameAtTime(us, MediaMetadataRetriever.OPTION_CLOSEST)?.let {
                    val scaled = Bitmap.createScaledBitmap(it, SAMPLE_W, h, true)
                    if (scaled !== it) it.recycle()
                    scaled
                }
            }
        } catch (_: Throwable) {
            null
        }
    }

    /** Narrows a cut between two samples down to about 125 ms. */
    private fun refineCut(
        retriever: MediaMetadataRetriever,
        fromMs: Long,
        toMs: Long,
        before: FloatArray,
        h: Int,
    ): Long {
        var lo = fromMs
        var hi = toMs
        repeat(2) {
            val mid = (lo + hi) / 2
            val frame = frameAt(retriever, mid, h) ?: return hi
            val changed = difference(before, histogram(frame)) > CUT
            frame.recycle()
            if (changed) hi = mid else lo = mid
        }
        return hi
    }

    /** A 4×4×4 colour histogram of a shrunken frame, summing to 1. */
    private fun histogram(frame: Bitmap): FloatArray {
        val small = Bitmap.createScaledBitmap(frame, 32, 18, true)
        val pixels = IntArray(32 * 18)
        small.getPixels(pixels, 0, 32, 0, 0, 32, 18)
        if (small !== frame) small.recycle()
        val bins = FloatArray(64)
        for (p in pixels) {
            val r = (p shr 16 and 0xff) shr 6
            val g = (p shr 8 and 0xff) shr 6
            val b = (p and 0xff) shr 6
            bins[r * 16 + g * 4 + b] += 1f
        }
        for (i in bins.indices) bins[i] /= pixels.size.toFloat()
        return bins
    }

    /** 1 minus the histograms' overlap. */
    private fun difference(a: FloatArray, b: FloatArray): Float {
        var overlap = 0f
        for (i in a.indices) overlap += min(a[i], b[i])
        return 1f - overlap
    }
}
