#if defined __cwx_included
	#endinput
#endif

#define __cwx_included

/***************************************************************************************
 * Constant definitions below are shared between the core plugin and its dependencies. *
 * Values here should not be rearranged.                                               *
 ***************************************************************************************/

#define LOADOUT_FLAG_UPDATE_BACKEND (1 << 0) // update the item on the backing database, in
                                             // addition to the current session -- if this is
                                             // not set, the item will be treated as a temporary
                                             // override
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
 * Callback for `CWX_GetItemList`.  Return `true` if the specified custom item UID should be
 * added to the returned `ArrayList`.
 */
typedef CWXItemFilterCriteria = function bool(const char[] uid, any data);

/**
 * Adds the given item to the player's session loadout.  This item will be equipped on the
 * player on next regeneration (spawn / resupply) and persisted until they disconnect.
 * 
 * The loadout slot is determined based on the item definition.
 */
native bool CWX_SetPlayerLoadoutItem(int client, TFClassType playerClass, const char[] uid,
		int flags = 0);

/**
 * Removes the item from a player's session loadout.
 */
native void CWX_RemovePlayerLoadoutItem(int client, TFClassType playerClass, int itemSlot,
		int flags = 0);

/**
 * Retrieves the UID active in a player's session loadout.
 */
native bool CWX_GetPlayerLoadoutItem(int client, TFClassType playerClass, int itemSlot,
		char[] uid, int uidLen, int flags = 0);

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
 * Checks if the player has access to the given item.
 * 
 * @return    Whether or not the client can normally use the item.
 */
native bool CWX_CanPlayerAccessItem(int client, const char[] uid);

/**
 * Returns an ArrayList containing all valid item UIDs.  If a CWXItemFilterCriteria callback is
 * passed in, the ArrayList only contains UIDs that the callback returned `true` on.
 * 
 * This handle is owned by the calling plugin, so it should be `delete`d when not needed
 * anymore.
 * 
 * @return    ArrayList containing strings.
 */
native ArrayList CWX_GetItemList(CWXItemFilterCriteria func = INVALID_FUNCTION, any data = 0);

/**
 * Validates that the given item UID is found in CWX's item list.
 */
native bool CWX_IsItemUIDValid(const char[] uid);

/**
 * Retrieves an item's UID, if one exists.
 *
 * @return    True if the item has an associated UID, false if not.  (Note that the item UID is
 *            not tested for validity within the plugin's known items - use CWX_IsItemUIDValid
 *            if necessary.)
 * @error     Entity is not an item.
 */
native bool CWX_GetItemUIDFromEntity(int entity, char[] buffer, int maxlen);

/**
 * Returns the item's loadout slot for the given class, or -1 if the item UID or item / class
 * combination is not valid.
 */
native int CWX_GetItemLoadoutSlot(const char[] uid, TFClassType playerClass);

/**
 * Retrieves a copy of a custom item definition's "extended data" section by name, if one
 * exists.  This handle should be freed by the calling plugin.
 * 
 * @return    A KeyValues handle containing the custom item definition's extended data named
 *            subsection, or `null` if the custom item definition or subsection does not exist.
 */
native KeyValues CWX_GetItemExtData(const char[] uid, const char[] section);

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
	MarkNativeAsOptional("CWX_GetItemUIDFromEntity");
	MarkNativeAsOptional("CWX_GetItemExtData");
}
#endif
