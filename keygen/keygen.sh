#!/bin/bash

# --- Dependency & CLI Installation ---
install_dependency() {
  local tool="$1"
  local os
  os=$(uname)
  if [[ "$os" == "Darwin" ]]; then
    command -v brew &>/dev/null || { echo "Please install Homebrew."; exit 1; }
    echo "Installing ${tool} via Homebrew..."
    brew install "$tool"
  elif [[ "$os" == "Linux" ]]; then
    if command -v apt-get &>/dev/null; then
      echo "Installing ${tool} via apt-get..."
      sudo apt-get update && sudo apt-get install -y "$tool"
    elif command -v yum &>/dev/null; then
      echo "Installing ${tool} via yum..."
      sudo yum install -y "$tool"
    elif command -v dnf &>/dev/null; then
      echo "Installing ${tool} via dnf..."
      sudo dnf install -y "$tool"
    elif command -v pacman &>/dev/null; then
      echo "Installing ${tool} via pacman..."
      sudo pacman -Sy "$tool"
    else
      echo "No supported package manager found. Please install ${tool} manually."
      exit 1
    fi
  else
    echo "Unsupported OS: $(uname). Please install ${tool} manually."
    exit 1
  fi
}

install_akeyless_cli() {
  if command -v akeyless &>/dev/null; then
    echo "Akeyless CLI is already installed."
    return
  fi
  echo "Installing Akeyless CLI..."
  local os=$(uname) arch=$(uname -m) cli_url=""
  if [[ "$os" == "Linux" ]]; then
    [[ "$arch" == "x86_64" ]] && cli_url="https://akeyless-cli.s3.us-east-2.amazonaws.com/cli/latest/production/cli-linux-amd64"
    [[ "$arch" == "aarch64" ]] && cli_url="https://akeyless-cli.s3.us-east-2.amazonaws.com/cli/latest/production/cli-linux-arm64"
  elif [[ "$os" == "Darwin" ]]; then
    [[ "$arch" == "x86_64" ]] && cli_url="https://akeyless-cli.s3.us-east-2.amazonaws.com/cli/latest/production/cli-darwin-amd64"
    [[ "$arch" == "arm64" ]] && cli_url="https://akeyless-cli.s3.us-east-2.amazonaws.com/cli/latest/cli-darwin-arm64"
  fi
  [[ -z "$cli_url" ]] && { echo "Unsupported architecture: $arch on $os."; exit 1; }
  curl -o akeyless "$cli_url"
  chmod +x akeyless
  sudo mv akeyless /usr/local/bin/
  echo "Akeyless CLI installed."
}

# --- Key Conversion & Generation Functions ---
convert_pem_to_base64_der() {
  local pem_file="$1"
  local out_file="$2"
  openssl pkey -in "$pem_file" -outform der | base64 -w 0 > "$out_file"
}

generate_rsa_key() {
  local bits="$1" basefile="$2"
  local temp_pem="${basefile}_temp.pem" final_file="${basefile}.txt"
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:"$bits" -out "$temp_pem"
  convert_pem_to_base64_der "$temp_pem" "$final_file"
  rm "$temp_pem"
}

generate_ec_key() {
  local curve="$1" basefile="$2"
  local temp_pem="${basefile}_temp.pem" final_file="${basefile}.txt"
  openssl ecparam -genkey -name "$curve" -out "$temp_pem"
  convert_pem_to_base64_der "$temp_pem" "$final_file"
  rm "$temp_pem"
}

# --- Main Execution ---
command -v fzf &>/dev/null || install_dependency "fzf"
install_akeyless_cli

# Prompt key type via fzf
key_type=$(printf "AES128GCM\nAES256GCM\nAES128SIV\nAES256SIV\nAES128CBC\nAES256CBC\nRSA1024\nRSA2048\nRSA3072\nRSA4096\nEC256\nEC384\nGPG" | fzf --prompt="Select the key type: ")
[[ -z "$key_type" ]] && { echo "No key type selected. Exiting..."; exit 1; }

# For AES keys, determine byte length
if [[ "$key_type" =~ ^AES ]]; then
  case "$key_type" in
    AES128GCM|AES128CBC) bytes=16 ;;
    AES256GCM|AES256CBC) bytes=32 ;;
    AES128SIV) bytes=32 ;;  # SIV mode: underlying AES-128 requires 32 bytes
    AES256SIV) bytes=64 ;;
  esac
fi

