# Cluster Manager - Project Context

## Overview

Build a cross-platform (Ubuntu 24.04 + macOS) web application to manage EKS and GKE clusters across shared accounts.

## Core Features

1. **Dashboard** - List all EKS and GKE clusters with status
2. **Scale Down** - Scale node groups/pools to 0 (save previous config)
3. **Scale Up** - Restore to previous node count
4. **Delete** - Remove cluster with double confirmation

## Technical Stack

- **Backend**: Python 3.12 + Flask
- **Frontend**: HTML (single template, no framework)
- **Config**: YAML file
- **Auth**: AWS CLI credentials + GCP Application Default Credentials (ADC)

## Configuration

`config.yaml` structure:
```yaml
aws:
  regions:
    - eu-central-1

gcp:
  project: field-engineering-eu
  locations:
    - europe-west2      # regional
    - europe-west3-a    # zonal

# Auto-populated by app when scaling down
saved_state:
  eks:
    cluster-name:
      nodegroup-name: 3
  gke:
    cluster-name:
      pool-name: 2
```

## Environment Details

- Python 3.12.3 at `/usr/bin/python3`
- AWS CLI at `/usr/local/bin/aws`
- gcloud at `/snap/bin/gcloud`
- GCP ADC configured at `~/.config/gcloud/application_default_credentials.json`

## Cluster Context

Shared accounts with multiple users. Clusters may have different naming conventions. Show all clusters - user identifies their own.

**Current GKE clusters:**
- `cluster-1aotp` (europe-west2, regional)
- `mgmtaotp` (europe-west2, regional)
- `ambient-demo` (europe-west3-a, zonal)
- `lutz-waypoint-test` (europe-west3-a, zonal)

## API Libraries

- `boto3` - AWS EKS operations
- `google-cloud-container` - GKE operations

## Key Operations

### EKS
- List clusters: `eks.list_clusters()`
- Describe: `eks.describe_cluster(name=cluster_name)`
- List node groups: `eks.list_nodegroups(clusterName=cluster_name)`
- Scale: `eks.update_nodegroup_config(clusterName, nodegroupName, scalingConfig={minSize, maxSize, desiredSize})`
- Delete: `eks.delete_cluster(name=cluster_name)` (must delete node groups first)

### GKE
- List clusters: `cluster_manager.list_clusters(parent=f"projects/{project}/locations/{location}")`
- Get node pools: cluster object contains `node_pools`
- Scale: `cluster_manager.set_node_pool_size(name=node_pool_path, node_count=N)`
- Delete: `cluster_manager.delete_cluster(name=cluster_path)`

## UI Requirements

- Simple, functional dashboard
- Cluster cards showing: name, provider, location, status, node count
- Action buttons: Scale Down, Scale Up, Delete
- Delete requires double confirmation (click → confirm dialog → confirm again)
- Visual distinction between EKS and GKE clusters
- Show loading states during operations

## File Structure

```
cluster-manager/
├── config.yaml
├── app.py
├── templates/
│   └── index.html
├── requirements.txt
└── CLAUDE.md
```
