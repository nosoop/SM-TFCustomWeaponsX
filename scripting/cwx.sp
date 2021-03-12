/**
 * [TF2] Custom Weapons X
 */
#pragma semicolon 1
#include <sourcemod>

#pragma newdecls required

#include <tf2wearables>
#include <tf_econ_data>
#include <stocksoup/math>
#include <stocksoup/tf/econ>
#include <stocksoup/tf/entity_prop_stocks>
#include <stocksoup/tf/weapon>
#include <tf2attributes>
#include <tf_custom_attributes>
#include <tf2utils>

public Plugin myinfo = {
	name = "[TF2] Custom Weapons X",
	author = "nosoop",
	description = "Allows server operators to design their own weapons.",
	version = "X.0.0",
	url = "https://github.com/nosoop/SM-TFCustomWeaponsX"
}

// enum struct custom_item_entry_t {
	// KeyValues m_hKeyValues;
// };

// this is the maximum expected length of our UID
#define MAX_ITEM_IDENTIFIER_LENGTH 64

// this is the number of slots allocated to our thing
#define NUM_ITEMS 5

// okay, so we can't use TFClassType even view_as'd
// otherwise it'll warn on array-based enumstruct
#define NUM_PLAYER_CLASSES 10

// StringMap g_CustomItems; // <identifier, custom_item_entry_t>

char g_CurrentLoadout[MAXPLAYERS + 1][NUM_ITEMS][MAX_ITEM_IDENTIFIER_LENGTH];

static int g_iPlayerClassInMenu[MAXPLAYERS + 1];
static int g_iPlayerSlotInMenu[MAXPLAYERS + 1];

KeyValues g_CustomItemConfig;
Handle g_SDKCallWeaponSwitch;

static Menu s_LoadoutSlotMenu;

static Menu s_EquipMenu;
static StringMap s_EquipLoadoutPosition;

char g_LocalizedPlayerClass[][] = {
	"TF_Class_Name_Undefined",
	"TF_Class_Name_Scout",
	"TF_Class_Name_Sniper",
	"TF_Class_Name_Soldier",
	"TF_Class_Name_Demoman",
	"TF_Class_Name_Medic",
	"TF_Class_Name_HWGuy",
	"TF_Class_Name_Pyro",
	"TF_Class_Name_Spy",
	"TF_Class_Name_Engineer",
};

char g_LocalizedLoadoutSlots[][] = {
	"LoadoutSlot_Primary",
	"LoadoutSlot_Secondary",
	"LoadoutSlot_Melee",
	"LoadoutSlot_Utility",
	"LoadoutSlot_Building",
	"LoadoutSlot_pda",
	"LoadoutSlot_pda2",
	"LoadoutSlot_PrimaryMod",
	"LoadoutSlot_Head",
	"LoadoutSlot_Misc",
	"LoadoutSlot_Action",
	"LoadoutSlot_Taunt",
	"LoadoutSlot_Taunt2",
	"LoadoutSlot_Taunt3",
	"LoadoutSlot_Taunt4",
	"LoadoutSlot_Taunt5",
	"LoadoutSlot_Taunt6",
	"LoadoutSlot_Taunt7",
	"LoadoutSlot_Taunt8",
	"LoadoutSlot_TauntSlot",
};

public void OnPluginStart() {
	LoadTranslations("cwx.phrases");
	LoadTranslations("common.phrases");
	
	Handle hGameConf = LoadGameConfigFile("sdkhooks.games");
	if (!hGameConf) {
		SetFailState("Failed to load gamedata (sdkhooks.games).");
	}
	
	StartPrepSDKCall(SDKCall_Player);
	PrepSDKCall_SetFromConf(hGameConf, SDKConf_Virtual, "Weapon_Switch");
	PrepSDKCall_AddParameter(SDKType_CBaseEntity, SDKPass_Pointer);
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	g_SDKCallWeaponSwitch = EndPrepSDKCall();
	if (!g_SDKCallWeaponSwitch) {
		SetFailState("Could not initialize call for CTFPlayer::Weapon_Switch");
	}
	
	delete hGameConf;
	
	HookUserMessage(GetUserMessageId("PlayerLoadoutUpdated"), OnPlayerLoadoutUpdated);
	
	RegAdminCmd("sm_cwx", DisplayItems, ADMFLAG_ROOT);
	RegAdminCmd("sm_cwx_equip", EquipItemCmd, ADMFLAG_ROOT);
	RegAdminCmd("sm_cwx_equip_target", EquipItemCmdTarget, ADMFLAG_ROOT);
	
	RegAdminCmd("sm_cwx_export", ExportActiveWeapon, ADMFLAG_ROOT);
}

