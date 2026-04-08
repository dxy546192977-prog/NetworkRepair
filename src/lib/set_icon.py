#!/usr/bin/env python3
"""Set macOS Terminal.app icon on the .app bundle."""
import subprocess
import sys
import os
import tempfile
import shutil

ICON_SRC = "/System/Applications/Utilities/Terminal.app/Contents/Resources/Terminal.icns"
TARGET_ICNS = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "..", "Mac双击运行.app", "Contents", "Resources", "AppIcon.icns"
)

def main():
    if not os.path.exists(ICON_SRC):
        print(f"Icon source not found: {ICON_SRC}")
        sys.exit(1)

    target = os.path.normpath(TARGET_ICNS)
    os.makedirs(os.path.dirname(target), exist_ok=True)
    shutil.copy2(ICON_SRC, target)
    print(f"Icon copied to: {target}")

    # Touch the app bundle to refresh Finder icon cache
    app_path = os.path.normpath(os.path.join(target, "..", "..", ".."))
    subprocess.run(["touch", app_path], check=False)
    print("Finder icon cache refreshed")

if __name__ == "__main__":
    main()
