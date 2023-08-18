/**
 * [TF2] Custom Weapons X
 */
#pragma semicolon 1
#include <sourcemod>

#pragma newdecls required

#include <tf_econ_data>
#include <stocksoup/convars>
#include <stocksoup/handles>
#include <stocksoup/math>
#include <stocksoup/tf/econ>
#include <stocksoup/tf/entity_prop_stocks>
#include <stocksoup/tf/weapon>
#include <tf2attributes>
#include <tf_custom_attributes>
#include <tf2utils>
#include <clientprefs>
#include <dhooks>

#define CWX_INCLUDE_SHAREDDEFS_ONLY
#include <cwx>

#tryinclude <autoversioning/version>
#if defined __ninjabuild_auto_version_included
	#define VERSION_SUFFIX "-" ... GIT_COMMIT_SHORT_HASH
#else
	#define VERSION_SUFFIX ""
#endif

public Plugin myinfo = {
	name = "[TF2] Custom Weapons X",
	author = "nosoop",
	description = "Allows server operators to design their own weapons.",
	version = "X.0.10" ... VERSION_SUFFIX,
	url = "https://github.com/nosoop/SM-TFCustomWeaponsX"
}

// this is the maximum expected length of our UID; it is intentional that this is *not* shared
// to dependent plugins, as we may change this at any time
#define MAX_ITEM_IDENTIFIER_LENGTH 64

// this is the maximum length of the item name displayed to players
#define MAX_ITEM_NAME_LENGTH 128

// this is the number of slots allocated to our thing
#define NUM_ITEMS 7

// okay, so we can't use TFClassType even view_as'd
// otherwise it'll warn on array-based enumstruct
#define NUM_PLAYER_CLASSES 10

// we're recycling the following attribute to ensure that the item UID persists across dropped
// weapons - it's kinda icky and if anyone else happened to get the same idea it'd be bad, but
// it's the best we've got without trying TOO hard
// TODO: rework this in the future to optionally use an injected attribute?
#define ATTRIB_NAME_CUSTOM_UID "random drop line item unusual list"

bool g_bRetrievedLoadout[MAXPLAYERS + 1];

Cookie g_ItemPersistCookies[NUM_PLAYER_CLASSES][NUM_ITEMS];

bool g_bForceReequipItems[MAXPLAYERS + 1];

ConVar sm_cwx_enable_loadout;

ConVar mp_stalemate_meleeonly;

#include "cwx/item_config.sp"
#include "cwx/item_entity.sp"
#include "cwx/item_export.sp"
#include "cwx/loadout_entries.sp"
#include "cwx/loadout_radio_menu.sp"

int g_attrdef_AllowedInMedievalMode;

