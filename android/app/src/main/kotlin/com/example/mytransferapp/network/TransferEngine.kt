package com.example.mytransferapp.network

import android.content.ContentValues
import android.content.Context
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import com.example.mytransferapp.model.ScanMode
import com.example.mytransferapp.model.SendMode
import com.example.mytransferapp.model.TargetDevice
import com.example.mytransferapp.model.TransferHandle
import com.example.mytransferapp.model.TransferState
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import java.io.*
import java.net.*
import java.util.Locale
import java.util.Random
import java.util.concurrent.ConcurrentHashMap

object TransferEngine {
    private const val TAG = "TransferEngine"
    private const val UDP_DISCOVERY_PORT = 8889
    private const val TCP_TRANSFER_PORT = 9999
    private const val BUFFER_SIZE = 512 * 1024 // 512KB

    // ==================== HANDSHAKE PROTOCOL ====================
    private const val MSG_TYPE_REQUEST = 0   // Xin phép gửi N file
    private const val MSG_TYPE_FILE = 1      // Dữ liệu file
    private const val RESPONSE_ACCEPT = 1
    private const val RESPONSE_REJECT = 0
    private const val REQUEST_TIMEOUT_MS = 60_000L

    // ==================== STATE FLOWS ====================

    private val _discoveredDevices = MutableStateFlow<List<TargetDevice>>(emptyList())
    val discoveredDevices: StateFlow<List<TargetDevice>> = _discoveredDevices.asStateFlow()

    // Map<transferId, TransferState> — hỗ trợ nhiều transfer cùng lúc
    private val _transfers = MutableStateFlow<Map<Long, TransferState>>(emptyMap())
    val transfers: StateFlow<Map<Long, TransferState>> = _transfers.asStateFlow()

    // Backward compatibility — lấy transfer đầu tiên nếu chỉ cần 1
    val activeTransfer: StateFlow<TransferState?> = _transfers
        .map { it.values.firstOrNull() }
        .stateIn(CoroutineScope(Dispatchers.IO), SharingStarted.Eagerly, null)

    private val _isWifiScanning = MutableStateFlow(false)
    val isWifiScanning: StateFlow<Boolean> = _isWifiScanning.asStateFlow()

    private val _isBluetoothScanning = MutableStateFlow(false)
    val isBluetoothScanning: StateFlow<Boolean> = _isBluetoothScanning.asStateFlow()

    private val _isReceiving = MutableStateFlow(false)
    val isReceiving: StateFlow<Boolean> = _isReceiving.asStateFlow()

    private val _isAdvertising = MutableStateFlow(false)
    val isAdvertising: StateFlow<Boolean> = _isAdvertising.asStateFlow()

    // Stream thông báo khi có thiết bị request gửi file đến (cần Accept/Reject)
    private val _incomingConnectionRequest = MutableSharedFlow<TargetDevice>(
        replay = 0,
        extraBufferCapacity = 8,
        onBufferOverflow = BufferOverflow.DROP_OLDEST
    )
    val incomingConnectionRequest: SharedFlow<TargetDevice> =
        _incomingConnectionRequest.asSharedFlow()

    // Kết quả handshake gửi-đi: thiết bị đích đã accept hay reject request
    data class SendRequestResult(val device: TargetDevice, val accepted: Boolean)

    private val _sendRequestResult = MutableSharedFlow<SendRequestResult>(
        replay = 0,
        extraBufferCapacity = 16,
        onBufferOverflow = BufferOverflow.DROP_OLDEST
    )
    val sendRequestResult: SharedFlow<SendRequestResult> = _sendRequestResult.asSharedFlow()

    // ==================== INTERNAL ====================

    private val deviceMap = ConcurrentHashMap<String, TargetDevice>()

    // Track handle (socket + job) theo transferId
    private val activeTransfers = ConcurrentHashMap<Long, TransferHandle>()

    // Track các request đang chờ người dùng accept/reject
    private data class PendingRequest(val deferred: CompletableDeferred<Boolean>)

    private val pendingRequests = ConcurrentHashMap<Long, PendingRequest>()

    private var udpScanJob: Job? = null
    private var udpAdvertiseJob: Job? = null
    private var tcpServerJob: Job? = null
    private var serverSocket: ServerSocket? = null

    // ==================== EMIT HELPERS ====================

    private fun emitTransfer(state: TransferState) {
        _transfers.update { current ->
            current.toMutableMap().also { it[state.id] = state }
        }
    }

    private fun removeTransfer(id: Long) {
        _transfers.update { current ->
            current.toMutableMap().also { it.remove(id) }
        }
    }

    // ==================== PUBLIC API ====================

    fun setBluetoothScanning(isScanning: Boolean) {
        _isBluetoothScanning.value = isScanning
    }

