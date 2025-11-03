#!/bin/bash
set -eo pipefail

LOGS=1
TIMEOUT=30  # Таймаут для команд (секунды)

# НОВОЕ: Определяем рабочую директорию (где запущен скрипт)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}/lxc-instances"  # Папка для хранения образов

mkdir -p "$WORK_DIR"

log() {
    [ "$LOGS" -eq 1 ] && echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> install.log
}

[ "$LOGS" -eq 1 ] && exec > >(tee -a install.log) 2>&1

log "Script started from: $SCRIPT_DIR"
log "Work directory: $WORK_DIR"

GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
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

print_warning() {
    echo -e "${YELLOW}[Warning]${NC} $1"
    log "[Warning] $1"
}

print_info() {
    echo -e "${BLUE}[Info]${NC} $1"
    log "[Info] $1"
}

validate_number() {
    [[ "$1" =~ ^[0-9]+$ ]] || print_error "Invalid number: $1"
}

# Функция для отображения спиннера
show_spinner() {
    local message=$1
    local duration=$2
    local elapsed=0
    local spinner="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
    
    while [ $elapsed -lt $duration ]; do
        for i in {0..9}; do
            printf "\r${message} ${spinner:i:1}"
            sleep 0.1
            ((elapsed+=1))
            [ $elapsed -ge $duration ] && break
        done
    done
    printf "\r\033[K"  # Очистить строку
}

[[ "$(id -u)" -eq 0 ]] || print_error "Run as root"

# Проверка доступности LXD
print_step "Checking LXD availability"
if ! timeout $TIMEOUT lxc list >/dev/null 2>&1; then
    print_error "LXD daemon is not available. Start it with: systemctl start lxd"
fi
log "LXD is available"

command -v dialog >/dev/null || { apt-get update && apt-get install -y dialog; }

# Выбор репозитория
repo_choice=$(dialog --menu "Select image source:" 15 50 4 \
    1 "Official Ubuntu (cloud images)" \
    2 "LinuxContainers.org (all images)" 2>&1 >/dev/tty)
ret=$?
clear

if [ $ret -eq 1 ] || [ $ret -eq 255 ]; then
    print_error "Operation cancelled"
fi

case $repo_choice in
    1) repo="ubuntu:" ;;
    2) repo="images:" ;;
    *) print_error "Invalid selection" ;;
esac

log "Selected repository: $repo"

# Выбор типа (контейнер или VM)
instance_type=$(dialog --menu "Create container or VM?" 12 40 2 \
    container "Container" \
    virtual-machine "Virtual Machine" 2>&1 >/dev/tty)
ret=$?
clear

if [ $ret -eq 1 ] || [ $ret -eq 255 ]; then
    print_error "Operation cancelled"
fi

vm_flag=""
[ "$instance_type" == "virtual-machine" ] && vm_flag="--vm"

log "Selected instance type: $instance_type"

# ИСПРАВЛЕНО: Получение списка локальных образов с обработкой потоков
print_step "Checking for local images..."
show_spinner "Loading images" 3

images_data=$(timeout $TIMEOUT lxc image list --format csv 2>&1 || echo "")
log "Raw images data received"

local_images=()
mapfile -t local_images < <(echo "$images_data" | grep ",${instance_type}," || echo "")

