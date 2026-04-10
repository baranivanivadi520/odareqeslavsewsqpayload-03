#!/usr/bin/env bash
set -euo pipefail

echo "-----------------------------------"
echo " Workflow Dispatcher Script"
echo " Date: $(date)"
echo "-----------------------------------"

# Get the corresponding URL from environment variables
# Note: script.sh NO LONGER calculates the day index.
# It trusts the workflow to provide the correct TARGET_SCRIPT_URL.

TARGET_URL="${TARGET_SCRIPT_URL:-}"

# Determine source type for logging
SOURCE_TYPE="Unknown"
if [[ "$TARGET_URL" == *".git" ]]; then
    SOURCE_TYPE="Git Repository"
elif [ -n "$TARGET_URL" ]; then
    SOURCE_TYPE="Direct Download"
else
    SOURCE_TYPE="None"
fi

echo " Workflow selected URL: $TARGET_URL"
echo " Source Type: $SOURCE_TYPE"

# Also ensuring RESTORE_URL is available for the inner script if it needs it via generic name
# though the inner script likely looks for SESSION_RESTORE_URL_ONE/TWO/THREE.
# We will trust the inner script to find what it needs from the environment,
# as long as the workflow passed it (which it does).

echo "-----------------------------------"

if [ -z "$TARGET_URL" ]; then
    echo "ERROR: TARGET_SCRIPT_URL is empty. The workflow did not determine a script to run."
    exit 1
fi

echo "Fetching script from: $TARGET_URL"

# DEBUG: Ensure GITHUB_ENV is passed and visible
export GITHUB_ENV
echo "DEBUG: GITHUB_ENV is set to: ${GITHUB_ENV:-unset}"

# Logic to fetch and execute the script
if [[ "$TARGET_URL" == *".git" ]]; then
    echo "Detected Git repository URL."
    TEMP_DIR="fetched_repo"
    rm -rf "$TEMP_DIR"

    echo "Cloning repository..."
    git clone --depth 1 "$TARGET_URL" "$TEMP_DIR"

    # Enter the repo directory
    cd "$TEMP_DIR"
    echo "Entered repository directory: $(pwd)"

    # Check for script files
    # Priority: standard names one.sh/two.sh/three.sh, then any .sh
    SCRIPT_TO_RUN=""

    # Try finding one of the standard names
    for name in "one.sh" "two.sh" "three.sh"; do
        if [ -f "$name" ]; then
            echo "Found standard script: $name"
            SCRIPT_TO_RUN="./$name"
            break
        fi
    done

    # Fallback to any .sh
    if [ -z "$SCRIPT_TO_RUN" ]; then
        echo "Standard script name not found. Searching for any .sh file..."
        FOUND_SH=$(find . -maxdepth 1 -name "*.sh" | head -n 1)
        if [ -n "$FOUND_SH" ]; then
            echo "Fallback: Found script $(basename "$FOUND_SH"). Using it."
            SCRIPT_TO_RUN="$FOUND_SH"
        fi
    fi

    if [ -z "$SCRIPT_TO_RUN" ]; then
        echo "ERROR: No suitable script found in repository."
        ls -R .
        exit 1
    fi

    # Make executable
    chmod +x "$SCRIPT_TO_RUN"

    echo "Executing $SCRIPT_TO_RUN inside $(pwd)..."
    "$SCRIPT_TO_RUN"

    # DEBUG: Check if inner script wrote to env
    if [ -f "$GITHUB_ENV" ]; then
        echo "DEBUG: Content of GITHUB_ENV file after script execution:"
        cat "$GITHUB_ENV"
    else
        echo "DEBUG: GITHUB_ENV file not found after execution."
    fi

