/**
 * Contains functionality for the item config.
 */

#include <stocksoup/files>

enum struct CustomItemDefinition {
	KeyValues source;
	
	char uid[MAX_ITEM_IDENTIFIER_LENGTH];
	int defindex;
	char displayName[128];
	KeyValues localizedNames;
	char className[128];
	int loadoutPosition[NUM_PLAYER_CLASSES];
	
	char access[64];
	
	KeyValues nativeAttributes;
	KeyValues customAttributes;
	
	bool bKeepStaticAttributes;
	
	void Init() {
		this.defindex = TF_ITEMDEF_DEFAULT;
		this.source = new KeyValues("Item");
		for (int i; i < sizeof(CustomItemDefinition::loadoutPosition); i++) {
			this.loadoutPosition[i] = -1;
		}
	}
	
	void Destroy() {
		delete this.source;
		delete this.nativeAttributes;
		delete this.customAttributes;
		delete this.localizedNames;
	}
	
	/**
	 * If one exists, returns a copy of the contents of a named "extdata" subsection for the
	 * item.  Returns null otherwise.
	 */
	KeyValues GetExtData(const char[] name) {
		if (!this.source.JumpToKey("extdata", false)) {
			return null;
		}
		
		KeyValues result;
		if (this.source.JumpToKey(name, false)) {
			result = new KeyValues(name);
			result.Import(this.source);
			this.source.GoBack();
		}
		this.source.GoBack();
		return result;
	}
}

/**
 * Holds a uid to CustomItemDefinition mapping.
 */
static StringMap g_CustomItems;

void LoadCustomItemConfig() {
	KeyValues itemSchema = new KeyValues("Items");
	
	// tracks the first file a given item UID was found in, used for duplicate UID warning
	StringMap origFileSource = new StringMap();
	
	// find files within `configs/cwx/` for importing
	char schemaDir[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, schemaDir, sizeof(schemaDir), "configs/%s", "cwx");
	
	ArrayList configFiles = GetFilesInDirectoryRecursive(schemaDir);
	
	// insert legacy format at head
	char schemaPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, schemaPath, sizeof(schemaPath), "configs/%s", "cwx_schema.txt");
	configFiles.ShiftUp(0);
	configFiles.SetString(0, schemaPath);
	
	for (int i, n = configFiles.Length; i < n; i++) {
		configFiles.GetString(i, schemaPath, sizeof(schemaPath));
		NormalizePathToPOSIX(schemaPath);
		
		// skip files in directories named "disabled", much like SourceMod
		if (StrContains(schemaPath, "/disabled/") != -1) {
			continue;
		}
		
		KeyValues importKV = new KeyValues("import");
		importKV.ImportFromFile(schemaPath);
		
		char uid[MAX_ITEM_IDENTIFIER_LENGTH];
		importKV.GotoFirstSubKey(false);
		do {
			importKV.GetSectionName(uid, sizeof(uid));
			if (importKV.GetDataType(NULL_STRING) == KvData_None) {
				if (itemSchema.JumpToKey(uid)) {
					char conflictPath[PLATFORM_MAX_PATH];
					origFileSource.GetString(uid, conflictPath, sizeof(conflictPath));
					LogMessage("Item uid %s first loaded from '%s', ignoring entry in '%s'",
							uid, conflictPath, schemaPath);
				} else {
					itemSchema.JumpToKey(uid, true);
					itemSchema.Import(importKV);
					origFileSource.SetString(uid, schemaPath);
				}
				itemSchema.GoBack();
			}
		} while (importKV.GotoNextKey(false));
		importKV.GoBack();
		
		delete importKV;
	}
	delete configFiles;
	delete origFileSource;
	
	// clean up old items
	if (g_CustomItems) {
		char uid[MAX_ITEM_IDENTIFIER_LENGTH];
		
		StringMapSnapshot itemList = GetCustomItemList();
		for (int i; i < itemList.Length; i++) {
			itemList.GetKey(i, uid, sizeof(uid));
			
			CustomItemDefinition item;
			GetCustomItemDefinition(uid, item);
			
			item.Destroy();
		}
		delete itemList;
	}
	
	delete g_CustomItems;
	g_CustomItems = new StringMap();
	
	if (itemSchema.GotoFirstSubKey()) {
		// we have items, go parse 'em
		do {
			CreateItemFromSection(itemSchema);
		} while (itemSchema.GotoNextKey());
		itemSchema.GoBack();
		
		BuildEquipMenu();
	} else {
		LogError("No custom items available.");
	}
	delete itemSchema;
	
	// TODO process other config logic here.
}

