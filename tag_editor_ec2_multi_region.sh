#!/bin/bash
 
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
    echo "$prompt (enter multiple lines, press Ctrl+D when done):"
    result_array=()
    while read -r line; do
        [[ -n "$line" ]] && result_array+=("$line")
    done
}
 
select_regions
regions=("${selected_regions[@]}")
if [[ ${#regions[@]} -eq 0 ]]; then
    echo "No regions selected or detected. Exiting."
    exit 1
fi
 
 
echo "Select operation:"
select operation in "Add tag" "Remove tag"; do
    if [[ "$operation" == "Add tag" || "$operation" == "Remove tag" ]]; then
        break
    fi
done
 
echo "Enter tag key:"
read tag_key
if [[ "$operation" == "Add tag" ]]; then
    echo "Enter tag value:"
    read tag_value
else
    tag_value=""
fi
 
read_inputs "Enter instance IDs" instance_ids
if [[ ${#instance_ids[@]} -eq 0 ]]; then
    echo "No instance IDs entered. Exiting."
    exit 1
fi
 
echo "Input collected. Performing tag ${operation/ tag/tag} operation..."
 
declare -A instance_found_in_some_region
 
# Work on a mutable copy of the instance_ids array
remaining_instance_ids=("${instance_ids[@]}")
 
for region in "${regions[@]}"; do
    echo "$region"
 
    new_remaining=()
    for iid in "${remaining_instance_ids[@]}"; do
        tags_json=$(aws ec2 describe-instances --region "$region" --instance-ids "$iid" --query "Reservations[0].Instances[0].Tags[]" --output json 2>/dev/null)
 
        if [[ -n "$tags_json" && "$tags_json" != "null" && "$tags_json" != "[]" \
            && ! "$tags_json" =~ "InvalidInstanceID" && ! "$tags_json" =~ "InvalidInstanceID.NotFound" \
            && ! "$tags_json" =~ "error" ]]; then
 
            instance_found_in_some_region["$iid"]=1
            tag_value_found=$(echo "$tags_json" | jq -r --arg k "$tag_key" '.[] | select(.Key==$k) | .Value' 2>/dev/null)
 
            if [[ "$operation" == "Add tag" ]]; then
                if [[ -n "$tag_value_found" && "$tag_value_found" == "$tag_value" ]]; then
                    echo "$iid $tag_key $tag_value already available"
                else
                    aws ec2 create-tags --region "$region" --resources "$iid" --tags Key="$tag_key",Value="$tag_value" 2>/dev/null
                    echo "$iid $tag_key $tag_value added"
                fi
            else # Remove tag
                if [[ -n "$tag_value_found" ]]; then
                    aws ec2 delete-tags --region "$region" --resources "$iid" --tags Key="$tag_key" 2>/dev/null
                    echo "$iid $tag_key $tag_value_found deleted"
                fi
            fi
        else
            # Keep only IDs not found in this region
            new_remaining+=("$iid")
        fi
    done
 
    # Update remaining_instance_ids for the next region
    remaining_instance_ids=("${new_remaining[@]}")
    echo
done
 
# Print instance IDs not found in ANY region
if [[ ${#remaining_instance_ids[@]} -gt 0 ]]; then
    echo "Instance IDs not found in any selected region:"
    for nf in "${remaining_instance_ids[@]}"; do
        echo "$nf"
    done
fi
 