if [ ${#local_images[@]} -gt 0 ]; then
    # Есть локальные образы - показываем меню выбора
    print_info "Found ${#local_images[@]} local image(s)"
    
    menu_options=()
    menu_options+=("download" "Download new image from repository")
    
    for i in "${!local_images[@]}"; do
        alias=$(echo "${local_images[$i]}" | awk -F',' '{print $2}')
        desc=$(echo "${local_images[$i]}" | awk -F',' '{print $4}')
        arch=$(echo "${local_images[$i]}" | awk -F',' '{print $5}')
        menu_options+=("$i" "$alias | $desc | $arch")
    done
    
    os_choice=$(dialog --menu "Select OS image:" 25 100 15 "${menu_options[@]}" 2>&1 >/dev/tty)
    ret=$?
    clear
    
    if [ $ret -eq 1 ] || [ $ret -eq 255 ]; then
        print_error "Selection cancelled"
    fi
    
    if [ "$os_choice" == "download" ]; then
        # Пользователь выбрал загрузить новый образ
        need_download=1
    else
        # Пользователь выбрал локальный образ
        os_alias=$(echo "${local_images[$os_choice]}" | awk -F',' '{print $2}')
        image_source="local"
        log "Selected local image: $os_alias"
    fi
else
    # Нет локальных образов - нужно загружать из репозитория
    print_info "No local images found for type: $instance_type"
    need_download=1
fi

# Если нужно загрузить образ из репозитория
if [ "${need_download:-0}" -eq 1 ]; then
    print_step "Fetching images from repository..."
    show_spinner "Downloading image list" 5
    
    if [ "$repo" == "images:" ]; then
        remote_data=$(timeout 60 lxc image list images: type="$instance_type" --format csv 2>&1 || echo "")
    else
        remote_data=$(timeout 60 lxc image list ubuntu: --format csv 2>&1 | grep -i "$instance_type" || echo "")
    fi
    
    log "Remote images data received"
    
    remote_images=()
    mapfile -t remote_images < <(echo "$remote_data")
    
    if [ ${#remote_images[@]} -eq 0 ]; then
        print_error "No images found in repository for type: $instance_type"
    fi
    
    print_info "Found ${#remote_images[@]} image(s) in repository"
    
    menu_options=()
    for i in "${!remote_images[@]}"; do
        alias=$(echo "${remote_images[$i]}" | awk -F',' '{print $2}')
        desc=$(echo "${remote_images[$i]}" | awk -F',' '{print $4}')
        arch=$(echo "${remote_images[$i]}" | awk -F',' '{print $5}')
        menu_options+=("$i" "$alias | $desc | $arch")
    done
    
    os_choice=$(dialog --menu "Select image to download:" 25 100 15 "${menu_options[@]}" 2>&1 >/dev/tty)
    ret=$?
    clear
    
    if [ $ret -eq 1 ] || [ $ret -eq 255 ]; then
        print_error "Selection cancelled"
    fi
    
    os_alias=$(echo "${remote_images[$os_choice]}" | awk -F',' '{print $2}')
    image_source="remote"
    
    # Загружаем образ
    print_step "Downloading image '$os_alias'..."
    show_spinner "Downloading ${os_alias}" 3
    
    if timeout 300 lxc image copy "${repo}${os_alias}" local: --auto-update >/dev/null 2>&1; then
        print_info "Image downloaded successfully"
    else
        print_warning "Image download started (may continue in background)"
    fi
    
    log "Selected remote image: $os_alias"
fi

log "Selected image alias: $os_alias (source: $image_source)"

# Ввод данных с валидацией
container_name=$(dialog --inputbox "Instance name:" 8 40 2>&1 >/dev/tty)
ret=$?
clear
[[ $ret -ne 0 ]] && print_error "Instance name input cancelled"
container_name=$(echo "$container_name" | tr -cd 'a-zA-Z0-9-')
[[ -z "$container_name" ]] && print_error "Instance name cannot be empty"

disk_size=$(dialog --inputbox "Disk size (GB):" 8 40 10 2>&1 >/dev/tty)
ret=$?
clear
[[ $ret -ne 0 ]] && print_error "Disk size input cancelled"
validate_number "$disk_size"

ram=$(dialog --inputbox "RAM (GB):" 8 40 2 2>&1 >/dev/tty)
ret=$?
clear
[[ $ret -ne 0 ]] && print_error "RAM input cancelled"
validate_number "$ram"
ram_mb=$((ram*1024))

cpu=$(dialog --inputbox "CPU cores:" 8 40 2 2>&1 >/dev/tty)
ret=$?
clear
[[ $ret -ne 0 ]] && print_error "CPU input cancelled"
validate_number "$cpu"

# Планирование snapshot'ов с опцией расширения размера
snapshot_plan=$(dialog --menu "Snapshots & size buffer:" 12 50 6 \
    0 "No snapshots (100%)" \
    1 "+10%" \
    2 "+50%" \
    3 "+100%" \
    4 "+150%" \
    5 "+200%" 2>&1 >/dev/tty)
ret=$?
clear
[[ $ret -ne 0 ]] && print_error "Snapshot plan selection cancelled"

case $snapshot_plan in
    0) multiplier=1.0 ;;
    1) multiplier=1.1 ;;
    2) multiplier=1.5 ;;
    3) multiplier=2.0 ;;
    4) multiplier=2.5 ;;
    5) multiplier=3.0 ;;
    *) multiplier=1.0 ;;
esac

disk_size_final=$(awk "BEGIN {printf \"%d\", $disk_size * $multiplier}")

# ИСПРАВЛЕНО: Определение переменных путей относительно рабочей директории
image_path="${WORK_DIR}/${container_name}.img"
mount_point="${WORK_DIR}/${container_name}"
mkdir -p "$WORK_DIR"

log "Image path: $image_path"
log "Mount point: $mount_point"
log "Disk size: ${disk_size}G, Final with buffer: ${disk_size_final}G (multiplier: $multiplier)"

