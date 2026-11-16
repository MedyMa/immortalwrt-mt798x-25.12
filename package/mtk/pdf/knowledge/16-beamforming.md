# Tx Beamforming：eBF、iBF 与 STBC

文档 ID：`beamforming`。来源：`MT7996 Tx Beamforming Application Note v1.0.pdf`，7 页，2023-06-20。重点：第 4–6 页。

显式 BF 通过 sounding 与反馈获取信道信息；隐式 BF 依赖收发信道推断及相应校准。文档第 4 页的一般性描述不应被理解为支持 iBF 的客户端必须进行同样的显式反馈协商。

## 配置和优先级

profile 的 `ETxBfEnCond`、`ITxBfEn` 分别控制显式和隐式 BF。第 5 页限制 iBF 到 2.4/5 GHz，且需要额外相位校准。文档策略为 eBF 优先于 iBF，再到 STBC；不能把三者同时开启便认为每个报文都叠加使用。

当前源可在 `mt_wifi/profiles/cmm_profile.c` 检索对应配置，并追到 BF capability/firmware 操作。实际可用 streams 取决于板卡、校准、对端能力、带宽和固件，不能把测试图中的 4T 能力赋给 BE14 的各频段。

## 观测与测试

第 5–6 页给出三个频段的 BF 计数器寄存器示例；这些地址只用于对应芯片版本，不能直接写入通用采集器。测试 eBF 时应控制 iBF；测试 STBC 时需要避免 BF 选择覆盖实验条件，并用抓包或已确认的 TX 计数验证。

对我们的实际帮助是显示“配置允许”和“当前发送使用”之间的差别，以及 MU-MIMO 的 BF 前提。BF 状态必须与 Single SKU/BF Backoff 一起解释功率，不能看到功率表数值不变就声称没有回退。资料导入不改变 BF 默认开关、校准数据或 STBC 设置。
