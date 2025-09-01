
# ---- REGION SELECTION MODULE ----
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
			echo "Regions selected: ${selected_regions[*]}"
        else
            [[ -n "$sel" ]] && echo "Warning: Invalid selection '$sel'."
			exit 1
        fi
    done
 
    
}
 

DAYS="10"


select_regions
regions=("${selected_regions[@]}")


echo "Enter single or multiple instance IDs (Ctrl+D on new line to finish):"
INSTANCE_IDS=$(cat)


for region in "${regions[@]}"; do
    echo "$region"
	
for INSTANCE_ID in $INSTANCE_IDS; do

instance_details=$(aws ec2 describe-instances --region "$region" --instance-ids "$INSTANCE_ID" --query "Reservations[].Instances[]" --output json)


NAME_TAG=$(echo $instance_details | jq -r '.[0].State.Name')
[ -z "$NAME_TAG" ] && NAME_TAG=$INSTANCE_ID

current_status=$(echo "$instance_details" | jq -r '.[0].Tags[] | select(.Key=="Name").Value')



echo "Fetching the start-stop details of the instance for the past $DAYS days.  -------  $INSTANCE_ID ==>  $NAME_TAG  ==>  Current Status: $current_status"

aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=ResourceName,AttributeValue=$INSTANCE_ID \
  --start-time $(date -d "$DAYS days ago" --utc +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date --utc +%Y-%m-%dT%H:%M:%SZ) \
  --output json | \
  jq -r '
    .Events[]? |
    select(.EventName == "StopInstances" or .EventName == "StartInstances") |
    [
      .EventName,
      (.EventTime | sub("\\.[0-9]+Z$"; "Z") | sub("\\+00:00$"; "Z") | fromdateiso8601 + 19800 | strftime("%Y-%m-%d %H:%M:%S IST")),
      (.Username // "N/A")
    ] | @tsv' | \
  (echo -e "Event\tTime (IST)\tUser"; echo -e "-----\t---------\t----"; cat -) | \
  column -t -s $'\t'
 
 
done

done

