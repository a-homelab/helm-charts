import addon_utils
import bpy


def enable_mcp():
    addon_utils.enable("blender_mcp", default_set=False, persistent=True)
    server = getattr(bpy.types, "blendermcp_server", None)
    if server is None or not server.running:
        raise RuntimeError("Blender MCP did not start")
    print("Blender MCP ready on loopback port 9876", flush=True)


def register():
    # Background exports must not compete with the interactive socket listener.
    if not bpy.app.background:
        bpy.app.timers.register(enable_mcp, first_interval=1.0)


def unregister():
    if bpy.app.timers.is_registered(enable_mcp):
        bpy.app.timers.unregister(enable_mcp)
