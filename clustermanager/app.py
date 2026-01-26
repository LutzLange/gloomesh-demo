#!/usr/bin/env python3
"""Cluster Manager - Manage EKS and GKE clusters across shared accounts."""

import argparse
import getpass
import logging
import subprocess
import threading
import uuid
from pathlib import Path
from datetime import datetime

import boto3
import webview
import yaml
from flask import Flask, jsonify, render_template, request
from google.cloud import container_v1
from google.oauth2 import service_account

app = Flask(__name__)

CONFIG_PATH = Path(__file__).parent / "config.yaml"
config: dict = {}

# Track long-running operations (delete, etc.)
operations: dict = {}


def load_config() -> dict:
    """Load configuration from YAML file."""
    global config
    with open(CONFIG_PATH) as f:
        config = yaml.safe_load(f)
    if "saved_state" not in config:
        config["saved_state"] = {"eks": {}, "gke": {}}
    return config


def save_config() -> None:
    """Save configuration back to YAML file."""
    with open(CONFIG_PATH, "w") as f:
        yaml.dump(config, f, default_flow_style=False)


def get_boto_session() -> boto3.Session:
    """Create boto3 session with optional profile from config."""
    profile = config.get("aws", {}).get("profile")
    return boto3.Session(profile_name=profile) if profile else boto3.Session()


def get_gke_client() -> container_v1.ClusterManagerClient:
    """Create GKE client with optional service account credentials."""
    creds_file = config.get("gcp", {}).get("credentials_file")
    if creds_file:
        creds_path = Path(creds_file).expanduser()
        credentials = service_account.Credentials.from_service_account_file(creds_path)
        return container_v1.ClusterManagerClient(credentials=credentials)
    return container_v1.ClusterManagerClient()


def get_cloudformation_stacks(session: boto3.Session, region: str) -> dict[str, dict]:
    """Fetch eksctl-related CloudFormation stacks. Returns dict keyed by cluster name."""
    stacks_by_cluster: dict[str, dict] = {}
    try:
        cfn = session.client("cloudformation", region_name=region)
        paginator = cfn.get_paginator("list_stacks")
        # Only get stacks that are not fully deleted
        active_statuses = [
            "CREATE_IN_PROGRESS", "CREATE_FAILED", "CREATE_COMPLETE",
            "ROLLBACK_IN_PROGRESS", "ROLLBACK_FAILED", "ROLLBACK_COMPLETE",
            "DELETE_IN_PROGRESS", "DELETE_FAILED",
            "UPDATE_IN_PROGRESS", "UPDATE_COMPLETE_CLEANUP_IN_PROGRESS",
            "UPDATE_COMPLETE", "UPDATE_FAILED", "UPDATE_ROLLBACK_IN_PROGRESS",
            "UPDATE_ROLLBACK_FAILED", "UPDATE_ROLLBACK_COMPLETE_CLEANUP_IN_PROGRESS",
            "UPDATE_ROLLBACK_COMPLETE"
        ]
        for page in paginator.paginate(StackStatusFilter=active_statuses):
            for stack in page.get("StackSummaries", []):
                stack_name = stack["StackName"]
                # Match eksctl stack naming: eksctl-{cluster}-cluster, eksctl-{cluster}-nodegroup-*
                if stack_name.startswith("eksctl-"):
                    parts = stack_name.split("-")
                    if len(parts) >= 3:
                        # Extract cluster name (between "eksctl-" and "-cluster" or "-nodegroup" or "-addon")
                        if "-cluster" in stack_name:
                            cluster_name = stack_name.replace("eksctl-", "").replace("-cluster", "")
                        elif "-nodegroup-" in stack_name:
                            cluster_name = stack_name.split("-nodegroup-")[0].replace("eksctl-", "")
                        elif "-addon-" in stack_name:
                            cluster_name = stack_name.split("-addon-")[0].replace("eksctl-", "")
                        elif "-podidentityrole-" in stack_name:
                            cluster_name = stack_name.split("-podidentityrole-")[0].replace("eksctl-", "")
                        else:
                            continue

                        if cluster_name not in stacks_by_cluster:
                            stacks_by_cluster[cluster_name] = {
                                "cluster_name": cluster_name,
                                "region": region,
                                "stacks": [],
                                "has_failed": False,
                                "has_in_progress": False,
                                "owner": "",
                                "created_at": None,
                            }

                        stack_info = {
                            "name": stack_name,
                            "status": stack["StackStatus"],
                            "reason": stack.get("StackStatusReason", ""),
                        }
                        stacks_by_cluster[cluster_name]["stacks"].append(stack_info)

                        if "FAILED" in stack["StackStatus"]:
                            stacks_by_cluster[cluster_name]["has_failed"] = True
                        if "IN_PROGRESS" in stack["StackStatus"]:
                            stacks_by_cluster[cluster_name]["has_in_progress"] = True

                        # Get owner and creation time from the main cluster stack
                        if stack_name.endswith("-cluster"):
                            try:
                                stack_details = cfn.describe_stacks(StackName=stack_name)["Stacks"][0]
                                # Get creation time
                                creation_time = stack_details.get("CreationTime")
                                if creation_time:
                                    stacks_by_cluster[cluster_name]["created_at"] = creation_time.isoformat()
                                # Get owner tag
                                if not stacks_by_cluster[cluster_name]["owner"]:
                                    for tag in stack_details.get("Tags", []):
                                        if tag["Key"] == "owner":
                                            stacks_by_cluster[cluster_name]["owner"] = tag["Value"]
                                            break
                            except Exception:
                                pass

    except Exception as e:
        logging.error(f"Error listing CloudFormation stacks in {region}: {e}")
    return stacks_by_cluster


def get_enabled_aws_regions(session: boto3.Session) -> list[str]:
    """Get list of enabled AWS regions for the account."""
    try:
        ec2 = session.client("ec2", region_name="us-east-1")
        regions = ec2.describe_regions(
            Filters=[{"Name": "opt-in-status", "Values": ["opt-in-not-required", "opted-in"]}]
        )
        return [r["RegionName"] for r in regions["Regions"]]
    except Exception as e:
        logging.error(f"Error getting AWS regions: {e}")
        return []


def get_eks_clusters() -> tuple[list[dict], list[dict]]:
    """Fetch all EKS clusters and orphaned CF stacks from all enabled AWS regions."""
    clusters = []
    orphaned_stacks = []
    session = get_boto_session()

    # Use configured regions if specified, otherwise auto-discover all enabled regions
    configured_regions = config.get("aws", {}).get("regions", [])
    if configured_regions:
        regions = configured_regions
    else:
        regions = get_enabled_aws_regions(session)
        logging.info(f"Auto-discovered {len(regions)} AWS regions")

    for region in regions:
        # Get CloudFormation stacks first
        cf_stacks = get_cloudformation_stacks(session, region)
        eks_cluster_names = set()

        try:
            eks = session.client("eks", region_name=region)
            cluster_names = eks.list_clusters().get("clusters", [])
            eks_cluster_names = set(cluster_names)

            for name in cluster_names:
                try:
                    desc = eks.describe_cluster(name=name)["cluster"]
                    nodegroups = eks.list_nodegroups(clusterName=name).get(
                        "nodegroups", []
                    )
                    node_info = []
                    total_nodes = 0
                    for ng_name in nodegroups:
                        ng = eks.describe_nodegroup(clusterName=name, nodegroupName=ng_name)["nodegroup"]
                        desired = ng["scalingConfig"]["desiredSize"]
                        total_nodes += desired
                        node_info.append({
                            "name": ng_name,
                            "desired": desired,
                            "min": ng["scalingConfig"]["minSize"],
                            "max": ng["scalingConfig"]["maxSize"],
                        })
                    tags = desc.get("tags", {})
                    created_at = desc.get("createdAt")
                    created_at_iso = created_at.isoformat() if created_at else None

                    # Add CloudFormation stack info if available
                    cf_info = cf_stacks.get(name)
                    cluster_data = {
                        "provider": "eks",
                        "name": name,
                        "region": region,
                        "status": desc.get("status", "UNKNOWN"),
                        "node_count": total_nodes,
                        "node_groups": node_info,
                        "owner": tags.get("owner", ""),
                        "created_at": created_at_iso,
                    }
                    if cf_info:
                        cluster_data["cf_stacks"] = cf_info["stacks"]
                        cluster_data["cf_has_failed"] = cf_info["has_failed"]
                        cluster_data["cf_has_in_progress"] = cf_info["has_in_progress"]

                    clusters.append(cluster_data)
                except Exception as e:
                    logging.error(f"Error describing EKS cluster {name}: {e}")
        except Exception as e:
            logging.error(f"Error listing EKS clusters in {region}: {e}")

        # Find orphaned CF stacks (no matching EKS cluster)
        for cluster_name, cf_info in cf_stacks.items():
            if cluster_name not in eks_cluster_names:
                orphaned_stacks.append({
                    "provider": "cloudformation",
                    "name": cluster_name,
                    "region": region,
                    "status": "ORPHANED",
                    "cf_stacks": cf_info["stacks"],
                    "cf_has_failed": cf_info["has_failed"],
                    "cf_has_in_progress": cf_info["has_in_progress"],
                    "node_count": 0,
                    "node_groups": [],
                    "owner": cf_info.get("owner", ""),
                    "created_at": cf_info.get("created_at"),
                })

    return clusters, orphaned_stacks


