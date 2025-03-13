# !!! Attention: the script works stably only with Ubuntu 22.04 and 24.04

# lxc version

```
Client version: 5.21.3 LTS
Server version: 5.21.3 LTS
```

## Instructions for Using the LXC/LXD Container and Virtual Machine Creation Script

### Installing LXD/LXC on Ubuntu 22.04(24.04)

Before using the script, you need to install LXD/LXC on your Ubuntu 22.04(24.04) system. Follow these steps:

1. Update your system:
   ```
   sudo apt update && sudo apt upgrade -y
   ```

2. Install LXD:
   ```
   sudo apt install lxd -y
   ```

3. Initialize LXD:
   ```
   sudo lxd init
   ```
   Follow the setup wizard instructions, choosing default options or customizing as needed.

4. Add your user to the lxd group:
   ```
   sudo usermod -aG lxd $USER
   ```

5. Restart your session or system for the changes to take effect.

### Script Description

This script automates the process of creating LXC containers or virtual machines using LXD. Here's how it works:

1. **Preparation and Checks**:
   - Sets up logging and error handling.
   - Verifies if it's run as root.
   - Installs necessary dependencies (dialog and jq).

2. **Image Source Selection**:
   - Prompts the user to choose between official Ubuntu images and LinuxContainers.org images.

3. **Instance Type Selection**:
   - User selects between creating a container or a virtual machine.

4. **OS Image Selection**:
   - Fetches a list of available images and prompts the user to select a specific image.

5. **Parameter Configuration**:
   - User inputs instance name, disk size, RAM amount, and CPU cores.

6. **Disk Image Creation and Mounting**:
   - Creates a disk image of the specified size.
   - Formats it as btrfs and mounts it.
   - Adds an entry to /etc/fstab for automatic mounting.

7. **Storage Pool Creation**:
   - Creates an LXD storage pool based on the created disk image.

8. **Instance Launch**:
   - Initializes and starts the container or VM with the specified parameters.

9. **Disk Expansion (VM only)**:
   - For VMs, the script expands the disk to the specified size.
   - Restarts the VM and expands the filesystem inside it.

10. **Completion**:
    - Displays information about the created instance.
    - Saves additional logs to a file.

### Using the Script

1. Save the script to a file, e.g., `create_lxd_instance.sh`.
2. Make the script executable: `chmod +x create_lxd_instance.sh`.
3. Run the script as root: `sudo ./create_lxd_instance.sh`.
4. Follow the instructions in the interactive menu to create a container or VM.

This script provides a convenient way to create and configure LXC containers and virtual machines with flexible parameters, automating many manual steps of the process.

____
# !!! Внимание стабильно скрипт работает только с Ubuntu 22.04 и 24.04

# lxc version

```
Client version: 5.21.3 LTS
Server version: 5.21.3 LTS
```

## Инструкция по использованию скрипта для создания LXC/LXD контейнеров и виртуальных машин

### Установка LXD/LXC на Ubuntu 22.04(24.04)

Перед использованием скрипта необходимо установить LXD/LXC на вашу систему Ubuntu 22.04(24.04). Выполните следующие шаги:

1. Обновите систему:
   ```
   sudo apt update && sudo apt upgrade -y
   ```

2. Установите LXD:
   ```
   sudo apt install lxd -y
   ```

3. Инициализируйте LXD:
   ```
   sudo lxd init
   ```
   Следуйте инструкциям мастера настройки, выбирая параметры по умолчанию или настраивая под свои нужды.

4. Добавьте вашего пользователя в группу lxd:
   ```
   sudo usermod -aG lxd $USER
   ```

5. Перезагрузите сессию или систему, чтобы изменения вступили в силу.

### Описание работы скрипта

Этот скрипт автоматизирует процесс создания LXC контейнеров или виртуальных машин с использованием LXD. Вот как он работает:

1. **Подготовка и проверки**:
   - Скрипт настраивает логирование и обработку ошибок.
   - Проверяет, запущен ли он от имени root.
   - Устанавливает необходимые зависимости (dialog и jq).

2. **Выбор источника образа**:
   - Пользователю предлагается выбрать между официальными образами Ubuntu и образами от LinuxContainers.org.

3. **Выбор типа экземпляра**:
   - Пользователь выбирает между созданием контейнера или виртуальной машины.

4. **Выбор образа ОС**:
   - Скрипт получает список доступных образов и предлагает пользователю выбрать конкретный образ.

5. **Настройка параметров**:
   - Пользователь вводит имя экземпляра, размер диска, объем RAM и количество ядер CPU.

6. **Создание и монтирование образа диска**:
   - Создается образ диска указанного размера.
   - Форматируется в btrfs и монтируется.
   - Добавляется запись в /etc/fstab для автоматического монтирования.

7. **Создание пула хранения**:
   - Создается пул хранения LXD на основе созданного образа диска.

8. **Запуск экземпляра**:
   - Инициализируется и запускается контейнер или VM с указанными параметрами.

9. **Расширение диска (только для VM)**:
   - Если создается VM, скрипт расширяет диск до указанного размера.
   - Перезагружает VM и расширяет файловую систему внутри нее.

10. **Завершение**:
    - Выводится информация о созданном экземпляре.
    - Дополнительные логи сохраняются в файл.

### Использование скрипта

1. Сохраните скрипт в файл, например `create_lxd_instance.sh`.
2. Сделайте скрипт исполняемым: `chmod +x create_lxd_instance.sh`.
3. Запустите скрипт от имени root: `sudo ./create_lxd_instance.sh`.
4. Следуйте инструкциям в интерактивном меню для создания контейнера или VM.

Этот скрипт предоставляет удобный способ создания и настройки LXC контейнеров и виртуальных машин с гибкими параметрами, автоматизируя многие ручные шаги процесса.
