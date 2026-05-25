# Application Deploy with Monitoring GitHub Action

A full-stack BMI and health tracking application with an end-to-end AWS EC2 deployment pipeline and an observability stack.

The repository contains:
- a React + Vite frontend
- a Node.js + Express backend
- PostgreSQL migrations
- GitHub Actions deployment workflow
- monitoring configuration for Prometheus, Grafana, Alertmanager, and Node Exporter
- an EC2 deployment script that installs and configures the app and monitoring stack

## 📋 Table of Contents

- [Features](#features)
- [Architecture](#architecture)
- [Repository Structure](#repository-structure)
- [Prerequisites](#prerequisites)
- [Local Setup](#local-setup)
- [API Endpoints](#api-endpoints)
- [Monitoring & Deployment](#monitoring--deployment)
- [Run Commands](#run-commands)
- [Notes](#notes)

## ✨ Features

- Track user health measurements including weight, height, age, sex, and activity level
- Calculate BMI, BMI category, BMR, and daily calorie needs
- Store historical health measurements in PostgreSQL
- Display recent measurements and 30-day BMI trend charts
- Full observability with Prometheus, Grafana, Alertmanager, and Node Exporter
- AWS EC2 deployment via GitHub Actions

## 🏗️ Architecture

```
Frontend (React + Vite)
    ↕
Backend (Node.js + Express)
    ↕
PostgreSQL database
```

The frontend runs on `localhost:5173` in development and proxies `/api` requests to the backend at `localhost:3000`.

A remote deployment workflow syncs the repository to an EC2 host and runs `scripts/deploy-ec2.sh`, which installs:
- PostgreSQL
- Node.js + PM2
- Nginx
- Prometheus
- Alertmanager
- Grafana
- Node Exporter

## 📁 Repository Structure

```
application-deploy-with-monitoring-github-action/
├── .github/workflows/           # GitHub Actions deployment workflow
│   └── deploy.yml
├── backend/                     # Express API server
│   ├── migrations/              # PostgreSQL migration scripts
│   │   ├── 001_create_measurements.sql
│   │   └── 002_add_measurement_date.sql
│   ├── src/
│   │   ├── calculations.js
│   │   ├── db.js
│   │   ├── routes.js
│   │   └── server.js
│   ├── ecosystem.config.js
│   └── package.json
├── database/                    # Local database setup helper script
│   └── setup-database.sh
├── frontend/                    # React + Vite frontend
│   ├── src/
│   │   ├── api.js
│   │   ├── App.jsx
│   │   ├── main.jsx
│   │   ├── index.css
│   │   └── components/
│   │       ├── MeasurementForm.jsx
│   │       └── TrendChart.jsx
│   ├── index.html
│   ├── vite.config.js
│   └── package.json
├── monitoring/                  # Observability configuration
│   ├── alertmanager/
│   ├── grafana/
│   ├── prometheus/
│   └── systemd/
├── scripts/                     # EC2 deployment script
│   └── deploy-ec2.sh
└── README.md
```

## 🔧 Prerequisites

- Node.js and npm
- PostgreSQL
- Linux shell access for deployment scripts
- AWS EC2 instance for GitHub Actions-driven remote deployment
- GitHub repository secrets for EC2 deployment

## 🚀 Local Setup

### 1. Clone the repository

```bash
git clone <repository-url>
cd application-deploy-with-monitoring-github-action
```

### 2. Install dependencies

Backend:

```bash
cd backend
npm install
```

Frontend:

```bash
cd ../frontend
npm install
```

### 3. Create and migrate the database

Option A: Use the included setup helper script

```bash
cd ../database
sudo chmod +x setup-database.sh
sudo ./setup-database.sh
```

Option B: Run migrations manually

```sql
CREATE USER bmi_user WITH PASSWORD 'your_password';
CREATE DATABASE bmidb OWNER bmi_user;
```

Then apply `backend/migrations/001_create_measurements.sql` and `backend/migrations/002_add_measurement_date.sql` against `bmidb`.

### 4. Configure the backend

Create `backend/.env` with:

```env
DATABASE_URL=postgresql://bmi_user:your_password@localhost:5432/bmidb
PORT=3000
NODE_ENV=development
FRONTEND_URL=http://localhost:5173
```

### 5. Run the backend

```bash
cd backend
npm run dev
```

### 6. Run the frontend

```bash
cd ../frontend
npm run dev
```

Visit `http://localhost:5173` to use the app.

## 🔌 API Endpoints

### POST `/api/measurements`

Create a new health measurement.

Request body:

```json
{
  "weightKg": 75.5,
  "heightCm": 180,
  "age": 30,
  "sex": "male",
  "activity": "moderate",
  "measurementDate": "2026-05-20"
}
```

### GET `/api/measurements`

Retrieve all stored measurements.

### GET `/api/measurements/trends`

Retrieve 30-day BMI trend data.

### GET `/health`

Health check endpoint.

## 📡 Monitoring & Deployment

### GitHub Actions deployment

Workflow: `.github/workflows/deploy.yml`

The workflow:
- checks out the repository
- sets up Node.js
- installs backend and frontend dependencies
- builds the frontend
- syncs code to the remote EC2 host
- runs `scripts/deploy-ec2.sh` remotely

### Required GitHub Secrets

- `AWS_EC2_HOST`
- `AWS_EC2_USER`
- `AWS_EC2_SSH_KEY`
- `DB_PASSWORD`
- `SMTP_HOST`
- `SMTP_PORT`
- `SMTP_USER`
- `SMTP_PASSWORD`
- `SMTP_FROM`
- `ALERT_EMAIL_TO`
- `GRAFANA_ADMIN_PASSWORD`

### Remote deployment script

The EC2 deployment script installs and configures:
- PostgreSQL
- Node.js and PM2
- Nginx
- Prometheus
- Alertmanager
- Grafana
- Node Exporter

It also applies backend database migrations and starts the backend service under PM2.

## ⚙️ Run Commands

Backend development:

```bash
cd backend
npm run dev
```

Frontend development:

```bash
cd frontend
npm run dev
```

Build frontend:

```bash
cd frontend
npm run build
```

Preview production frontend locally:

```bash
cd frontend
npm run preview
```

## 🧪 Notes

- The frontend uses Vite proxy settings to forward `/api` calls to `http://localhost:3000`.
- The backend allows CORS from `http://localhost:5173` in development.
- The repo is designed for combined application deployment and monitoring on a Linux EC2 host.
