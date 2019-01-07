#
# Copyright (C) 2011 OpenWrt.org
#

PART_NAME=firmware
REQUIRE_IMAGE_METADATA=1

platform_check_image() {
	return 0
}

platform_do_upgrade() {
	case "$(board_name)" in
	ocedo,panda)
		nand_do_upgrade "$1"
		;;
	*)
		default_do_upgrade "$ARGV"
		;;
	esac
}
