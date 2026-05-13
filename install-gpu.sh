#!/bin/bash
# ==========================================================================
# Exegol GPU Host Setup
# ==========================================================================
# Run this on your HOST machine to:
#   1. Detect NVIDIA driver version, CUDA version, GPU model
#   2. Install nvidia-container-toolkit (if missing)
#   3. Configure Docker NVIDIA runtime (if needed)
#   4. Write gpu-host.conf so the container script can match versions
#   5. Patch load_user_setup.sh to call setup-gpu.sh on container start
#   6. Add --gpu shell wrapper to ~/.zshrc or ~/.bashrc
#
# Supports: Arch/CachyOS/EndeavourOS, Fedora/RHEL/Nobara,
#           Debian/Ubuntu/Kali/ParrotOS
# ==========================================================================

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Where Exegol my-resources lives on the host
EXEGOL_RESOURCES="${HOME}/.exegol/my-resources"
GPU_DIR="${EXEGOL_RESOURCES}/setup/gpu"
CONF="${GPU_DIR}/gpu-host.conf"
SETUP_SCRIPT="${EXEGOL_RESOURCES}/setup/load_user_setup.sh"

# --------------------------------------------------------------------------
# 0. Detect host distro family
# --------------------------------------------------------------------------
detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            arch|cachyos|endeavouros|manjaro|garuda|artix)
                DISTRO_FAMILY="arch"
                ;;
            fedora|rhel|centos|rocky|alma|nobara)
                DISTRO_FAMILY="fedora"
                ;;
            debian|ubuntu|pop|mint|kali|parrot)
                DISTRO_FAMILY="debian"
                ;;
            opensuse*|sles)
                DISTRO_FAMILY="suse"
                ;;
            *)
                DISTRO_FAMILY="unknown"
                ;;
        esac
        DISTRO_NAME="${PRETTY_NAME:-$ID}"
    else
        DISTRO_FAMILY="unknown"
        DISTRO_NAME="Unknown"
    fi
    echo -e "${BLUE}[*]${NC} Detected distro: ${DISTRO_NAME} (family: ${DISTRO_FAMILY})"
}

# --------------------------------------------------------------------------
# 1. Detect NVIDIA driver + GPU
# --------------------------------------------------------------------------
detect_gpu() {
    echo -e "${BLUE}[*]${NC} Detecting NVIDIA GPU..."

    if ! command -v nvidia-smi &>/dev/null; then
        echo -e "${RED}[-]${NC} nvidia-smi not found. Install NVIDIA drivers first."
        case "$DISTRO_FAMILY" in
            arch)   echo -e "${BLUE}[*]${NC} Try: sudo pacman -S nvidia nvidia-utils" ;;
            fedora) echo -e "${BLUE}[*]${NC} Try: sudo dnf install akmod-nvidia xorg-x11-drv-nvidia-cuda" ;;
            debian) echo -e "${BLUE}[*]${NC} Try: sudo apt install nvidia-driver-XXX" ;;
        esac
        exit 1
    fi

    HOST_GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 | xargs)
    HOST_DRIVER_VERSION=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 | xargs)
    HOST_COMPUTE_CAP=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1 | xargs)
    HOST_GPU_MEM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader 2>/dev/null | head -1 | xargs)

    # CUDA version from nvidia-container-cli or nvidia-smi
    HOST_CUDA_VERSION=""
    if command -v nvidia-container-cli &>/dev/null; then
        HOST_CUDA_VERSION=$(nvidia-container-cli info 2>/dev/null | grep "CUDA" | awk '{print $NF}')
    fi
    if [ -z "$HOST_CUDA_VERSION" ]; then
        HOST_CUDA_VERSION=$(nvidia-smi 2>/dev/null | grep -oP 'CUDA Version: \K[\d.]+')
    fi

    if [ -z "$HOST_DRIVER_VERSION" ]; then
        echo -e "${RED}[-]${NC} Could not detect NVIDIA driver version"
        exit 1
    fi

    echo -e "${GREEN}[+]${NC} GPU:     ${HOST_GPU_NAME}"
    echo -e "${GREEN}[+]${NC} Driver:  ${HOST_DRIVER_VERSION}"
    echo -e "${GREEN}[+]${NC} CUDA:    ${HOST_CUDA_VERSION}"
    echo -e "${GREEN}[+]${NC} Compute: ${HOST_COMPUTE_CAP}"
    echo -e "${GREEN}[+]${NC} VRAM:    ${HOST_GPU_MEM}"

    # Detect host nvidia lib path (varies by distro)
    # Arch/CachyOS: /usr/lib
    # Debian/Ubuntu: /usr/lib/x86_64-linux-gnu
    # Fedora/RHEL:   /usr/lib64
    HOST_NVIDIA_LIB_DIR=""
    for dir in /usr/lib/x86_64-linux-gnu /usr/lib /usr/lib64 /usr/local/nvidia/lib64; do
        if [ -f "${dir}/libcuda.so.${HOST_DRIVER_VERSION}" ]; then
            HOST_NVIDIA_LIB_DIR="$dir"
            break
        fi
    done
    echo -e "${BLUE}[*]${NC} Host lib dir: ${HOST_NVIDIA_LIB_DIR:-not found (nvidia-container-toolkit handles mapping)}"
}

