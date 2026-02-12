# XiaoZhi AI聊天交互完整流程

本文档详细介绍XiaoZhi从唤醒词检测到AI对话完成的整个技术流程，帮助理解这个2.5MB应用如何实现完整的AI语音交互能力。

## 目录
- [系统架构概览](#系统架构概览)
- [核心组件](#核心组件)
- [完整交互流程](#完整交互流程)
- [关键技术细节](#关键技术细节)
- [状态机设计](#状态机设计)

---

## 系统架构概览

XiaoZhi采用**边缘计算+云端协同**的架构：

```
┌─────────────────────────────────────────────────────────┐
│                    ESP32-S3 设备端                        │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌─────────┐ │
│  │唤醒词检测 │→ │音频采集  │→ │OPUS编码  │→ │网络传输 │ │
│  │(ESP-SR)  │  │(16kHz)   │  │(压缩)    │  │(WS/MQTT)│ │
│  └──────────┘  └──────────┘  └──────────┘  └─────────┘ │
│         ↑                                          ↓     │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌─────────┐ │
│  │LED指示   │← │LVGL显示  │← │OPUS解码  │← │音频接收 │ │
│  │状态管理  │  │表情动画  │  │TTS播放   │  │(流式)   │ │
│  └──────────┘  └──────────┘  └──────────┘  └─────────┘ │
└─────────────────────────────────────────────────────────┘
                           ↕ JSON + Binary Protocol
┌─────────────────────────────────────────────────────────┐
│                      云端服务                            │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌─────────┐ │
│  │ASR识别   │→ │LLM推理   │→ │TTS合成   │→ │流式传输 │ │
│  │(Qwen)    │  │(GPT/DS)  │  │(CosyVoice│  │(OPUS)   │ │
│  └──────────┘  └──────────┘  └──────────┘  └─────────┘ │
│                      ↕ MCP Protocol                      │
│  ┌──────────────────────────────────────────────────┐   │
│  │  设备侧MCP: LED/GPIO/传感器控制                   │   │
│  │  云侧MCP: 智能家居/PC操作/知识搜索                │   │
│  └──────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

**核心特性**：
- **离线唤醒**：本地ESP-SR模型，<100ms响应，无需联网
- **流式传输**：ASR、LLM、TTS全程流式处理，低延迟体验
- **双向音频**：16kHz采集 + 24kHz播放，OPUS压缩节省带宽
- **MCP协议**：设备能力与云端服务无缝集成

---

## 核心组件

### 1. WakeWord（唤醒词检测）

**实现类层次**：
```cpp
// 抽象基类：main/audio/wake_word.h
class WakeWord {
    virtual bool Initialize(AudioCodec* codec, srmodel_list_t* models_list) = 0;
    virtual void Feed(const std::vector<int16_t>& data) = 0;  // 喂入音频数据
    virtual void OnWakeWordDetected(callback) = 0;  // 检测回调
    virtual void Start() / Stop() = 0;
};

// 三种具体实现（根据配置自动选择）：
// 1. EspWakeWord    - 基于ESP-WN的基础唤醒（ESP32-C3/C6）
// 2. AfeWakeWord    - 基于ESP-AFE的高级唤醒（支持降噪/回声消除）
// 3. CustomWakeWord - 基于ESP-MN的自定义命令词识别
```

**工作原理**（以EspWakeWord为例）：

```cpp
// 文件：main/audio/wake_words/esp_wake_word.cc

void EspWakeWord::Feed(const std::vector<int16_t>& data) {
    std::lock_guard<std::mutex> lock(input_buffer_mutex_);
    
    // 1. 音频数据入队（双声道转单声道）
    if (codec_->input_channels() == 2) {
        for (size_t i = 0; i < data.size(); i += 2) {
            input_buffer_.push_back(data[i]);  // 只取左声道
        }
    }
    
    // 2. 滑动窗口检测（每次处理chunksize个样本，通常512）
    int chunksize = wakenet_iface_->get_samp_chunksize(wakenet_data_);
    while (input_buffer_.size() >= chunksize) {
        // 调用ESP-SR库检测
        int res = wakenet_iface_->detect(wakenet_data_, input_buffer_.data());
        
        if (res > 0) {  // 检测到唤醒词！
            // 3. 获取唤醒词名称（如"你好小智"）
            last_detected_wake_word_ = wakenet_iface_->get_word_name(wakenet_data_, res);
            running_ = false;
            
            // 4. 触发回调通知应用层
            if (wake_word_detected_callback_) {
                wake_word_detected_callback_(last_detected_wake_word_);
            }
            break;
        }
        
        // 移除已处理的数据，继续检测下一个窗口
        input_buffer_.erase(input_buffer_.begin(), input_buffer_.begin() + chunksize);
    }
}
```

**模型配置**（sdkconfig.defaults.esp32s3）：
```ini
# 第24行：选择唤醒词模型
CONFIG_SR_WN_WN9_NIHAOXIAOZHI_TTS=y  # "你好小智" 唤醒词

# 模型特点：
# - 大小：约200KB（INT8量化）
# - 准确率：>95%
# - 延迟：<100ms
# - 功耗：+10mW（持续监听）
```

---

### 2. AudioService（音频服务）

**职责**：统一管理音频采集、编码、解码、播放和唤醒词检测。

```cpp
// 文件：main/audio/audio_service.h

class AudioService {
public:
    // 初始化与启动
    void Initialize(AudioCodec* codec);
    void Start();
    
    // 唤醒词管理
    void SetModelsList(srmodel_list_t* models_list);
    void EnableWakeWordDetection(bool enable);
    std::string GetLastWakeWord();
    void EncodeWakeWord();  // 编码唤醒词音频用于上传
    
    // 语音处理
    void EnableVoiceProcessing(bool enable);  // 启动/停止录音+编码
    void PushPacketToDecodeQueue(std::unique_ptr<AudioStreamPacket> packet);  // TTS音频入队
    std::unique_ptr<AudioStreamPacket> PopPacketFromSendQueue();  // 获取待发送音频
    
    // 回调设置
    void SetCallbacks(AudioServiceCallbacks callbacks);
};
```

**回调机制**：
```cpp
// 文件：main/application.cc 第76-86行

AudioServiceCallbacks callbacks;

// 回调1：音频数据准备好发送
callbacks.on_send_queue_available = [this]() {
    xEventGroupSetBits(event_group_, MAIN_EVENT_SEND_AUDIO);
};

// 回调2：检测到唤醒词
callbacks.on_wake_word_detected = [this](const std::string& wake_word) {
    xEventGroupSetBits(event_group_, MAIN_EVENT_WAKE_WORD_DETECTED);
};

// 回调3：VAD检测到说话/静音状态变化
callbacks.on_vad_change = [this](bool speaking) {
    xEventGroupSetBits(event_group_, MAIN_EVENT_VAD_CHANGE);
};

audio_service_.SetCallbacks(callbacks);
```

---

### 3. DeviceStateMachine（状态机）

**设备状态定义**（main/device_state.h）：
```cpp
enum DeviceState {
    kDeviceStateUnknown,         // 未知状态
    kDeviceStateStarting,        // 启动中
    kDeviceStateWifiConfiguring, // WiFi配置中
    kDeviceStateIdle,            // 空闲待机（唤醒词监听中）
    kDeviceStateConnecting,      // 连接服务器中
    kDeviceStateListening,       // 录音监听中（用户说话）
    kDeviceStateSpeaking,        // 播放TTS中（AI回答）
    kDeviceStateUpgrading,       // OTA升级中
    kDeviceStateActivating,      // 设备激活中
    kDeviceStateAudioTesting,    // 音频测试中
    kDeviceStateFatalError       // 致命错误
};
```

**状态转换验证**：
```cpp
// 文件：main/device_state_machine.cc

bool DeviceStateMachine::IsValidTransition(DeviceState from, DeviceState to) const {
    // 定义合法的状态转换规则，例如：
    // - Idle → Connecting → Listening → Speaking → Idle
    // - Speaking 时检测到唤醒词 → 直接回到 Listening（打断）
    // - 任意状态 → FatalError（错误处理）
}
```

---

### 4. Protocol（通信协议）

**支持两种协议**：
1. **WebSocket**（推荐）：全双工，低延迟，适合实时对话
2. **MQTT + UDP**：MQTT传控制消息，UDP传音频数据

**消息格式**（文件：main/protocols/protocol.h）：
```cpp
// JSON消息结构
{
    "session_id": "xxx",  // 会话ID
    "type": "listen",     // 消息类型：listen/tts/stt/llm/mcp/system
    "state": "detect",    // 状态：detect/start/stop
    "text": "你好小智"    // 附加数据
}

// 音频二进制协议（Protocol v3，最紧凑）
struct BinaryProtocol3 {
    uint8_t  type;           // 0=OPUS音频
    uint16_t payload_size;   // 负载大小
    uint8_t  payload[];      // OPUS音频数据
} __attribute__((packed));
```

---

## 完整交互流程

### 阶段1：待机监听（Idle）

```
┌──────────────────────────────────────────────┐
│ 1. 麦克风持续采集音频（16kHz, 16bit PCM）      │
│    ├─ 硬件：ESP32-S3内置ADC或外部CODEC         │
│    └─ 缓冲：每次读取512样本（32ms）            │
└──────────────────────────────────────────────┘
                  ↓
┌──────────────────────────────────────────────┐
│ 2. 音频数据喂入WakeWord检测器                 │
│    代码：audio_service.cc → wake_word_->Feed()│
└──────────────────────────────────────────────┘
                  ↓
┌──────────────────────────────────────────────┐
│ 3. ESP-SR本地检测（无需联网）                 │
│    ├─ 提取MFCC特征（梅尔频率倒谱系数）         │
│    ├─ 通过量化神经网络（3层CNN）               │
│    ├─ 匹配置信度 > 95% → 检测成功！           │
│    └─ 资源占用：50KB内存 + 20% CPU            │
└──────────────────────────────────────────────┘
                  ↓
┌──────────────────────────────────────────────┐
│ 4. 触发回调 → Application处理                │
│    代码：application.cc:HandleWakeWordDetected│
└──────────────────────────────────────────────┘
```

**关键代码路径**：
```cpp
// 1. AudioService持续采集音频
void AudioService::ReadTask() {
    while (running_) {
        codec_->Read(input_buffer_.data(), samples_to_read);
        
        // 喂入唤醒词检测器
        if (wake_word_ && wake_word_detection_enabled_) {
            wake_word_->Feed(input_buffer_);
        }
    }
}

// 2. 检测到唤醒词后触发事件
callbacks.on_wake_word_detected = [this](const std::string& wake_word) {
    xEventGroupSetBits(event_group_, MAIN_EVENT_WAKE_WORD_DETECTED);
};

// 3. Application主循环接收事件
void Application::Run() {
    while (true) {
        auto bits = xEventGroupWaitBits(event_group_, ALL_EVENTS, ...);
        
        if (bits & MAIN_EVENT_WAKE_WORD_DETECTED) {
            HandleWakeWordDetectedEvent();  // ← 处理唤醒
        }
    }
}
```

---

### 阶段2：唤醒响应（Wake → Connecting）

```cpp
// 文件：application.cc 第776行
void Application::HandleWakeWordDetectedEvent() {
    auto state = GetDeviceState();
    auto wake_word = audio_service_.GetLastWakeWord();  // "你好小智"
    ESP_LOGI(TAG, "Wake word detected: %s", wake_word.c_str());
    
    if (state == kDeviceStateIdle) {
        // 1. 编码唤醒词音频（可选，用于上传到服务器）
        audio_service_.EncodeWakeWord();
        
        // 2. 检查音频通道是否已打开
        if (!protocol_->IsAudioChannelOpened()) {
            // 3. 状态转换：Idle → Connecting
            SetDeviceState(kDeviceStateConnecting);
            
            // 4. 异步打开音频通道（避免阻塞主线程）
            Schedule([this, wake_word]() {
                ContinueWakeWordInvoke(wake_word);
            });
            return;
        }
        
        // 通道已打开，直接继续
        ContinueWakeWordInvoke(wake_word);
    }
    
    // 如果正在Speaking/Listening，打断当前对话重新开始
    else if (state == kDeviceStateSpeaking || state == kDeviceStateListening) {
        AbortSpeaking(kAbortReasonWakeWordDetected);
        // ... 重新开始监听
    }
}
```

**网络连接过程**：
```cpp
void Application::ContinueWakeWordInvoke(const std::string& wake_word) {
    // 1. 打开WebSocket/MQTT音频通道
    if (!protocol_->OpenAudioChannel()) {
        audio_service_.EnableWakeWordDetection(true);  // 失败则重新启用检测
        return;
    }
    
    // 2. 发送唤醒词数据到服务器（可选）
#if CONFIG_SEND_WAKE_WORD_DATA
    while (auto packet = audio_service_.PopWakeWordPacket()) {
        protocol_->SendAudio(std::move(packet));  // 发送唤醒词前后的音频
    }
    protocol_->SendWakeWordDetected(wake_word);  // JSON消息通知服务器
#endif
    
    // 3. 设置监听模式并开始录音
    SetListeningMode(GetDefaultListeningMode());  // → 状态转为 Listening
}
```

**服务器接收到的JSON消息**：
```json
{
    "session_id": "abc123",
    "type": "listen",
    "state": "detect",
    "text": "你好小智"
}
```

---

### 阶段3：录音监听（Listening）

**状态切换处理**：
```cpp
// 文件：application.cc 第878行
void Application::HandleStateChangedEvent() {
    switch (new_state) {
        case kDeviceStateListening:
            display->SetStatus(Lang::Strings::LISTENING);  // UI显示"正在聆听"
            display->SetEmotion("neutral");
            
            // 1. 发送开始监听命令到服务器
            protocol_->SendStartListening(listening_mode_);
            
            // 2. 启动音频处理管道
            audio_service_.EnableVoiceProcessing(true);
            //   ├─ 启动VAD（Voice Activity Detection，人声检测）
            //   ├─ 启动OPUS编码器（压缩音频）
            //   └─ 启动发送队列
            
            // 3. 播放提示音
            audio_service_.PlaySound(Lang::Sounds::OGG_POPUP);  // "嘀"
            break;
    }
}
```

**服务器接收到的JSON消息**：
```json
{
    "session_id": "abc123",
    "type": "listen",
    "state": "start",
    "mode": "auto"  // auto=VAD自动停止, manual=手动停止, realtime=实时模式
}
```

**音频上传流程**：
```
┌─────────────────────────────────────────────┐
│ 麦克风采集 (16kHz PCM)                       │
│   └─ 每32ms读取512样本                       │
└─────────────────────────────────────────────┘
                 ↓
┌─────────────────────────────────────────────┐
│ VAD检测（人声活动检测）                      │
│   ├─ 检测到说话 → 发送音频                  │
│   └─ 静音超过1秒 → 自动停止（auto模式）     │
└─────────────────────────────────────────────┘
                 ↓
┌─────────────────────────────────────────────┐
│ OPUS编码（压缩）                             │
│   ├─ 比特率：24kbps                         │
│   ├─ 压缩比：约6:1                          │
│   └─ 每60ms一帧（约180字节）                │
└─────────────────────────────────────────────┘
                 ↓
┌─────────────────────────────────────────────┐
│ 网络发送（WebSocket二进制帧）                │
│   ├─ 协议：BinaryProtocol3                  │
│   ├─ 频率：每60ms发送一次                   │
│   └─ 带宽：~3KB/s（远低于原始PCM的32KB/s）  │
└─────────────────────────────────────────────┘
```

**应用层代码**：
```cpp
// 主事件循环处理音频发送
if (bits & MAIN_EVENT_SEND_AUDIO) {
    // 从发送队列取出编码好的音频包
    while (auto packet = audio_service_.PopPacketFromSendQueue()) {
        // 通过WebSocket/MQTT发送到服务器
        if (protocol_ && !protocol_->SendAudio(std::move(packet))) {
            break;  // 发送失败则停止
        }
    }
}
```

---

### 阶段4：云端处理（ASR → LLM → TTS）

**服务器端流式处理**（XiaoZhi云端架构）：

```
接收OPUS音频流
     ↓
┌──────────────────┐
│ 1. 流式ASR       │  Qwen-ASR / OpenAI Whisper
│    实时语音转文字 │  每收到一段音频即返回部分识别结果
└──────────────────┘
     ↓ 发送 {"type":"stt", "text":"今天天气怎么样"}
┌──────────────────┐
│ 2. 流式LLM推理   │  GPT-4 / DeepSeek / Qwen
│    生成AI回答    │  逐Token流式返回
└──────────────────┘
     ↓ 发送 {"type":"llm", "emotion":"happy", "text":"😀"}
┌──────────────────┐
│ 3. 流式TTS合成   │  CosyVoice / Azure TTS
│    文字转语音    │  边合成边发送OPUS音频帧
└──────────────────┘
     ↓ 发送 {"type":"tts", "state":"start"}
     ↓ 发送二进制OPUS音频帧...
     ↓ 发送 {"type":"tts", "state":"sentence_start", "text":"今天天气晴朗"}
     ↓ 发送 {"type":"tts", "state":"stop"}
```

**设备端接收处理**：
```cpp
// 文件：application.cc 第521行
protocol_->OnIncomingJson([this, display](const cJSON* root) {
    auto type = cJSON_GetObjectItem(root, "type");
    
    // 1. 接收ASR识别结果
    if (strcmp(type->valuestring, "stt") == 0) {
        auto text = cJSON_GetObjectItem(root, "text");
        ESP_LOGI(TAG, ">> %s", text->valuestring);  // 日志：">> 今天天气怎么样"
        
        // 显示在屏幕上
        Schedule([display, message = std::string(text->valuestring)]() {
            display->SetChatMessage("user", message.c_str());
        });
    }
    
    // 2. 接收LLM情感提示
    else if (strcmp(type->valuestring, "llm") == 0) {
        auto emotion = cJSON_GetObjectItem(root, "emotion");
        Schedule([display, emotion_str = std::string(emotion->valuestring)]() {
            display->SetEmotion(emotion_str.c_str());  // 切换表情动画
        });
    }
    
    // 3. 接收TTS控制消息
    else if (strcmp(type->valuestring, "tts") == 0) {
        auto state = cJSON_GetObjectItem(root, "state");
        
        if (strcmp(state->valuestring, "start") == 0) {
            // TTS开始 → 状态切换为 Speaking
            Schedule([this]() {
                SetDeviceState(kDeviceStateSpeaking);
            });
        }
        else if (strcmp(state->valuestring, "sentence_start") == 0) {
            // 显示当前播放的句子
            auto text = cJSON_GetObjectItem(root, "text");
            ESP_LOGI(TAG, "<< %s", text->valuestring);  // 日志："<< 今天天气晴朗"
            Schedule([display, message = std::string(text->valuestring)]() {
                display->SetChatMessage("assistant", message.c_str());
            });
        }
        else if (strcmp(state->valuestring, "stop") == 0) {
            // TTS结束 → 根据模式决定下一步
            Schedule([this]() {
                if (listening_mode_ == kListeningModeManualStop) {
                    SetDeviceState(kDeviceStateIdle);  // 手动模式：回到待机
                } else {
                    SetDeviceState(kDeviceStateListening);  // 自动模式：继续监听
                }
            });
        }
    }
    
    // 4. 接收MCP控制指令
    else if (strcmp(type->valuestring, "mcp") == 0) {
        auto payload = cJSON_GetObjectItem(root, "payload");
        McpServer::GetInstance().ParseMessage(payload);
        // 例如：{"method":"tools/call", "params":{"name":"self.light.set_rgb", ...}}
    }
});
```

---

### 阶段5：TTS播放（Speaking）

**音频接收与解码**：
```cpp
// 接收二进制OPUS音频帧
protocol_->OnIncomingAudio([this](std::unique_ptr<AudioStreamPacket> packet) {
    if (GetDeviceState() == kDeviceStateSpeaking) {
        // 将音频包推入解码队列
        audio_service_.PushPacketToDecodeQueue(std::move(packet));
    }
});
```

**AudioService内部处理**：
```
┌─────────────────────────────────────────────┐
│ 1. 解码队列接收OPUS音频包                    │
│    └─ 服务器每60ms发送一帧（~180字节）       │
└─────────────────────────────────────────────┘
                 ↓
┌─────────────────────────────────────────────┐
│ 2. OPUS解码器（多线程）                      │
│    ├─ 输入：24kHz OPUS音频                   │
│    ├─ 输出：24kHz PCM音频                    │
│    └─ 延迟：<10ms                            │
└─────────────────────────────────────────────┘
                 ↓
┌─────────────────────────────────────────────┐
│ 3. 播放队列缓冲                              │
│    └─ 缓冲约300ms音频，平滑网络抖动          │
└─────────────────────────────────────────────┘
                 ↓
┌─────────────────────────────────────────────┐
│ 4. I2S播放输出                               │
│    ├─ 硬件：ESP32-S3内置DAC或外部CODEC       │
│    ├─ 采样率：24kHz                          │
│    └─ 音量控制：软件+硬件混合                │
└─────────────────────────────────────────────┘
```

**状态管理**：
```cpp
case kDeviceStateSpeaking:
    display->SetStatus(Lang::Strings::SPEAKING);  // UI显示"正在回答"
    
    // 停止录音（非实时模式）
    if (listening_mode_ != kListeningModeRealtime) {
        audio_service_.EnableVoiceProcessing(false);
        
        // 但保持唤醒词检测（AFE模式可以边播放边检测）
        audio_service_.EnableWakeWordDetection(audio_service_.IsAfeWakeWord());
    }
    
    // 清空解码器缓冲
    audio_service_.ResetDecoder();
    break;
```

---

### 阶段6：对话结束（Speaking → Idle/Listening）

**三种结束模式**：

1. **手动模式（Manual Stop）**：
   ```cpp
   // TTS播放完成后回到Idle，等待下一次唤醒
   SetDeviceState(kDeviceStateIdle);
   audio_service_.EnableWakeWordDetection(true);  // 重新启用唤醒词检测
   ```

2. **自动模式（Auto Stop）**：
   ```cpp
   // TTS播放完成后继续监听，实现多轮对话
   SetDeviceState(kDeviceStateListening);
   protocol_->SendStartListening(kListeningModeAutoStop);
   ```

3. **实时模式（Realtime）**：
   ```cpp
   // 全程保持Listening状态，边说边听（全双工）
   // 用于需要打断的场景，如语音助手
   ```

**打断机制**：
```cpp
// 播放TTS时检测到唤醒词 → 立即打断
if (state == kDeviceStateSpeaking) {
    AbortSpeaking(kAbortReasonWakeWordDetected);
    
    // 发送打断通知到服务器
    protocol_->SendAbortSpeaking(kAbortReasonWakeWordDetected);
    // → {"type":"abort", "reason":"wake_word_detected"}
    
    // 清空所有音频缓冲
    while (audio_service_.PopPacketFromSendQueue());
    
    // 播放提示音并重新开始监听
    audio_service_.PlaySound(Lang::Sounds::OGG_POPUP);
    SetListeningMode(GetDefaultListeningMode());
}
```

---

## 关键技术细节

### 1. 为什么唤醒词检测这么快？

**秘密在于三个优化**：

#### ① 量化神经网络
```
原始模型（Float32）：    50MB
↓ INT8量化
量化模型（INT8）：        200KB  ← 体积缩小250倍
↓ 精度损失
识别准确率：            95.2% → 95.0%  ← 几乎无损
```

**量化原理**：
```python
# 浮点权重：-1.234567 ~ +3.456789
# INT8映射：-128 ~ +127 (256个刻度)

scale = (max_val - min_val) / 255
zero_point = -min_val / scale

quantized_value = round(float_value / scale) + zero_point
```

#### ② 关键词检测（Keyword Spotting）
```
完整ASR：识别任意语音 → 需要庞大词典（数十万词）+ 语言模型
   ↓ 简化
关键词检测：只识别"你好小智" → 极简模型（只学这4个字的声学特征）
```

**模型结构**（ESP-WN9）：
```
输入：MFCC特征（39维 × 31帧 = 1209维）
  ↓
3层卷积神经网络（CNN）
  ├─ Conv1: 64 filters, 3×3 kernel
  ├─ Conv2: 128 filters, 3×3 kernel
  └─ Conv3: 256 filters, 3×3 kernel
  ↓
全连接层 + Softmax
  ↓
输出：[0.02, 0.03, 0.94, 0.01]  ← 第3个类别概率94% = 检测到！
```

#### ③ ESP32-S3硬件加速
```
Xtensa LX7处理器特性：
├─ SIMD指令：一次处理4个INT8乘法
├─ MAC单元：专用乘加运算（矩阵运算核心）
└─ 240MHz主频：足够实时处理16kHz音频

实测性能：
├─ 推理延迟：<50ms
├─ CPU占用：单核20%
└─ 内存占用：50KB（模型30KB + 缓冲20KB）
```

---

### 2. 音频编解码为什么选OPUS？

**对比各种编解码器**：

| 编解码器 | 比特率 | 延迟 | CPU占用 | 音质 | 带宽(16kHz) |
|---------|--------|------|---------|------|-------------|
| **PCM** | 256kbps| 0ms  | 0%      | 无损 | 32KB/s      |
| **MP3** | 128kbps| 100ms| 高      | 一般 | 16KB/s      |
| **AAC** | 64kbps | 80ms | 中      | 好   | 8KB/s       |
| **OPUS**| 24kbps | 20ms | 低      | 优秀 | **3KB/s**   |

**OPUS优势**：
1. **低延迟**：20ms编码延迟（MP3需要100ms+）
2. **低比特率**：24kbps即可达到电话音质
3. **自适应**：根据网络状况动态调整比特率
4. **低功耗**：ARM优化，ESP32轻松运行

**ESP32上的OPUS性能**：
```cpp
// 编码参数（audio_service.cc）
opus_encoder_ctl(encoder_, OPUS_SET_BITRATE(24000));      // 24kbps
opus_encoder_ctl(encoder_, OPUS_SET_COMPLEXITY(5));       // 复杂度5（0-10）
opus_encoder_ctl(encoder_, OPUS_SET_VBR(1));              // 可变比特率
opus_encoder_ctl(encoder_, OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE)); // 语音优化

实测数据：
├─ 编码：16kHz PCM → 24kbps OPUS，耗时 3ms
├─ 解码：24kbps OPUS → 24kHz PCM，耗时 5ms
└─ 带宽节省：32KB/s → 3KB/s（节省90%）
```

---

### 3. 流式传输如何保证低延迟？

**端到端延迟分解**：

```
用户说话 → 云端回答（总延迟：<500ms）
│
├─ [设备端] 音频采集             32ms   (512样本 @ 16kHz)
├─ [设备端] OPUS编码             3ms
├─ [网络]   上行传输             50ms   (4G网络典型值)
├─ [云端]   流式ASR识别          100ms  (每收到3帧即返回结果)
├─ [云端]   LLM推理（首Token）   150ms  (GPT-4o / DeepSeek)
├─ [云端]   TTS合成（首音频）    100ms  (CosyVoice)
├─ [网络]   下行传输             50ms
├─ [设备端] OPUS解码             5ms
└─ [设备端] 播放缓冲             10ms
───────────────────────────────────────
总计：约500ms（用户感知 < 0.5秒）
```

**关键优化技巧**：

#### ① 流式ASR（Streaming ASR）
```python
# 传统ASR：等待完整语音 → 一次性识别
# 延迟：2-5秒

# 流式ASR：边收边识别
def streaming_asr(audio_stream):
    partial_text = ""
    for chunk in audio_stream:  # 每60ms一帧
        partial_text = asr_model.decode_partial(chunk)
        send_to_device({"type":"stt", "text": partial_text})  # 实时发送部分结果
```

#### ② 流式LLM（Streaming LLM）
```python
# 传统LLM：生成完整回答 → 一次性返回
# 延迟：5-10秒

# 流式LLM：逐Token生成
response = llm.stream_chat(messages)
for token in response:  # 每生成一个字就发送
    send_token_to_tts(token)  # 立即送入TTS
```

#### ③ 流式TTS（Streaming TTS）
```python
# 传统TTS：合成完整音频 → 一次性播放
# 延迟：3-5秒

# 流式TTS：边合成边发送
def streaming_tts(text_stream):
    for sentence in text_stream:  # 每收到一句话
        audio_chunk = tts_model.synthesize(sentence)
        send_audio_to_device(audio_chunk)  # 立即发送OPUS帧
```

---

### 4. 状态机如何保证线程安全？

**挑战**：多个线程同时修改设备状态会导致竞态条件。

**解决方案**：原子操作 + 事件驱动

```cpp
// 文件：device_state_machine.h

class DeviceStateMachine {
private:
    // 使用原子变量保证状态读写的线程安全
    std::atomic<DeviceState> current_state_{kDeviceStateUnknown};
    
    std::vector<std::pair<int, StateCallback>> listeners_;
    std::mutex mutex_;  // 保护listeners_
};

// 状态转换方法
bool DeviceStateMachine::TransitionTo(DeviceState new_state) {
    DeviceState old_state = current_state_.load();  // 原子读取
    
    // 1. 验证转换是否合法
    if (!IsValidTransition(old_state, new_state)) {
        ESP_LOGW(TAG, "Invalid state transition: %s → %s",
                 GetStateName(old_state), GetStateName(new_state));
        return false;
    }
    
    // 2. 原子更新状态
    current_state_.store(new_state);
    
    // 3. 通知所有监听器（加锁保护）
    {
        std::lock_guard<std::mutex> lock(mutex_);
        for (auto& [id, callback] : listeners_) {
            callback(old_state, new_state);
        }
    }
    
    return true;
}
```

**为什么用事件驱动而不是直接回调？**

```cpp
// ❌ 错误做法：直接在中断中调用状态转换
void IRAM_ATTR button_isr_handler(void* arg) {
    Application* app = (Application*)arg;
    app->SetDeviceState(kDeviceStateListening);  // 危险！ISR中不能执行复杂操作
}

// ✅ 正确做法：ISR只设置事件标志
void IRAM_ATTR button_isr_handler(void* arg) {
    Application* app = (Application*)arg;
    xEventGroupSetBitsFromISR(app->event_group_, MAIN_EVENT_START_LISTENING, NULL);
}

// 主任务循环处理事件
void Application::Run() {
    while (true) {
        auto bits = xEventGroupWaitBits(event_group_, ...);
        
        if (bits & MAIN_EVENT_START_LISTENING) {
            HandleStartListeningEvent();  // 在任务上下文安全执行
        }
    }
}
```

---

## 状态机设计

### 状态转换图

```mermaid
stateDiagram-v2
    [*] --> Starting: 上电启动
    Starting --> WifiConfiguring: WiFi未配置
    Starting --> Activating: 网络连接成功
    
    WifiConfiguring --> AudioTesting: 按键测试音频
    AudioTesting --> WifiConfiguring: 再次按键
    WifiConfiguring --> Activating: WiFi配置完成
    
    Activating --> Idle: 激活完成
    Activating --> Idle: 检测到唤醒词（跳过激活）
    
    Idle --> Connecting: 唤醒词检测 / 按键触发
    Connecting --> Listening: 音频通道打开
    Connecting --> Idle: 连接失败
    
    Listening --> Speaking: 收到TTS开始
    Listening --> Idle: 手动停止 / 超时
    
    Speaking --> Listening: TTS结束（自动模式）
    Speaking --> Idle: TTS结束（手动模式）
    Speaking --> Listening: 检测到唤醒词（打断）
    
    Idle --> Upgrading: 发现新固件
    Upgrading --> [*]: 升级成功重启
    Upgrading --> Idle: 升级失败
    
    任意状态 --> FatalError: 严重错误
    FatalError --> [*]: 需要重启
```

### 状态转换验证规则

```cpp
// 文件：device_state_machine.cc

bool DeviceStateMachine::IsValidTransition(DeviceState from, DeviceState to) const {
    // 允许任意状态转为FatalError
    if (to == kDeviceStateFatalError) return true;
    
    // 允许任意状态转为自身（重入）
    if (from == to) return true;
    
    // 定义合法转换矩阵
    static const std::map<DeviceState, std::vector<DeviceState>> valid_transitions = {
        {kDeviceStateStarting, {
            kDeviceStateWifiConfiguring,
            kDeviceStateActivating,
            kDeviceStateIdle
        }},
        {kDeviceStateIdle, {
            kDeviceStateConnecting,
            kDeviceStateActivating,
            kDeviceStateUpgrading,
            kDeviceStateWifiConfiguring
        }},
        {kDeviceStateConnecting, {
            kDeviceStateListening,
            kDeviceStateIdle
        }},
        {kDeviceStateListening, {
            kDeviceStateSpeaking,
            kDeviceStateIdle,
            kDeviceStateConnecting  // 重新连接
        }},
        {kDeviceStateSpeaking, {
            kDeviceStateListening,  // 多轮对话
            kDeviceStateIdle
        }},
        // ... 更多规则
    };
    
    auto it = valid_transitions.find(from);
    if (it != valid_transitions.end()) {
        auto& allowed = it->second;
        return std::find(allowed.begin(), allowed.end(), to) != allowed.end();
    }
    
    return false;  // 默认禁止未定义的转换
}
```

---

## 总结

**XiaoZhi的技术亮点**：

1. **边缘AI**：200KB模型实现离线唤醒，<100ms响应
2. **流式架构**：ASR+LLM+TTS全流式，端到端延迟<500ms
3. **高效编码**：OPUS压缩节省90%带宽，24kbps电话音质
4. **状态机设计**：原子操作+事件驱动，线程安全
5. **MCP协议**：设备能力与云端服务无缝集成

**代码路径速查**：

| 功能 | 文件路径 | 关键方法 |
|-----|---------|---------|
| 唤醒词检测 | `main/audio/wake_words/esp_wake_word.cc` | `Feed()`, `detect()` |
| 音频服务 | `main/audio/audio_service.cc` | `EnableVoiceProcessing()` |
| 状态管理 | `main/device_state_machine.cc` | `TransitionTo()` |
| 主应用 | `main/application.cc` | `HandleWakeWordDetectedEvent()` |
| 协议层 | `main/protocols/websocket_protocol.cc` | `OnIncomingJson()` |

**性能数据**：

```
应用体积：     2.5MB
模型体积：     200KB (唤醒词) + 300KB (资源)
内存占用：     ~150KB (运行时峰值)
CPU占用：      20% (唤醒检测) + 30% (录音编码)
网络带宽：     上行3KB/s, 下行6KB/s
端到端延迟：   <500ms (唤醒到首次TTS播放)
功耗：         待机10mW, 对话时200mW
```

---

## 扩展阅读

- [ESP-SR官方文档](https://github.com/espressif/esp-sr)
- [OPUS编解码器规范](https://opus-codec.org/)
- [WebSocket协议详解](../websocket.md)
- [MCP协议说明](../mcp-protocol.md)
- [设备适配指南](../custom-board.md)
