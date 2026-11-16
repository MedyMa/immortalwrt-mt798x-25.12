# 3-Wire PTA：Wi-Fi 与外部无线器件共存

文档 ID：`pta`。来源：`MT7996 PTA Application Note v1.0.pdf`，9 页，2023-06-21。重点：第 4–8 页。

PTA（Packet Traffic Arbitration）用于 Wi-Fi 与外部 BLE 等器件的收发仲裁。它不是 Wi-Fi 7 preamble puncturing 的 PP，也不是 QoS 的 Packet Prioritizing。第 7 页说明外部接收和 Wi-Fi 发送不能共存时，仲裁策略可撤销 Wi-Fi TX；因此误配可能直接表现为吞吐异常，而不是额外获得一种提速能力。

## 必须同时确认的层次

第 5 页给出 `ThreeWireFunctionEnable=1` 及外部 pinmux 示例。当前驱动的 `mt_wifi/profiles/cmm_profile.c` 确有该 profile 键，但软件支持不能证明板上已经把 REQUEST/PRIORITY/GRANT 等信号连接到目标器件。第 6、8 页的接线和 pinmux 主要在图中；OCR 已保留，实际使用前仍要核对原图与本板原理图。

文档中的 `mwctl ... mac 70005310=11111111` 会写寄存器，不属于查询。固定地址和数值只适用于文档的参考硬件。本文档路径里还有 `/etc/wirless` 的拼写错误，不能原样变成脚本。

## 对源码的帮助

可用于将来增加外部蓝牙/共存模块时设计能力探测、板卡数据与互斥配置。合理的实现需要把硬件连线、极性、pinmux、驱动开关及 firmware arbitration 策略作为一个组合验证，不能在通用 defconfig 默认打开。当前 BE14 是否具备相应外部连接尚无该资料能证明的结论，本次没有添加 PTA 寄存器写入。