# --------------------------------------------------------------------------
# 2. Install nvidia-container-toolkit (if missing)
# --------------------------------------------------------------------------
install_container_toolkit() {
    echo ""
    echo -e "${BLUE}[*]${NC} Checking nvidia-container-toolkit..."

    if command -v nvidia-container-cli &>/dev/null; then
        NCT_VERSION=$(nvidia-container-cli --version 2>/dev/null | head -1)
        echo -e "${GREEN}[+]${NC} nvidia-container-toolkit installed: ${NCT_VERSION}"
        return 0
    fi

    echo -e "${YELLOW}[~]${NC} nvidia-container-toolkit not found. Installing..."

    case "$DISTRO_FAMILY" in
        arch)
            echo -e "${BLUE}[*]${NC} Installing via pacman..."
            sudo pacman -S --noconfirm nvidia-container-toolkit || {
                echo -e "${RED}[-]${NC} pacman install failed"
                return 1
            }
            ;;
        fedora)
            echo -e "${BLUE}[*]${NC} Adding NVIDIA repo and installing via dnf..."
            curl -s -L https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
                | sudo tee /etc/yum.repos.d/nvidia-container-toolkit.repo > /dev/null
            sudo dnf install -y nvidia-container-toolkit || {
                echo -e "${RED}[-]${NC} dnf install failed"
                return 1
            }
            ;;
        debian)
            echo -e "${BLUE}[*]${NC} Adding NVIDIA repo and installing via apt..."
            curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
                | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg 2>/dev/null
            curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
                | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
                | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null
            sudo apt-get update -qq && sudo apt-get install -y nvidia-container-toolkit || {
                echo -e "${RED}[-]${NC} apt install failed"
                return 1
            }
            ;;
        *)
            echo -e "${RED}[-]${NC} Unsupported distro family: ${DISTRO_FAMILY}"
            echo -e "${YELLOW}[~]${NC} See: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html"
            return 1
            ;;
    esac

    # Verify it installed
    if ! command -v nvidia-container-cli &>/dev/null; then
        echo -e "${RED}[-]${NC} Installation completed but nvidia-container-cli not found"
        return 1
    fi

    NCT_VERSION=$(nvidia-container-cli --version 2>/dev/null | head -1)
    echo -e "${GREEN}[+]${NC} nvidia-container-toolkit installed: ${NCT_VERSION}"
}

