# XiaoZhi 网络连接与会话管理机制

本文档深入分析XiaoZhi的网络连接架构、会话ID管理、以及连接与会话之间的关联关系。

## 目录
- [架构概览](#架构概览)
- [连接与会话的关系](#连接与会话的关系)
- [会话ID管理机制](#会话ID管理机制)
- [协议层实现对比](#协议层实现对比)
- [生命周期管理](#生命周期管理)
- [关键代码解析](#关键代码解析)

---

## 架构概览

XiaoZhi采用**连接与会话分离**的设计，支持两种底层传输协议：

```
┌─────────────────────────────────────────────────────────────┐
│                      Application 层                         │
│  ┌───────────────────────────────────────────────────────┐ │
│  │  状态机管理：Idle → Connecting → Listening → Speaking  │ │
│  │  业务逻辑：唤醒词检测、音频编解码、UI更新              │ │
│  └───────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
                              ↕ 调用 Protocol 接口
┌─────────────────────────────────────────────────────────────┐
│                      Protocol 抽象层                        │
│  ┌───────────────────────────────────────────────────────┐ │
│  │  统一接口：OpenAudioChannel() / CloseAudioChannel()    │ │
│  │  会话管理：session_id_ 生命周期控制                    │ │
│  │  消息封装：所有JSON消息自动附加 session_id            │ │
│  └───────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
                              ↕ 具体协议实现
        ┌─────────────────────┴─────────────────────┐
        ↓                                           ↓
┌───────────────────────┐               ┌───────────────────────┐
│   WebSocket Protocol  │               │     MQTT Protocol     │
│  ┌─────────────────┐  │               │  ┌─────────────────┐  │
│  │ 长连接保持      │  │               │  │ MQTT连接保持    │  │
│  │ 全双工通信      │  │               │  │ UDP音频通道     │  │
│  │ 实时性高        │  │               │  │ 低功耗优化      │  │
│  └─────────────────┘  │               │  └─────────────────┘  │
└───────────────────────┘               └───────────────────────┘
```

**核心设计原则**：
1. **连接 ≠ 会话**：网络连接是物理层的，会话是逻辑层的
2. **延迟连接**：只在需要音频交互时才建立连接（节省电量）
3. **会话隔离**：每个对话有独立的session_id，服务器可区分不同对话上下文
4. **协议透明**：应用层不关心底层是WebSocket还是MQTT

---

## 连接与会话的关系

### 概念区分

| 维度 | 网络连接 (Connection) | 会话 (Session) |
|-----|----------------------|---------------|
| **层级** | 传输层 (TCP/UDP) | 应用层 (业务逻辑) |
| **生命周期** | 长连接保持（可复用） | 每次对话新建（一次性） |
| **标识** | IP+端口 / ClientID | session_id (UUID) |
| **作用** | 数据传输通道 | 对话上下文隔离 |
| **创建时机** | 首次需要时建立 | 每次OpenAudioChannel时新建 |
| **销毁时机** | 网络断开/设备休眠 | CloseAudioChannel时结束 |

### 关系图解

```
【场景1：单次对话】
时间轴 ──────────────────────────────────────────────→

网络连接:  [=========建立=========][====保持====][===关闭===]
           ↑                      ↑             ↑
会话:      [session_abc][session_def][session_ghi]
           ↑唤醒词1    ↑唤醒词2     ↑唤醒词3

说明：一个网络连接可以承载多个会话（对话）


【场景2：连接断开后的新对话】
时间轴 ──────────────────────────────────────────────→

网络连接:  [====建立1====][断开...][====建立2====]
           ↑             ↑       ↑
会话:      [session_xxx]        [session_yyy]
           ↑唤醒词            ↑唤醒词（重新连接后）

说明：连接断开后重建，会话ID也会重新生成
```

### 为什么这样设计？

**1. 节省电量（关键！）**
```cpp
// 文件：websocket_protocol.cc 第23-26行
bool WebsocketProtocol::Start() {
    // Only connect to server when audio channel is needed
    return true;  // 启动时不连接！
}

// 真正连接发生在 OpenAudioChannel()
bool WebsocketProtocol::OpenAudioChannel() {
    // 此时才建立WebSocket连接
    websocket_->Connect(url.c_str());
}
```

**2. 服务器负载均衡**
```
用户说"你好小智" → 连接到服务器A → 对话结束 → 连接保持但不传输数据
用户再说"你好小智" → 复用同一连接 → 但新session_id → 服务器可分配到不同处理节点
```

**3. 故障隔离**
```
如果某个对话(session)出现问题（如LLM卡死）
→ 只影响当前session
→ 不影响网络连接
→ 用户可立即开始新对话（新session_id）
```

---

## 会话ID管理机制

### session_id 的生命周期

```cpp
// 文件：main/protocols/protocol.h 第89行
class Protocol {
protected:
    std::string session_id_;  // 当前会话ID
};
```

**完整生命周期**：

```
1. 初始状态
   session_id_ = "" (空字符串)
   
2. 创建会话（OpenAudioChannel）
   ├─ 发送 hello 消息到服务器
   ├─ 服务器返回 hello 响应，包含新生成的 session_id
   └─ 设备端保存：session_id_ = server_response["session_id"]
   
3. 会话期间的所有消息
   每条JSON消息自动附加 session_id_：
   {"session_id": "abc123", "type": "listen", "state": "start"}
   
4. 会话结束（CloseAudioChannel）
   ├─ WebSocket：直接关闭，session_id_ 保留（但连接已断）
   └─ MQTT：发送 goodbye 消息，清空 session_id_ = ""
```

### 关键代码：session_id 的获取与使用

**① 从服务器获取 session_id**

```cpp
// 文件：websocket_protocol.cc 第228-239行
void WebsocketProtocol::ParseServerHello(const cJSON* root) {
    // 1. 验证传输协议
    auto transport = cJSON_GetObjectItem(root, "transport");
    if (strcmp(transport->valuestring, "websocket") != 0) {
        ESP_LOGE(TAG, "Unsupported transport");
        return;
    }

    // 2. 提取 session_id（服务器生成）
    auto session_id = cJSON_GetObjectItem(root, "session_id");
    if (cJSON_IsString(session_id)) {
        session_id_ = session_id->valuestring;  // ← 保存会话ID
        ESP_LOGI(TAG, "Session ID: %s", session_id_.c_str());
    }

    // 3. 提取音频参数
    auto audio_params = cJSON_GetObjectItem(root, "audio_params");
    if (cJSON_IsObject(audio_params)) {
        server_sample_rate_ = cJSON_GetObjectItem(audio_params, "sample_rate")->valueint;
        server_frame_duration_ = cJSON_GetObjectItem(audio_params, "frame_duration")->valueint;
    }

    // 4. 通知应用层：音频通道已打开
    xEventGroupSetBits(event_group_handle_, WEBSOCKET_PROTOCOL_SERVER_HELLO_EVENT);
}
```

**② 所有消息自动附加 session_id**

```cpp
// 文件：protocol.cc 第51-79行

// 唤醒词检测消息
void Protocol::SendWakeWordDetected(const std::string& wake_word) {
    std::string json = "{\"session_id\":\"" + session_id_ + 
                      "\",\"type\":\"listen\",\"state\":\"detect\",\"text\":\"" + wake_word + "\"}";
    SendText(json);
}

// 开始监听消息
void Protocol::SendStartListening(ListeningMode mode) {
    std::string message = "{\"session_id\":\"" + session_id_ + "\"";
    message += ",\"type\":\"listen\",\"state\":\"start\"";
    if (mode == kListeningModeRealtime) {
        message += ",\"mode\":\"realtime\"";
    } else if (mode == kListeningModeAutoStop) {
        message += ",\"mode\":\"auto\"";
    } else {
        message += ",\"mode\":\"manual\"";
    }
    message += "}";
    SendText(message);
}

// 停止监听消息
void Protocol::SendStopListening() {
    std::string message = "{\"session_id\":\"" + session_id_ + 
                          "\",\"type\":\"listen\",\"state\":\"stop\"}";
    SendText(message);
}

// MCP消息
void Protocol::SendMcpMessage(const std::string& payload) {
    std::string message = "{\"session_id\":\"" + session_id_ + 
                          "\",\"type\":\"mcp\",\"payload\":" + payload + "}";
    SendText(message);
}
```

### 服务器如何识别会话？

**WebSocket 场景**：
```
设备 ──WebSocket连接──→ 服务器
  │                       │
  ├─ hello 请求 ─────────→│ 服务器创建新session
  │  {                    │  session_id = generate_uuid()
  │    "type": "hello",   │  
  │    "transport": "ws"  │
  │  }                    │
  │                       │
  │←─ hello 响应 ─────────┤
  │  {                    │
  │    "type": "hello",   │
  │    "session_id": "abc"│ ← 设备保存此ID
  │  }                    │
  │                       │
  ├─ listen start ───────→│ 服务器查找session
  │  {"session_id":"abc"} │  找到对应上下文
  │                       │
  ├─ OPUS音频帧 ─────────→│ 服务器将音频关联到session
  │                       │
```

**MQTT 场景**：
```
设备 ──MQTT连接──→ MQTT Broker ──→ 服务器
  │                  │              │
  ├─ publish hello ─→│─────────────→│ 服务器创建session
  │  topic: /device  │              │  回复到 /server
  │                  │              │
  │←─ publish resp ──│←────────────┤
  │  topic: /server  │              │
  │  {"session_id":"xyz"}          │
  │                  │              │
  ├─ UDP音频 ───────→│（绕过MQTT）   │ 服务器用session_id关联
  │  (加密OPUS)      │              │
```

---

## 协议层实现对比

### WebSocket vs MQTT 架构差异

```cpp
// 抽象基类：protocol.h
class Protocol {
public:
    virtual bool OpenAudioChannel() = 0;      // 打开音频通道
    virtual void CloseAudioChannel(bool send_goodbye = true) = 0;  // 关闭
    virtual bool IsAudioChannelOpened() const = 0;  // 检查状态
    virtual bool SendAudio(std::unique_ptr<AudioStreamPacket> packet) = 0;
    
protected:
    std::string session_id_;  // 会话ID（两种协议都使用）
    int server_sample_rate_ = 24000;
    int server_frame_duration_ = 60;
};
```

### WebSocketProtocol 实现

**特点**：单连接、全双工、JSON+二进制混合

```cpp
// 文件：websocket_protocol.h
class WebsocketProtocol : public Protocol {
private:
    std::unique_ptr<WebSocket> websocket_;  // 单一WebSocket连接
    int version_ = 3;  // 协议版本
};

// 连接管理
bool WebsocketProtocol::OpenAudioChannel() {
    // 1. 创建WebSocket连接
    websocket_ = network->CreateWebSocket(1);
    
    // 2. 设置请求头（鉴权+设备信息）
    websocket_->SetHeader("Authorization", token.c_str());
    websocket_->SetHeader("Protocol-Version", std::to_string(version_).c_str());
    websocket_->SetHeader("Device-Id", SystemInfo::GetMacAddress().c_str());
    websocket_->SetHeader("Client-Id", Board::GetInstance().GetUuid().c_str());
    
    // 3. 建立连接
    websocket_->Connect(url.c_str());
    
    // 4. 发送hello，等待服务器返回session_id
    SendText(GetHelloMessage());
    WaitForServerHello();  // 阻塞等待，超时10秒
    
    return true;
}

// 音频发送（支持三种协议版本）
bool WebsocketProtocol::SendAudio(std::unique_ptr<AudioStreamPacket> packet) {
    if (version_ == 2) {
        // 版本2：带时间戳的二进制协议（用于服务器AEC）
        BinaryProtocol2 bp2;
        bp2.version = htons(2);
        bp2.timestamp = htonl(packet->timestamp);  // 关键：时间戳用于回声消除对齐
        bp2.payload_size = htonl(packet->payload.size());
        // ...
    } else if (version_ == 3) {
        // 版本3：简化头（推荐）
        BinaryProtocol3 bp3;
        bp3.type = 0;
        bp3.payload_size = htons(packet->payload.size());
        // ...
    } else {
        // 版本1：直接发送OPUS数据（无头）
        return websocket_->Send(packet->payload.data(), packet->payload.size(), true);
    }
}

// 关闭通道
void WebsocketProtocol::CloseAudioChannel(bool send_goodbye) {
    // WebSocket不需要显式发送goodbye，直接关闭连接
    websocket_.reset();  // 释放连接对象
}

// 检查通道状态
bool WebsocketProtocol::IsAudioChannelOpened() const {
    return websocket_ != nullptr 
        && websocket_->IsConnected() 
        && !error_occurred_ 
        && !IsTimeout();
}
```

### MqttProtocol 实现

**特点**：控制通道+数据通道分离、低功耗、适合物联网

```cpp
// 文件：mqtt_protocol.h
class MqttProtocol : public Protocol {
private:
    std::unique_ptr<Mqtt> mqtt_;      // MQTT控制通道（TCP）
    std::unique_ptr<Udp> udp_;        // UDP音频通道（传输音频数据）
    std::mutex channel_mutex_;        // 保护udp_的线程安全
    mbedtls_aes_context aes_ctx_;     // AES加密上下文
};

// 连接管理（分两步）
bool MqttProtocol::OpenAudioChannel() {
    // 第1步：确保MQTT控制通道已连接（长连接保持）
    if (mqtt_ == nullptr || !mqtt_->IsConnected()) {
        if (!StartMqttClient(true)) {
            return false;
        }
    }
    
    // 第2步：发送hello，获取session_id和UDP配置
    session_id_ = "";
    SendText(GetHelloMessage());
    WaitForServerHello();  // 等待服务器返回session_id和加密密钥
    
    // 第3步：建立UDP音频通道
    std::lock_guard<std::mutex> lock(channel_mutex_);
    udp_ = network->CreateUdp(2);
    udp_->OnMessage([this](const std::string& data) {
        // 解密并播放音频
        DecryptAndPlayAudio(data);
    });
    
    return true;
}

// 音频发送（加密传输）
bool MqttProtocol::SendAudio(std::unique_ptr<AudioStreamPacket> packet) {
    std::lock_guard<std::mutex> lock(channel_mutex_);
    if (udp_ == nullptr) return false;
    
    // 构造加密nonce（包含序列号和时间戳）
    std::string nonce(aes_nonce_);
    *(uint16_t*)&nonce[2] = htons(packet->payload.size());
    *(uint32_t*)&nonce[8] = htonl(packet->timestamp);
    *(uint32_t*)&nonce[12] = htonl(++local_sequence_);
    
    // AES-CTR加密
    std::string encrypted;
    encrypted.resize(aes_nonce_.size() + packet->payload.size());
    memcpy(encrypted.data(), nonce.data(), nonce.size());
    mbedtls_aes_crypt_ctr(&aes_ctx_, packet->payload.size(), &nc_off, 
                          (uint8_t*)nonce.c_str(), stream_block,
                          (uint8_t*)packet->payload.data(), 
                          (uint8_t*)&encrypted[nonce.size()]);
    
    // 通过UDP发送（比TCP更高效）
    return udp_->Send(encrypted) > 0;
}

// 关闭通道（显式发送goodbye）
void MqttProtocol::CloseAudioChannel(bool send_goodbye) {
    {
        std::lock_guard<std::mutex> lock(channel_mutex_);
        udp_.reset();  // 关闭UDP通道
    }
    
    // MQTT需要显式发送goodbye消息
    if (send_goodbye) {
        std::string message = "{";
        message += "\"session_id\":\"" + session_id_ + "\",";
        message += "\"type\":\"goodbye\"";
        message += "}";
        SendText(message);  // 通知服务器会话结束
    }
    
    session_id_ = "";  // 清空会话ID
    
    if (on_audio_channel_closed_ != nullptr) {
        on_audio_channel_closed_();
    }
}

// 服务器主动关闭会话的处理
void MqttProtocol::OnMessage(const std::string& topic, const std::string& payload) {
    cJSON* root = cJSON_Parse(payload.c_str());
    cJSON* type = cJSON_GetObjectItem(root, "type");
    
    if (strcmp(type->valuestring, "goodbye") == 0) {
        // 服务器发送了goodbye
        auto session_id = cJSON_GetObjectItem(root, "session_id");
        if (session_id == nullptr || session_id_ == session_id->valuestring) {
            // 是当前会话，关闭通道（不再发送goodbye回去，避免乒乓）
            CloseAudioChannel(false);
        }
    }
}
```

### 两种协议对比表

| 特性 | WebSocket | MQTT |
|-----|-----------|------|
| **连接类型** | 单一TCP长连接 | MQTT TCP + UDP音频双通道 |
| **实时性** | 极高（全双工） | 高（UDP无拥塞控制） |
| **功耗** | 中高（保持TCP连接） | 低（MQTT可休眠，UDP按需） |
| **安全性** | TLS加密 | TLS + AES双重加密 |
| **适用场景** | 实时对话、高交互 | 物联网、低功耗设备 |
| **会话结束** | 直接关闭连接 | 显式发送goodbye消息 |
| **音频传输** | 同一连接（二进制帧） | 独立UDP通道 |
| **服务器推送** | 原生支持 | 通过MQTT订阅实现 |

---

## 生命周期管理

### 应用层调用流程

```cpp
// 文件：application.cc

// 场景1：首次唤醒，需要新建连接和会话
void Application::HandleWakeWordDetectedEvent() {
    if (state == kDeviceStateIdle) {
        // 检查是否已有音频通道
        if (!protocol_->IsAudioChannelOpened()) {
            // 没有连接，进入Connecting状态
            SetDeviceState(kDeviceStateConnecting);
            
            // 异步打开通道（避免阻塞主线程）
            Schedule([this, wake_word]() {
                ContinueWakeWordInvoke(wake_word);
            });
            return;
        }
        // 通道已存在，复用连接但会新建会话
        ContinueWakeWordInvoke(wake_word);
    }
}

void Application::ContinueWakeWordInvoke(const std::string& wake_word) {
    // 打开音频通道（新建会话）
    if (!protocol_->OpenAudioChannel()) {
        // 失败处理：重新启用唤醒词检测
        audio_service_.EnableWakeWordDetection(true);
        return;
    }
    
    // 可选：发送唤醒词音频到服务器
#if CONFIG_SEND_WAKE_WORD_DATA
    while (auto packet = audio_service_.PopWakeWordPacket()) {
        protocol_->SendAudio(std::move(packet));
    }
    protocol_->SendWakeWordDetected(wake_word);
#endif
    
    // 开始监听（使用新会话）
    SetListeningMode(GetDefaultListeningMode());
}

// 场景2：手动停止对话
void Application::HandleStopListeningEvent() {
    if (state == kDeviceStateListening) {
        // 发送停止监听消息（带上当前session_id）
        protocol_->SendStopListening();
        
        // 关闭音频通道（结束当前会话）
        SetDeviceState(kDeviceStateIdle);
    }
}

// 场景3：打断当前对话（检测到新的唤醒词）
void Application::HandleWakeWordDetectedEvent() {
    if (state == kDeviceStateSpeaking || state == kDeviceStateListening) {
        // 打断当前播放
        AbortSpeaking(kAbortReasonWakeWordDetected);
        
        // 清空发送队列（旧会话的残留数据）
        while (audio_service_.PopPacketFromSendQueue());
        
        if (state == kDeviceStateListening) {
            // 如果正在监听，发送新的开始监听（复用同一会话）
            protocol_->SendStartListening(GetDefaultListeningMode());
            audio_service_.ResetDecoder();
        } else {
            // 如果正在播放，重新开始监听
            SetListeningMode(GetDefaultListeningMode());
        }
    }
}
```

### 连接复用策略

```
【连接复用场景】

时间轴 ──────────────────────────────────────────────→

用户操作:  [说"你好小智"] [对话结束] [说"你好小智"] [对话结束]
           ↑             ↑             ↑             ↑
网络连接:  [====建立====][============][============][====保持====]
           ↑             ↑             ↑             ↑
session:   [session_A]   [结束]        [session_B]   [结束]

说明：
- 连接建立后保持打开（直到超时或网络断开）
- 每次唤醒创建新session_id
- 多个session可复用同一连接


【连接断开场景】

时间轴 ──────────────────────────────────────────────→

网络状态:  [====连接====][断网...][恢复网络][====重连====]
           ↑             ↑       ↑         ↑
session:   [session_1]   [丢失]   [session_2]

说明：
- 网络断开时当前session丢失
- 恢复后用户需重新唤醒
- 新唤醒创建新session_id
```

### 超时与保活机制

```cpp
// 文件：protocol.cc 第81-90行

bool Protocol::IsTimeout() const {
    const int kTimeoutSeconds = 120;  // 2分钟超时
    auto now = std::chrono::steady_clock::now();
    auto duration = std::chrono::duration_cast<std::chrono::seconds>(
        now - last_incoming_time_);
    
    bool timeout = duration.count() > kTimeoutSeconds;
    if (timeout) {
        ESP_LOGE(TAG, "Channel timeout %ld seconds", (long)duration.count());
    }
    return timeout;
}

// 每次收到消息更新最后接收时间
void WebsocketProtocol::OnData(const char* data, size_t len, bool binary) {
    // ... 处理消息 ...
    last_incoming_time_ = std::chrono::steady_clock::now();  // 更新时间戳
}
```

**超时检测逻辑**：
```
IsAudioChannelOpened() = websocket_->IsConnected() 
                      && !error_occurred_ 
                      && !IsTimeout()  // 120秒内必须有消息往来
```

---

## 关键代码解析

### 1. 协议选择逻辑

```cpp
// 文件：application.cc 第480-487行

void Application::InitializeProtocol() {
    // 根据OTA配置选择协议
    if (ota_->HasMqttConfig()) {
        protocol_ = std::make_unique<MqttProtocol>();
    } else if (ota_->HasWebsocketConfig()) {
        protocol_ = std::make_unique<WebsocketProtocol>();
    } else {
        // 默认使用MQTT
        protocol_ = std::make_unique<MqttProtocol>();
    }
    
    // 设置回调
    protocol_->OnConnected([this]() { DismissAlert(); });
    protocol_->OnNetworkError([this](const std::string& message) {
        last_error_message_ = message;
        xEventGroupSetBits(event_group_, MAIN_EVENT_ERROR);
    });
    // ... 更多回调
}
```

### 2. 音频通道状态检查

```cpp
// 文件：application.cc 第789-799行

void Application::HandleWakeWordDetectedEvent() {
    // 关键检查：音频通道是否已打开
    if (!protocol_->IsAudioChannelOpened()) {
        // 未打开：需要新建连接和会话
        SetDeviceState(kDeviceStateConnecting);
        Schedule([this, wake_word]() {
            ContinueWakeWordInvoke(wake_word);
        });
    } else {
        // 已打开：复用连接，但会创建新会话
        ContinueWakeWordInvoke(wake_word);
    }
}
```

### 3. 会话结束时的清理

```cpp
// 文件：application.cc 第512-518行

protocol_->OnAudioChannelClosed([this, &board]() {
    // 1. 降低功耗（从性能模式切换到省电模式）
    board.SetPowerSaveLevel(PowerSaveLevel::LOW_POWER);
    
    // 2. 清理UI
    Schedule([this]() {
        auto display = Board::GetInstance().GetDisplay();
        display->SetChatMessage("system", "");  // 清空聊天消息
        SetDeviceState(kDeviceStateIdle);        // 回到待机状态
    });
});
```

### 4. 网络断开处理

```cpp
// 文件：application.cc 第286-297行

void Application::HandleNetworkDisconnectedEvent() {
    // 如果正在进行对话，关闭音频通道
    auto state = GetDeviceState();
    if (state == kDeviceStateConnecting || 
        state == kDeviceStateListening || 
        state == kDeviceStateSpeaking) {
        ESP_LOGI(TAG, "Closing audio channel due to network disconnection");
        protocol_->CloseAudioChannel();
    }
    
    // 更新UI显示网络断开
    auto display = Board::GetInstance().GetDisplay();
    display->UpdateStatusBar(true);
}
```

---

## 总结

**核心设计要点**：

1. **连接与会话分离**
   - 连接是物理通道（TCP/UDP），会话是逻辑上下文
   - 一个连接可承载多个会话，实现连接复用

2. **延迟连接策略**
   - 设备启动时不建立连接
   - 首次唤醒时才连接，节省电量

3. **会话ID由服务器生成**
   - 设备发送hello，服务器返回session_id
   - 所有消息必须携带session_id

4. **两种协议适配**
   - WebSocket：单连接全双工，适合实时对话
   - MQTT：控制+数据分离，适合物联网场景

5. **超时与保活**
   - 120秒无消息自动判定超时
   - MQTT支持自动重连

**代码路径速查**：

| 功能 | 文件路径 | 关键方法 |
|-----|---------|---------|
| 会话ID获取 | `main/protocols/websocket_protocol.cc` | `ParseServerHello()` |
| 消息发送 | `main/protocols/protocol.cc` | `SendWakeWordDetected()` 等 |
| 通道打开 | `main/protocols/websocket_protocol.cc` | `OpenAudioChannel()` |
| 通道关闭 | `main/protocols/mqtt_protocol.cc` | `CloseAudioChannel()` |
| 状态检查 | `main/protocols/websocket_protocol.cc` | `IsAudioChannelOpened()` |
| 应用层调用 | `main/application.cc` | `HandleWakeWordDetectedEvent()` |

**调试技巧**：

```cpp
// 查看当前session_id
ESP_LOGI(TAG, "Session ID: %s", protocol_->session_id().c_str());

// 检查通道状态
bool is_open = protocol_->IsAudioChannelOpened();
ESP_LOGI(TAG, "Audio channel opened: %s", is_open ? "yes" : "no");

// 监控网络消息
// 在 websocket_protocol.cc 的 OnData() 中添加日志
ESP_LOGI(TAG, "Received: %s", data);
```

---

## 扩展阅读

- [WebSocket协议详解](../websocket.md)
- [MCP协议说明](../mcp-protocol.md)
- [语音交互流程](./01-voice-interaction-flow.md)
- [设备适配指南](../custom-board.md)
