import addon_utils
import bpy


def enable_mcp():
    repos = bpy.context.preferences.extensions.repos
    repo = next((repo for repo in repos if repo.module == "blender_mcp"), None)
    if repo is None:
        repo = repos.new(
            name="Blender MCP",
            module="blender_mcp",
            custom_directory="/opt/blender-user-scripts/extensions",
            source="SYSTEM",
        )
    repo.enabled = True
    repo.use_custom_directory = True
    repo.custom_directory = "/opt/blender-user-scripts/extensions"
    # The official addon requires online access even for its loopback socket.
    bpy.context.preferences.system.use_online_access = True
    module = addon_utils.enable(
        "bl_ext.blender_mcp.mcp", default_set=True, persistent=True
    )
    if module is None:
        raise RuntimeError("Blender MCP extension could not be enabled")
    prefs = bpy.context.preferences.addons[module.__name__].preferences
    prefs.host = "127.0.0.1"
    prefs.port = 9876
    if module.mcp_to_blender_server.is_running():
        bpy.ops.blmcp.server_stop()
    result = bpy.ops.blmcp.server_start()
    if result != {"FINISHED"} or not module.mcp_to_blender_server.is_running():
        raise RuntimeError("Blender MCP did not start")
    print("Blender MCP ready on loopback port 9876", flush=True)


def register():
    # Background exports must not compete with the interactive socket listener.
    if not bpy.app.background:
        bpy.app.timers.register(enable_mcp, first_interval=1.0)


def unregister():
    if bpy.app.timers.is_registered(enable_mcp):
        bpy.app.timers.unregister(enable_mcp)