public APLRes AskPluginLoad2(Handle self, bool late, char[] error, int maxlen) {
	RegPluginLibrary("cwx");
	
	CreateNative("CWX_SetPlayerLoadoutItem", Native_SetPlayerLoadoutItem);
	CreateNative("CWX_RemovePlayerLoadoutItem", Native_RemovePlayerLoadoutItem);
	CreateNative("CWX_GetPlayerLoadoutItem", Native_GetPlayerLoadoutItem);
	CreateNative("CWX_EquipPlayerItem", Native_EquipPlayerItem);
	CreateNative("CWX_CanPlayerAccessItem", Native_CanPlayerAccessItem);
	CreateNative("CWX_GetItemList", Native_GetItemList);
	CreateNative("CWX_IsItemUIDValid", Native_IsItemUIDValid);
	CreateNative("CWX_GetItemUIDFromEntity", Native_GetItemUIDFromEntity);
	CreateNative("CWX_GetItemExtData", Native_GetItemExtData);
	CreateNative("CWX_GetItemLoadoutSlot", Native_GetItemLoadoutSlot);
	
	return APLRes_Success;
}

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
	
	Handle dtManageRegularWeapons = DHookCreateFromConf(hGameConf, "CTFPlayer::ManageRegularWeapons()");
	if (!dtManageRegularWeapons) {
		SetFailState("Failed to create detour %s", "CTFPlayer::ManageRegularWeapons()");
	}
	DHookEnableDetour(dtManageRegularWeapons, false, OnManageRegularWeaponsPre);
	DHookEnableDetour(dtManageRegularWeapons, true, OnManageRegularWeaponsPost);
	
	delete hGameConf;
	
	HookEvent("player_spawn", OnPlayerSpawnPost);
	HookUserMessage(GetUserMessageId("PlayerLoadoutUpdated"), OnPlayerLoadoutUpdated,
			.post = OnPlayerLoadoutUpdatedPost);
	
	CreateVersionConVar("cwx_version", "Custom Weapons X version.");
	
	sm_cwx_enable_loadout = CreateConVar("sm_cwx_enable_loadout", "1",
			"Allows players to receive custom items they have selected.");
	
	RegAdminCmd("sm_cwx_export", ExportActiveWeapon, ADMFLAG_ROOT);
	
	// player commands
	RegAdminCmd("sm_cwx", DisplayItems, 0);
	AddCommandListener(DisplayItemsCompat, "sm_c");
	AddCommandListener(DisplayItemsCompat, "sm_cus");
	AddCommandListener(DisplayItemsCompat, "sm_custom");
	
	mp_stalemate_meleeonly = FindConVar("mp_stalemate_meleeonly");
	
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
	
	g_attrdef_AllowedInMedievalMode =
			TF2Econ_TranslateAttributeNameToDefinitionIndex("allowed in medieval mode");
}

public void OnMapStart() {
	LoadCustomItemConfig();
	
	PrecacheMenuResources();
}

/**
 * Clear out per-client inventory from previous player.
 */
public void OnClientConnected(int client) {
	g_bRetrievedLoadout[client] = false;
	for (int c; c < NUM_PLAYER_CLASSES; c++) {
		for (int i; i < NUM_ITEMS; i++) {
			g_CurrentLoadout[client][c][i].Clear(.initialize = true);
		}
	}
}

public void OnClientAuthorized(int client, const char[] auth) {
	FetchLoadoutItems(client);
}

/**
 * Called when we know our client is valid.  Retrieve our loadout from our storage backend.
 * 
 * `g_bRetrievedLoadout[client]` should be set once our loadout is retrieved, which may happen
 * asynchronously.
 */
void FetchLoadoutItems(int client) {
	if (AreClientCookiesCached(client)) {
		OnClientCookiesCached(client);
	}
}

public void OnClientCookiesCached(int client) {
	for (int c; c < NUM_PLAYER_CLASSES; c++) {
		for (int i; i < NUM_ITEMS; i++) {
			g_ItemPersistCookies[c][i].Get(client, g_CurrentLoadout[client][c][i].uid,
					sizeof(g_CurrentLoadout[][][].uid));
		}
	}
	g_bRetrievedLoadout[client] = true;
}

// int CWX_EquipPlayerItem(int client, const char[] uid);
int Native_EquipPlayerItem(Handle plugin, int argc) {
	int client = GetNativeCell(1);
	
	char itemuid[MAX_ITEM_IDENTIFIER_LENGTH];
	GetNativeString(2, itemuid, sizeof(itemuid));
	
	CustomItemDefinition item;
	if (!GetCustomItemDefinition(itemuid, item)) {
		return INVALID_ENT_REFERENCE;
	}
	
	int itemEntity = EquipCustomItem(client, item);
	return IsValidEntity(itemEntity)? EntIndexToEntRef(itemEntity) : INVALID_ENT_REFERENCE;
}

// bool CWX_CanPlayerAccessItem(int client, const char[] uid);
int Native_CanPlayerAccessItem(Handle plugin, int argc) {
	int client = GetNativeCell(1);
	
	char itemuid[MAX_ITEM_IDENTIFIER_LENGTH];
	GetNativeString(2, itemuid, sizeof(itemuid));
	
	CustomItemDefinition item;
	if (!GetCustomItemDefinition(itemuid, item)) {
		return false;
	}
	return CanPlayerAccessItem(client, item);
}

