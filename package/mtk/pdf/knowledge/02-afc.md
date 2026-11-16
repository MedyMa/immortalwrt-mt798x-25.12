# AFC：6 GHz 标准功率授权链路

文档 ID：`afc`。来源：`MT7996 AFC Application Note v1.0.pdf`，15 页，版本日期 2023-06-21。重点：第 4–8、11–14 页；截图页已有独立 OCR 文本，OCR 字符不作为直接执行依据。

## 文档限定的范围

该版本把 AFC 实现限定在 US/FCC 的 6 GHz 标准功率设备。它描述设备提交位置、天线高度、位置不确定性、设备标识和频谱请求，再从服务端获取允许使用的频率/信道及最大功率。AFC 不等于 6 GHz 基本支持，也不能把 LPI 模式、国家码选择、固件支持与标准功率授权合并成一个开关。

第 5 页的 TLS 要求包含 URL 主机名、证书链和 CA 信任校验。示例服务器、bearer token、经纬度和设备序列号都是演示值，不能放进产品默认配置。WAN 可访问是第 7 页的前置条件；仍需检查系统时间、DNS、TLS 和授权回复有效性。

## 配置与完整调用链

第 7 页截图包括 `AfcDeviceType`、`AfcSpectrumType`、频率范围、operating class 和 `ACSAfterAFC`；位置配置示例路径为 `/etc/afc/location.cfg`。第 8 页给出 AFC 用户态程序作用于 6 GHz 接口的流程。必须同时具备 daemon、驱动能力、当前固件支持、正确位置和有效回复，单独启用驱动宏不会完成这条链。

当前仓库的配置符号是 `CONFIG_MTK_WIFI7_6G_AFC_SUPPORT`，在 `package/mtk/drivers/mt_wifi7/config.in` 定义，并由 Makefile 转换到驱动的 `CONFIG_6G_AFC_SUPPORT`。解包源码的 `mt_wifi/profiles/cmm_profile.c` 可检索 `AfcDeviceType`。文档菜单显示名称 `WIFI_6G_AFC_SUPPORT`，不是可以原样复制的 OpenWrt Kconfig 符号。

## 当前适用性与改进价值

当前固件没有因为存入本资料而增加 AFC 服务或改变国家码/功率。AFC 适合作为未来功能的依赖与状态建模参考：区分未构建、daemon 未运行、位置缺失、授权失败、授权到期、信道不可用。不能把普通 Wi-Fi MCU 命令返回成功等同于获得授权。

对以后接口设计有用的校验点包括频率区间有序、宽度及单位一致、未知 operating class 拒绝而非猜测、回复与设备/请求匹配，以及授权不可用时的明确状态。具体失效处理要再对照现行协议和当地规则，本 2023 年文档不是当前所有地区的完整规范。

## 文档缺口

第 7–14 页关键内容主要为截图。OCR 中 `AfcFreqrange`、`ACSAfterArC` 等存在错字的可能，不能据此生成配置键。需要修改这些字段时，先读原图并核对本版 parser。第 9 页指向旧 21.02 SDK 和内网构建工具，不可作为本仓库 25.12 的构建步骤。
