# SPDX-License-Identifier: GPL-2.0-or-later
#
# Copyright (C) 2023 MediaTek Inc.
#
# Author: Chris.Chou <chris.chou@mediatek.com>
#         Ren-Ting Wang <ren-ting.wang@mediatek.com>

include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/kernel.mk

PKG_NAME:=crypto-eip
PKG_RELEASE:=2
# MediaTek public SDK c58bfb6bc8462ac51adc59d6ed6b9dbd7781f3a2.
PKG_BUILD_DEPENDS:=pce
PKG_FILE_DEPENDS:=$(CURDIR)/src/ $(CURDIR)/firmware/

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/package-defaults.mk

# For package initialization such as menuconfig or description etc.
EIP_KERNEL_PKGS:=
EIP_PKGS:=

include crypto-eip.mk
include $(filter-out crypto-eip.mk,$(wildcard *.mk))

PKG_CONFIG_DEPENDS += CONFIG_CRYPTO_OFFLOAD_INLINE \
	CONFIG_CRYPTO_XFRM_OFFLOAD_MTK_PCE CONFIG_CRYPTO_MTK_DDK_LOOKASIDE \
	CONFIG_CRYPTO_OFFLOAD_INLINE_FLOWBLOCK CONFIG_MTK_TOPS_CAPWAP_DTLS \
	CONFIG_PACKAGE_kmod-crypto-eip CONFIG_TOPS_TNL_NUM

EXTRA_CFLAGS+= \
	$(patsubst CONFIG_%, -DCONFIG_%=1, $(patsubst %=m,%,$(filter %=m,$(EXTRA_KCONFIG)))) \
	$(patsubst CONFIG_%, -DCONFIG_%=1, $(patsubst %=y,%,$(filter %=y,$(EXTRA_KCONFIG))))

EXTRA_CFLAGS+=	-Wall -Werror

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)/firmware
	$(CP) ./firmware/. $(PKG_BUILD_DIR)/firmware/
	$(CP) ./src/. $(PKG_BUILD_DIR)/
endef

define Build/Compile
	+$(MAKE) $(PKG_JOBS) -C "$(LINUX_DIR)" \
		$(KERNEL_MAKE_FLAGS) \
		M="$(PKG_BUILD_DIR)" \
		EXTRA_CFLAGS="$(EXTRA_CFLAGS)" \
		$(EXTRA_KCONFIG) \
		modules
endef

$(foreach KERNEL_PKG,$(EIP_KERNEL_PKGS),$(eval $(call KernelPackage,$(KERNEL_PKG))))
$(foreach PKG,$(EIP_PKGS),$(eval $(call BuildPackage,$(PKG))))
