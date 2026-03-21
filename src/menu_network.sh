#!/bin/sh
# menu_network.sh - Network Setup (Wi-Fi / Wired LAN / USB Tethering)

. /opt/pcinfo/common.sh

WPA_CONF="/tmp/wpa_supplicant.conf"
WPA_PID="/tmp/wpa_supplicant.pid"

# ---- Wi-Fi helpers ----

wifi_list_interfaces() {
    for iface in /sys/class/net/*; do
        [ -d "$iface/wireless" ] && basename "$iface"
    done
}

wifi_scan() {
    local iface="$1"
    ip link set "$iface" up 2>/dev/null
    # Use iw if available, else iwlist
    if command -v iw > /dev/null 2>&1; then
        iw dev "$iface" scan 2>/dev/null | \
            awk '/SSID:/{ssid=substr($0,index($0,"SSID: ")+6)} /signal:/{sig=$2} /DS Parameter/{printf "%-4s %s\n", sig, ssid}'
    elif command -v iwlist > /dev/null 2>&1; then
        iwlist "$iface" scan 2>/dev/null | \
            awk -F'"' '/ESSID/{print $2}'
    fi
}

wifi_connect() {
    local iface="$1" ssid="$2" pass="$3"

    # Stop any existing wpa_supplicant
    if [ -f "$WPA_PID" ]; then
        kill "$(cat $WPA_PID)" 2>/dev/null
        rm -f "$WPA_PID"
    fi

    if [ -z "$pass" ]; then
        # Open network
        cat > "$WPA_CONF" << EOF
network={
    ssid="$ssid"
    key_mgmt=NONE
}
EOF
    else
        # WPA/WPA2
        cat > "$WPA_CONF" << EOF
network={
    ssid="$ssid"
    psk="$pass"
}
EOF
    fi

    wpa_supplicant -B -i "$iface" -c "$WPA_CONF" -P "$WPA_PID" 2>/dev/null
    sleep 3
    udhcpc -i "$iface" -t 10 -T 3 -q 2>/dev/null
    if ip addr show "$iface" 2>/dev/null | grep -q "inet "; then
        return 0
    fi
    return 1
}

wifi_menu() {
    local iface
    iface=$(wifi_list_interfaces | head -1)

    if [ -z "$iface" ]; then
        dialog --title "Wi-Fi" --msgbox "No wireless interface found.\n\nMake sure the driver is loaded." 8 50
        return
    fi

    dialog --title "Wi-Fi" --infobox "Scanning for networks on $iface..." 5 50
    sleep 1

    local scan_result
    scan_result=$(wifi_scan "$iface" 2>/dev/null)

    if [ -z "$scan_result" ]; then
        dialog --title "Wi-Fi" --msgbox "No networks found.\n\nCheck antenna or move closer to the AP." 8 50
        return
    fi

    # Build dialog menu from scan results (remove duplicates)
    local entries=""
    local i=1
    local shown_ssids=""
    while IFS= read -r line; do
        ssid=$(echo "$line" | awk '{print substr($0, index($0,$2))}')
        [ -z "$ssid" ] && continue
        echo "$shown_ssids" | grep -qF "$ssid" && continue
        shown_ssids="$shown_ssids|$ssid"
        entries="$entries $i \"$ssid\""
        i=$((i + 1))
    done << EOF
$scan_result
EOF

    local choice
    choice=$(eval dialog --clear \
        --title '"Wi-Fi - Select Network"' \
        --menu '"Choose a network:"' \
        18 60 10 \
        $entries \
        2>&1 > /dev/tty)
    [ $? -ne 0 ] && return

    # Get selected SSID
    local selected_ssid
    i=1
    while IFS= read -r line; do
        ssid=$(echo "$line" | awk '{print substr($0, index($0,$2))}')
        [ -z "$ssid" ] && continue
        echo "$shown_ssids_order" | grep -qF "$ssid" && continue
        if [ "$i" -eq "$choice" ]; then
            selected_ssid="$ssid"
            break
        fi
        i=$((i + 1))
    done << EOF
$scan_result
EOF

    # Prompt for password
    local password
    password=$(dialog --title "Wi-Fi Password" \
        --passwordbox "Password for \"$selected_ssid\":\n(Leave blank for open network)" \
        10 60 \
        2>&1 > /dev/tty)
    [ $? -ne 0 ] && return

    dialog --title "Wi-Fi" --infobox "Connecting to $selected_ssid..." 5 50
    if wifi_connect "$iface" "$selected_ssid" "$password"; then
        local ip
        ip=$(ip addr show "$iface" 2>/dev/null | awk '/inet /{print $2}')
        dialog --title "Wi-Fi" --msgbox "Connected!\n\nInterface : $iface\nSSID      : $selected_ssid\nIP        : $ip" 10 50
    else
        dialog --title "Wi-Fi" --msgbox "Connection failed.\n\nCheck password or signal strength." 8 50
    fi
}

# ---- Wired LAN helpers ----

wired_list_interfaces() {
    for iface in /sys/class/net/*; do
        name=$(basename "$iface")
        # Exclude loopback and wireless
        [ "$name" = "lo" ] && continue
        [ -d "$iface/wireless" ] && continue
        echo "$name"
    done
}

wired_menu() {
    local iface
    iface=$(wired_list_interfaces | grep -v usb | head -1)

    if [ -z "$iface" ]; then
        dialog --title "Wired LAN" --msgbox "No wired interface found." 6 40
        return
    fi

    local choice
    choice=$(dialog --clear \
        --title "Wired LAN - $iface" \
        --menu "Select connection method:" \
        10 50 2 \
        "1" "DHCP (automatic)" \
        "2" "Static IP" \
        2>&1 > /dev/tty)
    [ $? -ne 0 ] && return

    ip link set "$iface" up 2>/dev/null

    case "$choice" in
        1)
            dialog --title "Wired LAN" --infobox "Obtaining IP via DHCP on $iface..." 5 50
            if udhcpc -i "$iface" -t 15 -T 3 -q 2>/dev/null; then
                local ip
                ip=$(ip addr show "$iface" 2>/dev/null | awk '/inet /{print $2}')
                dialog --title "Wired LAN" --msgbox "Connected!\n\nInterface : $iface\nIP        : $ip" 9 50
            else
                dialog --title "Wired LAN" --msgbox "DHCP failed.\n\nCheck cable connection." 7 50
            fi
            ;;
        2)
            local ip_addr gw dns
            ip_addr=$(dialog --title "Static IP" --inputbox "IP Address (e.g. 192.168.1.100/24):" 8 50 2>&1 > /dev/tty)
            [ $? -ne 0 ] && return
            gw=$(dialog --title "Static IP" --inputbox "Gateway (e.g. 192.168.1.1):" 8 50 2>&1 > /dev/tty)
            [ $? -ne 0 ] && return
            dns=$(dialog --title "Static IP" --inputbox "DNS Server (e.g. 8.8.8.8):" 8 50 "8.8.8.8" 2>&1 > /dev/tty)
            [ $? -ne 0 ] && return

            ip addr add "$ip_addr" dev "$iface" 2>/dev/null
            ip route add default via "$gw" 2>/dev/null
            echo "nameserver $dns" > /etc/resolv.conf
            dialog --title "Wired LAN" --msgbox "Static IP configured.\n\nInterface : $iface\nIP        : $ip_addr\nGateway   : $gw\nDNS       : $dns" 11 50
            ;;
    esac
}

# ---- USB Tethering helper ----

usb_tethering_menu() {
    local iface=""
    # USB tethering typically appears as usb0 or enp*u*
    for candidate in usb0 usb1; do
        [ -d "/sys/class/net/$candidate" ] && iface="$candidate" && break
    done
    if [ -z "$iface" ]; then
        # Try to find enp*u* style interface
        iface=$(ls /sys/class/net/ 2>/dev/null | grep -E 'enp.*u|usb' | head -1)
    fi

    if [ -z "$iface" ]; then
        dialog --title "USB Tethering" --msgbox \
            "No USB tethering interface found.\n\nPlease:\n1. Connect your phone via USB\n2. Enable USB Tethering on the phone\n3. Try again" \
            11 55
        return
    fi

    dialog --title "USB Tethering" --infobox "Connecting via $iface (DHCP)..." 5 50
    ip link set "$iface" up 2>/dev/null
    if udhcpc -i "$iface" -t 15 -T 3 -q 2>/dev/null; then
        local ip
        ip=$(ip addr show "$iface" 2>/dev/null | awk '/inet /{print $2}')
        dialog --title "USB Tethering" --msgbox "Connected!\n\nInterface : $iface\nIP        : $ip" 9 50
    else
        dialog --title "USB Tethering" --msgbox "DHCP failed.\n\nCheck phone's USB tethering setting." 8 50
    fi
}

# ---- Show current status ----

show_network_status() {
    local info=""
    for iface in $(ls /sys/class/net/ 2>/dev/null); do
        [ "$iface" = "lo" ] && continue
        local state ip
        state=$(cat "/sys/class/net/$iface/operstate" 2>/dev/null)
        ip=$(ip addr show "$iface" 2>/dev/null | awk '/inet /{print $2}' | head -1)
        [ -z "$ip" ] && ip="(no IP)"
        info="${info}  $iface\t$state\t$ip\n"
    done
    [ -z "$info" ] && info="  (no interfaces found)\n"
    dialog --title "Network Status" --msgbox "$(printf "$info")" 15 60
}

# ---- Main menu ----
while true; do
    CHOICE=$(dialog --clear \
        --backtitle "PCInfo Classic" \
        --title "Network Setup" \
        --menu "Select a connection type:" \
        14 55 5 \
        "1" "Wi-Fi" \
        "2" "Wired LAN" \
        "3" "USB Tethering" \
        "4" "Show Status" \
        "q" "Back to Main Menu" \
        2>&1 > /dev/tty)

    [ $? -ne 0 ] && break

    case "$CHOICE" in
        1) wifi_menu ;;
        2) wired_menu ;;
        3) usb_tethering_menu ;;
        4) show_network_status ;;
        q|Q) break ;;
    esac
done
