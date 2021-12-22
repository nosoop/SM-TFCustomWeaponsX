/**
 * [TF2] Custom Weapons X
 */
#pragma semicolon 1
#include <sourcemod>

#pragma newdecls required

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
	version = "X.0.8" ... VERSION_SUFFIX,
	url = "https://github.com/nosoop/SM-TFCustomWeaponsX"
}

// this is the maximum expected length of our UID
// it is intentional that this is *not* shared to dependent plugins
#define MAX_ITEM_IDENTIFIER_LENGTH 64

// this is the maximum length of the item name displayed to players
#define MAX_ITEM_NAME_LENGTH 128

// this is the number of slots allocated to our thing
#define NUM_ITEMS 7

// okay, so we can't use TFClassType even view_as'd
// otherwise it'll warn on array-based enumstruct
#define NUM_PLAYER_CLASSES 10

// we're using the "random drop line item unusual list" attribute as a dumping attribute to store the UID onto the item in an attribute
// it's kinda icky and if anyone else happened to get the same idea it'd be bad, but it's the best we've got without trying TOO hard
#define UID_ATTRIBUTE "random drop line item unusual list"

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

any offs_CTFPlayer_m_bRegenerating;

public APLRes AskPluginLoad2(Handle self, bool late, char[] error, int maxlen) {
	RegPluginLibrary("cwx");
	
	CreateNative("CWX_SetPlayerLoadoutItem", Native_SetPlayerLoadoutItem);
	CreateNative("CWX_EquipPlayerItem", Native_EquipPlayerItem);
	CreateNative("CWX_IsItemUIDValid", Native_IsItemUIDValid);
	CreateNative("CWX_GetItemUIDFromEntity", Native_GetItemUIDFromEntity);
	
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
	
	any offs_CTFPlayer_m_hItem = FindSendPropInfo("CTFPlayer", "m_hItem");
	if (!offs_CTFPlayer_m_hItem) {
		SetFailState("Failed to resolve member offset CTFPlayer::m_bRegenerating");
	}
	
	// m_hItem is dword-aligned, the previous dword contains at least 1 unknown bool value
	// this is consistent between Windows / Linux
	offs_CTFPlayer_m_bRegenerating = offs_CTFPlayer_m_hItem - 5;
	
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
		LogError("Tried to get UID from invalid entity %i", entity);
		return false;
	}
	
	Address result = TF2Attrib_GetByName(entity, UID_ATTRIBUTE);
	
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
	
	// TODO: work around invalid class items being invalidated
	int playerClass = DHookGetParam(hParams, 1);
	int loadoutSlot = DHookGetParam(hParams, 2);
	
	if (loadoutSlot < 0 || loadoutSlot >= NUM_ITEMS) {
		return MRES_Ignored;
	}
	
	int storedItem = g_CurrentLoadout[client][playerClass][loadoutSlot].entity;
	if (!IsValidEntity(storedItem) || !HasEntProp(storedItem, Prop_Send, "m_Item")) {
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

/**
 * Unsets any existing item in the given loadout slot for the specified class.
 */
void UnsetClientCustomLoadoutItem(int client, int playerClass, int itemSlot) {
	g_CurrentLoadout[client][playerClass][itemSlot].Clear();
	g_ItemPersistCookies[playerClass][itemSlot].Set(client, "");
	
	OnClientCustomLoadoutItemModified(client, playerClass);
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
	SetPlayerRegenerationState(client, true);
	TF2_RespawnPlayer(client);
	SetPlayerRegenerationState(client, false);
}

void SetPlayerRegenerationState(int client, bool value) {
	SetEntData(client, offs_CTFPlayer_m_bRegenerating, value, .size = 1);
}

/**
 * Returns whether or not the player can actually equip this item normally.
 * (This does not prevent admins from forcibly applying the item to the player.)
 */
bool CanPlayerEquipItem(int client, const CustomItemDefinition item) {
	TFClassType playerClass = TF2_GetPlayerClass(client);
	
	if (item.loadoutPosition[playerClass] == -1) {
		return false;
	} else if (item.access[0] && !CheckCommandAccess(client, item.access, 0, true)) {
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
