
 
region_options=("ap-south-1" "ap-south-2" "us-east-1" "us-east-2" "eu-central-1" "eu-west-2")
 
select_regions() {
    echo -e "\nSelect AWS regions by entering numbers separated by space (e.g. 1 3 5)."
    echo "Press Enter with no input to use the current region $AWS_REGION."
    for i in "${!region_options[@]}"; do
        printf "%d. %s\n" $((i+1)) "${region_options[$i]}"
    done
    read -p "Your selection: " -a selections
 
    selected_regions=()
 
    # Case 1: user pressed Enter with no input
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
 
    # Case 2: user entered numbers
    for sel in "${selections[@]}"; do
        if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#region_options[@]} )); then
            selected_regions+=("${region_options[$((sel-1))]}")
        else
            [[ -n "$sel" ]] && echo "Warning: Invalid selection '$sel' ignored."
        fi
    done
 
    echo "Regions selected: ${selected_regions[*]}"
}
 
 
read_inputs() {
    local prompt="$1"
    local -n result_array=$2
    echo "$prompt (enter multiple lines / space separated, press Ctrl+D when done):"
    result_array=()
    while read -r line; do
        for val in $line; do
            [[ -n "$val" ]] && result_array+=("$val")
        done
    done
    # Message after Ctrl+D
    echo "Input received, sending ssm commands..."
}
 
# Main Flow
select_regions
regions=("${selected_regions[@]}")
if [ ${#regions[@]} -eq 0 ]; then
    echo "No regions selected and AWS_REGION not set. Exiting."
    exit 1
fi
 
echo "Select operation type:"
echo "1) Scan only"
echo "2) Install"
read -p "Enter choice [1/2]: " op_choice
if [[ "$op_choice" == "1" ]]; then
    operation="Scan"
else
    operation="Install"
fi
 
echo "Reboot option:"
echo "1) Reboot if needed"
echo "2) Don't reboot"
read -p "Enter choice [1/2]: " reb_choice
if [[ "$reb_choice" == "1" ]]; then
    reboot_option="RebootIfNeeded"
else
    reboot_option="NoReboot"
fi
 
read_inputs "Enter instance IDs" instance_ids
if [ ${#instance_ids[@]} -eq 0 ]; then
    echo "No instance IDs entered. Exiting."
    exit 1
fi
 
# Group running instance IDs by region
declare -A region_instances


for region in "${regions[@]}"; do
    running_ids=()
    for inst in "${instance_ids[@]}"; do
        state=$(aws ec2 describe-instances \
                --instance-ids "$inst" \
                --query "Reservations[].Instances[].State.Name" \
                --region "$region" \
                --output text 2>/dev/null)
        if [[ "$state" == "running" ]]; then
            running_ids+=("$inst")
		else
			if [[ -n "$state" ]]; then
			echo "$inst $region ==> Not running instance excluded from patching list..."
			fi
        fi
    done
    region_instances["$region"]="${running_ids[*]}"
done
 
 
 

max_batch=50
for region in "${regions[@]}"; do
    ids_str="${region_instances[$region]}"
    read -a rids <<< "$ids_str"
    total=${#rids[@]}
    if (( total == 0 )); then
        continue
    fi
 
    echo ""
    echo "$region"
    start=0
 
    while (( start < total )); do
        batch=()
        for ((i=start; i<start+max_batch && i<total; i++)); do
            batch+=("${rids[$i]}")
        done
        batch_count=${#batch[@]}
        id_csv=$(IFS=,; echo "${batch[*]}")
        response=$(aws ssm send-command \
            --region "$region" \
            --document-name "AWS-RunPatchBaseline" \
            --targets "Key=InstanceIds,Values=$id_csv" \
            --parameters "Operation=$operation,RebootOption=$reboot_option" \
            --timeout-seconds 600 \
            --max-concurrency "$batch_count" \
            --max-errors "1" \
            --output json 2>/dev/null)
        command_id=$(echo "$response" | grep -oP '"CommandId":\s*"\K[^"]+')
        for id in "${batch[@]}"; do
            echo "instance id : $id | command id: $command_id"
        done
        start=$((start + max_batch))
    done
done