// ArrayList CWX_GetItemList(CWXItemFilterCriteria func = INVALID_FUNCTION, any data = 0);
int Native_GetItemList(Handle plugin, int argc) {
	Function func = GetNativeFunction(1);
	any data = GetNativeCell(2);
	
	StringMapSnapshot itemSnapshot = GetCustomItemList();
	
	ArrayList itemList = new ArrayList(ByteCountToCells(MAX_ITEM_IDENTIFIER_LENGTH));
	for (int i, n = itemSnapshot.Length; i < n; i++) {
		char itemuid[MAX_ITEM_IDENTIFIER_LENGTH];
		itemSnapshot.GetKey(i, itemuid, sizeof(itemuid));
		
		if (func == INVALID_FUNCTION) {
			itemList.PushString(itemuid);
			continue;
		}
		
		bool result;
		Call_StartFunction(plugin, func);
		Call_PushString(itemuid);
		Call_PushCell(data);
		Call_Finish(result);
		
		if (result) {
			itemList.PushString(itemuid);
		}
	}
	delete itemSnapshot;
	
	return MoveHandle(itemList, plugin);
}

// bool CWX_IsItemUIDValid(const char[] uid);
int Native_IsItemUIDValid(Handle plugin, int argc) {
	char itemuid[MAX_ITEM_IDENTIFIER_LENGTH];
	GetNativeString(1, itemuid, sizeof(itemuid));
	
	CustomItemDefinition item;
	return GetCustomItemDefinition(itemuid, item);
}

// bool CWX_GetItemUIDFromEntity(int entity, char[] buffer, int maxlen);
int Native_GetItemUIDFromEntity(Handle plugin, int argc) {
	int entity = GetNativeCell(1);
	
	if (!IsValidEntity(entity) || !HasEntProp(entity, Prop_Send, "m_AttributeList")) {
		ThrowNativeError(SP_ERROR_NATIVE, "Entity %d is invalid or not an item", entity);
		return false;
	}
	
	// only pull the value from the runtime attribute list
	Address result = TF2Attrib_GetByName(entity, ATTRIB_NAME_CUSTOM_UID);
	if (!result) {
		return false;
	}
	
	any rawValue = TF2Attrib_GetValue(result);
	
	int maxlen = GetNativeCell(3);
	char[] buffer = new char[maxlen];
	
	TF2Attrib_UnsafeGetStringValue(rawValue, buffer, maxlen);
	
	if (strcmp(buffer, "") == 0) {
		return false;
	}
	
	SetNativeString(2, buffer, maxlen);
	return true;
}

// int CWX_GetItemLoadoutSlot(const char[] uid, TFClassType playerClass);
int Native_GetItemLoadoutSlot(Handle plugin, int argc) {
	char uid[MAX_ITEM_IDENTIFIER_LENGTH];
	GetNativeString(1, uid, sizeof(uid));
	int playerClass = GetNativeCell(2);
	
	CustomItemDefinition customItem;
	if (!GetCustomItemDefinition(uid, customItem)) {
		return -1;
	}
	return customItem.loadoutPosition[playerClass];
}

// optional<KeyValues> CWX_GetItemExtData(const char[] uid, const char[] section);
int Native_GetItemExtData(Handle plugin, int argc) {
	char uid[MAX_ITEM_IDENTIFIER_LENGTH];
	char sectionName[64];
	
	GetNativeString(1, uid, sizeof(uid));
	GetNativeString(2, sectionName, sizeof(sectionName));
	
	CustomItemDefinition customItem;
	if (!GetCustomItemDefinition(uid, customItem)) {
		return 0;
	}
	
	KeyValues result = customItem.GetExtData(sectionName);
	return result? MoveHandle(result, plugin) : 0;
}

int s_LastUpdatedClient;

