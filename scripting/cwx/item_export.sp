/**
 * Functions related to exporting items.
 */

/**
 * Exports the currently active weapon to an item config file in CWX schema format.
 */
Action ExportActiveWeapon(int client, int argc) {
	// TODO we should allow loadout slot selection
	int weapon = TF2_GetClientActiveWeapon(client);
	if (!IsValidEntity(weapon)) {
		ReplyToCommand(client, "No active weapon to export.");
		return Plugin_Handled;
	}
	
	char uuid_rendered[64], uuid_bracketed[64];
	GenerateUUID4(uuid_rendered, sizeof(uuid_rendered));
	FormatEx(uuid_bracketed, sizeof(uuid_bracketed), "{%s}", uuid_rendered);
	
	KeyValues exportedWeapon = new KeyValues("ItemExport");
	exportedWeapon.JumpToKey(uuid_bracketed, true);
	
	{
		// client can specify a custom display name to export with
		char displayName[64];
		if (argc > 1) {
			GetCmdArg(2, displayName, sizeof(displayName));
		} else {
			// use name based on uuid for the server operator to fix up later
			strcopy(displayName, sizeof(displayName), uuid_rendered);
		}
		exportedWeapon.SetString("name", displayName);
	}
	
	{
		// assume the item inherits based on itemdef
		int defindex = TF2_GetItemDefinitionIndex(weapon);
		char itemName[64];
		TF2Econ_GetItemName(defindex, itemName, sizeof(itemName));
		
		exportedWeapon.SetString("inherits", itemName);
	}
	
	{
		// export our native attributes
		exportedWeapon.JumpToKey("attributes_game", true);
		
		// TODO: we should implement native accessors iterating runtime attribs in tf2attributes
		int attrdefs[32];
		int nAttrs = TF2Attrib_ListDefIndices(weapon, attrdefs, sizeof(attrdefs));
		for (int i = 0; i < nAttrs; i++) {
			Address pAttrib = TF2Attrib_GetByDefIndex(weapon, attrdefs[i]);
			if (!pAttrib) {
				continue;
			}
			
			char attrName[128];
			TF2Econ_GetAttributeName(attrdefs[i], attrName, sizeof(attrName));
			
			any attrValue = TF2Attrib_GetValue(pAttrib);
			
			char attribType[64];
			if (TF2Econ_GetAttributeDefinitionString(attrdefs[i], "attribute_type",
					attribType, sizeof(attribType)) && StrEqual(attribType, "string")) {
				// not the most ideal detection method but it'll do
				char attrStrValue[128];
				TF2Attrib_UnsafeGetStringValue(attrValue, attrStrValue, sizeof(attrStrValue));
				exportedWeapon.SetString(attrName, attrStrValue);
			} else {
				// everything else that matters are float values
				exportedWeapon.SetFloat(attrName, attrValue);
			}
		}
		exportedWeapon.GoBack();
	}
	
	KeyValues kv = TF2CustAttr_GetAttributeKeyValues(weapon);
	if (kv) {
		// export our custom attributes
		exportedWeapon.JumpToKey("attributes_custom", true);
		exportedWeapon.Import(kv);
		
		delete kv;
		exportedWeapon.GoBack();
	}
	
	exportedWeapon.Rewind();
	
	char filePath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, filePath, sizeof(filePath), "configs/cwx/%s.cfg", uuid_rendered);
	
	exportedWeapon.ExportToFile(filePath);
	
	ReplyToCommand(client, "Exported active weapon to %s", filePath);
	delete exportedWeapon;
	
	return Plugin_Handled;
}

/**
 * Generates a UUIDv4.
 */
static void GenerateUUID4(char[] buffer, int maxlen) {
	int uuid[4];
	for (int i; i < sizeof(uuid); i++) {
		uuid[i] = GetURandomInt();
	}
	
	FormatEx(buffer, maxlen, "%08x-%04x-%04x-%04x-%04x%08x",
			uuid[0],
			(uuid[1] >>> 16) & 0xFFFF, (uuid[1] & 0xFFFF),
			(uuid[2] >>> 16) & 0xFFFF, (uuid[2] & 0xFFFF),
			uuid[3]);
}
