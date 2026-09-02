package jp.ox.doorbell

import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream

internal interface OriginatedCallPersistence {
    fun load(): OriginatedCall?
    fun save(call: OriginatedCall): Boolean
    fun clear()
}

internal class OriginatedCallFileStore(private val file: File) : OriginatedCallPersistence {
    @Synchronized
    override fun load(): OriginatedCall? {
        if (!file.isFile || file.length() !in 1..MAX_FILE_BYTES) return null
        return try {
            DataInputStream(FileInputStream(file)).use { input ->
                if (input.readInt() != MAGIC || input.readInt() != VERSION) return null
                val call = OriginatedCall(
                    callId = input.readUTF(),
                    door = input.readUTF(),
                    stageRevision = input.readInt(),
                    expiresAtMs = input.readLong(),
                    purpose = input.readUTF(),
                    phase = CallUiPhase.valueOf(input.readUTF()),
                )
                call.takeIf(::isValid)
            }
        } catch (_: Exception) {
            null
        }
    }

    @Synchronized
    override fun save(call: OriginatedCall): Boolean {
        if (!isValid(call)) return false
        val parent = file.parentFile ?: return false
        if (!parent.exists() && !parent.mkdirs()) return false
        val temporary = File(parent, file.name + ".tmp")
        return try {
            FileOutputStream(temporary, false).use { stream ->
                DataOutputStream(stream).use { output ->
                    output.writeInt(MAGIC)
                    output.writeInt(VERSION)
                    output.writeUTF(call.callId)
                    output.writeUTF(call.door)
                    output.writeInt(call.stageRevision)
                    output.writeLong(call.expiresAtMs)
                    output.writeUTF(call.purpose)
                    output.writeUTF(call.phase.name)
                    output.flush()
                    stream.fd.sync()
                }
            }
            if (!temporary.renameTo(file)) {
                temporary.delete()
                false
            } else true
        } catch (_: Exception) {
            temporary.delete()
            false
        }
    }

    @Synchronized
    override fun clear() {
        if (file.isFile) file.delete()
        file.parentFile?.let { File(it, file.name + ".tmp").delete() }
    }

    private fun isValid(call: OriginatedCall): Boolean =
        call.callId.isNotEmpty() && call.callId.length <= MAX_FIELD_CHARS &&
            call.door.length <= MAX_FIELD_CHARS &&
            call.purpose.length <= MAX_FIELD_CHARS &&
            call.stageRevision in 0..MAX_STAGE_REVISION && call.expiresAtMs > 0L

    companion object {
        private const val MAGIC = 0x44424346
        private const val VERSION = 1
        private const val MAX_FILE_BYTES = 16 * 1024L
        private const val MAX_FIELD_CHARS = 1024
        private const val MAX_STAGE_REVISION = 1_000_000
    }
}
