#!/bin/bash
 
# ==============================================================================
# AWS EC2 Instance Management Script
#
# Description:
# This script provides an interactive menu to start, stop, and reboot
# EC2 instances. It includes safety checks for production environments and
# maintains a cache of started instances for easy stopping.
#
# Author: Gemini
# Version: 2.0
#
# Prerequisites:
#   - AWS CLI installed and configured with appropriate permissions.
#   - jq (command-line JSON processor) installed.
#
# Usage:
#   ./manage_ec2.sh
#
# ==============================================================================
 
# --- Configuration & Setup ---
CACHE_FILE=".cache_started_instances.txt"
 
# Define available region options
REGION_OPTIONS=(
    "ap-south-1"
	"ap-south-2"
    "us-east-1"
    "us-east-2"
    "eu-central-1"
    "eu-west-2"
)
 
# --- Color Definitions for Output ---
RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
YELLOW=$(tput setaf 3)
BLUE=$(tput setaf 4)
BOLD=$(tput bold)
NORMAL=$(tput sgr0)
 
# --- Prerequisite Check ---
if ! command -v aws &> /dev/null; then
    echo "${RED}Error: AWS CLI is not installed. Please install it to continue.${NORMAL}"
    exit 1
fi
 
if ! command -v jq &> /dev/null; then
    echo "${RED}Error: jq is not installed. Please install it to continue.${NORMAL}"
    exit 1
fi
 
# --- Helper Functions ---
 
# Function to log messages with different levels and colors
log() {
    local type="$1"
    local message="$2"
    case "$type" in
        "INFO") echo "${BLUE}[INFO]${NORMAL} $message" ;;
        "SUCCESS") echo "${GREEN}[SUCCESS]${NORMAL} $message" ;;
        "WARN") echo "${YELLOW}[WARN]${NORMAL} $message" ;;
        "ERROR") echo "${RED}[ERROR]${NORMAL} $message" ;;
        *) echo "$message" ;;
    esac
}
 