public void OnAllPluginsLoaded() {
	BuildLoadoutSlotMenu();
}

public void OnMapStart() {
	LoadCustomItemConfig();
}

static void LoadCustomItemConfig() {
	delete g_CustomItemConfig;
	g_CustomItemConfig = new KeyValues("Items");
	
	char schemaPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, schemaPath, sizeof(schemaPath), "configs/%s", "cwx_schema.txt");
	g_CustomItemConfig.ImportFromFile(schemaPath);
	
	// TODO add a forward that allows other plugins to hook registered attribute names and
	// precache any resources
	
	BuildEquipMenu();
	ComputeEquipSlotPosition();
	
	// TODO process other config logic here.
}

Action DisplayItems(int client, int argc) {
	g_iPlayerClassInMenu[client] = view_as<int>(TF2_GetPlayerClass(client));
	s_LoadoutSlotMenu.Display(client, 30);
	return Plugin_Handled;
}

Action EquipItemCmd(int client, int argc) {
	if (!client) {
		return Plugin_Continue;
	}
	
	char itemuid[MAX_ITEM_IDENTIFIER_LENGTH];
	GetCmdArgString(itemuid, sizeof(itemuid));
	
	StripQuotes(itemuid);
	TrimString(itemuid);
	
	if (!LookupAndEquipItem(client, itemuid)) {
		ReplyToCommand(client, "Unknown custom item uid %s", itemuid);
	}
	return Plugin_Handled;
}

Action EquipItemCmdTarget(int client, int argc) {
	if (!client) {
		return Plugin_Continue;
	}
	
	char targetString[64];
	GetCmdArg(1, targetString, sizeof(targetString));
	
	char itemuid[MAX_ITEM_IDENTIFIER_LENGTH];
	GetCmdArg(2, itemuid, sizeof(itemuid));
	
	StripQuotes(itemuid);
	TrimString(itemuid);
	
	int target = FindTarget(client, targetString, .immunity = false);
	if (!LookupAndEquipItem(target, itemuid)) {
		ReplyToCommand(client, "Unknown custom item uid %s", itemuid);
	}
	return Plugin_Handled;
}

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

Action OnPlayerLoadoutUpdated(UserMsg msg_id, BfRead msg, const int[] players,
		int playersNum, bool reliable, bool init) {
	int client = msg.ReadByte();
	int playerClass = view_as<int>(TF2_GetPlayerClass(client));
	
	// TODO reapply items
}

/**
 * Saves the current item.
 */
bool SetClientCustomLoadoutItem(int client, const char[] itemuid) {
	// TODO: write item to the class that the player opened the menu with
	int playerClass = view_as<int>(TF2_GetPlayerClass(client));
	
	int position[NUM_PLAYER_CLASSES];
	s_EquipLoadoutPosition.GetArray(itemuid, position, sizeof(position));
	if (0 <= position[playerClass] < NUM_ITEMS) {
		strcopy(g_CurrentLoadout[client][position[playerClass]], sizeof(g_CurrentLoadout[][]),
				itemuid);
	} else {
		return false;
	}
	
	if (!IsPlayerInRespawnRoom(client)) {
		// TODO: notify that the player will get the item when they resup
		return true;
	} else {
		// TODO respawn instead of giving the item instantly
	}
	
	if (!itemuid[0]) {
		// TODO restore default item
		return true;
	}
	return LookupAndEquipItem(client, itemuid);
}

bool LookupAndEquipItem(int client, const char[] itemuid) {
	g_CustomItemConfig.Rewind();
	if (g_CustomItemConfig.JumpToKey(itemuid)) {
		EquipCustomItem(client, g_CustomItemConfig);
		
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
		
		return true;
	}
	return false;
}

/**
 * Equips an item from the given KeyValues structure.
 */
