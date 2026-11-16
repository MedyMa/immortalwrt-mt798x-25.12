# Single SKU 与波束成形功率回退

文档 ID：`single-sku`。来源：`MT7996 Single SKU Application Note v1.0.pdf`，20 页，2023-06-21。重点：第 4–19 页。

## 两张表和三种量

Single SKU 按信道、PHY、带宽和速率限制功率；BF Backoff 还考虑发射天线数、数据流及 BF 状态。表中的 per-chain power 不等于总发射功率或 EIRP；PSD 限制也不能直接换成固定总 dBm。文档按功率限制、PSD 限制分别说明 SKU 与 backoff 表的合成方法，不能将不同地区/工作模式的表混用。

第 5、15 页称表的单位是 dBm、分辨率 0.5 dBm。EEPROM DAC、MCU 有符号半 dB 编码、UI 的 dBm 和表格十进制字符串是不同表示，写 parser 前必须逐层确认转换，不能一律乘二或除二。

## RU 与构建流程

第 7 页的 RU 表说明固件 TPA 算法参与 HE/EHT MU 发射功率分配；SU、MU 的目标项对应不同 RU/BW 列。文档把 RU996×2、×4 分别关联 160/320 MHz，不能据此假设所有板卡有该带宽或空间流能力。

第 8、16 页的表格导出流程：SKU_OUT/Back_off_OUT→CSV/.dat→`sku_tables`→`build_power_limit_tables`→生成的 `PowerLimit_sku.h`。这是该 SDK 的构建时输入。替换当前运行系统的一个 `.dat` 文件不等于重新编译进驱动的功率表已更新。

## 运行开关与查询限制

`SKUenable`、`BFBACKOFFenable` 和 `SkuTableIdx` 按 band 生效；BF Backoff 使用同一表索引。当前 profile 解析在 `mt_wifi/profiles/cmm_profile.c`。需要核对实际选用表、国家码、天线配置、固件及温度补偿等共同限制。

第 11–12、19 页用 `TxPowerInfo=0/2` 查询状态/速率功率表，虽带 `set` 语法却是查询入口；仍需确认当前命令表。第 19 页特别指出普通速率功率表不反映 BF Backoff，因此不能凭一张表数值不变判断 BF 回退没有执行。

## 对我们的帮助

适合改进功率状态解释、单位显示及配置依赖，避免把“25 dBm”当作所有帧实际 EIRP。更换表须有相应硬件测量数据；本次没有替换 SKU 表、关闭 backoff、修改国家码或提高发射功率。文档的 21 套表编号不是地区码枚举的通用定义。
