#if defined __cwx_included
	#endinput
#endif

#define __cwx_included

/***************************************************************************************
 * Constant definitions below are shared between the core plugin and its dependencies. *
 * Values here should not be rearranged.                                               *
 ***************************************************************************************/

#define LOADOUT_FLAG_UPDATE_BACKEND (1 << 0) // update the item on the backing database, in
                                             // addition to the current session
#define LOADOUT_FLAG_ATTEMPT_REGEN  (1 << 1) // if the player is in a spawn room, perform
                                             // regeneration to refresh the loadout


// End of shared definitions; `CWX_INCLUDE_SHAREDDEFS_ONLY` should only be defined in core.
#if defined CWX_INCLUDE_SHAREDDEFS_ONLY
	#endinput
#endif

/************************************************
 * Start of definitions for dependency plugins. *
 ************************************************/

#include <tf2>

/**
 * Adds the given item to the player's session loadout.  This item will be equipped on the
 * player on next regeneration (spawn / resupply) and persisted until they disconnect.
 */
native bool CWX_SetPlayerLoadoutItem(int client, TFClassType playerClass, const char[] uid,
		int flags = 0);

/**
 * Immediately equips the item onto the target player.  The item is not persisted.
 * 
 * As this happens outside of the standard loadout regeneration flow, unexpected side effects
 * may occur.  Consider using `CWX_SetCustomLoadoutItem` instead.
 * 
 * @return    Item entity reference, or INVALID_ENT_REFERENCE on failure.
 * @error     Client is not in-game or uid is invalid.
 */
native int CWX_EquipPlayerItem(int client, const char[] uid);

/**
 * Returns if the item UID is valid.
 */
native bool CWX_IsItemUIDValid(const char[] uid);

public SharedPlugin __pl_custom_weapons_x = {
	name = "cwx",
	file = "cwx.smx",
#if defined REQUIRE_PLUGIN
	required = 1,
#else
	required = 0,
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_custom_weapons_x_SetNTVOptional() {
	MarkNativeAsOptional("CWX_SetPlayerLoadoutItem");
	MarkNativeAsOptional("CWX_EquipPlayerItem");
	MarkNativeAsOptional("CWX_IsItemUIDValid");
}
#endif
