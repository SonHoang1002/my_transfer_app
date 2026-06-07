package com.example.mytransferapp.network


import android.content.ContentValues
import android.content.ContentResolver
import android.content.Context
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.util.Log
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.*
import java.net.*
import java.util.Locale
import java.util.Random
import java.util.concurrent.ConcurrentHashMap

// Model represented devices
data class DeviceInfo(
    val name: String,
    val ipAddress: String,
    val port: Int,
    val lastSeen: Long = System.currentTimeMillis()
)

// Active file transfer state
data class TransferState(
    val id: Long = 0,
    val fileName: String = "",
    val totalBytes: Long = 0,
    val bytesTransferred: Long = 0,
    val progress: Int = 0,
    val speedMbps: Double = 0.0,
    val isIncoming: Boolean = false,
    val peerName: String = "",
    val status: String = "IDLE", // IDLE, CONNECTING, TRANSFERRING, SUCCESS, FAILED
    val error: String? = null
)

object TransferEngine {
    private const val TAG = "TransferEngine"
    private const val UDP_DISCOVERY_PORT = 8889
    private const val TCP_TRANSFER_PORT = 9999
    private const val BUFFER_SIZE = 512 * 1024 // 512KB for ultra physical device throughput

    private val _discoveredDevices = MutableStateFlow<List<DeviceInfo>>(emptyList())
    val discoveredDevices: StateFlow<List<DeviceInfo>> = _discoveredDevices.asStateFlow()

    private val _activeTransfer = MutableStateFlow<TransferState?>(null)
    val activeTransfer: StateFlow<TransferState?> = _activeTransfer.asStateFlow()

    private val deviceMap = ConcurrentHashMap<String, DeviceInfo>()
    private var udpScanJob: Job? = null
    private var udpAdvertiseJob: Job? = null
    private var tcpServerJob: Job? = null
    private var serverSocket: ServerSocket? = null
    private var activeSocket: Socket? = null
    private var activeJob: Job? = null

    fun cancelActiveTransfer() {
        Log.d(TAG, "Đang huỷ chuyển file hoạt động...")
        _activeTransfer.value = _activeTransfer.value?.copy(status = "FAILED", error = "Truyền file bị hủy bởi người dùng")
        try {
            activeSocket?.close()
        } catch (e: Exception) {
            Log.e(TAG, "Lỗi khi đóng socket huỷ kết nối", e)
        }
        activeSocket = null
        activeJob?.cancel()
        activeJob = null
    }

    // Get the device name (e.g., "Google Pixel")
    fun getDeviceName(): String {
        val manufacturer = Build.MANUFACTURER
        val model = Build.MODEL
        return if (model.startsWith(manufacturer)) {
            model.replaceFirstChar { it.uppercase() }
        } else {
            "${manufacturer.replaceFirstChar { it.uppercase() }} $model"
        }
    }

