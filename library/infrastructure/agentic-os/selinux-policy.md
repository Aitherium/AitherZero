# Multi-Agent Isolation Policy Generation

To enforce strict security isolation for "The Constructs" (Agents), we use `udica` to generate custom SELinux policies based on container inspection.

## Policy Generation Workflow

1. **Run the Agent Container (Inspection Mode):**
    Start the agent container with a temporary name to inspect its requirements.

    ```bash
    podman run --name terra-agent-inspect -d \
      -v /etc/agent-config:/etc/agent-config:ro \
      -v /var/log/terra:/var/log/terra:rw \
      rocky/agentic-os:latest /bin/sleep 1000
    ```

2. **Generate SELinux Policy (`.cil`):**
    Use `podman inspect` to get the container's JSON definition and pipe it to `udica`. We also pass the custom capability requirements defined in `terra-agent.json`.

    ```bash
    podman inspect terra-agent-inspect > container.json
    udica -j container.json -f terra-agent.json terra_agent_policy
    ```

3. **Load the Policy:**
    Install the generated policy module into the kernel.

    ```bash
    semodule -i terra_agent_policy.cil /usr/share/udica/templates/base_container.cil
    ```

4. **Apply Policy to Agent:**
    Restart the agent container with the new security label.

    ```bash
    podman stop terra-agent-inspect
    podman rm terra-agent-inspect
    podman run --name terra-agent \
      --security-opt label=type:terra_agent_policy.process \
      -v /etc/agent-config:/etc/agent-config:ro \
      -v /var/log/terra:/var/log/terra:rw \
      rocky/agentic-os:latest
    ```

## Verification

Check that the process is running with the correct context:

```bash
ps -eZ | grep terra_agent
```
