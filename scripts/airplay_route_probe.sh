#!/bin/bash

set -euo pipefail

duration="${1:-45}"
wifi_interface="${WIFI_INTERFACE:-en0}"
awdl_interface="${AWDL_INTERFACE:-awdl0}"

if ! [[ "${duration}" =~ ^[0-9]+$ ]] || (( duration < 5 )); then
  echo "Usage: $0 [duration-in-seconds, minimum 5]"
  exit 2
fi

read_counters() {
  local interface="$1"
  netstat -ibdn | awk -v interface="${interface}" '
    $1 == interface && $3 ~ /^<Link#/ {
      print $7, $10
      exit
    }
  '
}

format_mb() {
  awk -v bytes="$1" 'BEGIN { printf "%.2f", bytes / 1048576 }'
}

read -r awdl_rx_start awdl_tx_start <<< "$(read_counters "${awdl_interface}")"
read -r wifi_rx_start wifi_tx_start <<< "$(read_counters "${wifi_interface}")"

echo "Monitoring ${awdl_interface} (Apple peer-to-peer) and ${wifi_interface} (infrastructure Wi-Fi)."
echo "Start AirPlay mirroring now and keep a moving scene visible for ${duration} seconds."

for ((elapsed = 5; elapsed <= duration; elapsed += 5)); do
  sleep 5

  read -r awdl_rx_now awdl_tx_now <<< "$(read_counters "${awdl_interface}")"
  read -r wifi_rx_now wifi_tx_now <<< "$(read_counters "${wifi_interface}")"

  awdl_total=$((awdl_rx_now - awdl_rx_start + awdl_tx_now - awdl_tx_start))
  wifi_total=$((wifi_rx_now - wifi_rx_start + wifi_tx_now - wifi_tx_start))

  printf 't=%3ss  awdl=%8s MB  wifi=%8s MB\n' \
    "${elapsed}" \
    "$(format_mb "${awdl_total}")" \
    "$(format_mb "${wifi_total}")"
done

read -r awdl_rx_end awdl_tx_end <<< "$(read_counters "${awdl_interface}")"
read -r wifi_rx_end wifi_tx_end <<< "$(read_counters "${wifi_interface}")"

awdl_total=$((awdl_rx_end - awdl_rx_start + awdl_tx_end - awdl_tx_start))
wifi_total=$((wifi_rx_end - wifi_rx_start + wifi_tx_end - wifi_tx_start))
minimum_video_bytes=$((5 * 1024 * 1024))

echo
echo "Total ${awdl_interface}: $(format_mb "${awdl_total}") MB"
echo "Total ${wifi_interface}: $(format_mb "${wifi_total}") MB"

if (( awdl_total >= minimum_video_bytes && awdl_total > wifi_total * 3 )); then
  echo "Result: AWDL / Apple peer-to-peer is the dominant AirPlay data path."
elif (( wifi_total >= minimum_video_bytes && wifi_total > awdl_total * 3 )); then
  echo "Result: infrastructure Wi-Fi is the dominant AirPlay data path."
else
  echo "Result: inconclusive. Confirm that mirroring remained active with moving content for the full test."
fi
