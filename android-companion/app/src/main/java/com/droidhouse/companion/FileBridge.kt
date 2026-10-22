package com.droidhouse.companion

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Environment
import android.os.StatFs
import android.os.storage.StorageManager
import androidx.core.content.ContextCompat
import io.ktor.http.ContentType
import io.ktor.http.HttpStatusCode
import io.ktor.server.application.ApplicationCall
import io.ktor.server.application.call
import io.ktor.server.request.receive
import io.ktor.server.request.receiveChannel
import io.ktor.server.response.respond
import io.ktor.server.response.respondFile
import io.ktor.server.response.respondOutputStream
import io.ktor.server.routing.Route
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import io.ktor.server.routing.put
import io.ktor.utils.io.jvm.javaio.toInputStream
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import java.io.File

@Serializable
data class FsEntryPayload(
    val name: String,
    val isDirectory: Boolean,
    val size: Long,
    val modified: Long,
    val permissions: String
)

@Serializable
data class FsSizePayload(val bytes: Long, val isDirectory: Boolean)

@Serializable
data class FsVolumePayload(
    val id: String,
    val label: String,
    val totalBytes: Long,
    val freeBytes: Long,
    val isInternal: Boolean
)

@Serializable
data class FsAccessPayload(val granted: Boolean, val needsAllFilesAccess: Boolean)

@Serializable
data class FsPathRequest(val path: String)

@Serializable
data class FsPathsRequest(val paths: List<String>)

@Serializable
data class FsTransferRequest(val from: String, val to: String)

/**
 * The file explorer over HTTP — what `adb shell ls/mv/cp/rm`, `adb pull` and
 * `adb push` do over USB, for a Mac that only has Wi-Fi.
 *
 * Every route runs as the companion's own UID, so it sees exactly what the
 * storage permission (or "All files access" on Android 11+) allows.
 */
object FileBridge {