/**
 * Called once the game has updated the player's loadout with all the weapons it wanted, but
 * before the post_inventory_application event is fired.
 * 
 * As other plugins may send usermessages in response to our equip events, we have to wait until
 * after the usermessage is sent before we can run our own logic.  We don't have access to the
 * usermessage itself in post, so this function simply grabs the info it needs.
 */
Action OnPlayerLoadoutUpdated(UserMsg msg_id, BfRead msg, const int[] players,
		int playersNum, bool reliable, bool init) {
	int client = msg.ReadByte();
	s_LastUpdatedClient = GetClientSerial(client);
}

/**
 * Called once the game has updated the player's loadout with all the weapons it wanted, but
 * before the post_inventory_application event is fired.
 * 
 * This is the point where we check our custom loadout settings, then create our items if
 * necessary (because persistence is implemented, the player may already have our custom items,
 * and we keep track of them so we don't unnecessarily reequip them).
 */
void OnPlayerLoadoutUpdatedPost(UserMsg msg_id, bool sent) {
	if (!sm_cwx_enable_loadout.BoolValue) {
		return;
	}
	
	int client = GetClientFromSerial(s_LastUpdatedClient);
	int playerClass = view_as<int>(TF2_GetPlayerClass(client));
	
	for (int i; i < NUM_ITEMS; i++) {
		if (g_CurrentLoadout[client][playerClass][i].IsEmpty()) {
			// no item specified, use default
			continue;
		}
		
		// equip our item if it isn't already equipped, or if it's being killed
		// the latter applies to items that are normally invalid for the class
		int currentLoadoutItem = g_CurrentLoadout[client][playerClass][i].entity;
		if (g_bForceReequipItems[client] || !IsValidEntity(currentLoadoutItem)
				|| GetEntityFlags(currentLoadoutItem) & FL_KILLME) {
			CustomItemDefinition item;
			if (!g_CurrentLoadout[client][playerClass][i].GetItemDefinition(item)) {
				continue;
			}
			
			if (!IsCustomItemAllowed(client, item)) {
				continue;
			}
			
			g_CurrentLoadout[client][playerClass][i].entity =
					EntIndexToEntRef(EquipCustomItem(client, item));
		}
	}
	
	// TODO: switch to the correct slot if we're not holding anything
	// as is the case again, this happens on non-valid-for-class items
}

void OnPlayerSpawnPost(Event event, const char[] name, bool dontBroadcast) {
	int client = GetClientOfUserId(event.GetInt("userid"));
	g_bForceReequipItems[client] = false;
}

/**
 * Called when the game wants to know what item the player has in a specific class / slot.  This
 * only happens when the game is regenerating the player (resupply, spawn).  This hook
 * intercepts the result and returns one of the following:
 * 
 * - the player's inventory item view, if we are not overriding it ourselves (no change)
 * - the spawned entity's item view, if our override item exists; this will prevent our custom
 *   item from being invalidated when we touch resupply
 * - an uninitialized item view, if our override item does not exist; the game will skip adding
 *   a weapon in that slot, and we can then spawn our own item later
 * 
 * The game expects there to be a valid CEconItemView pointer in certain areas of the code, so
 * avoid returning a nullptr.
 */