bool CreateItemFromSection(KeyValues config) {
	CustomItemDefinition item;
	item.Init();
	
	item.source.Import(config);
	
	config.GetSectionName(item.uid, sizeof(item.uid));
	
	config.GetString("name", item.displayName, sizeof(item.displayName));
	
	char inheritFromItem[64];
	config.GetString("inherits", inheritFromItem, sizeof(inheritFromItem));
	int inheritDef = FindItemByName(inheritFromItem);
	
	// populate values for the 'inherit' entry, if any
	if (inheritDef != TF_ITEMDEF_DEFAULT) {
		item.defindex = inheritDef;
		TF2Econ_GetItemClassName(inheritDef, item.className, sizeof(item.className));
	} else if (inheritFromItem[0]) {
		LogError("Item uid '%s' inherits from unknown item '%s'", item.uid, inheritFromItem);
		item.Destroy();
		return false;
	}
	
	// apply inherited overrides
	item.defindex = config.GetNum("defindex", item.defindex);
	config.GetString("item_class", item.className, sizeof(item.className), item.className);
	
	if (!item.className[0]) {
		LogError("Item uid '%s' has no classname", item.uid);
		item.Destroy();
		return false;
	}
	
	if (item.defindex == TF_ITEMDEF_DEFAULT) {
		LogError("Item uid '%s' has no item definition", item.uid);
		item.Destroy();
		return false;
	}
	
	// compute slots based on inherited itemdef if we have it, else defindex
	ComputeEquipSlotPosition(config,
			inheritDef == TF_ITEMDEF_DEFAULT? item.defindex : inheritDef, item.loadoutPosition);
	
	config.GetString("item_class", item.className, sizeof(item.className), item.className);
	
	item.bKeepStaticAttributes = !!config.GetNum("keep_static_attrs", true);
	
	// allows restricting access to the item
	config.GetString("access", item.access, sizeof(item.access));
	
	if (config.JumpToKey("attributes_game")) {
		// validate that the attributes actually exist
		// we don't throw a complete failure here since it can be injected later
		if (config.GotoFirstSubKey(false)) {
			do {
				char key[256];
				config.GetSectionName(key, sizeof(key));
				
				if (TF2Econ_TranslateAttributeNameToDefinitionIndex(key) == -1) {
					LogError("Item uid '%s' references non-existent attribute '%s'", item.uid, key);
				}
			} while (config.GotoNextKey(false));
			config.GoBack();
		}
		
		item.nativeAttributes = new KeyValues("attributes_game");
		item.nativeAttributes.Import(config);
		
		config.GoBack();
	}
	
	if (config.JumpToKey("attributes_custom")) {
		item.customAttributes = new KeyValues("attributes_custom");
		item.customAttributes.Import(config);
		config.GoBack();
	}
	
	if (config.JumpToKey("localized_name")) {
		item.localizedNames = new KeyValues("localized_name");
		item.localizedNames.Import(config);
		config.GoBack();
	}
	
	g_CustomItems.SetArray(item.uid, item, sizeof(item));
	return true;
}

bool GetCustomItemDefinition(const char[] uid, CustomItemDefinition item) {
	return g_CustomItems.GetArray(uid, item, sizeof(item));
}

StringMapSnapshot GetCustomItemList() {
	return g_CustomItems.Snapshot();
}

