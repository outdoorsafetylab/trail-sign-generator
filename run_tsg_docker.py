#!/usr/bin/env python3
import os
import subprocess
from gooey import Gooey, GooeyParser

@Gooey(
    program_name="TSG Docker Runner",
    menu=[{
        'name': 'Help',
        'items': [{
            'type': 'AboutDialog',
            'menuTitle': 'About',
            'name': 'TSG Docker Runner',
            'description': 'A small GUI to run the TSG Docker image.',
            'version': '1.0',
        }]
    }]
)
def main():
    parser = GooeyParser(description="Run Docker with the TSG container")

    # 1) PWD: Working directory (default to script's location)
    parser.add_argument(
        "PWD",
        metavar="Working Directory ($PWD)",
        help="Select the working directory you want to mount into the container",
        widget="DirChooser",
        default=os.path.dirname(os.path.abspath(__file__)),
    )

    # 2) YAML_CONFIG: Only the filename (no path)
    parser.add_argument(
        "YAML_CONFIG",
        metavar="YAML Config ($YAML_CONFIG)",
        help="Select the YAML configuration file (inside the Trail Directory)",
        widget="FileChooser",
    )

    # Optional arguments
    parser.add_argument(
        "--docker_image",
        metavar="Docker Image",
        help="Docker image name to use (defaults to 'rudychung/tsg')",
        default="rudychung/tsg",
        required=False,
    )

    parser.add_argument(
        "--term",
        metavar="TERM Environment Variable",
        help="TERM environment variable for Docker container (default: 'xterm')",
        default="xterm",
        required=False,
    )

    args = parser.parse_args()

    # Post-processing
    args.YAML_CONFIG = os.path.relpath(args.YAML_CONFIG, args.PWD)

    # Build the final Docker command
    command = [
        "docker", "run",
        "--rm",
        "--user", "builder",
        "-v", f"{args.PWD}:/home/builder/workdir",
        "-e", f"TERM={args.term}",
        args.docker_image,
        args.YAML_CONFIG
    ]

    print("Executing command:")
    print(" ".join(command))
    
    # Run the Docker command
    try:
        subprocess.run(command, check=True)
    except subprocess.CalledProcessError as e:
        print(f"Error: {e}")

if __name__ == "__main__":
    main()