def get_gke_clusters() -> list[dict]:
    """Fetch all GKE clusters from configured GCP project."""
    clusters = []
    gcp_config = config.get("gcp", {})
    project = gcp_config.get("project")
    if not project:
        return clusters

    try:
        client = get_gke_client()
        # Use "-" as location to list clusters in ALL locations at once
        parent = f"projects/{project}/locations/-"
        try:
            response = client.list_clusters(parent=parent)
            for cluster in response.clusters:
                total_nodes = 0
                pool_info = []
                for pool in cluster.node_pools:
                    node_count = pool.initial_node_count
                    if pool.autoscaling and pool.autoscaling.enabled:
                        node_count = pool.autoscaling.min_node_count
                    total_nodes += node_count
                    pool_info.append({
                        "name": pool.name,
                        "node_count": node_count,
                    })
                labels = dict(cluster.resource_labels) if cluster.resource_labels else {}
                # GKE returns createTime as a string like "2024-01-15T10:30:00+00:00"
                created_at = cluster.create_time if hasattr(cluster, 'create_time') else None
                # Extract location from cluster's self_link or location field
                location = cluster.location if hasattr(cluster, 'location') else cluster.zone
                clusters.append({
                    "provider": "gke",
                    "name": cluster.name,
                    "location": location,
                    "status": container_v1.Cluster.Status(cluster.status).name,
                    "node_count": total_nodes,
                    "node_pools": pool_info,
                    "owner": labels.get("owner", ""),
                    "created_at": created_at,
                })
        except Exception as e:
            logging.error(f"Error listing GKE clusters: {e}")
    except Exception as e:
        logging.error(f"Error initializing GKE client: {e}")
    return clusters


@app.route("/")
def index() -> str:
    return render_template("index.html", default_owner=getpass.getuser())


@app.route("/api/clusters")
def list_clusters() -> tuple:
    try:
        eks_clusters, orphaned_stacks = get_eks_clusters()
        gke_clusters = get_gke_clusters()
        return jsonify({
            "success": True,
            "data": eks_clusters + gke_clusters + orphaned_stacks,
            "current_user": getpass.getuser(),
        })
    except Exception as e:
        logging.error(f"Error listing clusters: {e}")
        return jsonify({"success": False, "error": str(e)}), 500


@app.route("/api/config/reload", methods=["POST"])
def reload_config() -> tuple:
    try:
        load_config()
        return jsonify({"success": True, "data": "Config reloaded"})
    except Exception as e:
        logging.error(f"Error reloading config: {e}")
        return jsonify({"success": False, "error": str(e)}), 500


@app.route("/api/eks/<region>/<cluster_name>/set-owner", methods=["POST"])
def set_eks_owner(region: str, cluster_name: str) -> tuple:
    """Set the owner tag on an EKS cluster."""
    owner = request.json.get("owner", "").strip()
    if not owner:
        return jsonify({"success": False, "error": "Owner cannot be empty"}), 400

    try:
        session = get_boto_session()
        eks = session.client("eks", region_name=region)

        # Get cluster ARN
        cluster = eks.describe_cluster(name=cluster_name)["cluster"]
        cluster_arn = cluster["arn"]

        # Tag the cluster
        eks.tag_resource(resourceArn=cluster_arn, tags={"owner": owner})
        logging.info(f"Set owner '{owner}' on EKS cluster {cluster_name}")

        return jsonify({"success": True, "data": f"Owner set to '{owner}'"})
    except Exception as e:
        logging.error(f"Error setting owner on EKS cluster {cluster_name}: {e}")
        return jsonify({"success": False, "error": str(e)}), 500


@app.route("/api/gke/<location>/<cluster_name>/set-owner", methods=["POST"])
def set_gke_owner(location: str, cluster_name: str) -> tuple:
    """Set the owner label on a GKE cluster."""
    owner = request.json.get("owner", "").strip()
    if not owner:
        return jsonify({"success": False, "error": "Owner cannot be empty"}), 400

    # GKE labels must be lowercase and can only contain lowercase letters, numbers, underscores, and hyphens
    owner_label = owner.lower().replace("@", "-").replace(".", "-")

    try:
        project = config["gcp"]["project"]
        client = get_gke_client()
        cluster_path = f"projects/{project}/locations/{location}/clusters/{cluster_name}"

        # Get current cluster to preserve existing labels
        cluster = client.get_cluster(name=cluster_path)
        labels = dict(cluster.resource_labels) if cluster.resource_labels else {}
        labels["owner"] = owner_label

        # Update labels
        update = container_v1.SetLabelsRequest(
            name=cluster_path,
            resource_labels=labels,
            label_fingerprint=cluster.label_fingerprint,
        )
        client.set_labels(request=update)
        logging.info(f"Set owner '{owner_label}' on GKE cluster {cluster_name}")

        return jsonify({"success": True, "data": f"Owner set to '{owner_label}'"})
    except Exception as e:
        logging.error(f"Error setting owner on GKE cluster {cluster_name}: {e}")
        return jsonify({"success": False, "error": str(e)}), 500


@app.route("/api/eks/<region>/<cluster_name>/scale-down", methods=["POST"])
def scale_down_eks(region: str, cluster_name: str) -> tuple:
    try:
        eks = get_boto_session().client("eks", region_name=region)
        nodegroups = eks.list_nodegroups(clusterName=cluster_name).get("nodegroups", [])

        if cluster_name not in config["saved_state"]["eks"]:
            config["saved_state"]["eks"][cluster_name] = {}

        for ng_name in nodegroups:
            ng = eks.describe_nodegroup(clusterName=cluster_name, nodegroupName=ng_name)["nodegroup"]
            current_desired = ng["scalingConfig"]["desiredSize"]

            # Only save state if current count > 0 (don't overwrite with 0)
            if current_desired > 0:
                config["saved_state"]["eks"][cluster_name][ng_name] = current_desired
                logging.info(f"Saving EKS state: {cluster_name}/{ng_name} = {current_desired}")
            else:
                logging.info(f"Skipping save for {cluster_name}/{ng_name} (already at 0)")

            eks.update_nodegroup_config(
                clusterName=cluster_name,
                nodegroupName=ng_name,
                scalingConfig={"minSize": 0, "maxSize": ng["scalingConfig"]["maxSize"], "desiredSize": 0},
            )
            logging.info(f"Scaled down EKS nodegroup: {cluster_name}/{ng_name}")

        save_config()
        return jsonify({"success": True, "data": f"Scaled down {len(nodegroups)} nodegroups"})
    except Exception as e:
        logging.error(f"Error scaling down EKS cluster {cluster_name}: {e}")
        return jsonify({"success": False, "error": str(e)}), 500


