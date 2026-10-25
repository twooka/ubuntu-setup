#!/bin/sh
c() { grep -oE '[0-9]+\.[0-9]+°C' | head -1; }
case "$1" in
  cputemp)  sensors 2>/dev/null | grep -m1 -E '^(Package id 0|Tctl|Tdie):' | c || echo n/a ;;
  nvmetemp) sensors 2>/dev/null | grep -A4 -i '^nvme' | grep -m1 Composite | c || echo n/a ;;
  fan)      r=$(sensors 2>/dev/null | grep -oE '[0-9]+ RPM' | head -1); echo "${r:-n/a}" ;;
  power)    b=$(ls -d /sys/class/power_supply/BAT* 2>/dev/null | head -1)
            if [ -r "$b/power_now" ]; then awk -v p="$(cat $b/power_now)" 'BEGIN{printf "%.1fW", p/1e6}'
            elif [ -r "$b/current_now" ]; then awk -v i="$(cat $b/current_now)" -v v="$(cat $b/voltage_now)" 'BEGIN{printf "%.1fW", i*v/1e12}'
            else echo n/a; fi ;;
  gpu)      for f in /sys/class/drm/card*/gt_act_freq_mhz /sys/class/drm/card*/device/tile0/gt0/freq0/act_freq; do
              [ -r "$f" ] && { echo "$(cat $f)MHz"; exit; }; done; echo n/a ;;
  zram)     z=$(zramctl -n -o DATA,COMPR,TOTAL 2>/dev/null | head -1); [ -n "$z" ] && echo "$z" | awk '{print $1" → "$3" (data → ram)"}' || echo off ;;
  profile)  powerprofilesctl get 2>/dev/null || echo n/a ;;
esac
