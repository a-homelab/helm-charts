import argparse
import json
import sys
from pathlib import Path

import bpy


def verify():
    parser = argparse.ArgumentParser()
    parser.add_argument("--backend", choices=["CUDA", "OPTIX"], default="CUDA")
    parser.add_argument("--output", default="/tmp/blender-gpu-check.png")
    args = parser.parse_args(sys.argv[sys.argv.index("--") + 1 :])
    preferences = bpy.context.preferences.addons["cycles"].preferences
    preferences.compute_device_type = args.backend
    preferences.refresh_devices()
    selected = []
    for device in preferences.devices:
        device.use = device.type == args.backend
        if device.use:
            selected.append(device.name)
    if not selected:
        raise RuntimeError(f"No {args.backend} devices available; CPU fallback refused")

    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.device = "GPU"
    scene.cycles.samples = 8
    scene.render.resolution_x = 64
    scene.render.resolution_y = 64
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.filepath = args.output
    bpy.ops.render.render(write_still=True)
    if not Path(args.output).is_file():
        raise RuntimeError("GPU render produced no image")
    print(
        json.dumps({"backend": args.backend, "devices": selected, "image": args.output})
    )


if __name__ == "__main__":
    verify()