@app.route("/api/eks/<region>/<cluster_name>/scale-up", methods=["POST"])
def scale_up_eks(region: str, cluster_name: str) -> tuple:
    try:
        saved = config.get("saved_state", {}).get("eks", {}).get(cluster_name, {})
        if not saved:
            return jsonify({"success": False, "error": "No saved state found for this cluster"}), 400

        eks = get_boto_session().client("eks", region_name=region)
        for ng_name, desired in saved.items():
            ng = eks.describe_nodegroup(clusterName=cluster_name, nodegroupName=ng_name)["nodegroup"]
            eks.update_nodegroup_config(
                clusterName=cluster_name,
                nodegroupName=ng_name,
                scalingConfig={"minSize": desired, "maxSize": ng["scalingConfig"]["maxSize"], "desiredSize": desired},
            )
            logging.info(f"Scaled up EKS nodegroup: {cluster_name}/{ng_name} to {desired}")

        return jsonify({"success": True, "data": f"Scaled up {len(saved)} nodegroups"})
    except Exception as e:
        logging.error(f"Error scaling up EKS cluster {cluster_name}: {e}")
        return jsonify({"success": False, "error": str(e)}), 500


def run_command(cmd: list, op: dict, description: str) -> int:
    """Run a command and capture output to operation logs."""
    op["logs"].append(f"\n{'='*60}\n{description}\n{'='*60}\n")
    op["logs"].append(f"$ {' '.join(cmd)}\n")
    logging.info(f"Running: {' '.join(cmd)}")

    try:
        process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        for line in process.stdout:
            op["logs"].append(line)
            logging.debug(f"{cmd[0]}: {line.rstrip()}")
        process.wait()
        return process.returncode
    except Exception as e:
        op["logs"].append(f"Error: {str(e)}\n")
        return -1


def cleanup_vpc_load_balancers(session: boto3.Session, vpc_id: str, region: str, op: dict) -> bool:
    """Delete all load balancers in a VPC. Returns True if any were found."""
    found_lbs = False

    # Delete classic ELBs
    op["logs"].append("  Checking for classic load balancers...\n")
    try:
        elb = session.client("elb", region_name=region)
        lbs = elb.describe_load_balancers().get("LoadBalancerDescriptions", [])
        for lb in lbs:
            if lb.get("VPCId") == vpc_id:
                found_lbs = True
                lb_name = lb["LoadBalancerName"]
                op["logs"].append(f"  Deleting classic ELB: {lb_name}\n")
                try:
                    elb.delete_load_balancer(LoadBalancerName=lb_name)
                except Exception as e:
                    op["logs"].append(f"    Warning: {e}\n")
    except Exception as e:
        op["logs"].append(f"  Warning: Could not check classic ELBs: {e}\n")

    # Delete ALB/NLBs (elbv2)
    op["logs"].append("  Checking for ALB/NLB load balancers...\n")
    try:
        elbv2 = session.client("elbv2", region_name=region)
        lbs = elbv2.describe_load_balancers().get("LoadBalancers", [])
        for lb in lbs:
            if lb.get("VpcId") == vpc_id:
                found_lbs = True
                lb_arn = lb["LoadBalancerArn"]
                lb_name = lb["LoadBalancerName"]
                op["logs"].append(f"  Deleting {lb['Type']} load balancer: {lb_name}\n")
                try:
                    elbv2.delete_load_balancer(LoadBalancerArn=lb_arn)
                except Exception as e:
                    op["logs"].append(f"    Warning: {e}\n")
    except Exception as e:
        op["logs"].append(f"  Warning: Could not check ALB/NLBs: {e}\n")

    return found_lbs


def cleanup_vpc_security_groups(session: boto3.Session, vpc_id: str, region: str, op: dict, cluster_name: str = None) -> None:
    """Delete all non-default security groups in a VPC."""
    ec2 = session.client("ec2", region_name=region)

    op["logs"].append("  Finding security groups in VPC...\n")
    try:
        sgs = ec2.describe_security_groups(
            Filters=[{"Name": "vpc-id", "Values": [vpc_id]}]
        ).get("SecurityGroups", [])

        # Filter out default security group
        non_default_sgs = [sg for sg in sgs if sg["GroupName"] != "default"]

        # Also look for workshop-created security groups by name pattern (ecs-{cluster}-sg)
        if cluster_name:
            try:
                extra_sgs = ec2.describe_security_groups(
                    Filters=[{"Name": "group-name", "Values": [f"ecs-{cluster_name}-sg"]}]
                ).get("SecurityGroups", [])
                for sg in extra_sgs:
                    if sg not in non_default_sgs:
                        non_default_sgs.append(sg)
                        op["logs"].append(f"  Found workshop SG: {sg['GroupName']} ({sg['GroupId']})\n")
            except Exception:
                pass

        if not non_default_sgs:
            op["logs"].append("  No non-default security groups found\n")
            return

        op["logs"].append(f"  Found {len(non_default_sgs)} security groups to clean up\n")

        # Step 1: Remove all rules first (SGs can reference each other)
        op["logs"].append("  Removing security group rules...\n")
        for sg in non_default_sgs:
            sg_id = sg["GroupId"]
            sg_name = sg["GroupName"]
            try:
                # Refresh SG data to get current rules
                current_sg = ec2.describe_security_groups(GroupIds=[sg_id])["SecurityGroups"][0]
                # Remove ingress rules
                if current_sg.get("IpPermissions"):
                    ec2.revoke_security_group_ingress(
                        GroupId=sg_id,
                        IpPermissions=current_sg["IpPermissions"]
                    )
                    op["logs"].append(f"    Revoked ingress rules for {sg_name}\n")
                # Remove egress rules
                if current_sg.get("IpPermissionsEgress"):
                    ec2.revoke_security_group_egress(
                        GroupId=sg_id,
                        IpPermissions=current_sg["IpPermissionsEgress"]
                    )
                    op["logs"].append(f"    Revoked egress rules for {sg_name}\n")
            except Exception as e:
                op["logs"].append(f"    Warning revoking rules for {sg_id}: {e}\n")

        # Step 2: Delete security groups
        op["logs"].append("  Deleting security groups...\n")
        for sg in non_default_sgs:
            sg_id = sg["GroupId"]
            sg_name = sg["GroupName"]
            try:
                ec2.delete_security_group(GroupId=sg_id)
                op["logs"].append(f"    Deleted SG: {sg_name} ({sg_id})\n")
            except Exception as e:
                op["logs"].append(f"    Warning deleting {sg_id}: {e}\n")

    except Exception as e:
        op["logs"].append(f"  Warning: Could not clean up security groups: {e}\n")


def get_eks_vpc_id(session: boto3.Session, cluster_name: str, region: str, op: dict) -> str | None:
    """Get VPC ID from EKS cluster or CloudFormation stack."""
    # Try to get from EKS cluster
    try:
        eks = session.client("eks", region_name=region)
        cluster = eks.describe_cluster(name=cluster_name)["cluster"]
        vpc_id = cluster.get("resourcesVpcConfig", {}).get("vpcId")
        if vpc_id:
            op["logs"].append(f"  Found VPC from cluster: {vpc_id}\n")
            return vpc_id
    except Exception:
        pass

    # Try to get from CloudFormation stack
    try:
        cfn = session.client("cloudformation", region_name=region)
        stack_name = f"eksctl-{cluster_name}-cluster"
        resources = cfn.describe_stack_resource(
            StackName=stack_name,
            LogicalResourceId="VPC"
        )
        vpc_id = resources["StackResourceDetail"]["PhysicalResourceId"]
        if vpc_id:
            op["logs"].append(f"  Found VPC from CloudFormation: {vpc_id}\n")
            return vpc_id
    except Exception:
        pass

    op["logs"].append("  Warning: Could not determine VPC ID\n")
    return None


