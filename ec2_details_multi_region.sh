#!/bin/bash
 
# Requires: awscli, jq
# Behavior:
# - Choose regions
# - Prompt to check Target Group (TG) details (Enter=yes, no=no, other=exit)
# - Read one or more instance IDs (Ctrl+D to finish)
# - Prints instance details; if TG check enabled, prints TG names too.
# - Minimizes TG API calls by building a TG index once per region.
 
region_options=(
  "ap-south-1"
  "ap-south-2"
  "us-east-1"
  "us-east-2"
  "eu-central-1"
  "eu-west-2"
)
 
select_regions() {
  echo -e "\nSelect AWS regions by entering numbers separated by space (e.g. 1 3 5)."
  echo "Press Enter with no input to use the current region \$AWS_REGION."
  for i in "${!region_options[@]}"; do
    printf "%d. %s\n" $((i+1)) "${region_options[$i]}"
  done
  read -p "Your selection: " -a selections
  selected_regions=()
  if [[ ${#selections[@]} -eq 0 ]]; then
    if [[ -n "${AWS_REGION:-}" ]]; then
      selected_regions=("$AWS_REGION")
      echo "Using current region: $AWS_REGION"
    else
      echo "No input and \$AWS_REGION is not set. Exiting."
      exit 1
    fi
    return
  fi
  for sel in "${selections[@]}"; do
    if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#region_options[@]} )); then
      selected_regions+=("${region_options[$((sel-1))]}")
    else
      [[ -n "$sel" ]] && echo "Warning: Invalid selection '$sel'."
      exit 1
    fi
  done
  echo "Regions selected: ${selected_regions[*]}"
}
 
select_regions
regions=("${selected_regions[@]}")
 
# Ask whether to check TGs (default = yes)
read -p "Do you want to check Target Group details? (Enter=yes, no=no): " check_tg
if [[ -z "$check_tg" ]]; then
  check_tg="yes"
elif [[ "$check_tg" != "yes" && "$check_tg" != "no" ]]; then
  echo "Invalid input. Exiting."
  exit 1
fi
 
# Read instance IDs
echo "Enter single or multiple instance IDs (Ctrl+D on new line to finish):"
INSTANCE_ID_LIST=()
while read -r line; do
  [[ -n "$line" ]] && INSTANCE_ID_LIST+=("$line")
done
echo -e "\nInstance IDs collected. Fetching details ...\n"
 
UNSEARCHED_IDS=("${INSTANCE_ID_LIST[@]}")
 
# ---------- Target Group utilities (only used if user chose 'yes') ----------
declare -A TG_INDEX_BUILT   # key: region -> "1" if built
declare -A TG_MAP           # key: "region|instance_id" -> "tg1,tg2,..."
 
build_tg_index_for_region() {
  local region="$1"
  [[ "${TG_INDEX_BUILT[$region]-}" == "1" ]] && return
 
  echo "[$region] Collecting Target Group details... it might take a few minutes."
 
  local tg_arns tg_arn tg_name targets id key
  tg_arns=$(aws elbv2 describe-target-groups \
              --region "$region" \
              --query "TargetGroups[].TargetGroupArn" \
              --output text 2>/dev/null)
 
  for tg_arn in $tg_arns; do
    tg_name=$(echo "$tg_arn" | cut -d'/' -f2)
    targets=$(aws elbv2 describe-target-health \
                --region "$region" \
                --target-group-arn "$tg_arn" \
                --query "TargetHealthDescriptions[].Target.Id" \
                --output text 2>/dev/null)
    for id in $targets; do
      [[ -z "$id" ]] && continue
      key="${region}|${id}"
      if [[ -z "${TG_MAP[$key]:-}" ]]; then
        TG_MAP[$key]="$tg_name"
      else
        TG_MAP[$key]="${TG_MAP[$key]},$tg_name"
      fi
    done
  done
  TG_INDEX_BUILT[$region]=1
}
 
print_tg_for_instance() {
  local region="$1" id="$2"
  local key="${region}|${id}"
  if [[ -n "${TG_MAP[$key]:-}" ]]; then
    IFS=',' read -ra _tgs <<< "${TG_MAP[$key]}"
    for _n in "${_tgs[@]}"; do
      echo "Target Group: $_n"
    done
  else
    echo "Target Group: None"
  fi
}
# ---------------------------------------------------------------------------
 
for region in "${regions[@]}"; do
  CURRENT_IDS=("${UNSEARCHED_IDS[@]}")
  IDS_FOUND_THIS_REGION=()
 
  if [[ "$check_tg" == "yes" ]]; then
    build_tg_index_for_region "$region"
  fi
 
  for INSTANCE_ID in "${CURRENT_IDS[@]}"; do
    instance_details=$(aws ec2 describe-instances \
      --region "$region" \
      --instance-ids "$INSTANCE_ID" \
      --query "Reservations[].Instances[]" \
      --output json 2>/dev/null)
 
    instance_cnt=$(echo "$instance_details" | jq length)
    if [[ "$instance_cnt" -gt 0 ]]; then
      IDS_FOUND_THIS_REGION+=("$INSTANCE_ID")
      for i in $(seq 0 $(($instance_cnt-1))); do
        info=$(echo "$instance_details" | jq ".[$i]")
 
        NAME_TAG=$(echo "$info" | jq -r '.Tags[]? | select(.Key=="Name") | .Value // empty')
        [[ -z "$NAME_TAG" ]] && NAME_TAG="No Name Tag"
 
        PRIVATE_IP=$(echo "$info" | jq -r '.PrivateIpAddress // "None"')
        SUBNET_ID=$(echo "$info" | jq -r '.SubnetId // "None"')
        VPC_ID=$(echo "$info" | jq -r '.VpcId // "None"')
 
        if [[ "$SUBNET_ID" != "None" ]]; then
          SUBNET_NAME=$(aws ec2 describe-subnets \
            --region "$region" \
            --subnet-ids "$SUBNET_ID" \
            --query "Subnets[0].Tags[?Key=='Name'].Value | [0]" \
            --output text 2>/dev/null)
          [[ "$SUBNET_NAME" == "None" || -z "$SUBNET_NAME" ]] && SUBNET_NAME="None"
        else
          SUBNET_NAME="None"
        fi
 
        if [[ "$VPC_ID" != "None" ]]; then
          VPC_NAME=$(aws ec2 describe-vpcs \
            --region "$region" \
            --vpc-ids "$VPC_ID" \
            --query "Vpcs[0].Tags[?Key=='Name'].Value | [0]" \
            --output text 2>/dev/null)
          [[ "$VPC_NAME" == "None" || -z "$VPC_NAME" ]] && VPC_NAME="None"
        else
          VPC_NAME="None"
        fi
 
        IAM_INSTANCE_PROFILE=$(echo "$info" | jq -r '.IamInstanceProfile.Arn // "None"')
        IAM_ROLE="None"
        if [[ "$IAM_INSTANCE_PROFILE" != "None" && "$IAM_INSTANCE_PROFILE" != "null" ]]; then
          PROFILE_NAME=$(basename "$IAM_INSTANCE_PROFILE")
          IAM_ROLE=$(aws iam get-instance-profile \
            --instance-profile-name "$PROFILE_NAME" \
            --query 'InstanceProfile.Roles[0].RoleName' \
            --output text 2>/dev/null)
          [[ -z "$IAM_ROLE" || "$IAM_ROLE" == "None" ]] && IAM_ROLE="None"
        fi
 
        ENIS=$(echo "$info" | jq -r '.NetworkInterfaces[]?.NetworkInterfaceId // empty' | paste -sd ',' -)
        [[ -z "$ENIS" ]] && ENIS="None"
 
        VOLUMES_OUT=()
        block_maps=$(echo "$info" | jq -c '.BlockDeviceMappings[]?')
        while IFS= read -r bdm; do
          VOL_ID=$(echo "$bdm" | jq -r '.Ebs.VolumeId // empty')
          DEV_NAME=$(echo "$bdm" | jq -r '.DeviceName // empty')
          if [[ -n "$VOL_ID" ]]; then
            VOL_SIZE=$(aws ec2 describe-volumes \
              --region "$region" \
              --volume-ids "$VOL_ID" \
              --query 'Volumes[0].Size' \
              --output text 2>/dev/null)
            [[ -z "$VOL_SIZE" || "$VOL_SIZE" == "None" ]] && VOL_SIZE="None"
            VOLUMES_OUT+=("$VOL_ID $VOL_SIZE GB $DEV_NAME")
          fi
        done <<< "$block_maps"
 
        SG_OUT=()
        while read -r line; do
          SG_ID=$(echo "$line" | awk '{print $1}')
          SG_NAME=$(echo "$line" | cut -d' ' -f2-)
          SG_OUT+=("$SG_ID $SG_NAME")
        done < <(echo "$info" | jq -r '.SecurityGroups[]? | "\(.GroupId) \(.GroupName)"')
 
		echo "-----------------------------------------------------------------------"
		echo "Region: 			$region"
		echo "Name: 			$NAME_TAG"
        echo "InstanceID: 		$INSTANCE_ID"
        echo "Private IP: 		$PRIVATE_IP"
        echo "Subnet: 		$SUBNET_ID ($SUBNET_NAME)"
        echo "VPC: 			$VPC_ID ($VPC_NAME)"
        echo "IAM Role: 		$IAM_ROLE"
        echo "ENIs: 			$ENIS"
        echo -e "\nAttached Volumes:"
        if ((${#VOLUMES_OUT[@]})); then
          printf "%s\n" "${VOLUMES_OUT[@]}" | column -t
        else
          echo "None"
        fi
 
        echo -e "\nSecurity Groups:"
		echo "Inbound Rules:"
        if ((${#SG_OUT[@]})); then
          for sg in "${SG_OUT[@]}"; do
            echo "$sg"
            SG_ID=$(echo "$sg" | awk '{print $1}')
            SG_RULES=$(aws ec2 describe-security-groups \
              --region "$region" \
              --group-ids "$SG_ID" \
              --query "SecurityGroups[].IpPermissions[]" \
              --output json 2>/dev/null)
            rule_count=$(echo "$SG_RULES" | jq length)
            SG_RULE_LINES=()
            for j in $(seq 0 $(($rule_count-1))); do
              rule=$(echo "$SG_RULES" | jq ".[$j]")
              PROTOCOL=$(echo "$rule" | jq -r '.IpProtocol')
              FROM_PORT=$(echo "$rule" | jq -r '.FromPort // "all"')
              TO_PORT=$(echo "$rule" | jq -r '.ToPort // "all"')
              for cidr in $(echo "$rule" | jq -r '.IpRanges[]?.CidrIp'); do
                PORTS="$FROM_PORT"
                [[ "$FROM_PORT" != "$TO_PORT" && "$TO_PORT" != "all" ]] && PORTS="$FROM_PORT-$TO_PORT"
                SG_RULE_LINES+=("$cidr $PORTS $PROTOCOL")
              done
            done
            if ((${#SG_RULE_LINES[@]})); then
              printf "%s\n" "${SG_RULE_LINES[@]}" | column -t
            else
              echo "No ingress rules"
            fi
          done
        else
          echo "None"
        fi
 
        if [[ "$check_tg" == "yes" ]]; then
          print_tg_for_instance "$region" "$INSTANCE_ID"
        fi
 
        #echo "---------------------------"
 
        unset SG_OUT
        unset VOLUMES_OUT
      done
    fi
  done
 
  for found_id in "${IDS_FOUND_THIS_REGION[@]}"; do
    for i in "${!UNSEARCHED_IDS[@]}"; do
      if [[ "${UNSEARCHED_IDS[i]}" = "$found_id" ]]; then
        unset "UNSEARCHED_IDS[i]"
      fi
    done
  done
  UNSEARCHED_IDS=("${UNSEARCHED_IDS[@]}")
done
 
if ((${#UNSEARCHED_IDS[@]} != 0)); then
  echo -e "\nInstance IDs NOT found in any region:"
  for unfound in "${UNSEARCHED_IDS[@]}"; do
    echo "$unfound"
  done
else
  echo -e "\nAll instance IDs found in at least one region."
fi
 