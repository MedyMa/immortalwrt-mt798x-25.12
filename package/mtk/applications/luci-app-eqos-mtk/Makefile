include $(TOPDIR)/rules.mk

PKG_RELEASE:=5

LUCI_TITLE:=LuCI support for Easy QoS
LUCI_DEPENDS:=+tc-full +ip-full +flock +nftables +rpcd +jshn +kmod-sched-core +kmod-ifb +kmod-mediatek_hnat @!PACKAGE_luci-app-eqos

PKG_MAINTAINER:=Jianhui Zhao <jianhuizhao329@gmail.com>
PKG_NAME:=luci-app-eqos-mtk

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
