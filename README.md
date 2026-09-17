# Exegol GPU Passthrough

NVIDIA GPU passthrough for [Exegol](https://exegol.readthedocs.io/) containers. Enables GPU-accelerated cracking with hashcat, john, and other tools.

Auto-detects your host NVIDIA driver version, writes a config file, and ensures the container environment matches - fixing library symlinks, OpenCL ICD, and CUDA paths automatically.

## Supported Host Distros

| Family | Distros |
|--------|---------|
| **Arch** | Arch, CachyOS, EndeavourOS, Manjaro, Garuda |
| **Fedora** | Fedora, Nobara, RHEL, Rocky, Alma |
| **Debian** | Debian, Ubuntu, Kali, Parrot, Pop!_OS, Mint |

## Prerequisites

1. **NVIDIA drivers** installed on host
2. **Docker** installed

The script automatically installs **nvidia-container-toolkit** and configures the **Docker NVIDIA runtime** if they're missing.

## Quick Start

```bash
# Clone
git clone https://github.com/p3ta00/exegol-gpu.git
cd exegol-gpu

# Run on your HOST machine
./install-gpu.sh
```

This will:
1. Detect your GPU model, driver version, CUDA version, compute capability
2. Install nvidia-container-toolkit if missing (via pacman/dnf/apt)
3. Configure Docker NVIDIA runtime and restart Docker if needed
4. Write `gpu-host.conf` to `~/.exegol/my-resources/setup/gpu/`
5. Copy `setup-gpu.sh` to `~/.exegol/my-resources/setup/gpu/`
6. Patch `load_user_setup.sh` to auto-run GPU setup on every new container
7. Add `--gpu` wrapper to your shell (`~/.zshrc` or `~/.bashrc`)

```bash
# Start Exegol with GPU
exegol start mybox full --gpu
```

GPU setup runs automatically on first container start.

## Verify Inside Container

```bash
gpu-check     # clinfo + hashcat device info
gpu-test      # hashcat MD5 benchmark
gpu-info      # nvidia-smi
gpu-watch     # live nvidia-smi monitor
```

## How It Works

### Host Side (`install-gpu.sh`)

- Detects distro family (Arch/Fedora/Debian) via `/etc/os-release`
- Queries `nvidia-smi` for GPU name, driver version, CUDA version, compute cap, VRAM
- Finds host nvidia lib path (`/usr/lib` on Arch, `/usr/lib/x86_64-linux-gnu` on Debian, `/usr/lib64` on Fedora)
- Installs nvidia-container-toolkit if missing (pacman/dnf/apt)
- Configures Docker NVIDIA runtime, ensures `runc` stays the default runtime, and restarts containerd + Docker
- On Arch/CachyOS: installs a pacman hook that auto-restarts containerd + Docker after every NVIDIA update
- Writes all detected values to `gpu-host.conf`
- Copies `setup-gpu.sh` and patches `load_user_setup.sh`
- Adds a smart `exegol()` shell wrapper (see below)
- No hardcoded driver versions — survives driver updates without changes

### Shell Wrapper (`exegol()` function in `~/.zshrc` / `~/.bashrc`)

The wrapper intercepts `exegol start <name> <image> --gpu` and handles three cases:

| Container state | Action |
|----------------|--------|
| Does not exist | Switch default runtime → `nvidia`, create container, restore `runc` |
| Exists, no GPU | Auto-delete and recreate with `nvidia` runtime, then restore `runc` |
| Exists with GPU | Start normally — no runtime swap needed |

It also checks for NVIDIA driver/library version mismatch before starting and offers to reboot if a driver update hasn't been reflected in the running kernel.

`runc` stays the default runtime at all times — `nvidia` is only set temporarily during container creation. This prevents all non-GPU containers from breaking after driver updates.

### Container Side (`setup-gpu.sh`)

- Reads `gpu-host.conf` to know expected driver version
- Auto-detects the actual mounted driver version (nvidia-smi or scanning versioned `.so` files)
- **Warns on version mismatch** between host config and mounted libs
- Locates nvidia lib directory inside the container (handles Arch/Fedora/Debian path remapping by nvidia-container-toolkit)
- Creates/fixes all library symlinks for the specific driver version:
  - `libcuda.so`, `libnvidia-ml.so`, `libnvidia-opencl.so`, `libnvidia-ptxjitcompiler.so`, etc.
- Configures OpenCL ICD vendor file
- Installs `ocl-icd-libopencl1` and `clinfo`
- Sets `LD_LIBRARY_PATH` and NVIDIA environment variables
- Verifies with nvidia-smi, clinfo, and hashcat

## After Driver Updates

**Arch/CachyOS**: The pacman hook installed by `install-gpu.sh` handles this automatically — containerd and Docker restart after every NVIDIA package update. No manual action needed.

**All distros**: Re-run on the host to refresh `gpu-host.conf`:

```bash
./install-gpu.sh
```

Next time a container starts, the container-side script will pick up the new driver version. If there's a mismatch with a running container, it warns but proceeds with whatever driver is actually mounted.

> **Why containerd must restart after a driver update:** containerd caches the container shim at creation time. If the NVIDIA runtime shim changes (due to a driver update) and containerd isn't restarted, all containers — even non-GPU ones — fail to start with `unsupported protocol` errors. The pacman hook and this script both restart containerd first, then Docker, to clear this state.

## Files

```
exegol-gpu/
├── install-gpu.sh     # Run on HOST - detects GPU, writes config, patches startup
├── setup-gpu.sh       # Runs INSIDE container - matches driver, fixes libs, OpenCL
└── README.md
```

`gpu-host.conf` is generated at runtime and contains your local GPU info (not committed).

## Troubleshooting

### "No NVIDIA driver libraries found in container"
Container wasn't started with GPU passthrough. Use: `exegol start <name> <image> --gpu`

### nvidia-container-toolkit install fails
The script auto-installs via pacman/dnf/apt. If it fails, check your package manager and internet connection. You can also install manually per [NVIDIA docs](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html).

### "DRIVER MISMATCH" warning
Your host driver was updated since the last `install-gpu.sh` run. Re-run it on the host.

### Containers fail to start after NVIDIA driver update ("unsupported protocol" / "failed to create TTRPC connection")
containerd has stale shim state from before the driver update. Fix:
```bash
sudo systemctl restart containerd && sudo systemctl restart docker
```
On Arch/CachyOS, the pacman hook installed by `install-gpu.sh` does this automatically on every future update. Also verify Docker isn't using `nvidia` as its default runtime — it should be `runc`:
```bash
docker info | grep "Default Runtime"
# Should output: Default Runtime: runc
```
If it shows `nvidia`, re-run `install-gpu.sh` to correct it.

### hashcat doesn't see GPU
Try `hashcat -I` to check backends. If OpenCL isn't listed, run `gpu-check` to debug. The CUDA backend may work even without OpenCL.

## License

MIT

## Windows / WSL2 + NVIDIA

Windows is supported through Docker Desktop's Linux engine and WSL2 GPU
passthrough. Native Windows containers are not supported by Exegol.

Prerequisites:

1. WSL2 enabled and Docker Desktop using the WSL2 backend
2. Docker Desktop WSL integration enabled for the distribution you use
3. The current NVIDIA Windows driver (do not install a separate Linux driver
   in WSL2)
4. Exegol installed in PowerShell: `py -m pip install exegol`

From PowerShell in this repository, run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\install-gpu-windows.ps1
```

The installer validates Docker Desktop, runs the same `--gpus all` check used
by Docker's WSL2 integration, and installs the container-side setup script in
`$HOME\.exegol\my-resources\setup\gpu`.

The generated launcher enables Docker's registered `nvidia` runtime for
Exegol container creation and sets the required NVIDIA environment variables.

Start Exegol with the generated launcher:

```powershell
powershell -ExecutionPolicy Bypass -File "$HOME\.exegol\exegol-gpu.ps1" start mybox full
```

The installer starts the Debian WSL2 distribution when present. Keep it
running while Docker Desktop creates Exegol containers; otherwise Docker may
report a missing `/run/guest-services/distro-services/debian.sock`. The
launcher also selects Docker network mode and disables Linux-host X11/timezone
mounts that are not available through Docker Desktop.

To run only the repeatable GPU check:

```powershell
.\gpu-smoke-test.ps1
```

If the smoke test fails, fix Docker Desktop/NVIDIA/WSL2 first; Exegol cannot
make a GPU available when `docker run --gpus all ... nvidia-smi` fails.
