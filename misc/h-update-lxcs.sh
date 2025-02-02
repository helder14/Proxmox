#!/usr/bin/env bash

# Copyright (c) 2021-2025 tteck
# Author: tteck (tteckster)
# License: MIT
# https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE

function header_info {
  clear
  cat <<"EOF"
   __  __          __      __          __   _  ________
  / / / /___  ____/ /___ _/ /____     / /  | |/ / ____/
 / / / / __ \/ __  / __ `/ __/ _ \   / /   |   / /
/ /_/ / /_/ / /_/ / /_/ / /_/  __/  / /___/   / /___
\____/ .___/\__,_/\__,_/\__/\___/  /_____/_/|_\____/
    /_/

EOF
}
set -eEuo pipefail

YW=$(echo "\033[33m")
BL=$(echo "\033[36m")
RD=$(echo "\033[01;31m")
CM='\xE2\x9C\x94\033'
GN=$(echo "\033[1;92m")
CL=$(echo "\033[m")

header_info
echo "Loading..."

whiptail --backtitle "Proxmox VE Helper Scripts" --title "Proxmox VE LXC Updater" --yesno "This Will Update LXC Containers. Proceed?" 10 58 || exit

NODE=$(hostname)
EXCLUDE_MENU=()
MSG_MAX_LENGTH=0

# Fetch container list with error handling
container_count=$(pct list | awk 'NR>1 {print $1}' | wc -l)
max_items=20

# Adjust the number of items to display, but don't exceed max_items
items_to_display=$(( container_count < max_items ? container_count : max_items ))

# Dynamically set the window height based on the number of items
height=$(( items_to_display + 4 ))  # Adding some padding for the window

# Set the window width to be double the original (adjust as necessary)
width=58

# Fetch container list
EXCLUDE_MENU=()
while read -r TAG ITEM; do
  OFFSET=2
  ((${#ITEM} + OFFSET > MSG_MAX_LENGTH)) && MSG_MAX_LENGTH=${#ITEM}+OFFSET
  EXCLUDE_MENU+=("$TAG" "$ITEM " "OFF")
done < <(pct list | awk 'NR>1 {print $1, $2}' || { echo "Error: Failed to get container list"; exit 1; })

# If no containers were found, show a message and exit
if [ ${#EXCLUDE_MENU[@]} -eq 0 ]; then
  echo "No containers found! Exiting..."
  exit 1
fi

# Use whiptail to display the list with adjusted window size
excluded_containers=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Proxmox VE LXC Updater" \
  --checklist "\nSelect containers to skip from updates:\n" $height $width 6 "${EXCLUDE_MENU[@]}" 3>&1 1>&2 2>&3 | tr -d '"') || exit

# Update Containers
function update_container() {
  container=$1
  header_info
  name=$(pct exec "$container" hostname)
  os=$(pct config "$container" | awk '/^ostype/ {print $2}')
  if [[ "$os" == "ubuntu" || "$os" == "debian" || "$os" == "fedora" ]]; then
    disk_info=$(pct exec "$container" df /boot | awk 'NR==2{gsub("%","",$5); printf "%s %.1fG %.1fG %.1fG", $5, $3/1024/1024, $2/1024/1024, $4/1024/1024 }')
    read -ra disk_info_array <<<"$disk_info"
    echo -e "${BL}[Info]${GN} Updating ${BL}$container${CL} : ${GN}$name${CL} - ${YW}Boot Disk: ${disk_info_array[0]}% full [${disk_info_array[1]}/${disk_info_array[2]} used, ${disk_info_array[3]} free]${CL}\n"
  else
    echo -e "${BL}[Info]${GN} Updating ${BL}$container${CL} : ${GN}$name${CL} - ${YW}[No disk info for ${os}]${CL}\n"
  fi
  
  # Check for untrusted sources
  untrusted_sources=$(pct exec "$container" -- grep -i "untrusted" /etc/apt/sources.list /etc/apt/sources.list.d/* || true)

  if [[ "$untrusted_sources" == *"untrusted"* ]]; then
    echo -e "${RD}[Warning]${GN} Untrusted source detected in ${BL}$container${CL}. Skipping update...${CL}"
    return
  fi

  # Check if nala is installed
  nala_installed=$(pct exec "$container" -- which nala 2>/dev/null || true)
  if [[ -n "$nala_installed" ]]; then
    # Use nala if installed
    case "$os" in
      ubuntu | debian | devuan)
        pct exec "$container" -- bash -c "
          nala update &&
          nala upgrade &&
          apt-get dist-upgrade -y &&
          rm -rf /usr/lib/python3.*/EXTERNALLY-MANAGED"
        ;;
      *)
        echo -e "${RD}[Error]${GN} Unsupported OS for nala update: ${BL}$os${CL}\n"
        ;;
    esac
  else
    # Fallback to apt-get if nala is not installed
    echo "Nala is not installed, falling back to apt-get"
    case "$os" in
      ubuntu | debian | devuan)
        pct exec "$container" -- bash -c "
          apt-get update &&
          apt-get upgrade -y &&
          apt-get dist-upgrade -y &&
          rm -rf /usr/lib/python3.*/EXTERNALLY-MANAGED"
        ;;
      *)
        echo -e "${RD}[Error]${GN} Unsupported OS for apt-get update: ${BL}$os${CL}\n"
        ;;
    esac
  fi
}

containers_needing_reboot=()
header_info

for container in $(pct list | awk 'NR>1 {print $1}'); do
  if [[ " ${excluded_containers[@]} " =~ " $container " ]]; then
    header_info
    echo -e "${BL}[Info]${GN} Skipping ${BL}$container${CL}"
    sleep 1
  else
    status=$(pct status $container)
    template=$(pct config $container | grep -q "template:" && echo "true" || echo "false")

    if [ "$template" == "false" ] && [ "$status" == "status: stopped" ]; then
      echo -e "${BL}[Info]${GN} Starting${BL} $container ${CL} \n"
      pct start $container
      echo -e "${BL}[Info]${GN} Waiting For${BL} $container${CL}${GN} To Start ${CL} \n"
      sleep 5
      update_container $container
      echo -e "${BL}[Info]${GN} Shutting down${BL} $container ${CL} \n"
      pct shutdown $container &
    elif [ "$status" == "status: running" ]; then
      update_container $container
    fi

    if pct exec "$container" -- [ -e "/var/run/reboot-required" ]; then
        container_hostname=$(pct exec "$container" hostname)
        containers_needing_reboot+=("$container ($container_hostname)")
    fi
  fi
done

wait
header_info
echo -e "${GN}The process is complete, and the containers have been successfully updated.${CL}\n"

if [ "${#containers_needing_reboot[@]}" -gt 0 ]; then
    echo -e "${RD}The following containers require a reboot:${CL}"
    for container_name in "${containers_needing_reboot[@]}"; do
        echo "$container_name"
    done
fi

echo ""
