#!/bin/bash
set -eo pipefail

LOGS=0

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
    log "[Error] $1"
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

print_step "Fetching images..."

if [ "$repo" == "images:" ]; then
    # Фильтруем только по типу (container/vm), без указания ОС
    images_csv=$(lxc image list images: type="$instance_type" --format csv)
else
    images_csv=$(lxc image list ubuntu: --format csv | grep -i "$instance_type")
fi

mapfile -t images < <(echo "$images_csv")

[ ${#images[@]} -eq 0 ] && print_error "No images found!"

menu_options=()
for i in "${!images[@]}"; do
    alias=$(echo "${images[$i]}" | awk -F',' '{print $2}')
    desc=$(echo "${images[$i]}" | awk -F',' '{print $4}')
    arch=$(echo "${images[$i]}" | awk -F',' '{print $5}')
    menu_options+=("$((i+1))" "$alias | $desc | $arch")
done

os_choice=$(dialog --menu "Select OS version:" 25 80 15 "${menu_options[@]}" 2>&1 >/dev/tty)
clear

selected_image=${images[$((os_choice-1))]}
os_alias=$(echo "$selected_image" | awk -F',' '{print $2}')

log "Selected image alias: $os_alias"

container_name=$(dialog --inputbox "Instance name:" 8 40 2>&1 >/dev/tty)
container_name=$(echo "$container_name" | tr -cd 'a-zA-Z0-9-')

disk_size=$(dialog --inputbox "Disk size (GB):" 8 40 10 2>&1 >/dev/tty); validate_number "$disk_size"
ram=$(dialog --inputbox "RAM (GB):" 8 40 2>&1 >/dev/tty); validate_number "$ram"; ram_mb=$((ram*1024))
cpu=$(dialog --inputbox "CPU cores:" 8 40 2>&1 >/dev/tty); validate_number "$cpu"

image_path="$(pwd)/${container_name}.img"
[[ ! -e "$image_path" ]] || print_error "Image exists!"

print_step "Creating disk image"
truncate -s "${disk_size}G" "$image_path"
mkfs.btrfs -f "$image_path"

mount_point="/mnt/lxc-pools/${container_name}"
mkdir -p "$mount_point"
mount -o loop,discard,compress=zstd "$image_path" "$mount_point"

# Добавляем автоматическое монтирование в /etc/fstab
print_step "Adding mount to /etc/fstab"
fstab_entry="$(realpath "${image_path}") ${mount_point} btrfs loop,discard,compress=zstd 0 0"
grep -qxF "${fstab_entry}" /etc/fstab || echo "${fstab_entry}" >> /etc/fstab
mount -a || print_error "Mounting via fstab failed"

storage_pool="${container_name}-pool"
print_step "Creating storage pool"
lxc storage create "$storage_pool" btrfs source="$mount_point"

ram_mb=$((ram*1024))

print_step "Launching instance"
lxc init "${repo}${os_alias}" "$container_name" $vm_flag \
    --storage="$storage_pool" \
    --config limits.memory="${ram_mb}MB" \
    --config limits.cpu="$cpu"

print_step "Starting instance"
lxc start "$container_name"

#расширяем раздел диска
if [ "$instance_type" == "virtual-machine" ]; then
    print_step "Expanding VM disk"

    # Ждем, пока VM полностью загрузится
    print_step "Wait 30 seconds"
    sleep 30

    # Расширяем диск на уровне LXD
    lxc config device set "$container_name" root size="${disk_size}GiB"

    # Перезагрузка VM для применения изменений размера диска
    print_step "Restarting VM to apply disk changes"
    lxc restart "$container_name"

    # Ждем, пока VM снова полностью загрузится
    sleep 30

    # Расширяем разделы и файловую систему внутри VM
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