key_file_path=""
extra_params=""
if [[ "$key_type" == AES* ]]; then
  key_file_path="$(pwd)/${key_type}_key.txt"
  openssl rand -base64 "$bytes" | tr -d '\n' > "$key_file_path"
  echo "Generated $key_type key saved to: $key_file_path"
elif [[ "$key_type" == RSA* ]]; then
  bits=${key_type:3}
  base="$(pwd)/${key_type}_key"
  generate_rsa_key "$bits" "$base"
  key_file_path="${base}.txt"
  echo "Generated $key_type RSA key (Base64 DER) saved to: $key_file_path"
elif [[ "$key_type" == EC* ]]; then
  curve="prime256v1"
  [[ "$key_type" == EC384 ]] && curve="secp384r1"
  base="$(pwd)/${key_type}_key"
  generate_ec_key "$curve" "$base"
  key_file_path="${base}.txt"
  echo "Generated $key_type EC key (Base64 DER) saved to: $key_file_path"
elif [[ "$key_type" == GPG ]]; then
  # Set GPG_TTY to avoid tty issues.
  export GPG_TTY=$(tty)
  default_gpg_alg="RSA2048"
  read -p "Enter the GPG algorithm (default: $default_gpg_alg) [RSA1024, RSA2048, RSA3072, RSA4096, Ed25519]: " gpg_alg
  gpg_alg=${gpg_alg:-$default_gpg_alg}

  # Create a temporary config file for GPG key generation.
  gpg_config_file=$(mktemp)
  if [[ "$gpg_alg" == "Ed25519" ]]; then
    cat > "$gpg_config_file" <<EOF
Key-Type: ed25519
Key-Curve: Ed25519
Name-Real: GPG-Key-User
Expire-Date: 0
%commit
EOF
  else
    key_length=${gpg_alg:3}
    cat > "$gpg_config_file" <<EOF
Key-Type: RSA
Key-Length: $key_length
Name-Real: GPG-Key-User
Expire-Date: 0
%commit
EOF
  fi

  # Generate the GPG key non-interactively.
  gpg --batch --passphrase '' --pinentry-mode loopback --gen-key "$gpg_config_file"
  rm "$gpg_config_file"

  # Retrieve the key ID for "GPG-Key-User"
  key_id=$(gpg --list-keys --with-colons GPG-Key-User | awk -F: '/^pub:/ {print $5; exit}')
  if [ -z "$key_id" ]; then
    echo "Failed to generate GPG key."
    exit 1
  fi
  key_file_path="$(pwd)/gpg_key.txt"
  # Export the secret key in ASCII armored format, then convert to Base64.
  gpg --export-secret-key --armor "$key_id" | base64 -w 0 > "$key_file_path"
  echo "Generated GPG key saved to: $key_file_path"

  extra_params="--gpg-alg $gpg_alg"
else
  echo "Unsupported key type: $key_type"
  exit 1
fi

default_key_name="$key_type"
read -p "Enter the name for the key (default: $default_key_name): " key_name
key_name=${key_name:-$default_key_name}
classic_key_name="1-Encryption_Keys/imported/$key_name"

read -p "Enter the Akeyless Gateway URL (default: http://localhost:8000): " gateway_url
gateway_url=${gateway_url:-http://localhost:8000}

read -p "Enter the Protection Key Name (leave blank to use the default key): " protection_key_name

echo -e "\nCreating the Classic Key in Akeyless..."
if [[ "$key_type" == GPG ]]; then
  # For GPG, use the key file parameter.
  akeyless create-classic-key \
    --name "$classic_key_name" \
    --alg "$key_type" \
    --gateway-url "$gateway_url" \
    --key-file-path "$key_file_path" \
    $extra_params \
    ${protection_key_name:+--protection-key-name "$protection_key_name"}
else
  # For other keys, read key data and use --key-data.
  key_data=$(< "$key_file_path")
  # Remap CBC types to GCM for Akeyless.
  alg_for_akeyless="$key_type"
  if [[ "$key_type" == AES128CBC ]]; then
    alg_for_akeyless="AES128GCM"
  elif [[ "$key_type" == AES256CBC ]]; then
    alg_for_akeyless="AES256GCM"
  fi
  akeyless create-classic-key \
    --name "$classic_key_name" \
    --alg "$alg_for_akeyless" \
    --gateway-url "$gateway_url" \
    --key-data "$key_data" \
    ${protection_key_name:+--protection-key-name "$protection_key_name"}
fi

if [ $? -eq 0 ]; then
  echo -e "\nClassic Key created successfully in Akeyless!"
else
  echo -e "\nFailed to create the Classic Key. Please check inputs and try again."
fi
