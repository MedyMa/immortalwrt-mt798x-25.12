# SPDX-License-Identifier: GPL-2.0-only
include $(TOPDIR)/rules.mk

PKG_NAME:=mtk-npu-tunnel
PKG_VERSION:=0.1
PKG_RELEASE:=2
PKG_LICENSE:=GPL-2.0-only
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/mtk-npu-tunnel
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=VPN
  TITLE:=MT7988 NPU L2TP/IPsec policy controller
  DEPENDS:=@TARGET_mediatek_filogic_a73 \
	firewall4 +ip-full +uci +ubus +coreutils-timeout \
	+strongswan-default +strongswan-mod-kdf +strongswan-swanctl \
	+xl2tpd +ppp-mod-pppol2tp +kmod-nft-xfrm \
	kmod-npu kmod-npu-autoload kmod-mediatek_hnat \
	kmod-npu-nf_hnat kmod-npu-nf_hnat-autoload npu-rebb-fw \
	kmod-crypto-eip kmod-crypto-eip-inline kmod-crypto-eip-autoload \
	crypto-eip-inline-fw \
	@CRYPTO_OFFLOAD_INLINE @CRYPTO_XFRM_OFFLOAD_MTK_PCE \
	@MTK_NPU_L2TP @MTK_NPU_L2TP_V2 @MTK_NPU_PPP
endef

define Package/mtk-npu-tunnel/description
  Disabled-by-default L2TPv2/IPsec policy profile for the native MT7988
  NPU/HNAT and EIP197 inline path. Configure peer, credentials and explicit
  IPv4 destinations on the router. Proxy protocol processing stays on CPU.
endef

define Package/mtk-npu-tunnel/conffiles
/etc/config/npu_tunnel
endef

define Build/Compile
endef

define Package/mtk-npu-tunnel/install
	$(INSTALL_DIR) $(1)/etc/config $(1)/etc/init.d \
		$(1)/etc/hotplug.d/iface $(1)/usr/sbin
	$(INSTALL_CONF) ./files/etc/config/npu_tunnel $(1)/etc/config/npu_tunnel
	$(INSTALL_BIN) ./files/etc/init.d/npu-tunnel $(1)/etc/init.d/npu-tunnel
	$(INSTALL_BIN) ./files/etc/hotplug.d/iface/95-npu-tunnel $(1)/etc/hotplug.d/iface/95-npu-tunnel
	$(INSTALL_BIN) ./files/usr/sbin/mtk-npu-tunnel $(1)/usr/sbin/mtk-npu-tunnel
endef

$(eval $(call BuildPackage,mtk-npu-tunnel))
