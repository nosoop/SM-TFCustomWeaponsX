/**
 * Contains functionality for the item config.
 */

KeyValues g_CustomItemConfig;

StringMap s_EquipLoadoutPosition;

void LoadCustomItemConfig() {
	delete g_CustomItemConfig;
	g_CustomItemConfig = new KeyValues("Items");
	
	char schemaPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, schemaPath, sizeof(schemaPath), "configs/%s", "cwx_schema.txt");
	g_CustomItemConfig.ImportFromFile(schemaPath);
	
	char schemaDir[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, schemaDir, sizeof(schemaDir), "configs/%s", "cwx/");
	DirectoryListing cwxConfigs = OpenDirectory(schemaDir, false);
	
	if (cwxConfigs) {
		// find files within `configs/cwx/` and import them, too
		FileType ftype;
		char schemaRelPath[PLATFORM_MAX_PATH];
		while (cwxConfigs.GetNext(schemaRelPath, sizeof(schemaRelPath), ftype)) {
			if (ftype != FileType_File) {
				continue;
			}
			
			BuildPath(Path_SM, schemaPath, sizeof(schemaPath), "configs/cwx/%s", schemaRelPath);
			
			KeyValues importKV = new KeyValues("import");
			importKV.ImportFromFile(schemaPath);
			
			char uid[MAX_ITEM_IDENTIFIER_LENGTH];
			importKV.GotoFirstSubKey(false);
			do {
				importKV.GetSectionName(uid, sizeof(uid));
				if (importKV.GetDataType(NULL_STRING) == KvData_None) {
					if (g_CustomItemConfig.JumpToKey(uid)) {
						LogMessage("Item uid %s already exists in schema, ignoring entry in %s",
								uid, schemaRelPath);
					} else {
						g_CustomItemConfig.JumpToKey(uid, true);
						g_CustomItemConfig.Import(importKV);
					}
					g_CustomItemConfig.GoBack();
				}
			} while (importKV.GotoNextKey(false));
			importKV.GoBack();
			
			delete importKV;
		}
	}
	
	// TODO parse into enum structure
	
	// TODO add a forward that allows other plugins to hook registered attribute names and
	// precache any resources
	
	BuildEquipMenu();
	ComputeEquipSlotPosition();
	
	// TODO process other config logic here.
}

/**
 * Builds the UID-to-loadout-position mapping, so the plugin knows which weapons can be rendered
 * in which menus.
 */
static void ComputeEquipSlotPosition() {
	delete s_EquipLoadoutPosition;
	
	if (!g_CustomItemConfig.GotoFirstSubKey()) {
		return;
	}
	
	s_EquipLoadoutPosition = new StringMap();
	do {
		// iterate over subsections and add name / uid pair to menu
		char uid[MAX_ITEM_IDENTIFIER_LENGTH];
		char inheritFromItem[128];
		
		g_CustomItemConfig.GetSectionName(uid, sizeof(uid));
		
		if (g_CustomItemConfig.JumpToKey("used_by_classes")) {
			char playerClassNames[][] = {
					"", "scout", "sniper", "soldier", "demoman",
					"medic", "heavy", "pyro", "spy", "engineer"
			};
			
			int classLoadoutPosition[NUM_PLAYER_CLASSES];
			for (TFClassType i = TFClass_Scout; i <= TFClass_Engineer; i++) {
				char slotName[16];
				g_CustomItemConfig.GetString(playerClassNames[i], slotName, sizeof(slotName));
				classLoadoutPosition[i] = TF2Econ_TranslateLoadoutSlotNameToIndex(slotName);
			}
			
			s_EquipLoadoutPosition.SetArray(uid,
					classLoadoutPosition, sizeof(classLoadoutPosition));
			
			g_CustomItemConfig.GoBack();
			continue;
		}
		
		int itemdef = TF_ITEMDEF_DEFAULT;
		if (g_CustomItemConfig.GetString("inherits", inheritFromItem, sizeof(inheritFromItem))) {
			itemdef = FindItemByName(inheritFromItem);
		}
		
		if (itemdef == TF_ITEMDEF_DEFAULT) {
			// we don't have an inherits, so assume the item is based on defindex
			itemdef = g_CustomItemConfig.GetNum("defindex", TF_ITEMDEF_DEFAULT);
		}
		
		if (!TF2Econ_IsValidItemDefinition(itemdef)) {
			// TODO: implement schema section for loadout slot
			LogError("Item uid %s is missing a valid item definition index or 'inherits' item "
					... "name is invalid", uid);
			continue;
		}
		
		int classLoadoutPosition[NUM_PLAYER_CLASSES];
		for (TFClassType i = TFClass_Scout; i <= TFClass_Engineer; i++) {
			classLoadoutPosition[i] = TF2Econ_GetItemLoadoutSlot(itemdef, i);
		}
		
		s_EquipLoadoutPosition.SetArray(uid,
				classLoadoutPosition, sizeof(classLoadoutPosition));
	} while (g_CustomItemConfig.GotoNextKey());
	g_CustomItemConfig.Rewind();
}

