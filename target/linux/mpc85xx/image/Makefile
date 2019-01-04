#
# This is free software, licensed under the GNU General Public License v2.
# See /LICENSE for more information.
#
include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/image.mk

DEVICE_VARS += TPLINK_HWID TPLINK_HWREV TPLINK_FLASHLAYOUT

define Device/Default
  PROFILES := Default
  DEVICE_DTS := $(1)
  KERNEL_DEPENDS = $$(wildcard $(DTS_DIR)/$$(DEVICE_DTS).dts)
  KERNEL_ENTRY := 0x00000000
  KERNEL_LOADADDR := 0x00000000
  KERNEL := kernel-bin
endef

define Build/tplink-v1-image
	$(STAGING_DIR_HOST)/bin/mktplinkfw \
		-H $(TPLINK_HWID) -W $(TPLINK_HWREV) -F $(TPLINK_FLASHLAYOUT) \
		-N "$(VERSION_DIST)" -V $(REVISION) \
		-k $(IMAGE_KERNEL) \
		-r $(IMAGE_ROOTFS) \
		-j \
		$(1) \
		-o $@
endef

ifeq ($(SUBTARGET),generic)

define Device/tl-wdr4900-v1
  DEVICE_TITLE := TP-Link TL-WDR4900
  DEVICE_PACKAGES := kmod-ath9k wpad-basic
  TPLINK_HWID := 0x49000001
  TPLINK_HWREV := 1
  TPLINK_FLASHLAYOUT := 16Mppc
  KERNEL_NAME := cuImage.tl-wdr4900-v1
  SUPPORTED_DEVICES:=tl-wdr4900-v1 tplink,tl-wdr4900-v1
  IMAGES := fdt.bin factory.bin sysupgrade.bin
  IMAGE/fdt.bin := append-dtb
  IMAGE/factory.bin := tplink-v1-image
  IMAGE/sysupgrade.bin := tplink-v1-image -s | append-metadata
endef
TARGET_DEVICES += tl-wdr4900-v1

define Device/red-15w-rev1
  DEVICE_TITLE := SOPHOS RED 15w Rev.1
  DEVICE_PACKAGES := kmod-usb2
  # Original firmware uses a dedicated DTB-partition.
  # The bootloader however supports FIT-images.
  KERNEL = kernel-bin | gzip | fit gzip $(KDIR)/image-$$(DEVICE_DTS).dtb
  SUPPORTED_DEVICES := sophos,red-15w-rev1
  IMAGES := sysupgrade.bin
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += red-15w-rev1

endif

ifeq ($(SUBTARGET),p1020)

define Device/hiveap-330
  DEVICE_TITLE := Aerohive HiveAP-330
  DEVICE_PACKAGES := kmod-ath9k wpad-basic kmod-tpm-i2c-atmel
  BLOCKSIZE := 128k
  KERNEL_NAME := zImage
  KERNEL_SIZE := 8m
  SUPPORTED_DEVICES := aerohive,hiveap-330
  IMAGES := fdt.bin sysupgrade.bin
  IMAGE/fdt.bin := append-dtb
  IMAGE/sysupgrade.bin := append-dtb | pad-to 256k | check-size 256k | \
	append-uImage-fakehdr ramdisk | pad-to 256k | check-size 512k | \
	append-rootfs | pad-rootfs $$(BLOCKSIZE) | pad-to 41216k | check-size 41216k | \
	append-kernel | append-metadata
endef
TARGET_DEVICES += hiveap-330

define Device/panda
  DEVICE_TITLE := OCEDO Panda
  DEVICE_PACKAGES := kmod-rtc-ds1307 kmod-usb2 uboot-envtools
  SUPPORTED_DEVICES := ocedo,panda
  IMAGES := fdt.bin sysupgrade.bin
  IMAGE/sysupgrade.bin := sysupgrade-tar dtb=$$(KDIR)/image-$$(DEVICE_DTS).dtb | append-metadata
  IMAGE/fdt.bin := append-dtb
endef
TARGET_DEVICES += panda

endif

$(eval $(call BuildImage))