def run_eksctl_delete(op_id: str, cluster_name: str, region: str) -> None:
    """Run eksctl delete cluster in background with full cleanup."""
    import time
    op = operations[op_id]
    profile = config.get("aws", {}).get("profile")
    sso_profile = config.get("aws", {}).get("sso_profile", "internal")
    session = get_boto_session()

    # Step 1: Update kubeconfig using SSO profile for k8s access
    kubeconfig_cmd = ["aws", "eks", "update-kubeconfig", "--name", cluster_name, "--region", region, "--profile", sso_profile]
    rc = run_command(kubeconfig_cmd, op, "Step 1: Updating kubeconfig")

    if rc == 0:
        # Step 2: Delete all LoadBalancer services via kubectl
        op["logs"].append(f"\n{'='*60}\nStep 2: Cleaning up LoadBalancer services via kubectl\n{'='*60}\n")

        get_svc_cmd = ["kubectl", "get", "svc", "--all-namespaces", "-o", "jsonpath={range .items[?(@.spec.type=='LoadBalancer')]}{.metadata.namespace}/{.metadata.name} {end}"]
        try:
            result = subprocess.run(get_svc_cmd, capture_output=True, text=True, timeout=30)
            services = result.stdout.strip().split()
            if services and services[0]:
                for svc in services:
                    if "/" in svc:
                        ns, name = svc.split("/", 1)
                        delete_cmd = ["kubectl", "delete", "svc", name, "-n", ns, "--timeout=60s"]
                        run_command(delete_cmd, op, f"Deleting LoadBalancer service {svc}")
            else:
                op["logs"].append("No LoadBalancer services found\n")
        except Exception as e:
            op["logs"].append(f"Warning: Could not list services: {e}\n")

        # Step 3: Delete all Ingresses
        op["logs"].append(f"\n{'='*60}\nStep 3: Cleaning up Ingresses\n{'='*60}\n")
        get_ing_cmd = ["kubectl", "get", "ingress", "--all-namespaces", "-o", "jsonpath={range .items[*]}{.metadata.namespace}/{.metadata.name} {end}"]
        try:
            result = subprocess.run(get_ing_cmd, capture_output=True, text=True, timeout=30)
            ingresses = result.stdout.strip().split()
            if ingresses and ingresses[0]:
                for ing in ingresses:
                    if "/" in ing:
                        ns, name = ing.split("/", 1)
                        delete_cmd = ["kubectl", "delete", "ingress", name, "-n", ns, "--timeout=60s"]
                        run_command(delete_cmd, op, f"Deleting Ingress {ing}")
            else:
                op["logs"].append("No Ingresses found\n")
        except Exception as e:
            op["logs"].append(f"Warning: Could not list ingresses: {e}\n")
    else:
        op["logs"].append(f"\nWarning: Could not update kubeconfig, will proceed with AWS API cleanup\n")

    # Step 4: Get VPC ID for AWS resource cleanup
    op["logs"].append(f"\n{'='*60}\nStep 4: Getting VPC ID for AWS resource cleanup\n{'='*60}\n")
    vpc_id = get_eks_vpc_id(session, cluster_name, region, op)

    if vpc_id:
        # Step 5: Delete load balancers directly via AWS API
        op["logs"].append(f"\n{'='*60}\nStep 5: Deleting load balancers via AWS API\n{'='*60}\n")
        found_lbs = cleanup_vpc_load_balancers(session, vpc_id, region, op)

        if found_lbs:
            # Wait for load balancers to fully delete (releases ENIs and SGs)
            op["logs"].append("  Waiting 60s for load balancers to fully delete...\n")
            time.sleep(60)

        # Step 6: Clean up VPC peering connections
        op["logs"].append(f"\n{'='*60}\nStep 6: Cleaning up VPC peering connections\n{'='*60}\n")
        cleanup_vpc_peering_connections(session, vpc_id, region, op)

        # Step 7: Clean up security groups
        op["logs"].append(f"\n{'='*60}\nStep 7: Cleaning up security groups\n{'='*60}\n")
        cleanup_vpc_security_groups(session, vpc_id, region, op, cluster_name)
    else:
        op["logs"].append("  Skipping AWS resource cleanup (no VPC ID)\n")
        # Still wait a bit for any k8s-triggered cleanup
        op["logs"].append("  Waiting 30s for any kubernetes-triggered cleanup...\n")
        time.sleep(30)

    # Step 8: Run eksctl delete
    eksctl_cmd = ["eksctl", "delete", "cluster", "--name", cluster_name, "--region", region, "--wait", "--force", "--disable-nodegroup-eviction"]
    if profile:
        eksctl_cmd.extend(["--profile", profile])

    rc = run_command(eksctl_cmd, op, "Step 8: Deleting EKS cluster via eksctl")

    if rc == 0:
        op["status"] = "completed"
        op["logs"].append(f"\n✓ Cluster {cluster_name} deleted successfully\n")
    else:
        op["status"] = "failed"
        op["logs"].append(f"\n✗ Deletion failed with exit code {rc}\n")
        op["logs"].append("\nTroubleshooting: Check CloudFormation console for stuck resources.\n")
        op["logs"].append("Common issues: ENIs still attached, security group dependencies.\n")

    op["end_time"] = datetime.now().isoformat()


@app.route("/api/eks/<region>/<cluster_name>/delete", methods=["POST"])
def delete_eks(region: str, cluster_name: str) -> tuple:
    if not request.json.get("confirm"):
        return jsonify({"success": False, "error": "Confirmation required"}), 400

    # Check if cluster was created with eksctl (has eksctl tags)
    try:
        eks = get_boto_session().client("eks", region_name=region)
        desc = eks.describe_cluster(name=cluster_name)["cluster"]
        tags = desc.get("tags", {})
        is_eksctl = "eksctl.cluster.k8s.io/v1alpha1/cluster-name" in tags or "alpha.eksctl.io/cluster-name" in tags
    except Exception as e:
        logging.error(f"Error checking EKS cluster {cluster_name}: {e}")
        return jsonify({"success": False, "error": str(e)}), 500

    if is_eksctl:
        # Use eksctl delete for eksctl-created clusters
        op_id = str(uuid.uuid4())
        operations[op_id] = {
            "id": op_id,
            "type": "delete",
            "provider": "eks",
            "cluster": cluster_name,
            "region": region,
            "status": "running",
            "start_time": datetime.now().isoformat(),
            "logs": [],
        }

        thread = threading.Thread(target=run_eksctl_delete, args=(op_id, cluster_name, region))
        thread.daemon = True
        thread.start()

        return jsonify({
            "success": True,
            "data": f"Deleting eksctl cluster {cluster_name} (this may take several minutes)",
            "operation_id": op_id,
        })
    else:
        # Non-eksctl cluster - use direct API
        try:
            nodegroups = eks.list_nodegroups(clusterName=cluster_name).get("nodegroups", [])
            for ng_name in nodegroups:
                logging.info(f"Deleting EKS nodegroup: {cluster_name}/{ng_name}")
                eks.delete_nodegroup(clusterName=cluster_name, nodegroupName=ng_name)

            if not nodegroups:
                eks.delete_cluster(name=cluster_name)
                logging.info(f"Deleted EKS cluster: {cluster_name}")
                return jsonify({"success": True, "data": "Cluster deletion initiated"})
            else:
                return jsonify({
                    "success": True,
                    "data": f"Deleting {len(nodegroups)} nodegroups. Retry cluster delete after they're gone.",
                })
        except Exception as e:
            logging.error(f"Error deleting EKS cluster {cluster_name}: {e}")
            return jsonify({"success": False, "error": str(e)}), 500


@app.route("/api/operations")
def list_operations() -> tuple:
    """List all running and recent operations."""
    ops_list = []
    for op_id, op in operations.items():
        ops_list.append({
            "id": op["id"],
            "type": op["type"],
            "provider": op["provider"],
            "cluster": op["cluster"],
            "status": op["status"],
            "start_time": op["start_time"],
            "end_time": op.get("end_time"),
        })
    return jsonify({"success": True, "data": ops_list})


@app.route("/api/operations/<op_id>")
def get_operation(op_id: str) -> tuple:
    """Get status and logs for a running operation."""
    if op_id not in operations:
        return jsonify({"success": False, "error": "Operation not found"}), 404

    op = operations[op_id]
    return jsonify({
        "success": True,
        "data": {
            "id": op["id"],
            "type": op["type"],
            "provider": op["provider"],
            "cluster": op["cluster"],
            "status": op["status"],
            "start_time": op["start_time"],
            "end_time": op.get("end_time"),
            "exit_code": op.get("exit_code"),
            "logs": "".join(op["logs"]),
        }
    })


