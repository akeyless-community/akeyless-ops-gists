#!/usr/bin/env bash
set -euo pipefail

cat <<'EOF'
============================================================
 STEP 1: Update your system and install prerequisites
============================================================
This ensures we have the latest package index and the tools
needed to fetch Docker's official repository.
EOF

sudo apt update
sudo apt install -y ca-certificates curl gnupg lsb-release

cat <<'EOF'
============================================================
 STEP 2: Add Docker’s official GPG key and repository
============================================================
This gives apt access to the latest Docker packages directly
from Docker’s official repositories.
EOF

sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

cat <<'EOF'
============================================================
 STEP 3: Install Docker Engine and CLI
============================================================
This installs the Docker daemon, CLI tools, and plugins such
as Buildx and Compose.
EOF

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

cat <<'EOF'
============================================================
 STEP 4: Enable non-root Docker usage
============================================================
By adding your user to the "docker" group, you can run
Docker commands without "sudo".
EOF

sudo usermod -aG docker $USER

cat <<'EOF'
============================================================
 STEP 5: Test Docker installation
============================================================
This pulls and runs the hello-world container to verify
everything works correctly.
EOF

sudo docker run hello-world

cat <<'EOF'
============================================================
 STEP 6: Install Kind (always fetch latest)
============================================================
Kind lets you spin up Kubernetes clusters inside Docker.
Here we dynamically fetch the latest release from GitHub.
EOF

LATEST_KIND=$(curl -s https://api.github.com/repos/kubernetes-sigs/kind/releases/latest \
  | grep "browser_download_url.*kind-linux-amd64\"" \
  | cut -d '"' -f 4)

echo "Downloading Kind from: $LATEST_KIND"
curl -Lo ./kind "$LATEST_KIND"
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind

cat <<'EOF'
============================================================
 STEP 7: Verify Kind installation
============================================================
Check that the binary is installed and working.
EOF

kind version

cat <<'EOF'
============================================================
 STEP 8: Install Helm
============================================================
Helm is the package manager for Kubernetes. We install it
from the Snap store with the --classic flag.
EOF

sudo snap install helm --classic

cat <<'EOF'
============================================================
 STEP 9: Configure Akeyless Helm repository
============================================================
This adds the official Akeyless Helm chart repository so you
can deploy Akeyless components with Helm.
EOF

helm repo add akeyless https://akeylesslabs.github.io/helm-charts
helm repo update

cat <<'EOF'
============================================================
 STEP 10: Refresh your group membership
============================================================
Now that Docker is installed and your user has been added to
the "docker" group, we need to refresh your shell session.

This will replace your shell with a new one that includes the
updated group membership.
EOF

newgrp docker
