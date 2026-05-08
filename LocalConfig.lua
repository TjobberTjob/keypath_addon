-- Per-install tweaks the companion writes from outside WoW. Loaded
-- last so it overrides anything set by the rest of the addon at file
-- scope. The companion's "Grid pixel size" setting rewrites this file
-- and prompts the user to /reload to pick up the change.
WCLHoverLocalConfig = WCLHoverLocalConfig or {}
WCLHoverLocalConfig.cellSize = 4
