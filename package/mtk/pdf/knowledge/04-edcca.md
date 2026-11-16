# EDCCA：能量检测与阈值编码

文档 ID：`edcca`。来源：`MT7996 EDCCA Application Note V1.0.pdf`，5 页，2023-06-16。技术内容在第 4–5 页。

EDCCA 根据能量阈值阻止发送；禁用后会忽略这一能量检测条件。因此“吞吐更高”不能单独证明禁用合理。EDCCA、SCS 的 packet detection 和 SR 的 OBSS 判定属于不同机制，不应合并为“抗干扰增强”。

## 参数及单位

- `EDCCAEnable` 是开关。
- 文档运行时格式为 `EDCCAThreshold=BandwidthID:Threshold`。BandwidthID 的 0/1/2/3 对应 20/40/80/160 MHz；127 为重置语义。本文档未定义 320 MHz 编码。
- 阈值以负 dBm 的绝对值输入，例如目标 -60 dBm 使用 60。127 又有“不设置”的哨兵含义，不能将其当作有效 -127 dBm。
- profile 用四个分号分隔值，分别描述主/次 20、次 40、次 80、次 160 MHz；不能把文档四项列表扩展为所有 EHT 带宽的通用结构。

## 已确认的文档矛盾

第 4 页对重置行为说明 `EDCCACfgMode=1` 保留上次命令，0 回到 profile/HW；第 5 页对初始值的 0/1 说明与此方向不一致。当前源 `mt_wifi/common/cmm_cfg.c` 的 `u1EDCCACfgMode == 1` 分支确实保存命令阈值及 enable 状态，`mt_wifi/common/rtmp_init.c` 默认该值为 0。知识库保留这个矛盾，采用源码证据解释，不能原样将第 5 页文字写进页面。

配置解析入口在 `mt_wifi/profiles/cmm_profile.c` 的 `EDCCACfgMode`、`EDCCAEnable`、`EDCCAThreshold`。日志里的 192/194 等 MCU 编码未必是命令输入的正数绝对值；未查明数据类型、符号转换和单位前，不能据数值大于 126 就报越界。

## 可以改进什么

页面可明确输入单位、每个带宽的作用范围、哨兵值与保留命令语义，并在解析层检查当前芯片支持的项目。验证时分别测试重置、无线 reload、完整重启和 profile 再生成；配置文件保存与 firmware command 成功应单独展示。当前资料导入不改变阈值、国家码或默认开关。
