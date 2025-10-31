#!/bin/bash
set -eo pipefail

LOGS=1

log() {
    [ "$LOGS" -eq 1 ] && echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> install.log
}

[ "$LOGS" -eq 1 ] && exec > >(tee -a install.log) 2>&1

log "Script started"

GREEN="\033[0;32m"
RED="\033[0;31m"
NC="\033[0m"

step=1
print_step() {
    echo -e "${GREEN}[Step ${step}]${NC} $1"
    log "[Step ${step}] $1"
    ((step++))
}

print_error() {
    echo -e "${RED}[Error]${NC} $1"
    log "[Error]$1"
    exit 1
}

validate_number() {
    [[ "$1" =~ ^[0-9]+$ ]] || print_error "Invalid number: $1"
}

[[ "$(id -u)" -eq 0 ]] || print_error "Run as root"

command -v dialog >/dev/null || { apt-get update && apt-get install -y dialog; }
command -v jq >/dev/null || { apt-get update && apt-get install -y jq; }

repo_choice=$(dialog --menu "Select image source:" 15 50 4 \
    1 "Official Ubuntu (cloud images)" \
    2 "LinuxContainers.org (all images)" 2>&1 >/dev/tty)
clear

case $repo_choice in
    1) repo="ubuntu:" ;;
    2) repo="images:" ;;
    *) print_error "Invalid selection" ;;
esac

instance_type=$(dialog --menu "Create container or VM?" 12 40 2 \
    container "Container" \
    virtual-machine "Virtual Machine" 2>&1 >/dev/tty)
clear

vm_flag=""
[ "$instance_type" == "virtual-machine" ] && vm_flag="--vm"

log "Fetching local images for selection..."
choose_local_image() {
    local instance_type=$1
    local images=()
    local menu_options=()
    local selected_alias os_choice selected_image os_alias

    # Получаем список локальных образов
    mapfile -t images < <(lxc image list --format csv | grep ",${instance_type}," || true)

    if [ ${#images[@]} -eq 0 ]; then
        dialog --msgbox "No local images found for type: $instance_type" 6 50
        return 1
    fi

    for i in "${!images[@]}"; do
        alias=$(echo "${images[$i]}" | awk -F',' '{print $2}')
        desc=$(echo "${images[$i]}" | awk -F',' '{print $4}')
        arch=$(echo "${images[$i]}" | awk -F',' '{print $5}')
        menu_options+=("$((i+1))" "$alias | $desc | $arch")
    done

    while true; do
        # Меню с кнопками OK / Cancel / Fetch image
        os_choice=$(dialog --menu "Select OS version (Press F to fetch images):" 25 80 15 "${menu_options[@]}" 2>&1 >/dev/tty)
        ret=$?
        if [ $ret -eq 1 ]; then
            # Cancel
            return 1
        elif [ $ret -eq 0 ]; then
            # OK
            if [[ "$os_choice" =~ ^[0-9]+$ ]] && [ "$os_choice" -ge 1 ] && [ "$os_choice" -le "${#images[@]}" ]; then
                selected_image=${images[$((os_choice-1))]}
                os_alias=$(echo "$selected_image" | awk -F',' '{print $2}')
                echo "$os_alias"
                return 0
            else
                dialog --msgbox "Invalid choice" 5 30
            fi
        fi

        # Обработка нажатия 'F' для fetch
        input=$(dialog --inputbox "Press 'f' to fetch images or Enter to cancel" 6 50 2>&1 >/dev/tty)
        if [[ "$input" == "f" ]]; then
            return 2
        else
            return 1
        fi
    done
}

while true; do
    # Выбираем образ из локальных
    result=$(choose_local_image "$instance_type")
    status=$?
    if [ $status -eq 0 ]; then
        os_alias="$result"
        break
    elif [ $status -eq 2 ]; then
        # Обновляем список образов
        print_step "Fetching images..."
        if [ "$repo" == "images:" ]; then
            lxc image list images: type="$instance_type" --format csv > /tmp/lxc_images.csv
        else
            lxc image list ubuntu: --format csv | grep -i "$instance_type" > /tmp/lxc_images.csv
        fi
        # Повторный вызов выбора
    else
        print_error "Image selection cancelled"
    fi
done

log "Selected image alias: $os_alias"

container_name=$(dialog --inputbox "Instance name:" 8 40 2>&1 >/dev/tty)
container_name=$(echo "$container_name" | tr -cd 'a-zA-Z0-9-')

disk_size=$(dialog --inputbox "Disk size (GB):" 8 40 10 2>&1 >/dev/tty); validate_number "$disk_size"
ram=$(dialog --inputbox "RAM (GB):" 8 40 2>&1 >/dev/tty); validate_number "$ram"; ram_mb=$((ram*1024))
cpu=$(dialog --inputbox "CPU cores:" 8 40 2>&1 >/dev/tty); validate_number "$cpu"

image_path="$(pwd)/${container_name}.img"
[[ ! -e "$image_path" ]] || print_error "Image exists!"

# Вопрос о планируемых snapshot
snapshot_plan=$(dialog --menu "Are snapshots planned?" 12 50 5 \
    1 "No snapshots (100%)" \
    2 "+50%" \
    3 "+100%" \
    4 "+150%" \
    5 "+200%" 2>&1 >/dev/tty)
clear

case $snapshot_plan in
    1) multiplier=1.0 ;;
    2) multiplier=1.5 ;;
    3) multiplier=2.0 ;;
    4) multiplier=2.5 ;;
    5) multiplier=3.0 ;;
    *) multiplier=1.0 ;;
