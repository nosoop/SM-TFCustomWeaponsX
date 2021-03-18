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
	version = "X.0.6" ... VERSION_SUFFIX,
	version = "X.0.7" ... VERSION_SUFFIX,
	url = "https://github.com/nosoop/SM-TFCustomWeaponsX"
}

// this is the maximum expected length of our UID
#define MAX_ITEM_IDENTIFIER_LENGTH 64

#define MAX_ITEM_NAME_LENGTH 128

// this is the number of slots allocated to our thing
#define NUM_ITEMS 7

// okay, so we can't use TFClassType even view_as'd
// otherwise it'll warn on array-based enumstruct
#define NUM_PLAYER_CLASSES 10

bool g_bRetrievedLoadout[MAXPLAYERS + 1];
char g_CurrentLoadout[MAXPLAYERS + 1][NUM_PLAYER_CLASSES][NUM_ITEMS][MAX_ITEM_IDENTIFIER_LENGTH];

// loadout entity, for persistence
// note for the future: we do *not* restore this on late load since the schema may have changed
int g_CurrentLoadoutEntity[MAXPLAYERS + 1][NUM_PLAYER_CLASSES][NUM_ITEMS];

Cookie g_ItemPersistCookies[NUM_PLAYER_CLASSES][NUM_ITEMS];

bool g_bForceReequipItems[MAXPLAYERS + 1];

#include "cwx/item_config.sp"
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
	
	HookEvent("player_spawn", OnPlayerSpawnPost);
	HookUserMessage(GetUserMessageId("PlayerLoadoutUpdated"), OnPlayerLoadoutUpdated,
			.post = OnPlayerLoadoutUpdatedPost);
	
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
	
	PrecacheMenuResources();
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
	
	CustomItemDefinition item;
	if (!GetCustomItemDefinition(itemuid, item)) {
		ReplyToCommand(client, "Unknown custom item uid %s", itemuid);
	} else if (!IsValidEntity(EquipCustomItem(client, item))) {
		ReplyToCommand(client, "Failed to equip custom item uid %s", itemuid);
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
	
	CustomItemDefinition item;
	if (!GetCustomItemDefinition(itemuid, item)) {
		ReplyToCommand(client, "Unknown custom item uid %s", itemuid);
		return Plugin_Handled;
	}
	
	bool multilang;
	char targetName[MAX_NAME_LENGTH];
	int targets[MAXPLAYERS], nTargetsOrFailureReason;
	nTargetsOrFailureReason = ProcessTargetString(targetString, client,
			targets, sizeof(targets), COMMAND_FILTER_NO_IMMUNITY,
			targetName, sizeof(targetName), multilang);
	
	if (nTargetsOrFailureReason <= 0) {
		ReplyToTargetError(client, nTargetsOrFailureReason);
		return Plugin_Handled;
	}
	
	for (int i; i < nTargetsOrFailureReason; i++) {
		int target = targets[i];
		if (!IsValidEntity(EquipCustomItem(target, item))) {
			ReplyToCommand(client, "Failed to equip custom item uid %s on %N", itemuid, target);
		}
	}
	
	return Plugin_Handled;
}

int s_LastUpdatedClient;

Action OnPlayerLoadoutUpdated(UserMsg msg_id, BfRead msg, const int[] players,
		int playersNum, bool reliable, bool init) {
	int client = msg.ReadByte();
	s_LastUpdatedClient = GetClientSerial(client);
}

