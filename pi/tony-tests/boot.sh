#!/bin/bash
# boot.sh — run at power-on from cron (@reboot). Silent: logs only, no voice cues (the bear has no screen; check boot.log).
# Order: bluetooth speaker → wifi by name (background) → one-shot pin hunt → claude rc if online. Silent: no voice cues.
# DRY=1: no GPIO, flags kept; checks and logging still run.
# Undo: crontab -e (delete the boot.sh line) ; rm ~/tony-tests/boot.sh
T=/home/spauly/tony-tests
exec >>"$T/boot.log" 2>&1
export HOME=/home/spauly XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 PATH="/home/spauly/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
PY=/home/spauly/Desktop/barnaby/evil-autonomous-bear-proj/.venv/bin/python
log() { echo "$(date '+%F %T') $*"; }
say() { log "(silent) $*"; }  # boot is silent: no voice cues
log "===== boot.sh start (DRY=${DRY:-0}) ====="

# 1. Audio: PipeWire session, then the paired Bluetooth speaker (SoundCore 2). Never pair anything new.
for i in $(seq 60); do [ -S /run/user/1000/pipewire-0 ] && break; sleep 1; done
[ -S /run/user/1000/pipewire-0 ] && log "pipewire up" || log "pipewire NOT up after 60 s (cues may be silent; HDMI is the only wired audio)"
for try in 1 2 3; do
    for mac in $(timeout 10 bluetoothctl devices Paired | awk '{print $2}'); do
        timeout 10 bluetoothctl connect "$mac" | tail -1 | sed "s/^/bt $mac: /" | while read -r l; do log "$l"; done
    done
    timeout 5 bluetoothctl info E8:09:59:20:51:92 | grep -q "Connected: yes" && { log "speaker connected"; break; }
    sleep 5
done
# Force music mode (A2DP): in headset mode the SoundCore plays quietly or not at all.
sleep 3
dev=$(wpctl status | grep -m1 -E "SoundCore 2 +\[bluez5\]" | grep -oE '[0-9]+\.' | head -1 | tr -d .)
idx=$(pw-cli enum-params "$dev" EnumProfile 2>/dev/null | grep -B3 '"a2dp-sink"' | grep -oE 'Int [0-9]+' | tail -1 | cut -d' ' -f2)
if [ -n "$dev" ] && [ -n "$idx" ] && wpctl set-profile "$dev" "$idx"; then
    sleep 2
    sink=$(wpctl status | grep -A6 "Sinks:" | grep -m1 "SoundCore" | grep -oE '[0-9]+\.' | head -1 | tr -d .)
    [ -n "$sink" ] && { wpctl set-default "$sink"; wpctl set-mute "$sink" 0; wpctl set-volume "$sink" 1.0; }
    log "speaker set to a2dp, unmuted, max volume (device $dev, sink $sink: $(wpctl get-volume "$sink"))"
else
    log "could not set speaker to a2dp (device=$dev idx=$idx)"
fi