/**
 * Builds the loadout position array for the item, so the plugin knows which weapons can be
 * rendered in loadout menus and which loadout slot they will be stored in within the database.
 */
static bool ComputeEquipSlotPosition(KeyValues kv, int itemdef,
		int loadoutPosition[NUM_PLAYER_CLASSES]) {
	char uid[MAX_ITEM_IDENTIFIER_LENGTH];
	kv.GetSectionName(uid, sizeof(uid));
	
	if (kv.JumpToKey("used_by_classes")) {
		char playerClassNames[][] = {
				"", "scout", "sniper", "soldier", "demoman",
				"medic", "heavy", "pyro", "spy", "engineer"
		};
		
		for (TFClassType i = TFClass_Scout; i <= TFClass_Engineer; i++) {
			char slotName[16];
			kv.GetString(playerClassNames[i], slotName, sizeof(slotName));
			loadoutPosition[i] = TF2Econ_TranslateLoadoutSlotNameToIndex(slotName);
		}
		
		kv.GoBack();
		return true;
	}
	
	if (!TF2Econ_IsValidItemDefinition(itemdef)) {
		LogError("Item uid '%s' is missing a valid item definition index or 'inherits' item "
				... "name is invalid", uid);
		return false;
	}
	
	for (TFClassType i = TFClass_Scout; i <= TFClass_Engineer; i++) {
		loadoutPosition[i] = TF2Econ_GetItemLoadoutSlot(itemdef, i);
	}
	return true;
}

/**
 * Equips an item from the given CustomItemDefinition instance.
 * Returns the item entity if successful.
 */
