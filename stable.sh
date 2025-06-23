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
if ! sudo apt install -y build-essential curl wget software-properties-common ca-certificates gnupg screen net-tools; then
    echo "Error: Failed to install required packages"
    exit 1
fi

echo "Adding deadsnakes PPA for Python 3.10..."
if ! sudo add-apt-repository ppa:deadsnakes/ppa -y; then
    echo "Error: Failed to add deadsnakes PPA"
    exit 1
fi

if ! sudo apt update; then
    echo "Error: Failed to update package list after adding PPA"
    exit 1
fi

echo "Installing Python 3.10..."
if ! sudo apt install -y python3.10 python3.10-venv python3.10-dev python3.10-distutils; then
    echo "Error: Failed to install Python 3.10"
    exit 1
fi

echo "Setting up Python 3.10 as default python3..."
sudo update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.10 1

echo "Installing pip for Python 3.10..."
if ! curl -sS https://bootstrap.pypa.io/get-pip.py | python3.10; then
    echo "Error: Failed to install pip for Python 3.10"
    exit 1
fi

echo "Setting up NodeSource repository for Node.js 20..."
sudo mkdir -p /etc/apt/keyrings
if ! curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg; then
    echo "Error: Failed to import NodeSource GPG key"
    exit 1
fi

NODE_MAJOR=20
echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_$NODE_MAJOR.x nodistro main" | sudo tee /etc/apt/sources.list.d/nodesource.list

if ! sudo apt update; then
    echo "Error: Failed to update package list after adding NodeSource repository"
    exit 1
fi

echo "Installing Node.js 20..."
if ! sudo apt install -y nodejs; then
    echo "Error: Failed to install Node.js"
    exit 1
fi

if ! command -v node &> /dev/null || ! command -v npm &> /dev/null; then
    echo "Error: Node.js installation verification failed"
    exit 1
fi

echo "Verifying installations..."
python3 --version
pip --version
node -v
npm -v

for pkg in python3 pip; do
    if ! command -v $pkg &> /dev/null; then
        echo "Error: $pkg not found after installation"
        exit 1
    fi
done

echo "Installing JupyterLab and Real-Time Collaboration extension..."
if ! pip install --user --break-system-packages jupyterlab jupyter-collaboration; then
    echo "Error: Failed to install JupyterLab and collaboration extension"
    exit 1
fi

if ! command -v $HOME/.local/bin/jupyter-lab &> /dev/null; then
    echo "Error: JupyterLab installation verification failed"
    exit 1
fi

echo "Verifying jupyter-collaboration extension installation..."
if ! $HOME/.local/bin/jupyter labextension list | grep -q "jupyter-collaboration"; then
    echo "Warning: jupyter-collaboration extension may not be properly installed"
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
    }
}
EOT

echo "Configuring text editor settings..."
cat <<EOT > "$JUPYTER_SETTINGS_DIR/@jupyterlab/fileeditor-extension/plugin.jupyterlab-settings"
{
    "editorConfig": {
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
        }
    },
    \"@jupyterlab/fileeditor-extension:plugin\": {
        \"editorConfig\": {
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

SYSTEMD_SERVICE="/etc/systemd/system/jupyter-lab.service"
sudo bash -c "cat <<EOT > $SYSTEMD_SERVICE
[Unit]
Description=Jupyter Lab Service with Real-Time Collaboration
After=network.target

[Service]
Type=simple
PIDFile=/run/jupyter.pid
WorkingDirectory=/root/
ExecStart=/root/.local/bin/jupyter-lab --config=/root/.jupyter/jupyter_lab_config.py --allow-root --collaborative
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

echo "Starting JupyterLab with Real-Time Collaboration in screen session..."
if ! screen -dmS jupyter-session bash -c "/root/.local/bin/jupyter-lab --allow-root --collaborative"; then
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
echo "Python and Node.js Versions:"
echo "Python: $(python3 --version)"
echo "Node.js: $(node -v)"
echo "NPM: $(npm -v)"
echo "========================================="
echo "JupyterLab Access Information:"
echo "URL: http://$SERVER_IP:$SELECTED_PORT"
echo "Terminal prompt: root@$SELECTED_USERNAME"
echo "Configuration file: $JUPYTER_CONFIG"
echo "Service status: sudo systemctl status jupyter-lab"
echo "Screen session: screen -r jupyter-session"
echo "========================================="
echo "Real-Time Collaboration Features:"
echo "✓ Auto-reload files when modified externally"
echo "✓ File watching for external changes"
echo "✓ No conflict warnings for file modifications"
echo "========================================="
echo "Editor Default Settings:"
echo "✓ JSON files always open in Editor (not viewer)"
echo "✓ All text files default to Editor mode"
echo "✓ Code folding enabled"
echo "✓ Line numbers enabled"
echo "✓ Auto-closing brackets enabled"
echo "========================================="
echo "To start/stop service manually:"
echo "sudo systemctl start jupyter-lab"
echo "sudo systemctl stop jupyter-lab"
echo "========================================="