void OnPlayerLoadoutUpdatedPost(UserMsg msg_id, bool sent) {
	int client = GetClientFromSerial(s_LastUpdatedClient);
	int playerClass = view_as<int>(TF2_GetPlayerClass(client));
	
	for (int i; i < NUM_ITEMS; i++) {
		if (!g_CurrentLoadout[client][playerClass][i][0]) {
			// no item specified, use default
			continue;
		}
		
		// equip our item if it isn't already equipped, or if it's being killed
		// the latter applies to items that are normally invalid for the class
		int currentLoadoutItem = g_CurrentLoadoutEntity[client][playerClass][i];
		if (g_bForceReequipItems[client] || !IsValidEntity(currentLoadoutItem)
				|| GetEntityFlags(currentLoadoutItem) & FL_KILLME) {
			// TODO validate that the player can access this item
			CustomItemDefinition item;
			if (!GetCustomItemDefinition(g_CurrentLoadout[client][playerClass][i], item)) {
				continue;
			}
			
			g_CurrentLoadoutEntity[client][playerClass][i] =
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
 * Item persistence - we return our item's CEconItemView instance when the game looks up our
 * inventory item.  This prevents our custom item from being invalidated when touch resupply.
 * 
 * The game expects there to be a valid CEconItemView pointer in certain areas of the code, so
 * avoid returning a nullptr.
 */
MRESReturn OnGetLoadoutItemPost(int client, Handle hReturn, Handle hParams) {
	// TODO: work around invalid class items being invalidated
	int playerClass = DHookGetParam(hParams, 1);
	int loadoutSlot = DHookGetParam(hParams, 2);
	
	if (loadoutSlot < 0 || loadoutSlot >= NUM_ITEMS) {
		return MRES_Ignored;
	}
	
	int storedItem = g_CurrentLoadoutEntity[client][playerClass][loadoutSlot];
	if (!IsValidEntity(storedItem) || !HasEntProp(storedItem, Prop_Send, "m_Item")) {
		// the loadout entity we keep track of isn't valid, so we may need to make one
		// we expect to have to equip something new at this point
		
		if (!g_CurrentLoadout[client][playerClass][loadoutSlot][0]) {
			// we don't have a custom item; let the game process it
			return MRES_Ignored;
		}
		
		/**
		 * we have a custom item we'd like to spawn in, don't return a loadout item, otherwise
		 * we may equip / unequip a weapon that has side effects (e.g. Gunslinger)
		 * 
		 * we'll initialize our custom item later in `OnPlayerLoadoutUpdated`
		 */
		static int s_DefaultItem = INVALID_ENT_REFERENCE;
		if (!IsValidEntity(s_DefaultItem)) {
			s_DefaultItem = EntIndexToEntRef(TF2_SpawnWearable());
			RemoveEntity(s_DefaultItem);
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
	 * invalidate the reference in g_CurrentLoadoutEntity (since it'll be valid after the first
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
 * Saves the current item into the loadout for the specified class.
 */
bool SetClientCustomLoadoutItem(int client, int playerClass, const char[] itemuid) {
	CustomItemDefinition item;
	if (!GetCustomItemDefinition(itemuid, item)) {
		return false;
	}
	
	int itemSlot = item.loadoutPosition[playerClass];
	if (0 <= itemSlot < NUM_ITEMS) {
		strcopy(g_CurrentLoadout[client][playerClass][itemSlot],
				sizeof(g_CurrentLoadout[][][]), itemuid);
		g_ItemPersistCookies[playerClass][itemSlot].Set(client, itemuid);
		g_CurrentLoadoutEntity[client][playerClass][itemSlot] = INVALID_ENT_REFERENCE;
	} else {
		return false;
	}
	
	OnClientCustomLoadoutItemModified(client, playerClass);
	return true;
}

void UnsetClientCustomLoadoutItem(int client, int playerClass, int itemSlot) {
	strcopy(g_CurrentLoadout[client][playerClass][itemSlot],
				sizeof(g_CurrentLoadout[][][]), "");
	g_ItemPersistCookies[playerClass][itemSlot].Set(client, "");
	g_CurrentLoadoutEntity[client][playerClass][itemSlot] = INVALID_ENT_REFERENCE;
	
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
	
	if (IsPlayerInRespawnRoom(client) && IsPlayerAlive(client)) {
		// see if the player is into being respawned on loadout changes
		QueryClientConVar(client, "tf_respawn_on_loadoutchanges", OnLoadoutRespawnPreference);
	} else {
		PrintToChat(client, "%t", "LoadoutChangesUpdate");
	}
}

void OnLoadoutRespawnPreference(QueryCookie cookie, int client, ConVarQueryResult result,
		const char[] cvarName, const char[] cvarValue) {
	if (result != ConVarQuery_Okay) {
		return;
	} else if (!StringToInt(cvarValue) || !IsPlayerInRespawnRoom(client)) {
		// the second check for respawn room is in case we're somehow not in one between
		// the query and the callback
		PrintToChat(client, "%t", "LoadoutChangesUpdate");
		return;
	}
	TF2_RespawnPlayer(client);
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

static bool IsPlayerInRespawnRoom(int client) {
	float vecMins[3], vecMaxs[3], vecCenter[3], vecOrigin[3];
	GetClientMins(client, vecMins);
	GetClientMaxs(client, vecMaxs);
	GetClientAbsOrigin(client, vecOrigin);
	
	GetCenterFromPoints(vecMins, vecMaxs, vecCenter);
	AddVectors(vecOrigin, vecCenter, vecCenter);
	return TF2Util_IsPointInRespawnRoom(vecCenter, client, true);
}
