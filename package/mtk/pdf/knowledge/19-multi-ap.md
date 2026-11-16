# Multi-AP 4.1 草案：Mesh 的完整依赖和配置边界

文档 ID：`multi-ap`。来源：`Multi-AP_Application_Note_v_4_1_Draft_0.3.pdf`，315 页。它是草案，涵盖多个历史平台、LSDK/OpenWrt 和不同 MAP 版本；示例之间的矛盾须按平台与版本拆开判断。

## 全文的功能地图

| 章节/物理页 | 范围 | 对当前项目的用途 |
| --- | --- | --- |
| 1–2，19–35 | MAP R1–R4、MLO、组件和拓扑 | 规划完整依赖，区分 native 与 hostapd 架构 |
| 3，36–80 | WPS/DPP、MLO 入网、BSS 分配、保存和重新入网 | 配置持久化与控制器下发的所有权 |
| 3，81–120 | 第三方上联、角色、renew、switch ops、回程/DHCP | 避免复制示例后改变网桥、WAN 与地址分配 |
| 3，121–132 | Mesh SR、单频、MLD dynamic regroup | 确认拓扑、BSS color/SRG 与 MLO 生命周期 |
| 4，133–146 | 自愈、回程优先级、优化、环路限制 | 自动控制的触发、失败边界与可观测性 |
| 5，147–190 | topology/client DB、Data Elements、DPP 凭据 | 建立设备身份、能力和指标来源模型 |
| 6，191–216 | 集中 steering、BTM/11k、ACL 与兼容问题 | 对端能力、误踢与回退测试 |
| 7，217–247 | 信道规划、BW、puncturing、CAC | 协调扫描/切换与各节点能力的交集 |
| 8，248–259 | VLAN traffic separation、service priority | 区分隔离、DSCP/PCP/WMM 与限速 |
| 9–10，260–274 | 独立 band steering、第三方 controller 共存 | 不必把独立 steering 与完整 EasyMesh 捆绑 |
| 11，275–314 | 构建、daemon、CLI、事件、UCI 示例 | 对照新增参考源码，不直接套旧启动脚本 |

## 一、不是一个 Kconfig 开关能完成的功能

第 30–33 页的核心组件为 driver、WAPP/wappctrl、1905 daemon、MAPD/mapd_cli、mapfilter；libmapd 提供客户端接口，libwpactrl 主要用于 hostapd/supplicant SKU。文档同时给出 native 与 cfg80211/hostapd 模型，不能从支持其中一个推导当前 WEXT 构建已经完成另一个。

当前缓存收录的是这些组件的参考源码；没有因此新增 package Makefile、选择模块、安装 init 脚本或开机启动服务。完整移植还需要 UAPI/事件布局、固件、接口命名、控制 socket、服务依赖、角色、网络模型和持久化相互匹配。

## 二、MAP_HOSTAPD 与 R4 的具体含义

第 281 页中 `CONFIG_MTK_WIFI7_MAP_HOSTAPD_SUPPORT=y` 在 mapd/wappd/1905daemon 中分别控制 hostapd、EHT、MLO 相关编译宏。它是跨组件构建契约，不等于所有 MT7990 固件都应默认开启。当前私有固件关闭 cfg80211，未完成完整 MAP hostapd 架构；不能只开一个宏宣称已经支持 EasyMesh R4。

**第 281–282 页明确：该版本构建 MAP R4 时，运行配置仍保持 `map_ver=R3`。** 不能因为构建符号叫 R4，就把 1905d.cfg 的值改成 R4。后续版本若定义新值，要重新核对 parser。当前驱动中的 MAP_R4_VER_SUPPORT 等宏与应用的 CONFIG_MAP_R4_SUPPORT 也不能仅凭相似名称互换。

## 三、配置保存与 BSS/MLO 分配

第 36–43 页定义 controller 的 BSS 目标配置，包含 ALMAC、radio、SSID、认证、BH/FH、hidden、VLAN/PVID/PCP 和 MLD group。字段属于一个完整记录，不能只按相同 SSID 合并节点。6 GHz/MLO 的认证限制和 WPS 所需的 2.4/5 GHz FH BSS要分开验证。

第 78 页规定已入网的 backhaul 和 DPP 配置应持久保存，重启无需重新入网。第 79 页说明 BSS interface 与 SSID 的匹配受 bss_config_priority 和初始化顺序影响，不能假设第一个 SSID 永远是 ra0。第 128–132 页的 MLD regroup 会改变 link/group，对象释放、旧 key 和前后身份关联需要显式处理。

第 275 页区分 LSDK 的 NVRAM 与 OpenWrt 的持久文件；第 310–314 页进一步说明 Eagle UCI→uci2map.lua→各 daemon 配置，wapp 将无线变更写入 `/etc/config/wireless`。因此不能照 LSDK 命令将运行文件覆盖回用户 UCI，也不能同时由两个脚本反向生成 wireless。Controller renew 覆盖哪些选项，应设计清晰的管理权与退出恢复策略。

## 四、角色、上联、交换机和环路

