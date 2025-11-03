#!/bin/bash
set -eo pipefail

LOGS=1
TIMEOUT=30  # Таймаут для команд (секунды)

log() {
    [ "$LOGS" -eq 1 ] && echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> install.log
}

# Функция для отображения прогресса
progress() {
    local message=$1
    local delay=0.1
    local spinner="/-\|"

    echo -n "$message "
    for ((i=0; ; i++)); do
        # Выводим текущий символ спиннера, перезаписываем его поверх
        printf "\b${spinner:i%4}"
        sleep "$delay"
        # Для выхода, когда команда завершится, нужно вызвать остановку
        # Но здесь используется как индикатор - до вызова следующей операции
    done
}

# Запуск команды с индикатором спиннера
run_with_spinner() {
    local message=$1
    local command=$2

    # Запускаем команду в фоне
    eval "$command" &
    local pid=$!
    # Показываем спиннер, пока команда выполняется
    while kill -0 "$pid" 2>/dev/null; do
        printf "\b|"
        sleep 0.1
        printf "\b/"
        sleep 0.1
        printf "\b-"
        sleep 0.1
        printf "\b\\"
        sleep 0.1
    done
    wait "$pid"
    echo -e "\b Done."
    log "$message - done"
}

[ "$LOGS" -eq 1 ] && exec > >(tee -a install.log) 2>&1

log "Script started"

GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[0;33m"
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

validate_number() {
    [[ "$1" =~ ^[0-9]+$ ]] || print_error "Invalid number: $1"
}

[[ "$(id -u)" -eq 0 ]] || print_error "Run as root"

# Проверка доступности LXD (ИСПРАВЛЕНО: добавлена проверка LXD)
print_step "Checking LXD availability"
if ! timeout $TIMEOUT lxc list >/dev/null 2>&1; then
    print_error "LXD daemon is not available. Start it with: systemctl start lxd"
fi
log "LXD is available"

command -v dialog >/dev/null || { apt-get update && apt-get install -y dialog; }
command -v jq >/dev/null || { apt-get update && apt-get install -y jq; }

# Выбор репозитория (убрана run_with_spinner для интерактивной команды)
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

# Выбор типа (убрана run_with_spinner для интерактивной команды)
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

# Получаем список образов (ИСПРАВЛЕНО: добавлены таймауты и обработка ошибок)
log "Fetching local images for selection..."
choose_local_image() {
    local images=()
    local menu_options=()
    local selected_alias os_choice selected_image os_alias

    # Получаем список образов с таймаутом
    print_step "Loading images from LXD (this may take a moment)..."
    
    if ! images_data=$(timeout $TIMEOUT lxc image list --format csv 2>&1); then
        print_error "Failed to fetch images from LXD. Check LXD status: lxc info"
    fi
    
    log "Raw images data received, filtering..."
    mapfile -t images < <(echo "$images_data" | grep ",${instance_type}," || true)
    
    if [ ${#images[@]} -eq 0 ]; then
        print_warning "No local images found for type: $instance_type"
        dialog --msgbox "No local images found for type: $instance_type\n\nFetching from repository..." 8 50
        clear
        return 2  # Сигнал для загрузки образов
    fi
    
    log "Found ${#images[@]} images"
    
    for i in "${!images[@]}"; do
        alias=$(echo "${images[$i]}" | awk -F',' '{print $2}')
        desc=$(echo "${images[$i]}" | awk -F',' '{print $4}')
        arch=$(echo "${images[$i]}" | awk -F',' '{print $5}')
        menu_options+=("$((i+1))" "$alias | $desc | $arch")
    done

    while true; do
        # Меню выбора с дополнительной кнопкой для загрузки образов
        os_choice=$(dialog --extra-button --extra-label "Fetch" \
            --menu "Select OS version:" 25 80 15 "${menu_options[@]}" 2>&1 >/dev/tty)
        ret=$?
        
        case $ret in
            0) # OK button
                if [[ "$os_choice" =~ ^[0-9]+$ ]] && [ "$os_choice" -ge 1 ] && [ "$os_choice" -le "${#images[@]}" ]; then
                    selected_image=${images[$((os_choice-1))]}
                    os_alias=$(echo "$selected_image" | awk -F',' '{print $2}')
                    echo "$os_alias"
                    clear
                    return 0
                fi
                ;;
            1) # Cancel button
                clear
                return 1
                ;;
            3) # Extra button (Fetch)
                clear
                return 2
                ;;
        esac
    done
}

