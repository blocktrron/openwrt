#!/bin/sh


[ -n "$INCLUDE_ONLY" ] || {
	. /lib/functions.sh
	. ../netifd-proto.sh
	init_proto "$@"
}


QMI_TIMEOUT=${QMI_TIMEOUT:-1000}
QMI_SPECIAL_APN="ims sos hos"

# JSON namespaces
JSON_NAMESPACE_PDP_LIST="pdp_list"	# List of all configured PDP sessions

proto_qmap_init_config() {
	available=1
	no_device=1
	proto_config_add_string "device:device"
	proto_config_add_int "uim_pin"
	proto_config_add_array "multiplex_channel"

	proto_config_add_string "ul_aggregation_proto"
	proto_config_add_int "ul_aggregation_max_size"
	proto_config_add_int "ul_aggregation_max_packets"
	proto_config_add_string "dl_aggregation_proto"
	proto_config_add_int "dl_aggregation_max_size"
	proto_config_add_int "dl_aggregation_max_packets"
}

qmi_get_ifname() {
	local device="$1"
	local devname devpath ifname

	device="$(readlink -f $device)"
	[ -c "$device" ] || {
		return 1
	}

	devname="$(basename "$device")"
	devpath="$(readlink -f /sys/class/usbmisc/$devname/device/)"
	ifname="$( ls "$devpath"/net )"
	[ -n "$ifname" ] || {
		echo "The interface could not be found."
	}

	echo "$ifname"
}

qmi_uim_unlock() {
	local device="$1"
	local uim_pin="$2"

	json_load "$(uqmi -s -d "$device" -t $QMI_TIMEOUT --uim-get-sim-state)"
	json_get_var card_application_state card_application_state

	[ "$card_application_state" = "ready" ] && {
		echo "UIM PIN not required"
		return 0
	}

	[ "$card_application_state" != "pin-required" ] && {
		echo "Unknown UIM state $card_application_state"
		return 1
	}

	[ -z "$uim_pin" ] && {
		echo "No UIM PIN provided"
		return 1
	}

	uqmi -s -d "$device" -t $QMI_TIMEOUT --uim-verify-pin1 "$uim_pin" || {
		echo "Failed to unlock UIM PIN ($uim_pin)"
		return 1
	}

	echo "Unlock UIM PIN successful"
	return 0
}

qmi_uim_init() {
	local interfinterfaceace="$1"

	local uim_state_timeout=5
	local uim_state_iterations=0

	while true; do
		json_load "$(uqmi -s -d "$device" -t $QMI_TIMEOUT --uim-get-sim-state)"
		json_get_var card_application_state card_application_state

		# SIM card is eithemultiplex_channelsr completely absent or state is labeled as illegal
		# Try to power-cycle the SIM card to recover from this state
		if [ -z "$card_application_state" -o "$card_application_state" = "illegal" ]; then
			echo "SIM in illegal state - Power-cycling SIM"

			# Try to reset SIM application
			uqmi -d "$device" -t $QMI_TIMEOUT --uim-power-off --uim-slot 1
			sleep 3
			uqmi -d "$device" -t $QMI_TIMEOUT --uim-power-on --uim-slot 1

			if [ "$uim_state_iterations" -lt "$uim_state_timeout" ] || [ "$uim_state_timeout" = "0" ]; then
				let uim_state_iterations++
				sleep 5
				continue
			fi

			# Recovery failed
			return 1
		else
			return 0
		fi
	done
}

qmap_load_pdp_session() {
	local session="$1"
	local config_parent="$2"

	local parent
	local ifname
	local apn
	local username
	local password
	local auth_type
	local pdp_type
	local proto
	
	config_get proto	"$session"	proto
	config_get parent	"$session" parent
	config_get ifname	"$session" ifname
	config_get apn		"$session" apn
	config_get username	"$session" username
	config_get password	"$session" password
	config_get auth_type	"$session" auth_type	"none"
	config_get pdp_type	"$session" pdp_type	"ipv4"
	config_get attach_pdn	"$session" attach_pdn	"1"

	[ "$proto" = "qmap_session" ] || return 0

	if [ "$config_parent" != "$parent" ]; then
		echo "PDH session $session with parent $parent is not child of $config_parent"
		return 0
	fi

	[ -n "$apn" ] || {
		echo "APN not set for PDH session $session"
		return 1
	}

	if [ -z "$ifname" ]; then
		ifname="${parent}_${pdh_id}"
	fi

	json_add_object ""
	json_add_string "config" "$session"
	json_add_string "pdh_id" "$pdh_id"
	json_add_string "ifname" "$ifname"
	[ -n "$parent" ] &&	json_add_string "parent"	"$parent"
	[ -n "$apn" ] && 	json_add_string "apn"		"$apn"
	[ -n "$username" ] &&	json_add_string "username"	"$username"
	[ -n "$password" ] &&	json_add_string "password"	"$password"
	[ -n "$auth_type" ] &&	json_add_string "auth_type"	"$auth_type"
	json_add_string "pdp_type" "$pdp_type"
	json_add_string "attach_pdn" "$attach_pdn"
	json_close_object ""

	pdh_id=$((pdh_id + 1))
}