    // Retrieve local IP Address
    fun getLocalIpAddress(): String {
        try {
            val interfaces = NetworkInterface.getNetworkInterfaces()
            while (interfaces.hasMoreElements()) {
                val networkInterface = interfaces.nextElement()
                val addresses = networkInterface.inetAddresses
                while (addresses.hasMoreElements()) {
                    val address = addresses.nextElement()
                    if (!address.isLoopbackAddress && address is Inet4Address) {
                        return address.hostAddress ?: "127.0.0.1"
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Lỗi khi lấy IP nội bộ", e)
        }
        return "127.0.0.1"
    }

    // --- UDP DISCOVERY ENGINE (SCANNER & ADVERTISER) ---

    // Advertise that this device is ready to RECEIVE files
    fun startAdvertising(deviceName: String) {
        udpAdvertiseJob?.cancel()
        udpAdvertiseJob = CoroutineScope(Dispatchers.IO).launch {
            var socket: DatagramSocket? = null
            try {
                // Listen to discovery PINGs
                socket = DatagramSocket(UDP_DISCOVERY_PORT).apply {
                    reuseAddress = true
                }
                Log.d(TAG, "Bắt đầu phát sóng nhận diện trên cổng $UDP_DISCOVERY_PORT")

                val buffer = ByteArray(1024)
                while (isActive) {
                    val packet = DatagramPacket(buffer, buffer.size)
                    try {
                        socket.receive(packet)
                        val message = String(packet.data, 0, packet.length).trim()
                        if (message.startsWith("SWIFTSHARE_PING:")) {
                            // Client discovered us! Respond back directly
                            val replyMsg = "SWIFTSHARE_PONG:$deviceName:$TCP_TRANSFER_PORT"
                            val replyBytes = replyMsg.toByteArray()
                            val replyPacket = DatagramPacket(
                                replyBytes,
                                replyBytes.size,
                                packet.address,
                                packet.port
                            )
                            socket.send(replyPacket)
                            Log.d(TAG, "Đã phản hồi PING từ ${packet.address.hostAddress}")
                        }
                    } catch (e: SocketException) {
                        break // Socket closed
                    } catch (e: Exception) {
                        Log.e(TAG, "Lỗi trong vòng lặp nhận UDP", e)
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Không thể khởi động cổng phát sóng quảng bá UDP", e)
            } finally {
                socket?.close()
            }
        }
    }

    fun stopAdvertising() {
        udpAdvertiseJob?.cancel()
        udpAdvertiseJob = null
    }

    // Scan for nearby devices wishing to send file
    fun startScanning(deviceName: String) {
        deviceMap.clear()
        _discoveredDevices.value = emptyList()

        udpScanJob?.cancel()
        udpScanJob = CoroutineScope(Dispatchers.IO).launch {
            var socket: DatagramSocket? = null
            try {
                // Create a dynamic port socket
                socket = DatagramSocket().apply {
                    broadcast = true
                    soTimeout = 1500
                }

                // Coroutine 1: Continuously read responses
                val receiveJob = launch {
                    val buffer = ByteArray(1024)
                    while (isActive) {
                        val packet = DatagramPacket(buffer, buffer.size)
                        try {
                            socket.receive(packet)
                            val message = String(packet.data, 0, packet.length).trim()
                            if (message.startsWith("SWIFTSHARE_PONG:")) {
                                val parts = message.split(":")
                                val peerName = parts.getOrNull(1) ?: "Thiết bị"
                                val peerPort = parts.getOrNull(2)?.toIntOrNull() ?: TCP_TRANSFER_PORT
                                val peerIp = packet.address.hostAddress ?: ""

                                val device = DeviceInfo(peerName, peerIp, peerPort)
                                deviceMap[peerIp] = device
                                _discoveredDevices.value = deviceMap.values.toList()
                                Log.d(TAG, "Tìm thấy thiết bị: $peerName ($peerIp:$peerPort)")
                            }
                        } catch (e: SocketTimeoutException) {
                            // Normal timeout, loop again
                        } catch (e: SocketException) {
                            break // Socket closed
                        } catch (e: Exception) {
                            Log.e(TAG, "Lỗi nhận phản hồi UDP", e)
                        }
                    }
                }

                // Coroutine 2: Periodically broadcast search pings
                while (isActive) {
                    try {
                        val pingMsg = "SWIFTSHARE_PING:$deviceName"
                        val pingBytes = pingMsg.toByteArray()
                        val addresses = listOf(
                            InetAddress.getByName("255.255.255.255"),
                            InetAddress.getByName("192.168.1.255"),
                            InetAddress.getByName("192.168.0.255")
                        )
                        for (addr in addresses) {
                            val packet = DatagramPacket(pingBytes, pingBytes.size, addr, UDP_DISCOVERY_PORT)
                            socket.send(packet)
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "Lỗi phát sóng ping quét thiết bị", e)
                    }

                    // Remove inactive devices after 6 seconds
                    val now = System.currentTimeMillis()
                    val countBefore = deviceMap.size
                    deviceMap.entries.removeIf { now - it.value.lastSeen > 6000 }
                    if (deviceMap.size != countBefore) {
                        _discoveredDevices.value = deviceMap.values.toList()
                    }

                    delay(2000)
                }

                receiveJob.join()

            } catch (e: Exception) {
                Log.e(TAG, "Lỗi trong tiến trình quét UDP", e)
            } finally {
                socket?.close()
            }
        }
    }

    fun stopScanning() {
        udpScanJob?.cancel()
        udpScanJob = null
        _discoveredDevices.value = emptyList()
    }

    // --- TCP SERVER FOR AUTO-RECEIVE ---

    fun startTcpServer(context: Context, onNotificationRequested: (title: String, body: String) -> Unit) {
        tcpServerJob?.cancel()
        serverSocket?.close()

        tcpServerJob = CoroutineScope(Dispatchers.IO).launch {
            try {
                serverSocket = ServerSocket(TCP_TRANSFER_PORT).apply {
                    reuseAddress = true
                }
                Log.d(TAG, "Máy chủ TCP đã khởi chạy trên cổng $TCP_TRANSFER_PORT")

                while (isActive) {
                    val clientSocket = try {
                        serverSocket?.accept()
                    } catch (e: Exception) {
                        null
                    } ?: break

                    // Handle connection sequentially or parallel depending on need.
                    // A single file transfer is best to avoid disk-write thrashing, but let's process each client in a separate coroutine
                    val incomingJob = launch {
                        handleIncomingTransfer(context, clientSocket, onNotificationRequested)
                    }
                    activeJob = incomingJob
                }
            } catch (e: Exception) {
                Log.e(TAG, "Lỗi nghiêm trọng máy chủ TCP", e)
            }
        }
    }

    fun stopTcpServer() {
        tcpServerJob?.cancel()
        tcpServerJob = null
        try {
            serverSocket?.close()
        } catch (e: Exception) {
            // normal
        }
        serverSocket = null
    }

    // Helpers to create public media / downloads file pointers without duplicating data on disk
    private fun getMimeType(fileName: String): String {
        val extension = fileName.substringAfterLast('.', "").lowercase(Locale.ROOT)
        return when (extension) {
            "jpg", "jpeg" -> "image/jpeg"
            "png" -> "image/png"
            "gif" -> "image/gif"
            "webp" -> "image/webp"
            "bmp" -> "image/bmp"
            "mp4" -> "video/mp4"
            "mkv" -> "video/x-matroska"
            "mov" -> "video/quicktime"
            "3gp" -> "video/3gpp"
            "webm" -> "video/webm"
            "avi" -> "video/x-msvideo"
            "pdf" -> "application/pdf"
            "apk" -> "application/vnd.android.package-archive"
            "zip" -> "application/zip"
            "txt" -> "text/plain"
            "mp3" -> "audio/mpeg"
            "wav" -> "audio/wav"
            else -> "application/octet-stream"
        }
    }

    private fun createPublicFileAndGetStream(
        context: Context,
        fileName: String,
        isImage: Boolean,
        isVideo: Boolean,
        fileSize: Long
    ): Pair<OutputStream?, Uri?> {
        val resolver = context.contentResolver
        val isAtLeastQ = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q

        if (isAtLeastQ) {
            val contentValues = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                put(MediaStore.MediaColumns.SIZE, fileSize)
                val mime = getMimeType(fileName)
                put(MediaStore.MediaColumns.MIME_TYPE, mime)

                if (isImage) {
                    put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_PICTURES + "/SwiftShare")
                } else if (isVideo) {
                    put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_MOVIES + "/SwiftShare")
                } else {
                    put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/SwiftShare")
                }
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }

            val collectionUri = if (isImage) {
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            } else if (isVideo) {
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            } else {
                MediaStore.Downloads.EXTERNAL_CONTENT_URI
            }

            try {
                val uri = resolver.insert(collectionUri, contentValues)
                if (uri != null) {
                    val os = resolver.openOutputStream(uri)
                    return Pair(os, uri)
                }
            } catch (e: Exception) {
                Log.e(TAG, "MediaStore insert failed, falling back to private storage", e)
            }
        }

        // Fallback to legacy private file storage (pre-Q or if MediaStore failures occur)
        try {
            val downloadsDir = context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
                ?: throw IOException("Thư mục lưu trữ không khả dụng")
            if (!downloadsDir.exists()) downloadsDir.mkdirs()
            val destFile = getUniqueFile(downloadsDir, fileName)
            val os = FileOutputStream(destFile)
            val uri = Uri.fromFile(destFile)
            return Pair(os, uri)
        } catch (e: Exception) {
            Log.e(TAG, "Fallback also failed", e)
            return Pair(null, null)
        }
    }

    private fun completePendingFile(context: Context, uri: Uri, fileSize: Long) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && uri.scheme == "content") {
            try {
                val contentValues = ContentValues().apply {
                    put(MediaStore.MediaColumns.IS_PENDING, 0)
                    put(MediaStore.MediaColumns.SIZE, fileSize)
                }
                context.contentResolver.update(uri, contentValues, null, null)
            } catch (e: Exception) {
                Log.e(TAG, "Lỗi khi cập nhật IS_PENDING = 0", e)
            }
        }
        // Run media scanner if it has a file path scheme
        try {
            val path = if (uri.scheme == "file") uri.path else null
            if (path != null) {
                MediaScannerConnection.scanFile(
                    context,
                    arrayOf(path),
                    null
                ) { p, scannedUri ->
                    Log.d(TAG, "Xử lý quét file hoàn thành: $p -> $scannedUri")
                }
            }
        } catch (e: Exception) {}
    }

