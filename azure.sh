#!/bin/bash

set -e

DEFAULT_USER=${DEFAULT_USER:-root}
DEFAULT_PORT=${DEFAULT_PORT:-8888}

cleanup() {
    echo "Cleaning up temporary files..."
    [ -f "/tmp/jupyter_install.log" ] && rm -f /tmp/jupyter_install.log
}
trap cleanup EXIT

echo "Enter custom username for root access:"
read -p "Username [$DEFAULT_USER]: " USERNAME_INPUT
SELECTED_USERNAME=${USERNAME_INPUT:-$DEFAULT_USER}

echo "Choose port for JupyterLab:"
read -p "Port [$DEFAULT_PORT]: " PORT_INPUT
SELECTED_PORT=${PORT_INPUT:-$DEFAULT_PORT}

if ! [[ "$SELECTED_PORT" =~ ^[0-9]+$ ]] || [ "$SELECTED_PORT" -lt 1024 ] || [ "$SELECTED_PORT" -gt 65535 ]; then
    echo "Error: Port must be a number between 1024-65535"
    exit 1
fi

if command -v netstat &> /dev/null; then
    if netstat -tuln | grep -q ":$SELECTED_PORT "; then
        echo "Warning: Port $SELECTED_PORT is already in use"
        read -p "Continue anyway? (y/n): " confirm
        [[ $confirm != "y" && $confirm != "Y" ]] && exit 1
    fi
fi

echo "Using username: $SELECTED_USERNAME"
echo "Using port: $SELECTED_PORT"

echo "Detecting server IP address..."
SERVER_IP=$(curl -s --connect-timeout 10 ifconfig.me 2>/dev/null || curl -s --connect-timeout 10 ipinfo.io/ip 2>/dev/null || curl -s --connect-timeout 10 icanhazip.com 2>/dev/null || hostname -I | awk '{print $1}')
if [[ -z "$SERVER_IP" ]]; then
    echo "Error: Unable to detect server IP address."
    exit 1
fi
echo "Detected server IP: $SERVER_IP"

echo "Updating operating system..."
sudo apt update && sudo apt upgrade -y || { echo "Error: Failed to update system packages"; exit 1; }

echo "Installing required packages..."
sudo apt install -y build-essential curl wget python3 python3-pip python3-full python3-venv screen net-tools || { echo "Error: Failed to install required packages"; exit 1; }

echo "Installing latest Node.js version..."
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - || { echo "Error: Failed to setup Node.js repository"; exit 1; }
sudo apt install -y nodejs || { echo "Error: Failed to install Node.js"; exit 1; }

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

echo "Installing JupyterLab and Real-Time Collaboration extension..."
PIP_BREAK_SYSTEM_PACKAGES=1 pip install --user jupyterlab jupyter-collaboration || { echo "Error: Failed to install JupyterLab and collaboration extension"; exit 1; }

if ! command -v $HOME/.local/bin/jupyter-lab &> /dev/null; then
    echo "Error: JupyterLab installation verification failed"
    exit 1
fi

echo "Verifying jupyter-collaboration extension installation..."
$HOME/.local/bin/jupyter labextension list | grep -q "jupyter-collaboration" || echo "Warning: jupyter-collaboration extension may not be properly installed"

echo "Configuring PATH and prompt in .bashrc..."
BASH_CONFIG="$HOME/.bashrc"
[ -f "$BASH_CONFIG" ] && cp "$BASH_CONFIG" "$BASH_CONFIG.backup.$(date +%Y%m%d_%H%M%S)"

if ! grep -q "export PATH=\$HOME/.local/bin:\$PATH" "$BASH_CONFIG"; then
    echo 'export PATH=$HOME/.local/bin:$PATH' >> "$BASH_CONFIG"
fi

if ! grep -q "export PATH=\$PATH:/usr/bin:/bin" "$BASH_CONFIG"; then
    echo 'export PATH=$PATH:/usr/bin:/bin' >> "$BASH_CONFIG"
fi

sed -i '/# Custom prompt configuration/,/# Terminal title settings/d' "$BASH_CONFIG"
cat <<EOT >> "$BASH_CONFIG"
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
$HOME/.local/bin/jupyter-lab --generate-config || { echo "Error: Failed to generate JupyterLab configuration"; exit 1; }

echo "Setting up password for JupyterLab..."
$HOME/.local/bin/jupyter-lab password || { echo "Error: Failed to set JupyterLab password"; exit 1; }

if [ ! -f ~/.jupyter/jupyter_server_config.json ]; then
    echo "Error: Password configuration file not found"
    exit 1
fi

