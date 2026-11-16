# Wi-Fi 7 SoftAP：架构、配置所有权与控制接口

文档 ID：`softap`。来源：`MediaTek Wi-Fi7 SoftAP Software Programming Guide_V1.1.pdf`，183 页。以下页码均为 PDF 物理页。各页完整提取文本保存在 `pages.jsonl`，可通过仓库脚本按 ID/页码读取。

## 全文导航与本树的使用方式

| 章节/页码 | 覆盖内容 | 对当前源码的主要用途 |
| --- | --- | --- |
| 1–3，9–28 | 软件分层、HWIFI、TX/RX、MLO、BSS manager | 定位控制面/数据面边界及对象生命周期 |
| 4，29–60 | NL80211、vendor ABI、cfg80211 hooks、mwctl | 审核前端能力、命令注册与参数一致性 |
| 5，61–89 | wifi-device/iface/mld、UCI、Lua 脚本 | 配置翻译、持久化、reload 与迁移审核 |
| 6，90–96 | WPA/SAE/OWE/DPP、MLO 安全 | 防止认证、PMF、MLD 配置被错误混合 |
| 7–8，97–115 | mWDS、WPS、registrar、CLI | 区分桥接扩展、Mesh 入网及独立 AP 配网 |
| 9，116–124 | 信道、CSA、扫描、ACS | 对照频率/主中心信道、扫描与信道切换状态 |
| 10，125–128 | WMM、DSCP→UP/AC、QoS exception | 审核优先级映射与限速组件之间的相互影响 |
| 11–12，129–142 | DFS/ZW-DFS、APCLI、连接查询 | 区分 CAC、关联、认证和实际链路能力 |
| 13–14，143–146 | Multicast-to-unicast、PMF | 避免混淆 Wi-Fi 组播转换与 Linux bridge snooping |
| 15–16，147–157 | 固定速率、速率表、UL MURU TPC | 核对带宽/NSS/MCS/功率各自的编码 |
| 17–19，158–169 | ACL、6 GHz、power percentage | 完善配置校验和状态解释 |
| 20，170–182 | 版本、连接、性能、panic、问题报告 | 建立带版本证据的定位流程；按当前用户任务范围使用 |

## 一、软件分层不能按包名猜测

第 9–17 页把系统分为用户态配置/hostapd、cfg80211、AP MAC（mt_wifi）、HWIFI、总线/芯片/MCU。mt_wifi 处理 MLME、帧分类和软件状态；HWIFI 管理芯片、总线、资源及硬件收发。文档中 OS 抽象层叫 mt_wifi_cmn，但当前仓库选用 mt_wifi_osal，并有拆分构建和依赖适配，不能照模块加载图恢复旧依赖。

TX/RX（17–21 页）区分软件路径、硬件 offload 与 RRO。实际 PPE、HNAT、WED、WO 的职责和计数源应在本树追踪，不能因普通 netfilter 或抓包只看到首包就判断没有流量。硬件卸载开启时，也不能用软件包计数直接承诺总流量统计正确。

MLO（22–28 页）区分 MLD、affiliated link、STR、EMLSR 和 setup link。BSS manager 管理分组、link 与 IE 同步；SSID 相同不等于已创建 MLD，多个 AP 接口同时存在也不证明 STR 并发。

## 二、三种命令编号空间必须分开

第 29–39 页列标准 NL80211、vendor sub-command 与 cfg80211_ops。第 53–56 页通过新增 channel 命令说明：用户态定义、内核 UAPI、driver handler、属性类型/长度和注册策略必须一致，枚举顺序是 ABI，不能随意插入或改号。

该版本表中“第 13 项 SET_AP_VOW”是用户态 vendor 命令表的编号，不是 MCU 的 `UNI_CMD_ID_VOW=0x37`；`UNI_CMD_ID_PP=0x38` 和 PP tag 3 又是另一个编号空间。相同字符串经过不同前端可能到达同一个内部控制函数，不能据前端不同便判定固件发送路径错误。

文档是 cfg80211/fullmac/hostapd 架构。当前私有固件的实际构建配置关闭了 `MTK_WIFI7_CFG80211_SUPPORT` 和 OSAL cfg80211，使用 WEXT。源码目录里存在 cfg80211.c 或安装了 mwctl，不证明运行内核注册了对应 handler。所有采集/设置示例先识别构建与运行前端；不要靠创建 iwpriv→mwctl 符号链接“修复兼容”。

## 三、配置所有权和持久化

第 61–89 页的核心是 UCI→band `.dat` 与 hostapd/supplicant 运行文件，再创建接口。反向 detect/profile→UCI 是初始化路径，和用户配置的正常 apply 不是一个操作。第 89 页 quick_setting 比较旧/新 profile 后执行增量命令，不是每次 reload 都覆盖整份 wireless。