void EquipCustomItem(int client, KeyValues customItemDefinition) {
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
		return;
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
		return;
	}
	
	if (itemdef == TF_ITEMDEF_DEFAULT) {
		char customItemName[64], sectionName[64];
		customItemDefinition.GetString("name", customItemName, sizeof(customItemName),
				"(none)");
		customItemDefinition.GetSectionName(sectionName, sizeof(sectionName));
		
		LogError("Custom item %s (uid %s) was not defined with a valid definition index.",
				customItemName, sectionName);
		return;
	}
	
	TF2Econ_TranslateWeaponEntForClass(itemClass, sizeof(itemClass),
			TF2_GetPlayerClass(client));
	
	// create our item
	int itemEntity = TF2_CreateItem(itemdef, itemClass);
	
	bool bKeepStaticAttrs = !!customItemDefinition.GetNum("keep_static_attrs", true);
	SetEntProp(itemEntity, Prop_Send, "m_bOnlyIterateItemViewAttributes", !bKeepStaticAttrs);
	
	// apply game attributes
	if (customItemDefinition.JumpToKey("attributes_game")) {
		if (customItemDefinition.GotoFirstSubKey(false)) {
			do {
				char key[256], value[256];
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
	
	// TODO retrieve our loadout slot
	//      check what entity is present with TF2_GetPlayerLoadoutSlot
	//      unequip as appropriate then equip our item
	
	// TODO remove wearable when applying weapon and vice-versa
	if (!TF2_IsWearable(itemEntity)) {
		int slot = TF2Util_GetWeaponSlot(itemEntity);
		int existingEntity = GetPlayerWeaponSlot(client, slot);
		if (IsValidEntity(existingEntity)) {
			RemoveEntity(existingEntity);
		}
		
		EquipPlayerWeapon(client, itemEntity);
		
		if (TF2_GetClientActiveWeapon(client) == existingEntity) {
			SetActiveWeapon(client, itemEntity);
		}
		TF2_ResetWeaponAmmo(itemEntity);
	} else {
		// TODO we should check m_hWearables instead of using GetPlayerLoadoutSlot
		int activeWearable = TF2_GetPlayerLoadoutSlot(client,
				TF2Econ_GetItemLoadoutSlot(itemdef, TF2_GetPlayerClass(client)));
		// TODO remove based on loadout slot?
		if (IsValidEntity(activeWearable)) {
			RemoveEntity(activeWearable);
		}
		TF2_EquipPlayerWearable(client, itemEntity);
	}
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

static void SetActiveWeapon(int client, int weapon) {
	int hActiveWeapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if (IsValidEntity(hActiveWeapon)) {
		bool bResetParity = !!GetEntProp(hActiveWeapon, Prop_Send, "m_bResetParity");
		SetEntProp(hActiveWeapon, Prop_Send, "m_bResetParity", !bResetParity);
	}
	
	SDKCall(g_SDKCallWeaponSwitch, client, weapon, 0);
}

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

/**
 * Determines visibility of items in the loadout menu.
 */
static bool ItemVisibleInEquipMenu(int client, const char[] uid) {
	TFClassType playerClass = TF2_GetPlayerClass(client);
	int position[NUM_PLAYER_CLASSES];
	
	// not visible for current submenu
	s_EquipLoadoutPosition.GetArray(uid, position, sizeof(position));
	if (position[playerClass] != g_iPlayerSlotInMenu[client]) {
		return false;
	}
	
	return CanPlayerEquipItem(client, uid);
}

static bool CanPlayerEquipItem(int client, const char[] uid) {
	// TODO hide based on admin overrides
	
	TFClassType playerClass = TF2_GetPlayerClass(client);
	int position[NUM_PLAYER_CLASSES];
	return s_EquipLoadoutPosition.GetArray(uid, position, sizeof(position))
			&& position[playerClass] != -1;
}

static void BuildLoadoutSlotMenu() {
	delete s_LoadoutSlotMenu;
	s_LoadoutSlotMenu = new Menu(OnLoadoutSlotMenuEvent,
			MENU_ACTIONS_DEFAULT | MenuAction_Display | MenuAction_DisplayItem);
	
	for (int i; i < 3; i++) {
		char name[32];
		TF2Econ_TranslateLoadoutSlotIndexToName(i, name, sizeof(name));
		s_LoadoutSlotMenu.AddItem(name, name);
	}
}

/**
 * Builds the weapon list menu used for players to equip weapons.  Visibility of an item is
 * toggled so they show up only for the correct class / loadout slot (see OnEquipMenuEvent).
 */
static void BuildEquipMenu() {
	delete s_EquipMenu;
	
	if (!g_CustomItemConfig.GotoFirstSubKey()) {
		return;
	}
	
	s_EquipMenu = new Menu(OnEquipMenuEvent, MENU_ACTIONS_ALL);
	s_EquipMenu.ExitBackButton = true;
	
	s_EquipMenu.AddItem("", "[Unequip custom weapon]");
	
	do {
		// iterate over subsections and add name / uid pair to menu
		char uid[MAX_ITEM_IDENTIFIER_LENGTH];
		char name[128];
		
		g_CustomItemConfig.GetSectionName(uid, sizeof(uid));
		g_CustomItemConfig.GetString("name", name, sizeof(name));
		
		s_EquipMenu.AddItem(uid, name);
	} while (g_CustomItemConfig.GotoNextKey());
	g_CustomItemConfig.Rewind();
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

int OnLoadoutSlotMenuEvent(Menu menu, MenuAction action, int param1, int param2) {
	switch (action) {
		/**
		 * Sets the menu header for the current section.
		 */
		case MenuAction_Display: {
			int client = param1;
			Panel panel = view_as<any>(param2);
			
			SetGlobalTransTarget(client);
			
			char buffer[64];
			FormatEx(buffer, sizeof(buffer), "Custom Weapons X");
			
			panel.SetTitle(buffer);
			
			SetGlobalTransTarget(LANG_SERVER);
		}
		
		/**
		 * Reads the selected loadout slot and displays the weapon selection menu.
		 */
		case MenuAction_Select: {
			int client = param1;
			int position = param2;
			
			char loadoutSlot[32];
			menu.GetItem(position, loadoutSlot, sizeof(loadoutSlot));
			
			g_iPlayerSlotInMenu[client] = TF2Econ_TranslateLoadoutSlotNameToIndex(loadoutSlot);
			s_EquipMenu.Display(client, 30);
		}
		
		/**
		 * Renders the native loadout slot name for the client.
		 */
		case MenuAction_DisplayItem: {
			int client = param1;
			int position = param2;
			
			char loadoutSlotName[64];
			menu.GetItem(position, loadoutSlotName, sizeof(loadoutSlotName));
			
			SetGlobalTransTarget(client);
			int loadoutSlot = TF2Econ_TranslateLoadoutSlotNameToIndex(loadoutSlotName);
			FormatEx(loadoutSlotName, sizeof(loadoutSlotName), "%t ›",
					g_LocalizedLoadoutSlots[loadoutSlot]);
			SetGlobalTransTarget(LANG_SERVER);
			
			return RedrawMenuItem(loadoutSlotName);
		}
	}
	return 0;
}

int OnEquipMenuEvent(Menu menu, MenuAction action, int param1, int param2) {
	switch (action) {
		/**
		 * Sets the menu title for the current section (as the player class / loadout slot).
		 */
		case MenuAction_Display: {
			int client = param1;
			Panel panel = view_as<any>(param2);
			
			SetGlobalTransTarget(client);
			
			char buffer[64];
			FormatEx(buffer, sizeof(buffer), "%t » %t",
					g_LocalizedPlayerClass[g_iPlayerClassInMenu[client]],
					g_LocalizedLoadoutSlots[g_iPlayerSlotInMenu[client]]);
			
			panel.SetTitle(buffer);
			
			SetGlobalTransTarget(LANG_SERVER);
		}
		
		/**
		 * Reads the custom item UID from the menu selection and sets the corresponding item
		 * on the player.
		 */
		case MenuAction_Select: {
			int client = param1;
			int position = param2;
			
			char uid[MAX_ITEM_IDENTIFIER_LENGTH];
			menu.GetItem(position, uid, sizeof(uid));
			
			// TODO: we should be making this a submenu with item description
			SetClientCustomLoadoutItem(client, uid);
		}
		
		/**
		 * Hides items that are not meant for the currently browsed loadout slot and items that
		 * the player cannot equip.
		 */
		case MenuAction_DrawItem: {
			int client = param1;
			int position = param2;
			
			char uid[MAX_ITEM_IDENTIFIER_LENGTH];
			menu.GetItem(position, uid, sizeof(uid));
			
			if (uid[0] && !ItemVisibleInEquipMenu(client, uid)) {
				// remove visibility of item
				return ITEMDRAW_IGNORE;
			}
		}
		
		/**
		 * Return back to the loadout selection menu.
		 */
		case MenuAction_Cancel: {
			int client = param1;
			int reason = param2;
			
			if (reason == MenuCancel_ExitBack) {
				s_LoadoutSlotMenu.Display(client, 30);
			}
		}
	}
	return 0;
}

static bool IsPlayerInRespawnRoom(int client) {
	float vecMins[3], vecMaxs[3], vecCenter[3];
	GetClientMins(client, vecMins);
	GetClientMaxs(client, vecMaxs);
	
	GetCenterFromPoints(vecMins, vecMaxs, vecCenter);
	return TF2Util_IsPointInRespawnRoom(vecCenter, client, true);
}

// Overrides the default visibility of the item in the loadout menu.
// CWX_SetItemVisibility(int client, const char[] uid, ItemVisibility vis);
