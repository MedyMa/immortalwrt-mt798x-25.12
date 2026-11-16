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
PKG_RELEASE:=5

PKG_MAINTAINER:=ChuCi Nan <nanchuci023@gmail.com>
PKG_CONFIG_DEPENDS:=CONFIG_WIFI_SCRIPTS_UCODE CONFIG_WIFI_SCRIPTS_WPS_BUTTON_DISABLED

include $(INCLUDE_DIR)/package.mk

define Package/mtwifi-scripts
  SECTION:=MTK Properties
  CATEGORY:=MTK Properties
  SUBMENU:=Applications
  TITLE:=mtwifi configure scripts for mt799x (ucode)
  DEPENDS:=+wifi-dats +netifd +iwinfo +iw +mwctl +hostapd-utils +wpa-cli wpad-openssl \
	+ucode +ucode-mod-fs +ucode-mod-uci +ucode-mod-ubus \
	+ucode-mod-nl80211 +ucode-mod-rtnl +ucode-mod-digest \
	@MTK_WIFI7_CFG80211_SUPPORT @MTK_WIFI_OSAL_CFG80211_SUPPORT
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
endef

define Package/mtwifi-scripts/install
	$(INSTALL_DIR) $(1) $(1)/sbin
	$(CP) ./files/* $(1)/
	$(CP) ./files-ucode/* $(1)/
	$(LN) l1util $(1)/sbin/l1dat
ifeq ($(CONFIG_WIFI_SCRIPTS_WPS_BUTTON_DISABLED),y)
	rm -f $(1)/etc/rc.button/wps
endif
endef

$(eval $(call BuildPackage,mtwifi-scripts))