当前适配应检查 `package/mtk/applications/mtwifi-cfg`、实际 Wi-Fi scripts 与 `luci-app-mtwifi-cfg` 的读写链，不能把文档旧 `wifi-profile/unified_script` 路径当成当前安装位置。新增 ucode mtwifi-scripts 属于另一套整合工作，不能只复制 `/sbin/wifi` 或把 config 调用移动到 kmodloader 后就认为迁移完成。

可复用的验证矩阵：已有配置/首次启动、单项保存/保存应用、reload/服务重启/系统重启、保留配置升级、增删 BSS/MLO、失败回滚。比较的是用户 UCI 值和实际生成结果；`/var/run` 文件通常不负责跨重启持久化。当前用户已暂缓偶发启动故障，知识库不会据此执行重启试验。

## 四、安全、MLD 与前端对象

第 84–96 页的 wifi-mld 是配置对象，包含成员接口、main_iface、SSID 和安全参数；表格对 required/default 的描述有不够严谨处，应以本版 parser 及接口模式为准。不能把 MLD 安全设置只写到某一个 link，然后假设全组已一致。

第 145–146 页明确 PMF：ieee80211w 0→MFPC/MFPR=0/0，1→1/0，2→1/1；WPA3 的示例要求 PMF。PMF 主要保护规定的 robust management frame，不应将概述理解为所有管理帧都加密。6 GHz 配置不能把旧 WPA/TKIP/WPS 示例直接复用。

`secinfo` 的文档示例会打印 Key。需要报告认证状态时只保留模式、cipher、MFPC/MFPR 和 secured 状态，避免把真实 PSK 放入日志附件或知识库。原 PDF 中的测试口令不应成为出厂配置。

## 五、WMM、DSCP 与 HQoS

第 125–128 页明确 DSCP 0–63、UP 0–7、WMM 四类 AC 是不同域。`DscpPriMapEnable`、每 BSS 的 `DscpPriMapBss%d` 与 `QoSEnable` 的例外表并不必然相同；不能把简单 DSCP/8 映射当成所有模式的最终结果。

对当前“网速控制”的帮助是区分：IP 优先级、Wi-Fi AC、VOW airtime、QDMA 队列和 tc/nft 软件限速。不要为启用其中一层而清空其他组件的 DSCP 或复位全部硬件队列。QoS 页面若新增 Wi-Fi 优先级配置，应注明作用于哪个 BSS/band、由谁拥有及关闭时如何恢复。

## 六、信道、APCLI、组播与功率

信道/CSA/扫描（116–124 页）有不同状态与时序；自动信道选择中 prim_ch=0 后进行扫描，不可仅凭中间初始化输出断言最终工作信道失效。主 20 MHz 信道、中心信道、第二段中心信道与 EHT puncturing bitmap 需要分别验证。

APCLI（135–142 页）同时涉及上联认证、地址转换/mWDS 及下联 AP，不能用桥接四地址和普通 STA 地址映射的说明互相替代。IGMP 章节（143–144 页）讨论 Wi-Fi 侧 multicast-to-unicast 表，不等于 bridge multicast snooping 和路由器 IGMP proxy 已正确配置。

固定速率（147–153 页）是实验控制，须与自动速率恢复成对验证；PHY rate 不是应用层吞吐。UL MURU TPC（154–157 页）调节多个 STA 的上行功率以控制 ICI/IRUI，不是下行 Single SKU，也不是 WAN 上传限速。ACL（158–160 页）按 BSS 工作；power percentage（166–169 页）的百分比不能直接作为 dBm 线性倍数计算。

## 七、可用的诊断流程及观测副作用

第 170 页强调 driver/WM/WA/DSP build date；必须记录实际加载固件，不能只用压缩包文件日期。第 173 页说明 `mibinfo` 是 read-and-clear，状态查询也可能影响下一次采样；第 178 页的循环会主动 ResetCounter，不能作为无副作用采集器。对照测试需记录采样区间、清零和计数回绕。

第 175–179 页的顺序有用：硬件/校准和天线→环境→对端→协商能力→PHY/PER→CPU/卸载。尽量控制变量，并保留每 STA 与总吞吐、重传、延迟和温度。设置更详细日志会增加负载，不把调试级别变化混入性能基准。

第 180–182 页要求匹配运行构建的 vmlinux/模块、编译选项、版本和日志；这只是保留的知识，不重启当前设备。报告应区分配置、实际命令返回、最终运行行为与尚未验证的推断。

## 能立即帮助本项目的内容

1. 为 Wi-Fi 页面建立“构建支持/配置允许/运行生效”三个独立状态。
2. 将配置来源、作用范围、单位、依赖和恢复方式写进字段说明。
3. 审核 MLD/BSS/WCID 生命周期及 all-sta 事件长度/布局；保留现有边界检查和固件真实错误。
4. 避免把旧 SDK 示例值、默认 4 streams、旧 Lua 脚本或实验室命令变成 BE14 的自动优化。
