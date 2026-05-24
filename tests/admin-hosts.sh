#!/bin/sh

set -eu
. /tests/lib.sh

prefix=$(unique_name host)
host1="$prefix-1.example.com"
host2="$prefix-2.example.com"
logical="$prefix-logical.example.com"
host_json=$(tmp_json)
map_json=$(tmp_json)

cleanup() {
	cleanup_host "$logical"
	cleanup_host "$host1"
	cleanup_host "$host2"
}
trap cleanup EXIT

run_ok "create host 1" bifrost create_host "$host1"	\
    ip_addr=10.10.0.1 realm="$REALM"
run_ok "create host 2" bifrost create_host "$host2"	\
    ip_addr=10.10.0.2 realm="$REALM"

json_cmd "$host_json" bifrost_json query_host "$host1"
json_field_eq "host 1 realm" "$host_json" .realm "$REALM"
json_field_eq "host 1 ip" "$host_json" .ip_addr 10.10.0.1

run_ok "create logical host" bifrost create_logical_host "$logical"
run_ok "map logical host to host 1" \
    bifrost insert_hostmap "$logical" "$host1"
run_ok "map logical host to host 2" \
    bifrost insert_hostmap "$logical" "$host2"

json_cmd "$map_json" bifrost_json query_hostmap "$logical"
json_array_has "hostmap contains host 1" "$map_json" . "$host1"
json_array_has "hostmap contains host 2" "$map_json" . "$host2"

json_cmd "$host_json" bifrost_json query_host "$logical"
json_field_eq "logical host is logical" "$host_json" .is_logical 1
json_array_has "logical host member 1" "$host_json" .member "$host1"
json_array_has "logical host member 2" "$host_json" .member "$host2"

finish_tests
