SERVICE_NAME="nc-discord"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
VENV_PYTHON="${SCRIPT_DIR}/.venv/bin/python3"

sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=Nextcloud Discord Signal bridge
After=network.target docker.service
Requires=docker.service

[Service]
Type=simple
User=$(whoami)
WorkingDirectory=${SCRIPT_DIR}
EnvironmentFile=${SCRIPT_DIR}/.env
ExecStart=${VENV_PYTHON} ${SCRIPT_DIR}/src/discord-script.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now "${SERVICE_NAME}.service"

echo ""
echo "Service installed and started."
echo "Check status with:  systemctl status ${SERVICE_NAME}.service"
echo "View logs with:     journalctl -u ${SERVICE_NAME}.service -f"