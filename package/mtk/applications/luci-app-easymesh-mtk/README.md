# MediaTek EasyMesh：25.12 原生无线后端集成

适用于本源码树的 `mt_wifi7` 私有驱动、`mtwifi-cfg`、netifd 和 hostapd 后端。
LuCI 提供基础设置、入网引导、状态、客户端、MLO 五个页面。
运行代码和依赖均由源码包安装。

## 构建与默认状态

先选择完整的 `wpad-openssl`（私有版 defconfig 已有），然后选择：

```text
CONFIG_PACKAGE_luci-app-easymesh-mtk=y
```

该包自动选择 MAP R2/R3、6 GHz、MAP hostapd、MBO、WAPP WPA control，以及
`mapd`、`1905daemon`、`wapp`、`libmapd`、`libwpactrl` 和 `kmod-mapfilter`。
LuCI 和 RPC 使用的 Lua 运行库由依赖提供。不支持仅复制网页文件安装。
普通版固件的 defconfig 不需要添加这些私有驱动选项。

首次安装默认关闭 EasyMesh，`DhcpCtl=0`。升级时保留用户配置；旧配置中显式启用的
DHCP 控制也会保留，需要在使用前检查。默认 AL MAC 取当前 LAN 桥的 MAC，
不再为所有节点设置相同的示例 MAC。

## 部署

1. 在“网络”中先配置好每台设备的地址、LAN 桥和 DHCP。Controller 与 Agent
   使用同一现有桥接 LAN；有线回程连接 LAN 端口。避免网络内出现多个 DHCP 服务器。
2. 在无线页面设置合法地区、频段和 WPA2/WPA3 密码。无线回程需要加密；
   6 GHz 不支持 WPS。多链路组的 SSID、密码和认证方式必须一致。
3. 在 EasyMesh 基础设置中选择 LAN 网络、Controller/Agent 角色和相同的 MAP 版本，
   启用后保存应用。支持 MAP R1、R2、R3；DPP 需要 R3。
4. 有线回程先检查拓扑。无线回程可在两端发起 WPS，或在 Agent 获取 DPP URI，
   再交给 Controller 发起 DPP 入网。按钮成功提示表示控制请求已接受；
   是否加入成功，以拓扑和实际回程链路为准。

集成使用单个已有 LAN 桥。参与 MAP 的活动 AP/STA 必须只属于所选网络；
混合访客网络会明确报错。这里没有配置跨 VLAN 的流量隔离。
服务不会创建 LAN 桥、搬动 WAN 端口或代替“网络”页面配置 DHCP。

## 服务和持久化

`mapd` 包安装 `/etc/init.d/easymesh`、`/usr/libexec/mtk-easymesh`
和共享 Lua 适配层。服务由 procd 管理，按控制套接字就绪顺序启动
`wapp` → `p1905_managerd` → `mapd`；无线或 LAN 重新就绪后重新准备运行配置。
不会调用 SDK 中会重建桥和 DHCP 的整机初始化脚本。

适配层根据 L1 profile 和实际接口状态识别 `ra*`、`rai*`、`rax*`、`apcli*`，
不把 PCI 路径或假定的 PHY 编号传给守护进程。`map_mode` 经 netifd 写入驱动 DAT；
MAP AP 使用 hostapd 全局控制接口，动态 BSS 采用实际注册的 PHY。
新增 BSS 必须使用连续的空闲 AP 槽，不能跳号创建。

Agent/Auto 角色按参与的无线电创建受管理的回程 STA。已有用户 STA 保留其配置；
Controller 或关闭 Mesh 时禁用自动创建的 STA。WPS/DPP 学到的 AP 凭据写回相应
`wireless` section；受管理 STA 的凭据保存到私有文件并在无线重载时恢复。
这些文件包含密码，权限为 0600。故障材料请勿公开上传这些配置。

| 配置 | 用途 |
|---|---|
| `/etc/config/mapd` | 服务开关、角色、引导、优化、Controller BSS/回程 MLD profiles |
| `/etc/config/1905d_cfg` | MAP 版本、可选 AL MAC |
| `/etc/config/wireless` | 本机 AP/STA、MAP 模式、本机 MLO 分组 |
| `/etc/map/mapd_cfg`、`/etc/map/1905d.cfg` | 根据 UCI 和实际 LAN 生成的守护进程配置 |
| `/etc/map/wts_bss_info_config` | Controller 分发给 Agent 的 BSS profiles |
| `/etc/map/wts_bsta_mlo_config` | Agent 回程 MLD profiles |
| `/var/run/easymesh/platform.json`、`error` | 当前平台状态和最近一次服务错误，不含无线密码 |

MLO 页的本机 `wireless.mldgroup` 范围为 0–16；Controller 分发使用
`mapd` 的 `iface` sections 和 `mld_groupID`，0 表示不分组，1–16 为多链路组，
17–48 为单链路 profiles。无显式 BSS profiles 时，从本机活动 AP 生成。
`bh_sta` sections 的链路数必须与无线电列表相符。配置通过校验不代表设备已建立多链路。

## 诊断

```sh
ubus call easymesh-mtk get_status
ubus call easymesh-mtk get_interfaces
ubus call easymesh-mtk get_clients
ubus call easymesh-mtk get_uri '{"ifname":"rai0"}'
ubus call easymesh-mtk action '{"action":"wps","band":"all","uri":""}'
ubus call easymesh-mtk restart
logread -e easymesh
```

状态页分别显示配置开关、开机启用状态、三个实际进程、mapd 控制套接字、LAN 桥、
拓扑和守护进程输出。只有进程及套接字均就绪时才显示运行。
客户端页仅展示本机 `iw` 查询到的终端，不冒充全网客户端表；无法判断的回程身份
显示 Unknown。接口速率或 Mesh 状态不作为 NPU、PPE、EIP 硬件加速的证据。

## 验证

原生运行回归需要 Lua 5.1、lua-cjson、libuci-lua 和 nixio：

```sh
lua package/mtk/applications/mapd/tests/runtime.lua "$PWD" /tmp/easymesh-new-test-directory
node package/mtk/applications/luci-app-easymesh-mtk/tests/views.js
python3 package/mtk/applications/mapd/tests/netifd.py
```

测试目录必须不存在。运行测试会把配置、sysfs 和运行文件重定向到该目录，
模拟路由器控制命令，不接触真实无线设备。前端测试覆盖 UCI 保存和 RPC 参数契约。
构建还需验证用户态程序、MAP 驱动和 mapfilter 的交叉编译及最终模块链接。

发布验收需要两台实际支持的设备：检查三频启动、有线发现、WPS/DPP 无线入网、
重载/重启后凭据恢复、Controller 与 Agent 拓扑一致、客户端漫游和实际 MLO 链路。
编译及模拟回归不能替代这些设备测试，也不构成 Wi-Fi EasyMesh 认证。
