# SCS：自适应载波侦听

文档 ID：`scs`。来源：`MT7996 Smart Carrier Sense Application Note v1.0.pdf`，9 页，2023-06-21。重点：第 4–7 页；第 8 页为 CSCCA 图表。

SCS 通过观察有效吞吐和拥塞情况调整 packet detection，目标是增加干扰环境中的有效信道访问机会。它不等于 EDCCA 的能量门限，也不等于 Spatial Reuse 的 OBSS 识别；三者会相互影响，测试时需要控制变量。

## 激活条件与局限

第 5 页的旧版策略包括信道拥塞、低 TX airtime、busy traffic，且描述不止一个 active STA（吞吐超过 25 Mbps）才激活。该条件是这版文档对算法的描述，不是已确认的 20260721 固件阈值。`SCSEnable=1` 只说明允许算法，不代表此刻正在提高 PD。

隐藏节点靠近 STA、远端 STA 在 PD blocking 时不能连接，是文档明确列出的局限。因此近距离吞吐提高的同时必须观察远距离接入、漫游、重传和延迟。

## 当前代码与命令

构建选项在本仓库为 `CONFIG_MTK_WIFI7_SMART_CARRIER_SENSE_SUPPORT`、`CONFIG_MTK_WIFI7_SCS_FW_OFFLOAD`。驱动可由 `mt_wifi/include/scs.h`、`SCSEnable` 处理函数和相关统一固件命令继续追踪。

文档的 `SCSEnable` 0/1/2/3 分别为禁用、默认启用、打开 SCS 日志、关闭 SCS 日志；不能把 2/3 当作另两个性能等级。`SCSPdRange` 使用 CCK/OFDM 上下限四项，必须核对单位、范围和两类 PHY 是否适用于该 band。

`fwlog`、`fw_dbg` 会改变日志输出负载，不能在每次页面刷新时启用。当前日志中的 `SCS Default Enable, Ret=0` 只证明初始化命令路径得到相应返回，不能证明算法已达到性能目标。

## 帮助与验证

页面可分开显示编译支持、配置开关、实际运行状态及日志状态；不要把日志状态存成算法配置。性能测试至少比较干净信道、同频干扰、邻频干扰、弱信号终端和单/多 STA。Mesh 环境还需对照 Multi-AP 的 SR 协调设计，不能把独立 AP 的 SCS 参数直接推广到所有 Mesh 节点。