# Создание образа диска
print_step "Creating disk image (${disk_size_final}G)"
show_spinner "Creating disk image" 3

if ! truncate -s "${disk_size_final}G" "$image_path"; then
    print_error "Failed to create disk image"
fi

print_step "Creating btrfs filesystem"
show_spinner "Formatting filesystem" 3

if ! mkfs.btrfs -f "$image_path" >/dev/null 2>&1; then
    print_error "Failed to create btrfs filesystem"
fi

# Монтируем
mkdir -p "$mount_point"

print_step "Adding mount to /etc/fstab"
fstab_entry="$(realpath "${image_path}") ${mount_point} btrfs loop,discard,compress=zstd 0 0"
grep -qxF "${fstab_entry}" /etc/fstab || echo "${fstab_entry}" >> /etc/fstab

if ! mount -a; then
    print_error "Mounting via fstab failed"
fi

log "Filesystem mounted successfully"

# Создаем lxc storage
storage_pool="${container_name}-pool"
print_step "Creating storage pool"
show_spinner "Setting up LXD storage" 2

if ! timeout $TIMEOUT lxc storage create "$storage_pool" btrfs source="$mount_point" 2>&1 >/dev/null; then
    print_error "Failed to create storage pool"
fi

# Создаем и запускаем контейнер/виртуальную машину
print_step "Launching instance"
show_spinner "Initializing ${instance_type^}" 3

if ! timeout 60 lxc init "${repo}${os_alias}" "$container_name" $vm_flag --storage="$storage_pool" --config limits.memory="${ram_mb}MB" --config limits.cpu="$cpu" 2>&1 >/dev/null; then
    print_error "Failed to initialize instance"
fi

print_step "Starting instance"
show_spinner "Starting ${container_name}" 3

if ! timeout 60 lxc start "$container_name" 2>&1 >/dev/null; then
    print_error "Failed to start instance"
fi

# Расширяем диск внутри VM
if [ "$instance_type" == "virtual-machine" ]; then
    print_info "Waiting for VM to fully boot (30 seconds)..."
    show_spinner "VM boot" 30
    
    # расширение уровня LXD
    print_step "Resizing disk at LXD level"
    show_spinner "Setting disk size to ${disk_size_final}GiB" 2
    
    if ! timeout 30 lxc config device set "$container_name" root size="${disk_size_final}GiB" 2>&1 >/dev/null; then
        print_warning "Failed to resize disk at LXD level (may still work)"
    fi
    
    # перезагружать VM
    print_step "Restarting VM to apply disk changes"
    show_spinner "Restarting ${container_name}" 3
    
    if ! timeout 60 lxc restart "$container_name" 2>&1 >/dev/null; then
        print_warning "Failed to restart VM"
    fi
    
    print_info "Waiting for VM to boot after resize (30 seconds)..."
    show_spinner "VM boot" 30
    
    # расширение внутри VM
    print_step "Resizing partition & filesystem inside VM"
    show_spinner "Resizing disk inside VM" 3
    
    if ! timeout 60 lxc exec "$container_name" -- bash -c '
        set -e
        growpart /dev/sda 1 || true
        if [ -f /etc/redhat-release ]; then
            xfs_growfs /
        else
            resize2fs /dev/sda1 || true
        fi
        df -h /
    ' 2>&1 >/dev/null; then
        print_warning "Failed to resize filesystem inside VM (may still work)"
    fi
fi

echo ""
echo -e "${GREEN}✓ Success!${NC} Instance '${GREEN}${container_name}${NC}' created successfully!"
echo ""
echo "Instance Details:"
echo "  OS Image:     $os_alias"
echo "  Type:         ${instance_type^}"
echo "  Disk Size:    ${disk_size_final}G"
echo "  RAM:          ${ram}GB (${ram_mb}MB)"
echo "  CPU Cores:    ${cpu}"
echo "  Image Path:   $image_path"
echo "  Mount Point:  $mount_point"
echo "  Storage Pool: $storage_pool"
echo ""

log "Instance '$container_name' created successfully"
log "Collecting additional logs..."
{
    echo "=== Instance Info ==="
    timeout 30 lxc info "$container_name" 2>&1 || echo "Failed to get instance info"
    echo ""
    echo "=== Instance Config ==="
    timeout 30 lxc config show "$container_name" 2>&1 || echo "Failed to get instance config"
    echo ""
    echo "=== Storage Pool Info ==="
    timeout 30 lxc storage info "$storage_pool" 2>&1 || echo "Failed to get storage pool info"
} >> install.log

log "Script completed successfully"
