#
# Copyright (C) 2024 OpenWrt.org
# Copyright (C) 2024-2026 Felix Fietkau <nbd@nbd.name>
# Copyright (C) 2026 nanchuci <nanchuci023@gmail.com>
#
# This is free software, licensed under the GNU General Public License v2.
# See /LICENSE for more information.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=mtwifi-scripts
PKG_LICENSE:=GPL-2.0+
PKG_VERSION:=2.0
PKG_RELEASE:=22

PKG_MAINTAINER:=ChuCi Nan <nanchuci023@gmail.com>
PKG_CONFIG_DEPENDS:=CONFIG_WIFI_SCRIPTS_UCODE CONFIG_WIFI_SCRIPTS_WPS_BUTTON_DISABLED \
	CONFIG_MTK_WIFI7_OSAL_SUPPORT CONFIG_MTK_WIFI_OSAL_CFG80211_SUPPORT \
	CONFIG_MTK_WIFI7_CFG80211_SUPPORT CONFIG_MTK_WIFI7_IWCOMMAND_CFG80211_SUPPORT \
	CONFIG_MTK_WIFI7_CFG80211_FULL_OPS_SUPPORT CONFIG_MTK_WIFI7_HOSTAPD_MBSS_SUPPORT
PKG_FILE_DEPENDS:=../mtwifi-cfg/files/mtwifi-cfg/mtwifi_mlo \
	../mtwifi-cfg/files/mtwifi-cfg/mtwifi_defs.lua \
	../mtwifi-cfg/files/mtwifi-cfg/mtwifi-mlo-recover

include $(INCLUDE_DIR)/package.mk

define Package/mtwifi-scripts
  SECTION:=MTK Properties
  CATEGORY:=MTK Properties
  SUBMENU:=Applications
  TITLE:=mtwifi configure scripts for mt799x (ucode)
  DEPENDS:=+wifi-dats +netifd +iwinfo +iw +mwctl +hostapd-utils +wpa-cli wpad-openssl +@WIFI_SCRIPTS_UCODE \
	+ucode +ucode-mod-fs +ucode-mod-uci +ucode-mod-ubus +ucode-mod-uloop \
	+ucode-mod-nl80211 +ucode-mod-rtnl +ucode-mod-digest \
	+lua-cjson +libuci-lua +luci-lib-nixio \
	@MTK_WIFI7_CFG80211_SUPPORT @MTK_WIFI7_IWCOMMAND_CFG80211_SUPPORT \
	@MTK_WIFI7_CFG80211_FULL_OPS_SUPPORT @MTK_WIFI7_HOSTAPD_MBSS_SUPPORT \
	@(!MTK_WIFI7_OSAL_SUPPORT||MTK_WIFI_OSAL_CFG80211_SUPPORT)
  CONFLICTS:=wifi-scripts mtwifi-cfg
  PKGARCH:=all
endef

define Package/mtwifi-scripts/config
	source "$(SOURCE)/Config.in"
endef

define Package/mtwifi-scripts/description
  mtwifi driver glue for the netifd ucode wireless framework:
  L1 profile parsing, MTK .dat generation, hostapd/wpa_supplicant
  handling, VAP name allocation, WPS external registrar.
endef

define Build/Prepare
endef

define Build/Configure
endef

define Build/Compile
	$(foreach option,WIFI_SCRIPTS_UCODE MTK_WIFI7_CFG80211_SUPPORT \
		MTK_WIFI7_IWCOMMAND_CFG80211_SUPPORT MTK_WIFI7_CFG80211_FULL_OPS_SUPPORT \
		MTK_WIFI7_HOSTAPD_MBSS_SUPPORT,\
		$(if $(filter y,$(CONFIG_$(option))),,$(error mtwifi-scripts requires $(option)=y)))
endef

define Package/mtwifi-scripts/install
	$(INSTALL_DIR) $(1) $(1)/sbin
	$(CP) ./files/* $(1)/
	$(CP) ./files-ucode/* $(1)/
	$(LN) l1util $(1)/sbin/l1dat
	$(INSTALL_DIR) $(1)/usr/sbin $(1)/usr/lib/lua $(1)/etc/init.d $(1)/lib/upgrade/keep.d
	$(INSTALL_BIN) ../mtwifi-cfg/files/mtwifi-cfg/mtwifi_mlo $(1)/usr/sbin/mtwifi-mlo-status
	$(LN) mtwifi-mlo-status $(1)/usr/sbin/mtwifi-mlo-control
	$(INSTALL_DATA) ../mtwifi-cfg/files/mtwifi-cfg/mtwifi_defs.lua $(1)/usr/lib/lua/
	$(INSTALL_BIN) ../mtwifi-cfg/files/mtwifi-cfg/mtwifi-mlo-recover $(1)/etc/init.d/mtwifi-mlo-recover
	echo /etc/mtwifi-cfg/mlo-groups.json > $(1)/lib/upgrade/keep.d/mtwifi-mlo
ifeq ($(CONFIG_WIFI_SCRIPTS_WPS_BUTTON_DISABLED),y)
	rm -f $(1)/etc/rc.button/wps
endif
endef

$(eval $(call BuildPackage,mtwifi-scripts))
