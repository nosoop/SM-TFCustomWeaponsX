/**
 * Holds the definition for player inventory data.
 */

enum struct LoadoutEntry {
	char uid[MAX_ITEM_IDENTIFIER_LENGTH];
	
	// overload UID -- used when plugins want to take priority over user preference
	char override_uid[MAX_ITEM_IDENTIFIER_LENGTH];
	
	// loadout entity, for persistence
	// note for the future: we do *not* restore this on late load since the schema may have changed
	int entity;
	
	void SetItemUID(const char[] other_uid) {
		strcopy(this.uid, MAX_ITEM_IDENTIFIER_LENGTH, other_uid);
	}
	
	void SetOverloadItemUID(const char[] other_uid) {
		strcopy(this.override_uid, MAX_ITEM_IDENTIFIER_LENGTH, other_uid);
	}
	
	/**
	 * Returns the custom item definition associated with the given loadout entry.  Any overload
	 * (i.e., external plugin-granted) item that is set will take priority.
	 */
	bool GetItemDefinition(CustomItemDefinition item) {
		return GetCustomItemDefinition(this.override_uid, item)
				|| GetCustomItemDefinition(this.uid, item);
	}
	
	/**
	 * Returns true if the given loadout entry does not have a custom item assigned.
	 */
	bool IsEmpty() {
		return !(this.override_uid[0] || this.uid[0]);
	}
	
	void Clear(bool initialize = false) {
		this.entity = INVALID_ENT_REFERENCE;
		this.uid = "";
		
		if (initialize) {
			this.override_uid = "";
		}
	}
}

LoadoutEntry g_CurrentLoadout[MAXPLAYERS + 1][NUM_PLAYER_CLASSES][NUM_ITEMS];
