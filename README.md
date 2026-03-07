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
2. **nvidia-container-toolkit** installed (the script will guide you if missing)
3. **Docker** configured with NVIDIA runtime

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
2. Verify nvidia-container-toolkit is installed (prints distro-specific install instructions if not)
3. Write `gpu-host.conf` to `~/.exegol/my-resources/setup/gpu/`
4. Copy `setup-gpu.sh` to `~/.exegol/my-resources/setup/gpu/`
5. Patch `load_user_setup.sh` to auto-run GPU setup on every new container

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
- Checks nvidia-container-toolkit and Docker NVIDIA runtime
- Writes all detected values to `gpu-host.conf`
- Copies `setup-gpu.sh` and patches `load_user_setup.sh`

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

```bash
# Re-run on host to update the config
./install-gpu.sh
```

Next time a container starts, the container-side script will pick up the new driver version. If there's a mismatch with a running container, it warns but proceeds with whatever driver is actually mounted.

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

### "nvidia-container-toolkit NOT installed"
The script prints distro-specific install instructions. Follow them, then re-run.

### "DRIVER MISMATCH" warning
Your host driver was updated since the last `install-gpu.sh` run. Re-run it on the host.

### hashcat doesn't see GPU
Try `hashcat -I` to check backends. If OpenCL isn't listed, run `gpu-check` to debug. The CUDA backend may work even without OpenCL.

## License

MIT
