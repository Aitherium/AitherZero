import sys
import yaml
import json
import os

def load_config():
    # Try to find services.yaml relative to this script
    # Script is in AitherZero/library/helpers/
    # Config is in AitherOS/config/services.yaml
    # Depth: ../../../AitherOS/config/services.yaml
    
    current_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.abspath(os.path.join(current_dir, "../../../"))
    config_path = os.path.join(project_root, "AitherOS", "config", "services.yaml")
    
    if not os.path.exists(config_path):
        # Try absolute fallback if running different context
        config_path = r"d:\AitherOS-Fresh\AitherOS\config\services.yaml"
        
    if not os.path.exists(config_path):
        print(json.dumps({"error": f"Config not found at {config_path}"}))
        sys.exit(1)
        
    try:
        with open(config_path, 'r', encoding='utf-8') as f:
            data = yaml.safe_load(f)
            
        # Extract services part
        services = data.get('services', {})
        
        # Flatten for CLI easier usage
        output = {
            "services": services
        }
        print(json.dumps(output))
    except Exception as e:
        print(json.dumps({"error": str(e)}))
        sys.exit(1)

if __name__ == "__main__":
    load_config()