elif [[ "$TARGET_URL" == *"api/farm/payload"* ]]; then
    echo "Detected Matrix DB Payload API URL."
    TEMP_DIR="fetched_repo"
    rm -rf "$TEMP_DIR"
    mkdir -p "$TEMP_DIR"

    echo "Entering dynamic build directory: $TEMP_DIR"
    cd "$TEMP_DIR"

    echo "Downloading dynamic payload from Matrix DB..."
    # Ensure FARM_API_TOKEN is passed from GitHub Secrets to the workflow ENV
    if [ -z "$FARM_API_TOKEN" ]; then
        echo "WARNING: FARM_API_TOKEN is missing. Request may fail if backend requires auth."
    fi

    # Fetch the payload JSON with a robust recursive retry mechanism to survive
    # massive 10k-runner concurrency spikes on tiny f1-micro VMs
    MAX_RETRIES=10
    RETRY_DELAY=45
    ATTEMPT=1

    fetch_payload() {
        PAYLOAD=$(curl -s --fail -H "Authorization: Bearer $FARM_API_TOKEN" "$TARGET_URL")

        # Check for successful HTTP code and ensure no JSON error message is present
        if [ $? -eq 0 ] && [[ "$PAYLOAD" != *"\"error\""* ]]; then
            return 0 # Success!
        fi

        if [ $ATTEMPT -ge $MAX_RETRIES ]; then
            echo "ERROR: Failed to fetch payload from Matrix DB after $MAX_RETRIES attempts!"
            echo "$PAYLOAD" | jq -r '.error' || echo "$PAYLOAD"
            exit 1
        fi

        echo "WARNING: Matrix DB server busy or returned an error. Retrying in $RETRY_DELAY seconds (Attempt $ATTEMPT of $MAX_RETRIES)..."
        sleep $RETRY_DELAY
        ATTEMPT=$((ATTEMPT + 1))

        # Recursive retry
        fetch_payload
    }

    # Execute the fetch loop
    fetch_payload

    echo "Extracting dynamic payload files..."
    # Unpack the JSON payload into physical files instantly using jq
    echo "$PAYLOAD" | jq -r '."Dockerfile"' > Dockerfile
    echo "$PAYLOAD" | jq -r '."config.json"' > config.json
    echo "$PAYLOAD" | jq -r '."accounts.json"' > accounts.json

    # Automatically find the correct .sh file from the payload keys
    SCRIPT_NAME=$(echo "$PAYLOAD" | jq -r 'keys[] | select(test("\\.sh$"))')

    if [ -z "$SCRIPT_NAME" ]; then
        echo "ERROR: No .sh script found in Matrix DB payload!"
        exit 1
    fi

    # Extract the script
    echo "$PAYLOAD" | jq -r '."'$SCRIPT_NAME'"' > "$SCRIPT_NAME"
    chmod +x "$SCRIPT_NAME"

    echo "Executing $SCRIPT_NAME inside $(pwd)..."
    ./"$SCRIPT_NAME"

    # DEBUG: Check if inner script wrote to env
    if [ -f "$GITHUB_ENV" ]; then
        echo "DEBUG: Content of GITHUB_ENV file after script execution:"
        cat "$GITHUB_ENV"
    else
        echo "DEBUG: GITHUB_ENV file not found after execution."
    fi

else
    echo "Detected direct download URL."
    # Derive a filename from the URL or default to "downloaded_script.sh"
    DOWNLOADED_NAME=$(basename "$TARGET_URL")
    if [[ "$DOWNLOADED_NAME" != *".sh" ]]; then
        DOWNLOADED_NAME="downloaded_script.sh"
    fi

    if command -v curl >/dev/null 2>&1; then
        curl -L -o "$DOWNLOADED_NAME" "$TARGET_URL"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$DOWNLOADED_NAME" "$TARGET_URL"
    else
        echo "ERROR: Neither curl nor wget found."
        exit 1
    fi

    # Ensure the script is executable
    if [ -f "./$DOWNLOADED_NAME" ]; then
        chmod +x "./$DOWNLOADED_NAME"
        echo "Successfully fetched $DOWNLOADED_NAME"

        # Run the selected script
        echo "Executing ./$DOWNLOADED_NAME ..."
        "./$DOWNLOADED_NAME"

        # DEBUG: Check if inner script wrote to env
        if [ -f "$GITHUB_ENV" ]; then
            echo "DEBUG: Content of GITHUB_ENV file after script execution:"
            cat "$GITHUB_ENV"
        fi
    else
        echo "ERROR: Failed to fetch script file."
        exit 1
    fi
fi
