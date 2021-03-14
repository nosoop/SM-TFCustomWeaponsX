/**
 * [TF2] Custom Weapons X
 */
#pragma semicolon 1
#include <sourcemod>

#pragma newdecls required

#include <tf2wearables>
#include <tf_econ_data>
#include <stocksoup/convars>
#include <stocksoup/math>
#include <stocksoup/tf/econ>
#include <stocksoup/tf/entity_prop_stocks>
#include <stocksoup/tf/weapon>
#include <tf2attributes>
#include <tf_custom_attributes>
#include <tf2utils>
#include <clientprefs>
#include <dhooks>

public Plugin myinfo = {
	name = "[TF2] Custom Weapons X",
	author = "nosoop",
	description = "Allows server operators to design their own weapons.",
	version = "X.0.5",
	url = "https://github.com/nosoop/SM-TFCustomWeaponsX"
}

// enum struct custom_item_entry_t {
	// KeyValues m_hKeyValues;
// };

// this is the maximum expected length of our UID
#define MAX_ITEM_IDENTIFIER_LENGTH 64

#define MAX_ITEM_NAME_LENGTH 128

// this is the number of slots allocated to our thing
#define NUM_ITEMS 5

// okay, so we can't use TFClassType even view_as'd
// otherwise it'll warn on array-based enumstruct
#define NUM_PLAYER_CLASSES 10

// StringMap g_CustomItems; // <identifier, custom_item_entry_t>

bool g_bRetrievedLoadout[MAXPLAYERS + 1];
char g_CurrentLoadout[MAXPLAYERS + 1][NUM_PLAYER_CLASSES][NUM_ITEMS][MAX_ITEM_IDENTIFIER_LENGTH];

int g_CurrentLoadoutEntity[MAXPLAYERS + 1][NUM_PLAYER_CLASSES][NUM_ITEMS];

KeyValues g_CustomItemConfig;

StringMap s_EquipLoadoutPosition;

Cookie g_ItemPersistCookies[NUM_PLAYER_CLASSES][NUM_ITEMS];

#include "cwx/item_entity.sp"
#include "cwx/item_export.sp"
#include "cwx/loadout_radio_menu.sp"

public void OnPluginStart() {
	LoadTranslations("cwx.phrases");
	LoadTranslations("common.phrases");
	LoadTranslations("core.phrases");
	
	Handle hGameConf = LoadGameConfigFile("tf2.custom_weapons_x");
	if (!hGameConf) {
		SetFailState("Failed to load gamedata (tf2.custom_weapons_x).");
	}
	
	Handle dtGetLoadoutItem = DHookCreateFromConf(hGameConf, "CTFPlayer::GetLoadoutItem()");
	DHookEnableDetour(dtGetLoadoutItem, true, OnGetLoadoutItemPost);
	
	delete hGameConf;
	
	
	HookUserMessage(GetUserMessageId("PlayerLoadoutUpdated"), OnPlayerLoadoutUpdated);
	
	CreateVersionConVar("cwx_version", "Custom Weapons X version.");
	
	RegAdminCmd("sm_cwx_equip", EquipItemCmd, ADMFLAG_ROOT);
	RegAdminCmd("sm_cwx_equip_target", EquipItemCmdTarget, ADMFLAG_ROOT);
	
	RegAdminCmd("sm_cwx_export", ExportActiveWeapon, ADMFLAG_ROOT);
	
	// player commands
	RegAdminCmd("sm_cwx", DisplayItems, 0);
	AddCommandListener(DisplayItemsCompat, "sm_c");
	AddCommandListener(DisplayItemsCompat, "sm_cus");
	AddCommandListener(DisplayItemsCompat, "sm_custom");
	
	// TODO: I'd like to use a separate, independent database for this
	// but leveraging the cookie system is easier for now
	char cookieName[64], cookieDesc[128];
	for (int c; c < NUM_PLAYER_CLASSES; c++) {
		for (int i; i < NUM_ITEMS; i++) {
			FormatEx(cookieName, sizeof(cookieName), "cwx_loadout_%d_%d", c, i);
			FormatEx(cookieDesc, sizeof(cookieDesc),
					"CWX loadout entry for class %d in slot %d", c, i);
			g_ItemPersistCookies[c][i] = new Cookie(cookieName, cookieDesc,
					CookieAccess_Private);
		}
	}
	
	for (int i = 1; i <= MaxClients; i++) {
		if (!IsClientConnected(i)) {
			continue;
		}
		OnClientConnected(i);
		
		if (IsClientAuthorized(i)) {
			FetchLoadoutItems(i);
		}
	}
}

