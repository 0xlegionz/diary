#!/bin/bash

set -e

DEFAULT_USER=${DEFAULT_USER:-root}
DEFAULT_PORT=${DEFAULT_PORT:-8888}

cleanup() {
    echo "Cleaning up temporary files..."
    if [ -f "/tmp/jupyter_install.log" ]; then
        rm -f /tmp/jupyter_install.log
    fi
}
trap cleanup EXIT

echo "Enter custom username for root access:"
read -p "Username [$DEFAULT_USER]: " USERNAME_INPUT

if [[ -z "$USERNAME_INPUT" ]]; then
    SELECTED_USERNAME=$DEFAULT_USER
else
    SELECTED_USERNAME=$USERNAME_INPUT
fi

echo "Choose port for JupyterLab:"
read -p "Port [$DEFAULT_PORT]: " PORT_INPUT

if [[ -z "$PORT_INPUT" ]]; then
    SELECTED_PORT=$DEFAULT_PORT
else
    SELECTED_PORT=$PORT_INPUT
fi

if ! [[ "$SELECTED_PORT" =~ ^[0-9]+$ ]] || [ "$SELECTED_PORT" -lt 1024 ] || [ "$SELECTED_PORT" -gt 65535 ]; then
    echo "Error: Port must be a number between 1024-65535"
    exit 1
fi

if command -v netstat &> /dev/null; then
    if netstat -tuln | grep -q ":$SELECTED_PORT "; then
        echo "Warning: Port $SELECTED_PORT is already in use"
        read -p "Continue anyway? (y/n): " confirm
        if [[ $confirm != "y" && $confirm != "Y" ]]; then
            exit 1
        fi
    fi
fi

echo "Using username: $SELECTED_USERNAME"
echo "Using port: $SELECTED_PORT"

echo "Detecting server IP address..."
SERVER_IP=$(hostname -I | awk '{print $1}')
if [[ -z "$SERVER_IP" ]]; then
    echo "Error: Unable to detect server IP address."
    exit 1
fi
echo "Detected server IP: $SERVER_IP"

echo "Updating operating system..."
if ! sudo apt update && sudo apt upgrade -y; then
    echo "Error: Failed to update system packages"
    exit 1
fi

echo "Installing required packages..."
if ! sudo apt install -y build-essential curl wget python3 python3-pip python3-full python3-venv screen net-tools; then
    echo "Error: Failed to install required packages"
    exit 1
fi

echo "Installing latest Node.js version..."
if ! curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -; then
    echo "Error: Failed to setup Node.js repository"
    exit 1
fi

if ! sudo apt install -y nodejs; then
    echo "Error: Failed to install Node.js"
    exit 1
fi

if ! command -v node &> /dev/null || ! command -v npm &> /dev/null; then
    echo "Error: Node.js installation verification failed"
    exit 1
fi

node -v
npm -v

for pkg in python3 pip; do
    if ! command -v $pkg &> /dev/null; then
        echo "Error: $pkg not found after installation"
        exit 1
    fi
done

echo "Installing JupyterLab via pip with break-system-packages..."
if ! pip install --user --break-system-packages jupyterlab; then
    echo "Error: Failed to install JupyterLab"
    exit 1
fi

if ! command -v $HOME/.local/bin/jupyter-lab &> /dev/null; then
    echo "Error: JupyterLab installation verification failed"
    exit 1
fi

echo "Configuring PATH and prompt in .bashrc..."
BASH_CONFIG="$HOME/.bashrc"

if [ -f "$BASH_CONFIG" ]; then
    cp "$BASH_CONFIG" "$BASH_CONFIG.backup.$(date +%Y%m%d_%H%M%S)"
fi

if ! grep -q "export PATH=\$HOME/.local/bin:\$PATH" "$BASH_CONFIG"; then
    echo 'export PATH=$HOME/.local/bin:$PATH' >> "$BASH_CONFIG"
fi

if ! grep -q "export PATH=\$PATH:/usr/bin:/bin" "$BASH_CONFIG"; then
    echo 'export PATH=$PATH:/usr/bin:/bin' >> "$BASH_CONFIG"
fi

sed -i '/# Custom prompt configuration/,/# Terminal title settings/d' "$BASH_CONFIG"
cat <<EOT >> "$BASH_CONFIG"

# Custom prompt configuration for root and non-root users
if [ "\$USER" = "root" ]; then
    PS1='\\[\\e[1;32m\\]root@$SELECTED_USERNAME\\[\\e[0m\\]:\\w\\$ '