    private fun deletePendingFile(context: Context, uri: Uri) {
        try {
            if (uri.scheme == "content") {
                context.contentResolver.delete(uri, null, null)
            } else if (uri.scheme == "file") {
                val file = File(uri.path ?: "")
                if (file.exists()) {
                    file.delete()
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Lỗi khi xóa file tạm do chuyển thất bại", e)
        }
    }

    private suspend fun handleIncomingTransfer(
        context: Context,
        socket: Socket,
        onNotificationRequested: (title: String, body: String) -> Unit
    ) {
        var dis: DataInputStream? = null
        var bos: BufferedOutputStream? = null
        var senderName = "Thiết bị"
        var targetUri: Uri? = null

        try {
            activeSocket = socket
            socket.tcpNoDelay = true // Disable Nagle's algorithm for faster transfers
            socket.receiveBufferSize = 1024 * 1024 // 1MB receive buffer for maximum throughput
            dis = DataInputStream(BufferedInputStream(socket.getInputStream(), 1024 * 1024))

            // 1. Read Metadata Length
            val metaLength = dis.readInt()
            if (metaLength <= 0 || metaLength > 1024 * 1024) throw IOException("Kích thước metadata không hợp lệ")

            // 2. Read Metadata Byte
            val metaBytes = ByteArray(metaLength)
            dis.readFully(metaBytes)
            val metaStr = String(metaBytes, Charsets.UTF_8)

            // Metadata Format: name|size|sender
            val parts = metaStr.split("|")
            if (parts.size < 3) throw IOException("Metadata không đúng định dạng")
            val fileName = parts[0]
            val fileSize = parts[1].toLongOrNull() ?: 0L
            senderName = parts[2]

            Log.d(TAG, "Bắt đầu nhận file: $fileName, Dung lượng: $fileSize từ: $senderName")
            onNotificationRequested("Nhận diện gửi file", "$senderName đang gửi cho bạn: $fileName")

            // 4. Create Public Output Stream (using MediaStore / Scoped Storage for high efficiency and zero copy)
            val lowercaseName = fileName.lowercase(Locale.ROOT)
            val isImage = lowercaseName.endsWith(".jpg") || lowercaseName.endsWith(".jpeg") ||
                    lowercaseName.endsWith(".png") || lowercaseName.endsWith(".gif") ||
                    lowercaseName.endsWith(".webp") || lowercaseName.endsWith(".bmp")
            val isVideo = lowercaseName.endsWith(".mp4") || lowercaseName.endsWith(".mkv") ||
                    lowercaseName.endsWith(".mov") || lowercaseName.endsWith(".3gp") ||
                    lowercaseName.endsWith(".webm") || lowercaseName.endsWith(".avi")

            val (rawStream, fileUri) = createPublicFileAndGetStream(context, fileName, isImage, isVideo, fileSize)
            if (rawStream == null || fileUri == null) {
                throw IOException("Không thể chuẩn bị luồng dữ liệu đích để lưu")
            }
            targetUri = fileUri
            bos = BufferedOutputStream(rawStream, 1024 * 1024)

            _activeTransfer.value = TransferState(
                id = Random().nextLong(),
                fileName = fileName,
                totalBytes = fileSize,
                bytesTransferred = 0L,
                progress = 0,
                speedMbps = 0.0,
                isIncoming = true,
                peerName = senderName,
                status = "TRANSFERRING"
            )

            // 5. Transfer File bytes
            val buffer = ByteArray(BUFFER_SIZE)
            var bytesRead: Int
            var totalRead = 0L
            var lastUpdate = System.currentTimeMillis()
            var bytesSavedSinceLastUpdate = 0L

            // Keep track of speed of transfer
            while (totalRead < fileSize) {
                // Read from buffered stream
                val toRead = java.lang.Math.min(buffer.size.toLong(), fileSize - totalRead).toInt()
                bytesRead = dis.read(buffer, 0, toRead)
                if (bytesRead == -1) break

                bos.write(buffer, 0, bytesRead)
                totalRead += bytesRead
                bytesSavedSinceLastUpdate += bytesRead

                val now = System.currentTimeMillis()
                val delta = now - lastUpdate
                if (delta >= 500 || totalRead == fileSize) {
                    val progress = if (fileSize > 0) ((totalRead * 100) / fileSize).toInt() else 0
                    val speedMBs = if (delta > 0) (bytesSavedSinceLastUpdate / 1024.0 / 1024.0) / (delta / 1000.0) else 0.0

                    _activeTransfer.value = _activeTransfer.value?.copy(
                        bytesTransferred = totalRead,
                        progress = progress,
                        speedMbps = speedMBs
                    )

                    // NOTE: Removed database update inside the I/O loop to avoid blocking operations!

                    lastUpdate = now
                    bytesSavedSinceLastUpdate = 0
                }
            }

            bos.flush()
            bos.close()
            bos = null

            if (totalRead >= fileSize) {
                // Complete file pending status
                completePendingFile(context, fileUri, fileSize)

                // If fallback file was used, copy to gallery if it's media
                if (fileUri.scheme == "file") {
                    val fallbackFile = File(fileUri.path ?: "")
                    if (fallbackFile.exists()) {
                        saveMediaToGallery(context, fallbackFile)
                    }
                }

                // Success!
                val displayPath = if (fileUri.scheme == "content") {
                    if (isImage) "Thư viện ảnh / SwiftShare/$fileName"
                    else if (isVideo) "Thư viện video / SwiftShare/$fileName"
                    else "Thư mục tải về / SwiftShare/$fileName"
                } else {
                    fileUri.path ?: ""
                }

                _activeTransfer.value = _activeTransfer.value?.copy(status = "SUCCESS", progress = 100)
                Log.d(TAG, "Truyền file thành công: $displayPath")
                onNotificationRequested("Truyền file thành công", "Đã nhận được $fileName từ $senderName")
            } else {
                throw IOException("Luồng tải file bị gián đoạn giữa chừng")
            }

        } catch (e: Exception) {
            Log.e(TAG, "Lỗi khi nhận file", e)
            _activeTransfer.value = _activeTransfer.value?.copy(status = "FAILED", error = e.localizedMessage)

            // Clean up files
            try { bos?.close() } catch (e: Exception) {}
            bos = null
            if (targetUri != null) {
                deletePendingFile(context, targetUri)
            }

            onNotificationRequested("Lỗi truyền tải", "Lỗi xảy ra khi nhận file từ $senderName")
        } finally {
            if (activeSocket === socket) {
                activeSocket = null
                activeJob = null
            }
            try { bos?.close() } catch (e: Exception) {}
            try { dis?.close() } catch (e: Exception) {}
            try { socket.close() } catch (e: Exception) {}
            delay(1500) // Keep the completed/failed state on screen for 1.5s
            _activeTransfer.value = null
        }
    }


    // --- SENDER TRANSFER INITIATION ---

    fun sendFile(
        context: Context,
        device: DeviceInfo,
        fileUri: Uri,
        senderName: String,
        onDone: (success: Boolean, errorMsg: String?) -> Unit
    ) {
        val sendJob = CoroutineScope(Dispatchers.IO).launch {
            var socket: Socket? = null
            var bos: BufferedOutputStream? = null
            var bis: BufferedInputStream? = null
            try {
                // Extract Uri details
                val (fileName, fileSize) = getUriDetails(context, fileUri)
                if (fileName == null || fileSize <= 0) {
                    throw IOException("Không thể đọc thông tin file được chọn.")
                }

                _activeTransfer.value = TransferState(
                    id = Random().nextLong(),
                    fileName = fileName,
                    totalBytes = fileSize,
                    bytesTransferred = 0L,
                    progress = 0,
                    speedMbps = 0.0,
                    isIncoming = false,
                    peerName = device.name,
                    status = "CONNECTING"
                )

                // 2. Establish connection to receiver TCP Server
                socket = Socket()
                activeSocket = socket
                socket.tcpNoDelay = true
                socket.sendBufferSize = 1024 * 1024 // 1MB Send buffer size
                socket.connect(InetSocketAddress(device.ipAddress, device.port), 10000)

                _activeTransfer.value = _activeTransfer.value?.copy(status = "TRANSFERRING")

                // 3. Write metadata prefix
                val metaStr = "$fileName|$fileSize|$senderName"
                val metaBytes = metaStr.toByteArray(Charsets.UTF_8)

                bos = BufferedOutputStream(socket.getOutputStream(), 1024 * 1024)
                val dos = DataOutputStream(bos)
                dos.writeInt(metaBytes.size)
                dos.write(metaBytes)
                dos.flush()

                // 4. Open and write File contents
                val rawInputStream = context.contentResolver.openInputStream(fileUri)
                    ?: throw IOException("Không thể mở file được chọn.")
                bis = BufferedInputStream(rawInputStream, 1024 * 1024)

                val buffer = ByteArray(BUFFER_SIZE)
                var bytesRead: Int
                var totalSent = 0L
                var lastUpdate = System.currentTimeMillis()
                var bytesSavedSinceLastUpdate = 0L

                while (isActive) {
                    bytesRead = bis.read(buffer)
                    if (bytesRead == -1) break

                    bos.write(buffer, 0, bytesRead)
                    totalSent += bytesRead
                    bytesSavedSinceLastUpdate += bytesRead

                    val now = System.currentTimeMillis()
                    val delta = now - lastUpdate
                    if (delta >= 500 || totalSent == fileSize) {
                        val progress = if (fileSize > 0) ((totalSent * 100) / fileSize).toInt() else 0
                        val speedMBs = if (delta > 0) (bytesSavedSinceLastUpdate / 1024.0 / 1024.0) / (delta / 1000.0) else 0.0

                        _activeTransfer.value = _activeTransfer.value?.copy(
                            bytesTransferred = totalSent,
                            progress = progress,
                            speedMbps = speedMBs
                        )

                        // NOTE: Removed database updates within the sending loop to avoid SQLite blockages

                        lastUpdate = now
                        bytesSavedSinceLastUpdate = 0
                    }
                }

                bos.flush()

                if (totalSent >= fileSize) {
                    // Successful completion!
                    _activeTransfer.value = _activeTransfer.value?.copy(status = "SUCCESS", progress = 100)
                    Log.d(TAG, "Đã gửi file xong.")
                    onDone(true, null)
                } else {
                    throw IOException("Hủy truyền file nửa chừng.")
                }

            } catch (e: Exception) {
                Log.e(TAG, "Lỗi gửi file đi", e)
                _activeTransfer.value = _activeTransfer.value?.copy(status = "FAILED", error = e.localizedMessage)
                onDone(false, e.localizedMessage)
            } finally {
                if (activeSocket === socket) {
                    activeSocket = null
                    activeJob = null
                }
                try { bis?.close() } catch (e: Exception) {}
                try { bos?.close() } catch (e: Exception) {}
                try { socket?.close() } catch (e: Exception) {}
                delay(1500)
                _activeTransfer.value = null
            }
        }
        activeJob = sendJob
    }

    // Resolves simple Uri metadata details
    fun getUriDetails(context: Context, uri: Uri): Pair<String?, Long> {
        var name: String? = null
        var size = 0L

        if (uri.scheme == ContentResolver.SCHEME_CONTENT) {
            val cursor = context.contentResolver.query(uri, null, null, null, null)
            cursor?.use {
                if (it.moveToFirst()) {
                    val nameIndex = it.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (nameIndex != -1) name = it.getString(nameIndex)

                    val sizeIndex = it.getColumnIndex(OpenableColumns.SIZE)
                    if (sizeIndex != -1) size = it.getLong(sizeIndex)
                }
            }
        }
        if (name == null) {
            name = uri.path?.substringAfterLast('/')
        }
        return Pair(name, size)
    }

    // Saves images and videos into Android's system photo gallery
    private fun saveMediaToGallery(context: Context, file: File) {
        val lowercaseName = file.name.lowercase(Locale.ROOT)
        val isImage = lowercaseName.endsWith(".jpg") || lowercaseName.endsWith(".jpeg") ||
                lowercaseName.endsWith(".png") || lowercaseName.endsWith(".gif") ||
                lowercaseName.endsWith(".webp") || lowercaseName.endsWith(".bmp")

        val isVideo = lowercaseName.endsWith(".mp4") || lowercaseName.endsWith(".mkv") ||
                lowercaseName.endsWith(".mov") || lowercaseName.endsWith(".3gp") ||
                lowercaseName.endsWith(".webm") || lowercaseName.endsWith(".avi")

        if (!isImage && !isVideo) {
            // Non-media file. Just invoke public media scanner so it can be viewed by download / file explorers
            MediaScannerConnection.scanFile(
                context,
                arrayOf(file.absolutePath),
                null
            ) { path, scannedUri ->
                Log.d(TAG, "File scanned: $path -> $scannedUri")
            }
            return
        }

        try {
            val resolver = context.contentResolver
            val contentValues = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, file.name)
                put(MediaStore.MediaColumns.SIZE, file.length())
                if (isImage) {
                    put(MediaStore.MediaColumns.MIME_TYPE, "image/*")
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_PICTURES + "/SwiftShare")
                        put(MediaStore.MediaColumns.IS_PENDING, 1)
                    }
                } else {
                    put(MediaStore.MediaColumns.MIME_TYPE, "video/*")
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_MOVIES + "/SwiftShare")
                        put(MediaStore.MediaColumns.IS_PENDING, 1)
                    }
                }
            }

            val collectionUri = if (isImage) {
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            } else {
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            }

            val uri = resolver.insert(collectionUri, contentValues)
            if (uri != null) {
                resolver.openOutputStream(uri)?.use { outputStream ->
                    FileInputStream(file).use { inputStream ->
                        val buffer = ByteArray(BUFFER_SIZE)
                        var read: Int
                        while (inputStream.read(buffer).also { read = it } != -1) {
                            outputStream.write(buffer, 0, read)
                        }
                        outputStream.flush()
                    }
                }

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    contentValues.clear()
                    contentValues.put(MediaStore.MediaColumns.IS_PENDING, 0)
                    resolver.update(uri, contentValues, null, null)
                }

                // Also trigger scanner registration
                MediaScannerConnection.scanFile(
                    context,
                    arrayOf(file.absolutePath),
                    null
                ) { path, scannedUri ->
                    Log.d(TAG, "Scanner index completed: $path -> $scannedUri")
                }

                Log.d(TAG, "Lưu file media vào thư viện thành công: $uri")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Nỗ lực lưu file vào Gallery thất bại", e)
        }
    }

    // Prevents duplicates in received directory files
    private fun getUniqueFile(directory: File, name: String): File {
        var file = File(directory, name)
        if (!file.exists()) return file

        val dotIndex = name.lastIndexOf('.')
        val baseName = if (dotIndex != -1) name.substring(0, dotIndex) else name
        val extension = if (dotIndex != -1) name.substring(dotIndex) else ""

        var count = 1
        while (file.exists()) {
            file = File(directory, "$baseName($count)$extension")
            count++
        }
        return file
    }
}