    // Cancel theo transferId, hoặc cancel tất cả nếu null
    fun cancelActiveTransfer(transferId: Long? = null) {
        if (transferId == null) {
            Log.d(TAG, "Huỷ tất cả transfer đang hoạt động")
            activeTransfers.forEach { (id, handle) ->
                _transfers.value[id]?.let { state ->
                    emitTransfer(state.copy(status = "FAILED", error = "Bị huỷ bởi người dùng"))
                }
                try {
                    handle.socket.close()
                } catch (e: Exception) {
                }
                handle.job.cancel()
            }
            activeTransfers.clear()
        } else {
            Log.d(TAG, "Huỷ transfer id=$transferId")
            activeTransfers[transferId]?.let { handle ->
                _transfers.value[transferId]?.let { state ->
                    emitTransfer(state.copy(status = "FAILED", error = "Bị huỷ bởi người dùng"))
                }
                try {
                    handle.socket.close()
                } catch (e: Exception) {
                }
                handle.job.cancel()
                activeTransfers.remove(transferId)
            }
        }
    }

    fun getDeviceName(): String {
        val manufacturer = Build.MANUFACTURER
        val model = Build.MODEL
        return if (model.startsWith(manufacturer)) {
            model.replaceFirstChar { it.uppercase() }
        } else {
            "${manufacturer.replaceFirstChar { it.uppercase() }} $model"
        }
    }

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

    // ==================== UDP DISCOVERY ====================

