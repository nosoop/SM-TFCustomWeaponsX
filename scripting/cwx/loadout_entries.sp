/**
 * Holds the definition for player inventory data.
 */

enum struct LoadoutEntry {
	char uid[MAX_ITEM_IDENTIFIER_LENGTH];
	
	// loadout entity, for persistence
	// note for the future: we do *not* restore this on late load since the schema may have changed
	int entity;
	
	void SetItemUID(const char[] other_uid) {
		strcopy(this.uid, MAX_ITEM_IDENTIFIER_LENGTH, other_uid);
	}
	
	bool IsEmpty() {
		return !this.uid[0];
	}
	
	void Clear() {
		this.entity = INVALID_ENT_REFERENCE;
		this.uid = "";
	}
	
	bool GetItemDefinition(CustomItemDefinition item) {
		return GetCustomItemDefinition(this.uid, item);
	}
}

LoadoutEntry g_CurrentLoadout[MAXPLAYERS + 1][NUM_PLAYER_CLASSES][NUM_ITEMS];
