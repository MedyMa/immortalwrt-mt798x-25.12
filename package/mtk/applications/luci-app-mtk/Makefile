# SPDX-License-Identifier: Apache-2.0

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-mtk
PKG_VERSION:=2026.11.06
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0
PKGARCH:=all
PKG_MAINTAINER:=MedyMa

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-mtk
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=MTK platform applications
  DEPENDS:=+luci-base +luci-app-turboacc-mtk +luci-app-traffic +luci-app-fan +luci-app-hqos-mtk
endef

define Build/Compile
endef

# This package groups the maintained applications. The legacy vendor wireless
# controllers and templates are not installed alongside mtwifi-cfg.
define Package/luci-app-mtk/install
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./files/luci-app-mtk.json $(1)/usr/share/luci/menu.d/
endef

$(eval $(call BuildPackage,luci-app-mtk))