int EquipCustomItem(int client, const CustomItemDefinition item) {
	char itemClass[128];
	
	strcopy(itemClass, sizeof(itemClass), item.className);
	TF2Econ_TranslateWeaponEntForClass(itemClass, sizeof(itemClass),
			TF2_GetPlayerClass(client));
	
	// create our item
	int itemEntity = TF2_CreateItem(item.defindex, itemClass);
	
	if (!IsFakeClient(client)) {
		// prevent item from being thrown in resupply
		int accountid = GetSteamAccountID(client);
		if (accountid) {
			SetEntProp(itemEntity, Prop_Send, "m_iAccountID", accountid);
		}
	}

	if(!item.bKeepStaticAttributes) {
		TF2Attrib_RemoveAll(itemEntity);

		char valueType[2];
		char valueFormat[64];

		int staticAttribs[16];
		float staticAttribsValues[16];

		TF2Attrib_GetStaticAttribs(item.defindex, staticAttribs, staticAttribsValues);

		for(int i = 0; i < 16; i++)
		{
			if(staticAttribs[i] == 0)
				continue;

			// Probably overkill
			if(staticAttribs[i] == 796 || staticAttribs[i] == 724 || staticAttribs[i] == 817 || staticAttribs[i] == 834 
				|| staticAttribs[i] == 745 || staticAttribs[i] == 731 || staticAttribs[i] == 746)
				continue;

			// "stored_as_integer" is absent from the attribute schema if its type is "string".
			// TF2ED_GetAttributeDefinitionString returns false if it can't find the given string.
			if(!TF2Econ_GetAttributeDefinitionString(staticAttribs[i], "stored_as_integer", valueType, sizeof(valueType)))
				continue;

			TF2Econ_GetAttributeDefinitionString(staticAttribs[i], "description_format", valueFormat, sizeof(valueFormat));

			// Since we already know what we're working with and what we're looking for, we can manually handpick
			// the most significative chars to check if they match. Eons faster than doing StrEqual or StrContains.

			if(valueFormat[9] == 'a' && valueFormat[10] == 'd') // value_is_additive & value_is_additive_percentage
			{
				TF2Attrib_SetByDefIndex(itemEntity, staticAttribs[i], 0.0);
			}
			else if((valueFormat[9] == 'i' && valueFormat[18] == 'p')
				|| (valueFormat[9] == 'p' && valueFormat[10] == 'e')) // value_is_percentage & value_is_inverted_percentage
			{
				TF2Attrib_SetByDefIndex(itemEntity, staticAttribs[i], 1.0);
			}
			else if(valueFormat[9] == 'o' && valueFormat[10] == 'r') // value_is_or
			{
				TF2Attrib_SetByDefIndex(itemEntity, staticAttribs[i], 0.0);
			}
		}
	}
	
	// apply game attributes
	if (item.nativeAttributes) {
		if (item.nativeAttributes.GotoFirstSubKey(false)) {
			do {
				char key[256], value[256];
				
				// TODO: support multiline KeyValues
				// keyvalues are case-insensitive, so section name + value would sidestep that
				item.nativeAttributes.GetSectionName(key, sizeof(key));
				item.nativeAttributes.GetString(NULL_STRING, value, sizeof(value));
				
				// this *almost* feels illegal.
				TF2Attrib_SetFromStringValue(itemEntity, key, value);
			} while (item.nativeAttributes.GotoNextKey(false));
			item.nativeAttributes.GoBack();
		}
	}
	
	// add a stinky attribute that holds the item's uid
	// this value is read with CWX_GetItemUIDFromEntity
	TF2Attrib_SetFromStringValue(itemEntity, ATTRIB_NAME_CUSTOM_UID, item.uid);
	
	// apply attributes for Custom Attributes
	if (item.customAttributes) {
		TF2CustAttr_UseKeyValues(itemEntity, item.customAttributes);
	}
	
	// remove existing item(s) on player
	bool bRemovedWeaponInSlot;
	if (TF2Util_IsEntityWeapon(itemEntity)) {
		// replace item by slot for cross-class equip compatibility
		int weaponSlot = TF2Util_GetWeaponSlot(itemEntity);
		bRemovedWeaponInSlot = IsValidEntity(GetPlayerWeaponSlot(client, weaponSlot));
		TF2_RemoveWeaponSlot(client, weaponSlot);
	}
	
	// we didn't remove a weapon by its weapon slot; remove item based on loadout slot
	if (!bRemovedWeaponInSlot) {
		int loadoutSlot = item.loadoutPosition[TF2_GetPlayerClass(client)];
		if (loadoutSlot == -1) {
			loadoutSlot = TF2Econ_GetItemDefaultLoadoutSlot(item.defindex);
			if (loadoutSlot == -1) {
				return INVALID_ENT_REFERENCE;
			}
		}
		
		// HACK: remove the correct item for demoman when applying the revolver
		if (TF2Util_IsEntityWeapon(itemEntity)
				&& TF2Econ_GetItemLoadoutSlot(item.defindex, TF2_GetPlayerClass(client)) == -1) {
			loadoutSlot = TF2Util_GetWeaponSlot(itemEntity);
		}
		
		TF2_RemoveItemByLoadoutSlot(client, loadoutSlot);
	}
	TF2_EquipPlayerEconItem(client, itemEntity);
	return itemEntity;
}

/**
 * Returns the item definition index given a name, or TF_ITEMDEF_DEFAULT if not found.
 */
static int FindItemByName(const char[] name) {
	if (!name[0]) {
		return TF_ITEMDEF_DEFAULT;
	}
	
	static StringMap s_ItemDefsByName;
	if (s_ItemDefsByName) {
		int value = TF_ITEMDEF_DEFAULT;
		return s_ItemDefsByName.GetValue(name, value)? value : TF_ITEMDEF_DEFAULT;
	}
	
	s_ItemDefsByName = new StringMap();
	
	ArrayList itemList = TF2Econ_GetItemList();
	char nameBuffer[64];
	for (int i, nItems = itemList.Length; i < nItems; i++) {
		int itemdef = itemList.Get(i);
		TF2Econ_GetItemName(itemdef, nameBuffer, sizeof(nameBuffer));
		s_ItemDefsByName.SetValue(nameBuffer, itemdef);
	}
	delete itemList;
	
	return FindItemByName(name);
}
