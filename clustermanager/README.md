# Cluster Manager

Manage EKS and GKE clusters across shared accounts.

## Setup

```bash
# Create virtual environment
python3 -m venv .venv
source .venv/bin/activate

# Install dependencies
pip install -r requirements.txt

# Configure
cp config.yaml.example config.yaml
# Edit config.yaml with your AWS regions and GCP project/locations
```

## Requirements

- AWS CLI configured (`aws configure`)
- GCP Application Default Credentials (`gcloud auth application-default login`)

## Usage

```bash
# Run as native desktop application
python3 app.py

# Run in browser instead
python3 app.py --browser

# Run with debug logging
python3 app.py --debug

# Custom port
python3 app.py --port 8080
```

## Features

- List EKS and GKE clusters
- Scale down (to 0 nodes) - saves previous state
- Scale up (restore previous node count)
- Delete clusters (requires double confirmation)
