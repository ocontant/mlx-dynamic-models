#!/bin/bash

# Simple script to test port forwarding from 443 to a specific port
PORT=${1:-11429}  # Default to port 11432 if none provided
HTTPS_PORT=${2:-11430}

echo "Creating port forwarding from 80 -> ${PORT}..."

# Create a simple PF rule file
TMP_RULE_FILE=$(mktemp)
cat > $TMP_RULE_FILE << EOF
# Simple redirect rule for testing
pass in quick on lo0 inet proto tcp from any to 127.0.0.1 port 443 rdr-to 127.0.0.1 port ${PORT}
EOF

echo "Rule contents:"
cat $TMP_RULE_FILE

# Make sure PF is enabled
echo "Enabling packet filter..."
sudo pfctl -e

# Load the rule
echo "Loading rule..."
sudo pfctl -f $TMP_RULE_FILE

# Check if the rule was applied
echo "Checking if rule was applied:"
sudo pfctl -s nat

# Clean up
rm $TMP_RULE_FILE

echo "Starting netcat listener on port ${PORT}..."
echo "Press Ctrl+C to exit"
echo "In another terminal, try: curl -v https://127.0.0.1/"

# Start a simple listener on the target port to test
nc -l ${PORT} &
curl -v http://127.0.0.1/ && echo $?