    fun hasStorageAccess(context: Context): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            ContextCompat.checkSelfPermission(context, Manifest.permission.WRITE_EXTERNAL_STORAGE) ==
                PackageManager.PERMISSION_GRANTED
        }

    fun install(route: Route, context: Context) = with(route) {

        get("/api/fs/access") {
            call.respond(
                FsAccessPayload(
                    granted = hasStorageAccess(context),
                    needsAllFilesAccess = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R
                )
            )
        }

        get("/api/fs/list") {
            val dir = call.requirePath("path") ?: return@get
            if (!call.requireAccess(context)) return@get
            if (!dir.isDirectory) {
                call.respond(HttpStatusCode.NotFound, SimpleResult(false, "No such folder: ${dir.path}"))
                return@get
            }
            val entries = withContext(Dispatchers.IO) {
                (dir.listFiles() ?: emptyArray()).map { file ->
                    val isDirectory = file.isDirectory
                    FsEntryPayload(
                        name = file.name,
                        isDirectory = isDirectory,
                        size = if (isDirectory) 0 else file.length(),
                        modified = file.lastModified(),
                        permissions = buildString {
                            append(if (isDirectory) 'd' else '-')
                            append(if (file.canRead()) 'r' else '-')
                            append(if (file.canWrite()) 'w' else '-')
                            append('-')
                        }
                    )
                }
            }
            call.respond(entries)
        }

        get("/api/fs/size") {
            val target = call.requirePath("path") ?: return@get
            if (!target.exists()) {
                call.respond(HttpStatusCode.NotFound, SimpleResult(false, "Not found"))
                return@get
            }
            val bytes = withContext(Dispatchers.IO) {
                if (target.isDirectory) target.walkTopDown().filter { it.isFile }.sumOf { it.length() }
                else target.length()
            }
            call.respond(FsSizePayload(bytes, target.isDirectory))
        }

        /** File bytes. `max` caps the read, for thumbnails of large files. */
        get("/api/fs/file") {
            val file = call.requirePath("path") ?: return@get
            if (!call.requireAccess(context)) return@get
            if (!file.isFile || !file.canRead()) {
                call.respond(HttpStatusCode.NotFound, SimpleResult(false, "Can't read ${file.path}"))
                return@get
            }
            val max = call.request.queryParameters["max"]?.toLongOrNull()
            if (max == null || max >= file.length()) {
                call.respondFile(file)
                return@get
            }
            call.respondOutputStream(ContentType.Application.OctetStream) {
                file.inputStream().use { input ->
                    val buffer = ByteArray(64 * 1024)
                    var remaining = max
                    while (remaining > 0) {
                        val read = input.read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
                        if (read < 0) break
                        write(buffer, 0, read)
                        remaining -= read
                    }
                }
            }
        }

        /**
         * Streams the request body into `path`. Written beside the target and
         * renamed at the end, so a dropped connection never leaves a truncated
         * file under the real name. `mtime` (ms) restores the Mac's date.
         */
        put("/api/fs/file") {
            val target = call.requirePath("path") ?: return@put
            if (!call.requireAccess(context)) return@put
            val mtime = call.request.queryParameters["mtime"]?.toLongOrNull()

            val written = withContext(Dispatchers.IO) {
                target.parentFile?.mkdirs()
                val partial = File(target.parentFile, ".${target.name}.droidhouse-part")
                runCatching {
                    call.receiveChannel().toInputStream().use { input ->
                        partial.outputStream().use { output -> input.copyTo(output, 256 * 1024) }
                    }
                    if (target.exists()) target.delete()
                    check(partial.renameTo(target)) { "Could not move the upload into place" }
                    mtime?.let { target.setLastModified(it) }
                }.onFailure { partial.delete() }
            }

            written.fold(
                onSuccess = { call.respond(SimpleResult(true, "Saved ${target.path}")) },
                onFailure = {
                    call.respond(HttpStatusCode.InternalServerError, SimpleResult(false, it.message ?: "Upload failed"))
                }
            )
        }

        post("/api/fs/mkdir") {
            val request = call.receive<FsPathRequest>()
            val dir = absoluteFile(request.path) ?: return@post call.badPath()
            if (!call.requireAccess(context)) return@post
            if (dir.isDirectory || dir.mkdirs()) {
                call.respond(SimpleResult(true, "Created"))
            } else {
                call.respond(HttpStatusCode.InternalServerError, SimpleResult(false, "Couldn't create ${dir.path}"))
            }
        }

        post("/api/fs/delete") {
            val request = call.receive<FsPathsRequest>()
            if (!call.requireAccess(context)) return@post
            val failed = withContext(Dispatchers.IO) {
                request.paths.mapNotNull { path ->
                    val file = absoluteFile(path) ?: return@mapNotNull path
                    if (!file.exists() || file.deleteRecursively()) null else path
                }
            }
            if (failed.isEmpty()) {
                call.respond(SimpleResult(true, "Deleted"))
            } else {
                call.respond(
                    HttpStatusCode.InternalServerError,
                    SimpleResult(false, "Couldn't delete ${failed.joinToString()}")
                )
            }
        }

        post("/api/fs/move") {
            val request = call.receive<FsTransferRequest>()
            val from = absoluteFile(request.from) ?: return@post call.badPath()
            val to = absoluteFile(request.to) ?: return@post call.badPath()
            if (!call.requireAccess(context)) return@post
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    check(from.exists()) { "${from.path} no longer exists" }
                    check(!to.exists()) { "${to.name} already exists there" }
                    to.parentFile?.mkdirs()
                    // A rename is instant on one volume; across volumes (SD
                    // card) it fails and has to become a copy.
                    if (!from.renameTo(to)) {
                        check(from.copyRecursively(to, overwrite = false)) { "Copy failed" }
                        from.deleteRecursively()
                    }
                }
            }
            call.respondResult(result, "Moved")
        }

        post("/api/fs/copy") {
            val request = call.receive<FsTransferRequest>()
            val from = absoluteFile(request.from) ?: return@post call.badPath()
            val to = absoluteFile(request.to) ?: return@post call.badPath()
            if (!call.requireAccess(context)) return@post
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    check(from.exists()) { "${from.path} no longer exists" }
                    check(from.copyRecursively(to, overwrite = false)) { "Copy failed" }
                }
            }
            call.respondResult(result, "Copied")
        }

        get("/api/fs/storage") {
            call.respond(withContext(Dispatchers.IO) { volumes(context) })
        }

        /**
         * `tar -cf -` of `paths` (relative to `root`), streamed as it's made.
         * tar keeps every file's date, which is what the timestamp-preserving
         * backup and whole-folder downloads rely on.
         */
        get("/api/fs/tar") {
            val root = call.requirePath("root") ?: return@get
            if (!call.requireAccess(context)) return@get
            val paths = call.request.queryParameters.getAll("paths").orEmpty()
            if (paths.isEmpty() || paths.any { it.startsWith("-") }) {
                call.respond(HttpStatusCode.BadRequest, SimpleResult(false, "Nothing to archive"))
                return@get
            }

            val process = ProcessBuilder(listOf("tar", "-cf", "-", "-C", root.path) + paths)
                // An unread stderr pipe would eventually block tar.
                .redirectError(ProcessBuilder.Redirect.to(File("/dev/null")))
                .start()
            try {
                call.respondOutputStream(ContentType.Application.OctetStream) {
                    process.inputStream.use { it.copyTo(this, 256 * 1024) }
                }
            } finally {
                process.destroy()
            }
        }

        /** Extracts a tar body into `root`, restoring each file's date. */
        post("/api/fs/untar") {
            val root = call.requirePath("root") ?: return@post
            if (!call.requireAccess(context)) return@post

            val result = withContext(Dispatchers.IO) {
                runCatching {
                    root.mkdirs()
                    val process = ProcessBuilder("tar", "-xf", "-", "-C", root.path)
                        .redirectErrorStream(true)
                        .start()
                    call.receiveChannel().toInputStream().use { input ->
                        process.outputStream.use { input.copyTo(it, 256 * 1024) }
                    }
                    val log = process.inputStream.bufferedReader().readText()
                    val status = process.waitFor()
                    check(status == 0) { log.ifBlank { "tar exited with status $status" } }
                }
            }
            call.respondResult(result, "Extracted")
        }
    }

    // ------------------------------------------------------------ helpers

    /** Only absolute paths: a relative one would resolve against the app's cwd. */
    private fun absoluteFile(path: String?): File? =
        path?.takeIf { it.startsWith("/") }?.let { File(it) }

    private suspend fun ApplicationCall.requirePath(name: String): File? {
        val file = absoluteFile(request.queryParameters[name])
        if (file == null) badPath()
        return file
    }

    private suspend fun ApplicationCall.badPath() =
        respond(HttpStatusCode.BadRequest, SimpleResult(false, "An absolute path is required"))

    private suspend fun ApplicationCall.requireAccess(context: Context): Boolean {
        if (hasStorageAccess(context)) return true
        respond(
            HttpStatusCode.Forbidden,
            SimpleResult(false, "Open DroidHouse on the phone and allow file access to browse it over Wi-Fi.")
        )
        return false
    }

    private suspend fun ApplicationCall.respondResult(result: Result<*>, success: String) {
        result.fold(
            onSuccess = { respond(SimpleResult(true, success)) },
            onFailure = {
                respond(HttpStatusCode.InternalServerError, SimpleResult(false, it.message ?: "Failed"))
            }
        )
    }

    private fun volumes(context: Context): List<FsVolumePayload> {
        val result = mutableListOf<FsVolumePayload>()

        val internal = Environment.getExternalStorageDirectory()
        runCatching { StatFs(internal.path) }.getOrNull()?.let { stat ->
            result += FsVolumePayload("internal", "Internal", stat.totalBytes, stat.availableBytes, true)
        }

        // Removable volumes (SD card, USB OTG) live at /storage/<uuid>.
        val manager = context.getSystemService(StorageManager::class.java)
        manager?.storageVolumes?.filter { it.isRemovable }?.forEach { volume ->
            val uuid = volume.uuid ?: return@forEach
            val dir = File("/storage/$uuid")
            val stat = runCatching { StatFs(dir.path) }.getOrNull() ?: return@forEach
            result += FsVolumePayload(
                dir.path,
                volume.getDescription(context) ?: uuid,
                stat.totalBytes,
                stat.availableBytes,
                false
            )
        }
        return result
    }
}
