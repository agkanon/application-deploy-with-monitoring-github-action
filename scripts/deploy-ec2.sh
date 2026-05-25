#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_ROOT="/opt/bmi-health-tracker"
BACKEND_SRC="$REPO_ROOT/backend"
FRONTEND_SRC="$REPO_ROOT/frontend"
MONITORING_SRC="$REPO_ROOT/monitoring"

DB_USER="${DB_USER:-bmi_user}"
DB_PASSWORD="${DB_PASSWORD:-bmi_user}"
DB_NAME="${DB_NAME:-bmidb}"
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
FRONTEND_URL="${FRONTEND_URL:-http://localhost}"

SMTP_HOST="${SMTP_HOST:-smtp.example.com}"
SMTP_PORT="${SMTP_PORT:-587}"
SMTP_USER="${SMTP_USER:-smtp-user}"
SMTP_PASSWORD="${SMTP_PASSWORD:-smtp-password}"
SMTP_FROM="${SMTP_FROM:-alertmanager@localhost}"
ALERT_EMAIL_TO="${ALERT_EMAIL_TO:-admin@example.com}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-admin}"

PROM_VERSION="2.50.1"
ALERTMANAGER_VERSION="0.26.0"
NODE_EXPORTER_VERSION="1.7.0"

function ensure_package() {
  if ! dpkg -s "$1" >/dev/null 2>&1; then
    echo "Installing package: $1"
    sudo apt-get install -y "$1"
  fi
}

function install_system_packages() {
  sudo apt-get update -y
  sudo apt-get install -y \
    git curl wget unzip rsync gnupg apt-transport-https software-properties-common ca-certificates lsb-release build-essential \
    nginx postgresql postgresql-contrib gettext-base
}

function install_nodejs_pm2() {
  if ! command -v node >/dev/null 2>&1; then
    echo "Installing Node.js 20.x"
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
    sudo apt-get install -y nodejs
  fi

  if ! command -v pm2 >/dev/null 2>&1; then
    echo "Installing PM2"
    sudo npm install -g pm2
  fi
}

function setup_postgres() {
  sudo systemctl enable --now postgresql

  if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1; then
    echo "Creating PostgreSQL user ${DB_USER}"
    sudo -u postgres psql -c "CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASSWORD}';"
  fi

  if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1; then
    echo "Creating PostgreSQL database ${DB_NAME}"
    sudo -u postgres psql -c "CREATE DATABASE ${DB_NAME};"
    sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};"
  fi
}

function run_migrations() {
  echo "Applying database migrations"
  cd "${BACKEND_SRC}"
  
  # Grant necessary privileges to the database user on the public schema
  sudo -u postgres psql -d "${DB_NAME}" <<EOF
-- Ensure public schema exists
CREATE SCHEMA IF NOT EXISTS public;

-- Grant permissions on public schema to the application user
GRANT USAGE ON SCHEMA public TO ${DB_USER};
GRANT CREATE ON SCHEMA public TO ${DB_USER};

-- Set default privileges so all future objects are accessible to the user
ALTER DEFAULT PRIVILEGES FOR USER postgres IN SCHEMA public GRANT ALL ON TABLES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES FOR USER postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES FOR USER postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO ${DB_USER};
EOF

  if ! sudo -u postgres psql -d "${DB_NAME}" -tAc "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'measurements'" | grep -q 1; then
    sudo -u postgres psql -d "${DB_NAME}" -f migrations/001_create_measurements.sql
  fi

  if ! sudo -u postgres psql -d "${DB_NAME}" -tAc "SELECT column_name FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'measurements' AND column_name = 'measurement_date'" | grep -q measurement_date; then
    sudo -u postgres psql -d "${DB_NAME}" -f migrations/002_add_measurement_date.sql
  fi
}

function deploy_backend() {
  echo "Deploying backend"
  sudo mkdir -p "${APP_ROOT}/backend"

  cd "${BACKEND_SRC}"
  npm install --production
  sudo rsync -a --delete --exclude 'node_modules' --exclude '.env' ./ "${APP_ROOT}/backend/"

  cat > /tmp/bmi-backend.env <<EOF
DATABASE_URL=postgresql://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
DB_NAME=${DB_NAME}
DB_HOST=${DB_HOST}
DB_PORT=${DB_PORT}
PORT=3000
NODE_ENV=production
FRONTEND_URL=${FRONTEND_URL}
EOF
  sudo mv /tmp/bmi-backend.env "${APP_ROOT}/backend/.env"
  sudo chmod 600 "${APP_ROOT}/backend/.env"
}

