ARCH:=aarch64
SUBTARGET:=filogic_a73
BOARDNAME:=Filogic 8x0 (MT798x - A73)
CPU_TYPE:=cortex-a73
DEFAULT_PACKAGES += fitblk kmod-crypto-hw-safexcel wpad-openssl uboot-envtools mtk-smp kmod-mt798x-2p5g-phy mtkhqos_util
KERNELNAME:=Image dtbs

define Target/Description
	Build firmware images for MediaTek Filogic MT7988 boards with Cortex-A73 tuning.
endef