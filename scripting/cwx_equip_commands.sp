/**
 * Custom Weapons X - Equip Commands
 * 
 * A few admin commands to apply items for testing purposes.  These have been moved from the
 * original plugin to use the shared plugin API instead.
 */
#pragma semicolon 1
#include <sourcemod>

#pragma newdecls required

#include <cwx>
#include <tf2_stocks>

public Plugin myinfo = {
	name = "[TF2] Custom Weapons X - Equip Commands",
	author = "nosoop",
	description = "Provides admin-level commands to force equip defined items.",
	version = "1.1.0",
	url = "https://github.com/nosoop/SM-TFCustomWeaponsX"
}

#define MAX_ITEM_IDENTIFIER_LENGTH 64

public void OnPluginStart() {
	RegAdminCmd("sm_cwx_equip", EquipItemCmd, ADMFLAG_ROOT);
	RegAdminCmd("sm_cwx_equip_target", EquipItemCmdTarget, ADMFLAG_ROOT);
	RegAdminCmd("sm_cwx_set_loadout", PersistItemCmd, ADMFLAG_ROOT);
}

/**
 * Testing command to equip the given item uid on the player.
 * 
 * NOTE: This command immediately equips the item without respawning - this may not accurately
 * reflect weapon behavior.
 */
Action EquipItemCmd(int client, int argc) {
	if (!client) {
		return Plugin_Continue;
	}
	
	char itemuid[MAX_ITEM_IDENTIFIER_LENGTH];
	GetCmdArgString(itemuid, sizeof(itemuid));
	
	StripQuotes(itemuid);
	TrimString(itemuid);
	
	if (!CWX_IsItemUIDValid(itemuid)) {
		ReplyToCommand(client, "Unknown custom item uid %s", itemuid);
	} else if (!IsValidEntity(CWX_EquipPlayerItem(client, itemuid))) {
		ReplyToCommand(client, "Failed to equip custom item uid %s", itemuid);
	}
	return Plugin_Handled;
}

/**
 * Testing command to temporarily assign the given item uid on the player's loadout.
 * The item will be applied the next time the player is regenerated.
 */
Action PersistItemCmd(int client, int argc) {
	if (!client) {
		return Plugin_Continue;
	}
	
	char itemuid[MAX_ITEM_IDENTIFIER_LENGTH];
	GetCmdArgString(itemuid, sizeof(itemuid));
	
	StripQuotes(itemuid);
	TrimString(itemuid);
	
	if (!CWX_IsItemUIDValid(itemuid)) {
		ReplyToCommand(client, "Unknown custom item uid %s", itemuid);
	} else if (!CWX_SetPlayerLoadoutItem(client, TF2_GetPlayerClass(client), itemuid)) {
		ReplyToCommand(client, "Failed to set custom item uid %s", itemuid);
	}
	
	return Plugin_Handled;
}

/**
 * Testing command to equip the given item uid on the specified target(s).
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
	
	if (!CWX_IsItemUIDValid(itemuid)) {
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
		if (!IsValidEntity(CWX_EquipPlayerItem(target, itemuid))) {
			ReplyToCommand(client, "Failed to equip custom item uid %s on %N", itemuid, target);
		}
	}
	
	return Plugin_Handled;
}