# --------------------------------------------------------------------------
# 3. Configure Docker NVIDIA runtime (if needed)
# --------------------------------------------------------------------------
configure_docker_runtime() {
    echo ""
    echo -e "${BLUE}[*]${NC} Checking Docker NVIDIA runtime..."

    if ! command -v docker &>/dev/null; then
        echo -e "${YELLOW}[~]${NC} Docker not found - skipping runtime config"
        echo -e "${YELLOW}[~]${NC} Install Docker, then re-run this script"
        return
    fi

    DOCKER_RUNTIMES=$(docker info 2>/dev/null | grep -i "runtimes" || echo "")
    if echo "$DOCKER_RUNTIMES" | grep -qi "nvidia"; then
        echo -e "${GREEN}[+]${NC} Docker NVIDIA runtime already registered"
    else
        echo -e "${YELLOW}[~]${NC} Docker NVIDIA runtime not configured. Configuring..."

        if ! command -v nvidia-ctk &>/dev/null; then
            echo -e "${RED}[-]${NC} nvidia-ctk not found - cannot configure runtime"
            return 1
        fi

        sudo nvidia-ctk runtime configure --runtime=docker 2>/dev/null || {
            echo -e "${RED}[-]${NC} Failed to configure Docker runtime"
            return 1
        }
    fi

    # nvidia-ctk may set nvidia as the default runtime.
    # This breaks ALL containers (not just GPU ones) after a driver update
    # because containerd caches the shim and fails with an unsupported protocol
    # error until restarted. Keep runc as the default — nvidia is available
    # explicitly via --runtime=nvidia or NVIDIA_VISIBLE_DEVICES when needed.
    DAEMON_JSON="/etc/docker/daemon.json"
    if [ -f "$DAEMON_JSON" ]; then
        CURRENT_DEFAULT=$(python3 -c "import json; d=json.load(open('$DAEMON_JSON')); print(d.get('default-runtime','runc'))" 2>/dev/null)
        if [ "$CURRENT_DEFAULT" = "nvidia" ]; then
            echo -e "${YELLOW}[~]${NC} Docker default runtime is nvidia — switching to runc..."
            sudo python3 -c "
import json
with open('$DAEMON_JSON') as f: cfg = json.load(f)
cfg['default-runtime'] = 'runc'
with open('$DAEMON_JSON', 'w') as f: json.dump(cfg, f, indent=4)
f.write('\n')
" && echo -e "${GREEN}[+]${NC} Default runtime set to runc (nvidia still available as explicit runtime)"
        fi
    fi

    echo -e "${BLUE}[*]${NC} Restarting containerd and Docker..."
    sudo systemctl restart containerd 2>/dev/null || true
    sudo systemctl restart docker 2>/dev/null || {
        echo -e "${YELLOW}[~]${NC} Could not restart Docker via systemctl"
        echo -e "${YELLOW}[~]${NC} Restart Docker manually, then re-run this script"
        return
    }

    # Verify after restart
    DOCKER_RUNTIMES=$(docker info 2>/dev/null | grep -i "runtimes" || echo "")
    DEFAULT_RUNTIME=$(docker info 2>/dev/null | grep -i "Default Runtime" || echo "")
    if echo "$DOCKER_RUNTIMES" | grep -qi "nvidia"; then
        echo -e "${GREEN}[+]${NC} Docker NVIDIA runtime configured and verified"
        echo -e "${GREEN}[+]${NC} ${DEFAULT_RUNTIME}"
    else
        echo -e "${YELLOW}[~]${NC} Runtime configured but not detected - Docker may need a manual restart"
    fi
}

