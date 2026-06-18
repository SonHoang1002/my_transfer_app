package com.example.mytransferapp.network

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import androidx.core.content.ContextCompat
import com.example.mytransferapp.model.ScanMode
import com.example.mytransferapp.model.SendMode
import com.example.mytransferapp.model.TargetDevice
import com.example.mytransferapp.model.TransferHandle
import com.example.mytransferapp.model.TransferState
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.*
import java.io.*
import java.net.*
import java.util.Locale
import java.util.Random
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

object TransferEngine {

    private const val TAG = "TransferEngine"

    // ── Network ports ─────────────────────────────────────────────────────────
    private const val UDP_DISCOVERY_PORT = 8889
    private const val TCP_TRANSFER_PORT  = 9999
    private const val BUFFER_SIZE        = 512 * 1024 // 512 KB

    // ── Bluetooth RFCOMM UUID (cố định — 2 đầu phải giống nhau) ──────────────
    private val BT_SERVICE_UUID: UUID =
        UUID.fromString("fa87c0d0-afac-11de-8a39-0800200c9a66")
    private const val BT_SERVICE_NAME = "SuperTransfer"

    // ── Handshake protocol (TCP) ──────────────────────────────────────────────
    // Message type byte (đọc đầu tiên sau khi connect)
    private const val MSG_TYPE_REQUEST = 0   // Xin phép gửi N file
    private const val MSG_TYPE_FILE    = 1   // Dữ liệu file thực sự

    // Response codes (bên nhận → bên gửi)
    private const val RESPONSE_ACCEPT = 0    // Chấp nhận
    private const val RESPONSE_REJECT = 1    // Từ chối (người dùng bấm từ chối)
    private const val RESPONSE_BUSY   = 2    // Đang bận nhận file từ thiết bị khác

    private const val REQUEST_TIMEOUT_MS = 60_000L  // 60 s chờ người dùng accept

    // =========================================================================
    // STATE FLOWS
    // =========================================================================

    // Danh sách thiết bị đã phát hiện (WiFi UDP + BT scan đều đẩy vào đây)
    private val _discoveredDevices = MutableStateFlow<List<TargetDevice>>(emptyList())
    val discoveredDevices: StateFlow<List<TargetDevice>> = _discoveredDevices.asStateFlow()

    // Map<transferId, TransferState> — nhiều transfer chạy song song
    private val _transfers = MutableStateFlow<Map<Long, TransferState>>(emptyMap())
    val transfers: StateFlow<Map<Long, TransferState>> = _transfers.asStateFlow()

    // Backward-compat: lấy transfer đầu tiên
    val activeTransfer: StateFlow<TransferState?> = _transfers
        .map { it.values.firstOrNull() }
        .stateIn(CoroutineScope(Dispatchers.IO), SharingStarted.Eagerly, null)

    private val _isWifiScanning      = MutableStateFlow(false)
    val isWifiScanning: StateFlow<Boolean> = _isWifiScanning.asStateFlow()

    private val _isBluetoothScanning = MutableStateFlow(false)
    val isBluetoothScanning: StateFlow<Boolean> = _isBluetoothScanning.asStateFlow()

    private val _isReceiving   = MutableStateFlow(false)
    val isReceiving: StateFlow<Boolean> = _isReceiving.asStateFlow()

    private val _isAdvertising = MutableStateFlow(false)
    val isAdvertising: StateFlow<Boolean> = _isAdvertising.asStateFlow()

    // Sự kiện: có thiết bị gửi REQUEST đến — Flutter hiển thị dialog accept/reject
    private val _incomingConnectionRequest = MutableSharedFlow<TargetDevice>(
        replay = 0,
        extraBufferCapacity = 8,
        onBufferOverflow = BufferOverflow.DROP_OLDEST
    )
    val incomingConnectionRequest: SharedFlow<TargetDevice> =
        _incomingConnectionRequest.asSharedFlow()

    // Kết quả handshake phía gửi: thiết bị đích đã ACCEPT / REJECT / BUSY
    data class SendRequestResult(
        val device: TargetDevice,
        val accepted: Boolean,
        val isBusy: Boolean = false,   // true khi thiết bị đích đang bận
    )

    private val _sendRequestResult = MutableSharedFlow<SendRequestResult>(
        replay = 0,
        extraBufferCapacity = 16,
        onBufferOverflow = BufferOverflow.DROP_OLDEST
    )
    val sendRequestResult: SharedFlow<SendRequestResult> = _sendRequestResult.asSharedFlow()

    // =========================================================================
    // INTERNAL STATE
    // =========================================================================

    // deviceMap: key = ipAddress (WiFi) hoặc MAC address (BT)
    private val deviceMap       = ConcurrentHashMap<String, TargetDevice>()
    private val activeTransfers = ConcurrentHashMap<Long, TransferHandle>()

    // Số lượng file đang được nhận tại thời điểm hiện tại (để báo BUSY)
    private val activeReceiveCount = AtomicInteger(0)

    // Pending requests: requestId → deferred accept/reject của người dùng
    private data class PendingRequest(val deferred: CompletableDeferred<Boolean>)
    private val pendingRequests = ConcurrentHashMap<Long, PendingRequest>()

    private var udpScanJob:      Job? = null
    private var udpAdvertiseJob: Job? = null
    private var tcpServerJob:    Job? = null
    private var btServerJob:     Job? = null
    private var serverSocket:    ServerSocket? = null
    private var btServerSocket:  BluetoothServerSocket? = null

    // =========================================================================
    // EMIT HELPERS
    // =========================================================================

    private fun emitTransfer(state: TransferState) {
        _transfers.update { it.toMutableMap().also { m -> m[state.id] = state } }
    }

    private fun removeTransfer(id: Long) {
        _transfers.update { it.toMutableMap().also { m -> m.remove(id) } }
    }

    // =========================================================================
    // PUBLIC API — GENERAL
    // =========================================================================

    fun setBluetoothScanning(isScanning: Boolean) {
        _isBluetoothScanning.value = isScanning
    }

    /** Thêm thiết bị Bluetooth vào danh sách phát hiện (gọi từ BroadcastReceiver). */
    fun addBluetoothDevice(device: TargetDevice) {
        // Key theo MAC để deduplicate
        val key = device.address ?: device.ipAddress
        deviceMap[key] = device
        _discoveredDevices.value = deviceMap.values.toList()
        Log.d(TAG, "BT device added: $device")
    }