esac

disk_size_final=$(awk "BEGIN {printf \"%d\", $disk_size * $multiplier}")

print_step "Creating disk image"
truncate -s "${disk_size_final}G" "$image_path"
mkfs.btrfs -f "$image_path"

mount_point="/mnt/lxc-pools/${container_name}"
mkdir -p "$mount_point"

print_step "Adding mount to /etc/fstab"
fstab_entry="$(realpath "${image_path}") ${mount_point} btrfs loop,discard,compress=zstd 0 0"
grep -qxF "${fstab_entry}" /etc/fstab || echo "${fstab_entry}" >> /etc/fstab
mount -a || print_error "Mounting via fstab failed"

# Создаем pool
storage_pool="${container_name}-pool"
print_step "Creating storage pool"
lxc storage create "$storage_pool" btrfs source="$mount_point"

print_step "Launching instance"
lxc init "${repo}${os_alias}" "$container_name" $vm_flag --storage="$storage_pool" --config limits.memory="${ram_mb}MB" --config limits.cpu="$cpu"

print_step "Starting instance"
lxc start "$container_name"

# Расширяем диск уровня VM, если необходимо
if [ "$instance_type" == "virtual-machine" ]; then
    print_step "Expanding VM disk"

    # Ждем загрузки VM
    print_step "Wait 30 seconds"
    sleep 30

    # Расширяем диск
    lxc config device set "$container_name" root size="${disk_size}GiB"
    # Перезагружаем VM
    print_step "Restarting VM to apply disk changes"
    lxc restart "$container_name"
    sleep 30

    # Расширяем внутри VM
    print_step "Resizing partition and filesystem inside VM"
    lxc exec "$container_name" -- bash -c '
        set -e
        echo "Expanding partition..."
        growpart /dev/sda 1
        echo "Expanding filesystem..."
        if [ -f /etc/redhat-release ]; then
            xfs_growfs /
        else
            resize2fs /dev/sda1
        fi
        echo "Disk expansion completed."
        df -h /
    '
fi

echo -e "\n${GREEN}[Success]${NC} Instance '$container_name' created:"
echo "- OS: $os_alias"
echo "- Type: ${instance_type^}"
echo "- Disk: ${disk_size}G"
echo "- RAM: ${ram}GB"
echo "- CPU: ${cpu} cores"

log "Instance '$container_name' created successfully"

log "Collecting additional logs"
{
lxc info "$container_name"
lxc config show "$container_name"
lxc storage info "$storage_pool"
} >> install.log

log "Script completed successfully"