# --------------------------------------------------------------------------
# 3b. Install pacman hook (Arch only) to auto-restart containerd + Docker
#     after NVIDIA driver updates — prevents the broken shim error
# --------------------------------------------------------------------------
install_update_hook() {
    [ "$DISTRO_FAMILY" != "arch" ] && return

    echo ""
    echo -e "${BLUE}[*]${NC} Checking NVIDIA update hook for Arch..."

    HOOK_SCRIPT="/usr/local/bin/nvidia-docker-reload"
    HOOK_FILE="/etc/pacman.d/hooks/nvidia-docker-reload.hook"

    # If hook script exists and already restarts containerd, nothing to do
    if [ -f "$HOOK_SCRIPT" ] && grep -q "restart containerd" "$HOOK_SCRIPT"; then
        echo -e "${GREEN}[+]${NC} NVIDIA update hook already configured"
        return
    fi

    sudo mkdir -p /etc/pacman.d/hooks

    sudo tee "$HOOK_SCRIPT" > /dev/null << 'HOOKSCRIPT'
#!/bin/bash
# Restarts containerd + Docker after NVIDIA driver updates.
# containerd caches shim state — without a restart after a driver update
# all containers fail with "unsupported protocol" until containerd is cycled.

LOADED_VER=$(cat /proc/driver/nvidia/version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)
PKG_VER=$(pacman -Q nvidia-utils 2>/dev/null | awk '{print $2}' | cut -d- -f1)

logger -t nvidia-docker-reload "loaded=$LOADED_VER pkg=$PKG_VER"

if [[ "$LOADED_VER" == "$PKG_VER" ]]; then
    logger -t nvidia-docker-reload "versions match — restarting containerd and docker"
    systemctl restart containerd && systemctl restart docker
    exit 0
fi

if lsof /dev/nvidia* 2>/dev/null | grep -q .; then
    logger -t nvidia-docker-reload "WARN: /dev/nvidia* in use — reboot required"
    wall "NVIDIA driver updated. Reboot required before Docker GPU containers will work."
    touch /run/nvidia-reboot-required
    exit 0
fi

modprobe -r nvidia_uvm nvidia_drm nvidia_modeset nvidia 2>/dev/null
if modprobe nvidia; then
    logger -t nvidia-docker-reload "modules reloaded — restarting containerd and docker"
    systemctl restart containerd && systemctl restart docker
else
    logger -t nvidia-docker-reload "module reload failed — reboot required"
    wall "NVIDIA driver updated. Reboot required before Docker GPU containers will work."
    touch /run/nvidia-reboot-required
fi
HOOKSCRIPT

    sudo chmod +x "$HOOK_SCRIPT"

    sudo tee "$HOOK_FILE" > /dev/null << 'HOOKDEF'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = nvidia
Target = nvidia-dkms
Target = nvidia-utils
Target = nvidia-open
Target = linux-cachyos-nvidia-open
Target = linux-cachyos-lts-nvidia-open
Target = nvidia-container-toolkit

[Action]
Description = Restarting containerd and Docker after NVIDIA update...
When = PostTransaction
Exec = /bin/sh -c "/usr/local/bin/nvidia-docker-reload"
Depends = bash
HOOKDEF

    echo -e "${GREEN}[+]${NC} Pacman hook installed — containerd + Docker restart automatically after NVIDIA updates"
}

# --------------------------------------------------------------------------
# 4. Write gpu-host.conf
# --------------------------------------------------------------------------
write_config() {
    echo ""
    echo -e "${BLUE}[*]${NC} Writing GPU config..."

    mkdir -p "$GPU_DIR"

    cat > "$CONF" << HOSTCONF
# Auto-generated by install-gpu.sh on $(date -Iseconds)
# Re-run install-gpu.sh after driver updates to refresh this file.

HOST_DISTRO_FAMILY="${DISTRO_FAMILY}"
HOST_DISTRO_NAME="${DISTRO_NAME}"
HOST_GPU_NAME="${HOST_GPU_NAME}"
HOST_DRIVER_VERSION="${HOST_DRIVER_VERSION}"
HOST_CUDA_VERSION="${HOST_CUDA_VERSION}"
HOST_COMPUTE_CAP="${HOST_COMPUTE_CAP}"
HOST_GPU_MEM="${HOST_GPU_MEM}"
HOST_NVIDIA_LIB_DIR="${HOST_NVIDIA_LIB_DIR}"
HOSTCONF

    echo -e "${GREEN}[+]${NC} Config written to ${CONF}"
}

