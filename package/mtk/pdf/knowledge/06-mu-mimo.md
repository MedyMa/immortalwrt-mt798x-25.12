# MU-MIMO：能力、波束成形与有效测试

文档 ID：`mu-mimo`。来源：`MT7996 MU-MIMO Application Note v1.0.pdf`，12 页，2023-06-20。重点：第 4–6、8–11 页。

## 依赖关系

DL MU-MIMO 依赖显式波束成形：BFer 发送 NDPA/NDP，BFee 回报信道信息，发送端据此生成 steering matrix。UL MU-MIMO 通过触发机制允许多个 STA 在相同频率资源并发发送；与按 RU 分配频率资源的 OFDMA 不同，也不是“多连接数量”开关。

第 8–9 页的配置组合包括 `ETxBfEnCond=1`、`MUTxRxEnable=1`、`MuMimoDlEnable`、`MuMimoUlEnable`、BA 设置和 TX/RX stream 数。文档示例使用 4 streams，不能覆盖 BE14 的 EEPROM 限制。当前用户日志显示各频段 2/3/3 streams 是该设备观测值，而非所有 MT7990 的固定能力。

## 当前实现与配置层

`mt_wifi/profiles/cmm_profile.c` 分别解析 `MuMimoDlEnable` 与 `MuMimoUlEnable`，需要继续追踪工作设备配置、BSS 特性及 firmware ACK。profile 中为 1 不足以证明 MU 调度已经发生；连接客户端也必须声明对应能力。

当前 WEXT 配置链和文档的 cfg80211/mwctl 示例不同。可以复用 profile 语义及测试方法，不能仅根据文档把用户态框架换成 hostapd，也不能把 PP MU/OFDMA 初始化失败解释为全部 MU 能力永久失效。

## 验证设计与帮助

第 10–11 页要求相应 MU 能力客户端、明确上下行方向和可控干扰；它建议近距离视距环境及客户端分开摆放。其 RSSI 文字同时出现“优于 -46 dBm”及 -34 至 -55 dBm 的建议区间，应视为实验设置而非严格阈值。

有效验证应观察 MU PPDU/调度计数、总与单 STA 吞吐、重传及延迟，保持包大小、带宽和流量方向一致。单客户端跑满链路不能证明 MU 已生效。可用于页面能力提示、避免强制超出硬件 NSS、建立 MU/OFDMA/Beamforming 独立的测试矩阵；不适合做“所有终端开启后必然提速”的默认宣传。