public void OnAllPluginsLoaded() {
	BuildLoadoutSlotMenu();
}

public void OnMapStart() {
	LoadCustomItemConfig();
}

/**
 * Clear out per-client inventory from previous player.
 */
public void OnClientConnected(int client) {
	g_bRetrievedLoadout[client] = false;
	for (int c; c < NUM_PLAYER_CLASSES; c++) {
		for (int i; i < NUM_ITEMS; i++) {
			g_CurrentLoadout[client][c][i] = "";
			g_CurrentLoadoutEntity[client][c][i] = INVALID_ENT_REFERENCE;
		}
	}
}

public void OnClientAuthorized(int client, const char[] auth) {
	// TODO request item information from backing storage
	FetchLoadoutItems(client);
}

void FetchLoadoutItems(int client) {
	if (AreClientCookiesCached(client)) {
		OnClientCookiesCached(client);
	}
}

public void OnClientCookiesCached(int client) {
	for (int c; c < NUM_PLAYER_CLASSES; c++) {
		for (int i; i < NUM_ITEMS; i++) {
			g_ItemPersistCookies[c][i].Get(client, g_CurrentLoadout[client][c][i],
					sizeof(g_CurrentLoadout[][][]));
		}
	}
	g_bRetrievedLoadout[client] = true;
}

static void LoadCustomItemConfig() {
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
	
	// TODO add a forward that allows other plugins to hook registered attribute names and
	// precache any resources
	
	BuildEquipMenu();
	ComputeEquipSlotPosition();
	
	// TODO process other config logic here.
}

/**
 * Testing command to equip the given item uid on the player.
 */
Action EquipItemCmd(int client, int argc) {
	if (!client) {
		return Plugin_Continue;
	}
	
	char itemuid[MAX_ITEM_IDENTIFIER_LENGTH];
	GetCmdArgString(itemuid, sizeof(itemuid));
	
	StripQuotes(itemuid);
	TrimString(itemuid);
	
	int item = LookupAndEquipItem(client, itemuid);
	if (!IsValidEntity(item)) {
		ReplyToCommand(client, "Unknown custom item uid %s", itemuid);
	}
	return Plugin_Handled;
}

/**
 * Testing command to equip the given item uid on the specified target.
 */
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
	if (!IsValidEntity(LookupAndEquipItem(target, itemuid))) {
		ReplyToCommand(client, "Unknown custom item uid %s", itemuid);
	}
	return Plugin_Handled;
}

Action OnPlayerLoadoutUpdated(UserMsg msg_id, BfRead msg, const int[] players,
		int playersNum, bool reliable, bool init) {
	int client = msg.ReadByte();
	int playerClass = view_as<int>(TF2_GetPlayerClass(client));
	
	for (int i; i < NUM_ITEMS; i++) {
		if (!g_CurrentLoadout[client][playerClass][i][0]) {
			// no item specified, use default
			continue;
		}
		
		// equip our item if it isn't already equipped
		if (!IsValidEntity(g_CurrentLoadoutEntity[client][playerClass][i])) {
			int entity = LookupAndEquipItem(client, g_CurrentLoadout[client][playerClass][i]);
			g_CurrentLoadoutEntity[client][playerClass][i] = EntIndexToEntRef(entity);
		}
	}
}