def get_vpc_id_from_cf_stack(session: boto3.Session, stack_name: str, region: str, op: dict) -> str | None:
    """Get VPC ID from a CloudFormation stack."""
    cfn = session.client("cloudformation", region_name=region)

    # Try to get VPC from stack resources
    try:
        resources = cfn.describe_stack_resources(StackName=stack_name)["StackResources"]
        for r in resources:
            if r["ResourceType"] == "AWS::EC2::VPC":
                vpc_id = r["PhysicalResourceId"]
                op["logs"].append(f"  Found VPC from stack resource: {vpc_id}\n")
                return vpc_id
    except Exception as e:
        op["logs"].append(f"  Could not get stack resources: {e}\n")

    # Try to get VPC from stack outputs
    try:
        stack_desc = cfn.describe_stacks(StackName=stack_name)["Stacks"][0]
        for output in stack_desc.get("Outputs", []):
            if "vpc" in output.get("OutputKey", "").lower():
                vpc_id = output["OutputValue"]
                op["logs"].append(f"  Found VPC from stack output: {vpc_id}\n")
                return vpc_id
    except Exception:
        pass

    return None


def run_cf_stack_delete(op_id: str, cluster_name: str, region: str, stacks: list[dict]) -> None:
    """Delete CloudFormation stacks for an orphaned cluster with full cleanup."""
    import time
    op = operations[op_id]
    session = get_boto_session()
    cfn = session.client("cloudformation", region_name=region)

    # Sort stacks: delete nodegroup/addon stacks first, cluster stack last
    cluster_stack = None
    other_stacks = []
    for stack in stacks:
        if stack["name"].endswith("-cluster"):
            cluster_stack = stack
        else:
            other_stacks.append(stack)

    all_stacks = other_stacks + ([cluster_stack] if cluster_stack else [])

    # Step 1: Get VPC ID from the cluster stack for cleanup
    op["logs"].append(f"\n{'='*60}\nStep 1: Finding VPC for resource cleanup\n{'='*60}\n")
    vpc_id = None
    if cluster_stack:
        vpc_id = get_vpc_id_from_cf_stack(session, cluster_stack["name"], region, op)

    # If not found in cluster stack, try other stacks
    if not vpc_id:
        for stack in other_stacks:
            vpc_id = get_vpc_id_from_cf_stack(session, stack["name"], region, op)
            if vpc_id:
                break

    # Step 2: Clean up ECS clusters created by workshops
    op["logs"].append(f"\n{'='*60}\nStep 2: Cleaning up ECS clusters (ecs-{cluster_name}-*)\n{'='*60}\n")
    cleanup_ecs_clusters(session, cluster_name, region, op)

    # Wait for ECS tasks to fully terminate and release ENIs
    op["logs"].append("  Waiting 30s for ECS resources to release...\n")
    time.sleep(30)

    if vpc_id:
        # Step 3: Delete load balancers in the VPC
        op["logs"].append(f"\n{'='*60}\nStep 3: Cleaning up load balancers in VPC {vpc_id}\n{'='*60}\n")
        found_lbs = cleanup_vpc_load_balancers(session, vpc_id, region, op)

        if found_lbs:
            op["logs"].append("  Waiting 60s for load balancers to fully delete...\n")
            time.sleep(60)

        # Step 4: Clean up VPC peering connections
        op["logs"].append(f"\n{'='*60}\nStep 4: Cleaning up VPC peering connections\n{'='*60}\n")
        cleanup_vpc_peering_connections(session, vpc_id, region, op)

        # Step 5: Clean up security groups
        op["logs"].append(f"\n{'='*60}\nStep 5: Cleaning up security groups in VPC {vpc_id}\n{'='*60}\n")
        cleanup_vpc_security_groups(session, vpc_id, region, op, cluster_name)

        # Step 6: Clean up any remaining ENIs
        op["logs"].append(f"\n{'='*60}\nStep 6: Cleaning up network interfaces in VPC {vpc_id}\n{'='*60}\n")
        cleanup_vpc_network_interfaces(session, vpc_id, region, op)
    else:
        op["logs"].append("  No VPC found, skipping resource cleanup\n")

    # Step 7: Delete CloudFormation stacks
    op["logs"].append(f"\n{'='*60}\nStep 7: Deleting CloudFormation stacks\n{'='*60}\n")

    for stack in all_stacks:
        stack_name = stack["name"]
        op["logs"].append(f"\n--- Deleting stack: {stack_name} ---\n")
        op["logs"].append(f"Current status: {stack['status']}\n")

        try:
            cfn.delete_stack(StackName=stack_name)
            op["logs"].append(f"Delete initiated for {stack_name}\n")

            # Wait for deletion
            op["logs"].append("Waiting for stack deletion...\n")
            waiter = cfn.get_waiter("stack_delete_complete")
            try:
                waiter.wait(StackName=stack_name, WaiterConfig={"Delay": 10, "MaxAttempts": 60})
                op["logs"].append(f"✓ Stack {stack_name} deleted successfully\n")
            except Exception as e:
                # Check if it's actually deleted or failed
                try:
                    stack_info = cfn.describe_stacks(StackName=stack_name)["Stacks"][0]
                    status = stack_info["StackStatus"]
                    op["logs"].append(f"✗ Stack {stack_name} deletion failed. Status: {status}\n")
                    if status == "DELETE_FAILED":
                        # Get failed resources
                        resources = cfn.describe_stack_resources(StackName=stack_name)["StackResources"]
                        failed_resources = []
                        for r in resources:
                            if r.get("ResourceStatus") == "DELETE_FAILED":
                                failed_resources.append(r["LogicalResourceId"])
                                op["logs"].append(f"  Failed resource: {r['LogicalResourceId']} - {r.get('ResourceStatusReason', 'Unknown')}\n")

                        # Try cleanup again if VPC-related failure
                        if vpc_id:
                            op["logs"].append("\n  Retrying cleanup after failure...\n")
                            cleanup_vpc_peering_connections(session, vpc_id, region, op)
                            cleanup_vpc_load_balancers(session, vpc_id, region, op)
                            time.sleep(30)
                            cleanup_vpc_security_groups(session, vpc_id, region, op, cluster_name)
                            cleanup_vpc_network_interfaces(session, vpc_id, region, op)

                            # Retry stack deletion
                            op["logs"].append(f"\n  Retrying stack deletion for {stack_name}...\n")
                            cfn.delete_stack(StackName=stack_name)
                            try:
                                waiter.wait(StackName=stack_name, WaiterConfig={"Delay": 10, "MaxAttempts": 30})
                                op["logs"].append(f"✓ Stack {stack_name} deleted on retry\n")
                            except Exception:
                                # Check if failed again - try with retain-resources
                                try:
                                    status2 = cfn.describe_stacks(StackName=stack_name)["Stacks"][0]["StackStatus"]
                                    if status2 == "DELETE_FAILED":
                                        op["logs"].append(f"\n  Stack still failing. Trying with --retain-resources...\n")
                                        # Get current failed resources
                                        resources2 = cfn.describe_stack_resources(StackName=stack_name)["StackResources"]
                                        retain = [r["LogicalResourceId"] for r in resources2 if r.get("ResourceStatus") == "DELETE_FAILED"]
                                        if retain:
                                            op["logs"].append(f"  Retaining: {', '.join(retain)}\n")
                                            cfn.delete_stack(StackName=stack_name, RetainResources=retain)
                                            try:
                                                waiter.wait(StackName=stack_name, WaiterConfig={"Delay": 10, "MaxAttempts": 30})
                                                op["logs"].append(f"✓ Stack {stack_name} deleted with retained resources\n")
                                            except Exception:
                                                op["logs"].append(f"✗ Stack {stack_name} still failed after retain\n")
                                except Exception:
                                    op["logs"].append(f"✓ Stack {stack_name} deleted on retry\n")
                        else:
                            # No VPC - try retain-resources directly
                            if failed_resources:
                                op["logs"].append(f"\n  Trying with --retain-resources for: {', '.join(failed_resources)}\n")
                                cfn.delete_stack(StackName=stack_name, RetainResources=failed_resources)
                                try:
                                    waiter.wait(StackName=stack_name, WaiterConfig={"Delay": 10, "MaxAttempts": 30})
                                    op["logs"].append(f"✓ Stack {stack_name} deleted with retained resources\n")
                                except Exception:
                                    op["logs"].append(f"✗ Stack {stack_name} still failed\n")
                except Exception:
                    # Stack might be deleted
                    op["logs"].append(f"✓ Stack {stack_name} deleted\n")

        except Exception as e:
            op["logs"].append(f"Error: {str(e)}\n")

    op["status"] = "completed"
    op["logs"].append(f"\n✓ Cleanup complete for {cluster_name}\n")
    op["end_time"] = datetime.now().isoformat()


