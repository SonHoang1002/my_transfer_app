package com.example.mytransferapp.model

import kotlinx.coroutines.Job
import java.net.Socket
/**
 * Theo dõi 1 lượt truyền đang chạy: socket đang dùng + coroutine job xử lý.
 * Dùng để có thể huỷ (cancel) bất cứ lúc nào từ TransferEngine.
 */
data class TransferHandle(
    val socket: Socket,
    val job: Job,
)

