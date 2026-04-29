## NVIDIA Container Toolkit - Guide

The [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html) rovides the runtime hook that exposes GPU devices inside Docker containers. 
Without it, `--gpus all` and the `deploy.resources.reservations.devices` directive in Compose won't work.

You do **not** need a host-level CUDA toolkit installation: the vLLM image ships its own CUDA libraries. The host only needs:

1. **NVIDIA GPU driver** (already installed if `nvidia-smi` works on the host)
2. **NVIDIA Container Toolkit** (bridges the driver into containers)

### 1. Check driver compatibility
Look at "CUDA Version: XX.X" in the top-right corner of the output.   
The official vLLM images bundle CUDA 12.x.   
As long as your driver reports CUDA ≥ 12.0 (driver ≥ 525), the default image works.   
```bash
nvidia-smi
```

### 2. Install the toolkit
```bash
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
  sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

### 3. Verify GPU access inside Docker
```bash
docker run --rm --gpus all nvidia/cuda:13.0.3-base-ubuntu24.04 nvidia-smi
```