# --------------------------------------------------------------------------
# 5. Copy setup-gpu.sh to my-resources
# --------------------------------------------------------------------------
copy_container_script() {
    echo ""
    echo -e "${BLUE}[*]${NC} Copying container-side GPU script..."

    if [ -f "${SCRIPT_DIR}/setup-gpu.sh" ]; then
        cp "${SCRIPT_DIR}/setup-gpu.sh" "${GPU_DIR}/setup-gpu.sh"
        chmod +x "${GPU_DIR}/setup-gpu.sh"
        echo -e "${GREEN}[+]${NC} setup-gpu.sh copied to ${GPU_DIR}/"
    else
        echo -e "${RED}[-]${NC} setup-gpu.sh not found next to this script (${SCRIPT_DIR}/)"
        echo -e "${RED}[-]${NC} Copy it manually to ${GPU_DIR}/setup-gpu.sh"
    fi
}

# --------------------------------------------------------------------------
# 6. Patch load_user_setup.sh
# --------------------------------------------------------------------------
patch_setup_script() {
    echo ""
    echo -e "${BLUE}[*]${NC} Patching load_user_setup.sh..."

    # Create my-resources setup dir and load_user_setup.sh if they don't exist
    mkdir -p "$(dirname "$SETUP_SCRIPT")"

    if [ ! -f "$SETUP_SCRIPT" ]; then
        echo -e "${YELLOW}[~]${NC} ${SETUP_SCRIPT} not found - creating it..."
        cat > "$SETUP_SCRIPT" << 'NEWSETUP'
#!/bin/bash

# Exegol first-start setup (auto-generated by install-gpu.sh)

GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

# ============================================================================
# NVIDIA GPU Setup (driver-aware, auto-detected)
# ============================================================================
if [ -f /opt/my-resources/setup/gpu/setup-gpu.sh ]; then
    /opt/my-resources/setup/gpu/setup-gpu.sh || echo -e "${RED}[-]${NC} GPU setup had errors, continuing..."
fi

echo -e "${GREEN}[+]${NC} First-time setup complete!"
NEWSETUP
        chmod +x "$SETUP_SCRIPT"
        echo -e "${GREEN}[+]${NC} Created load_user_setup.sh with GPU setup"
        return 0
    fi

    # Already patched?
    if grep -q "setup/gpu/setup-gpu.sh" "$SETUP_SCRIPT"; then
        echo -e "${YELLOW}[~]${NC} Already patched with setup-gpu.sh call"
    else
        # Remove trailing "First-time setup complete" line
        sed -i '/echo.*First-time setup complete/d' "$SETUP_SCRIPT"

        # Remove trailing blank lines
        sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$SETUP_SCRIPT"

        # Append the GPU setup block + completion message
        cat >> "$SETUP_SCRIPT" << 'GPUBLOCK'

# ============================================================================
# NVIDIA GPU Setup (driver-aware, auto-detected)
# ============================================================================
if [ -f /opt/my-resources/setup/gpu/setup-gpu.sh ]; then
    /opt/my-resources/setup/gpu/setup-gpu.sh || echo -e "${RED}[-]${NC} GPU setup had errors, continuing..."
fi

echo -e "${GREEN}[+]${NC} First-time setup complete!"
GPUBLOCK

        echo -e "${GREEN}[+]${NC} load_user_setup.sh patched"
    fi

    # Remove old inline NVIDIA block if present (from older setups)
    if grep -q "NVIDIA GPU Support (OpenCL ICD for hashcat" "$SETUP_SCRIPT"; then
        echo -e "${BLUE}[*]${NC} Removing old inline NVIDIA block..."
        # Use python for reliable multi-line removal, fallback to sed
        python3 -c "
import re
with open('$SETUP_SCRIPT') as f: text = f.read()
text = re.sub(r'# =+\n# NVIDIA GPU Support \(OpenCL ICD.*?\nfi\n*', '', text, flags=re.DOTALL)
with open('$SETUP_SCRIPT','w') as f: f.write(text)
" 2>/dev/null || sed -i '/NVIDIA GPU Support (OpenCL ICD/,/^fi$/d' "$SETUP_SCRIPT"
        echo -e "${GREEN}[+]${NC} Old inline block removed"
    fi
}

