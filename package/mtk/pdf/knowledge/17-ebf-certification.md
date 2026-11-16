# eBF 认证：工厂测试流程与参数域

文档 ID：`ebf-certification`。来源：`MT7996 eBF Certification Application Note v1.0.pdf`，20 页，2023-06-09。重点：第 4–19 页。

这份资料是 DUT/Golden 配合仪器的连续 TX 认证流程，不是生产网络调优指南。第 4 页要求高 duty、BF 手动开关和传导/受控 OTA 环境；第 5–6 页通过工厂数据 `0x1af` 切换 test/normal 模式。这会修改持久状态，不能当作普通版本查询或恢复设置执行。

## 不可混用的参数编码

第 7–8 页中 Golden 需要 6 项，DUT 需要 10 项，包含 PHY mode、MCS、带宽、NSS、TRxStream、功率、中心信道、第二中心信道、band 和包长。ATE 带宽编码里的 05=160C、06=160NC、12=320 MHz，不是 UCI EHT160/EHT320，也不是统一固件命令中所有 BW 枚举。TxPower 示例单位为 0.5 dBm DAC 表达，不能直接填 UI 的 dBm。

第 8 页注明部分初始化只能执行一次，改参数要重启 DUT/Golden；调功率是例外，但先 TXSTOP 再改，再 TXFRAME。20/40/80 MHz 的示例包长上限为 4000 bytes，不应推导其他带宽上限。

## 覆盖的实验组合

第 9 页定义开适配器、配置 Golden/DUT、发连续帧、检查 BF、停止 sounding、修改 profile tag invalid、再查 BF 的有序流程。第 10–19 页把此流程扩展到 2G HT/HE/EHT、5G VHT/HE/EHT、6G HE/EHT 的不同带宽和天线组合。重复步骤的用途是认证覆盖，不是所有组合在本板均有效的证明。

当前源码可由 `mt_wifi/ate/ate_agent.c` 的 `ATEConTxETxBfInitProc` 跟踪参数解析。正常固件能编译到某个符号，也不表示拥有配套 testmode 固件、仪器和正确校准。

## 对我们的帮助

适合审核参数编码、工厂/量产模式隔离和测试恢复流程；不适合用于普通网页“一键优化”。原始操作已保留在 PDF 和逐页索引中，技能不会自动运行工厂写入、连续发射或寄存器写入。BE14000 的 TESTMODE 文件与运行 WM/WA/PATCH 应分别记录，不能拿 testmode 文件替换正常运行固件。