def cleanup_ecs_clusters(session: boto3.Session, cluster_name: str, region: str, op: dict) -> None:
    """Clean up ECS clusters created by workshops (ecs-{cluster_name}-*)."""
    ecs = session.client("ecs", region_name=region)

    # Find ECS clusters matching the pattern
    try:
        cluster_arns = ecs.list_clusters().get("clusterArns", [])
        matching_clusters = []

        for arn in cluster_arns:
            # Extract cluster name from ARN
            ecs_cluster_name = arn.split("/")[-1]
            # Match patterns like ecs-{cluster_name}-1, ecs-{cluster_name}-2, etc.
            if ecs_cluster_name.startswith(f"ecs-{cluster_name}-"):
                matching_clusters.append(ecs_cluster_name)

        if not matching_clusters:
            op["logs"].append("  No matching ECS clusters found\n")
            return

        op["logs"].append(f"  Found {len(matching_clusters)} ECS clusters to clean up\n")

        for ecs_cluster in matching_clusters:
            op["logs"].append(f"\n  --- Cleaning up ECS cluster: {ecs_cluster} ---\n")

            # List and stop all running tasks
            try:
                task_arns = ecs.list_tasks(cluster=ecs_cluster, desiredStatus="RUNNING").get("taskArns", [])
                if task_arns:
                    op["logs"].append(f"    Stopping {len(task_arns)} running tasks...\n")
                    for task_arn in task_arns:
                        try:
                            ecs.stop_task(cluster=ecs_cluster, task=task_arn, reason="Cleanup by cluster-manager")
                        except Exception as e:
                            op["logs"].append(f"    Warning stopping task: {e}\n")
            except Exception as e:
                op["logs"].append(f"    Warning listing tasks: {e}\n")

            # List and delete all services
            try:
                service_arns = ecs.list_services(cluster=ecs_cluster).get("serviceArns", [])
                if service_arns:
                    op["logs"].append(f"    Deleting {len(service_arns)} services...\n")
                    for service_arn in service_arns:
                        service_name = service_arn.split("/")[-1]
                        try:
                            # Scale down to 0 first
                            ecs.update_service(cluster=ecs_cluster, service=service_name, desiredCount=0)
                            # Then delete with force
                            ecs.delete_service(cluster=ecs_cluster, service=service_name, force=True)
                            op["logs"].append(f"    Deleted service: {service_name}\n")
                        except Exception as e:
                            op["logs"].append(f"    Warning deleting service {service_name}: {e}\n")
            except Exception as e:
                op["logs"].append(f"    Warning listing services: {e}\n")

            # Delete the cluster
            try:
                ecs.delete_cluster(cluster=ecs_cluster)
                op["logs"].append(f"    Deleted ECS cluster: {ecs_cluster}\n")
            except Exception as e:
                op["logs"].append(f"    Warning deleting cluster: {e}\n")

    except Exception as e:
        op["logs"].append(f"  Warning: Could not clean up ECS clusters: {e}\n")


def cleanup_vpc_peering_connections(session: boto3.Session, vpc_id: str, region: str, op: dict) -> None:
    """Delete VPC peering connections associated with a VPC."""
    ec2 = session.client("ec2", region_name=region)

    try:
        # Find peerings where this VPC is the requester
        peerings = ec2.describe_vpc_peering_connections(
            Filters=[{"Name": "requester-vpc-info.vpc-id", "Values": [vpc_id]}]
        ).get("VpcPeeringConnections", [])

        # Also find peerings where this VPC is the accepter
        peerings += ec2.describe_vpc_peering_connections(
            Filters=[{"Name": "accepter-vpc-info.vpc-id", "Values": [vpc_id]}]
        ).get("VpcPeeringConnections", [])

        # Deduplicate
        seen = set()
        unique_peerings = []
        for p in peerings:
            if p["VpcPeeringConnectionId"] not in seen:
                seen.add(p["VpcPeeringConnectionId"])
                unique_peerings.append(p)

        if not unique_peerings:
            op["logs"].append("  No VPC peering connections found\n")
            return

        op["logs"].append(f"  Found {len(unique_peerings)} VPC peering connections to delete\n")

        for peering in unique_peerings:
            peering_id = peering["VpcPeeringConnectionId"]
            status = peering.get("Status", {}).get("Code", "unknown")

            if status in ["deleted", "deleting"]:
                op["logs"].append(f"    Skipping {peering_id} (status: {status})\n")
                continue

            try:
                ec2.delete_vpc_peering_connection(VpcPeeringConnectionId=peering_id)
                op["logs"].append(f"    Deleted VPC peering: {peering_id}\n")
            except Exception as e:
                op["logs"].append(f"    Warning deleting {peering_id}: {e}\n")

    except Exception as e:
        op["logs"].append(f"  Warning: Could not clean up VPC peering connections: {e}\n")


def cleanup_vpc_network_interfaces(session: boto3.Session, vpc_id: str, region: str, op: dict) -> None:
    """Delete orphaned network interfaces in a VPC."""
    ec2 = session.client("ec2", region_name=region)

    try:
        enis = ec2.describe_network_interfaces(
            Filters=[{"Name": "vpc-id", "Values": [vpc_id]}]
        ).get("NetworkInterfaces", [])

        if not enis:
            op["logs"].append("  No network interfaces found\n")
            return

        op["logs"].append(f"  Found {len(enis)} network interfaces\n")

        for eni in enis:
            eni_id = eni["NetworkInterfaceId"]
            status = eni["Status"]
            description = eni.get("Description", "")

            # Skip ENIs that are in-use by instances or other services
            if status == "in-use":
                attachment = eni.get("Attachment", {})
                # Check if it's deletable (not attached to running instances)
                if attachment.get("DeleteOnTermination", False):
                    op["logs"].append(f"  Skipping {eni_id} (in-use, will delete with instance)\n")
                    continue

                # Try to detach if possible
                attachment_id = attachment.get("AttachmentId")
                if attachment_id:
                    try:
                        op["logs"].append(f"  Detaching {eni_id}...\n")
                        ec2.detach_network_interface(AttachmentId=attachment_id, Force=True)
                        # Wait a bit for detachment
                        import time
                        time.sleep(5)
                    except Exception as e:
                        op["logs"].append(f"    Warning detaching {eni_id}: {e}\n")
                        continue

            # Try to delete the ENI
            try:
                ec2.delete_network_interface(NetworkInterfaceId=eni_id)
                op["logs"].append(f"  Deleted ENI: {eni_id} ({description})\n")
            except Exception as e:
                op["logs"].append(f"  Warning deleting {eni_id}: {e}\n")

    except Exception as e:
        op["logs"].append(f"  Warning: Could not clean up ENIs: {e}\n")


