#!/bin/sh

iface=$1
event=$2

case $event in
	CONNECTED|CTRL-EVENT-CONNECTED)
		[ -x /usr/libexec/mtk-easymesh ] && /usr/libexec/mtk-easymesh save-backhaul "$iface"
		;;
	CTRL-EVENT-SCAN-STARTED) echo "start" > /var/run/scan_state-$iface;;
	CTRL-EVENT-SCAN-FAILED) echo "failed" > /var/run/scan_state-$iface;;
	CTRL-EVENT-SCAN-RESULTS) echo "done" > /var/run/scan_state-$iface;;
esac