int LookupAndEquipItem(int client, const char[] itemuid) {
	g_CustomItemConfig.Rewind();
	if (g_CustomItemConfig.JumpToKey(itemuid)) {
		return EquipCustomItem(client, g_CustomItemConfig);
		
		// TODO store the uid as part of our active loadout for persistence
		// 
		// problem is, we don't know which slot to install it to based on classname alone,
		// so we need to either:
		// - generate the item and store its slot post-generation (we should only need to do this once per uid)
		// - infer based on "inherits" (whose presence isn't guaranteed, leading to...)
		// - manually define the loadout slot (icky. don't fucking trust config writers to get
		//   this correct, ever.)
		// 
		// valve manually defines loadout slots in their schema.
		// 
		// I think inherits + manual definition fallback is the way to go, just so we don't have
		// to deal with runtime shenanigans.
	}
	return INVALID_ENT_REFERENCE;
}

/**
 * Equips an item from the given KeyValues structure.
 * Returns the item entity if successful.
 */
int EquipCustomItem(int client, KeyValues customItemDefinition) {
	char inheritFromItem[64];
	customItemDefinition.GetString("inherits", inheritFromItem, sizeof(inheritFromItem));
	int inheritDef = FindItemByName(inheritFromItem);
	
	char itemClass[128];
	int itemdef = TF_ITEMDEF_DEFAULT;
	
	// populate values for the 'inherit' entry, if any
	if (inheritDef != TF_ITEMDEF_DEFAULT) {
		itemdef = inheritDef;
		TF2Econ_GetItemClassName(inheritDef, itemClass, sizeof(itemClass));
	} else if (inheritFromItem[0]) {
		// we have an 'inherit' entry, but it doesn't point to a valid item...
		// drop everything and walk away.
		char customItemName[64], sectionName[64];
		customItemDefinition.GetString("name", customItemName, sizeof(customItemName),
				"(none)");
		customItemDefinition.GetSectionName(sectionName, sizeof(sectionName));
		
		LogError("Custom item %s (uid %s) inherits from unknown item '%s'", customItemName,
				sectionName, inheritFromItem);
		return INVALID_ENT_REFERENCE;
	}
	
	// apply inherited overrides
	itemdef = customItemDefinition.GetNum("defindex", itemdef);
	customItemDefinition.GetString("item_class", itemClass, sizeof(itemClass), itemClass);
	
	if (!itemClass[0]) {
		char customItemName[64], sectionName[64];
		customItemDefinition.GetString("name", customItemName, sizeof(customItemName),
				"(none)");
		customItemDefinition.GetSectionName(sectionName, sizeof(sectionName));
		LogError("Custom item %s (uid %s) is missing classname", customItemName, sectionName);
		return INVALID_ENT_REFERENCE;
	}
	
	if (itemdef == TF_ITEMDEF_DEFAULT) {
		char customItemName[64], sectionName[64];
		customItemDefinition.GetString("name", customItemName, sizeof(customItemName),
				"(none)");
		customItemDefinition.GetSectionName(sectionName, sizeof(sectionName));
		
		LogError("Custom item %s (uid %s) was not defined with a valid definition index.",
				customItemName, sectionName);
		return INVALID_ENT_REFERENCE;
	}
	
	TF2Econ_TranslateWeaponEntForClass(itemClass, sizeof(itemClass),
			TF2_GetPlayerClass(client));
	
	// create our item
	int itemEntity = TF2_CreateItem(itemdef, itemClass);
	
	if (!IsFakeClient(client)) {
		// prevent item from being thrown in resupply
		int accountid = GetSteamAccountID(client);
		if (accountid) {
			SetEntProp(itemEntity, Prop_Send, "m_iAccountID", accountid);
		}
	}
	
	// TODO: implement a version that nullifies runtime attributes to their defaults
	bool bKeepStaticAttrs = !!customItemDefinition.GetNum("keep_static_attrs", true);
	SetEntProp(itemEntity, Prop_Send, "m_bOnlyIterateItemViewAttributes", !bKeepStaticAttrs);
	
	// apply game attributes
	if (customItemDefinition.JumpToKey("attributes_game")) {
		if (customItemDefinition.GotoFirstSubKey(false)) {
			do {
				char key[256], value[256];
				
				// TODO: support multiline KeyValues
				// keyvalues are case-insensitive, so section name + value should sidestep that
				customItemDefinition.GetSectionName(key, sizeof(key));
				customItemDefinition.GetString(NULL_STRING, value, sizeof(value));
				
				// this *almost* feels illegal.
				TF2Attrib_SetFromStringValue(itemEntity, key, value);
			} while (customItemDefinition.GotoNextKey(false));
			customItemDefinition.GoBack();
		}
		customItemDefinition.GoBack();
	}
	
	// apply attributes for Custom Attributes
	if (customItemDefinition.JumpToKey("attributes_custom")) {
		TF2CustAttr_UseKeyValues(itemEntity, customItemDefinition);
		customItemDefinition.GoBack();
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
		char uid[MAX_ITEM_IDENTIFIER_LENGTH];
		customItemDefinition.GetSectionName(uid, sizeof(uid));
		
		int position[NUM_PLAYER_CLASSES];
		s_EquipLoadoutPosition.GetArray(uid, position, sizeof(position));
		
		int loadoutSlot = position[TF2_GetPlayerClass(client)];
		if (loadoutSlot == -1) {
			loadoutSlot = TF2Econ_GetItemDefaultLoadoutSlot(itemdef);
			if (loadoutSlot == -1) {
				return INVALID_ENT_REFERENCE;
			}
		}
		
		// HACK: remove the correct item for demoman when applying the revolver
		if (TF2Util_IsEntityWeapon(itemEntity)
				&& TF2Econ_GetItemLoadoutSlot(itemdef, TF2_GetPlayerClass(client)) == -1) {
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
