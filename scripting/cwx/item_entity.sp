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
		
		// Allow quality / level override by updating through the offset.
		char netClass[64];
		GetEntityNetClass(weapon, netClass, sizeof(netClass));
		SetEntData(weapon, FindSendPropInfo(netClass, "m_iEntityQuality"), 6);
		SetEntData(weapon, FindSendPropInfo(netClass, "m_iEntityLevel"), 1);
		
		SetEntProp(weapon, Prop_Send, "m_iEntityQuality", 6);
		SetEntProp(weapon, Prop_Send, "m_iEntityLevel", 1);
		
		DispatchSpawn(weapon);
	}
	return weapon;
}

/**
 * Removes the given item based on its loadout slot.
 */
bool TF2_RemoveItemByLoadoutSlot(int client, int loadoutSlot) {
	int item = TF2_GetPlayerLoadoutSlot(client, loadoutSlot);
	if (!IsValidEntity(item)) {
		return false;
	}
	
	if (TF2_IsWearable(item)) {
		TF2_RemoveWearable(client, item);
	} else {
		TF2_RemoveWeaponSlot(client, TF2Util_GetWeaponSlot(item));
	}
	return true;
}

/**
 * Equips the given econ item.
 */
void TF2_EquipPlayerEconItem(int client, int item) {
	char weaponClass[64];
	GetEntityClassname(item, weaponClass, sizeof(weaponClass));
	
	if (StrContains(weaponClass, "tf_wearable", false) == 0) {
		TF2_EquipPlayerWearable(client, item);
	} else {
		EquipPlayerWeapon(client, item);
		TF2_ResetWeaponAmmo(item);
		
		int ammoType = GetEntProp(item, Prop_Send, "m_iPrimaryAmmoType");
		if (ammoType != -1) {
			SetEntProp(item, Prop_Send, "m_iClip1", TF2Util_GetWeaponMaxClip(item));
		}
	}
}