    fun cancelActiveTransfer(transferId: Long? = null) {
        if (transferId == null) {
            Log.d(TAG, "Huỷ tất cả transfer đang hoạt động")
            activeTransfers.forEach { (id, handle) ->
                _transfers.value[id]?.let { s ->
                    emitTransfer(s.copy(status = "FAILED", error = "Bị huỷ bởi người dùng"))
                }
                runCatching { handle.socket?.close() }
                runCatching { handle.btSocket?.close() }
                handle.job.cancel()
            }
            activeTransfers.clear()
        } else {
            Log.d(TAG, "Huỷ transfer id=$transferId")
            activeTransfers[transferId]?.let { handle ->
                _transfers.value[transferId]?.let { s ->
                    emitTransfer(s.copy(status = "FAILED", error = "Bị huỷ bởi người dùng"))
                }
                runCatching { handle.socket?.close() }
                runCatching { handle.btSocket?.close() }
                handle.job.cancel()
                activeTransfers.remove(transferId)
            }
        }
    }

    fun getDeviceName(): String {
        val manufacturer = Build.MANUFACTURER
        val model        = Build.MODEL
        return if (model.startsWith(manufacturer, ignoreCase = true))
            model.replaceFirstChar { it.uppercase() }
        else
            "${manufacturer.replaceFirstChar { it.uppercase() }} $model"
    }

