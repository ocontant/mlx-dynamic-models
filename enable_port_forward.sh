#!/bin/bash

# enable_port_forward.sh
# A minimal script to enable port forwarding from 443 to a specified port
# Without making permanent changes to the system

# Default target port (where traffic is forwarded to)
TARGET_PORT=11433
FROM_PORT=443

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --to-port)
      TARGET_PORT="$2"
      shift # past argument
      shift # past value
      ;;
    --from-port)
      FROM_PORT="$2"
      shift # past argument
      shift # past value
      ;;
    --help|-h)
      echo "Usage: $0 [options]"
      echo ""
      echo "Options:"
      echo "  --to-port PORT      Target port for forwarding (default: 11433)"
      echo "  --from-port PORT    Source port for forwarding (default: 443)"
      echo "  --help, -h          Show this help message"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      echo "Use --help for usage information"
      exit 1
      ;;
  esac
done

echo "Enabling port forwarding from port $FROM_PORT to port $TARGET_PORT..."

# Create a temporary pf configuration file
TMP_PF_CONF=$(mktemp)
cat > $TMP_PF_CONF << EOF
# Temporary port forwarding ruleset
# Forward port $FROM_PORT to port $TARGET_PORT
# This configuration makes minimal changes to the system

# Set skip on loopback interface
set skip on lo0

# Port forwarding rule
rdr pass inet proto tcp from any to any port $FROM_PORT -> 127.0.0.1 port $TARGET_PORT
EOF

# Enable pf if not already enabled (without changing the main ruleset)
PF_STATUS=$(sudo pfctl -s info 2>/dev/null | grep Status)
if [[ "$PF_STATUS" != *"Enabled"* ]]; then
  echo "Enabling packet filter..."
  sudo pfctl -E 2>/dev/null || true
fi

# Add our rule (without affecting existing rules)
echo "Setting up port forwarding rule..."
sudo pfctl -a com.litellm.portforward -f $TMP_PF_CONF

# Verify it was applied
echo "Verifying configuration..."
sudo pfctl -a com.litellm.portforward -s nat

# Cleanup the temporary file
rm $TMP_PF_CONF

echo ""
echo "Port forwarding is now active."
echo "Traffic to port $FROM_PORT will be forwarded to port $TARGET_PORT"
echo ""
echo "To disable port forwarding, run: 'sudo pfctl -a com.litellm.portforward -F all'"
echo "Or reboot your system (all changes are temporary)"
echo ""
echo "Note: This does not affect your macOS firewall settings."