qmap_load_pdh_config() {
	local config="$1"
	local pdh_config_ns="pdhconf"
	local old_ns
	local pdh_id=1

	# Save old namespace
	json_set_namespace "$pdh_config_ns" old_ns

	# Prepare output JSON
	json_init

	# Load PDH configurations from UCI
	config_load network

	# Load all PDH configurations
	json_add_array "pdh_sessions"
	config_foreach qmap_load_pdp_session interface "$config"
	json_close_array
	
	# Dump JSON
	json_dump

	# Restore old namespace
	json_set_namespace "$old_ns"
}

qmap_netifd_get_ip_settings() {
	local device="$1"
	local cid="$2"
	uqmi -s -d $device -t 1000 --set-client-id wds,$cid --get-current-settings
}

qmap_netifd_add_ip_settings() {
	local config_child="$1"
	local ifname="$2"
	local device="$3"
	local cid_4="$4"
	local cid_6="$5"

	local json_ns_cur="json_ns_add_ipv4"
	local json_ns_old

	local ip_4 gateway_4 dns1_4 dns2_4 subnet_4
	local ip_6 gateway_6 dns1_6 dns2_6 ip_prefix_length_6

	local zone="$(fw3 -q network "$config_child" 2>/dev/null)"

	json_set_namespace "$json_ns_cur" json_ns_old

	if [ -n "$cid_4" ]; then
		json_init
		json_load "$(qmap_netifd_get_ip_settings "$device" "$cid_4")"

		# IPv4 settings
		json_select ipv4
		json_get_var ip_4 ip
		json_get_var gateway_4 gateway
		json_get_var dns1_4 dns1
		json_get_var dns2_4 dns2
		json_get_var subnet_4 subnet

		echo "Adding IPv4 address $ip_4/$subnet_4 gateway $gateway_4 dns1 $dns1_4 dns2 $dns2_4 zone $zone to $ifname"
	fi

	if [ -n "$cid_6" ]; then
		json_init
		json_load "$(qmap_netifd_get_ip_settings "$device" "$cid_6")"

		# IPv6 settings
		json_select ipv6
		json_get_var ip_6 ip
		json_get_var gateway_6 gateway
		json_get_var dns1_6 dns1
		json_get_var dns2_6 dns2
		json_get_var ip_prefix_length_6 ip-prefix-length

		echo "Adding IPv6 address $ip_6/$ip_prefix_length_6 gateway $gateway_6 dns1 $dns1_6 dns2 $dns2_6 zone $zone to $ifname"
	fi

	json_set_namespace "$json_ns_old"

	json_add_object "ipv4"
	json_add_string "ip" "$ip_4"
	json_add_string "gateway" "$gateway_4"
	json_add_string "dns1" "$dns1_4"
	json_add_string "dns2" "$dns2_4"
	json_add_string "subnet" "$subnet_4"
	json_close_object

	json_add_object "ipv6"
	json_add_string "ip" "$ip_6"
	json_add_string "gateway" "$gateway_6"
	json_add_string "dns1" "$dns1_6"
	json_add_string "dns2" "$dns2_6"
	json_add_string "ip_prefix_length" "$ip_prefix_length_6"
	json_close_object

	json_set_namespace "$json_ns_old"
}

