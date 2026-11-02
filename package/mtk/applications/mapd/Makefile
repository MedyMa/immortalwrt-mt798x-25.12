#
# yogender.pathak@mediatek.com
#
# MTK Property Software.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=mapd
PKG_REVISION:=9742ce
PKG_SOURCE:=$(PKG_NAME)-$(PKG_REVISION).tar.bz2
PKG_RELEASE:=2

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)
PKG_CONFIG_DEPENDS:=CONFIG_MAP_R2_SUPPORT CONFIG_MAP_R3_SUPPORT CONFIG_MAP_R4_SUPPORT CONFIG_MAP_R5_SUPPORT \
	CONFIG_MTK_WIFI7_MAP_R2_6E_SUPPORT CONFIG_MTK_WIFI7_MAP_HOSTAPD_SUPPORT \
	CONFIG_MTK_WIFI7_MAP_R6_SUPPORT CONFIG_MTK_WIFI7_MAP_VENDOR_SUPPORT CONFIG_MTK_EM_PLUS_SUPPORT

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/kernel.mk

TARGET_CFLAGS += -DCONFIG_SUPPORT_OPENWRT \
	-Wno-error=unused-but-set-variable \
	-Wno-error=address-of-packed-member \
	-Wno-error=unused-function
MAKE_FLAGS += CONFIG_SUPPORT_OPENWRT=y

PKG_BUILD_DEPENDS:=libmapd
define Package/mapd
  SECTION:=MTK Properties
  CATEGORY:=MTK Properties
  TITLE:=map daemon
  SUBMENU:=Applications
  DEPENDS:=+wapp +1905daemon +libmapd +libjson-c +libcurl +MTK_WIFI7_MAP_HOSTAPD_SUPPORT:mtwifi-cfg \
	+MTK_WIFI7_MAP_HOSTAPD_SUPPORT:hostapd-utils +MTK_WIFI7_MAP_HOSTAPD_SUPPORT:wpa-cli \
	+MTK_WIFI7_MAP_HOSTAPD_SUPPORT:coreutils-timeout
endef

define Package/mapd/description
  Multi AP daemon from mediatek.
  yogender.pathak@mediatek.com
endef

define Package/mapd/config
	if PACKAGE_mapd
		config MAP_R2_SUPPORT
			bool "MAPR2"
			default n
		config MAP_R3_SUPPORT
			bool "MAPR3"
			default n
		config MAP_R4_SUPPORT
			bool "MAPR4"
			default n
		config MAP_R5_SUPPORT
			bool "MAPR5"
			default n
	endif
endef

define Package/mapd/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/mapd $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/mapd_cli $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/bs20 $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/mapd_user_iface $(1)/usr/bin
	$(INSTALL_DIR) $(1)/etc
	$(INSTALL_DIR) $(1)/etc/map
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/EasyMesh_openwrt5x.sh $(1)/usr/bin/EasyMesh_openwrt.sh; \
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/config_agent.lua $(1)/usr/bin; \
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/map_config_agent.lua $(1)/usr/bin; \
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/map_cert_script.sh $(1)/usr/bin; \
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/brsw-del.sh $(1)/usr/bin;
	$(CP) $(PKG_BUILD_DIR)/wts_bss_info_config  $(1)/etc/map
	$(CP) $(PKG_BUILD_DIR)/mapd_user.cfg $(1)/etc/map
	$(CP) $(PKG_BUILD_DIR)/mapd_default.cfg  $(1)/etc/map
	$(INSTALL_DIR) $(1)/etc/init.d
ifeq ($(CONFIG_MTK_WIFI7_MAP_HOSTAPD_SUPPORT),y)
	$(INSTALL_DIR) $(1)/usr/lib/lua/mtk $(1)/usr/libexec
	$(INSTALL_DATA) ./files/easymesh.lua $(1)/usr/lib/lua/mtk/easymesh.lua
	$(INSTALL_BIN) ./files/mtk-easymesh $(1)/usr/libexec/mtk-easymesh
	$(INSTALL_BIN) ./files/easymesh.init $(1)/etc/init.d/easymesh
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/90-easymesh $(1)/etc/uci-defaults/90-easymesh
	$(INSTALL_DIR) $(1)/lib/upgrade/keep.d
	$(INSTALL_DATA) ./files/keep.d $(1)/lib/upgrade/keep.d/easymesh
else
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/easymesh_init $(1)/etc/init.d/easymesh
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/easymesh_bridge_init $(1)/etc/init.d/easymesh_bridge
endif
endef

$(eval $(call BuildPackage,mapd))