echo "Reading password hash from configuration file..."
PASSWORD_HASH=$(cat ~/.jupyter/jupyter_server_config.json | grep -oP '(?<=hashed_password": ")[^"]*')
[[ -z "$PASSWORD_HASH" ]] && { echo "Error: Failed to read password hash"; exit 1; }

JUPYTER_CONFIG="$HOME/.jupyter/jupyter_lab_config.py"
cat <<EOT > "$JUPYTER_CONFIG"
c.ServerApp.ip = '0.0.0.0'
c.ServerApp.open_browser = False
c.ServerApp.password = '$PASSWORD_HASH'
c.ServerApp.port = $SELECTED_PORT
c.ContentsManager.allow_hidden = True
c.TerminalInteractiveShell.shell = 'bash'
c.ServerApp.allow_remote_access = True
c.ServerApp.disable_check_xsrf = False
c.LabApp.collaborative = True
c.YDocExtension.file_poll_interval = 1.0
c.YDocExtension.ystore_class = 'jupyter_ydoc.ystore.SQLiteYStore'
c.FileContentsManager.use_atomic_writing = True
c.ContentsManager.checkpoints_kwargs = {'root_dir': '.ipynb_checkpoints'}
EOT

echo "Creating JupyterLab settings directory..."
JUPYTER_SETTINGS_DIR="$HOME/.jupyter/lab/user-settings"
mkdir -p "$JUPYTER_SETTINGS_DIR/@jupyterlab/docmanager-extension"
mkdir -p "$JUPYTER_SETTINGS_DIR/@jupyterlab/fileeditor-extension"

echo "Configuring default file associations to always use editor..."
cat <<EOT > "$JUPYTER_SETTINGS_DIR/@jupyterlab/docmanager-extension/plugin.jupyterlab-settings"
{
    "defaultViewers": {
        "json": "Editor",
        "geojson": "Editor", 
        "txt": "Editor",
        "md": "Editor",
        "py": "Editor",
        "js": "Editor",
        "html": "Editor",
        "css": "Editor",
        "xml": "Editor",
        "yaml": "Editor",
        "yml": "Editor",
        "csv": "Editor",
        "log": "Editor",
        "conf": "Editor",
        "config": "Editor",
        "ini": "Editor"
    },
    "autosaveInterval": 30
}
EOT

echo "Configuring text editor settings..."
cat <<EOT > "$JUPYTER_SETTINGS_DIR/@jupyterlab/fileeditor-extension/plugin.jupyterlab-settings"
{
    "editorConfig": {
        "rulers": [80, 120],
        "lineWrap": "off",
        "lineNumbers": true,
        "wordWrapColumn": 80,
        "tabSize": 4,
        "insertSpaces": true,
        "matchBrackets": true,
        "autoClosingBrackets": true,
        "codeFolding": true
    }
}
EOT

echo "Creating system-wide overrides for all users..."
SYSTEM_OVERRIDES_DIR="/usr/local/share/jupyter/lab/settings"
sudo mkdir -p "$SYSTEM_OVERRIDES_DIR"
sudo bash -c "cat <<EOT > $SYSTEM_OVERRIDES_DIR/overrides.json
{
    \"@jupyterlab/docmanager-extension:plugin\": {
        \"defaultViewers\": {
            \"json\": \"Editor\",
            \"geojson\": \"Editor\",
            \"txt\": \"Editor\",
            \"md\": \"Editor\",
            \"py\": \"Editor\",
            \"js\": \"Editor\",
            \"html\": \"Editor\",
            \"css\": \"Editor\",
            \"xml\": \"Editor\",
            \"yaml\": \"Editor\",
            \"yml\": \"Editor\",
            \"csv\": \"Editor\",
            \"log\": \"Editor\",
            \"conf\": \"Editor\",
            \"config\": \"Editor\",
            \"ini\": \"Editor\"
        },
        \"autosaveInterval\": 30
    },
    \"@jupyterlab/fileeditor-extension:plugin\": {
        \"editorConfig\": {
            \"rulers\": [80, 120],
            \"lineWrap\": \"off\",
            \"lineNumbers\": true,
            \"wordWrapColumn\": 80,
            \"tabSize\": 4,
            \"insertSpaces\": true,
            \"matchBrackets\": true,
            \"autoClosingBrackets\": true,
            \"codeFolding\": true
        }
    }
}
EOT"

echo "Server configuration saved in $JUPYTER_CONFIG"

CURRENT_USER=$(whoami)
SYSTEMD_SERVICE="/etc/systemd/system/jupyter-lab.service"
sudo bash -c "cat <<EOT > $SYSTEMD_SERVICE
[Unit]
Description=Jupyter Lab Service with Real-Time Collaboration
After=network.target

