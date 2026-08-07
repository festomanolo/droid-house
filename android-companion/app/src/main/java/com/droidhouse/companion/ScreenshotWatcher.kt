package com.droidhouse.companion

import android.os.Environment
import android.os.FileObserver
import android.util.Log
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList

data class ScreenshotEvent(
    val path: String,
    val filename: String,
    val timestamp: Long
)

/**
 * Indexes the device's screenshot folders and watches them for new captures so
 * the Mac's gallery updates the instant a screenshot is taken.
 *
 * OEMs disagree about where screenshots live — stock Android uses
 * `Pictures/Screenshots`, Samsung has historically used `DCIM/Screenshots` —
 * so every plausible location is watched rather than assuming one.
 */
class ScreenshotWatcher {

    companion object {
        private const val TAG = "ScreenshotWatcher"
        private const val MAX_INDEXED = 200

        /** Snapshot for the Compose UI. */
        @Volatile
        var lastKnownCount: Int = 0
            private set

        private val CANDIDATE_DIRECTORIES = listOf(
            "Pictures/Screenshots",
            "DCIM/Screenshots",
            "Pictures/Screenshot",
            "DCIM/Screenshot"
        )

        private val IMAGE_EXTENSIONS = listOf(".png", ".jpg", ".jpeg", ".webp")
    }

    val screenshotList = CopyOnWriteArrayList<ScreenshotEvent>()

    private val observers = mutableListOf<FileObserver>()
    private val watchedDirectories = mutableListOf<File>()

    fun start() {
        val external = Environment.getExternalStorageDirectory()

        for (relative in CANDIDATE_DIRECTORIES) {
            val directory = File(external, relative)
            if (!directory.exists() || !directory.isDirectory) continue
            watchedDirectories.add(directory)
        }

        // Nothing exists yet — create the stock location so we have something
        // to watch when the first screenshot lands.
        if (watchedDirectories.isEmpty()) {
            val fallback = File(external, CANDIDATE_DIRECTORIES.first())
            if (runCatching { fallback.mkdirs() }.getOrDefault(false) || fallback.exists()) {
                watchedDirectories.add(fallback)
            }
        }

        loadExisting()

        val mask = FileObserver.CREATE or FileObserver.CLOSE_WRITE or FileObserver.MOVED_TO

        for (directory in watchedDirectories) {
            val observer = object : FileObserver(directory, mask) {
                override fun onEvent(event: Int, path: String?) {
                    handleEvent(directory, path)
                }
            }
            runCatching { observer.startWatching() }
                .onFailure { Log.w(TAG, "Could not watch ${directory.path}", it) }
            observers.add(observer)
        }

        Log.i(TAG, "Watching ${observers.size} screenshot directories")
    }

    fun stop() {
        observers.forEach { runCatching { it.stopWatching() } }
        observers.clear()
        watchedDirectories.clear()
    }

    private fun handleEvent(directory: File, path: String?) {
        if (path == null) return
        val file = File(directory, path)
        if (!file.isFile || !file.isImage()) return

        // Screenshot tools often write then rename; drop any stale entry for
        // the same path before recording the new one.
        screenshotList.removeAll { it.path == file.absolutePath }
        screenshotList.add(
            0,
            ScreenshotEvent(
                path = file.absolutePath,
                filename = file.name,
                timestamp = file.lastModified().takeIf { it > 0 } ?: System.currentTimeMillis()
            )
        )
        trim()
    }

    private fun loadExisting() {
        val found = watchedDirectories
            .flatMap { it.listFiles()?.toList().orEmpty() }
            .filter { it.isFile && it.isImage() }
            .sortedByDescending { it.lastModified() }
            .take(MAX_INDEXED)
            .map {
                ScreenshotEvent(
                    path = it.absolutePath,
                    filename = it.name,
                    timestamp = it.lastModified()
                )
            }

        screenshotList.addAll(found)
        trim()
    }

    private fun trim() {
        while (screenshotList.size > MAX_INDEXED) {
            screenshotList.removeAt(screenshotList.size - 1)
        }
        lastKnownCount = screenshotList.size
    }

    private fun File.isImage(): Boolean =
        IMAGE_EXTENSIONS.any { name.endsWith(it, ignoreCase = true) }
}
