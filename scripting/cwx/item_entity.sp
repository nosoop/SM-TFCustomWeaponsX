/**
 * Functions related to item entities.
 */

/**
 * Creates a weapon for the specified player.
 */
stock int TF2_CreateItem(int defindex, const char[] itemClass) {
	int weapon = CreateEntityByName(itemClass);
	
	if (IsValidEntity(weapon)) {
		SetEntProp(weapon, Prop_Send, "m_iItemDefinitionIndex", defindex);
		SetEntProp(weapon, Prop_Send, "m_bInitialized", 1);
		
		// allow quality / level override by updating through the offset
		// for some reason I've never been able to figure out, this just doesn't render
		// correctly without setting the memory
		char netClass[64];
		GetEntityNetClass(weapon, netClass, sizeof(netClass));
		SetEntData(weapon, FindSendPropInfo(netClass, "m_iEntityQuality"), 6);
		SetEntData(weapon, FindSendPropInfo(netClass, "m_iEntityLevel"), 1);
		
		SetEntProp(weapon, Prop_Send, "m_iEntityQuality", 6);
		SetEntProp(weapon, Prop_Send, "m_iEntityLevel", 1);
		
		// if this is not toggled, then the weapon entity may not be visible
		SetEntProp(weapon, Prop_Send, "m_bValidatedAttachedEntity", true);
		
		DispatchSpawn(weapon);
	}
	return weapon;
}

/**
 * Removes the given item based on its loadout slot.
 */
bool TF2_RemoveItemByLoadoutSlot(int client, int loadoutSlot) {
	int item = TF2Util_GetPlayerLoadoutEntity(client, loadoutSlot);
	
	if (!IsValidEntity(item)) {
		// try harder -- check if any off-class wearable matches, since GPLE only handles native
		for (int i, n = TF2Util_GetPlayerWearableCount(client); i < n; i++) {
			int wearable = TF2Util_GetPlayerWearable(client, i);
			int itemdef = TF2_GetItemDefinitionIndex(wearable);
			if (TF2Econ_GetItemDefaultLoadoutSlot(itemdef) == loadoutSlot) {
				item = wearable;
			}
		}
	}
	
	if (!IsValidEntity(item)) {
		return false;
	}
	
	if (TF2Util_IsEntityWearable(item)) {
		TF2_RemoveWearable(client, item);
	} else {
		TF2_RemoveWeaponSlot(client, TF2Util_GetWeaponSlot(item));
	}
	return true;
}

/**
 * Equips the given econ item.  If the item is a weapon, the ammo and clip are reset to their
 * correct starting capacity.
 */
void TF2_EquipPlayerEconItem(int client, int item) {
	char weaponClass[64];
	GetEntityClassname(item, weaponClass, sizeof(weaponClass));
	
	if (StrContains(weaponClass, "tf_wearable", false) == 0) {
		TF2Util_EquipPlayerWearable(client, item);
	} else {
		EquipPlayerWeapon(client, item);
		TF2_ResetWeaponAmmo(item);
		
		/**
		 * This calls CBaseCombatWeapon::GiveDefaultAmmo(), which sets up the appropriate clip
		 * count.  This mainly handles the case when the `auto_fires_full_clip` attribute class
		 * is present on the item.
		 * 
		 * Hope there aren't any further side effects from calling ActivateEntity; otherwise
		 * we'll have to add support for CBaseCombatWeapon::GiveDefaultAmmo() somewhere.
		 * Probably in TF2 Utils.
		 */
		ActivateEntity(item);
	}
}
