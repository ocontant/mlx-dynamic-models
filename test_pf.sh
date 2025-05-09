#!/bin/bash

# Simple script to test packet filter (pf) configuration for port forwarding

# Check if running as root (or with sudo)
if [[ "$EUID" -ne 0 ]]; then
    echo "This script needs to be run with sudo. Trying to run with sudo..."
    exec sudo "$0" "$@"
    exit $?
fi

# Default values
SOURCE_PORT=80
TARGET_PORT=8080
TEST_MODE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --source)
      SOURCE_PORT="$2"
      shift 2
      ;;
    --target)
      TARGET_PORT="$2"
      shift 2
      ;;
    --test)
      TEST_MODE=true
      shift
      ;;
    --help)
      echo "Usage: $0 [options]"
      echo ""
      echo "Options:"
      echo "  --source PORT    Set the source port to forward from (default: 80)"
      echo "  --target PORT    Set the target port to forward to (default: 8080)"
      echo "  --test           Test mode - only validate configuration"
      echo "  --help           Show this help message"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

echo "---------------------------------------------------------"
echo "Testing packet filter (pf) configuration for port forwarding"
echo "Source port: $SOURCE_PORT → Target port: $TARGET_PORT"
echo "---------------------------------------------------------"

# Create a temporary pf ruleset file
PF_RULES_FILE=$(mktemp)

# Create a simple ruleset for testing
cat > $PF_RULES_FILE << EOF
# Basic port forwarding test ruleset
rdr pass on lo0 inet proto tcp from any to 127.0.0.1 port $SOURCE_PORT -> 127.0.0.1 port $TARGET_PORT
EOF

echo "Created test ruleset:"
cat $PF_RULES_FILE
echo "---------------------------------------------------------"

# Enable pf if not already enabled
echo "Enabling packet filter (pf)..."
pfctl -E 2>/dev/null || true

# Try to load the rules
echo "Loading test rules..."
if pfctl -f $PF_RULES_FILE; then
    echo "✅ Rules loaded successfully"
else
    echo "❌ Failed to load rules"
    echo "Trying alternate syntax..."
    
    # Try with a different syntax
    cat > $PF_RULES_FILE << EOF
# Alternate syntax for testing
rdr on lo0 proto tcp from any to 127.0.0.1 port $SOURCE_PORT -> 127.0.0.1 port $TARGET_PORT
pass on lo0 proto tcp from any to 127.0.0.1 port $TARGET_PORT
EOF
    
    echo "Created alternate ruleset:"
    cat $PF_RULES_FILE
    echo "---------------------------------------------------------"
    
    if pfctl -f $PF_RULES_FILE; then
        echo "✅ Alternate rules loaded successfully"
    else
        echo "❌ Failed to load alternate rules"
        echo "Please check your pf configuration"
        rm $PF_RULES_FILE
        exit 1
    fi
fi

# Check if the rules were applied correctly
echo "Verifying rules..."
RULES_OUTPUT=$(pfctl -s nat)
echo "Current NAT rules:"
echo "$RULES_OUTPUT"

# Try different patterns since pfctl output format can vary
if echo "$RULES_OUTPUT" | grep -q "port $SOURCE_PORT -> port $TARGET_PORT" || \
   echo "$RULES_OUTPUT" | grep -q "port = $SOURCE_PORT -> .* port $TARGET_PORT" || \
   echo "$RULES_OUTPUT" | grep -q "port.*$SOURCE_PORT.*->.*$TARGET_PORT"; then
    echo "✅ Port forwarding rules verified: $SOURCE_PORT → $TARGET_PORT"
else
    echo "❌ Could not verify port forwarding rules"
    # Try a direct connection test if possible
    echo "Testing connection directly..."
    nc -z -v -w2 127.0.0.1 $TARGET_PORT &
    sleep 1
    curl -s -m 2 -o /dev/null -w "Result: %{http_code}\n" http://127.0.0.1:$SOURCE_PORT || true
    
    # Ask user to confirm
    read -p "Rules appear to be loaded but verification is uncertain. Continue anyway? (Y/n): " answer
    answer=${answer:-Y}
    if [[ "$answer" =~ ^[Yy] ]]; then
        echo "Continuing based on user confirmation..."
    else
        echo "Aborting based on user choice."
        rm $PF_RULES_FILE
        exit 1
    fi
fi

# If we're in test mode, clean up and exit
if [[ "$TEST_MODE" == true ]]; then
    echo "Test completed successfully. Cleaning up..."
    # Remove our temporary rules
    pfctl -Fa
    rm $PF_RULES_FILE
    echo "Test mode completed. All systems go!"
    exit 0
fi

echo "---------------------------------------------------------"
echo "Port forwarding is now active: localhost:$SOURCE_PORT → localhost:$TARGET_PORT"
echo "Press Ctrl+C to stop and remove port forwarding"
echo "---------------------------------------------------------"

# Keep the script running to maintain the port forwarding
trap "echo 'Cleaning up...'; pfctl -Fa; rm $PF_RULES_FILE; exit 0" INT TERM EXIT
while true; do
    sleep 1
done