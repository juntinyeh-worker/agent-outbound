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

  # IKE, NAT-T, SSH
  aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$sg_id" \
    --ip-permissions \
    '[{"IpProtocol":"udp","FromPort":500,"ToPort":500,"IpRanges":[{"CidrIp":"0.0.0.0/0"}]},
      {"IpProtocol":"udp","FromPort":4500,"ToPort":4500,"IpRanges":[{"CidrIp":"0.0.0.0/0"}]},
      {"IpProtocol":"tcp","FromPort":22,"ToPort":22,"IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]' >/dev/null

  echo "$sg_id"
}

create_key() {
  aws ec2 create-key-pair --region "$REGION" \
    --key-name "$KEY_NAME" --query 'KeyMaterial' --output text > "/tmp/${KEY_NAME}.pem"
  chmod 600 "/tmp/${KEY_NAME}.pem"
}

user_data() {
  local public_ip="$1"
  cat <<EOF
#!/bin/bash
yum install -y strongswan

# Generate self-signed cert for this server IP (required for iOS IKEv2)
mkdir -p /etc/strongswan/ipsec.d/{cacerts,certs,private}

# Generate CA key and cert
strongswan pki --gen --type rsa --size 4096 --outform pem > /etc/strongswan/ipsec.d/private/ca-key.pem
strongswan pki --self --ca --lifetime 3650 \
  --in /etc/strongswan/ipsec.d/private/ca-key.pem \
  --type rsa --dn "CN=VPN CA" \
  --outform pem > /etc/strongswan/ipsec.d/cacerts/ca-cert.pem

# Generate server key and cert
strongswan pki --gen --type rsa --size 4096 --outform pem > /etc/strongswan/ipsec.d/private/server-key.pem
strongswan pki --pub --in /etc/strongswan/ipsec.d/private/server-key.pem --type rsa | \
  strongswan pki --issue --lifetime 1825 \
    --cacert /etc/strongswan/ipsec.d/cacerts/ca-cert.pem \
    --cakey /etc/strongswan/ipsec.d/private/ca-key.pem \
    --dn "CN=${public_ip}" \
    --san="${public_ip}" \
    --flag serverAuth --flag ikeIntermediate \
    --outform pem > /etc/strongswan/ipsec.d/certs/server-cert.pem

cat > /etc/strongswan/ipsec.conf <<IPSEC
config setup
  uniqueids=no
  charondebug="ike 2, knl 2, cfg 2"

conn ikev2-eap
  auto=add
  type=tunnel
  keyexchange=ikev2
  left=%defaultroute
  leftid=${public_ip}
  leftcert=server-cert.pem
  leftsendcert=always
  leftsubnet=0.0.0.0/0
  right=%any
  rightid=%any
  rightauth=eap-mschapv2
  rightsourceip=10.10.10.0/24
  rightdns=8.8.8.8,8.8.4.4
  rightsendcert=never
  eap_identity=%identity
  ike=aes256-sha256-modp2048,aes256-sha384-ecp384!
  esp=aes256-sha256,aes256-sha384!
  dpdaction=clear
  dpddelay=300s
  rekey=no
  fragmentation=yes
IPSEC

cat > /etc/strongswan/ipsec.secrets <<SECRETS
: RSA server-key.pem
${VPN_USER} : EAP "${VPN_PASSWORD}"
SECRETS

# Enable IP forwarding and NAT
echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
echo 'net.ipv4.conf.all.accept_redirects=0' >> /etc/sysctl.conf
echo 'net.ipv4.conf.all.send_redirects=0' >> /etc/sysctl.conf
sysctl -p

iptables -t nat -A POSTROUTING -s 10.10.10.0/24 -o eth0 -j MASQUERADE
iptables -A FORWARD -s 10.10.10.0/24 -j ACCEPT
iptables -A FORWARD -d 10.10.10.0/24 -j ACCEPT

systemctl enable strongswan
systemctl start strongswan

# Export CA cert for client download
cp /etc/strongswan/ipsec.d/cacerts/ca-cert.pem /tmp/vpn-ca.pem
EOF
}

