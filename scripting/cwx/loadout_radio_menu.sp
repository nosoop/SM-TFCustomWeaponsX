/**
 * This file deals with the radio menu-based interface for equipping weapons.
 */

// Use game UI sounds for menus to provide a more TF2-sounding experience
#define SOUND_MENU_BUTTON_CLICK "ui/buttonclick.wav"
#define SOUND_MENU_BUTTON_CLOSE "ui/panel_close.wav"
#define SOUND_MENU_BUTTON_EQUIP "ui/panel_open.wav"

static Menu s_LoadoutSlotMenu;

// Menu containing our list of items.  This is initalized once, then items are modified
// depending on which ones the player is browsing at the time.
static Menu s_EquipMenu;

static int g_iPlayerClassInMenu[MAXPLAYERS + 1];
static int g_iPlayerSlotInMenu[MAXPLAYERS + 1];

/**
 * Localized player class names, in TFClassType order.  Used in CWX's translation file.
 */
static char g_LocalizedPlayerClass[][] = {
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

/**
 * Localized loadout slot names, in loadout slot order.
 */
static char g_LocalizedLoadoutSlots[][] = {
	"LoadoutSlot_Primary",
	"LoadoutSlot_Secondary",
	"LoadoutSlot_Melee",
	"LoadoutSlot_Utility",
	"LoadoutSlot_Building",
	"LoadoutSlot_pda",
	"LoadoutSlot_pda2",
	"LoadoutSlot_Head",
	"LoadoutSlot_Misc",
	"LoadoutSlot_Action",
	"LoadoutSlot_Misc",
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

/**
 * Slot option visibility bits.  These are hardcoded to restrict which slots are visible on
 * which player classes.
 * 
 * I originally considered automatically resolving this information through Econ Data, but that
 * seemed to be more trouble than it's worth.
 */
static int bitsSlotVisibility[NUM_PLAYER_CLASSES] = {
	0b0000000, 0b0000111, 0b0000111, 0b0000111, 0b0000111,
	0b0000111, 0b0000111, 0b0000111, 0b1010110, 0b1100111
};

/**
 * Command callback to display items to a player.
 */
Action DisplayItems(int client, int argc) {
	g_iPlayerClassInMenu[client] = view_as<int>(TF2_GetPlayerClass(client));
	if (!g_iPlayerClassInMenu[client]) {
		return Plugin_Handled;
	}
	
	s_LoadoutSlotMenu.Display(client, 30);
	return Plugin_Handled;
}

/**
 * Command listener callback to display items to a player.
 * This is a compatibility shim; this only displays the CWX menu if CW3 isn't running.
 */
Action DisplayItemsCompat(int client, const char[] command, int argc) {
	// allow CW3 to display if it's loaded in
	if (FindPluginByFile("cw3.smx")) {
		return Plugin_Continue;
	}
	
	if (!CheckCommandAccess(client, "sm_cwx", 0)) {
		ReplyToCommand(client, "[SM] %t.", "No Access");
		return Plugin_Stop;
	}
	
	// otherwise show the menu for CWX
	DisplayItems(client, argc);
	return Plugin_Stop;
}

/**
 * Resources precached during map start.
 */
void PrecacheMenuResources() {
	PrecacheSound(SOUND_MENU_BUTTON_CLICK);
	PrecacheSound(SOUND_MENU_BUTTON_CLOSE);
	PrecacheSound(SOUND_MENU_BUTTON_EQUIP);
}

/**
 * Initializes our loadout slot selection menu.
 * 
 * This must be called after all plugins are loaded, since we depend on Econ Data.
 */
void BuildLoadoutSlotMenu() {
	delete s_LoadoutSlotMenu;
	s_LoadoutSlotMenu = new Menu(OnLoadoutSlotMenuEvent, MENU_ACTIONS_ALL);
	s_LoadoutSlotMenu.OptionFlags |= MENUFLAG_NO_SOUND;
	
	for (int i; i < NUM_ITEMS; i++) {
		char name[32];
		TF2Econ_TranslateLoadoutSlotIndexToName(i, name, sizeof(name));
		s_LoadoutSlotMenu.AddItem(name, name);
	}
}

/**
 * Initializes the weapon list menu used for players to equip weapons.
 * Should be called when the custom item schema is reset.
 * 
 * Visibility of an item is determined based on currently browsed class / weapon slot
 * (see `ItemVisibleInEquipMenu` and `OnEquipMenuEvent->MenuAction_DrawItem`).
 */
void BuildEquipMenu() {
	delete s_EquipMenu;
	
	s_EquipMenu = new Menu(OnEquipMenuEvent, MENU_ACTIONS_ALL);
	s_EquipMenu.OptionFlags |= MENUFLAG_NO_SOUND;
	s_EquipMenu.ExitBackButton = true;
	
	s_EquipMenu.AddItem("", "[No custom item]");
	
	char uid[MAX_ITEM_IDENTIFIER_LENGTH];
	
	StringMapSnapshot itemList = GetCustomItemList();
	for (int i; i < itemList.Length; i++) {
		itemList.GetKey(i, uid, sizeof(uid));
		
		CustomItemDefinition item;
		GetCustomItemDefinition(uid, item);
		
		for (int c = 1; c < NUM_PLAYER_CLASSES; c++) {
			int loadoutPosition = item.loadoutPosition[c];
			if (loadoutPosition == -1) {
				continue;
			}
			
			if (bitsSlotVisibility[c] & (1 << loadoutPosition) == 0) {
				LogMessage("Item uid %s specifies a non-visible loadout slot for class %t",
						uid, g_LocalizedPlayerClass[c]);
			}
		}
		
		s_EquipMenu.AddItem(uid, item.displayName);
	}
	delete itemList;
}

/**
 * Determines visibility of items in the loadout menu.
 */
static bool ItemVisibleInEquipMenu(int client, const CustomItemDefinition item) {
	int playerClass = g_iPlayerClassInMenu[client];
	
	// not visible for current submenu
	if (item.loadoutPosition[playerClass] != g_iPlayerSlotInMenu[client]) {
		return false;
	}
	
	// visible for submenu, but player can't equip it for other reasons
	return CanPlayerEquipItem(client, item);
}

/**
 * Handles the loadout slot menu.
 */
static int OnLoadoutSlotMenuEvent(Menu menu, MenuAction action, int param1, int param2) {
	switch (action) {
		/**
		 * Sets the menu header for the current section.
		 */
		case MenuAction_Display: {
			int client = param1;
			Panel panel = view_as<any>(param2);
			
			SetGlobalTransTarget(client);
			
			char buffer[192];
			FormatEx(buffer, sizeof(buffer), "Custom Weapons X");
			
			if (!sm_cwx_enable_loadout.BoolValue) {
				Format(buffer, sizeof(buffer), "%s\n%t", buffer, "CustomItemsUnavailable");
			}
			
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
			
			EmitSoundToClient(client, SOUND_MENU_BUTTON_CLICK);
		}
		
		case MenuAction_DrawItem: {
			int client = param1;
			int position = param2;
			
			char loadoutSlotName[64];
			menu.GetItem(position, loadoutSlotName, sizeof(loadoutSlotName));
			int loadoutSlot = TF2Econ_TranslateLoadoutSlotNameToIndex(loadoutSlotName);
			
			if (bitsSlotVisibility[g_iPlayerClassInMenu[client]] & (1 << loadoutSlot) == 0) {
				return ITEMDRAW_IGNORE;
			}
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
		case MenuAction_Cancel: {
			int client = param1;
			EmitSoundToClient(client, SOUND_MENU_BUTTON_CLOSE);
		}
	}
	return 0;
}

/**
 * Handles the weapon list selection menu.
 */
static int OnEquipMenuEvent(Menu menu, MenuAction action, int param1, int param2) {
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
			
			EmitSoundToClient(client, SOUND_MENU_BUTTON_EQUIP);
			
			// TODO: we should be making this a submenu with item description?
			if (uid[0]) {
				SetClientCustomLoadoutItem(client, g_iPlayerClassInMenu[client], uid,
						LOADOUT_FLAG_UPDATE_BACKEND | LOADOUT_FLAG_ATTEMPT_REGEN);
			} else {
				UnsetClientCustomLoadoutItem(client, g_iPlayerClassInMenu[client],
						g_iPlayerSlotInMenu[client],
						LOADOUT_FLAG_UPDATE_BACKEND | LOADOUT_FLAG_ATTEMPT_REGEN);
			}
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
			
			if (!uid[0]) {
				// "no custom item" is always visible
				return ITEMDRAW_DEFAULT;
			}
			
			CustomItemDefinition item;
			if (!GetCustomItemDefinition(uid, item) || !ItemVisibleInEquipMenu(client, item)) {
				// remove visibility of item
				return ITEMDRAW_IGNORE;
			}
		}
		
		/**
		 * Renders the custom item name.
		 */
		case MenuAction_DisplayItem: {
			int client = param1;
			int position = param2;
			
			char uid[MAX_ITEM_IDENTIFIER_LENGTH], itemName[MAX_ITEM_NAME_LENGTH];
			menu.GetItem(position, uid, sizeof(uid), _, itemName, sizeof(itemName));
			
			CustomItemDefinition item;
			GetCustomItemDefinition(uid, item);
			
			int menuClass = g_iPlayerClassInMenu[client];
			int menuSlot = g_iPlayerSlotInMenu[client];
			
			bool equipped = StrEqual(g_CurrentLoadout[client][menuClass][menuSlot].uid, uid);
			bool override = StrEqual(g_CurrentLoadout[client][menuClass][menuSlot].override_uid, uid);
			
			SetGlobalTransTarget(client);
			
			bool redraw;
			if (!uid[0]) {
				FormatEx(itemName, sizeof(itemName), "%t", "UnequipCustomItem");
				redraw = true;
			} else if (item.localizedNames) {
				// attempt to look up a localized name based on shortcode
				char langcode[16], localizedName[MAX_ITEM_NAME_LENGTH];
				GetLanguageInfo(GetClientLanguage(client), langcode, sizeof(langcode));
				
				item.localizedNames.GetString(langcode, localizedName, sizeof(localizedName));
				if (localizedName[0]) {
					strcopy(itemName, sizeof(itemName), localizedName);
					redraw = true;
				}
			}
			
			if (equipped) {
				Format(itemName, sizeof(itemName), "%s %t", itemName, "QuickSwitchEquipped");
				redraw = true;
			} else if (uid[0] && override) {
				Format(itemName, sizeof(itemName), "%s %t", itemName, "ItemForcedByServer");
				redraw = true;
			}
			
			SetGlobalTransTarget(LANG_SERVER);
			
			if (redraw) {
				return RedrawMenuItem(itemName);
			}
		}
		
		/**
		 * Return back to the loadout selection menu.
		 */
		case MenuAction_Cancel: {
			int client = param1;
			int reason = param2;
			
			EmitSoundToClient(client, SOUND_MENU_BUTTON_CLOSE);
			if (reason == MenuCancel_ExitBack) {
				s_LoadoutSlotMenu.Display(client, 30);
			}
		}
	}
	return 0;
}
