# OTA固件升级API

<cite>
**本文档引用的文件**
- [ota.h](file://main/ota.h)
- [ota.cc](file://main/ota.cc)
- [application.h](file://main/application.h)
- [application.cc](file://main/application.cc)
- [system_info.h](file://main/system_info.h)
- [system_info.cc](file://main/system_info.cc)
- [settings.h](file://main/settings.h)
- [device_state.h](file://main/device_state.h)
- [device_state_machine.h](file://main/device_state_machine.h)
- [8m.csv](file://partitions/v2/8m.csv)
- [16m.csv](file://partitions/v2/16m.csv)
- [32m.csv](file://partitions/v2/32m.csv)
</cite>

## 目录
1. [简介](#简介)
2. [项目结构](#项目结构)
3. [核心组件](#核心组件)
4. [架构概览](#架构概览)
5. [详细组件分析](#详细组件分析)
6. [依赖关系分析](#依赖关系分析)
7. [性能考虑](#性能考虑)
8. [故障排除指南](#故障排除指南)
9. [结论](#结论)
10. [附录](#附录)

## 简介

本文档提供了ESP32设备OTA（Over-The-Air）固件升级系统的完整API参考文档。该系统实现了从版本检查、固件下载到安装升级的完整流程，包含激活码系统、版本管理、升级流程控制、安全验证等核心技术。

OTA升级系统基于ESP-IDF框架构建，采用模块化设计，通过Ota类提供核心升级功能，Application类负责协调整个升级流程，SystemInfo类提供系统信息查询，Settings类管理配置参数。

## 项目结构

OTA固件升级系统主要由以下核心模块组成：

```mermaid
graph TB
subgraph "OTA升级系统架构"
Application[Application类<br/>主控制器]
Ota[Ota类<br/>核心升级模块]
SystemInfo[SystemInfo类<br/>系统信息]
Settings[Settings类<br/>配置管理]
subgraph "硬件抽象层"
Board[Board类<br/>板级抽象]
Network[Network类<br/>网络接口]
Http[Http类<br/>HTTP客户端]
end
subgraph "存储管理"
Partitions[分区管理<br/>OTA分区]
NVS[NVS闪存<br/>配置存储]
end
end
Application --> Ota
Ota --> SystemInfo
Ota --> Settings
Ota --> Board
Board --> Network
Network --> Http
Ota --> Partitions
Settings --> NVS
```

**图表来源**
- [ota.h](file://main/ota.h#L10-L56)
- [application.h](file://main/application.h#L42-L172)
- [system_info.h](file://main/system_info.h#L9-L21)

**章节来源**
- [ota.h](file://main/ota.h#L1-L59)
- [application.h](file://main/application.h#L1-L190)

## 核心组件

### Ota类 - 核心升级模块

Ota类是OTA升级系统的核心，提供完整的固件升级功能：

#### 主要接口
- `CheckVersion()` - 检查新版本
- `Activate()` - 设备激活
- `StartUpgrade()` - 开始升级
- `MarkCurrentVersionValid()` - 标记当前版本有效

#### 关键属性
- 版本管理：current_version_, firmware_version_
- 升级状态：has_new_version_, has_activation_challenge_
- 配置参数：activation_timeout_ms_
- 网络配置：has_mqtt_config_, has_websocket_config_

**章节来源**
- [ota.h](file://main/ota.h#L10-L56)
- [ota.cc](file://main/ota.cc#L28-L493)

### Application类 - 主控制器

Application类负责协调整个OTA升级流程，包括版本检查、激活码处理、协议初始化等：

#### 协调功能
- 版本检查循环
- 激活码显示和输入
- 升级流程控制
- 错误处理和重试机制

**章节来源**
- [application.h](file://main/application.h#L42-L172)
- [application.cc](file://main/application.cc#L323-L471)

## 架构概览

OTA升级系统采用分层架构设计，确保各组件职责清晰、耦合度低：

```mermaid
sequenceDiagram
participant App as Application
participant Ota as Ota
participant Server as 升级服务器
participant Storage as 存储系统
participant Protocol as 协议层
App->>Ota : CheckVersion()
Ota->>Server : GET /check-version
Server-->>Ota : 返回版本信息
Ota-->>App : 版本检查结果
App->>Ota : Activate() (如有激活码)
Ota->>Server : POST /activate
Server-->>Ota : 激活确认
App->>Ota : StartUpgrade()
Ota->>Server : 下载固件
Ota->>Storage : 写入OTA分区
Ota->>Storage : 设置启动分区
Ota-->>App : 升级完成
App->>Protocol : 初始化协议
Protocol-->>App : 连接成功
```

**图表来源**
- [application.cc](file://main/application.cc#L398-L471)
- [ota.cc](file://main/ota.cc#L77-L245)
- [ota.cc](file://main/ota.cc#L267-L387)

## 详细组件分析

### 版本检查流程

版本检查是OTA升级的第一步，系统会向服务器请求最新的固件信息：

```mermaid
flowchart TD
Start([开始版本检查]) --> GetVersionUrl[获取版本检查URL]
GetVersionUrl --> SetupHttp[设置HTTP头部]
SetupHttp --> CheckUrl{URL是否有效?}
CheckUrl --> |否| ReturnError[返回错误]
CheckUrl --> |是| OpenConnection[打开HTTP连接]
OpenConnection --> GetResponse[获取响应]
GetResponse --> ParseJSON[解析JSON响应]
ParseJSON --> CheckNewVersion{是否有新版本?}
CheckNewVersion --> |是| StoreInfo[存储版本信息]
CheckNewVersion --> |否| MarkValid[标记当前版本有效]
StoreInfo --> End([结束])
MarkValid --> End
ReturnError --> End
```

**图表来源**
- [ota.cc](file://main/ota.cc#L77-L245)

#### 版本比较算法

系统使用语义化版本比较算法，支持多级版本号比较：

```mermaid
flowchart TD
VersionCompare[版本比较] --> ParseCurrent[解析当前版本]
ParseCurrent --> ParseNew[解析新版本]
ParseNew --> CompareDigits[逐位比较]
CompareDigits --> CurrentDigit[当前版本数字]
CompareDigits --> NewDigit[新版本数字]
CurrentDigit --> DigitCompare{数字比较}
NewDigit --> DigitCompare
DigitCompare --> |新版本更大| NewVersionAvailable[有新版本]
DigitCompare --> |相等| NextDigit[比较下一位]
DigitCompare --> |当前版本更大| NoNewVersion[无新版本]
NextDigit --> MoreDigits{还有数字?}
MoreDigits --> |是| CompareDigits
MoreDigits --> |否| NewVersionLonger[新版本更长]
NewVersionAvailable --> End([结束])
NoNewVersion --> End
NewVersionLonger --> End
```

**图表来源**
- [ota.cc](file://main/ota.cc#L406-L419)

**章节来源**
- [ota.cc](file://main/ota.cc#L77-L245)
- [ota.cc](file://main/ota.cc#L394-L419)

### 固件下载与安装

固件下载采用流式传输方式，支持断点续传和完整性校验：

```mermaid
flowchart TD
DownloadStart[开始下载] --> GetPartition[获取OTA分区]
GetPartition --> OpenHTTP[打开HTTP连接]
OpenHTTP --> CheckStatus{状态码200?}
CheckStatus --> |否| DownloadError[下载失败]
CheckStatus --> |是| ReadLoop[读取数据循环]
ReadLoop --> BufferFull{缓冲区满?}
BufferFull --> |是| WriteFlash[写入Flash]
BufferFull --> |否| CheckEnd{是否最后一块?}
CheckEnd --> |否| ReadLoop
CheckEnd --> |是| EndDownload[结束下载]
WriteFlash --> VerifyImage{验证镜像}
VerifyImage --> |失败| ValidateError[验证失败]
VerifyImage --> |成功| SetBoot[设置启动分区]
SetBoot --> Success[升级成功]
DownloadError --> End([结束])
ValidateError --> End
Success --> End
```

**图表来源**
- [ota.cc](file://main/ota.cc#L267-L387)

#### 安全验证机制

系统实现了多层次的安全验证：

1. **HMAC签名验证**：使用ESP32的HMAC功能进行数据完整性验证
2. **OTA分区验证**：ESP-IDF内置的OTA镜像验证机制
3. **网络传输安全**：支持HTTPS传输
4. **设备身份验证**：基于序列号的设备识别

**章节来源**
- [ota.cc](file://main/ota.cc#L267-L387)
- [ota.cc](file://main/ota.cc#L421-L456)

### 激活码系统

激活码系统提供设备注册和授权功能：

```mermaid
sequenceDiagram
participant Device as 设备
participant Server as 服务器
participant User as 用户
Device->>Server : 请求激活挑战
Server-->>Device : 返回挑战信息
Device->>Device : 计算HMAC签名
Device->>Server : 提交激活请求
Server->>Server : 验证签名
Server-->>Device : 激活成功/失败
alt 激活成功
Device->>User : 显示激活码
User->>Device : 输入激活码
Device->>Server : 验证激活码
Server-->>Device : 最终激活确认
end
```

**图表来源**
- [ota.cc](file://main/ota.cc#L458-L492)

**章节来源**
- [ota.cc](file://main/ota.cc#L421-L456)
- [ota.cc](file://main/ota.cc#L458-L492)

### 升级流程控制

Application类负责协调整个升级流程，包括错误处理和重试机制：

```mermaid
stateDiagram-v2
[*] --> 检查版本
检查版本 --> 发现新版本 : 有新版本
检查版本 --> 无新版本 : 无新版本
发现新版本 --> 显示升级界面
显示升级界面 --> 执行升级
执行升级 --> 升级成功 : 成功
执行升级 --> 升级失败 : 失败
升级成功 --> 重启设备
升级失败 --> 错误处理
错误处理 --> 重试机制
重试机制 --> 发现新版本 : 重试成功
重试机制 --> 无新版本 : 重试失败
无新版本 --> 激活设备
激活设备 --> [*]
重启设备 --> [*]
```

**图表来源**
- [application.cc](file://main/application.cc#L398-L471)
- [application.cc](file://main/application.cc#L967-L1017)

**章节来源**
- [application.cc](file://main/application.cc#L398-L471)
- [application.cc](file://main/application.cc#L967-L1017)

## 依赖关系分析

OTA升级系统的关键依赖关系如下：

```mermaid
graph TB
subgraph "外部依赖"
ESP32[ESP32芯片]
ESP-IDF[ESP-IDF框架]
FreeRTOS[FreeRTOS操作系统]
end
subgraph "内部模块"
Ota[Ota类]
Application[Application类]
SystemInfo[SystemInfo类]
Settings[Settings类]
DeviceState[设备状态机]
end
subgraph "硬件接口"
Network[网络接口]
Flash[Flash存储]
NVS[NVS闪存]
end
ESP32 --> ESP-IDF
ESP-IDF --> FreeRTOS
Application --> Ota
Application --> DeviceState
Ota --> SystemInfo
Ota --> Settings
Ota --> Network
Ota --> Flash
Settings --> NVS
```

**图表来源**
- [ota.h](file://main/ota.h#L1-L59)
- [application.h](file://main/application.h#L1-L190)

**章节来源**
- [ota.h](file://main/ota.h#L1-L59)
- [application.h](file://main/application.h#L1-L190)

## 性能考虑

### 内存管理

OTA升级过程中的内存使用需要特别关注：

- **缓冲区大小**：使用4KB页面大小进行数据传输
- **堆栈使用**：升级过程中临时增加内存占用
- **碎片整理**：升级完成后进行内存碎片整理

### 网络优化

- **超时设置**：合理的HTTP连接超时和读取超时
- **重试策略**：指数退避的重试机制
- **带宽控制**：避免影响其他网络服务

### 存储优化

- **分区布局**：合理的OTA分区大小分配
- **磨损均衡**：在两个OTA分区间轮换使用
- **空间预留**：为系统运行预留足够的存储空间

## 故障排除指南

### 常见问题及解决方案

#### 版本检查失败
- **症状**：无法获取最新版本信息
- **原因**：网络连接问题、服务器响应异常
- **解决**：检查网络配置、查看日志输出、重试连接

#### 升级下载中断
- **症状**：下载过程中断
- **原因**：网络不稳定、服务器问题
- **解决**：启用自动重试、检查网络质量

#### 验证失败
- **症状**：升级后设备无法正常启动
- **原因**：固件损坏、验证失败
- **解决**：重新下载固件、检查存储空间

#### 激活失败
- **症状**：设备无法完成激活
- **原因**：激活码错误、HMAC计算失败
- **解决**：重新生成激活码、检查设备序列号

**章节来源**
- [ota.cc](file://main/ota.cc#L370-L377)
- [application.cc](file://main/application.cc#L408-L431)

## 结论

OTA固件升级系统提供了完整的设备远程升级解决方案，具有以下特点：

1. **安全性**：多重验证机制确保升级过程的安全性
2. **可靠性**：完善的错误处理和重试机制
3. **易用性**：简洁的API接口和清晰的升级流程
4. **可扩展性**：模块化设计便于功能扩展

该系统适用于各种ESP32设备的固件升级需求，为设备维护和功能更新提供了可靠的保障。

## 附录

### 配置参数说明

| 参数名称 | 类型 | 默认值 | 描述 |
|---------|------|--------|------|
| ota_url | 字符串 | 空 | OTA服务器地址 |
| activation_timeout_ms | 整数 | 30000 | 激活超时时间(毫秒) |
| retry_count | 整数 | 10 | 最大重试次数 |
| retry_delay | 整数 | 10 | 初始重试延迟(秒) |

### 系统要求

- **存储空间**：至少需要两个OTA分区的空间
- **网络要求**：稳定的网络连接，支持HTTP/HTTPS协议
- **电源要求**：升级过程中需要稳定的电源供应
- **时间窗口**：建议在设备空闲时进行升级

### 分区配置示例

不同容量的设备需要不同的分区配置：

```mermaid
graph LR
subgraph "8MB设备分区"
OTA0[ota_0: 3MB]
OTA1[ota_1: 3MB]
ASSETS[assets: 2MB]
end
subgraph "16MB设备分区"
OTA0_16[ota_0: 6MB]
OTA1_16[ota_1: 6MB]
ASSETS_16[assets: 8MB]
end
subgraph "32MB设备分区"
OTA0_32[ota_0: 4MB]
OTA1_32[ota_1: 4MB]
ASSETS_32[assets: 16MB]
end
```

**图表来源**
- [8m.csv](file://partitions/v2/8m.csv#L6-L7)
- [16m.csv](file://partitions/v2/16m.csv#L6-L7)
- [32m.csv](file://partitions/v2/32m.csv#L7-L8)