qmap_create_data_session() {
	local key="$1"
	local config_parent="$3"
	local device="$4"
	local parent_ifname="$5"

	local config
	local pdh_id
	local apn
	local username
	local password
	local auth_type
	local pdp_type
	local attach_pdn

	local wds_id_ipv4
	local wds_id_ipv6

	local pdh_id_ipv4
	local pdh_id_ipv6

	local connect_v4
	local connect_v6

	local ifname

	json_select "$2"
	json_get_vars config pdh_id apn username password auth_type pdp_type attach_pdn ifname

	if [ "$pdp_type" == "ipv4" ]; then
		connect_v4=1
	elif [ "$pdp_type" == "ipv6" ]; then
		connect_v6=1
	elif [ "$pdp_type" == "ipv4v6" ]; then
		connect_v4=1
		connect_v6=1
	else
		echo "Invalid PDP type $pdp_type"
		json_select ".."
		return 1
	fi

	echo "Creating multiplex channel $pdh_id on $parent_ifname: $ifname"

	# Create PDH session
	json_add_object "wds_clients"
	if [ "$connect_v4" == "1" ]; then
		wds_id_ipv4="$(uqmi -d "/dev/cdc-wdm0" --get-client-id wds)"
		json_add_int "ipv4" "$wds_id_ipv4"
	fi
	if [ "$connect_v6" == "1" ]; then
		wds_id_ipv6="$(uqmi -d "/dev/cdc-wdm0" --get-client-id wds)"
		json_add_int "ipv6" "$wds_id_ipv6"
	fi
	json_close_object

	# Bind clients to multiplex channel
	if [ "$connect_v4" == "1" ]; then
		uqmi -d "/dev/cdc-wdm0" --bind-mux "$pdh_id" --endpoint-type hsusb --endpoint-iface 4 --set-client-id wds,$wds_id_ipv4
		uqmi -d "/dev/cdc-wdm0" --set-ip-family ipv4 --set-client-id wds,$wds_id_ipv4
	fi
	if [ "$connect_v6" == "1" ]; then
		uqmi -d "/dev/cdc-wdm0" --bind-mux "$pdh_id" --endpoint-type hsusb --endpoint-iface 4 --set-client-id wds,$wds_id_ipv6
		uqmi -d "/dev/cdc-wdm0" --set-ip-family ipv6 --set-client-id wds,$wds_id_ipv6
	fi

	# Store APN profile settings
	uqmi -d "/dev/cdc-wdm0" --modify-profile 3gpp,$pdh_id --apn "$apn" --auth-type "$auth_type" --pdp-type "$pdp_type"
	if [ $? -ne 0 ]; then
		uqmi -d "/dev/cdc-wdm0" --create-profile 3gpp
		uqmi -d "/dev/cdc-wdm0" --modify-profile 3gpp,$pdh_id --apn "$apn" --auth-type "$auth_type" --pdp-type "$pdp_type"
	fi

	echo "Create PDH handles for $ifname"

	# Create PDH handles
	if [ "$connect_v4" == "1" ]; then
		pdh_id_ipv4="$(uqmi -d "/dev/cdc-wdm0" --set-client-id wds,$wds_id_ipv4 --start-network --profile $pdh_id)"
		if [ $? -ne 0 ]; then
			echo "Failed to start IPv4 network for PDH session $pdh_id"
			json_select ".."
			return 1
		fi
	fi

	if [ "$connect_v6" == "1" ]; then
		pdh_id_ipv6="$(uqmi -d "/dev/cdc-wdm0" --set-client-id wds,$wds_id_ipv6 --start-network --profile $pdh_id)"
		if [ $? -ne 0 ]; then
			echo "Failed to start IPv6 network for PDH session $pdh_id"
			json_select ".."
			return 1
		fi
	fi

	json_add_object "pdh_handles"
	[ -n "$pdh_id_ipv4" ] && json_add_int "ipv4" "$pdh_id_ipv4"
	[ -n "$pdh_id_ipv6" ] && json_add_int "ipv6" "$pdh_id_ipv6"
	json_close_object
	

	echo "Start netifd interface configuration for $ifname"
	# Create netifd interface configuration
	qmap_netifd_add_ip_settings "$config" "$ifname" "$device" "$wds_id_ipv4" "$wds_id_ipv6"
	json_select ".."
}

qmap_create_rmnet() {
	local key="$1"
	local config_parent="$3"
	local device="$4"
	local parent_ifname="$5"

	local json_ns_cur="json_ns_create_rmnet"
	local json_ns_old

	local pdh_id
	local ifname
	local config

	json_select "$2"
	json_get_vars pdh_id ifname config


	# Remove interface if it already exists
	ip link del dev "$ifname" 2>/dev/null

	ip link add \
		link "$parent_ifname" \
		name "$ifname" \
		type rmnet mux_id "${pdh_id}" \
		ingress-deaggregation on \
		ingress-mapv5-checksum on \
		egress-mapv5-checksum on \
		ingress-commands on
	if [ $? -ne 0 ]; then
		echo "Failed to create multiplex channel"
	fi

	json_select ".."

	json_set_namespace "$json_ns_cur" json_ns_old
	json_init

	proto_set_available "$config" 1

	json_set_namespace "$json_ns_old"
}