    fun startAdvertising(deviceName: String) {
        udpAdvertiseJob?.cancel()
        _isAdvertising.value = true
        udpAdvertiseJob = CoroutineScope(Dispatchers.IO).launch {
            var socket: DatagramSocket? = null
            try {
                socket = DatagramSocket(UDP_DISCOVERY_PORT).apply { reuseAddress = true }
                Log.d(TAG, "Bắt đầu phát sóng nhận diện trên cổng $UDP_DISCOVERY_PORT")
                val buffer = ByteArray(1024)
                while (isActive) {
                    val packet = DatagramPacket(buffer, buffer.size)
                    try {
                        socket.receive(packet)
                        val message = String(packet.data, 0, packet.length).trim()
                        if (message.startsWith("SUPERTRANSFER_PING:")) {
                            val replyMsg = "SUPERTRANSFER_PONG:$deviceName:$TCP_TRANSFER_PORT"
                            val replyBytes = replyMsg.toByteArray()
                            val replyPacket = DatagramPacket(
                                replyBytes, replyBytes.size,
                                packet.address, packet.port
                            )
                            socket.send(replyPacket)
                            Log.d(TAG, "Đã phản hồi PING từ ${packet.address.hostAddress}")
                        }
                    } catch (e: SocketException) {
                        break
                    } catch (e: Exception) {
                        Log.e(TAG, "Lỗi trong vòng lặp nhận UDP", e)
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Không thể khởi động UDP advertise", e)
            } finally {
                socket?.close()
            }
        }.also { job ->
            job.invokeOnCompletion { _isAdvertising.value = false }
        }
    }

    fun stopAdvertising() {
        udpAdvertiseJob?.cancel()
        udpAdvertiseJob = null
        _isAdvertising.value = false
    }

    fun startWifiScanning(deviceName: String, timeoutMs: Int) {
        deviceMap.clear()
        _discoveredDevices.value = emptyList()
        _isWifiScanning.value = true
        udpScanJob?.cancel()
        udpScanJob = CoroutineScope(Dispatchers.IO).launch {
            var socket: DatagramSocket? = null
            try {
                socket = DatagramSocket().apply {
                    broadcast = true
                    soTimeout = 1500
                    sendBufferSize = 4 * 1024
                    receiveBufferSize = 8 * 1024
                    reuseAddress = true
                }
                val socketDeadline = System.currentTimeMillis() + timeoutMs

                val receiveJob = launch {
                    val buffer = ByteArray(1024)
                    while (isActive && System.currentTimeMillis() < socketDeadline) {
                        val packet = DatagramPacket(buffer, buffer.size)
                        try {
                            socket.receive(packet)
                            val message = String(packet.data, 0, packet.length).trim()
                            if (message.startsWith("SUPERTRANSFER_PONG:")) {
                                val parts = message.split(":")
                                val peerName = parts.getOrNull(1) ?: "Thiết bị"
                                val peerPort =
                                    parts.getOrNull(2)?.toIntOrNull() ?: TCP_TRANSFER_PORT
                                val peerIp = packet.address.hostAddress ?: ""
                                if (peerIp.isNotEmpty()) {
                                    val device =
                                        TargetDevice(peerIp, peerName, peerPort, ScanMode.WIFI)
                                    deviceMap[peerIp] = device
                                    _discoveredDevices.value = deviceMap.values.toList()
                                    Log.d(TAG, "Tìm thấy: $peerName ($peerIp:$peerPort)")
                                }
                            }
                        } catch (e: SocketTimeoutException) {
                            // bình thường
                        } catch (e: SocketException) {
                            break
                        } catch (e: Exception) {
                            Log.e(TAG, "Lỗi nhận UDP", e)
                        }
                    }
                }

                val pingJob = launch {
                    while (isActive && System.currentTimeMillis() < socketDeadline) {
                        try {
                            val pingMsg = "SUPERTRANSFER_PING:$deviceName"
                            val pingBytes = pingMsg.toByteArray()
                            val broadcastAddresses = buildList {
                                add(InetAddress.getByName("255.255.255.255"))
                                getLocalSubnetBroadcast()?.let { add(it) }
                            }
                            for (addr in broadcastAddresses) {
                                if (!socket.isClosed) {
                                    socket.send(
                                        DatagramPacket(
                                            pingBytes,
                                            pingBytes.size,
                                            addr,
                                            UDP_DISCOVERY_PORT
                                        )
                                    )
                                }
                            }
                        } catch (e: Exception) {
                            Log.e(TAG, "Lỗi phát sóng ping", e)
                        }
                        val now = System.currentTimeMillis()
                        val before = deviceMap.size
                        deviceMap.entries.removeIf { now - it.value.lastSeen > 6000 }
                        if (deviceMap.size != before) _discoveredDevices.value =
                            deviceMap.values.toList()
                        delay(2000)
                    }
                }

                launch {
                    delay(timeoutMs.toLong())
                    Log.d(TAG, "Scan timeout — closing socket")
                    socket?.close()
                    pingJob.cancel()
                    receiveJob.cancel()
                }

                pingJob.join()
                receiveJob.join()

            } catch (e: Exception) {
                Log.e(TAG, "Lỗi UDP scan", e)
            } finally {
                try {
                    socket?.close()
                } catch (_: Exception) {
                }
                _isWifiScanning.value = false
                Log.d(TAG, "UDP scan finished")
            }
        }.also { job ->
            job.invokeOnCompletion { _isWifiScanning.value = false }
        }
    }

    fun stopWifiScanning() {
        udpScanJob?.cancel()
        udpScanJob = null
        _isWifiScanning.value = false
        _discoveredDevices.value = emptyList()
    }

    private fun getLocalSubnetBroadcast(): InetAddress? {
        return try {
            val interfaces = NetworkInterface.getNetworkInterfaces()
            while (interfaces.hasMoreElements()) {
                val iface = interfaces.nextElement()
                if (iface.isLoopback || !iface.isUp) continue
                for (addr in iface.interfaceAddresses) {
                    val ia = addr.address
                    if (ia !is Inet4Address || ia.isLoopbackAddress) continue
                    val prefix = addr.networkPrefixLength.toInt()
                    val ip = ia.address
                    val mask = (-1 shl (32 - prefix))
                    val broadcast = ByteArray(4) { i ->
                        (ip[i].toInt() and (mask shr (24 - i * 8)) or
                                (0xFF and (mask shr (24 - i * 8)).inv())).toByte()
                    }
                    return InetAddress.getByAddress(broadcast)
                }
            }
            null
        } catch (e: Exception) {
            null
        }
    }

    // ==================== TCP SERVER (RECEIVE) ====================

    fun startTcpServer(
        context: Context,
        onNotificationRequested: (title: String, body: String) -> Unit
    ) {
        tcpServerJob?.cancel()
        serverSocket?.close()
        _isReceiving.value = true

        tcpServerJob = CoroutineScope(Dispatchers.IO).launch {
            try {
                serverSocket = ServerSocket(TCP_TRANSFER_PORT).apply { reuseAddress = true }
                Log.d(TAG, "TCP server trên cổng $TCP_TRANSFER_PORT")

                while (isActive) {
                    val clientSocket = try {
                        serverSocket?.accept()
                    } catch (e: Exception) {
                        null
                    } ?: break

                    val clientIp = clientSocket.inetAddress.hostAddress ?: ""
                    Log.d(TAG, "Kết nối đến từ: $clientIp:${clientSocket.port}")

                    // Mỗi connection xử lý trong coroutine riêng — nhận song song
                    launch {
                        handleIncomingConnection(context, clientSocket, onNotificationRequested)
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Lỗi TCP server", e)
            } finally {
                _isReceiving.value = false
            }
        }
    }

    fun stopTcpServer() {
        tcpServerJob?.cancel()
        tcpServerJob = null
        _isReceiving.value = false
        try {
            serverSocket?.close()
        } catch (e: Exception) {
        }
        serverSocket = null
    }

    // Phân loại connection: REQUEST (xin phép) hay FILE (dữ liệu)
    private suspend fun handleIncomingConnection(
        context: Context,
        socket: Socket,
        onNotificationRequested: (title: String, body: String) -> Unit
    ) {
        try {
            socket.tcpNoDelay = true
            val dis = DataInputStream(BufferedInputStream(socket.getInputStream(), 1024 * 1024))
            val msgType = dis.readInt()

            when (msgType) {
                MSG_TYPE_REQUEST -> handleIncomingRequest(socket, dis, onNotificationRequested)
                MSG_TYPE_FILE -> {
                    val transferId = Random().nextLong()
                    val incomingJob = currentCoroutineContext()[Job]!!
                    activeTransfers[transferId] = TransferHandle(
                        socket = socket,
                        job = incomingJob
                    )
                    handleIncomingTransfer(
                        context,
                        socket,
                        dis,
                        transferId,
                        onNotificationRequested
                    )
                }

                else -> {
                    Log.e(TAG, "Unknown msgType=$msgType, đóng kết nối")
                    socket.close()
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Lỗi handleIncomingConnection", e)
            try {
                socket.close()
            } catch (_: Exception) {
            }
        }
    }

    // ==================== REQUEST HANDSHAKE (bên nhận) ====================

    private suspend fun handleIncomingRequest(
        socket: Socket,
        dis: DataInputStream,
        onNotificationRequested: (title: String, body: String) -> Unit
    ) {
        var accepted = false
        val requestId = Random().nextLong()
        try {
            val metaLength = dis.readInt()
            if (metaLength <= 0 || metaLength > 1024 * 1024) throw IOException("Kích thước metadata không hợp lệ")
            val metaBytes = ByteArray(metaLength)
            dis.readFully(metaBytes)
            val metaStr = String(metaBytes, Charsets.UTF_8)

            val parts = metaStr.split("|")
            val senderName = parts.getOrNull(0) ?: "Thiết bị"
            val totalFiles = parts.getOrNull(1)?.toIntOrNull() ?: 1
            val senderIp = socket.inetAddress.hostAddress ?: ""
            val senderPort = socket.port

            val deferred = CompletableDeferred<Boolean>()
            pendingRequests[requestId] = PendingRequest(deferred)

            _incomingConnectionRequest.tryEmit(
                TargetDevice(
                    name = senderName,
                    ipAddress = senderIp,
                    port = senderPort,
                    from = ScanMode.WIFI,
                    totalFiles = totalFiles,
                    requestId = requestId,
                    lastSeen = System.currentTimeMillis(),
                )
            )

            onNotificationRequested("Yêu cầu nhận file", "$senderName muốn gửi $totalFiles file")
            Log.d(
                TAG,
                "Nhận request id=$requestId từ $senderName ($senderIp), totalFiles=$totalFiles"
            )

            accepted = try {
                withTimeout(REQUEST_TIMEOUT_MS) { deferred.await() }
            } catch (e: TimeoutCancellationException) {
                Log.d(TAG, "Request id=$requestId timeout — auto reject")
                false
            }

        } catch (e: Exception) {
            Log.e(TAG, "Lỗi xử lý request id=$requestId", e)
            accepted = false
        } finally {
            // Phản hồi cho sender
            try {
                val bos = BufferedOutputStream(socket.getOutputStream())
                val dos = DataOutputStream(bos)
                dos.writeInt(if (accepted) RESPONSE_ACCEPT else RESPONSE_REJECT)
                dos.flush()
            } catch (e: Exception) {
                Log.e(TAG, "Lỗi gửi response request id=$requestId", e)
            }
            pendingRequests.remove(requestId)
            try {
                socket.close()
            } catch (e: Exception) {
            }
        }
    }

    /**
     * Người dùng đồng ý nhận file — gọi từ MethodChannel "acceptRequest"
     */
    fun acceptRequest(requestId: Long) {
        Log.d(TAG, "acceptRequest id=$requestId")
        pendingRequests[requestId]?.deferred?.complete(true)
            ?: Log.w(TAG, "acceptRequest: không tìm thấy requestId=$requestId (có thể đã timeout)")
    }

    /**
     * Người dùng từ chối / hủy request — gọi từ MethodChannel "cancelRequest"
     */
    fun cancelRequest(requestId: Long) {
        Log.d(TAG, "cancelRequest id=$requestId")
        pendingRequests[requestId]?.deferred?.complete(false)
            ?: Log.w(TAG, "cancelRequest: không tìm thấy requestId=$requestId (có thể đã timeout)")
    }

    // ==================== SEND FILE ====================

    // Gửi NHIỀU file đến NHIỀU thiết bị với 2 mode: SEQUENTIAL hoặc PARALLEL
    //
    // PHASE 1: Gửi REQUEST (xin phép) tới TẤT CẢ thiết bị SONG SONG. Kết quả
    //          accept/reject của từng thiết bị được emit ngay qua sendRequestResult.
    // PHASE 2: Chỉ thiết bị ACCEPT mới được gửi file, theo SendMode đã chọn.
    //          Thiết bị REJECT/timeout -> báo lỗi toàn bộ file ngay, không gửi gì.
    fun requestSendFileToMultiple(
        context: Context,
        devices: List<TargetDevice>,
        filePaths: List<String>,
        senderName: String,
        mode: SendMode = SendMode.SEQUENTIAL,
        onEachFileDone: (device: TargetDevice, filePath: String, success: Boolean, errorMsg: String?) -> Unit = { _, _, _, _ -> },
        onEachDeviceDone: (device: TargetDevice, results: Map<String, Boolean>) -> Unit = { _, _ -> },
        onAllDone: (results: Map<TargetDevice, Map<String, Boolean>>) -> Unit = {},
    ) {
        Log.d(TAG, "requestSendFileToMultiple: devices=$devices, filePaths=$filePaths")

        CoroutineScope(Dispatchers.IO).launch {
            val totalFiles = filePaths.size
            val allResults = mutableMapOf<TargetDevice, Map<String, Boolean>>()

            // ===== PHASE 1: Gửi REQUEST tới TẤT CẢ thiết bị song song =====
            val handshakeResults = devices.map { device ->
                async {
                    val accepted = requestHandshake(device, senderName, totalFiles)
                    _sendRequestResult.tryEmit(SendRequestResult(device, accepted))
                    Log.d(TAG, "Request tới ${device.name}: accepted=$accepted")
                    device to accepted
                }
            }.awaitAll()

            val acceptedDevices = mutableListOf<TargetDevice>()

            // Thiết bị reject/timeout -> huỷ ngay, không gửi file
            handshakeResults.forEach { (device, accepted) ->
                if (!accepted) {
                    Log.d(TAG, "Thiết bị ${device.name} từ chối hoặc không phản hồi request")
                    val results = filePaths.associateWith { false }
                    allResults[device] = results
                    results.forEach { (fp, ok) ->
                        onEachFileDone(device, fp, ok, "Thiết bị từ chối hoặc không phản hồi")
                    }
                    onEachDeviceDone(device, results)
                } else {
                    acceptedDevices.add(device)
                }
            }

            // ===== PHASE 2: Gửi file cho các thiết bị đã ACCEPT =====
            when (mode) {
                SendMode.SEQUENTIAL -> {
                    for (device in acceptedDevices) {
                        val deviceResults =
                            _sendFilesToDevice(device, filePaths, senderName, onEachFileDone)
                        allResults[device] = deviceResults
                        onEachDeviceDone(device, deviceResults)
                        Log.d(TAG, "SEQUENTIAL: xong thiết bị ${device.name}")
                    }
                }

                SendMode.PARALLEL -> {
                    val jobs = acceptedDevices.map { device ->
                        async {
                            val deviceResults =
                                _sendFilesToDevice(device, filePaths, senderName, onEachFileDone)
                            onEachDeviceDone(device, deviceResults)
                            device to deviceResults
                        }
                    }
                    jobs.awaitAll().forEach { (device, results) ->
                        allResults[device] = results
                    }
                    Log.d(TAG, "PARALLEL: tất cả ${acceptedDevices.size} thiết bị đã xong")
                }
            }

            onAllDone(allResults)
        }
    }

    // Gửi lần lượt danh sách file cho 1 thiết bị (ĐÃ accept ở Phase 1, không handshake lại)
    private suspend fun _sendFilesToDevice(
        device: TargetDevice,
        filePaths: List<String>,
        senderName: String,
        onEachFileDone: (device: TargetDevice, filePath: String, success: Boolean, errorMsg: String?) -> Unit,
    ): Map<String, Boolean> {
        val results = mutableMapOf<String, Boolean>()
        val totalFiles = filePaths.size

        filePaths.forEachIndexed { index, filePath ->
            val transferId = Random().nextLong()
            val latch = CompletableDeferred<Boolean>()

            coroutineScope {
                launch {
                    _sendFileSingle(
                        device, filePath, senderName, transferId,
                        fileIndex = index, totalFiles = totalFiles
                    ) { ok, error ->
                        results[filePath] = ok
                        onEachFileDone(device, filePath, ok, error)
                        latch.complete(ok)
                    }
                }
            }

            latch.await() // ✅ Đợi file này gửi xong mới sang file tiếp theo (cùng thiết bị)
        }

        return results
    }

    // Gửi request "xin phép" tới thiết bị đích — trả về true nếu được chấp nhận
    private suspend fun requestHandshake(
        device: TargetDevice,
        senderName: String,
        totalFiles: Int
    ): Boolean {
        var socket: Socket? = null
        return try {
            socket = Socket()
            socket.tcpNoDelay = true
            withContext(Dispatchers.IO) {
                socket.connect(InetSocketAddress(device.ipAddress, device.port), 10000)
            }
            socket.soTimeout = (REQUEST_TIMEOUT_MS + 5000L).toInt()

            withContext(Dispatchers.IO) {
                val bos = BufferedOutputStream(socket.getOutputStream())
                val dos = DataOutputStream(bos)
                dos.writeInt(MSG_TYPE_REQUEST)

                val metaStr = "$senderName|$totalFiles"
                val metaBytes = metaStr.toByteArray(Charsets.UTF_8)
                dos.writeInt(metaBytes.size)
                dos.write(metaBytes)
                dos.flush()

                val dis = DataInputStream(socket.getInputStream())
                val response = dis.readInt()
                Log.d(TAG, "Handshake với ${device.name}: response=$response")
                response == RESPONSE_ACCEPT
            }
        } catch (e: Exception) {
            Log.e(TAG, "Handshake lỗi với ${device.name}", e)
            false
        } finally {
            try {
                socket?.close()
            } catch (e: Exception) {
            }
        }
    }

    // Core logic gửi 1 file — đọc trực tiếp từ filePath (đường dẫn tuyệt đối)
    private suspend fun _sendFileSingle(
        device: TargetDevice,
        filePath: String,
        senderName: String,
        transferId: Long,
        fileIndex: Int = 0,
        totalFiles: Int = 1,
        onDone: (success: Boolean, errorMsg: String?) -> Unit
    ) {
        var socket: Socket? = null
        var bos: BufferedOutputStream? = null
        var fis: FileInputStream? = null

        try {
            Log.d(
                TAG,
                "_sendFileSingle: device=$device, filePath=$filePath, index=$fileIndex/$totalFiles"
            )

            val file = File(filePath)
            if (!file.exists()) {
                throw IOException("File không tồn tại: $filePath")
            }

            val fileName = file.name
            val fileSize = file.length()

            if (fileName.isEmpty() || fileSize <= 0) {
                throw IOException("Không thể đọc thông tin file được chọn: fileName=$fileName, fileSize=$fileSize")
            }

            emitTransfer(
                TransferState(
                    id = transferId,
                    fileName = fileName,
                    totalBytes = fileSize,
                    bytesTransferred = 0L,
                    progress = 0,
                    speedMbps = 0.0,
                    isIncoming = false,
                    peerName = device.name,
                    status = "CONNECTING"
                )
            )

            socket = Socket()
            socket.tcpNoDelay = true
            socket.sendBufferSize = 1024 * 1024
            withContext(Dispatchers.IO) {
                socket.connect(InetSocketAddress(device.ipAddress, device.port), 10000)
            }

            // Track handle sau khi connect thành công
            activeTransfers[transferId] = TransferHandle(
                socket = socket,
                job = currentCoroutineContext()[Job]!!
            )

            emitTransfer(_transfers.value[transferId]!!.copy(status = "TRANSFERRING"))

            bos = BufferedOutputStream(withContext(Dispatchers.IO) {
                socket.getOutputStream()
            }, 1024 * 1024)
            val dos = DataOutputStream(bos)

            dos.writeInt(MSG_TYPE_FILE)
            // ✅ Kèm fileIndex|totalFiles để bên nhận biết tổng số file của batch
            val metaStr = "$fileName|$fileSize|$senderName|$fileIndex|$totalFiles"
            val metaBytes = metaStr.toByteArray(Charsets.UTF_8)
            dos.writeInt(metaBytes.size)
            dos.write(metaBytes)
            dos.flush()

            fis = FileInputStream(file)

            val buffer = ByteArray(BUFFER_SIZE)
            var bytesRead: Int
            var totalSent = 0L
            var lastUpdate = System.currentTimeMillis()
            var bytesSavedSinceLastUpdate = 0L

            while (currentCoroutineContext().isActive) {
                bytesRead = fis.read(buffer)
                if (bytesRead == -1) break

                bos.write(buffer, 0, bytesRead)
                totalSent += bytesRead
                bytesSavedSinceLastUpdate += bytesRead

                val now = System.currentTimeMillis()
                val delta = now - lastUpdate
                if (delta >= 500 || totalSent == fileSize) {
                    val progress = if (fileSize > 0) ((totalSent * 100) / fileSize).toInt() else 0
                    val speedMBs = if (delta > 0)
                        (bytesSavedSinceLastUpdate / 1024.0 / 1024.0) / (delta / 1000.0) else 0.0
                    _transfers.value[transferId]?.let {
                        emitTransfer(
                            it.copy(
                                bytesTransferred = totalSent,
                                progress = progress,
                                speedMbps = speedMBs
                            )
                        )
                    }
                    lastUpdate = now
                    bytesSavedSinceLastUpdate = 0
                }
            }

            bos.flush()

            if (totalSent >= fileSize) {
                _transfers.value[transferId]?.let {
                    emitTransfer(it.copy(status = "SUCCESS", progress = 100))
                }
                Log.d(TAG, "Đã gửi xong đến ${device.name}")
                onDone(true, null)
            } else {
                throw IOException("Hủy truyền file nửa chừng.")
            }

        } catch (e: Exception) {
            Log.e(TAG, "Lỗi gửi file đến ${device.name}", e)
            _transfers.value[transferId]?.let {
                emitTransfer(it.copy(status = "FAILED", error = e.localizedMessage))
            }
            onDone(false, e.localizedMessage)
        } finally {
            activeTransfers.remove(transferId)
            try {
                fis?.close()
            } catch (e: Exception) {
            }
            try {
                bos?.close()
            } catch (e: Exception) {
            }
            try {
                socket?.close()
            } catch (e: Exception) {
            }
            delay(1500)
            removeTransfer(transferId)
        }
    }

    // ==================== INCOMING TRANSFER ====================

    private suspend fun handleIncomingTransfer(
        context: Context,
        socket: Socket,
        dis: DataInputStream,
        transferId: Long,
        onNotificationRequested: (title: String, body: String) -> Unit
    ) {
        var bos: BufferedOutputStream? = null
        var senderName = "Thiết bị"
        var targetUri: Uri? = null

        try {
            socket.receiveBufferSize = 1024 * 1024

            val metaLength = dis.readInt()
            if (metaLength <= 0 || metaLength > 1024 * 1024) throw IOException("Kích thước metadata không hợp lệ")

            val metaBytes = ByteArray(metaLength)
            dis.readFully(metaBytes)
            val metaStr = String(metaBytes, Charsets.UTF_8)

            val parts = metaStr.split("|")
            if (parts.size < 3) throw IOException("Metadata không đúng định dạng")
            val fileName = parts[0]
            val fileSize = parts[1].toLongOrNull() ?: 0L
            senderName = parts[2]
            val fileIndex = parts.getOrNull(3)?.toIntOrNull() ?: 0
            val totalFiles = parts.getOrNull(4)?.toIntOrNull() ?: 1

            Log.d(
                TAG,
                "Nhận file: $fileName ($fileSize bytes) từ $senderName [${fileIndex + 1}/$totalFiles]"
            )
            onNotificationRequested("Nhận diện gửi file", "$senderName đang gửi: $fileName")

            val lowercaseName = fileName.lowercase(Locale.ROOT)
            val isImage = lowercaseName.run {
                endsWith(".jpg") || endsWith(".jpeg") || endsWith(".png") ||
                        endsWith(".gif") || endsWith(".webp") || endsWith(".bmp")
            }
            val isVideo = lowercaseName.run {
                endsWith(".mp4") || endsWith(".mkv") || endsWith(".mov") ||
                        endsWith(".3gp") || endsWith(".webm") || endsWith(".avi")
            }

            val (rawStream, fileUri) = createPublicFileAndGetStream(
                context, fileName, isImage, isVideo, fileSize
            )
            if (rawStream == null || fileUri == null) {
                throw IOException("Không thể chuẩn bị luồng dữ liệu đích")
            }
            targetUri = fileUri
            bos = BufferedOutputStream(rawStream, 1024 * 1024)

            emitTransfer(
                TransferState(
                    id = transferId,
                    fileName = fileName,
                    totalBytes = fileSize,
                    bytesTransferred = 0L,
                    progress = 0,
                    speedMbps = 0.0,
                    isIncoming = true,
                    peerName = senderName,
                    status = "TRANSFERRING"
                )
            )

            val buffer = ByteArray(BUFFER_SIZE)
            var bytesRead: Int
            var totalRead = 0L
            var lastUpdate = System.currentTimeMillis()
            var bytesSavedSinceLastUpdate = 0L

            while (totalRead < fileSize) {
                val toRead = minOf(buffer.size.toLong(), fileSize - totalRead).toInt()
                bytesRead = dis.read(buffer, 0, toRead)
                if (bytesRead == -1) break

                bos.write(buffer, 0, bytesRead)
                totalRead += bytesRead
                bytesSavedSinceLastUpdate += bytesRead

                val now = System.currentTimeMillis()
                val delta = now - lastUpdate
                if (delta >= 500 || totalRead == fileSize) {
                    val progress = if (fileSize > 0) ((totalRead * 100) / fileSize).toInt() else 0
                    val speedMBs = if (delta > 0)
                        (bytesSavedSinceLastUpdate / 1024.0 / 1024.0) / (delta / 1000.0) else 0.0
                    _transfers.value[transferId]?.let {
                        emitTransfer(
                            it.copy(
                                bytesTransferred = totalRead,
                                progress = progress,
                                speedMbps = speedMBs
                            )
                        )
                    }
                    lastUpdate = now
                    bytesSavedSinceLastUpdate = 0
                }
            }

            bos.flush()
            bos.close()
            bos = null

            if (totalRead >= fileSize) {
                completePendingFile(context, fileUri, fileSize)
                if (fileUri.scheme == "file") {
                    val fallbackFile = File(fileUri.path ?: "")
                    if (fallbackFile.exists()) saveMediaToGallery(context, fallbackFile)
                }
                _transfers.value[transferId]?.let {
                    emitTransfer(it.copy(status = "SUCCESS", progress = 100))
                }
                Log.d(TAG, "Nhận file thành công: $fileName")
                onNotificationRequested(
                    "Truyền file thành công",
                    "Đã nhận $fileName từ $senderName"
                )
            } else {
                throw IOException("Luồng tải file bị gián đoạn")
            }

        } catch (e: Exception) {
            Log.e(TAG, "Lỗi nhận file", e)
            _transfers.value[transferId]?.let {
                emitTransfer(it.copy(status = "FAILED", error = e.localizedMessage))
            }
            try {
                bos?.close()
            } catch (e: Exception) {
            }
            bos = null
            if (targetUri != null) deletePendingFile(context, targetUri)
            onNotificationRequested("Lỗi truyền tải", "Lỗi nhận file từ $senderName")
        } finally {
            activeTransfers.remove(transferId)
            try {
                bos?.close()
            } catch (e: Exception) {
            }
            try {
                dis.close()
            } catch (e: Exception) {
            }
            try {
                socket.close()
            } catch (e: Exception) {
            }
            delay(1500)
            removeTransfer(transferId)
        }
    }

    // ==================== FILE HELPERS ====================

    private fun getMimeType(fileName: String): String {
        return when (fileName.substringAfterLast('.', "").lowercase(Locale.ROOT)) {
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
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val contentValues = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                put(MediaStore.MediaColumns.SIZE, fileSize)
                put(MediaStore.MediaColumns.MIME_TYPE, getMimeType(fileName))
                put(
                    MediaStore.MediaColumns.RELATIVE_PATH, when {
                        isImage -> Environment.DIRECTORY_PICTURES + "/SuperTransfer"
                        isVideo -> Environment.DIRECTORY_MOVIES + "/SuperTransfer"
                        else -> Environment.DIRECTORY_DOWNLOADS + "/SuperTransfer"
                    }
                )
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val collectionUri = when {
                isImage -> MediaStore.Images.Media.EXTERNAL_CONTENT_URI
                isVideo -> MediaStore.Video.Media.EXTERNAL_CONTENT_URI
                else -> MediaStore.Downloads.EXTERNAL_CONTENT_URI
            }
            try {
                val uri = resolver.insert(collectionUri, contentValues)
                if (uri != null) return Pair(resolver.openOutputStream(uri), uri)
            } catch (e: Exception) {
                Log.e(TAG, "MediaStore insert failed, fallback", e)
            }
        }
        return try {
            val downloadsDir = context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
                ?: throw IOException("Thư mục lưu trữ không khả dụng")
            if (!downloadsDir.exists()) downloadsDir.mkdirs()
            val destFile = getUniqueFile(downloadsDir, fileName)
            Pair(FileOutputStream(destFile), Uri.fromFile(destFile))
        } catch (e: Exception) {
            Log.e(TAG, "Fallback cũng thất bại", e)
            Pair(null, null)
        }
    }

    private fun completePendingFile(context: Context, uri: Uri, fileSize: Long) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && uri.scheme == "content") {
            try {
                context.contentResolver.update(uri, ContentValues().apply {
                    put(MediaStore.MediaColumns.IS_PENDING, 0)
                    put(MediaStore.MediaColumns.SIZE, fileSize)
                }, null, null)
            } catch (e: Exception) {
                Log.e(TAG, "Lỗi IS_PENDING = 0", e)
            }
        }
        try {
            if (uri.scheme == "file") {
                MediaScannerConnection.scanFile(context, arrayOf(uri.path), null) { p, u ->
                    Log.d(TAG, "Scan xong: $p -> $u")
                }
            }
        } catch (e: Exception) {
        }
    }

    private fun deletePendingFile(context: Context, uri: Uri) {
        try {
            if (uri.scheme == "content") {
                context.contentResolver.delete(uri, null, null)
            } else if (uri.scheme == "file") {
                File(uri.path ?: "").takeIf { it.exists() }?.delete()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Lỗi xóa file tạm", e)
        }
    }

    private fun saveMediaToGallery(context: Context, file: File) {
        val lowercaseName = file.name.lowercase(Locale.ROOT)
        val isImage = lowercaseName.run {
            endsWith(".jpg") || endsWith(".jpeg") || endsWith(".png") ||
                    endsWith(".gif") || endsWith(".webp") || endsWith(".bmp")
        }
        val isVideo = lowercaseName.run {
            endsWith(".mp4") || endsWith(".mkv") || endsWith(".mov") ||
                    endsWith(".3gp") || endsWith(".webm") || endsWith(".avi")
        }

        if (!isImage && !isVideo) {
            MediaScannerConnection.scanFile(context, arrayOf(file.absolutePath), null) { p, u ->
                Log.d(TAG, "File scanned: $p -> $u")
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
                        put(
                            MediaStore.MediaColumns.RELATIVE_PATH,
                            Environment.DIRECTORY_PICTURES + "/SuperTransfer"
                        )
                        put(MediaStore.MediaColumns.IS_PENDING, 1)
                    }
                } else {
                    put(MediaStore.MediaColumns.MIME_TYPE, "video/*")
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        put(
                            MediaStore.MediaColumns.RELATIVE_PATH,
                            Environment.DIRECTORY_MOVIES + "/SuperTransfer"
                        )
                        put(MediaStore.MediaColumns.IS_PENDING, 1)
                    }
                }
            }
            val collectionUri = if (isImage) MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            else MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            val uri = resolver.insert(collectionUri, contentValues)
            if (uri != null) {
                resolver.openOutputStream(uri)?.use { out ->
                    FileInputStream(file).use { inp ->
                        val buffer = ByteArray(BUFFER_SIZE)
                        var read: Int
                        while (inp.read(buffer).also { read = it } != -1) out.write(buffer, 0, read)
                        out.flush()
                    }
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    resolver.update(uri, ContentValues().apply {
                        put(MediaStore.MediaColumns.IS_PENDING, 0)
                    }, null, null)
                }
                MediaScannerConnection.scanFile(context, arrayOf(file.absolutePath), null) { p, u ->
                    Log.d(TAG, "Gallery scan: $p -> $u")
                }
                Log.d(TAG, "Lưu gallery thành công: $uri")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Lưu gallery thất bại", e)
        }
    }

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