else
    PS1='\\u@\\h:\\w\\$ '
fi
EOT

echo "Applying bash configuration changes..."
export PATH=$HOME/.local/bin:$PATH
export PATH=$PATH:/usr/bin:/bin
if [ "$USER" = "root" ]; then
    export PS1="\\[\\e[1;32m\\]root@$SELECTED_USERNAME\\[\\e[0m\\]:\\w\\$ "
else
    export PS1="\\u@\\h:\\w\\$ "
fi

echo "Creating JupyterLab configuration..."
if ! $HOME/.local/bin/jupyter-lab --generate-config; then
    echo "Error: Failed to generate JupyterLab configuration"
    exit 1
fi

echo "Setting up password for JupyterLab..."
if ! $HOME/.local/bin/jupyter-lab password; then
    echo "Error: Failed to set JupyterLab password"
    exit 1
fi

if [ ! -f ~/.jupyter/jupyter_server_config.json ]; then
    echo "Error: Password configuration file not found"
    exit 1
fi

echo "Reading password hash from configuration file..."
PASSWORD_HASH=$(cat ~/.jupyter/jupyter_server_config.json | grep -oP '(?<=hashed_password": ")[^"]*')

if [[ -z "$PASSWORD_HASH" ]]; then
    echo "Error: Failed to read password hash"
    exit 1
fi

JUPYTER_CONFIG="$HOME/.jupyter/jupyter_lab_config.py"
cat <<EOT > "$JUPYTER_CONFIG"
c.ServerApp.ip = '$SERVER_IP'
c.ServerApp.open_browser = False
c.ServerApp.password = '$PASSWORD_HASH'
c.ServerApp.port = $SELECTED_PORT
c.ContentsManager.allow_hidden = True
c.TerminalInteractiveShell.shell = 'bash'
c.ServerApp.allow_remote_access = True
c.ServerApp.disable_check_xsrf = False
EOT

echo "Server configuration saved in $JUPYTER_CONFIG"

SYSTEMD_SERVICE="/etc/systemd/system/jupyter-lab.service"
sudo bash -c "cat <<EOT > $SYSTEMD_SERVICE
[Unit]
Description=Jupyter Lab Service
After=network.target

[Service]
Type=simple
PIDFile=/run/jupyter.pid
WorkingDirectory=/root/
ExecStart=/root/.local/bin/jupyter-lab --config=/root/.jupyter/jupyter_lab_config.py --allow-root
User=root
Group=root
Restart=always
RestartSec=10
Environment=PATH=/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

[Install]
WantedBy=multi-user.target
EOT"

if ! sudo systemctl daemon-reload; then
    echo "Error: Failed to reload systemd daemon"
    exit 1
fi

if ! sudo systemctl enable jupyter-lab.service; then
    echo "Error: Failed to enable JupyterLab service"
    exit 1
fi

echo "Checking if screen session already exists..."
if screen -list | grep -q "jupyter-session"; then
    echo "Terminating existing screen session..."
    screen -S jupyter-session -X quit 2>/dev/null || true
fi

echo "Starting JupyterLab in screen session..."
if ! screen -dmS jupyter-session bash -c "/root/.local/bin/jupyter-lab --allow-root"; then
    echo "Error: Failed to start JupyterLab in screen session"
    exit 1
fi

sleep 3

if ! screen -list | grep -q "jupyter-session"; then
    echo "Warning: Screen session may not be running properly"
fi

echo "Verifying JupyterLab is accessible..."
sleep 5
if command -v curl &> /dev/null; then
    if curl -s --connect-timeout 10 http://localhost:$SELECTED_PORT > /dev/null; then
        echo "JupyterLab is responding on port $SELECTED_PORT"
    else
        echo "Warning: JupyterLab may not be fully started yet"
    fi
fi

echo "Installation completed successfully!"
echo "========================================="
echo "JupyterLab Access Information:"
echo "URL: http://$SERVER_IP:$SELECTED_PORT"
echo "Terminal prompt: root@$SELECTED_USERNAME"
echo "Configuration file: $JUPYTER_CONFIG"
echo "Service status: sudo systemctl status jupyter-lab"
echo "Screen session: screen -r jupyter-session"
echo "========================================="
echo "To start/stop service manually:"
echo "sudo systemctl start jupyter-lab"
echo "sudo systemctl stop jupyter-lab"
echo "========================================="
