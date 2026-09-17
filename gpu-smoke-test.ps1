[CmdletBinding()]
param([string]$Image = 'nvidia/cuda:12.4.1-base-ubuntu22.04')
$ErrorActionPreference = 'Stop'
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw 'docker is not installed or not on PATH.' }
docker info *> $null
if ($LASTEXITCODE -ne 0) { throw 'Docker Desktop is not running.' }
docker run --rm --gpus all $Image nvidia-smi
if ($LASTEXITCODE -ne 0) { throw 'NVIDIA GPU passthrough failed.' }
Write-Host '[+] NVIDIA GPU is visible inside a Linux container.' -ForegroundColor Green
