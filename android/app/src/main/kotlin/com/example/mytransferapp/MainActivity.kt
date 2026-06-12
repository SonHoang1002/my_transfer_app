package com.example.mytransferapp

import io.flutter.embedding.android.FlutterActivity
import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.Log
import androidx.annotation.RequiresPermission
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.example.mytransferapp.model.ScanMode
import com.example.mytransferapp.model.SendMode
import com.example.mytransferapp.model.TargetDevice
import com.example.mytransferapp.network.TransferEngine
import com.example.mytransferapp.service.TransferService
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.collectLatest

/**
 * Channel naming convention (dễ map sang iOS sau này):
 *
 *  METHOD  : com.supertransfer/method
 *  EVENT   : com.supertransfer/event.transfer      — tiến trình transfer realtime
 *  EVENT   : com.supertransfer/event.wifi_devices  — danh sách thiết bị WiFi scan
 *  EVENT   : com.supertransfer/event.bt_devices    — danh sách thiết bị Bluetooth scan
 *
 * Method list:
 *  ── Network info ───────────────────────────── 
 *  getCurrentDeviceInfo()           -> Map from Device infor
 *
 *  ── Permission ───────────────────────────────
 *  checkPermissions()        → bool
 *  requestPermissions()      → bool
 *
 *  ── WiFi scan ────────────────────────────────
 *  startWifiScan()           → void   (kết quả qua event.wifi_devices)
 *  stopWifiScan()            → void
 *
 *  ── Bluetooth scan ───────────────────────────
 *  checkBluetoothEnabled()   → bool
 *  requestEnableBluetooth()  → void   (mở dialog hệ thống)
 *  startBluetoothScan()      → void   (kết quả qua event.bt_devices)
 *  stopBluetoothScan()       → void
 *
 *  ── Transfer ─────────────────────────────────
 *  startReceiveServer()                           → void   (tự động bật khi mở app)
 *  stopReceiveServer()                            → void
 *  sendFileToMultiple(ipAddress, filePath)       → void   (tiến trình qua event.transfer)
 *  sendFileViaBluetooth(address, filePath)        → void
 *  cancelTransfer()                               → void
 *
 *  ── Utility ──────────────────────────────────
 *  openFile(filePath)        → void
 *  openHotspotSettings()     → void
 *  openWifiSettings()        → void
 *  openBluetoothSettings()   → void
 */
class MainActivity : FlutterActivity() {

    // ── Channel names ──────────────────────────────────────────────────
    companion object {
        const val CH_METHOD = "com.supertransfer/method"
        const val CH_TRANSFER = "com.supertransfer/event.transfer"
        const val CH_WIFI_DEVICES = "com.supertransfer/event.wifi_devices"
        const val CH_BT_DEVICES = "com.supertransfer/event.bt_devices"

        const val CH_INCOMING_REQUEST = "com.supertransfer/event.incoming_request"
        const val REQ_PERMISSIONS = 1001
        const val TAG = "Supertransfer"
    }

    // ── Coroutine scope cho flow collectors ───────────────────────────
    private val mainScope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    // ── Event sinks ────────────────────────────────────────────────────
    private var transferSink: EventChannel.EventSink? = null
    private var wifiDevicesSink: EventChannel.EventSink? = null
    private var btDevicesSink: EventChannel.EventSink? = null

    // ── Permission callback ────────────────────────────────────────────
    private var permissionResult: MethodChannel.Result? = null

    private var incomingRequestSink: EventChannel.EventSink? = null


