# TWT：协商、广播与会话暂停恢复

文档 ID：`twt`。来源：`MT7996 TWT Application Note v1.0.pdf`，16 页，2023-06-21。重点：第 4–15 页；第 7–15 页截图已补 OCR。

## 模型

TWT 协商让 STA 在服务周期内收发，降低竞争和唤醒时间。必须分别识别 implicit/explicit、announced/unannounced、trigger/non-trigger、individual/broadcast。配置开关、HE capability 宣告、setup request/response、agreement table 和实际周期性流量是不同层次。

第 6–7 页描述 individual TWT；第 11–13 页描述 broadcast TWT，profile 示例为 `TWTSupport=2`。当前解析入口在 `mt_wifi/profiles/cmm_profile.c`，构建选项为 `CONFIG_MTK_WIFI7_WIFI_TWT_SUPPORT`。不要把 TWTSupport 永久当成布尔值：当前代码与样例可能支持多种组合，具体值应继续对照 `wlan_config_set_he_twt_support` 及使用者。

## 协商与查询

第 8–10 页展示 APCLI 发起协商、抓取 TWT action frame、查询 node/link status。字段包括 WCID、flow ID、agreement table index、service period、interval exponent、TSF、suspend 状态。图中的 SP 单位为 256 µs，但不能把所有 interval/TSF 字段都按这个单位换算。

第 12 页的 `btwt` 子命令涵盖列出、创建和释放元素；`ApCliTwtParams` 会改变协商状态。OCR 对大小写、冒号、连字符及长参数容易出错，本库不把识别出的长串配置直接变成可执行脚本。

## 信息帧与版本限制

第 14 页说明 TWT Information frame 不含 Next TWT 时暂停会话，包含 Next TWT 时可在指定时刻恢复，profile 为 `TWTInfoFrame`。第 13、15 页说明当时的 MTK APCLI 不能验证 BTWT/TWT information frame，需要支持能力的其他 STA。它是 2023 年的能力描述，不能据此断言当前固件已经支持或仍不支持。

## 对我们的帮助

适合改进睡眠终端状态解释及协议测试，避免把正常休眠误判离线。MAC/主机名相同不等于同一 TWT agreement；MLO link、WCID、flow ID 和生命周期要一起考虑。TWT 是 Wi-Fi 协议，不是 NVMe APST，不能用于推断 SSD 电源状态。验证应覆盖关联、建立、空闲、负载、暂停/恢复、重关联与无线 reload，关注 agreement 资源是否释放；不通过强制 TWT 命令处理偶发重启问题。