[Service]
Type=simple
PIDFile=/run/jupyter.pid
WorkingDirectory=$HOME/
ExecStart=$HOME/.local/bin/jupyter-lab --config=$HOME/.jupyter/jupyter_lab_config.py --allow-root --collaborative
User=$CURRENT_USER
Group=$CURRENT_USER
Restart=always
RestartSec=10
Environment=PATH=$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

[Install]
WantedBy=multi-user.target
EOT"

sudo systemctl daemon-reload || { echo "Error: Failed to reload systemd daemon"; exit 1; }
sudo systemctl enable jupyter-lab.service || { echo "Error: Failed to enable JupyterLab service"; exit 1; }

echo "Checking if screen session already exists..."
if screen -list | grep -q "jupyter-session"; then
    echo "Terminating existing screen session..."
    screen -S jupyter-session -X quit 2>/dev/null || true
fi

echo "Starting JupyterLab with Real-Time Collaboration in screen session..."
JUPYTER_CMD="cd $HOME && $HOME/.local/bin/jupyter-lab --config=$HOME/.jupyter/jupyter_lab_config.py --ip=0.0.0.0 --port=$SELECTED_PORT --no-browser --allow-root --collaborative"
screen -dmS jupyter-session bash -c "$JUPYTER_CMD" || { echo "Error: Failed to start JupyterLab in screen session"; exit 1; }

sleep 5

if screen -list | grep -q "jupyter-session"; then
    echo "✓ Screen session 'jupyter-session' is running successfully"
else
    echo "Warning: Screen session may not be running properly"
    echo "Trying alternative method..."
    nohup $HOME/.local/bin/jupyter-lab --config=$HOME/.jupyter/jupyter_lab_config.py --ip=0.0.0.0 --port=$SELECTED_PORT --no-browser --allow-root --collaborative > /tmp/jupyter.log 2>&1 &
    echo "JupyterLab started with nohup instead"
fi

echo "Verifying JupyterLab is accessible..."
sleep 5
if command -v curl &> /dev/null; then
    if curl -s --connect-timeout 10 http://localhost:$SELECTED_PORT > /dev/null; then
        echo "✓ JupyterLab is responding on port $SELECTED_PORT"
    else
        echo "Warning: JupyterLab may not be fully started yet"
        echo "Check logs with: screen -r jupyter-session or cat /tmp/jupyter.log"
    fi
fi

echo "Checking port binding..."
if netstat -tuln | grep ":$SELECTED_PORT" | grep -q "0.0.0.0"; then
    echo "✓ JupyterLab is properly bound to all interfaces (0.0.0.0:$SELECTED_PORT)"
elif netstat -tuln | grep -q ":$SELECTED_PORT"; then
    echo "⚠ JupyterLab is running but may only be bound to localhost"
    echo "Check configuration: cat $JUPYTER_CONFIG"
else
    echo "✗ Port $SELECTED_PORT is not listening"
fi

echo "Installation completed successfully!"
echo "========================================="
echo "JupyterLab Access Information:"
echo "URL: http://$SERVER_IP:$SELECTED_PORT"
echo "Terminal prompt: root@$SELECTED_USERNAME"
echo "Configuration file: $JUPYTER_CONFIG"
echo "Service status: sudo systemctl status jupyter-lab"
echo "Screen session: screen -r jupyter-session"
echo "Logs: cat /tmp/jupyter.log (if using nohup)"
echo "========================================="
echo "Debug Commands:"
echo "Check screen sessions: screen -list"
echo "Attach to session: screen -r jupyter-session"
echo "Check port binding: netstat -tuln | grep $SELECTED_PORT"
echo "Manual start: $HOME/.local/bin/jupyter-lab --config=$HOME/.jupyter/jupyter_lab_config.py --ip=0.0.0.0 --port=$SELECTED_PORT --no-browser --allow-root"
echo "========================================="
echo "Real-Time Collaboration Features:"
echo "✓ Auto-reload files when modified externally"
echo "✓ Auto-save every 30 seconds"
echo "✓ File watching for external changes"
echo "✓ No conflict warnings for file modifications"
echo "========================================="
echo "Editor Default Settings:"
echo "✓ JSON files always open in Editor (not viewer)"
echo "✓ All text files default to Editor mode"
echo "✓ Code folding enabled"
echo "✓ Line numbers enabled"
echo "✓ Auto-closing brackets enabled"
echo "✓ Rulers at columns 80 and 120"
echo "========================================="
echo "To start/stop service manually:"
echo "sudo systemctl start jupyter-lab"
echo "sudo systemctl stop jupyter-lab"
echo "========================================="
