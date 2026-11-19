# BPI-R4 BE14 接入 UniFi Network

`be14-ucg` 在 R4 上向指定控制器的 `/inform` 发起连接。协议使用三频 U7 Pro 的型号与版本字段，设备名和管理 MAC 来自 R4。UCG 可能将它显示为 U7 Pro。软件包随 WEXT 固件安装，首次启用需要指定控制器地址。

## 启用采用

在 R4 的 `/etc/config/be14_ucg` 中设置控制器的实际 IP 和 R4 已有的管理网络。下面的地址为示例。

```uci
config agent 'main'
        option enabled '1'
        option inform_url 'http://192.0.2.1:8080/inform'
        option management_network 'lan'
```

执行 `/etc/init.d/be14-ucg enable` 和 `/etc/init.d/be14-ucg restart`。在 UniFi Network 的设备列表中选择这台 R4 的 MAC 并采用。控制器如果要求通过 SSH 采用，请使用高级采用和 R4 已有的 SSH 管理凭据。自定义 SSH 端口可填入 `option sshd_port`。首次采用应在受信任的管理网络进行。更改控制器 IP 前需在维护窗口重新配对。采用密钥保存在 R4 的 `/etc/be14-ucg/state.json`，服务重启和保留配置升级都会沿用它。

## 绑定测试 WLAN

在 UCG 创建一个普通、无 VLAN 标签的个人 WLAN，记录其 24 位十六进制 WLAN ID。在 R4 上选择已运行的独立测试 AP。其 UCI 节名须以 `be14_ucg_` 开头，`mode` 为 `ap`，`mldgroup` 显式为 `0`，并接到预定的测试网络。可用 `l1util list` 查看真实无线设备的 UCI 名称。例如 `be14_ucg_five` 可以绑定在已改名的 5 GHz 设备上。

在同一个 `config agent 'main'` 段加入实际的 WLAN ID 和测试 AP 的节名，然后重启服务。每个频段可以列一个节，同一 WLAN 在 UCG 上也要启用相应频段。

```uci
        option wlan_id '0123456789abcdef01234567'
        list section 'be14_ucg_five'
```

支持通过 GCM 或经证书验证的 HTTPS 下发测试 SSID、PSK/SAE 口令、PMF、隐藏和客户端隔离，6 GHz 支持 SAE 和 OWE。当前管理范围为一个指定 WLAN 的独立 AP。VLAN、访客门户、MLO 组、控制器远程刷机和全站无线电参数在此版本的管理范围以外。代理只向 UCG 发送 `iwinfo` 实测到的活动 SSID。配置变化后由 netifd 重载，无线回读超时会恢复先前的绑定配置。日志可用 `logread -e be14-ucg` 查看。

## 实机验收

1. 在 Cloud Gateway Fiber 的 UniFi Network 11.1.50 上，确认 R4 的管理 MAC 从「等待采用」变为「在线」。
2. 重启 R4，确认相同设备记录自动在线，并显示 2.4、5、6 GHz 三个无线电。
3. 在 UCG 修改绑定的测试 SSID。用另一台支持对应频段的终端扫描并连接新名称，核对 BSSID 和连接频段。R4 上可用 `ubus call network.wireless status` 确定接口，再用 `iwinfo <接口名> info` 交叉检查。