    fun getLocalIpAddress(): String {
        try {
            NetworkInterface.getNetworkInterfaces()?.let { ifaces ->
                while (ifaces.hasMoreElements()) {
                    val addrs = ifaces.nextElement().inetAddresses
                    while (addrs.hasMoreElements()) {
                        val addr = addrs.nextElement()
                        if (!addr.isLoopbackAddress && addr is Inet4Address)
                            return addr.hostAddress ?: "127.0.0.1"
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Lỗi lấy IP nội bộ", e)
        }
        return "127.0.0.1"
    }

    // =========================================================================
    // ACCEPT / REJECT INCOMING REQUEST (gọi từ MethodChannel)
    // =========================================================================

    fun acceptRequest(requestId: Long) {
        Log.d(TAG, "acceptRequest id=$requestId")
        pendingRequests[requestId]?.deferred?.complete(true)
            ?: Log.w(TAG, "acceptRequest: requestId=$requestId không tìm thấy (đã timeout?)")
    }

    fun cancelRequest(requestId: Long) {
        Log.d(TAG, "cancelRequest id=$requestId")
        pendingRequests[requestId]?.deferred?.complete(false)
            ?: Log.w(TAG, "cancelRequest: requestId=$requestId không tìm thấy (đã timeout?)")
    }

    // =========================================================================
    // UDP DISCOVERY (WiFi)
    // =========================================================================

    fun startAdvertising(deviceName: String) {
        udpAdvertiseJob?.cancel()
        _isAdvertising.value = true
        udpAdvertiseJob = CoroutineScope(Dispatchers.IO).launch {
            var socket: DatagramSocket? = null
            try {
                socket = DatagramSocket(UDP_DISCOVERY_PORT).apply { reuseAddress = true }
                Log.d(TAG, "UDP advertise trên cổng $UDP_DISCOVERY_PORT")
                val buffer = ByteArray(1024)
                while (isActive) {
                    val packet = DatagramPacket(buffer, buffer.size)
                    try {
                        socket.receive(packet)
                        val message = String(packet.data, 0, packet.length).trim()
                        if (message.startsWith("SUPERTRANSFER_PING:")) {
                            val reply = "SUPERTRANSFER_PONG:$deviceName:$TCP_TRANSFER_PORT"
                                .toByteArray()
                            socket.send(
                                DatagramPacket(reply, reply.size, packet.address, packet.port)
                            )
                        }
                    } catch (_: SocketException) { break }
                    catch (e: Exception) { Log.e(TAG, "UDP advertise loop error", e) }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Không thể khởi động UDP advertise", e)
            } finally {
                socket?.close()
            }
        }.also { it.invokeOnCompletion { _isAdvertising.value = false } }
    }

    fun stopAdvertising() {
        udpAdvertiseJob?.cancel()
        udpAdvertiseJob = null
        _isAdvertising.value = false
    }

    fun startWifiScanning(deviceName: String, timeoutMs: Int) {
        // Chỉ xoá device WiFi, giữ lại device Bluetooth đã scan
        deviceMap.entries.removeIf { it.value.from == ScanMode.WIFI }
        _discoveredDevices.value = deviceMap.values.toList()
        _isWifiScanning.value = true
        udpScanJob?.cancel()
        udpScanJob = CoroutineScope(Dispatchers.IO).launch {
            var socket: DatagramSocket? = null
            try {
                socket = DatagramSocket().apply {
                    broadcast        = true
                    soTimeout        = 1500
                    sendBufferSize   = 4  * 1024
                    receiveBufferSize = 8 * 1024
                    reuseAddress     = true
                }
                val deadline = System.currentTimeMillis() + timeoutMs

                val receiveJob = launch {
                    val buf = ByteArray(1024)
                    while (isActive && System.currentTimeMillis() < deadline) {
                        val pkt = DatagramPacket(buf, buf.size)
                        try {
                            socket.receive(pkt)
                            val msg = String(pkt.data, 0, pkt.length).trim()
                            if (msg.startsWith("SUPERTRANSFER_PONG:")) {
                                val parts    = msg.split(":")
                                val peerName = parts.getOrNull(1) ?: "Thiết bị"
                                val peerPort = parts.getOrNull(2)?.toIntOrNull() ?: TCP_TRANSFER_PORT
                                val peerIp   = pkt.address.hostAddress ?: ""
                                if (peerIp.isNotEmpty()) {
                                    deviceMap[peerIp] = TargetDevice(peerIp, peerName, peerPort, ScanMode.WIFI)
                                    _discoveredDevices.value = deviceMap.values.toList()
                                    Log.d(TAG, "WiFi found: $peerName ($peerIp:$peerPort)")
                                }
                            }
                        } catch (_: SocketTimeoutException) {}
                        catch (_: SocketException)      { break }
                        catch (e: Exception)            { Log.e(TAG, "UDP recv error", e) }
                    }
                }

                val pingJob = launch {
                    while (isActive && System.currentTimeMillis() < deadline) {
                        val ping = "SUPERTRANSFER_PING:$deviceName".toByteArray()
                        buildList {
                            add(InetAddress.getByName("255.255.255.255"))
                            getLocalSubnetBroadcast()?.let { add(it) }
                        }.forEach { addr ->
                            if (!socket.isClosed)
                                socket.send(DatagramPacket(ping, ping.size, addr, UDP_DISCOVERY_PORT))
                        }
                        // Dọn thiết bị WiFi cũ quá 6 s
                        val now = System.currentTimeMillis()
                        val before = deviceMap.size
                        deviceMap.entries.removeIf { e ->
                            e.value.from == ScanMode.WIFI && now - e.value.lastSeen > 6_000
                        }
                        if (deviceMap.size != before) _discoveredDevices.value = deviceMap.values.toList()
                        delay(2_000)
                    }
                }

                launch {
                    delay(timeoutMs.toLong())
                    socket?.close()
                    pingJob.cancel()
                    receiveJob.cancel()
                }

                pingJob.join()
                receiveJob.join()
            } catch (e: Exception) {
                Log.e(TAG, "UDP scan error", e)
            } finally {
                runCatching { socket?.close() }
                _isWifiScanning.value = false
            }
        }.also { it.invokeOnCompletion { _isWifiScanning.value = false } }
    }

    fun stopWifiScanning() {
        udpScanJob?.cancel()
        udpScanJob = null
        _isWifiScanning.value = false
        // Chỉ xoá WiFi device, giữ BT
        deviceMap.entries.removeIf { it.value.from == ScanMode.WIFI }
        _discoveredDevices.value = deviceMap.values.toList()
    }

    private fun getLocalSubnetBroadcast(): InetAddress? = try {
        NetworkInterface.getNetworkInterfaces()?.let { ifaces ->
            while (ifaces.hasMoreElements()) {
                val iface = ifaces.nextElement()
                if (iface.isLoopback || !iface.isUp) continue
                for (addr in iface.interfaceAddresses) {
                    val ia = addr.address
                    if (ia !is Inet4Address || ia.isLoopbackAddress) continue
                    val prefix    = addr.networkPrefixLength.toInt()
                    val ip        = ia.address
                    val mask      = (-1 shl (32 - prefix))
                    val broadcast = ByteArray(4) { i ->
                        (ip[i].toInt() and (mask shr (24 - i * 8)) or
                                (0xFF and (mask shr (24 - i * 8)).inv())).toByte()
                    }
                    return InetAddress.getByAddress(broadcast)
                }
            }
        }
        null
    } catch (_: Exception) { null }

    // =========================================================================
    // BLUETOOTH SCAN (gọi từ MainActivity BroadcastReceiver)
    // =========================================================================

    /**
     * Xoá danh sách thiết bị Bluetooth và reset trạng thái scan.
     * Gọi trước khi bắt đầu một lượt scan BT mới.
     */
    fun clearBluetoothDevices() {
        deviceMap.entries.removeIf { it.value.from == ScanMode.BLUETOOTH }
        _discoveredDevices.value = deviceMap.values.toList()
    }

    // =========================================================================
    // TCP SERVER (nhận file qua WiFi)
    // =========================================================================

    fun startTcpServer(
        context: Context,
        onNotificationRequested: (title: String, body: String) -> Unit,
    ) {
        tcpServerJob?.cancel()
        runCatching { serverSocket?.close() }
        _isReceiving.value = true

        tcpServerJob = CoroutineScope(Dispatchers.IO).launch {
            try {
                serverSocket = ServerSocket(TCP_TRANSFER_PORT).apply { reuseAddress = true }
                Log.d(TAG, "TCP server lắng nghe trên cổng $TCP_TRANSFER_PORT")

                while (isActive) {
                    val client = try { serverSocket?.accept() }
                    catch (_: Exception) { null } ?: break

                    Log.d(TAG, "TCP kết nối từ: ${client.inetAddress.hostAddress}:${client.port}")
                    launch { handleIncomingTcpConnection(context, client, onNotificationRequested) }
                }
            } catch (e: Exception) {
                Log.e(TAG, "TCP server lỗi", e)
            } finally {
                _isReceiving.value = false
            }
        }
    }

    fun stopTcpServer() {
        tcpServerJob?.cancel()
        tcpServerJob = null
        _isReceiving.value = false
        runCatching { serverSocket?.close() }
        serverSocket = null
    }

    /**
     * Phân loại connection ngay sau khi accept:
     * - MSG_TYPE_REQUEST (0): Handshake xin phép → handleIncomingRequest
     * - MSG_TYPE_FILE    (1): Dữ liệu file thực  → handleIncomingTransfer
     */
    private suspend fun handleIncomingTcpConnection(
        context: Context,
        socket: Socket,
        onNotificationRequested: (title: String, body: String) -> Unit,
    ) {
        try {
            socket.tcpNoDelay = true
            val dis     = DataInputStream(BufferedInputStream(socket.getInputStream(), 1024 * 1024))
            val msgType = dis.readInt()
            when (msgType) {
                MSG_TYPE_REQUEST -> handleIncomingRequest(socket, dis, onNotificationRequested)
                MSG_TYPE_FILE -> {
                    val transferId  = Random().nextLong()
                    val incomingJob = currentCoroutineContext()[Job]!!
                    activeTransfers[transferId] = TransferHandle(socket = socket, job = incomingJob)
                    handleIncomingTransfer(context, dis, transferId, onNotificationRequested,
                        onClose = { runCatching { socket.close() } })
                }
                else -> {
                    Log.e(TAG, "Unknown msgType=$msgType")
                    runCatching { socket.close() }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "handleIncomingTcpConnection lỗi", e)
            runCatching { socket.close() }
        }
    }

    // =========================================================================
    // BLUETOOTH RFCOMM SERVER (nhận file qua BT)
    // =========================================================================

    /**
     * Khởi động RFCOMM server để nhận kết nối Bluetooth.
     * Gọi song song với startTcpServer trong TransferService.
     *
     * Yêu cầu quyền BLUETOOTH_CONNECT (Android 12+).
     */
    fun startBluetoothServer(
        context: Context,
        onNotificationRequested: (title: String, body: String) -> Unit,
    ) {
        // Kiểm tra quyền BLUETOOTH_CONNECT trên Android 12+
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val granted = ContextCompat.checkSelfPermission(
                context, Manifest.permission.BLUETOOTH_CONNECT
            ) == PackageManager.PERMISSION_GRANTED
            if (!granted) {
                Log.w(TAG, "startBluetoothServer: thiếu BLUETOOTH_CONNECT permission")
                return
            }
        }

        val adapter = BluetoothAdapter.getDefaultAdapter()
        if (adapter == null || !adapter.isEnabled) {
            Log.w(TAG, "startBluetoothServer: Bluetooth không khả dụng hoặc chưa bật")
            return
        }

        btServerJob?.cancel()
        btServerJob = CoroutineScope(Dispatchers.IO).launch {
            try {
                @Suppress("MissingPermission")
                btServerSocket = adapter.listenUsingRfcommWithServiceRecord(
                    BT_SERVICE_NAME, BT_SERVICE_UUID
                )
                Log.d(TAG, "BT RFCOMM server đang lắng nghe — UUID=$BT_SERVICE_UUID")

                while (isActive) {
                    val btSocket = try { btServerSocket?.accept() }
                    catch (_: Exception) { null } ?: break

                    Log.d(TAG, "BT kết nối từ: ${btSocket.remoteDevice.address}")
                    launch { handleIncomingBtConnection(context, btSocket, onNotificationRequested) }
                }
            } catch (e: Exception) {
                Log.e(TAG, "BT RFCOMM server lỗi", e)
            }
        }
    }

    fun stopBluetoothServer() {
        btServerJob?.cancel()
        btServerJob = null
        runCatching { btServerSocket?.close() }
        btServerSocket = null
    }

    /**
     * Nhận file qua BluetoothSocket — cùng protocol với TCP
     * (đọc msgType → MSG_TYPE_FILE → handleIncomingTransfer).
     */
    private suspend fun handleIncomingBtConnection(
        context: Context,
        btSocket: BluetoothSocket,
        onNotificationRequested: (title: String, body: String) -> Unit,
    ) {
        try {
            val dis     = DataInputStream(BufferedInputStream(btSocket.inputStream, BUFFER_SIZE))
            val msgType = dis.readInt()
            if (msgType != MSG_TYPE_FILE) {
                Log.e(TAG, "BT: msgType không phải FILE ($msgType), bỏ qua")
                runCatching { btSocket.close() }
                return
            }
            val transferId  = Random().nextLong()
            val incomingJob = currentCoroutineContext()[Job]!!
            activeTransfers[transferId] = TransferHandle(btSocket = btSocket, job = incomingJob)
            handleIncomingTransfer(
                context, dis, transferId, onNotificationRequested,
                onClose = { runCatching { btSocket.close() } }
            )
        } catch (e: Exception) {
            Log.e(TAG, "handleIncomingBtConnection lỗi", e)
            runCatching { btSocket.close() }
        }
    }

    // =========================================================================
    // HANDSHAKE — bên nhận (TCP only — BT không cần handshake)
    // =========================================================================

    /**
     * Bên nhận xử lý REQUEST:
     * 1. Kiểm tra đang bận → phản hồi BUSY ngay (không cần hỏi người dùng).
     * 2. Emit incomingConnectionRequest để Flutter hiển thị dialog.
     * 3. Chờ người dùng accept/reject trong [REQUEST_TIMEOUT_MS].
     * 4. Phản hồi ACCEPT hoặc REJECT.
     */
    private suspend fun handleIncomingRequest(
        socket: Socket,
        dis: DataInputStream,
        onNotificationRequested: (title: String, body: String) -> Unit,
    ) {
        val requestId = Random().nextLong()
        var accepted  = false

        try {
            val metaLen = dis.readInt()
            if (metaLen <= 0 || metaLen > 1024 * 1024)
                throw IOException("Metadata size không hợp lệ: $metaLen")

            val metaBytes = ByteArray(metaLen)
            dis.readFully(metaBytes)
            val meta       = String(metaBytes, Charsets.UTF_8).split("|")
            val senderName = meta.getOrNull(0) ?: "Thiết bị"
            val totalFiles = meta.getOrNull(1)?.toIntOrNull() ?: 1
            val senderIp   = socket.inetAddress.hostAddress ?: ""
            val senderPort = socket.port

            Log.d(TAG, "REQUEST id=$requestId từ $senderName ($senderIp), totalFiles=$totalFiles")

            // ── Kiểm tra bận ────────────────────────────────────────────────
            val isBusy = activeReceiveCount.get() > 0
            if (isBusy) {
                Log.d(TAG, "Đang bận (activeReceive=${activeReceiveCount.get()}) — gửi BUSY về $senderName")
                // Vẫn emit để Flutter có thể hiển thị thông báo "Thiết bị đang bận"
                _incomingConnectionRequest.tryEmit(
                    TargetDevice(
                        name       = senderName,
                        ipAddress  = senderIp,
                        port       = senderPort,
                        from       = ScanMode.WIFI,
                        totalFiles = totalFiles,
                        requestId  = requestId,
                        isBusy     = true,
                    )
                )
                sendHandshakeResponse(socket, RESPONSE_BUSY)
                return
            }

            // ── Chờ người dùng accept/reject ─────────────────────────────────
            val deferred = CompletableDeferred<Boolean>()
            pendingRequests[requestId] = PendingRequest(deferred)

            _incomingConnectionRequest.tryEmit(
                TargetDevice(
                    name       = senderName,
                    ipAddress  = senderIp,
                    port       = senderPort,
                    from       = ScanMode.WIFI,
                    totalFiles = totalFiles,
                    requestId  = requestId,
                    isBusy     = false,
                )
            )
            onNotificationRequested("Yêu cầu nhận file", "$senderName muốn gửi $totalFiles file")

            accepted = try {
                withTimeout(REQUEST_TIMEOUT_MS) { deferred.await() }
            } catch (_: TimeoutCancellationException) {
                Log.d(TAG, "Request id=$requestId timeout — auto reject")
                false
            }
        } catch (e: Exception) {
            Log.e(TAG, "handleIncomingRequest lỗi (id=$requestId)", e)
            accepted = false
        } finally {
            pendingRequests.remove(requestId)
            sendHandshakeResponse(socket, if (accepted) RESPONSE_ACCEPT else RESPONSE_REJECT)
            runCatching { socket.close() }
        }
    }

    private fun sendHandshakeResponse(socket: Socket, responseCode: Int) {
        try {
            val dos = DataOutputStream(BufferedOutputStream(socket.getOutputStream()))
            dos.writeInt(responseCode)
            dos.flush()
        } catch (e: Exception) {
            Log.e(TAG, "sendHandshakeResponse lỗi (code=$responseCode)", e)
        }
    }

    // =========================================================================
    // SEND — PUBLIC ENTRY POINT
    // =========================================================================

    /**
     * Gửi nhiều file đến nhiều thiết bị.
     *
     * Tự động chọn kênh truyền:
     * - [ScanMode.WIFI]      → TCP handshake + TCP file transfer
     * - [ScanMode.BLUETOOTH] → BT RFCOMM file transfer (không handshake — chỉ gửi thẳng)
     *
     * PHASE 1 (chỉ WiFi): Gửi REQUEST song song tới tất cả thiết bị WiFi.
     *   → Thiết bị BUSY   : báo lỗi ngay, không gửi file.
     *   → Thiết bị REJECT : báo lỗi ngay, không gửi file.
     *   → Thiết bị ACCEPT : đưa vào danh sách gửi.
     *
     * PHASE 2: Gửi file theo [SendMode]:
     *   - SEQUENTIAL: lần lượt từng thiết bị.
     *   - PARALLEL  : tất cả thiết bị cùng lúc.
     */
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
        Log.d(TAG, "requestSendFileToMultiple: ${devices.size} devices, ${filePaths.size} files, mode=$mode")

        CoroutineScope(Dispatchers.IO).launch {
            val allResults       = mutableMapOf<TargetDevice, Map<String, Boolean>>()
            val wifiDevices      = devices.filter { it.from == ScanMode.WIFI }
            val btDevices        = devices.filter { it.from == ScanMode.BLUETOOTH }
            val readyToSend      = mutableListOf<TargetDevice>()

            // ── PHASE 1: Handshake song song với các thiết bị WiFi ────────────
            val handshakeResults = wifiDevices.map { device ->
                async {
                    val (accepted, isBusy) = wifiHandshake(device, senderName, filePaths.size)
                    _sendRequestResult.tryEmit(
                        SendRequestResult(device, accepted, isBusy)
                    )
                    Triple(device, accepted, isBusy)
                }
            }.awaitAll()

            handshakeResults.forEach { (device, accepted, isBusy) ->
                if (!accepted) {
                    val reason = if (isBusy) "Thiết bị đang bận nhận file từ người khác"
                    else        "Thiết bị từ chối yêu cầu"
                    Log.d(TAG, "${device.name}: $reason")
                    val results = filePaths.associateWith { false }
                    allResults[device] = results
                    results.forEach { (fp, _) -> onEachFileDone(device, fp, false, reason) }
                    onEachDeviceDone(device, results)
                } else {
                    readyToSend.add(device)
                }
            }

            // Thiết bị BT không cần handshake — thêm thẳng vào danh sách gửi
            readyToSend.addAll(btDevices)

            // ── PHASE 2: Gửi file ─────────────────────────────────────────────
            when (mode) {
                SendMode.SEQUENTIAL -> {
                    for (device in readyToSend) {
                        val results = sendFilesToDevice(
                            context, device, filePaths, senderName, onEachFileDone
                        )
                        allResults[device] = results
                        onEachDeviceDone(device, results)
                    }
                }
                SendMode.PARALLEL -> {
                    readyToSend.map { device ->
                        async {
                            val results = sendFilesToDevice(
                                context, device, filePaths, senderName, onEachFileDone
                            )
                            onEachDeviceDone(device, results)
                            device to results
                        }
                    }.awaitAll().forEach { (d, r) -> allResults[d] = r }
                }
            }

            onAllDone(allResults)
        }
    }

    // =========================================================================
    // SEND — HELPERS (PRIVATE)
    // =========================================================================

    /**
     * Gửi handshake REQUEST đến thiết bị WiFi.
     * Trả về Pair(accepted, isBusy).
     */
    private suspend fun wifiHandshake(
        device: TargetDevice,
        senderName: String,
        totalFiles: Int,
    ): Pair<Boolean, Boolean> {
        var socket: Socket? = null
        return try {
            socket = Socket().apply { tcpNoDelay = true }
            withContext(Dispatchers.IO) {
                socket.connect(InetSocketAddress(device.ipAddress, device.port), 10_000)
            }
            socket.soTimeout = (REQUEST_TIMEOUT_MS + 5_000L).toInt()

            withContext(Dispatchers.IO) {
                val dos = DataOutputStream(BufferedOutputStream(socket.getOutputStream()))
                dos.writeInt(MSG_TYPE_REQUEST)
                val meta = "$senderName|$totalFiles".toByteArray(Charsets.UTF_8)
                dos.writeInt(meta.size)
                dos.write(meta)
                dos.flush()

                val dis      = DataInputStream(socket.getInputStream())
                val response = dis.readInt()
                Log.d(TAG, "Handshake ${device.name}: response=$response")
                when (response) {
                    RESPONSE_ACCEPT -> Pair(true,  false)
                    RESPONSE_BUSY   -> Pair(false, true)
                    else            -> Pair(false, false) // REJECT hoặc unknown
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "wifiHandshake lỗi với ${device.name}", e)
            Pair(false, false)
        } finally {
            runCatching { socket?.close() }
        }
    }

    /** Gửi lần lượt danh sách file đến 1 thiết bị (WiFi hoặc BT). */
    private suspend fun sendFilesToDevice(
        context: Context,
        device: TargetDevice,
        filePaths: List<String>,
        senderName: String,
        onEachFileDone: (TargetDevice, String, Boolean, String?) -> Unit,
    ): Map<String, Boolean> {
        val results    = mutableMapOf<String, Boolean>()
        val totalFiles = filePaths.size

        filePaths.forEachIndexed { index, filePath ->
            val transferId = Random().nextLong()
            val latch      = CompletableDeferred<Boolean>()

            coroutineScope {
                launch {
                    when (device.from) {
                        ScanMode.WIFI ->
                            sendFileSingleTcp(
                                device, filePath, senderName, transferId, index, totalFiles
                            ) { ok, err ->
                                results[filePath] = ok
                                onEachFileDone(device, filePath, ok, err)
                                latch.complete(ok)
                            }

                        ScanMode.BLUETOOTH ->
                            sendFileSingleBluetooth(
                                context, device, filePath, senderName, transferId, index, totalFiles
                            ) { ok, err ->
                                results[filePath] = ok
                                onEachFileDone(device, filePath, ok, err)
                                latch.complete(ok)
                            }
                    }
                }
            }
            latch.await()
        }
        return results
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SEND via TCP (WiFi)
    // ─────────────────────────────────────────────────────────────────────────

    private suspend fun sendFileSingleTcp(
        device: TargetDevice,
        filePath: String,
        senderName: String,
        transferId: Long,
        fileIndex: Int,
        totalFiles: Int,
        onDone: (Boolean, String?) -> Unit,
    ) {
        var socket: Socket?            = null
        var bos: BufferedOutputStream? = null
        var fis: FileInputStream?      = null

        try {
            val file = File(filePath)
            if (!file.exists()) throw IOException("File không tồn tại: $filePath")
            val fileName = file.name
            val fileSize = file.length()

            emitTransfer(
                TransferState(id = transferId, fileName = fileName, totalBytes = fileSize,
                    isIncoming = false, peerName = device.name, status = "CONNECTING")
            )

            socket = Socket().apply {
                tcpNoDelay    = true
                sendBufferSize = 1024 * 1024
            }
            withContext(Dispatchers.IO) {
                socket.connect(InetSocketAddress(device.ipAddress, device.port), 10_000)
            }
            activeTransfers[transferId] = TransferHandle(
                socket = socket, job = currentCoroutineContext()[Job]!!
            )
            emitTransfer(_transfers.value[transferId]!!.copy(status = "TRANSFERRING"))

            bos = BufferedOutputStream(socket.getOutputStream(), 1024 * 1024)
            val dos = DataOutputStream(bos)
            dos.writeInt(MSG_TYPE_FILE)
            val meta = "$fileName|$fileSize|$senderName|$fileIndex|$totalFiles"
                .toByteArray(Charsets.UTF_8)
            dos.writeInt(meta.size)
            dos.write(meta)
            dos.flush()

            fis = FileInputStream(file)
            streamFileData(fis, bos, transferId, fileSize, device.name)
            bos.flush()

            _transfers.value[transferId]?.let {
                emitTransfer(it.copy(status = "SUCCESS", progress = 100))
            }
            Log.d(TAG, "TCP: đã gửi xong $fileName đến ${device.name}")
            onDone(true, null)
        } catch (e: Exception) {
            Log.e(TAG, "sendFileSingleTcp lỗi → ${device.name}", e)
            _transfers.value[transferId]?.let {
                emitTransfer(it.copy(status = "FAILED", error = e.localizedMessage))
            }
            onDone(false, e.localizedMessage)
        } finally {
            activeTransfers.remove(transferId)
            runCatching { fis?.close() }
            runCatching { bos?.close() }
            runCatching { socket?.close() }
            delay(1_500)
            removeTransfer(transferId)
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SEND via Bluetooth RFCOMM
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Kết nối tới thiết bị Bluetooth qua RFCOMM và gửi file.
     *
     * Protocol giống hệt TCP nhưng qua BluetoothSocket:
     *   writeInt(MSG_TYPE_FILE)
     *   writeInt(metaLength) + meta bytes
     *   raw file bytes
     *
     * Lưu ý: [device.address] phải là MAC address hợp lệ (XX:XX:XX:XX:XX:XX).
     * Yêu cầu quyền BLUETOOTH_CONNECT (Android 12+).
     */
    private suspend fun sendFileSingleBluetooth(
        context: Context,
        device: TargetDevice,
        filePath: String,
        senderName: String,
        transferId: Long,
        fileIndex: Int,
        totalFiles: Int,
        onDone: (Boolean, String?) -> Unit,
    ) {
        // Kiểm tra quyền
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val ok = ContextCompat.checkSelfPermission(
                context, Manifest.permission.BLUETOOTH_CONNECT
            ) == PackageManager.PERMISSION_GRANTED
            if (!ok) {
                onDone(false, "Thiếu quyền BLUETOOTH_CONNECT")
                return
            }
        }

        val btAdapter = BluetoothAdapter.getDefaultAdapter()
        if (btAdapter == null || !btAdapter.isEnabled) {
            onDone(false, "Bluetooth không khả dụng hoặc chưa bật")
            return
        }

        val macAddress = device.address
        if (macAddress.isNullOrBlank()) {
            onDone(false, "Địa chỉ MAC Bluetooth không hợp lệ")
            return
        }

        var btSocket: BluetoothSocket?         = null
        var bos: BufferedOutputStream?          = null
        var fis: FileInputStream?               = null

        try {
            val file = File(filePath)
            if (!file.exists()) throw IOException("File không tồn tại: $filePath")
            val fileName = file.name
            val fileSize = file.length()

            emitTransfer(
                TransferState(id = transferId, fileName = fileName, totalBytes = fileSize,
                    isIncoming = false, peerName = device.name, status = "CONNECTING")
            )

            @Suppress("MissingPermission")
            val remoteDevice = btAdapter.getRemoteDevice(macAddress)

            // Dừng discovery nếu đang chạy để tăng tốc kết nối
            @Suppress("MissingPermission")
            if (btAdapter.isDiscovering) btAdapter.cancelDiscovery()

            @Suppress("MissingPermission")
            btSocket = remoteDevice.createRfcommSocketToServiceRecord(BT_SERVICE_UUID)

            withContext(Dispatchers.IO) {
                @Suppress("MissingPermission")
                btSocket!!.connect()
            }
            Log.d(TAG, "BT RFCOMM connected to ${device.name} ($macAddress)")

            activeTransfers[transferId] = TransferHandle(
                btSocket = btSocket, job = currentCoroutineContext()[Job]!!
            )
            emitTransfer(_transfers.value[transferId]!!.copy(status = "TRANSFERRING"))

            bos = BufferedOutputStream(btSocket.outputStream, BUFFER_SIZE)
            val dos = DataOutputStream(bos)
            dos.writeInt(MSG_TYPE_FILE)
            val meta = "$fileName|$fileSize|$senderName|$fileIndex|$totalFiles"
                .toByteArray(Charsets.UTF_8)
            dos.writeInt(meta.size)
            dos.write(meta)
            dos.flush()

            fis = FileInputStream(file)
            streamFileData(fis, bos, transferId, fileSize, device.name)
            bos.flush()

            _transfers.value[transferId]?.let {
                emitTransfer(it.copy(status = "SUCCESS", progress = 100))
            }
            Log.d(TAG, "BT: đã gửi xong $fileName đến ${device.name}")
            onDone(true, null)
        } catch (e: Exception) {
            Log.e(TAG, "sendFileSingleBluetooth lỗi → ${device.name}", e)
            _transfers.value[transferId]?.let {
                emitTransfer(it.copy(status = "FAILED", error = e.localizedMessage))
            }
            onDone(false, e.localizedMessage)
        } finally {
            activeTransfers.remove(transferId)
            runCatching { fis?.close() }
            runCatching { bos?.close() }
            runCatching { btSocket?.close() }
            delay(1_500)
            removeTransfer(transferId)
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SHARED: stream bytes + emit progress
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Đọc từ [fis] và ghi vào [bos], emit transfer progress theo transferId.
     * Dùng chung cho cả TCP và BT sender.
     * Ném exception nếu transfer bị huỷ giữa chừng (bytesRead == -1 sớm).
     */
    private suspend fun streamFileData(
        fis: InputStream,
        bos: OutputStream,
        transferId: Long,
        fileSize: Long,
        peerName: String,
    ) {
        val buffer   = ByteArray(BUFFER_SIZE)
        var totalSent = 0L
        var lastUpdate = System.currentTimeMillis()
        var sinceLastUpdate = 0L

        while (currentCoroutineContext().isActive) {
            val bytesRead = fis.read(buffer)
            if (bytesRead == -1) break

            bos.write(buffer, 0, bytesRead)
            totalSent          += bytesRead
            sinceLastUpdate    += bytesRead

            val now   = System.currentTimeMillis()
            val delta = now - lastUpdate
            if (delta >= 500 || totalSent == fileSize) {
                val progress = if (fileSize > 0) ((totalSent * 100) / fileSize).toInt() else 0
                val speed    = if (delta > 0)
                    (sinceLastUpdate / 1024.0 / 1024.0) / (delta / 1000.0) else 0.0
                _transfers.value[transferId]?.let {
                    emitTransfer(it.copy(
                        bytesTransferred = totalSent,
                        progress         = progress,
                        speedMbps        = speed,
                    ))
                }
                lastUpdate      = now
                sinceLastUpdate = 0
            }
        }

        if (totalSent < fileSize) throw IOException("Truyền file bị gián đoạn (${totalSent}/$fileSize bytes)")
    }

    // =========================================================================
    // INCOMING TRANSFER (dùng chung TCP + BT — nhận qua DataInputStream)
    // =========================================================================

    /**
     * Xử lý nhận file từ một DataInputStream (TCP hoặc BT).
     * [onClose] được gọi ở cuối để đóng socket tương ứng.
     */
    private suspend fun handleIncomingTransfer(
        context: Context,
        dis: DataInputStream,
        transferId: Long,
        onNotificationRequested: (title: String, body: String) -> Unit,
        onClose: () -> Unit,
    ) {
        var bos: BufferedOutputStream? = null
        var senderName = "Thiết bị"
        var targetUri: Uri? = null

        activeReceiveCount.incrementAndGet()

        try {
            val metaLen = dis.readInt()
            if (metaLen <= 0 || metaLen > 1024 * 1024) throw IOException("Metadata size không hợp lệ")
            val metaBytes = ByteArray(metaLen)
            dis.readFully(metaBytes)
            val meta       = String(metaBytes, Charsets.UTF_8).split("|")

            val fileName   = meta.getOrNull(0) ?: throw IOException("Thiếu tên file")
            val fileSize   = meta.getOrNull(1)?.toLongOrNull() ?: 0L
            senderName     = meta.getOrNull(2) ?: "Thiết bị"
            val fileIndex  = meta.getOrNull(3)?.toIntOrNull() ?: 0
            val totalFiles = meta.getOrNull(4)?.toIntOrNull() ?: 1

            Log.d(TAG, "Nhận [$${fileIndex + 1}/$totalFiles] $fileName ($fileSize B) từ $senderName")
            onNotificationRequested("Đang nhận file", "$senderName gửi: $fileName")

            val lower   = fileName.lowercase(Locale.ROOT)
            val isImage = lower.let {
                it.endsWith(".jpg") || it.endsWith(".jpeg") || it.endsWith(".png") ||
                        it.endsWith(".gif") || it.endsWith(".webp") || it.endsWith(".bmp")
            }
            val isVideo = lower.let {
                it.endsWith(".mp4") || it.endsWith(".mkv") || it.endsWith(".mov") ||
                        it.endsWith(".3gp") || it.endsWith(".webm") || it.endsWith(".avi")
            }

            val (rawStream, fileUri) = createPublicFileAndGetStream(context, fileName, isImage, isVideo, fileSize)
            if (rawStream == null || fileUri == null)
                throw IOException("Không thể chuẩn bị luồng dữ liệu đích")
            targetUri = fileUri
            bos = BufferedOutputStream(rawStream, 1024 * 1024)

            emitTransfer(
                TransferState(id = transferId, fileName = fileName, totalBytes = fileSize,
                    isIncoming = true, peerName = senderName, status = "TRANSFERRING")
            )

            // Nhận dữ liệu file
            val buffer   = ByteArray(BUFFER_SIZE)
            var totalRead = 0L
            var lastUpdate = System.currentTimeMillis()
            var sinceLastUpdate = 0L

            while (totalRead < fileSize) {
                val toRead    = minOf(buffer.size.toLong(), fileSize - totalRead).toInt()
                val bytesRead = dis.read(buffer, 0, toRead)
                if (bytesRead == -1) break

                bos.write(buffer, 0, bytesRead)
                totalRead         += bytesRead
                sinceLastUpdate   += bytesRead

                val now   = System.currentTimeMillis()
                val delta = now - lastUpdate
                if (delta >= 500 || totalRead == fileSize) {
                    val progress = if (fileSize > 0) ((totalRead * 100) / fileSize).toInt() else 0
                    val speed    = if (delta > 0)
                        (sinceLastUpdate / 1024.0 / 1024.0) / (delta / 1000.0) else 0.0
                    _transfers.value[transferId]?.let {
                        emitTransfer(it.copy(bytesTransferred = totalRead, progress = progress, speedMbps = speed))
                    }
                    lastUpdate      = now
                    sinceLastUpdate = 0
                }
            }

            bos.flush()
            bos.close()
            bos = null

            if (totalRead >= fileSize) {
                completePendingFile(context, fileUri, fileSize)
                if (fileUri.scheme == "file") {
                    File(fileUri.path ?: "").takeIf { it.exists() }
                        ?.let { saveMediaToGallery(context, it) }
                }
                _transfers.value[transferId]?.let {
                    emitTransfer(it.copy(status = "SUCCESS", progress = 100))
                }
                Log.d(TAG, "Nhận thành công: $fileName")
                onNotificationRequested("Nhận file thành công", "Đã nhận $fileName từ $senderName")
            } else {
                throw IOException("Luồng dữ liệu bị gián đoạn (${totalRead}/$fileSize bytes)")
            }
        } catch (e: Exception) {
            Log.e(TAG, "handleIncomingTransfer lỗi", e)
            _transfers.value[transferId]?.let {
                emitTransfer(it.copy(status = "FAILED", error = e.localizedMessage))
            }
            runCatching { bos?.close() }
            targetUri?.let { deletePendingFile(context, it) }
            onNotificationRequested("Lỗi nhận file", "Lỗi khi nhận file từ $senderName")
        } finally {
            activeReceiveCount.decrementAndGet()
            activeTransfers.remove(transferId)
            runCatching { bos?.close() }
            runCatching { dis.close() }
            onClose()
            delay(1_500)
            removeTransfer(transferId)
        }
    }

    // =========================================================================
    // FILE HELPERS
    // =========================================================================

    private fun getMimeType(fileName: String): String = when (
        fileName.substringAfterLast('.', "").lowercase(Locale.ROOT)
    ) {
        "jpg", "jpeg" -> "image/jpeg"
        "png"         -> "image/png"
        "gif"         -> "image/gif"
        "webp"        -> "image/webp"
        "bmp"         -> "image/bmp"
        "mp4"         -> "video/mp4"
        "mkv"         -> "video/x-matroska"
        "mov"         -> "video/quicktime"
        "3gp"         -> "video/3gpp"
        "webm"        -> "video/webm"
        "avi"         -> "video/x-msvideo"
        "pdf"         -> "application/pdf"
        "apk"         -> "application/vnd.android.package-archive"
        "zip"         -> "application/zip"
        "txt"         -> "text/plain"
        "mp3"         -> "audio/mpeg"
        "wav"         -> "audio/wav"
        else          -> "application/octet-stream"
    }

    private fun createPublicFileAndGetStream(
        context: Context,
        fileName: String,
        isImage: Boolean,
        isVideo: Boolean,
        fileSize: Long,
    ): Pair<OutputStream?, Uri?> {
        val resolver = context.contentResolver
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val cv = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                put(MediaStore.MediaColumns.SIZE, fileSize)
                put(MediaStore.MediaColumns.MIME_TYPE, getMimeType(fileName))
                put(MediaStore.MediaColumns.RELATIVE_PATH, when {
                    isImage -> Environment.DIRECTORY_PICTURES + "/SuperTransfer"
                    isVideo -> Environment.DIRECTORY_MOVIES   + "/SuperTransfer"
                    else    -> Environment.DIRECTORY_DOWNLOADS + "/SuperTransfer"
                })
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val collectionUri = when {
                isImage -> MediaStore.Images.Media.EXTERNAL_CONTENT_URI
                isVideo -> MediaStore.Video.Media.EXTERNAL_CONTENT_URI
                else    -> MediaStore.Downloads.EXTERNAL_CONTENT_URI
            }
            try {
                val uri = resolver.insert(collectionUri, cv)
                if (uri != null) return Pair(resolver.openOutputStream(uri), uri)
            } catch (e: Exception) { Log.e(TAG, "MediaStore insert failed", e) }
        }
        return try {
            val dir = context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
                ?: throw IOException("Thư mục lưu trữ không khả dụng")
            dir.mkdirs()
            val file = getUniqueFile(dir, fileName)
            Pair(FileOutputStream(file), Uri.fromFile(file))
        } catch (e: Exception) {
            Log.e(TAG, "Fallback lưu file thất bại", e)
            Pair(null, null)
        }
    }

    private fun completePendingFile(context: Context, uri: Uri, fileSize: Long) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && uri.scheme == "content") {
            runCatching {
                context.contentResolver.update(uri, ContentValues().apply {
                    put(MediaStore.MediaColumns.IS_PENDING, 0)
                    put(MediaStore.MediaColumns.SIZE, fileSize)
                }, null, null)
            }
        }
        if (uri.scheme == "file") {
            runCatching {
                MediaScannerConnection.scanFile(context, arrayOf(uri.path), null) { p, u ->
                    Log.d(TAG, "Scan xong: $p → $u")
                }
            }
        }
    }

    private fun deletePendingFile(context: Context, uri: Uri) {
        runCatching {
            if (uri.scheme == "content") context.contentResolver.delete(uri, null, null)
            else if (uri.scheme == "file") File(uri.path ?: "").takeIf { it.exists() }?.delete()
        }
    }

    private fun saveMediaToGallery(context: Context, file: File) {
        val lower   = file.name.lowercase(Locale.ROOT)
        val isImage = lower.let {
            it.endsWith(".jpg") || it.endsWith(".jpeg") || it.endsWith(".png") ||
                    it.endsWith(".gif") || it.endsWith(".webp") || it.endsWith(".bmp")
        }
        val isVideo = lower.let {
            it.endsWith(".mp4") || it.endsWith(".mkv") || it.endsWith(".mov") ||
                    it.endsWith(".3gp") || it.endsWith(".webm") || it.endsWith(".avi")
        }
        if (!isImage && !isVideo) {
            MediaScannerConnection.scanFile(context, arrayOf(file.absolutePath), null) { p, u ->
                Log.d(TAG, "File scanned: $p → $u")
            }
            return
        }
        runCatching {
            val resolver = context.contentResolver
            val cv = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, file.name)
                put(MediaStore.MediaColumns.SIZE, file.length())
                if (isImage) {
                    put(MediaStore.MediaColumns.MIME_TYPE, "image/*")
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        put(MediaStore.MediaColumns.RELATIVE_PATH,
                            Environment.DIRECTORY_PICTURES + "/SuperTransfer")
                        put(MediaStore.MediaColumns.IS_PENDING, 1)
                    }
                } else {
                    put(MediaStore.MediaColumns.MIME_TYPE, "video/*")
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        put(MediaStore.MediaColumns.RELATIVE_PATH,
                            Environment.DIRECTORY_MOVIES + "/SuperTransfer")
                        put(MediaStore.MediaColumns.IS_PENDING, 1)
                    }
                }
            }
            val col = if (isImage) MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            else         MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            val uri = resolver.insert(col, cv) ?: return@runCatching
            resolver.openOutputStream(uri)?.use { out ->
                FileInputStream(file).use { inp ->
                    val buf = ByteArray(BUFFER_SIZE)
                    var n: Int
                    while (inp.read(buf).also { n = it } != -1) out.write(buf, 0, n)
                    out.flush()
                }
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                resolver.update(uri, ContentValues().apply {
                    put(MediaStore.MediaColumns.IS_PENDING, 0)
                }, null, null)
            }
            MediaScannerConnection.scanFile(context, arrayOf(file.absolutePath), null) { p, u ->
                Log.d(TAG, "Gallery scan: $p → $u")
            }
            Log.d(TAG, "saveMediaToGallery: $uri")
        }.onFailure { Log.e(TAG, "saveMediaToGallery thất bại", it) }
    }

    private fun getUniqueFile(directory: File, name: String): File {
        var file = File(directory, name)
        if (!file.exists()) return file
        val dot  = name.lastIndexOf('.')
        val base = if (dot != -1) name.substring(0, dot) else name
        val ext  = if (dot != -1) name.substring(dot)    else ""
        var n    = 1
        while (file.exists()) file = File(directory, "$base($n)$ext").also { n++ }
        return file
    }
}