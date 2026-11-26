package com.linkdrop.linkdrop_downloader

import android.util.Log
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer

/**
 * Pure-Kotlin ISO BMFF (MP4/M4V/MOV) timestamp patcher.
 *
 * Directly rewrites `creation_time` and `modification_time` inside every `mvhd`, `tkhd`,
 * and `mdhd` atom to the current UTC timestamp (seconds since 1904-01-01).
 *
 * This guarantees Android's MediaMetadataRetriever and WhatsApp/Gallery ALWAYS see
 * the download time as the video's true creation date — even for old YouTube videos
 * or when FFmpeg stream-copy is skipped.
 */
object Mp4TimestampPatcher {
    private const val TAG = "Mp4TimestampPatcher"

    // Seconds between 1904-01-01 00:00:00 UTC (MP4 epoch) and 1970-01-01 00:00:00 UTC (Unix epoch)
    private const val MP4_EPOCH_OFFSET_SECONDS = 2082844800L

    private val containerBoxes = setOf("moov", "trak", "mdia")
    private val headerBoxes = setOf("mvhd", "tkhd", "mdhd")

    fun patchToNow(file: File): Boolean {
        if (!file.exists() || !file.isFile || file.length() < 32L) return false
        val ext = file.extension.lowercase()
        if (ext != "mp4" && ext != "m4v" && ext != "mov" && ext != "3gp") return false

        val mp4NowSeconds = (System.currentTimeMillis() / 1000L) + MP4_EPOCH_OFFSET_SECONDS
        var patchedCount = 0

        return try {
            RandomAccessFile(file, "rw").use { raf ->
                patchedCount = walkBoxes(raf, 0L, raf.length(), mp4NowSeconds, depth = 0)
            }
            Log.d(TAG, "Patched $patchedCount MP4 header box(es) in ${file.name}")
            patchedCount > 0
        } catch (t: Throwable) {
            Log.w(TAG, "MP4 patch failed for ${file.name}: ${t.message}")
            false
        }
    }

    private fun walkBoxes(
        raf: RandomAccessFile,
        start: Long,
        end: Long,
        mp4Time: Long,
        depth: Int,
    ): Int {
        if (depth > 8) return 0
        var count = 0
        var offset = start
        val header = ByteArray(8)
        val extSizeBuf = ByteArray(8)

        while (offset + 8L <= end) {
            raf.seek(offset)
            if (raf.read(header) != 8) break

            val size32 = ByteBuffer.wrap(header, 0, 4).int.toLong() and 0xFFFFFFFFL
            val type = String(header, 4, 4, Charsets.ISO_8859_1)

            var headerLen = 8L
            var boxSize = size32
            if (size32 == 1L) {
                if (offset + 16L > end) break
                if (raf.read(extSizeBuf) != 8) break
                boxSize = ByteBuffer.wrap(extSizeBuf).long
                headerLen = 16L
            } else if (size32 == 0L) {
                boxSize = end - offset
            }

            if (boxSize < headerLen || offset + boxSize > end) break

            val contentStart = offset + headerLen
            val contentEnd = offset + boxSize

            if (type in containerBoxes) {
                count += walkBoxes(raf, contentStart, contentEnd, mp4Time, depth + 1)
            } else if (type in headerBoxes) {
                if (patchFullBoxTimestamps(raf, contentStart, contentEnd, mp4Time)) {
                    count++
                }
            }

            offset += boxSize
        }
        return count
    }

    private fun patchFullBoxTimestamps(
        raf: RandomAccessFile,
        contentStart: Long,
        contentEnd: Long,
        mp4Time: Long,
    ): Boolean {
        if (contentStart + 12L > contentEnd) return false
        raf.seek(contentStart)
        val version = raf.read()
        // Skip 3-byte flags
        val timePos = contentStart + 4L

        return when (version) {
            0 -> {
                if (timePos + 8L > contentEnd) return false
                val bytes = ByteBuffer.allocate(8)
                    .putInt((mp4Time and 0xFFFFFFFFL).toInt())
                    .putInt((mp4Time and 0xFFFFFFFFL).toInt())
                    .array()
                raf.seek(timePos)
                raf.write(bytes)
                true
            }
            1 -> {
                if (timePos + 16L > contentEnd) return false
                val bytes = ByteBuffer.allocate(16)
                    .putLong(mp4Time)
                    .putLong(mp4Time)
                    .array()
                raf.seek(timePos)
                raf.write(bytes)
                true
            }
            else -> false
        }
    }
}
