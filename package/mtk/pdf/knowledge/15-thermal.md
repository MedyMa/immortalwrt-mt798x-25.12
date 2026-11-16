# 热保护：Duty control、迟滞与状态查询

文档 ID：`thermal`。来源：`MT7996 Thermal Protection Application Note v1.0.pdf`，13 页，2023-06-09。重点：第 4–12 页，参数表第 5–6 页已补 OCR。

热保护可降低 TX duty，或者通过其他机制降低功率/空间流。本应用说明主要讨论 duty control，不能据此推导完整温度补偿算法。自动模式按阈值切换 0–3 级，低阈值用于恢复，形成迟滞；手动强制级别会绕开正常的自动决策。

## 字段和查询

`thermal_protect_enable` 的六项为 band、protection type、trigger type、触发温度、恢复温度、recheck 时间。第 5 页参数表把时间标为秒；示例中的 0005 不是 5 ms。当前 `mt_wifi/common/cmm_cfg.c` 的 `SetThermalProtectEnable` 将最后一项解析为 UINT16，温度为 INT32；还需要核对固件的实际解释及范围。

`thermal_protect_duty_cfg` 是 band/level/duty%，文档 duty 0–100；`thermal_protect_state_act` 用于强制状态；disable 会关闭保护。这几类均是状态修改，不能加入温度采集。

`thermal_protect_info`、`thermal_protect_duty_info` 是查询入口线索，语法含 set 也不意味着它们在调整阈值。`stat` 的 CurrentTemperature 是 Wi-Fi 芯片温度，不能与 SoC 的某个 thermal zone 或 SSD SMART 温度混合标注。

## 文档中的陷阱

- 120/114 °C 是实验示例，不是 BPI-R4/BE14 的推荐工作温度。
- 第 11 页 5G、2.4G 示例仍写 rax0，却给不同 band index；接口和 band 不能原样照抄。
- Radio-off 类型会停止无线业务，和减小 duty 的行为不同。
- 主机 parser 返回 TRUE 不必然表示所有参数已通过固件验证，后续实现应保留真实命令结果。

## 对我们的帮助

可用来区分热导致的吞吐下降与无线链路故障，为温度页面增加来源、band、采样时间和无数据状态。当前仓库的 autocore 已有 mwctl/iwpriv 回退及超时边界，不能退回无超时的循环查询；风扇策略和 MCU 热保护是不同控制层。测试以读取现有状态和受控负载为主，不自动运行文档中的关闭保护或高温强制实验。