    // ── Bluetooth scan receiver ────────────────────────────────────────
    private var isBtReceiverRegistered = false
    private val btReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) {
            if (intent.action != BluetoothDevice.ACTION_FOUND) return
            @Suppress("DEPRECATION")
            val device = intent.getParcelableExtra<BluetoothDevice>(BluetoothDevice.EXTRA_DEVICE)
                ?: return

            val name = try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                    ActivityCompat.checkSelfPermission(ctx, Manifest.permission.BLUETOOTH_CONNECT)
                    != PackageManager.PERMISSION_GRANTED
                ) device.address
                else device.name ?: device.address
            } catch (e: SecurityException) {
                device.address
            }

            val bondLabel = when (device.bondState) {
                BluetoothDevice.BOND_BONDED -> "bonded"
                BluetoothDevice.BOND_BONDING -> "bonding"
                else -> "none"
            }

            val map = mapOf(
                "name" to name,
                "address" to device.address,
                "bondState" to bondLabel,
                "type" to "bluetooth"
            )
            btDevicesSink?.success(map)
        }
    }

    // ──────────────────────────────────────────────────────────────────
    // configureFlutterEngine
    // ──────────────────────────────────────────────────────────────────
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        setupMethodChannel(messenger)
        setupTransferEventChannel(messenger)
        setupWifiDevicesEventChannel(messenger)
        setupBtDevicesEventChannel(messenger)
        setupIncomingRequestEventChannel(messenger)
    }

    // ──────────────────────────────────────────────────────────────────
    // MethodChannel
    // ──────────────────────────────────────────────────────────────────

    private fun setupMethodChannel(messenger: io.flutter.plugin.common.BinaryMessenger) {
        MethodChannel(messenger, CH_METHOD).setMethodCallHandler { call, result ->
            when (call.method) {

                // ── Network info ──────────────────────────────────────
                "getCurrentDeviceInfo" ->
                    result.success(
                        mapOf(
                            "ipAddress" to TransferEngine.getLocalIpAddress(),
                            "deviceName" to TransferEngine.getDeviceName(),
                            "isWifiConnected" to isWifiConnected()
                        )
                    )

                "getTransferEngineStatus" -> {
                    result.success(
                        mapOf(
                            "isWifiScanning" to TransferEngine.isWifiScanning.value,
                            "isBluetoothScanning" to TransferEngine.isBluetoothScanning.value,
                            "isReceiving" to TransferEngine.isReceiving.value,
                            "isAdvertising" to TransferEngine.isAdvertising.value,
                        )
                    )
                }

                // ── Permission ────────────────────────────────────────
                "checkPermissions" ->
                    result.success(hasAllPermissions())

                "requestPermissions" -> {
                    if (hasAllPermissions()) {
                        result.success(true)
                    } else {
                        permissionResult = result
                        ActivityCompat.requestPermissions(
                            this,
                            buildRequiredPermissions(),
                            REQ_PERMISSIONS
                        )
                    }
                }

                // ── WiFi scan ─────────────────────────────────────────
                "startWifiScan" -> {
                    val args = call.arguments as Map<*, *>
                    val timeoutMs = args["timeoutMs"] as Int
                    TransferEngine.startWifiScanning(TransferEngine.getDeviceName(), timeoutMs)
                    result.success(null)
                }

                "stopWifiScan" -> {
                    TransferEngine.stopWifiScanning()
                    result.success(null)
                }

                // ── Bluetooth ─────────────────────────────────────────
                "checkBluetoothEnabled" -> {
                    val adapter = BluetoothAdapter.getDefaultAdapter()
                    result.success(adapter?.isEnabled == true)
                }

                "requestEnableBluetooth" -> {
                    try {
                        val intent = Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE)
                        if (ActivityCompat.checkSelfPermission(
                                this,
                                Manifest.permission.BLUETOOTH_CONNECT
                            ) != PackageManager.PERMISSION_GRANTED
                        ) {
                            result.error(
                                "requestEnableBluetooth",
                                "BLUETOOTH_CONNECT Permission is not granted",
                                null
                            )
                        }
                        startActivity(intent)
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("requestEnableBluetooth", e.message, null)
                    }
                }

                "startBluetoothScan" -> {
                    val args = call.arguments as Map<*, *>
                    val timeoutMs = args["timeoutMs"] as Int
                    val adapter = BluetoothAdapter.getDefaultAdapter()
                    if (adapter == null) {
                        result.error("BT_NOT_SUPPORTED", "Device does not support Bluetooth", null)
                        return@setMethodCallHandler
                    }
                    if (!adapter.isEnabled) {
                        result.error("BT_DISABLED", "Bluetooth is not enabled", null)
                        return@setMethodCallHandler
                    }
                    registerBtReceiver()
                    try {
                        adapter.startDiscovery()
                        TransferEngine.setBluetoothScanning(true)
                        result.success(null)
                    } catch (e: SecurityException) {
                        result.error("BT_PERMISSION", e.message, null)
                    }
                }

                "stopBluetoothScan" -> {
                    try {
                        BluetoothAdapter.getDefaultAdapter()?.cancelDiscovery()
                    } catch (_: Exception) {
                    }
                    TransferEngine.setBluetoothScanning(false)
                    unregisterBtReceiver()
                    result.success(null)
                }

                // ── Transfer ──────────────────────────────────────────
                "startReceiveServer" -> {
                    startTransferService()
                    result.success(null)
                }

                "stopReceiveServer" -> {
                    stopService(Intent(this, TransferService::class.java))
                    result.success(null)
                }

                "requestSendFileToMultiple" -> {
                    val args = call.arguments as? Map<*, *>
                    if (args == null) {
                        result.error("INVALID_ARGS", "arguments required", null)
                        return@setMethodCallHandler
                    }

                    @Suppress("UNCHECKED_CAST")
                    val rawDevices = args["devices"] as? List<Map<*, *>>

                    @Suppress("UNCHECKED_CAST")
                    val listFilePath =
                        args["listFilePath"] as? List<String> // ✅ danh sách nhiều file

                    val modeStr = args["mode"] as? String ?: "SEQUENTIAL"

                    if (rawDevices.isNullOrEmpty() || listFilePath.isNullOrEmpty()) {
                        result.error("INVALID_ARGS", "devices and listFilePath are required", null)
                        return@setMethodCallHandler
                    }

                    val devices = rawDevices.map { d ->
                        TargetDevice(
                            name = d["name"] as? String ?: "",
                            ipAddress = d["ipAddress"] as? String ?: "",
                            port = (d["port"] as? Int) ?: 9999,
                            from = ScanMode.entries[(d["from"] as Int)]
                        )
                    }

                    // ✅ Convert list path → list Uri
                    val fileUris = listFilePath.map { Uri.parse(it) }

                    val mode = if (modeStr == "PARALLEL") SendMode.PARALLEL else SendMode.SEQUENTIAL

                    TransferEngine.requestSendFileToMultiple(
                        context = applicationContext,
                        devices = devices,
                        fileUris = fileUris,
                        senderName = TransferEngine.getDeviceName(),
                        mode = mode,
                        onEachFileDone = { device, fileUri, ok, error ->
                            Log.d(
                                TAG,
                                "onEachFileDone: device=${device.name} file=$fileUri success=$ok error=$error"
                            )
                        },
                        onEachDeviceDone = { device, results ->
                            Log.d(TAG, "onEachDeviceDone: ${device.name} → $results")
                        },
                        onAllDone = { resultMap ->
                            // resultMap: Map<DeviceInfo, Map<Uri, Boolean>>
                            val output = resultMap.map { (device, fileResults) ->
                                mapOf(
                                    "name" to device.name,
                                    "ipAddress" to device.ipAddress,
                                    "files" to fileResults.map { (uri, ok) ->
                                        mapOf("filePath" to uri.toString(), "success" to ok)
                                    }
                                )
                            }
                            result.success(output)
                        }
                    )
                }

                "sendFileViaBluetooth" -> {
                    val filePath = call.argument<String>("filePath")
                    if (filePath.isNullOrBlank()) {
                        result.error("INVALID_ARGS", "filePath is required", null)
                        return@setMethodCallHandler
                    }
                    shareFileViaBluetooth(Uri.parse(filePath))
                    result.success(null)
                }

                "cancelTransfer" -> {
                    val transferId = call.argument<Long>("transferId") // null = cancel tất cả
                    TransferEngine.cancelActiveTransfer(transferId)
                    result.success(null)
                }

                // ── Utility ───────────────────────────────────────────
                "openFile" -> {
                    val filePath = call.argument<String>("filePath")
                    val fileName = call.argument<String>("fileName") ?: ""
                    if (filePath.isNullOrBlank()) {
                        result.error("INVALID_ARGS", "filePath is required", null)
                        return@setMethodCallHandler
                    }
                    openFile(filePath, fileName)
                    result.success(null)
                }

                "openHotspotSettings" -> {
                    openHotspotSettings()
                    result.success(null)
                }

                "openWifiSettings" -> {
                    try {
                        startActivity(Intent(Settings.ACTION_WIFI_SETTINGS))
                    } catch (e: Exception) {
                        result.error("SETTINGS_ERROR", e.message, null); return@setMethodCallHandler
                    }
                    result.success(null)
                }

                "openBluetoothSettings" -> {
                    try {
                        startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS))
                    } catch (e: Exception) {
                        result.error("SETTINGS_ERROR", e.message, null); return@setMethodCallHandler
                    }
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }
    }

    // ──────────────────────────────────────────────────────────────────
    // EventChannel — transfer progress
    // ──────────────────────────────────────────────────────────────────
    private fun setupTransferEventChannel(messenger: BinaryMessenger) {
        EventChannel(messenger, CH_TRANSFER).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                transferSink = sink
                mainScope.launch {
                    // Collect Map<Long, TransferState> — emit list ra Flutter
                    TransferEngine.transfers.collectLatest { transferMap ->
                        val list = transferMap.values.map { state ->
                            mapOf(
                                "id" to state.id,
                                "fileName" to state.fileName,
                                "totalBytes" to state.totalBytes,
                                "bytesTransferred" to state.bytesTransferred,
                                "progress" to state.progress,
                                "speedMbps" to state.speedMbps,
                                "isIncoming" to state.isIncoming,
                                "peerName" to state.peerName,
                                "status" to state.status,
                                "error" to (state.error ?: "")
                            )
                        }
                        sink.success(list)
                    }
                }
            }

            override fun onCancel(args: Any?) {
                transferSink = null
            }
        })
    }

    // ──────────────────────────────────────────────────────────────────
    // EventChannel — WiFi discovered devices
    // ──────────────────────────────────────────────────────────────────
    private fun setupWifiDevicesEventChannel(messenger: io.flutter.plugin.common.BinaryMessenger) {
        EventChannel(messenger, CH_WIFI_DEVICES).setStreamHandler(object :
            EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                wifiDevicesSink = sink
                mainScope.launch {
                    TransferEngine.discoveredDevices.collectLatest { devices ->
                        val list = devices.map { d ->
                            mapOf(
                                "name" to d.name,
                                "ipAddress" to d.ipAddress,
                                "port" to d.port,
                                "lastSeen" to d.lastSeen,
                                "type" to "wifi"
                            )
                        }
                        sink.success(list)
                    }
                }
            }

            override fun onCancel(args: Any?) {
                wifiDevicesSink = null
            }
        })
    }

    // ──────────────────────────────────────────────────────────────────
    // EventChannel — Bluetooth discovered devices
    // (BroadcastReceiver push từng device, không phải list)
    // ──────────────────────────────────────────────────────────────────
    private fun setupBtDevicesEventChannel(messenger: io.flutter.plugin.common.BinaryMessenger) {
        EventChannel(messenger, CH_BT_DEVICES).setStreamHandler(object :
            EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                btDevicesSink = sink
            }

            override fun onCancel(args: Any?) {
                btDevicesSink = null
            }
        })
    }

    private fun setupIncomingRequestEventChannel(messenger: io.flutter.plugin.common.BinaryMessenger) {
        EventChannel(messenger, CH_INCOMING_REQUEST).setStreamHandler(object :
            EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                incomingRequestSink = sink
                mainScope.launch {
                    TransferEngine.incomingConnectionRequest.collect { device ->
                        sink.success(
                            mapOf(
                                "name" to device.name,
                                "ipAddress" to device.ipAddress,
                                "port" to device.port,
                                "lastSeen" to device.lastSeen,
                                "type" to "wifi"
                            )
                        )
                    }
                }
            }

            override fun onCancel(args: Any?) {
                incomingRequestSink = null
            }
        })
    }

    // ──────────────────────────────────────────────────────────────────
    // Lifecycle
    // ──────────────────────────────────────────────────────────────────
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Tự động bật nhận file khi mở app
        startTransferService()
    }

    override fun onDestroy() {
        super.onDestroy()
        mainScope.cancel()
        unregisterBtReceiver()
        stopService(Intent(this, TransferService::class.java))
        TransferEngine.stopWifiScanning()
        TransferEngine.cancelActiveTransfer()
        Log.d(TAG, "onDestroy — all services stopped")
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_PERMISSIONS) {
            val granted = grantResults.isNotEmpty() && grantResults.all {
                it == PackageManager.PERMISSION_GRANTED
            }
            permissionResult?.success(granted)
            permissionResult = null
            if (granted) startTransferService()
        }
    }

    // ──────────────────────────────────────────────────────────────────
    // Helpers
    // ──────────────────────────────────────────────────────────────────

    private fun startTransferService() {
        val intent = Intent(this, TransferService::class.java)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                startForegroundService(intent)
            else
                startService(intent)
        } catch (e: Exception) {
            Log.e(TAG, "startTransferService error: ${e.message}")
        }
    }

    private fun hasAllPermissions(): Boolean =
        buildRequiredPermissions().all {
            ContextCompat.checkSelfPermission(this, it) == PackageManager.PERMISSION_GRANTED
        }

    private fun buildRequiredPermissions(): Array<String> {
        val list = mutableListOf(
            Manifest.permission.ACCESS_FINE_LOCATION,
            Manifest.permission.ACCESS_COARSE_LOCATION
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            list += Manifest.permission.POST_NOTIFICATIONS
            list += Manifest.permission.NEARBY_WIFI_DEVICES
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            list += Manifest.permission.BLUETOOTH_SCAN
            list += Manifest.permission.BLUETOOTH_CONNECT
        }
        return list.toTypedArray()
    }

    @RequiresPermission(Manifest.permission.ACCESS_NETWORK_STATE)
    private fun isWifiConnected(): Boolean {
        val cm = getSystemService(CONNECTIVITY_SERVICE)
                as ConnectivityManager
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val net = cm.activeNetwork ?: return false
            val caps = cm.getNetworkCapabilities(net) ?: return false
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
        } else {
            @Suppress("DEPRECATION")
            cm.activeNetworkInfo?.type == ConnectivityManager.TYPE_WIFI
        }
    }

    private fun registerBtReceiver() {
        if (isBtReceiverRegistered) return
        registerReceiver(btReceiver, IntentFilter(BluetoothDevice.ACTION_FOUND))
        isBtReceiverRegistered = true
    }

    private fun unregisterBtReceiver() {
        if (!isBtReceiverRegistered) return
        try {
            unregisterReceiver(btReceiver)
        } catch (_: Exception) {
        }
        isBtReceiverRegistered = false
    }

    private fun openFile(filePath: String, fileName: String) {
        try {
            val uri = Uri.parse(filePath)
            val ext = fileName.substringAfterLast('.', "").lowercase()
            val mime = when (ext) {
                "jpg", "jpeg" -> "image/jpeg"; "png" -> "image/png"
                "gif" -> "image/gif"; "webp" -> "image/webp"
                "mp4" -> "video/mp4"; "mkv" -> "video/x-matroska"
                "mov" -> "video/quicktime"
                "mp3" -> "audio/mpeg"; "wav" -> "audio/wav"
                "pdf" -> "application/pdf"
                "txt" -> "text/plain"; "zip" -> "application/zip"
                else -> "*/*"
            }
            startActivity(Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mime)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            })
        } catch (e: Exception) {
            Log.e(TAG, "openFile error: ${e.message}")
        }
    }

    private fun openHotspotSettings() {
        try {
            startActivity(Intent().apply {
                action = Intent.ACTION_MAIN
                setClassName("com.android.settings", "com.android.settings.TetherSettings")
            })
        } catch (_: Exception) {
            try {
                startActivity(Intent(Settings.ACTION_WIRELESS_SETTINGS))
            } catch (e: Exception) {
                Log.e(TAG, "openHotspotSettings error: ${e.message}")
            }
        }
    }

    private fun shareFileViaBluetooth(fileUri: Uri) {
        try {
            startActivity(
                Intent.createChooser(
                    Intent(Intent.ACTION_SEND).apply {
                        type = contentResolver.getType(fileUri) ?: "*/*"
                        putExtra(Intent.EXTRA_STREAM, fileUri)
                        setPackage("com.android.bluetooth")
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    },
                    "Gửi file qua Bluetooth"
                )
            )
        } catch (_: Exception) {
            startActivity(
                Intent.createChooser(
                    Intent(Intent.ACTION_SEND).apply {
                        type = contentResolver.getType(fileUri) ?: "*/*"
                        putExtra(Intent.EXTRA_STREAM, fileUri)
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    },
                    "Chia sẻ file"
                )
            )
        }
    }
}