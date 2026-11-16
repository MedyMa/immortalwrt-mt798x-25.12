# DFS 与专用接收链路的零等待 DFS

文档 ID：`dfs`。来源：`Eagle_DFS_ZW_DFS_AN_V1.0_230217 (1).pdf`，11 页。主要技术依据：PDF 第 2–9 页。原件与逐页文本的关系见 [资料入口](README.md)。

## 机制与前置条件

DFS 的目标是在检测到雷达后退出占用信道。零等待 DFS 利用独立接收资源完成另一信道的 CAC；“零等待”不等于省略 CAC。文档描述两种收益：首次使用 DFS 信道前先在非 DFS 信道提供服务；工作信道出现雷达后切到已完成检查的候选信道。具体 CAC/NOP 时长取决于地区、信道及带宽，不应把图中的 1 分钟固定写进程序。

第 6 页同时给出 UCI 的 `DfsEnable`、`aregion`、`channel`、`htmode`、`dfs_dedicated_zero_wait`、`dfs_zero_wait_default` 和驱动 profile 的 `DfsZeroWait`、`DfsDedicatedZeroWait`、`DfsZeroWaitDefault`。它们属于不同配置层。`RDRegion` 是检测地区；`CountryRegionAband` 是信道列表选择，不能仅修改其中一个便认为整个无线监管状态一致。

## 对当前源码的映射

解包当前构建源并应用补丁后，可在 `mt_wifi/profiles/cmm_profile.c` 检索 `DfsZeroWait`、`DfsDedicatedZeroWait`，继续追踪 DFS/后台扫描的条件编译。BE14 的接收链路数和专用雷达资源应以板卡 SKU、EEPROM 与实际固件能力为准，不能从 BE19000 的例子推导。本文档中的 `MT7990_1_2` 只是示例 section 名。

第 7 页的 `show dfschinfo` 可作为状态查询的线索，但要先确认当前 `iwpriv`/`mwctl` 前端及命令表。寄存器 `830A5018` 的 bit 0 是旧硬件示例，不能直接成为本板的自动检测规则。

## MLO 与日志解释

第 9 页区分 setup link 所在频段：当 setup link 是正在停止发送以执行 CAC 的 5 GHz 链路时，APCLI 可能因 beacon 超时断开；setup link 在 2.4 GHz 时可有不同结果。因而“5 GHz 暂停发送”和“整个 MLD 永久失效”不能混为一谈。

`wdev is not 5G` 出现在非 5 GHz 的 DFS 初始化路径，不能单靠日志级别认定错误。应关联频段、CAC 状态、后续 AP link-up 和客户连接结果。这是解释日志的方法，不是对现有偶发故障的根因结论。

## 可用于改进的工作

- 页面区分 DFS、专用零等待、当前 CAC 和 NOP 状态，展示资源限制及实际生效情况。
- 配置迁移以 UCI 为用户配置入口，验证生成的 `.dat`，避免升级时用模板覆盖用户选择。
- 按非 DFS/DFS、固定信道/ACS、单链路/MLO 分别验证；记录中断时间和实际切换结果。

第 8 页的 bypasscac、清 NOP、生成雷达事件及保持信道的测试命令属于实验室操作，不能并入普通采集脚本或出厂默认设置。