qmap_create_pdp_get_session_apn() {
	local current_pdp_idx="$1"
	local device="$2"
	local apn_settings
	local json_ns_cur="json_ns_pdp_session_apn_name"
	local json_ns_old

	apn_settings="$(uqmi -d "$device" --get-profile-settings 3gpp,$current_pdp_idx)"
	if [ $? -ne 0 ]; then
		uqmi -d "$device" --create-profile 3gpp
		apn_settings="$(uqmi -d "$device" --get-profile-settings 3gpp,$current_pdp_idx)"
	fi

	json_set_namespace "$json_ns_cur" json_ns_old
	json_load "$apn_settings"
	json_get_var apn apn
	json_set_namespace "$json_ns_old"
}

qmap_create_pdp_session_write_profile() {
	local current_pdp_idx="$1"
	local device="$2"
	local apn

	# Get JSON Values
	json_get_vars apn username password auth_type pdp_type
	echo "Create PDP context $current_pdp_idx apn=$apn username=$username password=$password auth_type=$auth_type pdp_type=$pdp_type"
	uqmi -d "$device" --modify-profile 3gpp,$current_pdp_idx \
		${apn:+--apn $apn} \
		${username:+--username $username} \
		${password:+--password $password} \
		--auth-type none --pdp-type ipv4
}

qmap_create_pdp_session() {
	local session="$1"
	local js_idx="$2"
	local device="$3"
	local apn

	pdp_idx_found=0

	json_select "$js_idx"

	while [ "$pdp_idx_found" == 0 ]; do
		# Get profile settings of current APN
		qmap_create_pdp_get_session_apn "$current_pdp_idx" "$device"

		# Check if the current PDP index is a special APN
		for special_apn in $QMI_SPECIAL_APN; do
			if [ "$apn" != "$special_apn" ]; then
				pdp_idx_found=1
			else
				echo "Found special APN $special_apn at PDP index $current_pdp_idx, skipping"
				current_pdp_idx=$((current_pdp_idx + 1))
			fi
		done
	done

	qmap_create_pdp_session_write_profile "$current_pdp_idx" "$device"
	current_pdp_idx=$((current_pdp_idx + 1))
	json_select ".."
}

qmap_remove_pdp_session() {
	local index
	local val="$1"
	local js_idx="$2"
	local delete_start_idx="$3"

	# Get Profile Index
	json_select "$js_idx"
	json_get_vars index
	json_select ".."

	# Delete Profile if it is not in use
	[ "$index" -ge "$delete_start_idx" ] || return 0
	uqmi -d "$device" --delete-profile 3gpp,$index
}

qmap_create_pdp_profiles() {
	local device="$1"
	local pdh_configs="$2"
	local current_pdp_idx=1
	local pdp_delete_profile_start
	local pdp_idx_found
	local apn_settings
	local json_ns_cur="json_ns_create_pdp_profiles"
	local json_ns_old
	local all_pdn_profiles

	# Now it gets tricky. If modem has VoLTE enabled, we have APNs
	# we are not allowed to touch. We need to remove all others we
	# are allowed to touch.
	json_set_namespace "$json_ns_cur" json_ns_old
	json_init
	json_load "$pdh_configs"
	json_for_each_item qmap_create_pdp_session "pdh_sessions" "$device"


	# Get all PDN profiles
	all_pdn_profiles="$(uqmi -s -d "$device" --get-profile-list 3gpp)"
	json_init
	json_load "$all_pdn_profiles"

	# Delete all profiles starting from 'current_pdp_idx+1'
	current_pdp_idx=$((current_pdp_idx + 1))
	json_for_each_item qmap_remove_pdp_session "profiles" "$current_pdp_idx"
	json_set_namespace "$json_ns_old"
}