do_up() {
  echo "==> Deploying VPN server in ${REGION}..."

  local vpc_id ami sg_id instance_id public_ip alloc_id

  vpc_id=$(get_default_vpc)
  echo "    VPC: $vpc_id"

  ami=$(get_latest_ami)
  echo "    AMI: $ami"

  echo "    Allocating Elastic IP..."
  alloc_id=$(aws ec2 allocate-address --region "$REGION" \
    --domain vpc --query 'AllocationId' --output text)
  public_ip=$(aws ec2 describe-addresses --region "$REGION" \
    --allocation-ids "$alloc_id" --query 'Addresses[0].PublicIp' --output text)
  echo "    EIP: $public_ip"

  echo "    Creating security group..."
  sg_id=$(create_sg "$vpc_id")

  echo "    Creating key pair..."
  create_key

  echo "    Launching instance..."
  instance_id=$(aws ec2 run-instances --region "$REGION" \
    --image-id "$ami" --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" --security-group-ids "$sg_id" \
    --user-data "$(user_data "$public_ip")" \
    --tag-specifications "ResourceType=instance,Tags=[{${TAG}}]" \
    --query 'Instances[0].InstanceId' --output text)

  echo "    Waiting for instance to be running..."
  aws ec2 wait instance-running --region "$REGION" --instance-ids "$instance_id"

  echo "    Associating Elastic IP..."
  aws ec2 associate-address --region "$REGION" \
    --instance-id "$instance_id" --allocation-id "$alloc_id" >/dev/null

  # Save state for teardown
  cat > "$STATE_FILE" <<EOJSON
{"instance_id":"${instance_id}","sg_id":"${sg_id}","alloc_id":"${alloc_id}","region":"${REGION}"}
EOJSON

  echo ""
  echo "========================================="
  echo " VPN Server Ready!"
  echo "========================================="
  echo " Server IP:  $public_ip"
  echo " VPN Type:   IKEv2 + EAP (iOS/Android compatible)"
  echo " Username:   $VPN_USER"
  echo " Password:   $VPN_PASSWORD"
  echo " SSH Key:    /tmp/${KEY_NAME}.pem"
  echo "========================================="
  echo ""
  echo " iPhone setup:"
  echo "   Settings → VPN → Add VPN"
  echo "   Type: IKEv2"
  echo "   Server: $public_ip"
  echo "   Remote ID: $public_ip"
  echo "   Local ID: (leave blank)"
  echo "   Auth: Username"
  echo "   Username: $VPN_USER"
  echo "   Password: $VPN_PASSWORD"
  echo ""
  echo " NOTE: Wait ~2 min for server setup to complete."
  echo " If cert validation fails, install CA cert first:"
  echo "   scp -i /tmp/${KEY_NAME}.pem ec2-user@${public_ip}:/tmp/vpn-ca.pem ."
  echo "   Then AirDrop/email vpn-ca.pem to your phone and install it."
  echo ""
  echo "To tear down: $0 down --region $REGION"
}

do_down() {
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "No state file found at $STATE_FILE. Nothing to tear down."
    exit 1
  fi

  local instance_id sg_id alloc_id
  instance_id=$(jq -r .instance_id "$STATE_FILE")
  sg_id=$(jq -r .sg_id "$STATE_FILE")
  alloc_id=$(jq -r .alloc_id "$STATE_FILE")
  REGION=$(jq -r .region "$STATE_FILE")

  echo "==> Tearing down VPN in ${REGION}..."

  echo "    Terminating instance ${instance_id}..."
  aws ec2 terminate-instances --region "$REGION" --instance-ids "$instance_id" >/dev/null
  aws ec2 wait instance-terminated --region "$REGION" --instance-ids "$instance_id"

  echo "    Releasing Elastic IP..."
  aws ec2 release-address --region "$REGION" --allocation-id "$alloc_id" 2>/dev/null || true

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
