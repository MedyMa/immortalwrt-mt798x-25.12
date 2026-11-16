# 预校准、EEPROM 与工厂数据

文档 ID：`pre-calibration`。来源：`MT7996 Pre-Calibration Application Note v1.0.pdf`，13 页，2023-06-08。重点：第 4–10、12 页。

## 数据模型

文档把预校准分成 Group Cal 和 Per-channel Cal。前者涉及 RSSI/RX/TX DCOC、IQ 与 LPF 等项目；后者包括 TSSI DNL、TX DNL、DPD、flatness、MEMDPD。不同频段和带宽占用不同空间，6 GHz 的 160/320 MHz 有额外项目。因此 EEPROM、校准区长度、SKU、天线数和驱动固件必须匹配，不能只确认某一固件文件可以加载。

第 4–7 页包含内存布局、校准项目和中心信道表。例如 160/320 MHz 的校准中心信道并不等于 AP 的主 20 MHz 信道。表中 `6G 125B` 等单位有疑似排版错误；本知识库不将这些数值转换为 BE14 的 flash 偏移或分区大小。

## 操作的性质

第 8 页依次列出 ATESTART、GROUPREK、各频段 DPD、`sync eeprom all` 和 ATESTOP。同步步骤会把缓冲区写入 flash，是工厂校准流程，不是普通无线诊断或配置恢复方案。第 9–10 页的 Clean 操作会清理校准结果；Dump 与 Clean 必须在工具设计中严格区分。

文档给出 EEPROM `0x1a5` 各 bit 的完成状态：前三位为 2G/5G/6G Group Pre-K，后三位为 6G/5G/2G DPD。这个布局只可用于核对对应版本，不应对其他 SKU 直接写这些 bit。

## 当前源码与历史日志

在当前源可检索 `mt_wifi/ate/wlan_service/agent/agent.c` 的 GROUPREK/DPDClean 注册，再跟踪 EEPROM 读取、校准尺寸计算和固件下载。用户日志里的 `2Die modify group cal size` 是两 Die 分支的提示，是否故障必须看真实尺寸、读取结果和后续初始化，不能因打印 ERROR 就自动重做校准。

第 12 页声称 iwpriv 是 mwctl 的符号链接，这是该 SDK 的工具布局说明；我们的 WEXT 固件不能因此假设两者相同。首先核对实际可执行文件和驱动模式，再选择查询前端。

## 有用的改进方向

建立只读的版本/SKU/EEPROM 来源/校准状态报告，保留原厂数据的校验值；验证两 Die、三频配置的长度上限和异常返回。不得用预校准或清空 EEPROM 解决 UCI 保存、图标、限速或偶发重启问题。本次仅归档资料与源码参考包，未运行 ATE 或修改工厂数据。
