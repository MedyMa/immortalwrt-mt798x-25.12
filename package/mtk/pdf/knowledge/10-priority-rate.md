# 高优先级报文固定 PHY 速率

文档 ID：`priority-rate`。来源：`MT7996 Rate Setting of Packet Prioritizing Application Note v1.0.pdf`，9 页，2023-06-09。重点：第 4–8 页。

这里的 Packet Prioritizing 是 ARP、DHCP、PING、EAPOL 的发送速率配置，作用于每个 band，文档明确不支持 per-BSS。它不是 preamble puncturing（PP）、不是 VOW airtime fairness，也不是 WAN 设备限速。

## 编码与配置

本仓库的构建选项为 `CONFIG_MTK_WIFI7_RA_PHY_RATE_SUPPORT`。profile 键为 `hprirateset0` 至 `hprirateset3`，值是 `ratetype-phymode-mcs`：

| 字段 | 文档取值 |
| --- | --- |
| ratetype | 0 ARP、1 DHCP、2 PING、3 EAPOL |
| phymode | 0 禁用、1 CCK、2 OFDM |
| CCK mcs | 0–3 对应 1/2/5.5/11 Mbps |
| OFDM mcs | 0–7 对应 6/9/12/18/24/36/48/54 Mbps |

命令名是 `highprirate`，不是 `hprirateset`。显示中的 enable 是类别位图，不是 Mbps；值 5 表示 ARP 与 PING 两个位开启。这里的 PHY mode/MCS 也不是 EHT MCS 编码，不能跨表复用。

## 源码映射与验证

`mt_wifi/profiles/cmm_profile.c` 检索 `hprirateset`；`mt_wifi/ap/ap_cfg.c` 检索 `highprirate` 与条件编译 `RA_PHY_RATE_SUPPORT`。文档建议按 Host→WA→TX 追踪，并用空口抓包确认实际速率。查询显示只能说明配置/主机状态，不能替代空口结果。

提高 EAPOL、DHCP 等报文的速率可能降低弱信号终端接入可靠性；文档的 OFDM 54M 示例不是通用推荐。将来若增加页面，必须按 band 验证制式、频段和 MCS 组合，并说明其影响范围。不能把它作为 `cid=0x38, subcmd=3` 被固件拒绝的修复。