def run_claude_code_fix(op_id: str, cluster_name: str, region: str, prompt: str) -> None:
    """Run Claude Code to fix CloudFormation stack deletion issues."""
    op = operations[op_id]
    profile = config.get("aws", {}).get("profile", "")

    op["logs"].append(f"Starting Claude Code to troubleshoot {cluster_name}...\n")
    op["logs"].append(f"Region: {region}\n")
    op["logs"].append(f"AWS Profile: {profile}\n\n")

    # Build the Claude Code command
    claude_prompt = f"""I need you to help delete the CloudFormation stack for cluster "{cluster_name}" in region {region}.

{prompt}

Please:
1. Investigate what's blocking the deletion
2. Run AWS CLI commands to clean up blocking resources (use --profile {profile} for all AWS commands)
3. Delete the CloudFormation stack(s)
4. Verify the deletion was successful

Be thorough and handle all blocking resources including: VPC peering connections, load balancers, security groups, network interfaces, NAT gateways, and any other dependencies.

Use these AWS CLI flags for all commands:
--region {region} --profile {profile}
"""

    try:
        process = subprocess.Popen(
            ["claude", "-p", claude_prompt, "--allowedTools", "Bash(*)", "Read", "Glob", "Grep"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            cwd=Path(__file__).parent,
        )

        for line in process.stdout:
            op["logs"].append(line)

        process.wait()
        rc = process.returncode

        if rc == 0:
            op["status"] = "completed"
            op["logs"].append(f"\n✓ Claude Code finished successfully\n")
        else:
            op["status"] = "failed"
            op["logs"].append(f"\n✗ Claude Code exited with code {rc}\n")

    except FileNotFoundError:
        op["status"] = "failed"
        op["logs"].append("\n✗ Error: 'claude' command not found. Make sure Claude Code CLI is installed and in PATH.\n")
        op["logs"].append("Install with: npm install -g @anthropic-ai/claude-code\n")
    except Exception as e:
        op["status"] = "failed"
        op["logs"].append(f"\n✗ Error running Claude Code: {str(e)}\n")

    op["end_time"] = datetime.now().isoformat()


@app.route("/api/cloudformation/<region>/<cluster_name>/fix-with-claude", methods=["POST"])
def fix_cf_with_claude(region: str, cluster_name: str) -> tuple:
    """Use Claude Code to fix CloudFormation stack deletion issues."""
    if not request.json.get("confirm"):
        return jsonify({"success": False, "error": "Confirmation required"}), 400

    # Get the troubleshooting prompt
    prompt = request.json.get("prompt", "")

    op_id = str(uuid.uuid4())
    operations[op_id] = {
        "id": op_id,
        "type": "claude-fix",
        "provider": "cloudformation",
        "cluster": cluster_name,
        "region": region,
        "status": "running",
        "start_time": datetime.now().isoformat(),
        "logs": [],
    }

    thread = threading.Thread(target=run_claude_code_fix, args=(op_id, cluster_name, region, prompt))
    thread.daemon = True
    thread.start()

    return jsonify({
        "success": True,
        "data": f"Claude Code is working on fixing {cluster_name}",
        "operation_id": op_id,
    })


@app.route("/api/cloudformation/<region>/<cluster_name>/delete", methods=["POST"])
def delete_cf_stacks(region: str, cluster_name: str) -> tuple:
    """Delete orphaned CloudFormation stacks."""
    if not request.json.get("confirm"):
        return jsonify({"success": False, "error": "Confirmation required"}), 400

    stacks = request.json.get("stacks", [])
    if not stacks:
        return jsonify({"success": False, "error": "No stacks provided"}), 400

    op_id = str(uuid.uuid4())
    operations[op_id] = {
        "id": op_id,
        "type": "delete",
        "provider": "cloudformation",
        "cluster": cluster_name,
        "region": region,
        "status": "running",
        "start_time": datetime.now().isoformat(),
        "logs": [],
    }

    thread = threading.Thread(target=run_cf_stack_delete, args=(op_id, cluster_name, region, stacks))
    thread.daemon = True
    thread.start()

    return jsonify({
        "success": True,
        "data": f"Deleting {len(stacks)} CloudFormation stacks for {cluster_name}",
        "operation_id": op_id,
    })


@app.route("/api/cloudformation/<region>/<cluster_name>/troubleshoot", methods=["GET"])
def troubleshoot_cf_stack(region: str, cluster_name: str) -> tuple:
    """Gather diagnostic information for troubleshooting CF stack deletion."""
    session = get_boto_session()
    cfn = session.client("cloudformation", region_name=region)
    ec2 = session.client("ec2", region_name=region)

    diagnostics = {
        "cluster_name": cluster_name,
        "region": region,
        "stacks": [],
        "vpc_info": None,
        "blocking_resources": [],
        "prompt": "",
    }

    # Find related stacks
    stack_names = [
        f"eksctl-{cluster_name}-cluster",
        f"eksctl-{cluster_name}-nodegroup-managed-nodes",
        f"eksctl-{cluster_name}-addon-vpc-cni",
    ]

    vpc_id = None

    for stack_name in stack_names:
        try:
            stack = cfn.describe_stacks(StackName=stack_name)["Stacks"][0]
            stack_info = {
                "name": stack_name,
                "status": stack["StackStatus"],
                "reason": stack.get("StackStatusReason", ""),
                "failed_resources": [],
            }

            # Get failed resources
            resources = cfn.describe_stack_resources(StackName=stack_name)["StackResources"]
            for r in resources:
                if r.get("ResourceStatus") == "DELETE_FAILED":
                    stack_info["failed_resources"].append({
                        "logical_id": r["LogicalResourceId"],
                        "type": r["ResourceType"],
                        "physical_id": r.get("PhysicalResourceId", ""),
                        "reason": r.get("ResourceStatusReason", ""),
                    })
                # Get VPC ID
                if r["ResourceType"] == "AWS::EC2::VPC" and r.get("PhysicalResourceId"):
                    vpc_id = r["PhysicalResourceId"]

            diagnostics["stacks"].append(stack_info)
        except Exception:
            pass

    # Get VPC dependencies if we have a VPC
    if vpc_id:
        vpc_info = {"vpc_id": vpc_id, "exists": False}
        try:
            ec2.describe_vpcs(VpcIds=[vpc_id])
            vpc_info["exists"] = True

            # Security Groups
            sgs = ec2.describe_security_groups(
                Filters=[{"Name": "vpc-id", "Values": [vpc_id]}]
            ).get("SecurityGroups", [])
            vpc_info["security_groups"] = [
                {"id": sg["GroupId"], "name": sg["GroupName"]}
                for sg in sgs if sg["GroupName"] != "default"
            ]

            # Network Interfaces
            enis = ec2.describe_network_interfaces(
                Filters=[{"Name": "vpc-id", "Values": [vpc_id]}]
            ).get("NetworkInterfaces", [])
            vpc_info["network_interfaces"] = [
                {"id": eni["NetworkInterfaceId"], "status": eni["Status"],
                 "type": eni.get("InterfaceType", ""), "description": eni.get("Description", "")}
                for eni in enis
            ]

            # VPC Peering
            peerings = ec2.describe_vpc_peering_connections(
                Filters=[{"Name": "requester-vpc-info.vpc-id", "Values": [vpc_id]}]
            ).get("VpcPeeringConnections", [])
            peerings += ec2.describe_vpc_peering_connections(
                Filters=[{"Name": "accepter-vpc-info.vpc-id", "Values": [vpc_id]}]
            ).get("VpcPeeringConnections", [])
            vpc_info["peering_connections"] = [
                {"id": p["VpcPeeringConnectionId"], "status": p["Status"]["Code"]}
                for p in peerings if p["Status"]["Code"] not in ["deleted", "deleting"]
            ]

            # NAT Gateways
            nats = ec2.describe_nat_gateways(
                Filter=[{"Name": "vpc-id", "Values": [vpc_id]}]
            ).get("NatGateways", [])
            vpc_info["nat_gateways"] = [
                {"id": n["NatGatewayId"], "state": n["State"]}
                for n in nats if n["State"] not in ["deleted", "deleting"]
            ]

            # Internet Gateways
            igws = ec2.describe_internet_gateways(
                Filters=[{"Name": "attachment.vpc-id", "Values": [vpc_id]}]
            ).get("InternetGateways", [])
            vpc_info["internet_gateways"] = [{"id": igw["InternetGatewayId"]} for igw in igws]

            # Load Balancers
            try:
                elb = session.client("elb", region_name=region)
                lbs = elb.describe_load_balancers().get("LoadBalancerDescriptions", [])
                vpc_info["classic_load_balancers"] = [
                    {"name": lb["LoadBalancerName"]}
                    for lb in lbs if lb.get("VPCId") == vpc_id
                ]
            except Exception:
                vpc_info["classic_load_balancers"] = []

            try:
                elbv2 = session.client("elbv2", region_name=region)
                lbs = elbv2.describe_load_balancers().get("LoadBalancers", [])
                vpc_info["load_balancers_v2"] = [
                    {"name": lb["LoadBalancerName"], "type": lb["Type"], "arn": lb["LoadBalancerArn"]}
                    for lb in lbs if lb.get("VpcId") == vpc_id
                ]
            except Exception:
                vpc_info["load_balancers_v2"] = []

            # ECS clusters check
            try:
                ecs = session.client("ecs", region_name=region)
                clusters = ecs.list_clusters().get("clusterArns", [])
                related_ecs = [c.split("/")[-1] for c in clusters if f"ecs-{cluster_name}" in c]
                vpc_info["ecs_clusters"] = related_ecs
            except Exception:
                vpc_info["ecs_clusters"] = []

        except Exception as e:
            vpc_info["error"] = str(e)

        diagnostics["vpc_info"] = vpc_info

    # Generate Claude Code prompt
    prompt_lines = [
        f"I need help troubleshooting a CloudFormation stack deletion failure.",
        f"",
        f"Cluster: {cluster_name}",
        f"Region: {region}",
        f"",
    ]

    for stack in diagnostics["stacks"]:
        prompt_lines.append(f"Stack: {stack['name']}")
        prompt_lines.append(f"Status: {stack['status']}")
        if stack.get("reason"):
            prompt_lines.append(f"Reason: {stack['reason']}")
        if stack["failed_resources"]:
            prompt_lines.append("Failed resources:")
            for r in stack["failed_resources"]:
                prompt_lines.append(f"  - {r['logical_id']} ({r['type']}): {r['reason']}")
        prompt_lines.append("")

    if vpc_id and diagnostics["vpc_info"]:
        vi = diagnostics["vpc_info"]
        prompt_lines.append(f"VPC: {vpc_id} (exists: {vi.get('exists', False)})")
        if vi.get("security_groups"):
            prompt_lines.append(f"Security Groups: {[sg['name'] for sg in vi['security_groups']]}")
        if vi.get("network_interfaces"):
            prompt_lines.append(f"ENIs: {len(vi['network_interfaces'])} found")
            for eni in vi["network_interfaces"][:5]:
                prompt_lines.append(f"  - {eni['id']}: {eni['status']} - {eni['description'][:50]}")
        if vi.get("peering_connections"):
            prompt_lines.append(f"VPC Peering: {[p['id'] for p in vi['peering_connections']]}")
        if vi.get("nat_gateways"):
            prompt_lines.append(f"NAT Gateways: {[n['id'] for n in vi['nat_gateways']]}")
        if vi.get("internet_gateways"):
            prompt_lines.append(f"Internet Gateways: {[i['id'] for i in vi['internet_gateways']]}")
        if vi.get("classic_load_balancers"):
            prompt_lines.append(f"Classic LBs: {[lb['name'] for lb in vi['classic_load_balancers']]}")
        if vi.get("load_balancers_v2"):
            prompt_lines.append(f"ALB/NLBs: {[lb['name'] for lb in vi['load_balancers_v2']]}")
        if vi.get("ecs_clusters"):
            prompt_lines.append(f"ECS Clusters: {vi['ecs_clusters']}")

    prompt_lines.extend([
        "",
        "Please help me identify what's blocking the deletion and provide AWS CLI commands to clean up the blocking resources.",
    ])

    diagnostics["prompt"] = "\n".join(prompt_lines)

    return jsonify({"success": True, "data": diagnostics})


@app.route("/api/gke/<location>/<cluster_name>/scale-down", methods=["POST"])
def scale_down_gke(location: str, cluster_name: str) -> tuple:
    try:
        project = config["gcp"]["project"]
        client = get_gke_client()
        cluster_path = f"projects/{project}/locations/{location}/clusters/{cluster_name}"
        cluster = client.get_cluster(name=cluster_path)

        if cluster_name not in config["saved_state"]["gke"]:
            config["saved_state"]["gke"][cluster_name] = {}

        for pool in cluster.node_pools:
            current_count = pool.initial_node_count

            # Only save state if current count > 0 (don't overwrite with 0)
            if current_count > 0:
                config["saved_state"]["gke"][cluster_name][pool.name] = current_count
                logging.info(f"Saving GKE state: {cluster_name}/{pool.name} = {current_count}")
            else:
                logging.info(f"Skipping save for {cluster_name}/{pool.name} (already at 0)")

            pool_path = f"{cluster_path}/nodePools/{pool.name}"
            request = container_v1.SetNodePoolSizeRequest(name=pool_path, node_count=0)
            client.set_node_pool_size(request=request)
            logging.info(f"Scaled down GKE node pool: {cluster_name}/{pool.name}")

        save_config()
        return jsonify({"success": True, "data": f"Scaled down {len(cluster.node_pools)} node pools"})
    except Exception as e:
        logging.error(f"Error scaling down GKE cluster {cluster_name}: {e}")
        return jsonify({"success": False, "error": str(e)}), 500


@app.route("/api/gke/<location>/<cluster_name>/scale-up", methods=["POST"])
def scale_up_gke(location: str, cluster_name: str) -> tuple:
    try:
        saved = config.get("saved_state", {}).get("gke", {}).get(cluster_name, {})
        if not saved:
            return jsonify({"success": False, "error": "No saved state found for this cluster"}), 400

        project = config["gcp"]["project"]
        client = get_gke_client()
        cluster_path = f"projects/{project}/locations/{location}/clusters/{cluster_name}"

        for pool_name, node_count in saved.items():
            pool_path = f"{cluster_path}/nodePools/{pool_name}"
            request = container_v1.SetNodePoolSizeRequest(name=pool_path, node_count=node_count)
            client.set_node_pool_size(request=request)
            logging.info(f"Scaled up GKE node pool: {cluster_name}/{pool_name} to {node_count}")

        return jsonify({"success": True, "data": f"Scaled up {len(saved)} node pools"})
    except Exception as e:
        logging.error(f"Error scaling up GKE cluster {cluster_name}: {e}")
        return jsonify({"success": False, "error": str(e)}), 500


@app.route("/api/gke/<location>/<cluster_name>/delete", methods=["POST"])
def delete_gke(location: str, cluster_name: str) -> tuple:
    if not request.json.get("confirm"):
        return jsonify({"success": False, "error": "Confirmation required"}), 400

    try:
        project = config["gcp"]["project"]
        client = get_gke_client()
        cluster_path = f"projects/{project}/locations/{location}/clusters/{cluster_name}"
        client.delete_cluster(name=cluster_path)
        logging.info(f"Deleted GKE cluster: {cluster_name}")
        return jsonify({"success": True, "data": "Cluster deletion initiated"})
    except Exception as e:
        logging.error(f"Error deleting GKE cluster {cluster_name}: {e}")
        return jsonify({"success": False, "error": str(e)}), 500


def start_server(port: int) -> None:
    """Start Flask server in background thread."""
    app.run(host="127.0.0.1", port=port, debug=False, use_reloader=False)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Cluster Manager")
    parser.add_argument("-c", "--config", type=str, help="Path to config file")
    parser.add_argument("--debug", action="store_true", help="Enable debug logging")
    parser.add_argument("--port", type=int, default=5000, help="Port to run on")
    parser.add_argument("--browser", action="store_true", help="Run in browser instead of native window")
    args = parser.parse_args()

    if args.config:
        CONFIG_PATH = Path(args.config).expanduser()

    log_level = logging.DEBUG if args.debug else logging.INFO
    logging.basicConfig(
        level=log_level,
        format="%(asctime)s - %(levelname)s - %(message)s",
    )

    # Suppress noisy loggers unless in debug mode
    if not args.debug:
        logging.getLogger("werkzeug").setLevel(logging.WARNING)
        logging.getLogger("botocore").setLevel(logging.WARNING)
        logging.getLogger("boto3").setLevel(logging.WARNING)
        logging.getLogger("urllib3").setLevel(logging.WARNING)
        logging.getLogger("google").setLevel(logging.WARNING)

    load_config()
    logging.info(f"Loaded config from {CONFIG_PATH}")

    if args.browser:
        import webbrowser
        url = f"http://127.0.0.1:{args.port}"
        logging.info(f"Opening browser at {url}")
        webbrowser.open(url)
        app.run(host="0.0.0.0", port=args.port, debug=args.debug)
    else:
        import os
        os.environ["PYWEBVIEW_GUI"] = "qt"  # Use Qt backend
        os.environ["QT_API"] = "pyqt5"  # Force PyQt5 over PyQt6
        try:
            server = threading.Thread(target=start_server, args=(args.port,), daemon=True)
            server.start()
            webview.create_window("Cluster Manager", f"http://127.0.0.1:{args.port}", width=1000, height=700)
            webview.start()
        except Exception as e:
            logging.error(f"Native window failed: {e}, falling back to browser")
            import webbrowser
            webbrowser.open(f"http://127.0.0.1:{args.port}")
            app.run(host="0.0.0.0", port=args.port, debug=args.debug)
