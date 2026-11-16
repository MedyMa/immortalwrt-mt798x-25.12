# 逐份分析与检索路线

每篇分析给出文档物理页、机制/参数、当前源映射、实际用途和版本边界。原 PDF 和 721 页文本保留全部原始内容，以下是解释与应用判断，不能替代硬件/固件验证。

原件固定取自 [benboguan/immortalwrt-mt799x@38666f1d](https://github.com/benboguan/immortalwrt-mt799x/tree/38666f1d78047eb78036fa4d2b7b96880cefcaa3/package/mtk/pdf)。[统一索引](index.json) 记录文档 ID、原 URL、页数、校验值、分析路径，以及 `source_cache` 中的参考归档与保留的构建输入；[逐页文本](pages.jsonl) 按物理页检索，37 页 OCR 补充须对照原图确认。原件中的版权和条款保持原样，不另行授予软件许可证。

| 文档 ID | 分析 | 页数 | 对本项目的主要帮助 |
| --- | --- | --- | --- |
| dfs | [DFS/ZW-DFS](01-dfs.md) | 11 | CAC/专用接收资源、MLO setup link 和日志状态 |
| afc | [AFC](02-afc.md) | 15 | 6 GHz 标准功率的完整依赖与状态；当前非自动启用功能 |
| airtime | [VOW airtime](03-airtime.md) | 15 | ATF/WATF/ATC/TPC、DWRR 耦合、15 组与 MLO 配额 |
| edcca | [EDCCA](04-edcca.md) | 5 | 门限单位、reset/哨兵及文档模式矛盾 |
| led | [Wi-Fi LED](05-led.md) | 10 | 控制器归属、时序字段、避免推导到 SSD/机箱灯 |
| mu-mimo | [MU-MIMO](06-mu-mimo.md) | 12 | BF/BA/NSS 前提、方向和多 STA 测试 |
| ofdma | [OFDMA/MRU](07-ofdma.md) | 14 | 生效与配置区分、MURU 实验边界和短/长包收益 |
| pta | [3-Wire PTA](08-pta.md) | 9 | 外部 BLE 仲裁、连线/pinmux 前提；不是 PP |
| pre-calibration | [预校准](09-pre-calibration.md) | 13 | EEPROM/校准/SKU 匹配和工厂数据保护 |
| priority-rate | [优先报文速率](10-priority-rate.md) | 9 | ARP/DHCP/PING/EAPOL 的 per-band PHY 速率 |
| single-sku | [Single SKU/BF Backoff](11-single-sku.md) | 20 | per-chain/EIRP/PSD、单位与构建时表格 |
| scs | [SCS](12-scs.md) | 9 | 激活条件、日志状态和弱信号/隐藏节点限制 |
| spatial-reuse | [Spatial Reuse/E-SR](13-spatial-reuse.md) | 25 | OBSS/SRG、计数定位与 Mesh 协调边界 |
| twt | [TWT](14-twt.md) | 16 | ITWT/BTWT、协商/状态和暂停恢复；不是 NVMe APST |
| thermal | [热保护](15-thermal.md) | 13 | 温度来源、duty/迟滞、秒单位和查询副作用 |
| beamforming | [Tx Beamforming](16-beamforming.md) | 7 | eBF/iBF/STBC 选择、校准与功率回退 |
| ebf-certification | [eBF 认证](17-ebf-certification.md) | 20 | ATE 编码和工厂测试，不能作生产调优 |
| softap | [SoftAP 架构](18-softap.md) | 183 | 用户态/驱动/固件边界、配置所有权、20 章导航 |
| multi-ap | [Multi-AP](19-multi-ap.md) | 315 | 完整 Mesh 组件、持久化、角色、steering/VLAN/MLO |

## 先按问题选资料

- PP/VOW：先读 airtime、priority-rate、softap 的命令编号空间，再读 multi-ap 的静态 puncturing；不能用同一个缩写判断同一功能。
- 无线配置保存：先读 softap 第三节、multi-ap 第三节，追 UCI 与生成文件的所有权；不先运行 detect、工厂重置或重新入网。
- 吞吐/时延：按 SCS、EDCCA、SR、OFDMA、MU-MIMO、Beamforming 的不同机制分别测试，再考虑 VOW/WMM/HQoS；每次控制变量。
- 6 GHz：结合 AFC、Single SKU、SoftAP 安全与信道章节，区分能力、功率模式、授权和认证。
- 温度/LED/休眠：分别查 thermal/led/twt，先核对控制器和数据来源；不要把相似现象跨子系统解释。
- Mesh：先读 multi-ap 的组件和模式，再用缓存中的 mapd/wappd/1905daemon 源码验证；一个 Kconfig 开关不构成完整服务。

## 证据层级

1. 原文明确写出的机制/参数，以物理页引用。
2. `source-map.json` 提供当前源码的文本锚点，仍需检查条件编译和调用者。
3. 实际构建配置和加载的 firmware build date 决定适用范围。
4. 命令 ACK、运行状态和受控测试证明效果。

前两个层级不等于最后两个。OCR/旧 SDK 示例、没有版本信息的日志、单次吞吐值都不能单独证明根因或兼容。