function configure_nginx() {
  echo "Configuring Nginx for frontend and API proxy"
  sudo mkdir -p /var/www/bmi-health-tracker

  cat > /tmp/bmi-health-tracker.conf <<'EOF'
server {
  listen 80;
  server_name _;
  root /var/www/bmi-health-tracker;
  index index.html;

  location / {
    try_files $uri $uri/ /index.html;
  }

  location /api/ {
    proxy_pass http://127.0.0.1:3000;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection 'upgrade';
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_cache_bypass $http_upgrade;
  }
}
EOF

  sudo mv /tmp/bmi-health-tracker.conf /etc/nginx/sites-available/bmi-health-tracker.conf
  sudo ln -sf /etc/nginx/sites-available/bmi-health-tracker.conf /etc/nginx/sites-enabled/bmi-health-tracker.conf
  sudo rm -f /etc/nginx/sites-enabled/default
  sudo nginx -t
  sudo systemctl enable --now nginx
  sudo systemctl reload nginx
}

function deploy_frontend() {
  echo "Building frontend"
  cd "${FRONTEND_SRC}"
  npm install
  npm run build

  sudo mkdir -p /var/www/bmi-health-tracker
  sudo rm -rf /var/www/bmi-health-tracker/*
  sudo cp -r dist/* /var/www/bmi-health-tracker/
  sudo chown -R www-data:www-data /var/www/bmi-health-tracker
}

function start_backend_process() {
  echo "Starting backend with PM2"
  cd "${APP_ROOT}/backend"
  if pm2 describe bmi-backend >/dev/null 2>&1; then
    pm2 restart bmi-backend
  else
    pm2 start src/server.js --name bmi-backend --env production
  fi
  pm2 save
  sudo env PATH=$PATH:$(which node) $(which pm2) startup systemd -u $USER --hp $HOME
  pm2 save
}

function install_prometheus() {
  if [ ! -x /usr/local/bin/prometheus ]; then
    echo "Installing Prometheus ${PROM_VERSION}"
    if ! curl -fsSL -o /tmp/prometheus.tar.gz https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/prometheus-${PROM_VERSION}.linux-amd64.tar.gz; then
      echo "Error: Failed to download Prometheus. Please verify version ${PROM_VERSION} exists."
      return 1
    fi
    tar -xzf /tmp/prometheus.tar.gz -C /tmp
    sudo cp /tmp/prometheus-${PROM_VERSION}.linux-amd64/prometheus /usr/local/bin/
    sudo cp /tmp/prometheus-${PROM_VERSION}.linux-amd64/promtool /usr/local/bin/
    sudo mkdir -p /etc/prometheus /var/lib/prometheus
    sudo useradd --system --no-create-home --shell /usr/sbin/nologin prometheus || true
    sudo chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus
  fi

  sudo cp "${MONITORING_SRC}/prometheus/prometheus.yml" /etc/prometheus/prometheus.yml
  sudo cp "${MONITORING_SRC}/prometheus/rules.yml" /etc/prometheus/rules.yml
  sudo chown prometheus:prometheus /etc/prometheus/prometheus.yml /etc/prometheus/rules.yml
}

function install_alertmanager() {
  if [ ! -x /usr/local/bin/alertmanager ]; then
    echo "Installing Alertmanager ${ALERTMANAGER_VERSION}"
    if ! curl -fsSL -o /tmp/alertmanager.tar.gz https://github.com/prometheus/alertmanager/releases/download/v${ALERTMANAGER_VERSION}/alertmanager-${ALERTMANAGER_VERSION}.linux-amd64.tar.gz; then
      echo "Error: Failed to download Alertmanager. Please verify version ${ALERTMANAGER_VERSION} exists."
      return 1
    fi
    tar -xzf /tmp/alertmanager.tar.gz -C /tmp
    sudo cp /tmp/alertmanager-${ALERTMANAGER_VERSION}.linux-amd64/alertmanager /usr/local/bin/
    sudo mkdir -p /etc/alertmanager /var/lib/alertmanager
    sudo useradd --system --no-create-home --shell /usr/sbin/nologin alertmanager || true
    sudo chown -R alertmanager:alertmanager /etc/alertmanager /var/lib/alertmanager
  fi

  SMTP_FROM="${SMTP_FROM}"
  cat > /tmp/alertmanager.yml <<EOF
$(envsubst < "${MONITORING_SRC}/alertmanager/alertmanager.tmpl.yml")
EOF
  sudo mv /tmp/alertmanager.yml /etc/alertmanager/alertmanager.yml
  sudo chown alertmanager:alertmanager /etc/alertmanager/alertmanager.yml
}

function install_node_exporter() {
  if [ ! -x /usr/local/bin/node_exporter ]; then
    echo "Installing Node Exporter ${NODE_EXPORTER_VERSION}"
    if ! curl -fsSL -o /tmp/node_exporter.tar.gz https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz; then
      echo "Error: Failed to download Node Exporter. Please verify version ${NODE_EXPORTER_VERSION} exists."
      return 1
    fi
    tar -xzf /tmp/node_exporter.tar.gz -C /tmp
    sudo cp /tmp/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter /usr/local/bin/
    sudo useradd --system --no-create-home --shell /usr/sbin/nologin node_exporter || true
  fi
}

function install_grafana() {
  if ! dpkg -s grafana >/dev/null 2>&1; then
    echo "Installing Grafana"
    sudo curl -fsSL https://packages.grafana.com/gpg.key | sudo apt-key add -
    echo "deb https://packages.grafana.com/oss/deb stable main" | sudo tee /etc/apt/sources.list.d/grafana.list
    sudo apt-get update -y
    sudo apt-get install -y grafana
  fi

  sudo mkdir -p /etc/grafana/provisioning/datasources
  sudo mkdir -p /etc/grafana/provisioning/dashboards
  sudo mkdir -p /var/lib/grafana/dashboards
  sudo cp "${MONITORING_SRC}/grafana/provisioning/datasources/datasource.yml" /etc/grafana/provisioning/datasources/datasource.yml
  sudo cp "${MONITORING_SRC}/grafana/provisioning/dashboards/dashboard.yml" /etc/grafana/provisioning/dashboards/dashboard.yml
  sudo cp "${MONITORING_SRC}/grafana/dashboards/node-exporter-dashboard.json" /var/lib/grafana/dashboards/node-exporter-dashboard.json
  sudo chown -R grafana:grafana /etc/grafana /var/lib/grafana/dashboards

  sudo sed -i 's/^;http_port = 3000/http_port = 3001/' /etc/grafana/grafana.ini || true
  sudo sed -i 's|^;root_url = .*|root_url = http://localhost:3001/|' /etc/grafana/grafana.ini || true
  sudo systemctl enable --now grafana-server
  sudo grafana-cli admin reset-admin-password "${GRAFANA_ADMIN_PASSWORD}" >/dev/null 2>&1 || true
}

function install_systemd_services() {
  echo "Creating systemd services"
  sudo cp "${MONITORING_SRC}/systemd/prometheus.service" /etc/systemd/system/prometheus.service
  sudo cp "${MONITORING_SRC}/systemd/alertmanager.service" /etc/systemd/system/alertmanager.service
  sudo cp "${MONITORING_SRC}/systemd/node_exporter.service" /etc/systemd/system/node_exporter.service

  sudo systemctl daemon-reload
  sudo systemctl enable --now prometheus
  sudo systemctl enable --now alertmanager
  sudo systemctl enable --now node_exporter
}

function create_monitoring_user() {
  if ! id -u prometheus >/dev/null 2>&1; then
    sudo useradd --system --no-create-home --shell /usr/sbin/nologin prometheus
  fi

  if ! id -u alertmanager >/dev/null 2>&1; then
    sudo useradd --system --no-create-home --shell /usr/sbin/nologin alertmanager
  fi

  if ! id -u node_exporter >/dev/null 2>&1; then
    sudo useradd --system --no-create-home --shell /usr/sbin/nologin node_exporter
  fi
}

# Execution steps
install_system_packages
install_nodejs_pm2
setup_postgres
run_migrations
deploy_backend
deploy_frontend
configure_nginx
start_backend_process
install_prometheus
install_alertmanager
install_node_exporter
install_grafana
create_monitoring_user
install_systemd_services

# Get EC2 public IP
EC2_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 || echo "EC2_HOST")

cat <<EOF
Deployment completed.
- Frontend served from http://${EC2_IP}/
- Backend API available from http://${EC2_IP}/api
- Prometheus available at http://${EC2_IP}:9090
- Grafana available at http://${EC2_IP}:3001
- Alertmanager available at http://${EC2_IP}:9093
EOF
