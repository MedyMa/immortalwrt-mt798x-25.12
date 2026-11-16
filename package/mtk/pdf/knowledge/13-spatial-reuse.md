# Spatial Reuse：OBSS、E-SR 与 Mesh 的区别

文档 ID：`spatial-reuse`。来源：`MT7996 Spatial Reuse Application Note v1.1 (1).pdf`，25 页。第 2 页修订至 1.1（2023-06-29），封面仍写 1.0。重点：第 4–24 页。

## 机制和附加约束

SR 先用 BSS color 或 BSSID/MAC 判定其他 BSS，再比较 OBSS 信号与 PD 门限，符合条件时终止该接收并发起并发发送。它不是一般意义的 MU-MIMO/空间流增多。第 4 页的概述较宽泛，应以第 6 页的具体判定过程为准。

第 7–12 页描述 MTK 附加机制：独立 SR 速率控制、与 OBSS PPDU 对齐以减少碰撞、对 legacy HT/VHT 干扰的 E-SR。速率偏移、暂时黑名单、每 20 MHz RSSI 和 antenna offset 都属于算法条件，不能只根据总 RSSI 一个数判断 SR 必须生效。

## 模式与文档之间的区别

第 13–16 页以 `SREnable` 开关，`SRDPDEnable=0/1` 区分 normal/performance 示例。normal 示例 OBSS PD 为 -62 dBm，performance 使用动态门限；它不是任意放宽 EDCCA 的许可。

第 16–17 页建议普通 Multi-AP 环境关闭 standalone SR/SCS。但更晚的 Multi-AP 文档第 121–127 页新增 Mesh No-SR、SRG Protect、Mesh SR 三阶段协同，不能把旧说明改成“所有 Mesh 永远不能 SR”，也不能把 standalone SR 当作已实现 Mesh SR。需要 MAPD、拓扑、BSS color/SRG 信息和对应固件一起工作。

当前 `mt_wifi/profiles/cmm_profile.c` 可检索 `SREnable`、`SRDPDEnable`；`mt_wifi/hw_ctrl/sr_cmd.c` 提供相关查询/设置入口。配置生效应通过计数和当前模式确认，不能只读 profile。

## 计数器驱动的定位方法

第 23–24 页提供一个有用的分层方法：先看 non-SRG/E-SR 是否启用，再比较 OBSS 接收、可复用接收、SR 发送和 SR ACK 四组计数。对应字段包括 `u2InterBssPpduCnt`、`u2NonSrgVldCnt`、`u4SrAmpduMpduCnt`、`u4SrAmpduMpduAckedCnt`。

- OBSS 多而 valid 少：查识别和阈值条件。
- valid 多而 SR TX 少：查调度、积压和算法禁止条件。
- SR TX 多而 ACK 少：查碰撞、隐藏节点和速率策略。

这是排查方向，不是仅凭计数就锁定硬件故障。文档的部分字段是有限位宽计数，采样要考虑回绕和清零。

## 可用于改进的内容

可以形成状态页与对照测试：Pure、SR off、有干扰 SR on，在相同干扰电平和负载下比较重传、时延及吞吐。文档展示的 27% 下载时间改善是特定测试结果，不能当作设备收益保证。第 18–22 页的单链路/E-SR/MLO 拓扑可用作测试分组，而非直接调整出厂参数。