MRESReturn OnGetLoadoutItemPost(int client, Handle hReturn, Handle hParams) {
	if (!sm_cwx_enable_loadout.BoolValue) {
		return MRES_Ignored;
	}
	
	int playerClass = DHookGetParam(hParams, 1);
	int loadoutSlot = DHookGetParam(hParams, 2);
	
	if (loadoutSlot < 0 || loadoutSlot >= NUM_ITEMS) {
		return MRES_Ignored;
	}
	
	int storedItem = g_CurrentLoadout[client][playerClass][loadoutSlot].entity;
	if (!IsValidEntity(storedItem) || GetEntityFlags(storedItem) & FL_KILLME
			|| !HasEntProp(storedItem, Prop_Send, "m_Item")) {
		// the loadout entity we keep track of isn't valid, so we may need to make one
		// we expect to have to equip something new at this point
		
		if (g_CurrentLoadout[client][playerClass][loadoutSlot].IsEmpty()) {
			// we don't have nor want a custom item; let the game process it
			return MRES_Ignored;
		}
		
		/**
		 * We have a custom item we'd like to spawn in; don't return a loadout item, otherwise
		 * we may equip / unequip a user's inventory weapon that has side effects
		 * (e.g. Gunslinger).
		 * 
		 * We'll initialize our custom item later in `OnPlayerLoadoutUpdated`.
		 */
		static int s_DefaultItem = INVALID_ENT_REFERENCE;
		if (!IsValidEntity(s_DefaultItem)) {
			s_DefaultItem = EntIndexToEntRef(TF2_SpawnWearable());
			RemoveEntity(s_DefaultItem); // (this is OK, RemoveEntity doesn't act immediately)
		}
		storedItem = s_DefaultItem;
	}
	
	Address pStoredItemView = GetEntityAddress(storedItem)
			+ view_as<Address>(GetEntSendPropOffs(storedItem, "m_Item", true));
	
	DHookSetReturn(hReturn, pStoredItemView);
	return MRES_Supercede;
}

/**
 * Intercept ManageRegularWeapons to trick the game into thinking the weapons we have are valid
 * for that class, so they don't get removed.
 */
MRESReturn OnManageRegularWeaponsPre(int client, Handle hParams) {
	TFClassType playerClass = TF2_GetPlayerClass(client);
	for (int s; s < NUM_ITEMS; s++) {
		int storedItem = g_CurrentLoadout[client][playerClass][s].entity;
		if (!IsValidEntity(storedItem)) {
			continue;
		}
		
		int validitemdef = FindBaseItem(playerClass, s);
		if (validitemdef == TF_ITEMDEF_DEFAULT) {
			continue;
		}
		
		int currentitemdef = GetEntProp(storedItem, Prop_Send, "m_iItemDefinitionIndex");
		if (TF2Econ_GetItemLoadoutSlot(currentitemdef, playerClass) != -1) {
			// only replace the itemdef if the existing one is not valid for the class
			// this is because something something static attribute retention
			
			// we should probably just drop support for invalid weapons at this point;
			// it's starting to be a headache to manage
			continue;
		}
		
		// replace the itemdef and classname with ones actually valid for that class to skirt
		// around the ValidateWeapons checks
		char classname[64];
		TF2Econ_GetItemClassName(validitemdef, classname, sizeof(classname));
		
		// we need to translate the item class because base shotguns use 'tf_weapon_shotgun'
		TF2Econ_TranslateWeaponEntForClass(classname, sizeof(classname), playerClass);
		
		SetEntProp(storedItem, Prop_Send, "m_iItemDefinitionIndex", validitemdef);
		SetEntPropString(storedItem, Prop_Data, "m_iClassname", classname);
	}
	return MRES_Ignored;
}

/**
 * For every custom item in our loadout, reapply the correct defindex / classname.
 */
MRESReturn OnManageRegularWeaponsPost(int client, Handle hParams) {
	TFClassType playerClass = TF2_GetPlayerClass(client);
	for (int s; s < NUM_ITEMS; s++) {
		int storedItem = g_CurrentLoadout[client][playerClass][s].entity;
		if (!IsValidEntity(storedItem)) {
			continue;
		}
		
		CustomItemDefinition item;
		if (!g_CurrentLoadout[client][playerClass][s].GetItemDefinition(item)) {
			continue;
		}
		
		// have to resolve the classname since, y'know, multiclass.
		char realClassName[64];
		strcopy(realClassName, sizeof(realClassName), item.className);
		TF2Econ_TranslateWeaponEntForClass(realClassName, sizeof(realClassName), playerClass);
		
		SetEntProp(storedItem, Prop_Send, "m_iItemDefinitionIndex", item.defindex);
		SetEntPropString(storedItem, Prop_Data, "m_iClassname", realClassName);
	}
	return MRES_Ignored;
}