qmi_modem_setup() {
	local success_iterations=5
	local success=0

	echo "Setting up modem"

	while [ $success_iterations -ne 0 ]; do
		uqmi -s -d "$1" -t "$QMI_TIMEOUT" --sync > /dev/null 2>&1
		if [ $? -eq 0 ]; then
			success=$((success + 1))
		else
			success=0
			sleep 10
		fi
		success_iterations=$((success_iterations - 1))
		sleep 1
	done

	if [ $success -eq 0 ]; then
		echo "Failed to sync device"
		exit 1
	fi

	echo "Disconnect from network"
	uqmi -s -d "$1" -t "$QMI_TIMEOUT" ---set-device-operating-mode low_power > /dev/null 2>&1
	sleep 1

	echo "Power-cycle SIM card"
	uqmi -s -d "$1" -t "$QMI_TIMEOUT" --uim-power-off --uim-slot 1 > /dev/null 2>&1
	sleep 1
	uqmi -s -d "$1" -t "$QMI_TIMEOUT" --uim-power-on --uim-slot 1 > /dev/null 2>&1
	sleep 3
}

qmpi_modem_connect() {
	local connected=0
	local connection_tries=12

	local json_ns_cur="json_ns_modem_setup"
	local json_ns_old

	local registration_status


	echo "Connect to network"
	uqmi -s -d "$1" -t "$QMI_TIMEOUT" --set-device-operating-mode online > /dev/null 2>&1
	sleep 1

	json_set_namespace "$json_ns_cur" json_ns_old
	while [ $connected -ne 1 ] && [ $connection_tries -ne 0 ]; do
		connection_tries=$((connection_tries - 1))
		json_init
		json_load "$(uqmi -s -d "$1" -t "$QMI_TIMEOUT" --get-serving-system)"
		if [ $? -eq 1 ]; then
			continue
		fi

		json_get_var registration_status registration

		if [ "$registration_status" = "registered" ]; then
			connected=1
		else
			echo "Waiting for network registration status=$registration_status"
			sleep 5
		fi
	done
	json_set_namespace "$json_ns_old"

	if [ $connected -ne 1 ]; then
		echo "Failed to connect to network"
		exit 1
	fi

	echo "Connected to cellular network"

}

proto_qmap_setup() {
	local config="$1"
	local proto_config_json_ns

	local device
	local ifname

	local mtu
	local multiplex_channel
	local multiplex_channels

	local ul_aggregation_proto
	local ul_aggregation_max_size
	local ul_aggregation_max_packets
	local dl_aggregation_proto
	local dl_aggregation_max_size
	local dl_aggregation_max_packets

	local uim_pin

	local pdh_configs

	json_get_vars device
	json_get_vars uim_pin

	json_get_vars ul_aggregation_proto ul_aggregation_max_size ul_aggregation_max_packets
	json_get_vars dl_aggregation_proto dl_aggregation_max_size dl_aggregation_max_packets

	json_set_namespace "$config" proto_config_json_ns

	# Load all PDH configurations
	pdh_configs="$(qmap_load_pdh_config "$config")"

	# Resolve interface name
	ifname="$(qmi_get_ifname "${device}")"
	[ -n "$ifname" ] || {
		echo "The interface could not be found."
		exit 1
	}

	# Setup device
	qmi_modem_setup "${device}"
	if [ $? -ne 0 ]; then
		echo "Failed to setup modem"
		exit 1
	fi

	# Wait for UIM init
	qmi_uim_init "${device}"
	if [ $? -ne 0 ]; then
		echo "Failed to initialize UIM"
		return 1
	fi

	# Unlock SIM if necessary
	qmi_uim_unlock "${device}" "${uim_pin}"
	if [ $? -ne 0 ]; then
		echo "Failed to unlock UIM PIN"
		return 1
	fi

	# Connect to network
	qmpi_modem_connect "${device}"
	if [ $? -ne 0 ]; then
		echo "Failed to connect to network"
		return 1
	fi

	# Cleanup state
	uqmi -s -d "$device" -t "$QMI_TIMEOUT" --stop-network 0xffffffff --autoconnect > /dev/null 2>&1

	# Go online
	uqmi -s -d "$device" -t "$QMI_TIMEOUT" --set-device-operating-mode online 2>&1
	if [ $? -ne 0 ]; then
		echo "Failed to set device operating mode"
		return 1
	fi

	# Enable raw-ip
	echo "Y" > /sys/class/net/$ifname/qmi/raw_ip

	# Enable pass-through
	echo "Y" > /sys/class/net/$ifname/qmi/pass_through

	# Sync state
	uqmi -s -d "$device" -t "$QMI_TIMEOUT" --sync > /dev/null 2>&1
	if [ $? -ne 0 ]; then
		echo "Failed to sync device"
		return 1
	fi

	# Setup datapath aggregation parameters
	uqmi -d "$device" -t "$QMI_TIMEOUT" \
		--wda-set-data-format raw-ip \
		--dl-aggregation-protocol "$dl_aggregation_proto" \
		--dl-datagram-max-count "$dl_aggregation_max_packets" \
		--dl-datagram-max-size "$dl_aggregation_max_size" \
		--ul-aggregation-protocol "$ul_aggregation_proto" \
		--ul-datagram-max-count "$ul_aggregation_max_packets" \
		--ul-datagram-max-size "$ul_aggregation_max_size"
	if [ $? -ne 0 ]; then
		echo "Failed to set aggregation parameters"
		return 1
	fi


	# Set MTU
	mtu=1500
	[ "$mtu" -lt "$ul_aggregation_max_size" ] && mtu="$ul_aggregation_max_size"
	[ "$mtu" -lt "$dl_aggregation_max_size" ] && mtu="$dl_aggregation_max_size"
	ip link set dev "$ifname" mtu "$mtu"
	if [ $? -ne 0 ]; then
		echo "Failed to set MTU"
		return 1
	fi

	# Enable interface
	ip link set dev "$ifname" up
	if [ $? -ne 0 ]; then
		echo "Failed to bring up interface"
		return 1
	fi

	# Create PDP connection profiles
	qmap_create_pdp_profiles "$device" "$pdh_configs"

	# Create PDH channels
	json_set_namespace "pdhconf"
	json_init
	json_load "$pdh_configs"
	echo "$pdh_configs"
	json_for_each_item qmap_create_data_session "pdh_sessions" "$config" "$device" "$ifname"
	pdh_configs="$(json_dump)"

	json_set_namespace "$proto_config_json_ns"

	echo "$ifname - $config"

	proto_init_update "$ifname" 1
	proto_set_keep 1
	proto_add_data
	json_add_string "pdh_config" "$pdh_configs"
	proto_close_data
	proto_send_update "$config"

	# Create multiplex channels
	json_set_namespace "pdhconf"
	json_init
	json_load "$pdh_configs"
	json_for_each_item qmap_create_rmnet "pdh_sessions" "$config" "$device" "$ifname"

	echo "END HERE"

	return 0
}

