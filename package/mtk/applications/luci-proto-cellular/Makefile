# SPDX-License-Identifier: Apache-2.0
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-proto-cellular
PKG_VERSION:=1.0
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/luci-proto-rmnet
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=6. Protocols
  TITLE:=LuCI support for the vendor RMNET IPv4 and IPv6 handlers
  DEPENDS:=+luci-base
endef

define Package/luci-proto-rmnet/description
  LuCI definitions for already installed vendor rmnet and rmnet6 handlers.
  The connection manager is selected separately: quectel-CM-5G and the
  feed's quectel-cm both install quectel-CM and must not be forced together.
endef

define Package/luci-proto-wwan
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=6. Protocols
  TITLE:=LuCI support for automatic USB WWAN setup
  DEPENDS:=+luci-base +wwan
endef

define Build/Compile
endef

define Package/luci-proto-rmnet/install
	$(INSTALL_DIR) $(1)/www/luci-static/resources/protocol
	$(INSTALL_DATA) ./files/rmnet.js ./files/rmnet6.js $(1)/www/luci-static/resources/protocol/
endef

define Package/luci-proto-wwan/install
	$(INSTALL_DIR) $(1)/www/luci-static/resources/protocol
	$(INSTALL_DATA) ./files/wwan.js $(1)/www/luci-static/resources/protocol/
endef

$(eval $(call BuildPackage,luci-proto-rmnet))
$(eval $(call BuildPackage,luci-proto-wwan))
