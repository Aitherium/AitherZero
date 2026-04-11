# ostree.ks - Kickstart for AgenticOS Provisioning
lang en_US.UTF-8
keyboard us
timezone UTC --utc

# Network information
network --bootproto=dhcp --device=link --activate

# Root password (for debugging, disable in production or use SSH keys)
rootpw --plaintext rocky

# User setup
user --name=core --groups=wheel --password=foobar --plaintext

# Reboot after installation
reboot

# Use text mode install
text

# Partitioning
clearpart --all --initlabel
autopart

# OSTree Setup
# Pulls the 'rocky/9/x86_64/agentic-os' ref from the local repo server
ostreesetup --nogpg --osname=agentic-os --remote=agentic-os --url=http://10.0.2.2:8000/repo/ --ref=rocky/9/x86_64/agentic-os

%post
# Post-installation configuration
echo "AgenticOS Provisioned via AitherZero" > /etc/issue.d/agentic-os.issue
%end