/**
 * Handles a special case where the player is refunding all of their upgrades, which may stomp
 * on any existing runtime attributes applied to our weapon.
 */
public Action OnClientCommandKeyValues(int client, KeyValues kv) {
	char cmd[64];
	kv.GetSectionName(cmd, sizeof(cmd));
	
	/**
	 * Mark the player to always invalidate our items so they get reequipped during respawn --
	 * this is fine since TF2 manages to reapply upgrades to plugin-granted items.
	 * 
	 * The player gets their loadout changed multiple times during respec so we can't just
	 * invalidate the reference in LoadoutEntry.entity (since it'll be valid after the first
	 * change).
	 * 
	 * Hopefully nobody's blocking "MVM_Respec", because that would leave this flag set.
	 * Otherwise we should be able to hook CUpgrades::GrantOrRemoveAllUpgrades() directly,
	 * though that incurs a gamedata burden.
	 */
	if (StrEqual(cmd, "MVM_Respec")) {
		g_bForceReequipItems[client] = true;
	}
}

public void OnClientCommandKeyValues_Post(int client, KeyValues kv) {
	char cmd[64];
	kv.GetSectionName(cmd, sizeof(cmd));
	
	if (StrEqual(cmd, "MVM_Respec")) {
		g_bForceReequipItems[client] = false;
	}
}

/**
 * Returns the base item associated with the given playerClass and loadoutSlot combination, or
 * TF_ITEMDEF_DEFAULT if no match is found.
 */
int FindBaseItem(TFClassType playerClass, int loadoutSlot) {
	static ArrayList s_BaseItems;
	if (!s_BaseItems) {
		s_BaseItems = TF2Econ_GetItemList(FilterBaseItems);
	}
	
	for (int i, n = s_BaseItems.Length; i < n; i++) {
		int itemdef = s_BaseItems.Get(i);
		if (TF2Econ_GetItemLoadoutSlot(itemdef, playerClass) == loadoutSlot) {
			return itemdef;
		}
	}
	return TF_ITEMDEF_DEFAULT;
}

bool FilterBaseItems(int itemdef, any __) {
	return TF2Econ_IsItemInBaseSet(itemdef);
}

// bool CWX_SetPlayerLoadoutItem(int client, TFClassType playerClass, const char[] uid, int flags = 0);
int Native_SetPlayerLoadoutItem(Handle plugin, int argc) {
	int client = GetNativeCell(1);
	int playerClass = GetNativeCell(2);
	
	char uid[MAX_ITEM_IDENTIFIER_LENGTH];
	GetNativeString(3, uid, sizeof(uid));
	
	int flags = GetNativeCell(4);
	
	return SetClientCustomLoadoutItem(client, playerClass, uid, flags);
}

/**
 * Saves the current item into the loadout for the specified class.
 */
bool SetClientCustomLoadoutItem(int client, int playerClass, const char[] itemuid, int flags) {
	CustomItemDefinition item;
	if (!GetCustomItemDefinition(itemuid, item)) {
		return false;
	}
	
	int itemSlot = item.loadoutPosition[playerClass];
	if (0 <= itemSlot < NUM_ITEMS) {
		if (flags & LOADOUT_FLAG_UPDATE_BACKEND) {
			// item being set as user preference; update backend and set permanent UID slot
			g_ItemPersistCookies[playerClass][itemSlot].Set(client, itemuid);
			g_CurrentLoadout[client][playerClass][itemSlot].SetItemUID(itemuid);
		} else {
			// item being set temporarily; set as overload
			g_CurrentLoadout[client][playerClass][itemSlot].SetOverloadItemUID(itemuid);
		}
		
		g_CurrentLoadout[client][playerClass][itemSlot].entity = INVALID_ENT_REFERENCE;
	} else {
		return false;
	}
	
	if (flags & LOADOUT_FLAG_ATTEMPT_REGEN) {
		OnClientCustomLoadoutItemModified(client, playerClass);
	}
	return true;
}

