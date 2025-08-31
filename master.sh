
#!/bin/bash
set -euo pipefail
 
# =========================
# COMMON MODULES
# =========================
region_options=(
    "ap-south-1"
    "ap-south-2"
    "us-east-1"
    "us-east-2"
    "eu-central-1"
    "eu-west-2"
)
 
select_regions() {
    echo "Select AWS regions by entering numbers separated by space (e.g. 1 3 5). Press Enter to select none:"
    for i in "${!region_options[@]}"; do
        printf "%d. %s\n" $((i+1)) "${region_options[$i]}"
    done
    read -p "Your selection: " -a selections
    selected_regions=()
    for sel in "${selections[@]}"; do
        if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#region_options[@]} )); then
            selected_regions+=("${region_options[$((sel-1))]}")
        else
            [[ -n "$sel" ]] && echo "Warning: Invalid selection '$sel' ignored."
        fi
    done
    if [[ -n "${AWS_REGION:-}" ]]; then
        if [[ ! " ${selected_regions[@]} " =~ " $AWS_REGION " ]]; then
            selected_regions+=("$AWS_REGION")
        fi
    fi
    echo "Regions selected: ${selected_regions[*]}"
}
 
read_inputs() {
    local prompt="$1"
    local -n result_array=$2
    echo "$prompt (enter multiple lines, press Ctrl+D when done):"
    result_array=()
    while read -r line; do
        [[ -n "$line" ]] && result_array+=("$line")
    done
}







# =========================
# FUNCTION 1: AMI BACKUP
# =========================
ami_backup() {
    echo "=== AMI Backup Script ==="
 

# ---- Get Instance Name Tag ----
get_instance_name() {
    local region=$1
    local instance_id=$2
    aws ec2 describe-instances --region "$region" --instance-ids "$instance_id" \
        --query "Reservations[].Instances[].Tags[?Key=='Name'].Value | [0]" --output text 2>/dev/null
}
 
# ---- AMI BACKUP FUNCTION ----
create_ami_backup() {
  local region=$1
  local instance_id=$2
  local delete_on=$3
  local instance_name=$4
  
  ami_id=$(aws ec2 create-image --region "$region" --instance-id "$instance_id" --no-reboot --name "Backup-$instance_id-$(date +%Y%m%d%H%M%S)" --query "ImageId" --output text)
  
  # Compose Name tag value for AMI
  local ami_name_tag="${instance_name}-DeleteOn-${delete_on}"
  
  # Tag the AMI with DeleteOn and Name
  aws ec2 create-tags --region "$region" --resources "$ami_id" --tags Key=DeleteOn,Value="$delete_on" Key=Name,Value="$ami_name_tag"
  
  echo "$instance_id $ami_id Name $ami_name_tag"
}
 
check_instance_existence() {
  aws ec2 describe-instances --region "$1" --instance-ids "$2" --query "Reservations[*].Instances[*].InstanceId" --output text 2>/dev/null
}
 
# ------------- SCRIPT BEGINS -----------------
select_regions
regions=("${selected_regions[@]}")
if [[ ${#regions[@]} -eq 0 ]]; then
    echo "No regions selected or detected. Exiting."
    exit 1
fi
 
read_inputs "Enter instance IDs" instance_ids
if [[ ${#instance_ids[@]} -eq 0 ]]; then
    echo "No instance IDs entered. Exiting."
    exit 1
fi
 
 
read -p "Enter the DeleteOn date (MM-DD-YYYY) [default: 7 days from today]: " delete_on
if [[ -z "$delete_on" ]]; then
    delete_on=$(date -d "+7 days" +%m-%d-%Y)
    echo "No date provided, defaulting DeleteOn to $delete_on"
fi
 
declare -A instance_found
 
for region in "${regions[@]}"; do
    echo "$region"
    for instance_id in "${instance_ids[@]}"; do
        # Skip if instance already found in previous region
        if [[ "${instance_found[$instance_id]}" == "yes" ]]; then
            continue
        fi
 
        existing_instance=$(check_instance_existence "$region" "$instance_id")
        if [ -n "$existing_instance" ]; then
            instance_name=$(get_instance_name "$region" "$instance_id")
            # If no Name tag, fallback to instance ID as name
            if [[ -z "$instance_name" || "$instance_name" == "None" ]]; then
                instance_name="$instance_id"
            fi
            create_ami_backup "$region" "$instance_id" "$delete_on" "$instance_name"
            instance_found[$instance_id]="yes"
        fi
    done
    echo
done
 
# After all regions processed, print instances not found in any region
echo "Instances not found in any selected region:"
not_found=0
for instance_id in "${instance_ids[@]}"; do
    if [[ "${instance_found[$instance_id]}" != "yes" ]]; then
        echo "$instance_id"
        not_found=1
    fi
done
 
if [[ $not_found -eq 0 ]]; then
    echo "None"
fi
 
}







# =========================
# PLACEHOLDER FUNCTIONS
# =========================
start_stop_reboot() { echo "=== Start/Stop/Reboot Script (to be expanded) ==="; }
ssm_command() { echo "=== SSM Command Script (to be expanded) ==="; }
patch_baseline() { echo "=== Patch Baseline Script (to be expanded) ==="; }
tag_editor() { echo "=== Tag Editor Script (to be expanded) ==="; }
compliance_status() { echo "=== Compliance Status Script (to be expanded) ==="; }
 
# =========================
# MAIN MENU
# =========================
while true; do
    echo ""
    echo "===== AWS MASTER SCRIPT ====="
    echo "1. AMI Backup"
    echo "2. Start/Stop/Reboot Instances"
    echo "3. Run SSM Command"
    echo "4. Patch Baseline"
    echo "5. Tag Editor"
    echo "6. Compliance Status"
    echo "7. Exit"
    read -p "Choose an option: " choice
 
    case $choice in
        1) ami_backup ;;
        2) start_stop_reboot ;;
        3) ssm_command ;;
        4) patch_baseline ;;
        5) tag_editor ;;
        6) compliance_status ;;
        7) echo "Exiting..."; exit 0 ;;
        *) echo "Invalid choice, try again." ;;
    esac
done
 