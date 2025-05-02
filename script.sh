#!/bin/bash

set -e

CUSTOM_USERNAME="root"
echo "Username set to: $CUSTOM_USERNAME"

echo "Determining VPS IP address..."
VPS_IP=$(hostname -I | awk '{print $1}')
if [[ -z "$VPS_IP" ]]; then
    echo "Error: Could not determine VPS IP address."
    exit 1
fi
echo "Identified VPS IP: $VPS_IP"

echo "Enter the port number for JupyterLab [default: 8888]:"
read -p "Port: " PORT_INPUT
CUSTOM_PORT=${PORT_INPUT:-8888}
if ! [[ "$CUSTOM_PORT" =~ ^[0-9]+$ ]] || [ "$CUSTOM_PORT" -lt 1024 ] || [ "$CUSTOM_PORT" -gt 65535 ]; then
    echo "Error: Port must be a number between 1024 and 65535."
    exit 1
fi
echo "Using port: $CUSTOM_PORT"

echo "Updating and upgrading system packages..."
sudo apt update && sudo apt upgrade -y

echo "Installing necessary dependencies..."
sudo apt install -y build-essential curl wget python3 python3-pip screen

echo "Installing Node.js (LTS 20++)..."
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs
node -v
npm -v

echo "Deploying JupyterLab..."
pip install --user jupyterlab

BASHRC_PATH="$HOME/.bashrc"
echo "Modifying PATH and PS1 in .bashrc..."
if ! grep -q "export PATH=\$HOME/.local/bin:\$PATH" "$BASHRC_PATH"; then
    echo 'export PATH=$HOME/.local/bin:$PATH' >> "$BASHRC_PATH"
fi
if ! grep -q "export PATH=\$PATH:/usr/bin:/bin" "$BASHRC_PATH"; then
    echo 'export PATH=$PATH:/usr/bin:/bin' >> "$BASHRC_PATH"
fi
sed -i '/# Custom prompt for root and non-root users/,/# Set the terminal title for xterm-like terminals/d' "$BASHRC_PATH"
cat <<EOT >> "$BASHRC_PATH"
if [ "\$USER" = "root" ]; then
    PS1='\\[\\e[1;32m\\]$CUSTOM_USERNAME@\\h\\[\\e[0m\\]:\\w\\$ '
else
    PS1='\\u@\\h:\\w\\$ '
fi
EOT
export PATH=$HOME/.local/bin:$PATH
export PATH=$PATH:/usr/bin:/bin
if [ "$USER" = "root" ]; then
    export PS1="\\[\\e[1;32m\\]$CUSTOM_USERNAME@\\h\\[\\e[0m\\]:\\w\\$ "
else
    export PS1="\\u@\\h:\\w\\$ "
fi

echo "Generating JupyterLab configuration..."
jupyter-lab --generate-config

echo "Setting JupyterLab password..."
jupyter-lab password

echo "Fetching hashed password from config..."
JUPYTER_PASSWORD_HASH=$(cat ~/.jupyter/jupyter_server_config.json | grep -oP '(?<=hashed_password": ")[^"]*')

CONFIG_PATH="$HOME/.jupyter/jupyter_lab_config.py"
cat <<EOT > "$CONFIG_PATH"
c.ServerApp.ip = '$VPS_IP'
c.ServerApp.open_browser = False
c.ServerApp.password = '$JUPYTER_PASSWORD_HASH'
c.ServerApp.port = $CUSTOM_PORT
c.ContentsManager.allow_hidden = True
c.TerminalInteractiveShell.shell = 'bash'
EOT
echo "Configuration saved at $CONFIG_PATH"

SERVICE_FILE="/etc/systemd/system/jupyter-lab.service"
sudo bash -c "cat <<EOT > $SERVICE_FILE
[Unit]
Description=Jupyter Lab
[Service]
Type=simple
PIDFile=/run/jupyter.pid
WorkingDirectory=$HOME
ExecStart=$HOME/.local/bin/jupyter-lab --config=$HOME/.jupyter/jupyter_lab_config.py --allow-root
User=root
Group=root
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOT"
sudo systemctl daemon-reload
sudo systemctl enable jupyter-lab.service

echo "Initiating JupyterLab in a screen session..."
screen -dmS jupy bash -c "$HOME/.local/bin/jupyter-lab --allow-root"

echo "Setup completed successfully!"
echo "JupyterLab is running at: http://$VPS_IP:$CUSTOM_PORT"
echo "PS1 prompt set to: $CUSTOM_USERNAME@hostname"
echo "Password stored in $CONFIG_PATH."
echo "To reconnect to the screen session, run: screen -r jupy"