// void CWX_RemovePlayerLoadoutItem(int client, TFClassType playerClass, int itemSlot, int flags = 0);
int Native_RemovePlayerLoadoutItem(Handle plugin, int argc) {
	int client = GetNativeCell(1);
	int playerClass = GetNativeCell(2);
	int itemSlot = GetNativeCell(3);
	int flags = GetNativeCell(4);
	
	UnsetClientCustomLoadoutItem(client, playerClass, itemSlot, flags);
}

/**
 * Unsets any existing item in the given loadout slot for the specified class.
 */
void UnsetClientCustomLoadoutItem(int client, int playerClass, int itemSlot, int flags) {
	if (flags & LOADOUT_FLAG_UPDATE_BACKEND) {
		g_CurrentLoadout[client][playerClass][itemSlot].Clear();
		g_ItemPersistCookies[playerClass][itemSlot].Set(client, "");
	} else {
		g_CurrentLoadout[client][playerClass][itemSlot].SetOverloadItemUID("");
	}
	
	if (flags & LOADOUT_FLAG_ATTEMPT_REGEN) {
		OnClientCustomLoadoutItemModified(client, playerClass);
	}
}

// bool CWX_GetPlayerLoadoutItem(int client, TFClassType playerClass, int itemSlot, char[] uid, int uidLen, int flags = 0);
int Native_GetPlayerLoadoutItem(Handle plugin, int argc) {
	int client = GetNativeCell(1);
	int playerClass = GetNativeCell(2);
	int itemSlot = GetNativeCell(3);
	int uidLen = GetNativeCell(5);
	int flags = GetNativeCell(6);
	
	if (g_CurrentLoadout[client][playerClass][itemSlot].IsEmpty()) {
		return false;
	}
	
	char[] uid = new char[uidLen];
	if (flags & LOADOUT_FLAG_UPDATE_BACKEND) {
		strcopy(uid, uidLen, g_CurrentLoadout[client][playerClass][itemSlot].uid);
	} else {
		strcopy(uid, uidLen, g_CurrentLoadout[client][playerClass][itemSlot].override_uid);
	}
	SetNativeString(4, uid, uidLen);
	return true;
}

/**
 * Called when a player's custom inventory has changed.  Decide if we should act on it.
 */
void OnClientCustomLoadoutItemModified(int client, int modifiedClass) {
	if (view_as<int>(TF2_GetPlayerClass(client)) != modifiedClass) {
		// do nothing if the loadout for the current class wasn't modified
		return;
	}
	
	if (!sm_cwx_enable_loadout.BoolValue) {
		// do nothing if user selections are disabled
		return;
	}
	
	if (IsPlayerAllowedToRespawnOnLoadoutChange(client)) {
		// see if the player is into being respawned on loadout changes
		QueryClientConVar(client, "tf_respawn_on_loadoutchanges", OnLoadoutRespawnPreference);
	} else {
		PrintToChat(client, "%t", "LoadoutChangesUpdate");
	}
}

/**
 * Called after inventory change and we have the client's tf_respawn_on_loadoutchanges convar
 * value.  Respawn them if desired.
 */
void OnLoadoutRespawnPreference(QueryCookie cookie, int client, ConVarQueryResult result,
		const char[] cvarName, const char[] cvarValue) {
	if (result != ConVarQuery_Okay) {
		return;
	} else if (!StringToInt(cvarValue) || !IsPlayerAllowedToRespawnOnLoadoutChange(client)) {
		// the second check for respawn room is in case we're somehow not in one between
		// the query and the callback
		PrintToChat(client, "%t", "LoadoutChangesUpdate");
		return;
	}
	
	// mark player as regenerating during respawn -- this prevents stickies from despawning
	// this matches the game's internal behavior during GC loadout changes
	SetEntProp(client, Prop_Send, "m_bRegenerating", true);
	TF2_RespawnPlayer(client);
	SetEntProp(client, Prop_Send, "m_bRegenerating", false);
}

/**
 * Returns whether or not the player can actually equip this item normally.
 * (This does not prevent admins from forcibly applying the item to the player.)
 */