# NEW: Function to get user input for regions and instance IDs interactively
select_inputs() {
    # --- Region Selection ---
    echo "${BOLD}Select AWS regions by entering numbers separated by space (e.g., 1 3).${NORMAL}"
    for i in "${!REGION_OPTIONS[@]}"; do
        printf "%d. %s\n" $((i+1)) "${REGION_OPTIONS[$i]}"
    done
 
    read -p "${BOLD}Your selection: ${NORMAL}" -a selections
 
    SELECTED_REGIONS=()
    for sel in "${selections[@]}"; do
        if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#REGION_OPTIONS[@]} )); then
            SELECTED_REGIONS+=("${REGION_OPTIONS[$((sel-1))]}")
        else
            log "WARN" "Invalid selection '$sel' ignored."
        fi
    done
 
    # Automatically add AWS_REGION if it is set
    if [[ -n "$AWS_REGION" ]] && [[ ! " ${SELECTED_REGIONS[@]} " =~ " $AWS_REGION " ]]; then
        log "INFO" "Adding region from AWS_REGION environment variable: $AWS_REGION"
        SELECTED_REGIONS+=("$AWS_REGION")
    fi
 
    if [ ${#SELECTED_REGIONS[@]} -eq 0 ]; then
        log "ERROR" "No regions selected. Exiting."
        exit 1
    fi
    log "INFO" "Regions to be processed: ${YELLOW}${SELECTED_REGIONS[*]}${NORMAL}"
    
    # --- Instance ID Selection ---
    echo "${BOLD}Enter instance ID(s). You can paste multiple lines. Press Ctrl+D when done:${NORMAL}"
    INSTANCE_IDS=()
    while read -r line; do
        # Add multiple IDs if they are space-separated on one line
        for id in $line; do
            [[ -n "$id" ]] && INSTANCE_IDS+=("$id")
        done
    done
    
    if [ ${#INSTANCE_IDS[@]} -eq 0 ]; then
        log "ERROR" "No instance IDs entered. Exiting."
        exit 1
    fi
    log "INFO" "Instance IDs to be processed: ${YELLOW}${INSTANCE_IDS[*]}${NORMAL}"
    echo "--------------------------------------------------"
}
 
 
# Function to describe an instance and return its state and specific tags
get_instance_details() {
    local region="$1"
    local instance_id="$2"
    
    # Suppress stderr to handle "not found" cases gracefully
    aws ec2 describe-instances \
        --region "$region" \
        --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0].{State:State.Name, Name:Tags[?Key==`Name`].Value | [0], Env:Tags[?Key==`environment`].Value | [0]}' \
        --output json 2>/dev/null
}
 
 
# --- Core Action Functions ---
 
# 1. START INSTANCES
start_instances() {
    log "INFO" "Starting the 'start instance' module..."
    select_inputs
 
    local all_started_instances=()
    
    for region in "${SELECTED_REGIONS[@]}"; do
        log "INFO" "Processing region: ${BOLD}$region${NORMAL}"
        local region_started_ids=()
        
        for instance_id in "${INSTANCE_IDS[@]}"; do
            details=$(get_instance_details "$region" "$instance_id")
            
            if [ -z "$details" ] || [ "$details" == "null" ]; then
                # Instance not found in this region, which is normal.
                continue
            fi
 
            state=$(echo "$details" | jq -r .State)
            log "INFO" "Instance ${YELLOW}$instance_id${NORMAL} found with state: ${BOLD}$state${NORMAL}"
 
            if [ "$state" == "stopped" ]; then
                log "INFO" "Attempting to start instance ${YELLOW}$instance_id${NORMAL}..."
                aws ec2 start-instances --region "$region" --instance-ids "$instance_id" > /dev/null
                region_started_ids+=("$instance_id")
                all_started_instances+=("$instance_id:$region")
            else
                log "WARN" "Instance ${YELLOW}$instance_id${NORMAL} is not in a 'stopped' state. No action taken."
            fi
        done
 
        if [ ${#region_started_ids[@]} -gt 0 ]; then
            echo
            log "SUCCESS" "Start command issued for the following instances in region ${GREEN}$region${NORMAL}:"
            printf "  - %s\n" "${region_started_ids[@]}"
            echo
        else
            log "INFO" "No stopped instances from your list were found in region ${BOLD}$region${NORMAL}."
        fi
        echo "--------------------------------------------------"
    done
 
    if [ ${#all_started_instances[@]} -gt 0 ]; then
        log "SUCCESS" "Summary: All start commands have been issued."
        # Save to cache file, overwriting previous content
        printf "%s\n" "${all_started_instances[@]}" > "$CACHE_FILE"
        log "INFO" "Started instance list saved to cache file for use with the 'stop' command: ${YELLOW}$CACHE_FILE${NORMAL}"
    else
        log "WARN" "No instances were started across any of the selected regions."
    fi
}
 
# Generic function for Stop and Reboot operations
perform_action() {
    local action="$1" # "stop" or "reboot"
    local action_ing="$2" # "stopping" or "rebooting"
    
    log "INFO" "Starting the '$action instance' module..."
    
    local instances_to_process=()
    local use_cache_input=""
    
    # Check for cache file
    if [ -f "$CACHE_FILE" ] && [ -s "$CACHE_FILE" ]; then
        log "INFO" "Found a cache file with previously started instances."
        read -p "${BOLD}Do you want to $action these instances? [y/n]: ${NORMAL}" use_cache_input
    fi
 
    if [[ "$use_cache_input" =~ ^[Yy]$ ]]; then
        # === A: Process from Cache File ===
        mapfile -t instances_to_process < "$CACHE_FILE"
        log "INFO" "Processing ${#instances_to_process[@]} instance(s) from cache."
 
        for item in "${instances_to_process[@]}"; do
            instance_id="${item%%:*}"
            region="${item##*:}"
            # This is the single-item processing logic, refactored into a function
            process_single_instance "$action" "$action_ing" "$region" "$instance_id"
        done
 
    else
        # === B: Process from New User Input ===
        select_inputs
        for region in "${SELECTED_REGIONS[@]}"; do
            log "INFO" "Processing region: ${BOLD}$region${NORMAL}"
            for instance_id in "${INSTANCE_IDS[@]}"; do
                # Check if instance exists in this region before processing
                details=$(get_instance_details "$region" "$instance_id")
                if [ -z "$details" ] || [ "$details" == "null" ]; then
                    continue
                fi
                process_single_instance "$action" "$action_ing" "$region" "$instance_id"
            done
        done
    fi
    
    # Clear cache if we used it
    if [[ "$use_cache_input" =~ ^[Yy]$ ]]; then
        > "$CACHE_FILE"
        log "INFO" "Cache file has been cleared."
    fi
}
 
# Helper for perform_action to process one instance (avoids code duplication)
process_single_instance() {
    local action="$1"
    local action_ing="$2"
    local region="$3"
    local instance_id="$4"
 
    log "INFO" "Checking instance ${YELLOW}$instance_id${NORMAL} in region ${YELLOW}$region${NORMAL}..."
    details=$(get_instance_details "$region" "$instance_id")
    
    name_tag=$(echo "$details" | jq -r .Name)
    env_tag=$(echo "$details" | jq -r .Env)
    
    # --- Production/Criticality Safety Check ---
    local is_critical=false
    local reason=""
    
    # Check 1: 3rd last letter of Name tag is 'p' (case-insensitive)
    if [ ${#name_tag} -ge 3 ]; then
        third_last_char="${name_tag: -3:1}"
        if [[ "$third_last_char" =~ [pP] ]]; then
            is_critical=true
            reason="Name tag '${name_tag}' contains 'p' at the 3rd to last position."
        fi
    fi
    
    # Check 2: Environment tag is 'prod' or 'UPPER' (case-insensitive)
    if [[ "$env_tag" =~ ^[Pp][Rr][Oo][Dd]$ || "$env_tag" == "UPPER" ]]; then
        is_critical=true
        reason="Environment tag is set to '${env_tag}'."
    fi
    
    local proceed=false
    if $is_critical; then
        echo "${RED}${BOLD}==================== WARNING ====================${NORMAL}"
        echo "${RED}A critical server has been detected based on its tags:${NORMAL}"
        echo "  - ${BOLD}Instance ID:${NORMAL} $instance_id"
        echo "  - ${BOLD}Name Tag:${NORMAL} $name_tag"
        echo "  - ${BOLD}Environment Tag:${NORMAL} $env_tag"
        echo "  - ${BOLD}Reason:${NORMAL} $reason"
        echo "${RED}${BOLD}=================================================${NORMAL}"
        read -p "${BOLD}Are you sure you want to $action this instance? [y/n]: ${NORMAL}" confirmation
        if [[ "$confirmation" =~ ^[Yy]$ ]]; then
            proceed=true
        fi
    else
        # Not critical, proceed without confirmation
        proceed=true
    fi
    
    if $proceed; then
        log "INFO" "Issuing $action command for instance ${YELLOW}$instance_id${NORMAL}..."
        aws ec2 "${action}-instances" --region "$region" --instance-ids "$instance_id" > /dev/null
        log "SUCCESS" "Instance ${GREEN}$instance_id${NORMAL} is now $action_ing."
    else
        log "WARN" "Action cancelled for instance ${YELLOW}$instance_id${NORMAL}."
    fi
    echo "--------------------------------------------------"
}
 
# --- Main Script Logic ---
echo "${BOLD}AWS EC2 Instance Management Utility${NORMAL}"
echo "1. START instances"
echo "2. STOP instances"
echo "3. REBOOT instances"
read -p "${BOLD}Enter your choice (1, 2, or 3): ${NORMAL}" action_choice
 
case "$action_choice" in
    1)
        start_instances
        ;;
    2)
        perform_action "stop" "stopping"
        ;;
    3)
        perform_action "reboot" "rebooting"
        ;;
    *)
        log "ERROR" "Invalid choice. Please run the script again and enter 1, 2, or 3."
        exit 1
        ;;
esac

