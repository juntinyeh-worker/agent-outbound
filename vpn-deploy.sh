#!/usr/bin/env bash
set -euo pipefail

# On-demand IPsec VPN server on EC2 (strongSwan + IKEv2)
# Usage:
#   ./vpn-deploy.sh up   [--region us-east-1] [--instance-type t3.micro]
#   ./vpn-deploy.sh down [--region us-east-1]

STACK_NAME="vpn-ondemand"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
INSTANCE_TYPE="t3.micro"
VPN_USER="vpnuser"
VPN_PSK=$(openssl rand -base64 24)
VPN_PASSWORD=$(openssl rand -base64 16)

# Parse args
ACTION="${1:-help}"; shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2;;
    --instance-type) INSTANCE_TYPE="$2"; shift 2;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

SG_NAME="${STACK_NAME}-sg"
KEY_NAME="${STACK_NAME}-key"
TAG="Key=Stack,Value=${STACK_NAME}"
STATE_FILE="/tmp/${STACK_NAME}-state.json"

get_default_vpc() {
  aws ec2 describe-vpcs --region "$REGION" \
    --filters Name=is-default,Values=true \
    --query 'Vpcs[0].VpcId' --output text
}

get_latest_ami() {
  aws ec2 describe-images --region "$REGION" \
    --owners amazon \
    --filters "Name=name,Values=al2023-ami-2023.*-x86_64" "Name=state,Values=available" \
    --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' --output text
}

create_sg() {
  local vpc_id="$1"
  local sg_id
  sg_id=$(aws ec2 create-security-group --region "$REGION" \
    --group-name "$SG_NAME" --description "VPN server SG" \
    --vpc-id "$vpc_id" --output text --query 'GroupId')

  # IKE, NAT-T, ESP
  aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$sg_id" \
    --ip-permissions \
    '[{"IpProtocol":"udp","FromPort":500,"ToPort":500,"IpRanges":[{"CidrIp":"0.0.0.0/0"}]},
      {"IpProtocol":"udp","FromPort":4500,"ToPort":4500,"IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]' >/dev/null

  echo "$sg_id"
}

create_key() {
  aws ec2 create-key-pair --region "$REGION" \
    --key-name "$KEY_NAME" --query 'KeyMaterial' --output text > "/tmp/${KEY_NAME}.pem"
  chmod 600 "/tmp/${KEY_NAME}.pem"
}

user_data() {
  cat <<EOF
#!/bin/bash
yum install -y strongswan

cat > /etc/strongswan/ipsec.conf <<'IPSEC'
config setup
  uniqueids=no

conn ikev2-psk
  auto=add
  type=tunnel
  keyexchange=ikev2
  authby=secret
  left=%defaultroute
  leftsubnet=0.0.0.0/0
  right=%any
  rightsourceip=10.10.10.0/24
  ike=aes256-sha256-modp2048!
  esp=aes256-sha256-modp2048!
IPSEC

cat > /etc/strongswan/ipsec.secrets <<SECRETS
: PSK "${VPN_PSK}"
${VPN_USER} : EAP "${VPN_PASSWORD}"
SECRETS

# Enable IP forwarding and NAT
echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
sysctl -p
iptables -t nat -A POSTROUTING -s 10.10.10.0/24 -o eth0 -j MASQUERADE

systemctl enable strongswan
systemctl start strongswan
EOF
}

do_up() {
  echo "==> Deploying VPN server in ${REGION}..."

  local vpc_id ami sg_id instance_id public_ip

  vpc_id=$(get_default_vpc)
  echo "    VPC: $vpc_id"

  ami=$(get_latest_ami)
  echo "    AMI: $ami"

  echo "    Creating security group..."
  sg_id=$(create_sg "$vpc_id")

  echo "    Creating key pair..."
  create_key

  echo "    Launching instance..."
  instance_id=$(aws ec2 run-instances --region "$REGION" \
    --image-id "$ami" --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" --security-group-ids "$sg_id" \
    --user-data "$(user_data)" \
    --tag-specifications "ResourceType=instance,Tags=[{${TAG}}]" \
    --query 'Instances[0].InstanceId' --output text)

  echo "    Waiting for instance to be running..."
  aws ec2 wait instance-running --region "$REGION" --instance-ids "$instance_id"

  public_ip=$(aws ec2 describe-instances --region "$REGION" \
    --instance-ids "$instance_id" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

  # Save state for teardown
  cat > "$STATE_FILE" <<EOJSON
{"instance_id":"${instance_id}","sg_id":"${sg_id}","region":"${REGION}"}
EOJSON

  echo ""
  echo "========================================="
  echo " VPN Server Ready!"
  echo "========================================="
  echo " Server IP:  $public_ip"
  echo " VPN Type:   IKEv2 + PSK"
  echo " PSK:        $VPN_PSK"
  echo " Username:   $VPN_USER"
  echo " Password:   $VPN_PASSWORD"
  echo " SSH Key:    /tmp/${KEY_NAME}.pem"
  echo "========================================="
  echo ""
  echo "To tear down: $0 down --region $REGION"
}

do_down() {
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "No state file found at $STATE_FILE. Nothing to tear down."
    exit 1
  fi

  local instance_id sg_id
  instance_id=$(jq -r .instance_id "$STATE_FILE")
  sg_id=$(jq -r .sg_id "$STATE_FILE")
  REGION=$(jq -r .region "$STATE_FILE")

  echo "==> Tearing down VPN in ${REGION}..."

  echo "    Terminating instance ${instance_id}..."
  aws ec2 terminate-instances --region "$REGION" --instance-ids "$instance_id" >/dev/null
  aws ec2 wait instance-terminated --region "$REGION" --instance-ids "$instance_id"

  echo "    Deleting security group ${sg_id}..."
  aws ec2 delete-security-group --region "$REGION" --group-id "$sg_id"

  echo "    Deleting key pair..."
  aws ec2 delete-key-pair --region "$REGION" --key-name "$KEY_NAME"
  rm -f "/tmp/${KEY_NAME}.pem"

  rm -f "$STATE_FILE"
  echo "==> Done. VPN server destroyed."
}

case "$ACTION" in
  up)   do_up;;
  down) do_down;;
  *)
    echo "Usage: $0 {up|down} [--region REGION] [--instance-type TYPE]"
    exit 1;;
esac