# --------------------------------------------------------------------------
# 7. Add --gpu shell wrapper to user's shell rc
# --------------------------------------------------------------------------
setup_shell_wrapper() {
    echo ""
    echo -e "${BLUE}[*]${NC} Configuring shell --gpu wrapper..."

    # Find exegol binary
    EXEGOL_BIN=""
    for candidate in \
        "$(command -v exegol 2>/dev/null)" \
        "${HOME}/.local/bin/exegol" \
        "/usr/local/bin/exegol" \
        "/usr/bin/exegol"; do
        if [ -n "$candidate" ] && [ -f "$candidate" ]; then
            EXEGOL_BIN="$candidate"
            break
        fi
    done

    if [ -z "$EXEGOL_BIN" ]; then
        echo -e "${YELLOW}[~]${NC} Could not find exegol binary - skipping shell wrapper"
        echo -e "${YELLOW}[~]${NC} You can manually start with: exegol start <name> <image> --privileged -e NVIDIA_VISIBLE_DEVICES=all -e NVIDIA_DRIVER_CAPABILITIES=compute,utility"
        return
    fi

    # Detect shell rc file
    SHELL_RC=""
    if [ -n "$ZSH_VERSION" ] || [ "$(basename "$SHELL")" = "zsh" ]; then
        SHELL_RC="${HOME}/.zshrc"
    elif [ -n "$BASH_VERSION" ] || [ "$(basename "$SHELL")" = "bash" ]; then
        SHELL_RC="${HOME}/.bashrc"
    fi

    if [ -z "$SHELL_RC" ] || [ ! -f "$SHELL_RC" ]; then
        echo -e "${YELLOW}[~]${NC} Could not detect shell rc file - skipping shell wrapper"
        return
    fi

    # Remove any old GPU wrapper (hardcoded driver version style)
    if grep -q "gpu_args=(" "$SHELL_RC" 2>/dev/null; then
        echo -e "${BLUE}[*]${NC} Removing old hardcoded GPU wrapper from ${SHELL_RC}..."
        # Remove old exegol function block with gpu_args
        python3 -c "
import re
with open('$SHELL_RC') as f: text = f.read()
# Remove old-style wrapper with hardcoded gpu_args
text = re.sub(r'\n*unalias exegol[^\n]*\nexegol\(\) \{[^}]*gpu_args=\([^)]*\)[^}]*\}\n*', '\n', text, flags=re.DOTALL)
with open('$SHELL_RC','w') as f: f.write(text)
" 2>/dev/null
        echo -e "${GREEN}[+]${NC} Old GPU wrapper removed"
    fi

    # Check if our new wrapper already exists
    if grep -q "# exegol-gpu: --gpu wrapper" "$SHELL_RC" 2>/dev/null; then
        echo -e "${YELLOW}[~]${NC} GPU wrapper already present in ${SHELL_RC}"
        return
    fi

    # Add the wrapper
    cat >> "$SHELL_RC" << SHELLWRAPPER

# exegol-gpu: --gpu wrapper (added by install-gpu.sh)
# Translates 'exegol start <name> <image> --gpu' into the right flags.
# Uses nvidia runtime only at container creation time, then restores runc.
# If the container already has GPU (NVIDIA_VISIBLE_DEVICES in env), just starts it.
# If the container exists without GPU, auto-deletes and recreates it with GPU.
exegol() {
    if [[ "\$1" == "start" ]] && [[ " \$* " == *" --gpu "* ]]; then
        local name="\$2"
        local args=("\${@/--gpu/}")

        # Check for nvidia driver/library version mismatch before GPU start
        local loaded_ver=\$(cat /proc/driver/nvidia/version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)
        local lib_ver=\$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null)
        if [[ -z "\$lib_ver" ]] || [[ "\$loaded_ver" != "\$lib_ver" ]]; then
            echo "\e[1;31m[!] NVIDIA driver mismatch: kernel=\$loaded_ver libs=\${lib_ver:-unknown}\e[0m"
            echo "\e[1;33m[*] GPU was updated since last boot. Reboot required.\e[0m"
            echo -n "    Reboot now? [y/N] "
            read -r reply
            if [[ "\$reply" =~ ^[Yy]\$ ]]; then
                systemctl reboot
            fi
            return 1
        fi

        # Determine if we need to switch to nvidia runtime:
        #   - Container doesn't exist yet → create fresh with nvidia runtime
        #   - Container exists but lacks NVIDIA_VISIBLE_DEVICES → recreate with nvidia runtime
        #   - Container exists and already has GPU env → just start it (no runtime swap)
        local needs_runtime_swap=false
        local container_id
        container_id=\$(docker ps -a --format '{{.Names}} {{.ID}}' 2>/dev/null | grep "^exegol-\${name} " | awk '{print \$2}')
        if [[ -z "\$container_id" ]]; then
            needs_runtime_swap=true
        elif ! docker inspect "\$container_id" --format '{{json .Config.Env}}' 2>/dev/null | grep -q "NVIDIA_VISIBLE_DEVICES"; then
            echo "\e[1;33m[!]\e[0m Container exists without GPU support, recreating with nvidia runtime..."
            docker rm -f "\$container_id" >/dev/null
            needs_runtime_swap=true
        fi

        if [[ "\$needs_runtime_swap" == "true" ]]; then
            echo "\e[0;34m[*]\e[0m Switching to nvidia runtime for GPU container creation..."
            sudo python3 -c "
import json
with open('/etc/docker/daemon.json') as f: d = json.load(f)
d['default-runtime'] = 'nvidia'
with open('/etc/docker/daemon.json', 'w') as f: json.dump(d, f, indent=4); f.write('\n')
"
            sudo systemctl restart docker
        fi

        sudo -E ${EXEGOL_BIN} \${args[@]} \\
            --privileged \\
            -e NVIDIA_VISIBLE_DEVICES=all \\
            -e NVIDIA_DRIVER_CAPABILITIES=compute,utility
        local exit_code=\$?

        if [[ "\$needs_runtime_swap" == "true" ]]; then
            echo "\e[0;34m[*]\e[0m Restoring runc as default runtime..."
            sudo python3 -c "
import json
with open('/etc/docker/daemon.json') as f: d = json.load(f)
d['default-runtime'] = 'runc'
with open('/etc/docker/daemon.json', 'w') as f: json.dump(d, f, indent=4); f.write('\n')
"
            sudo systemctl restart docker
        fi

        return \$exit_code
    else
        sudo -E ${EXEGOL_BIN} "\$@"
    fi
}
SHELLWRAPPER

    echo -e "${GREEN}[+]${NC} GPU wrapper added to ${SHELL_RC}"
    echo -e "${BLUE}[*]${NC}   Wrapper features:"
    echo -e "${BLUE}[*]${NC}     - Driver mismatch check (warns and offers reboot)"
    echo -e "${BLUE}[*]${NC}     - Switches to nvidia runtime only at container creation time"
    echo -e "${BLUE}[*]${NC}     - Auto-detects existing containers without GPU and recreates them"
    echo -e "${BLUE}[*]${NC}     - Restores runc as default after creation"
    echo -e "${BLUE}[*]${NC}   Run 'source ${SHELL_RC}' or open a new terminal to activate"
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
echo "=========================================="
echo "  Exegol GPU Host Setup"
echo "=========================================="
echo ""

detect_distro
detect_gpu
install_container_toolkit || exit 1
configure_docker_runtime
install_update_hook
write_config
copy_container_script
patch_setup_script
setup_shell_wrapper

echo ""
echo "=========================================="
echo -e "${GREEN}[+]${NC} Setup complete!"
echo "=========================================="
echo ""
echo "Start Exegol with GPU:"
echo -e "  ${YELLOW}exegol start <name> <image> --gpu${NC}"
echo ""
echo "After driver updates, re-run this script to update gpu-host.conf."
echo ""
echo "NOTE (Arch/CachyOS): The pacman hook installed above will automatically"
echo "restart containerd + Docker after every NVIDIA package update."
echo "If you skip re-running this script, Exegol containers may warn about"
echo "a driver mismatch but will still function with the mounted driver."
echo ""