qmap_teardown_pdh_and_client() {
	local pdh_id="$1"
	local wds_cid="$2"
	local device="$3"

	# Stop PDH session
	uqmi -s -d "$device" -t 1000 --set-client-id wds,"$wds_cid" \
		--stop-network "$pdh_id" > /dev/null 2>&1

	# Release WDS client ID
	uqmi -s -d "$device" -t 1000 --set-client-id wds,"$wds_cid" \
		--release-client-id wds > /dev/null 2>&1
}

qmap_teardown_child_interface() {
	local js_idx="$2"
	local device="$3"
	local ifname

	local wds_cid_ipv4
	local wds_cid_ipv6

	local pdh_id_ipv4
	local pdh_id_ipv6

	json_select "$js_idx"
	json_get_vars ifname

	echo "Remove interface $ifname"
	ip link del dev "$ifname"

	json_select "wds_clients"
	json_get_var wds_cid_ipv4 ipv4
	json_get_var wds_cid_ipv6 ipv6
	json_select ".."

	json_select "pdh_handles"
	json_get_var pdh_id_ipv4 ipv4
	json_get_var pdh_id_ipv6 ipv6
	json_select ".."

	[ -n "$pdh_id_ipv4" ] && qmap_teardown_pdh_and_client "$pdh_id_ipv4" "$wds_cid_ipv4" "$device"
	[ -n "$pdh_id_ipv6" ] && qmap_teardown_pdh_and_client "$pdh_id_ipv6" "$wds_cid_ipv6" "$device"

	json_select ".."
}

proto_qmap_teardown() {
	local interface="$1"
	local device
	local pdh_config

	json_get_vars device

	json_load "$(ubus call network.interface.$interface status)"
	json_select data
	json_get_vars pdh_config

	json_load "$pdh_config"

	json_for_each_item qmap_teardown_child_interface "pdh_sessions" "$device"

	# Remove multiplex channels
	for multiplex_channel in $(json_get_keys "$interface" "multiplex_channels"); do
		ip link del dev "$interface"_"$multiplex_channel"
	done


	# Shut down modem
	# uqmi -s -d "$device" -t "$QMI_TIMEOUT" --set-device-operating-mode low_power 2>&1
}

[ -n "$INCLUDE_ONLY" ] || {
	add_protocol qmap
}