while true; do
    result=$(choose_local_image "$instance_type")
    status=$?
    if [ $status -eq 0 ]; then
        os_alias="$result"
        break
    elif [ $status -eq 2 ]; then
        # Обновляем список образов (ИСПРАВЛЕНО: добавлены таймауты)
        print_step "Fetching images from repository..."
        
        if [ "$repo" == "images:" ]; then
            if ! timeout $TIMEOUT lxc image list images: type="$instance_type" --format csv > /tmp/lxc_images.csv 2>&1; then
                print_warning "Failed to fetch from images: repository, trying ubuntu:"
            fi
        else
            if ! timeout $TIMEOUT lxc image list ubuntu: --format csv 2>&1 | grep -i "$instance_type" > /tmp/lxc_images.csv; then
                print_warning "Failed to fetch from ubuntu: repository"
            fi
        fi
        log "Image fetch completed"
        # повторный вызов
    else
        print_error "Image selection cancelled"
    fi
done

log "Selected image alias: $os_alias"

# Ввод данных (добавлены проверки на Cancel и пустые значения)
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

# Планирование snapshot'ов
snapshot_plan=$(dialog --menu "Are snapshots planned?" 12 50 5 \
    1 "No snapshots (100%)" \
    2 "+50%" \
    3 "+100%" \
    4 "+150%" \
    5 "+200%" 2>&1 >/dev/tty)
ret=$?
clear
[[ $ret -ne 0 ]] && print_error "Snapshot plan selection cancelled"

case $snapshot_plan in
    1) multiplier=1.0 ;;
    2) multiplier=1.5 ;;
    3) multiplier=2.0 ;;
    4) multiplier=2.5 ;;
    5) multiplier=3.0 ;;
    *) multiplier=1.0 ;;
esac

disk_size_final=$(awk "BEGIN {printf \"%d\", $disk_size * $multiplier}")

# Определение переменной image_path
image_path="/var/lib/lxc-images/${container_name}.img"
mkdir -p /var/lib/lxc-images

log "Image path: $image_path"
log "Disk size final: ${disk_size_final}G"

# Создание образа
print_step "Creating disk image"
truncate -s "${disk_size_final}G" "$image_path" || print_error "Failed to create disk image"
mkfs.btrfs -f "$image_path" || print_error "Failed to create btrfs filesystem"

# Монтируем
mount_point="/mnt/lxc-pools/${container_name}"
mkdir -p "$mount_point"

# добавим флаг
print_step "Adding mount to /etc/fstab"
fstab_entry="$(realpath "${image_path}") ${mount_point} btrfs loop,discard,compress=zstd 0 0"
grep -qxF "${fstab_entry}" /etc/fstab || echo "${fstab_entry}" >> /etc/fstab
mount -a || print_error "Mounting via fstab failed"

# Создаем lxc storage
storage_pool="${container_name}-pool"
print_step "Creating storage pool"
if ! timeout $TIMEOUT lxc storage create "$storage_pool" btrfs source="$mount_point"; then
    print_error "Failed to create storage pool"
fi

# Создаем и запускаем контейнер/виртуальную машину
print_step "Launching instance"
if ! timeout 60 lxc init "${repo}${os_alias}" "$container_name" $vm_flag --storage="$storage_pool" --config limits.memory="${ram_mb}MB" --config limits.cpu="$cpu"; then
    print_error "Failed to initialize instance"
fi

print_step "Starting instance"
if ! timeout 60 lxc start "$container_name"; then
    print_error "Failed to start instance"
fi

# Расширяем диск внутри VM
if [ "$instance_type" == "virtual-machine" ]; then
    print_step "Expanding VM disk"
    sleep 30
    
    # расширение уровня LXD
    if ! timeout 30 lxc config device set "$container_name" root size="${disk_size_final}GiB"; then
        print_warning "Failed to resize disk at LXD level"
    fi
    
    # перезагружать VM
    print_step "Restarting VM to apply disk changes"
    if ! timeout 60 lxc restart "$container_name"; then
        print_warning "Failed to restart VM"
    fi
    sleep 30
    
    # расширение внутри VM
    print_step "Resizing partition & filesystem inside VM"
    if ! timeout 60 lxc exec "$container_name" -- bash -c '
        set -e
        growpart /dev/sda 1 || true
        if [ -f /etc/redhat-release ]; then
            xfs_growfs /
        else
            resize2fs /dev/sda1 || true
        fi
        df -h /
    '; then
        print_warning "Failed to resize filesystem inside VM (may still work)"
    fi
fi

echo -e "${GREEN}[Success]${NC} Instance '$container_name' created:"
echo "- OS: $os_alias"
echo "- Type: ${instance_type^}"
echo "- Disk: ${disk_size_final}G"
echo "- RAM: ${ram}GB"
echo "- CPU: ${cpu} cores"
echo "- Image path: $image_path"

log "Instance '$container_name' created successfully"
log "Collecting additional logs..."
{
    echo "=== Instance Info ==="
    timeout 30 lxc info "$container_name" || echo "Failed to get instance info"
    echo ""
    echo "=== Instance Config ==="
    timeout 30 lxc config show "$container_name" || echo "Failed to get instance config"
    echo ""
    echo "=== Storage Pool Info ==="
    timeout 30 lxc storage info "$storage_pool" || echo "Failed to get storage pool info"
} >> install.log

log "Script completed successfully"
