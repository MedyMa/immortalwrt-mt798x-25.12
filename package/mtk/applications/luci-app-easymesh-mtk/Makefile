# SPDX-License-Identifier: GPL-2.0
# MediaTek EasyMesh (MAP Turnkey) LuCI application for OpenWrt 25.12+
# Native LuCI JavaScript views with a Lua rpcd backend and MAP adapter.

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-easymesh-mtk
PKG_VERSION:=2.0.0
PKG_RELEASE:=2
PKG_LICENSE:=GPL-2.0
PKG_MAINTAINER:=MTK EasyMesh maintainers

LUCI_TITLE:=LuCI support for MediaTek EasyMesh (MAP Turnkey)
LUCI_DEPENDS:=@PACKAGE_kmod-mt_wifi7 @PACKAGE_wpad-openssl +luci-base +rpcd +mtwifi-cfg +libmapd +libwpactrl +mapd +wapp +1905daemon +kmod-mapfilter \
	+@MTK_WIFI7_MAP_SUPPORT +@MTK_WIFI7_MAP_R2_VER_SUPPORT +@MTK_WIFI7_MAP_R3_VER_SUPPORT \
	+@MTK_WIFI7_MAP_R2_6E_SUPPORT +@MTK_WIFI7_MAP_R3_6E_SUPPORT +@MTK_WIFI7_MAP_HOSTAPD_SUPPORT \
	+@MAP_R2_SUPPORT +@MAP_R3_SUPPORT +@WAPP_WPACTRL_SUPPORT
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