# 2. Wifi in the background: wait for wlan0, click through a guest portal (no credentials ever), log ONLINE/OFFLINE.
WIFI_NAME=SC_GUEST  # campus: many access points share this name, so match by NAME, never by router
wifi() {
    for i in $(seq 60); do ip -4 addr show wlan0 | grep -q inet && break; sleep 1; done
    if ! ip -4 addr show wlan0 | grep -q inet || [ "$(iwgetid -r)" != "$WIFI_NAME" ]; then
        nmcli dev wifi rescan 2>/dev/null; sleep 5
        aps=$(nmcli -t -f SSID,SECURITY,SIGNAL dev wifi list | grep "^$WIFI_NAME:")
        if [ -z "$aps" ]; then log "wifi: $WIFI_NAME not in range"
        elif grep -q "^$WIFI_NAME::" <<<"$aps"; then
            log "wifi: $WIFI_NAME seen on $(wc -l <<<"$aps") access points, open (free); connecting by name"
            timeout 30 nmcli dev wifi connect "$WIFI_NAME" 2>&1 | while read -r l; do log "nmcli: $l"; done
        else log "wifi: $WIFI_NAME needs a password — not free, not connecting"
        fi
        for i in $(seq 30); do ip -4 addr show wlan0 | grep -q inet && break; sleep 1; done
    fi
    log "wifi name=$(iwgetid -r) router=$(iwgetid -ar) ip=$(ip -4 -br addr show wlan0 | awk '{print $3}')"
    if [ "$(iwgetid -r)" = SC_GUEST ]; then
        code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' http://connectivitycheck.gstatic.com/generate_204)
        if [ "$code" != 204 ]; then
            log "portal suspected (generate_204 -> $code), trying click-through"
            page=$(curl -s -m 10 -L -c "$T/.portal.cookies" -w '\n%{url_effective}' http://neverssl.com)
            url=$(tail -1 <<<"$page")
            if grep -qiE 'type="?password|name="?(user|email|room|last.?name|pin)' <<<"$page"; then
                log "portal needs login at $url — not handled"
            else
                action=$(grep -oiE '<form[^>]*action="[^"]*"' <<<"$page" | head -1 | sed -E 's/.*action="([^"]*)".*/\1/I')
                fields=$(grep -oiE '<input[^>]*>' <<<"$page" | grep -iE 'type="?(hidden|checkbox|submit)' |
                    sed -nE 's/.*name="([^"]*)".*value="([^"]*)".*/\1=\2/Ip; s/.*value="([^"]*)".*name="([^"]*)".*/\2=\1/Ip' | paste -sd'&')
                case "$action" in http*) ;; /*) action="$(grep -oE '^https?://[^/]+' <<<"$url")$action" ;; *) action="${url%/*}/$action" ;; esac
                log "portal form: action=$action fields=$fields"
                curl -s -m 10 -L -b "$T/.portal.cookies" -o /dev/null -w '%{http_code}' --data "$fields" "$action" | sed 's/^/portal POST -> /' | while read -r l; do log "$l"; done
            fi
        fi
    fi
    code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' http://connectivitycheck.gstatic.com/generate_204)
    [ "$code" = 204 ] && echo ONLINE >"$T/.net_state" || echo OFFLINE >"$T/.net_state"
    log "net: $(cat "$T/.net_state") (generate_204 -> $code; 204 = free wifi with real internet, else portal/offline)"
}
rm -f "$T/.net_state"
wifi &
WIFI_PID=$!

# 3. One-shot pin hunt (flag removed FIRST so a crash can't cause a reboot loop).
if [ -e "$T/RUN_PIN_HUNT" ]; then
    wheels=no; [ -e "$T/RUN_WHEELS" ] && wheels=yes
    if [ "${DRY:-0}" = 1 ]; then
        log "DRY: would run pin_hunt (wheels=$wheels); flags kept"
    else
        rm -f "$T/RUN_PIN_HUNT"; [ $wheels = yes ] && rm -f "$T/RUN_WHEELS"
        say "Boot OK. Pin hunt in ten seconds."
        sleep 10
        if [ $wheels = yes ]; then "$T/pin_hunt.sh"; else NO_WHEELS=1 "$T/pin_hunt.sh"; fi
        log "pin_hunt exit=$?"
        say "Pin hunt done."
    fi
else
    say "Boot OK. No pin hunt."
fi

# 4. Network result, then Claude remote control so the cloud sessions can reach the Pi.
wait $WIFI_PID
state=$(cat "$T/.net_state" 2>/dev/null || echo OFFLINE)
[ "$state" = ONLINE ] && say "Online." || say "Offline."
if [ "$state" = ONLINE ]; then
    if pgrep -f "claude rc" >/dev/null; then log "claude rc already running"
    elif [ "${DRY:-0}" = 1 ]; then log "DRY: would start claude rc"
    else
        # No tmux/screen on the Pi: `script` gives claude rc the terminal it needs.
        (cd /home/spauly && nohup setsid script -qfc "claude rc" /dev/null >"$T/claude-rc.log" 2>&1 &)
        sleep 5; pgrep -f "claude rc" >/dev/null && log "claude rc started (log: claude-rc.log)" || log "claude rc FAILED to start (see claude-rc.log)"
    fi
fi
log "===== boot.sh end ====="
