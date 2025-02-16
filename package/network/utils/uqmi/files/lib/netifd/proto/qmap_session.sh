#!/bin/sh


[ -n "$INCLUDE_ONLY" ] || {
	. /lib/functions.sh
	. ../netifd-proto.sh
	init_proto "$@"
}

qmap_session_configure_from_parent_session()  {
	local iter_key="$2"
	local config="$3"
	local iter_config

	json_select "$iter_key"
	json_get_var iter_config "config"
	json_get_var qmap_ifname "ifname"
	[ "$iter_config" != "$config" ] && {
		echo "iter_config: $iter_config"
		echo "config: $config"
		json_select ".."
		return
	}

	if json_is_a "ipv4" "object"; then
		json_select "ipv4"
		json_get_var ipv4_addr "ip"
		json_get_var ipv4_gateway "gateway"
		json_get_var ipv4_dns1 "dns1"
		json_get_var ipv4_dns2 "dns2"
		json_get_var ipv4_subnet "subnet"
		json_select ".."
	fi

	if json_is_a "ipv6" "object"; then
		json_select "ipv6"
		json_get_var ipv6_addr "ip"
		json_get_var ipv6_gateway "gateway"
		json_get_var ipv6_dns1 "dns1"
		json_get_var ipv6_dns2 "dns2"
		json_get_var ipv6_prefix_length "ip_prefix_length"
		json_select ".."
	fi

	json_select ".."
}

qmap_session_configure_from_parent() {
	local child_config="$1"
	local parent_data="$2"
	local json_ns_cur="json_ns_get_settings"
	local json_ns_old

	local config
	local ifname

	json_set_namespace "$json_ns_cur" json_ns_old
	json_init
	json_load "$parent_data"
	json_for_each_item qmap_session_configure_from_parent_session "pdh_sessions" "$child_config"
}

qmap_session_get_parent_data() {
	local config="$1"
	local parent_status="$2"
	local json_ns_cur="json_ns_get_settings"
	local json_ns_old

	local pdh_config
	local pdh_sessions

	json_set_namespace "$json_ns_cur" json_ns_old

	json_init
	json_load "$parent_status"
	json_select "data"
	json_get_vars "pdh_config"

	json_init
	json_load "$pdh_config"
	json_get_vars pdh_sessions
	json_dump

	json_set_namespace "$json_ns_old"
}

proto_qmap_session_init_config() {
	available=1
	no_device=1
	proto_config_add_string "parent"
}

proto_qmap_session_setup() {
	local config="$1"
	local parent_status
	local parent_data
	local session_data
	local parent
	local up
	local settings

	local qmap_ifname

	local ipv4_addr
	local ipv4_gateway
	local ipv4_subnet
	local ipv4_dns1
	local ipv4_dns2

	local ipv6_addr
	local ipv6_gateway
	local ipv6_dns1
	local ipv6_dns2
	local ipv6_prefix_length

	echo "proto_qmap_session_setup"

	json_get_vars parent

	echo "parent: $parent"

	[ -z "$parent" ] && {
		proto_notify_error "$config" "MISSING_PARENT"
		proto_set_available "$config" 0
		return
	}

	parent_status="$(ubus call network.interface.$parent status)"
	json_init
	json_load "$parent_status"
	json_get_var up up

	echo "up: $up"

	[ "$up" != "1" ] && {
		proto_notify_error "$config" "PARENT_DOWN"
		proto_set_available "$config" 0
		return
	}

	parent_data=$(qmap_session_get_parent_data "$config" "$parent_status")
	echo "settings: $parent_data"
	[ -z "$parent_status" ] && {
		proto_notify_error "$config" "NO_PARENT_SETTINGS"
		proto_set_available "$config" 0
		return
	}

	qmap_session_configure_from_parent "$config" "$parent_data"

	ip link set dev "$qmap_ifname" up
	ethtool -C "$qmap_ifname" tx-aggr-max-bytes 4000 tx-aggr-max-frames 20 tx-aggr-time-usecs 10000

	proto_init_update "$qmap_ifname" 1
	proto_set_keep 1

	# IPv4
	if [ -n "$ipv4_addr" ]; then
		proto_add_ipv4_address "$ipv4_addr" "$ipv4_subnet" "" "$ipv4_gateway"
		proto_add_ipv4_route "0.0.0.0" 0 "$ipv4_gateway"
		proto_add_dns_server "$ipv4_dns1"
		proto_add_dns_server "$ipv4_dns2"
	fi

	# IPv6
	if [ -n "$ipv6_addr" ]; then
		proto_add_ipv6_address "$ipv6_addr" "128"
		proto_add_ipv6_prefix "${ipv6_addr}/${ipv6_prefix_length}"
		proto_add_ipv6_route "$ipv6_gateway" "128"
		proto_add_ipv6_route "::0" 0 "$ipv6_gateway" "" "" "${ipv6_addr}/${ipv6_prefix_length}"
		proto_add_dns_server "$ipv6_dns1"
		proto_add_dns_server "$ipv6_dns2"
	fi

	proto_send_update "$config"
}

proto_qmap_session_teardown() {
	local config="$1"
}

[ -n "$INCLUDE_ONLY" ] || {
	add_protocol qmap_session
}
