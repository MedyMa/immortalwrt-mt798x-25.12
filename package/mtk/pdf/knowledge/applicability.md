# 对当前 MT7988/BE14 私有源码的应用判断

对照基线为源提交 `3bda8cd5e751a651ef4a71a6077eeb90b315f088`，构建选择以 BananaPi-BPI-R4 builder 的 MTK defconfig 为准，不以源码示例 defconfig 为准。该判断是 2026-11-16 的快照，后续变更驱动、脚本或固件时重新核对。

## 能直接帮助审核和设计的内容

| 资料结论 | 可改进的对象 | 必须保留的区别 |
| --- | --- | --- |
| UCI→profile/hostapd 是有方向的生成关系 | 无线保存、reload、升级迁移和失败回滚 | 用户配置与初始化模板/运行文件 |
| ATF 同时涉及 DWRR max wait | VOW 配置提示、依赖检查与状态页 | 开关与运行算法/积压是否充足 |
| EDCCACfgMode 文档前后矛盾 | 参数说明、reset 和重载测试 | profile 初始值与命令保留值 |
| DSCP/UP/WMM、VOW、QDMA 是不同域 | QoS 页面、mark/优先级/队列所有权 | 优先级与 Mbps 限速 |
| 部分查询会 read-and-clear | 性能采样器、日志报告 | 读取状态与无副作用观测 |
| 温度有不同控制器来源 | 温度页面、风扇/保护状态展示 | SoC/Wi-Fi/NVMe，不按数字位置混用 |
| MLD、BSS、STA、link 有独立身份与生命周期 | 状态模型、关联事件、设备展示 | SSID/主机名不是协议唯一标识 |
| MAP R4 构建在该版仍使用 map_ver=R3 | 将来 Mesh 构建、参数校验 | 驱动宏、应用宏与协议配置值 |

这些都是可供后续改动使用的依据，本次没有切换相应运行策略。

## 与当前构建不匹配的直接复制

私有构建使用 WEXT，而 SoftAP 文档重点是 cfg80211/hostapd/mwctl。命令前端、Kconfig、vendor UAPI、脚本、wpad 与服务依赖必须整体核对。当前 source 中既有 CFG80211 代码也有 WEXT 代码，源文件存在不能证明那个分支在固件中启用。

文档常使用 4 streams/BE19000、旧 Lua、测试信道、静态寄存器和仪器参数；BE14 的 SKU/EEPROM/两 Die 及固件能力不能据此重写。工厂预校准、test mode、DFS 绕过、关闭热保护、强制 MURU 和改 pinmux 不属于自动诊断。

## PP/VOW 目前能证明到哪里

上游参考与当前源的 PP 发送构造基本相同；当前错误返回处理增加了失败传播与诊断，而非换了一条不同 MCU 编号。BE14000-20260721 的 WM/WA/PATCH/TESTMODE 四文件此前已逐字节核对一致，匹配设备日志里的 build date。当前自定义固件选择会覆盖基础 bin 包内的 fallback 文件，所以不能只按 `dl` 文件日期声称升级或降级。

三类容易混淆的缩写需要固定在知识库中：

- Packet Prioritizing：ARP/DHCP/PING/EAPOL 的 PHY 速率设置。
- Preamble puncturing/PP MCU controls：带宽打孔及相关固件控制，`UNI_CMD_ID_PP=0x38`。
- VOW：airtime/fairness/group bandwidth，`UNI_CMD_ID_VOW=0x37`。

公开文档不足以解释 `0xc0000001` 的固件内部拒绝条件。不能删除返回值校验、伪造成功或恢复已拦截的越界访问来获得“日志正常”。

## dl 入库决策

上游 14 个归档中，10 个新条目以 reference-only 纳入：Wi-Fi SDK source、warp、datconf 新修订及 1905daemon/libmapd/libwpactrl/mapd/mapfilter/mtfwd/wappd。它们用于离线比较与阅读，与资料章节形成可追溯的代码依据。

已有同内容的 OSAL/fwdd/wificonf 不重复替换；现有 R4 Wi-Fi source/bin 和 datconf-757f9679 保留。未导入 20250613 fallback bin 包，它没有提供比当前 BE14 覆盖文件更新的已确认固件，复制它也不会自动修复 PP。

参考归档里可能夹带固件或工具 ELF，清单记录数量；“有源码”不等于所有成员都是源码、完整开源许可证或可以直接执行。新 Mesh 归档并未被自动新增的包、init 或默认选项引用。升级到新 SDK 或启用 EasyMesh 是后续独立集成工作，需检查依赖、ABI、配置迁移与实机结果。

## 本次资料不提供的结论

没有对偶发重启/SFP 故障继续做根因实验；没有调整 SD/NVMe 根目录、PCIe、U-Boot、pstore 或启动设备树。文档也没有给出该设备的 NVMe 驱动升级方案。硬件 LED/校准/热保护说明不能替代板卡布线和真实故障日志。
