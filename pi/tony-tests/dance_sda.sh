#!/bin/bash
# dance_sda.sh — trigger the bear with SIG on SDA1 (BCM2): relay normally ON (pull-up), brief OFF, then ON again.
# This is the pattern that danced 3/3 on 2026-10-13. Used as BEAR_DANCE_BIN by dance_launch.py.
trap 'pinctrl set 2 ip pu' EXIT
pinctrl set 2 op dl; sleep "${SDA_OFF_S:-0.3}"; pinctrl set 2 ip pu
echo "$(date '+%T') dance_sda: relay OFF ${SDA_OFF_S:-0.3}s then ON" >> /home/spauly/tony-tests/pulse_seq.log