bool CanPlayerEquipItem(int client, const CustomItemDefinition item) {
	TFClassType playerClass = TF2_GetPlayerClass(client);
	
	if (item.loadoutPosition[playerClass] == -1) {
		return false;
	}
	return CanPlayerAccessItem(client, item);
}

/**
 * Returns whether or not the player has access to this item.
 */
bool CanPlayerAccessItem(int client, const CustomItemDefinition item) {
	if (item.access[0] && !CheckCommandAccess(client, item.access, 0, true)) {
		// this item requires access
		return false;
	}
	return true;
}

/**
 * Returns whether or not the player is in a respawn room that their team owns, for the purpose
 * of repsawning on loadout change.
 */
static bool IsPlayerInRespawnRoom(int client) {
	float vecMins[3], vecMaxs[3], vecCenter[3], vecOrigin[3];
	GetClientMins(client, vecMins);
	GetClientMaxs(client, vecMaxs);
	GetClientAbsOrigin(client, vecOrigin);
	
	GetCenterFromPoints(vecMins, vecMaxs, vecCenter);
	AddVectors(vecOrigin, vecCenter, vecCenter);
	return TF2Util_IsPointInRespawnRoom(vecCenter, client, true);
}

/**
 * Returns whether or not the player is allowed to respawn on loadout changes.
 */
static bool IsPlayerAllowedToRespawnOnLoadoutChange(int client) {
	if (!IsClientInGame(client) || !IsPlayerInRespawnRoom(client) || !IsPlayerAlive(client)) {
		return false;
	}
	
	// prevent respawns on sudden death
	// ideally we'd base this off of CTFGameRules::CanChangeClassInStalemate(), but that
	// requires either gamedata or keeping track of the stalemate time ourselves
	if (GameRules_GetRoundState() == RoundState_Stalemate) {
		return false;
	}
	
	return true;
}

/**
 * Returns whether or not the custom item is currently allowed.  This is specifically for
 * instances where the item may be temporarily restricted (Medieval, melee-only Sudden Death).
 * 
 * sm_cwx_enable_loadout is checked earlier, during OnPlayerLoadoutUpdatedPost and
 * OnGetLoadoutItemPost.
 */
static bool IsCustomItemAllowed(int client, const CustomItemDefinition item) {
	if (!IsClientInGame(client)) {
		return false;
	}
	
	TFClassType playerClass = TF2_GetPlayerClass(client);
	int slot = item.loadoutPosition[playerClass];
	
	// TODO work out other restrictions?
	
	if (GameRules_GetRoundState() == RoundState_Stalemate && mp_stalemate_meleeonly.BoolValue) {
		bool bMelee = slot == 2 || (playerClass == TFClass_Spy && (slot == 5 || slot == 6));
		if (!bMelee) {
			return false;
		}
	}
	
	if (GameRules_GetProp("m_bPlayingMedieval")) {
		bool bMedievalAllowed;
		if (slot == 2) {
			bMedievalAllowed = true;
		}
		
		if (!bMedievalAllowed) {
			// non-melee item; time to check the schema...
			bool bMedievalAllowedInSchema;
			
			bool bNativeAttributeOverride;
			if (item.nativeAttributes) {
				char configValue[8];
				item.nativeAttributes.GetString("allowed in medieval mode",
						configValue, sizeof(configValue));
				
				if (configValue[0]) {
					// don't fallback to static attributes if override in config
					bNativeAttributeOverride = true;
					bMedievalAllowedInSchema = !!StringToInt(configValue);
				}
			}
			if (!bNativeAttributeOverride && item.bKeepStaticAttributes) {
				// TODO we should cache this...
				ArrayList attribList = TF2Econ_GetItemStaticAttributes(item.defindex);
				bMedievalAllowedInSchema =
						attribList.FindValue(g_attrdef_AllowedInMedievalMode) != -1;
				delete attribList;
			}
			
			if (!bMedievalAllowedInSchema) {
				return false;
			}
		}
	}
	return true;
}
