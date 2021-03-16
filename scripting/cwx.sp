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
	version = "X.0.6",
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

Cookie g_ItemPersistCookies[NUM_PLAYER_CLASSES][NUM_ITEMS];

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
		
		// equip our item if it isn't already equipped, or if it's being killed
		// the latter applies to items that are normally invalid for the class
		int currentLoadoutItem = g_CurrentLoadoutEntity[client][playerClass][i];
		if (!IsValidEntity(currentLoadoutItem)
				|| GetEntityFlags(currentLoadoutItem) & FL_KILLME) {
			int entity = LookupAndEquipItem(client, g_CurrentLoadout[client][playerClass][i]);
			g_CurrentLoadoutEntity[client][playerClass][i] = IsValidEntity(entity)?
					EntIndexToEntRef(entity) : INVALID_ENT_REFERENCE;
		}
	}
	
	// TODO: switch to the correct slot if we're not holding anything
	// as is the case again, this happens on non-valid-for-class items
}

/**
 * Item persistence - we return our item's CEconItemView instance when the game looks up our
 * inventory item.  This prevents our custom item from being invalidated when touch resupply.
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
	
	CustomItemDefinition item;
	if (!g_CustomItems.GetArray(itemuid, item, sizeof(item))) {
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

bool CanPlayerEquipItem(int client, const char[] uid) {
	// TODO hide based on admin overrides
	
	TFClassType playerClass = TF2_GetPlayerClass(client);
	
	CustomItemDefinition item;
	return g_CustomItems.GetArray(uid, item, sizeof(item))
			&& item.loadoutPosition[playerClass] != -1;
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

// Overrides the default visibility of the item in the loadout menu.
// CWX_SetItemVisibility(int client, const char[] uid, ItemVisibility vis);
