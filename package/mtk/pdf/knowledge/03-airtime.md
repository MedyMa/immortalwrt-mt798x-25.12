# VOW：ATF、WATF、ATC 与 TPC

文档 ID：`airtime`。来源：`MT7996 Airtime Management Application Note v1.1.pdf`，15 页。封面仍写 1.0，但第 2 页版本记录为 1.1，修订日期 2023-08-25。重点：第 4–14 页。

## 四种控制的区别

| 机制 | 控制对象 | 不能据此承诺的效果 |
| --- | --- | --- |
| ATF | 同一组、同一 WMM AC 内各 STA 的发送调度/空口时间 | 不是各 STA 字节吞吐相同 |
| WATF | 给 STA 分组并配置不同 DWRR quantum | 不是固定 Mbps 限速 |
| ATC | BSS/组最小、最大 airtime 比例 | 不是以太网硬件队列配额 |
| TPC | BSS/组吞吐最小、最大值 | 不是完整的每设备双向 WAN 限速 |

ATF 用 DWRR 减少慢速客户端占用过多 airtime。第 4–5 页的 WATF 四等级约为 1/2/3/4 ms；第 11 页给出的配置量单位为 256 µs，示例 quantum 为 4/8/12/16。不要把近似毫秒值当成精确换算或忽略当前固件单位。

## 关键耦合与配置

第 6–9 页指出 ATF 开关与 `vow_dwrr_max_wait_time` 必须一起检查：示例开启时为 64，关闭时为 1；只关 ATF 而保留 64，测试结果可能仍类似开启状态。它是需对照固件确认的配置耦合，不是本次修改默认值的指令。

`VOW_Airtime_Fairness_En`、`VOW_WATF_Enable` 和 `VOW_WATF_Q_LV0..3` 对应 profile；MAC 分组由 `VOW_WATF_MAC_LV0..3` 表达。WATF 依赖先开启 ATF，未分组的 STA 按文档落在最低组。`show vow_info` 和 `show vow_watf_info` 是查询入口线索；当前 WEXT 构建必须确认命令前端和注册表。

第 13 页的 `VOW_BW_Ctrl`、`VOW_Group_Min_Ratio`、`VOW_Group_Max_Ratio`、`VOW_Airtime_Ctrl_En`、`VOW_Group_Min_Rate`、`VOW_Group_Max_Rate`、`VOW_Rate_Ctrl_En` 是按组索引排列的列表。文档例子包含占位组 0，不能只根据 SSID 名字猜数组下标；表单应验证列表长度、最小值不大于最大值和组容量。

## MLO 与当前代码

第 14 页明确每条 MLO link 有独立 airtime/fairness；ATC/TPC 的 15 组在各链路间共享。15 组并不意味着 MT7990 支持所有旧代 VOW group-to-band estimator 命令。当前 `99999999-fix-vow-group-band-generation-limit.patch` 已对 `VOW_GEN_BESRA` 及之后的旧命令限制做适配，不能用此容量说明撤销保护。

当前源的配置解析位于 `mt_wifi/profiles/ap_profile.c`，运行控制位于 `mt_wifi/feature/vow/`。VOW MCU ID 为 `0x37`；`PP=0x38`、其 MU/OFDMA 子命令 3 是另一条命令。用户态的 VOW vendor 子命令编号也不是 MCU ID，三个编号空间不能混用。

## 对我们的帮助与验证方法

可以改进配置提示、依赖校验、运行状态展示及公平性测试。测试需有持续积压的发送队列，按第 7–9 页用快慢两个 STA、同 AC、相同负载条件比较 airtime，TCP 流控会干扰饱和度，必要时用受控 UDP 负载。报告同时记录 Mbps、airtime、排队和丢包，不能只看总吞吐。

该文档不提供固件拒绝 `0xc0000001` 的内部条件，也不能替代 `luci-app-hqos-mtk` 的 QDMA 所有权、nftables 和 WAN/LAN 限速机制。
