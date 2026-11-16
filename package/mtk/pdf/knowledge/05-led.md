# Wi-Fi LED 的行为设置与硬件边界

文档 ID：`led`。来源：`MT7996 LED Application Note v1.0.pdf`，10 页，2023-06-21。技术内容第 4–9 页，GPIO 附录为截图。

文档控制 Wi-Fi 芯片的 WF LED。第 5 页的驱动宏 `CONFIG_LED_CONTROL_SUPPORT` 在本仓库对应 `CONFIG_MTK_WIFI7_LED_CONTROL_SUPPORT`；还必须有实际硬件连接和有效 pinmux，仅编译选项存在不会生成任意机箱灯的 GPIO 路径。

## 协议结构

`led_setting=AA-BB-CC-DD-EE-FF` 的六个字段分别为 TX blink 覆盖固定闪烁、反相、TX 包类型、熄灭时长、点亮时长、行为索引。时长示例单位为 10 ms。CC 的 0/1/2 区分全部包、排除 beacon、仅数据帧，因此仅有 beacon 的空闲 AP 也可能呈现不同灯效。

第 7 页列出主要 FF：0 常亮，1 常灭，2 TX 闪烁，3–9 为固定周期，16–18 为 WPS 行为，31 为自定义闪烁。不是每个索引都使用所有字段；反相位会改变物理亮灭极性，不能把输出电平直接解释为状态。

## 适用性核对

解包源可从 `mt_wifi/include/rt_led.h`、`mt_wifi/hw_ctrl/eeprom.c` 和 `LED_CONTROL_SUPPORT` 的条件编译继续追踪。第 9 页是 MT7990 封装/信号映射，不是 BPI-R4 机箱布线图；OCR 对该表的管脚字符不可靠，未将其转换为自动寄存器写入。

Wi-Fi LED、Linux `gpio-leds`/netdev trigger、U-Boot status LED、NVMe 活动灯是不同控制层。资料不能证明 SSD 灯可被 Wi-Fi LED 命令控制，也不构成板卡设计缺陷的证据。

## 可用于源码的改进

以后设计 LED 设置应先验证板卡设备树、连线和控制器，再提供与能力匹配的行为。对 DD/EE 做解析范围检查；文档声称 8 bit 对应上限 2560 ms，但 8 bit 的数值上限与其表述存在边界差异，应以当前 parser 为准。验证只观察已经确认归属的 LED，不试写未知 GPIO/pinmux。当前未修改 LED 启动或重启行为。