/**
 * Item persistence - we return our item's CEconItemView instance when the game looks up our
 * inventory item.  This prevents our custom item from being invalidated when touch resupply.
 */
MRESReturn OnGetLoadoutItemPost(int client, Handle hReturn, Handle hParams) {
	int playerClass = DHookGetParam(hParams, 1);
	int loadoutSlot = DHookGetParam(hParams, 2);
	
	if (loadoutSlot < 0 || loadoutSlot >= NUM_ITEMS) {
		return MRES_Ignored;
	}
	
	int storedItem = g_CurrentLoadoutEntity[client][playerClass][loadoutSlot];
	if (!IsValidEntity(storedItem) || !HasEntProp(storedItem, Prop_Send, "m_Item")) {
		return MRES_Ignored;
	}
	
	Address pStoredItemView = GetEntityAddress(storedItem)
			+ view_as<Address>(GetEntSendPropOffs(storedItem, "m_Item", true));
	
	DHookSetReturn(hReturn, pStoredItemView);
	return MRES_Supercede;
}

/**
 * Saves the current item.
 */
bool SetClientCustomLoadoutItem(int client, const char[] itemuid) {
	// TODO: write item to the class that the player opened the menu with
	int playerClass = view_as<int>(TF2_GetPlayerClass(client));
	
	int position[NUM_PLAYER_CLASSES];
	s_EquipLoadoutPosition.GetArray(itemuid, position, sizeof(position));
	
	int itemSlot = position[playerClass];
	if (0 <= itemSlot < NUM_ITEMS) {
		strcopy(g_CurrentLoadout[client][playerClass][itemSlot],
				sizeof(g_CurrentLoadout[][][]), itemuid);
		g_ItemPersistCookies[playerClass][itemSlot].Set(client, itemuid);
		g_CurrentLoadoutEntity[client][playerClass][itemSlot] = INVALID_ENT_REFERENCE;
	} else {
		return false;
	}
	
	OnClientCustomLoadoutItemModified(client);
	return true;
}

void UnsetClientCustomLoadoutItem(int client, int playerClass, int itemSlot) {
	strcopy(g_CurrentLoadout[client][playerClass][itemSlot],
				sizeof(g_CurrentLoadout[][][]), "");
	g_ItemPersistCookies[playerClass][itemSlot].Set(client, "");
	g_CurrentLoadoutEntity[client][playerClass][itemSlot] = INVALID_ENT_REFERENCE;
	
	OnClientCustomLoadoutItemModified(client);
}

void OnClientCustomLoadoutItemModified(int client) {
	if (!IsPlayerInRespawnRoom(client)) {
		// TODO: notify that the player will get the item when they resup
		
	} else {
		// player is respawned
		TF2_RespawnPlayer(client);
	}
	// NOTE: we don't do active reequip on live players, because that's kind of a mess
	// return LookupAndEquipItem(client, itemuid);
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
		int loadoutSlot = TF2Econ_GetItemLoadoutSlot(itemdef, TF2_GetPlayerClass(client));
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

bool CanPlayerEquipItem(int client, const char[] uid) {
	// TODO hide based on admin overrides
	
	TFClassType playerClass = TF2_GetPlayerClass(client);
	int position[NUM_PLAYER_CLASSES];
	return s_EquipLoadoutPosition.GetArray(uid, position, sizeof(position))
			&& position[playerClass] != -1;
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

static bool IsPlayerInRespawnRoom(int client) {
	float vecMins[3], vecMaxs[3], vecCenter[3];
	GetClientMins(client, vecMins);
	GetClientMaxs(client, vecMaxs);
	
	GetCenterFromPoints(vecMins, vecMaxs, vecCenter);
	return TF2Util_IsPointInRespawnRoom(vecCenter, client, true);
}

// Overrides the default visibility of the item in the loadout menu.
// CWX_SetItemVisibility(int client, const char[] uid, ItemVisibility vis);