第 81–90 页含第三方上联、自动角色和 renew。角色变化可能影响 DHCP、上联和 SSID，不适合作为默认后台探测自动操作。附录第 305 页仍残留“非 MAP Wi-Fi 上联不支持”的旧说明，与第 81–83 页 ThirdPartyConnection 支持描述不一致，需要按版本/平台验证，不能任选一个作通用结论。

第 90–114 页的 switch ops 涵盖端口类型、FDB、状态、VLAN、速度和端口阻断，区分 DSA 与非 DSA。物理 port 0、CPU conduit、wan/lan 名字不能照图硬编码；与本树已修复的 BPI-R4 端口命名、桥接、HNAT 关系一起验证。

第 144–146 页的以太网回程防环依赖 switch 和 vendor TLV，明确不覆盖全以太网环形拓扑；不能将它当作通用 STP/RSTP 替代。引用完整架构也不意味着可以删除现有 firewall、bridge isolation 或 packet steering。

## 五、Mesh Spatial Reuse 与独立 SR

第 121–127 页区分 No-SR、SRG Protect、Mesh SR，由 MAPD 信息和固件自动选择阶段，使用 BSS color、partial BSSID/SRG bitmap。保护模式不复用 Mesh 内部流量，增强模式在条件满足时允许部分内部 FH 复用。

该段还注明验证范围为 AX4200 Panther，不能据有此章节就认定 BE14/当前 WM 已完成支持。它扩展了 2023 年 standalone SR 文档中“Multi-AP 关闭 SR”的建议，但要求拓扑协调；不能只把所有节点 SREnable/SRDPDEnable 置 1。

## 六、自愈、steering 与兼容性

第 133–144 页集中在 controller 决策、自愈、BH 优先级和拓扑优化。Off-channel scan、CAC 完成和信道变化都可能触发重新优化；手动 steering 也可能关闭自动优化。不能把每次回程变化当作驱动重置异常，应先查控制器动作及触发来源。

第 191–216 页的集中 steering 依赖拓扑 DB、客户端度量、RSSI/负载、BTM/11k 与跨 AP 协调；算法延迟也包含控制器处理时间。第 211、263 页注明集中方案 pre-assoc 限制、CAC 期间 steering 限制、跨 band FT 回退，以及随机 MAC 导致的能力推断困难。不能把同名主机跨 MAC 视为协议层已证明同一 STA。

第 211、271 页列出旧终端 IOT 案例，包括建议关 PMF 的历史规避方法。它们不是当前 Apple/华为/联想设备的通用缺陷，也不是 WPA3/6 GHz 默认关 PMF 的依据。品牌识别、UI 合并和控制器 steering 身份必须分开。

## 七、信道规划、静态 puncturing 与 CAC

第 217–247 页把监测、扫描、规划、切换和 radar 处理作为协调过程；Ethernet BH 与 Wi-Fi BH 的可用信道约束不同。第 227–229 页的静态 puncturing 支持依赖主信道、带宽、bitmap、对端与调度器，不能用该章节证明 `PP MU/OFDMA subcmd=3` 被拒绝是发送路径错误。

第 241 页说明该文档中的 MTK 不支持 MIMO dimension reduced/time-sliced CAC，仅支持连续或专用接收资源等列明方式。文档的旧能力表不能推广到所有后续固件，但可防止页面无依据展示所有 CAC 模式。信道组已完成 CAC 的复用也要遵守带宽、NOP 与有效状态，不能简单缓存一个 channel 的布尔值。

## 八、VLAN、业务优先级与现有 HQoS

第 248–254 页用 SSID↔VLAN 建立 primary/secondary 网络，LAN 有线通常归 primary。VLAN 标签、PVID、PCP、BH 透传及出 WAN 去标签必须成套实现。文档列有不支持的 GPON/直接上联拓扑，不能只建立 Linux VLAN 接口便声称完整 traffic separation。

第 255–259 页的 service prioritization 使用静态/动态规则和 DSCP↔PCP 映射，可能改变报文优先级；它不是按设备 Mbps 限速。与当前 HQoS、代理 mark、nft/DSCP 配置共存时，需要明确规则优先级和所有权，不能让退出 Mesh 时清空其他服务队列或 mark。

## 九、遥测与独立 band steering

第 147–190 页的 topology、client DB、Data Elements 包含节点、BSS、radio、MLD/link 与能力数据，不等价于 nlbwmon 的长期字节统计。DPP 配置包含密钥、connector 等持久凭据，不应原样加入诊断附件。

第 260–272 页说明独立 band steering 不要求完整 1905 controller 拓扑服务，但仍有驱动/WAPP/MAPD 相关依赖与不同决策语义。它可作为未来独立功能评估，不应为了图标或设备展示顺便启用。第 273–274 页第三方 controller 共存涉及 veth/bridge 协议隔离，也需要单独设计，不能照例子改变当前 LAN。

## 可实施收益与边界

本资料直接提供完整依赖图、配置持久化审核点、状态/事件模型和测试矩阵。将来引入 Mesh，应分别验证 controller/agent、R1/R2/R3/R4、WEXT/hostapd、以太/无线 BH、单频/多频/MLD、升级保留/退出恢复。当前仅归档和提炼知识，没有启用 Mesh、改角色、重建无线配置或更换正常运行固件。
