#!/bin/bash
 
# Define available region options here:
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
 
    # Validate selections and map to region codes
    selected_regions=()
    for sel in "${selections[@]}"; do
        if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#region_options[@]} )); then
            selected_regions+=("${region_options[$((sel-1))]}")
        else
            echo "Warning: Invalid selection '$sel' ignored."
        fi
    done
 
    # Use AWS_REGION environment variable if set
    cloud_region="${AWS_REGION}"
 
    if [[ -n "$cloud_region" ]]; then
        # Include cloud region if not already selected
        if [[ ! " ${selected_regions[@]} " =~ " $cloud_region " ]]; then
            selected_regions+=("$cloud_region")
        fi
    else
        echo "Info: AWS_REGION environment variable is not set."
    fi
 
    echo "Regions selected: ${selected_regions[*]}"
}
 
# Function to read multi-line input until Ctrl+D
read_inputs() {
    local prompt="$1"
    local -n result_array=$2
    echo "$prompt (enter multiple lines, press Ctrl+D when done):"
    result_array=()
    while read -r line; do
        [[ -n "$line" ]] && result_array+=("$line")
    done
}
 
echo "Select action:"
echo "1. START SERVER"
echo "2. STOP SERVER"
echo "3. RESTART SERVER"
read -p "Enter your choice (1, 2, or 3): " action
 
if [[ "$action" != "1" && "$action" != "2" && "$action" != "3" ]]; then
    echo "Invalid choice. Exiting."
    exit 1
fi
 
# Select regions using the custom function
select_regions
regions=("${selected_regions[@]}")
if [ ${#regions[@]} -eq 0 ]; then
    echo "No regions selected or detected. Exiting."
    exit 1
fi
 
# Read instance IDs
read_inputs "Enter instance IDs" instance_ids
echo "Input collection complete. Processing your request..."
if [ ${#instance_ids[@]} -eq 0 ]; then
    echo "No instance IDs entered. Exiting."
    exit 1
fi
 
ist_now=$(TZ="Asia/Kolkata" date "+%Y%m%d-%H%M%S")
out_file="started-instances-$ist_now.txt"
> "$out_file"
 
for region in "${regions[@]}"; do
    affected_ids=()
 
    if [[ "$action" == "1" ]]; then
        # Start only stopped instances in this region
        for instance_id in "${instance_ids[@]}"; do
            state=$(aws ec2 describe-instances \
                    --instance-ids "$instance_id" \
                    --query "Reservations[].Instances[].State.Name" \
                    --region "$region" \
                    --output text 2>/dev/null)
            if [[ "$state" == "stopped" ]]; then
                aws ec2 start-instances --instance-ids "$instance_id" --region "$region" >/dev/null 2>&1
                affected_ids+=("$instance_id")
            fi
        done
        if [ ${#affected_ids[@]} -gt 0 ]; then
            echo "$region" >> "$out_file"
            echo "started servers" >> "$out_file"
            printf "%s\n" "${affected_ids[@]}" >> "$out_file"
 
            echo ""
            echo "$region"
            echo "start command issued for the following instances:"
            printf "%s\n" "${affected_ids[@]}"
        else
            echo "No stopped instances found to start in region $region."
        fi
 
    elif [[ "$action" == "2" ]]; then
        # Only stop running instances
        for instance_id in "${instance_ids[@]}"; do
            state=$(aws ec2 describe-instances \
                    --instance-ids "$instance_id" \
                    --query "Reservations[].Instances[].State.Name" \
                    --region "$region" \
                    --output text 2>/dev/null)
            if [[ "$state" == "running" ]]; then
                aws ec2 stop-instances --instance-ids "$instance_id" --region "$region" >/dev/null 2>&1
                affected_ids+=("$instance_id")
            fi
        done
        if [ ${#affected_ids[@]} -gt 0 ]; then
            echo ""
            echo "$region"
            echo "stop command issued for the following instances:"
            printf "%s\n" "${affected_ids[@]}"
        else
            echo "No running instances found to stop in region $region."
        fi
 
    elif [[ "$action" == "3" ]]; then
        # Only reboot running instances
        for instance_id in "${instance_ids[@]}"; do
            state=$(aws ec2 describe-instances \
                    --instance-ids "$instance_id" \
                    --query "Reservations[].Instances[].State.Name" \
                    --region "$region" \
                    --output text 2>/dev/null)
            if [[ "$state" == "running" ]]; then
                aws ec2 reboot-instances --instance-ids "$instance_id" --region "$region" >/dev/null 2>&1
                affected_ids+=("$instance_id")
            fi
        done
        if [ ${#affected_ids[@]} -gt 0 ]; then
            echo ""
            echo "$region"
            echo "reboot command issued for the following instances:"
            printf "%s\n" "${affected_ids[@]}"
        else
            echo "No running instances found to reboot in region $region."
        fi
    fi
done
 
if [[ "$action" == "1" ]]; then
    if [[ ! -s "$out_file" ]]; then
        rm -f "$out_file"
        echo "In the provided instance IDs, no stopped instances were found to start in any selected region."
    else
        echo ""
        echo "Started stopped instances are listed in file: $out_file"
    fi
fi
 