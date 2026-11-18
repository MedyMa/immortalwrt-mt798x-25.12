# MTK SDK 参考源码缓存

2026-11-16 从用户指定的 `benboguan/immortalwrt-mt799x` 固定提交
`38666f1d78047eb78036fa4d2b7b96880cefcaa3` 引入 10 个参考归档。
逐项 SHA-256、上游 Git blob SHA-1、大小、原 URL、源码/ELF 数量和许可证成员见
[`package/mtk/pdf/knowledge/index.json`](../package/mtk/pdf/knowledge/index.json) 的 `source_cache` 部分。

| 新归档 | 用途 |
| --- | --- |
| mt799x_20250613-415824.tar.xz | 对照 Wi-Fi 7 SDK 控制路径、profile、HWIFI、MCU 与协议实现 |
| warp_20250613-433271.tar.xz | 阅读 WED/WO 平台 glue；不替换当前 warp 实现 |
| datconf-19d67f.tar.bz2 | 由 `package/mtk/applications/datconf` 校验 SHA-256 后构建，文件截断在加锁后执行 |
| 1905daemon-42cf90.tar.bz2 | Multi-AP/1905 协议与角色、事件接口 |
| libmapd-e1e011.tar.bz2 | MAPD control/client 接口 |
| libwpactrl-dcc1d7.tar.bz2 | WAPP 与 hostapd/supplicant 的控制连接 |
| mapd-9742ce.tar.bz2 | Mesh 拓扑、steering、规划、配置解析 |
| mapfilter-70fcdd.tar.bz2 | Mesh 协议转发与流量隔离相关内核组件 |
| mtfwd-30b1ab.tar.bz2 | 配套转发模块的参考实现 |
| wappd-24f7e6.tar.bz2 | 无线应用接口、事件及配置保存 |

这批归档均已解包，并核对大小、SHA-256、Git 对象哈希及文件清单。
现用 Wi-Fi 驱动和 WARP 来自 BPI-R4 的构建输入。1905daemon、libmapd、libwpactrl、
mapd、mapfilter、mtfwd 和 wappd 保留供源码对照，EasyMesh 依赖配套协议、服务和驱动接口。
已有同内容的 OSAL、fwdd 和 wificonf 归档继续由原包配方管理。

通过纯读取工具检索，不运行归档中的脚本或二进制：

```sh
python3 scripts/mtk-sdk-reference.py verify
python3 scripts/mtk-sdk-reference.py archive-list mapd-9742ce.tar.bz2
python3 scripts/mtk-sdk-reference.py archive-search wappd-24f7e6.tar.bz2 wireless
python3 scripts/mtk-sdk-reference.py archive-search mt799x_20250613-415824.tar.xz UniCmdPPCapCtrl
```

归档保留上游原始成员、版权和许可；有些 source 包也包含固件或 ELF，对其功能或许可不能仅凭扩展名推断。
