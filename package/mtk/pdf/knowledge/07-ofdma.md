# OFDMA、MRU 与 MURU 调试

文档 ID：`ofdma`。来源：`MT7996 OFDMA Application Note v1.0.pdf`，14 页，2023-06-20。重点：第 4–13 页。

OFDMA 让多个用户共享一次 PPDU 的不同 RU；Wi-Fi 7 进一步支持 MRU。MU-MIMO 复用空间资源，OFDMA 复用频率资源，二者可能组合，但不能等同。文档第 4 页把 MRU、SU puncturing 放在关联背景中介绍，不表示它们共享完全相同的固件命令。

## 启用与观测

profile 的 `MuOfdmaDlEnable`、`MuOfdmaUlEnable` 分别控制方向。当前解析可在 `mt_wifi/profiles/cmm_profile.c` 找到；MURU 调试代码可由 `mt_wifi/common/capi.c` 的 `set_muru_manual_config` 跟踪。

第 10 页 `show apcfginfo` 用于查询配置；`set_muru_manual_config=dl_comm_user_cnt:<N>`、`update` 和 `set_muru_sutx` 都会改变调度，属于实验设置。解除强制包含 `dl_init` 后 `update` 或退出 SU 强制，必须成对记录。不能把文档中的强制命令放进日常状态刷新。

第 11–12 页列出 firmware debug 类别、MURU 调试和 ICS 采集入口。这些编号依赖固件版本，开启日志本身也会影响 CPU、串口带宽和测试性能，应先核对本版固件命令表，不能将编号存在当作兼容证明。

## 性能结论的边界

第 7–8 页指出 OFDMA 在短 PPDU、多个用户、空口充分占用且各 RU 时长接近时更容易获得收益；长 PPDU 受最大时长限制，不一定减少 PPDU 数量。第 13 页的 2 个大流量加 14 个低速业务流，是混合负载实验，不是家庭网络必然收益的证明。

对我们有帮助的是建立按负载、方向、包大小和 STA 能力分类的验证方法，以及页面上区分支持、配置开启、调度实际发生三种状态。`PP=0x38` 子命令 3 被拒绝时，文档不足以区分字段不支持、状态不允许或固件版本限制；继续保留真实返回值与诊断，不能改成无条件成功。
