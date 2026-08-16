#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <tf2attributes>
#include <tf2>
#include <tf2_stocks>
#include <tf2items>
#include <tf_econ_data>
#include <dhooks>

#define PLUGIN_VERSION       "0.9.3"

#define PVE_TEAM_HUMANS_NAME "blue"
#define PVE_TEAM_BOTS_NAME   "red"

#define UNCLE_DANE_STEAMID   "STEAM_0:0:48866904"

#define MAX_COSMETIC_ATTRS   8
#define GIBS_CLEANUP_PERIOD  10.0

#define GOLDEN_PAN_DEFID     1071
#define GOLDEN_PAN_CHANCE    1

#define TFTeam_Humans        TFTeam_Blue
#define TFTeam_Bots          TFTeam_Red

public Plugin myinfo =
{
    name        = "[TF2] Engineer PVE",
    author      = "Moonly Days, Uncle Dane",
    description = "Engineer PVE",
    version     = PLUGIN_VERSION,
    url         = "https://github.com/MoonlyDays/TF2_EngineerPVE"
};

/**
 * Definition of a TF2 attribute to apply to the bot.
 */
enum struct TFAttribute
{
    char  m_szName[PLATFORM_MAX_PATH];
    float m_flValue;
}

/**
 * Definition of a special game item to apply to the bot.
 */
enum struct BotItem
{
    int       m_iItemDefinitionIndex;
    char      m_szClassName[32];
    ArrayList m_Attributes;
}

//-----------------------------------------------------//
// List of Definitions
//-----------------------------------------------------//
ArrayList     g_hBotCosmetics;
ArrayList     g_hPlayerAttributes;
ArrayList     g_hBotNames;
ArrayList     g_hPrimaryWeapons;
ArrayList     g_hSecondaryWeapons;
ArrayList     g_hMeleeWeapons;

//-----------------------------------------------------//
// ConVar Definitions
//-----------------------------------------------------//
ConVar        tf_gamemode_cp;
ConVar        sm_engipve_bot_sapper_insta_remove;
ConVar        sm_engipve_respawn_bots_on_round_end;
ConVar        sm_engipve_allow_respawnroom_build;
ConVar        sm_engipve_clear_gibs;

//-----------------------------------------------------//
// SDK Calls and Detours
//-----------------------------------------------------//
Handle        g_SdkEquipWearable;
DynamicHook   g_HookHandleSwitchTeams;
DynamicDetour g_DetourPointIsWithin;
DynamicDetour g_DetourEstimateValidBuildPos;
DynamicDetour g_DetourCreateObjectGibs;
DynamicDetour g_DetourDropAmmoPack;
DynamicDetour g_DetourCreateRagdollEntity;
DynamicDetour g_DetourComputeIncursionDistance;

//-----------------------------------------------------//
// Memory Patches
//-----------------------------------------------------//

int           g_nOffset_CBaseEntity_m_iTeamNum;

// Reference to the team_round_timer entity to modify its' time value.
int           g_eTeamRoundTimer;
// Are we currently in round end period?
bool          g_bIsRoundEnd           = false;
// Are we currently in active round period?
bool          g_bIsRoundActive        = false;
bool          g_bIsFakeSetupActive    = false;
float         g_flFakeSetupEndTime    = 0.0;
bool          g_bIsHydro              = false;
// Is this map cp_steel?
bool          g_bIsSteel              = false;
bool          g_bSteelFirstCap        = false;
bool          g_bForceBotSpawnActive  = false;
float         g_vecForceBotSpawn[3];
// When did the round start?
float         g_flRoundStartTime      = 0.0;
// Current round time if a multimap stage
float         g_flCurrentMapTime      = 0.0;
// Is this map a multistage map
bool          g_bIsMultiStageMap      = false;

// List of entities that need to be cleaned up on arrival to save
// on edict count.
char          g_szCleanupEntities[][] = {
    "keyframe_rope",
    "move_rope",
    "env_sprite",
    "env_lightglow",
    "env_smokestack",
    "func_smokevolume",
    "func_dust",
    "func_dustmotes",
    "point_spotlight",
    "env_smoketrail",
    "env_sun",
    "halloween_souls_pack"
}

public OnPluginStart()
{
    GameData conf = new GameData("tf2.engipve");
    CreateTimer(0.5, Timer_UpdateRoundTime, _, TIMER_REPEAT);

    //-----------------------------------------------------//
    // CONVARS
    //-----------------------------------------------------//
    CreateConVar("engipve_version", PLUGIN_VERSION, "[TF2] Engineer PVE Version", FCVAR_DONTRECORD);
    sm_engipve_allow_respawnroom_build   = CreateConVar("sm_engipve_allow_respawnroom_build", "1", "Can humans build in respawn rooms?");
    sm_engipve_bot_sapper_insta_remove   = CreateConVar("sm_engipve_bot_sapper_insta_remove", "1", "Immediately destroys sappers placed by spy bots.");
    sm_engipve_respawn_bots_on_round_end = CreateConVar("sm_engipve_respawn_bots_on_round_end", "0", "Should we instantly respawn bots on round end? (Engineer Massacre)");
    sm_engipve_clear_gibs                = CreateConVar("sm_engipve_clear_gibs", "1", "Should we clean up gibs to save up on edicts?");
    tf_gamemode_cp                       = FindConVar("tf_gamemode_cp");

    //-----------------------------------------------------//
    // EVENTS
    //-----------------------------------------------------//
    HookEvent("post_inventory_application", post_inventory_application);
    HookEvent("player_spawn", player_spawn);
    HookEvent("teamplay_round_start", teamplay_round_start);
    HookEvent("teamplay_round_win", teamplay_round_win);
    HookEvent("teamplay_setup_finished", teamplay_setup_finished);
    HookEvent("teamplay_point_captured", teamplay_point_captured);
    HookEvent("player_death", player_death);

    //-----------------------------------------------------//
    // OFFSETS
    //-----------------------------------------------------//
    g_nOffset_CBaseEntity_m_iTeamNum = FindSendPropInfo("CBaseEntity", "m_iTeamNum");

    //-----------------------------------------------------//
    // SDK CALLS
    //-----------------------------------------------------//
    StartPrepSDKCall(SDKCall_Player);
    PrepSDKCall_SetFromConf(conf, SDKConf_Virtual, "CTFPlayer::EquipWearable");
    PrepSDKCall_AddParameter(SDKType_CBaseEntity, SDKPass_Pointer);
    g_SdkEquipWearable      = EndPrepSDKCall();

    //-----------------------------------------------------//
    // DYNAMIC HOOKS
    //-----------------------------------------------------//
    g_HookHandleSwitchTeams = DynamicHook.FromConf(conf, "CTFGameRules::HandleSwitchTeams");

    //-----------------------------------------------------//
    // DETOURS
    //-----------------------------------------------------//
    g_DetourPointIsWithin   = DynamicDetour.FromConf(conf, "PointIsWithin");
    g_DetourPointIsWithin.Enable(Hook_Pre, Detour_OnPointIsWithin);

    g_DetourEstimateValidBuildPos = DynamicDetour.FromConf(conf, "EstimateValidBuildPos");
    g_DetourEstimateValidBuildPos.Enable(Hook_Pre, Detour_EstimateValidBuildPos);
    g_DetourEstimateValidBuildPos.Enable(Hook_Post, Detour_EstimateValidBuildPos_Post);

    g_DetourCreateObjectGibs = DynamicDetour.FromConf(conf, "CBaseObject::CreateObjectGibs");
    g_DetourCreateObjectGibs.Enable(Hook_Pre, Detour_CreateObjectGibs);

    g_DetourDropAmmoPack = DynamicDetour.FromConf(conf, "CTFPlayer::DropAmmoPack");
    g_DetourDropAmmoPack.Enable(Hook_Pre, Detour_DropAmmoPack);

    g_DetourCreateRagdollEntity = DynamicDetour.FromConf(conf, "CTFPlayer::DropAmmoPack");
    g_DetourCreateRagdollEntity.Enable(Hook_Pre, Detour_CreateRagdollEntity);

    g_DetourComputeIncursionDistance = DynamicDetour.FromConf(conf, "CTFNavMesh::ComputeIncursionDistances");
    g_DetourComputeIncursionDistance.Enable(Hook_Pre, CTFNavMesh_ComputeIncursionDistance);
    g_DetourComputeIncursionDistance.Enable(Hook_Post, CTFNavMesh_ComputeIncursionDistance_Post);

    //-----------------------------------------------------//
    // COMMANDS
    //-----------------------------------------------------//
    RegAdminCmd("sm_engipve_reload", cReload, ADMFLAG_CHANGEMAP, "Reloads Engineer PVE config.");
    RegAdminCmd("sm_becomeengibot", cBecomeEngiBot, ADMFLAG_ROOT, "Switches the client to the bot team.");

    AddCommandListener(cJoinTeam, "jointeam");
    AddCommandListener(cAutoTeam, "autoteam");

    AutoExecConfig(true, "tf_engipve");
}

public void OnMapStart()
{
    char mapname[64];
    GetCurrentMap(mapname, sizeof(mapname));
    g_bIsHydro = StrEqual(mapname, "tc_hydro", false);
    g_bIsSteel = StrEqual(mapname, "cp_steel", false);

    // Disable boss spawn on map start
    ConVar hBossTime = FindConVar("tf_populator_active_boss_time");
    if (hBossTime != null)
    {
        hBossTime.SetInt(0);
    }
    
    // Config loading
    Config_Load();

    g_HookHandleSwitchTeams.HookGamerules(Hook_Pre, CTFGameRules_HandleSwitchTeams);
    g_bIsRoundActive = false;
    g_bIsMultiStageMap = false;
    g_flCurrentMapTime = 0.0;
}

public Action Timer_HydroUpdateObjectiveResource(Handle timer)
{
    int or = FindEntityByClassname(-1, "tf_objective_resource");
    if (or != -1)
    {
        SetEntProp(or, Prop_Send, "m_bPlayingMiniRounds", 0);
        for (int i = 0; i < 6; i++)
        {
            SetEntProp(or, Prop_Send, "m_bCPIsVisible", 1, 1, i);
            SetEntProp(or, Prop_Send, "m_bInMiniRound", 1, 1, i);
        }
        
        bool currentReset = GetEntProp(or, Prop_Send, "m_bControlPointsReset") != 0;
        SetEntProp(or, Prop_Send, "m_bControlPointsReset", !currentReset ? 1 : 0);
    }
    return Plugin_Handled;
}

void PVE_OnRoundStart_Hydro()
{
    // 1. Delete master and round control point entities
    int entity = -1;
    while ((entity = FindEntityByClassname(entity, "team_control_point_master")) != -1)
    {
        SetEntPropString(entity, Prop_Data, "m_iClassname", "TOBEDELETED");
        AcceptEntityInput(entity, "Disable");
        AcceptEntityInput(entity, "Kill");
    }
    entity = -1;
    while ((entity = FindEntityByClassname(entity, "team_control_point_round")) != -1)
    {
        SetEntPropString(entity, Prop_Data, "m_iClassname", "TOBEDELETED");
        AcceptEntityInput(entity, "Disable");
        AcceptEntityInput(entity, "Kill");
    }
    
    // 2. Spawn our own master
    int cpm = CreateEntityByName("team_control_point_master");
    if (cpm != -1)
    {
        DispatchKeyValue(cpm, "caplayout", "2 4,0 1 3 5");
        DispatchKeyValue(cpm, "cpm_restrict_team_cap_win", "2"); // RED win
        DispatchKeyValue(cpm, "switch_teams", "1");
        DispatchKeyValue(cpm, "score_style", "0");
        DispatchSpawn(cpm);
        
        AcceptEntityInput(cpm, "RoundSpawn");
        AcceptEntityInput(cpm, "RoundActivate");
    }
    
    int or = FindEntityByClassname(-1, "tf_objective_resource");
    if (or != -1)
    {
        SetEntProp(or, Prop_Send, "m_bPlayingMiniRounds", 0);
    }
    
    // Kill native timers
    entity = FindEntityByClassname(-1, "timer_dred");
    if (entity != -1) AcceptEntityInput(entity, "Kill");
    
    entity = FindEntityByClassname(-1, "timer_ablue");
    if (entity != -1) AcceptEntityInput(entity, "Kill");
    
    // Lock points for BLU, unlock for RED
    entity = -1;
    while ((entity = FindEntityByClassname(entity, "trigger_capture_area")) != -1)
    {
        SetVariantString("2 0");
        AcceptEntityInput(entity, "SetTeamCanCap");
        SetVariantString("3 1");
        AcceptEntityInput(entity, "SetTeamCanCap");
    }
    
    // Change owner of points to RED
    entity = -1;
    while ((entity = FindEntityByClassname(entity, "team_control_point")) != -1)
    {
        SetVariantString("2");
        AcceptEntityInput(entity, "Setowner");
    }
    
    // Clean up spawns
    entity = -1;
    while ((entity = FindEntityByClassname(entity, "info_player_teamspawn")) != -1)
    {
        SetEntPropString(entity, Prop_Data, "m_iszControlPointName", "");
        SetEntPropString(entity, Prop_Data, "m_iszRoundBlueSpawn", "");
        SetEntPropString(entity, Prop_Data, "m_iszRoundRedSpawn", "");
    }
    
    // Disable all hydro spawns
    char spawns[6][] = {"BLUE", "A", "B", "C", "D", "RED"};
    for (int i = 0; i < 6; i++)
    {
        PVE_SetHydroSpawnEnabled(spawns[i], 0, false);
    }
    
    // Set icons
    for (int i = 0; i < 6; i++)
    {
        char targetName[32];
        Format(targetName, sizeof(targetName), "cp_%s", spawns[i]);
        int cp = FindEntityByClassname(-1, "team_control_point");
        while (cp != -1)
        {
            char name[128];
            GetEntPropString(cp, Prop_Data, "m_iName", name, sizeof(name));
            if (StrEqual(name, targetName, false))
            {
                // Note: Updating models dynamically via KeyValues post-spawn might need SetEntPropString
                // But VScript uses KeyValueFromString and then DispatchSpawn again? We'll just ignore icons for now or use DispatchKeyValue
                break;
            }
            cp = FindEntityByClassname(cp, "team_control_point");
        }
    }
    
    PVE_SetHydroSpawnEnabled("A", TFTeam_Red, true);
    PVE_SetHydroSpawnEnabled("BLUE", TFTeam_Blue, true);
    
    CreateTimer(3.0, Timer_HydroUpdateObjectiveResource);
    
    // Fix trigger names
    entity = -1;
    while ((entity = FindEntityByClassname(entity, "trigger_multiple")) != -1)
    {
        SetEntPropString(entity, Prop_Data, "m_iName", "");
    }
    
    // Disable prop signs
    entity = -1;
    while ((entity = FindEntityByClassname(entity, "prop_dynamic")) != -1) // propsign_* are usually prop_dynamic
    {
        char name[128];
        GetEntPropString(entity, Prop_Data, "m_iName", name, sizeof(name));
        if (StrContains(name, "propsign_", false) == 0)
        {
            AcceptEntityInput(entity, "Disable");
        }
    }
    
    // Kill round brushes
    entity = -1;
    while ((entity = FindEntityByClassname(entity, "func_brush")) != -1)
    {
        char name[128];
        GetEntPropString(entity, Prop_Data, "m_iName", name, sizeof(name));
        if (StrContains(name, "round_", false) == 0 && StrContains(name, "brush", false) != -1)
        {
            AcceptEntityInput(entity, "Kill");
        }
    }
}

public OnClientPutInServer(int client)
{
    if (IsClientSourceTV(client) || IsClientReplay(client))
        return;

    CreateTimer(0.1, Timer_OnClientConnect, client);
}

/*
public bool OnClientConnect(int client, char[] rejectMsg, int maxlen)
{
    int maxHumans = MaxClients - tf_bot_quota.IntValue;
    if (PVE_GetHumanCount() > maxHumans)
    {
        Format(rejectMsg, maxlen, "[1000 Engis] No more human slots are available, sorry :C");
        return false;
    }

    return true;
}
*/

public OnEntityCreated(int entity, const char[] szClassname)
{
    for (int i = 0; i < sizeof(g_szCleanupEntities); i++)
    {
        if (StrEqual(szClassname, g_szCleanupEntities[i]))
        {
            RemoveEntity(entity);
            return;
        }
    }
    
    if (StrEqual(szClassname, "trigger_capture_area"))
    {
        SDKHook(entity, SDKHook_Touch, OnCaptureAreaTouch);
        SDKHook(entity, SDKHook_StartTouch, OnCaptureAreaTouch);
    }

    if (StrEqual(szClassname, "obj_attachment_sapper"))
    {
        SDKHook(entity, SDKHook_OnTakeDamage, OnSapperTakeDamage);
    }
}

//-------------------------------------------------------//
// CONFIG
//-------------------------------------------------------//

/** Reload the plugin config */
void Config_Load()
{
    // Build the path to the config file.
    char szCfgPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, szCfgPath, sizeof(szCfgPath), "configs/tf_engipve.cfg");

    // Load the keyvalues.
    KeyValues kv = new KeyValues("EngineerPVE");
    if (kv.ImportFromFile(szCfgPath) == false)
    {
        SetFailState("Failed to read configs/tf_engipve.cfg");
        return;
    }

    // Try to load bot names.
    if (kv.JumpToKey("Names"))
    {
        Config_LoadNamesFromKV(kv);
        kv.GoBack();
    }

    // Try to load bot cosmetics.
    if (kv.JumpToKey("Cosmetics"))
    {
        Config_LoadCosmeticsFromKV(kv);
        kv.GoBack();
    }

    // Try to load bot cosmetics.
    if (kv.JumpToKey("Weapons"))
    {
        Config_LoadWeaponsFromKV(kv);
        kv.GoBack();
    }

    // Try to load bot cosmetics.
    if (kv.JumpToKey("Attributes"))
    {
        Config_LoadAttributesFromKV(kv);
        kv.GoBack();
    }

    char szClassName[32];
    kv.GetString("Class", szClassName, sizeof(szClassName));
    FindConVar("tf_bot_force_class").SetString(szClassName);
    FindConVar("tf_bot_auto_vacate").SetBool(false);
    FindConVar("tf_bot_quota").SetInt(kv.GetNum("Count"));
    FindConVar("tf_bot_difficulty").SetInt(kv.GetNum("Difficulty"));
    FindConVar("mp_disable_respawn_times").SetBool(true);
    FindConVar("mp_teams_unbalance_limit").SetInt(0);
    FindConVar("tf_bot_max_teleport_entrance_travel").SetInt(-1);
}

/** Reload the bot names that will be on the bot team. */
void Config_LoadNamesFromKV(KeyValues kv)
{
    delete g_hBotNames;
    g_hBotNames = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));

    if (kv.GotoFirstSubKey(false))
    {
        do
        {
            char szName[PLATFORM_MAX_PATH];
            kv.GetString(NULL_STRING, szName, sizeof(szName));
            g_hBotNames.PushString(szName);
        }
        while (kv.GotoNextKey(false));

        kv.GoBack();
    }
}

/** Reload the bot names that will be on the bot team. */
void Config_LoadAttributesFromKV(KeyValues kv)
{
    delete g_hPlayerAttributes;
    g_hPlayerAttributes = new ArrayList(sizeof(TFAttribute));

    if (kv.GotoFirstSubKey(false))
    {
        do
        {
            // Read name and float value, add the pair to the attributes array.
            TFAttribute attrib;
            kv.GetSectionName(attrib.m_szName, sizeof(attrib.m_szName));
            attrib.m_flValue = kv.GetFloat(NULL_STRING);
            g_hPlayerAttributes.PushArray(attrib);
        }
        while (kv.GotoNextKey(false));

        kv.GoBack();
    }
}

void Config_LoadItemFromKV(KeyValues kv, BotItem buffer)
{
    // First check inlined definition.
    int inlineDefId = kv.GetNum(NULL_STRING, 0);
    if (inlineDefId > 0)
    {
        buffer.m_iItemDefinitionIndex = inlineDefId;
        return;
    }

    // Definition is not inlined
    buffer.m_iItemDefinitionIndex = kv.GetNum("Index");

    // Check if cosmetic definition contains attributes.
    if (kv.JumpToKey("Attributes"))
    {
        // If so, create an array list.
        buffer.m_Attributes = new ArrayList(sizeof(TFAttribute));

        // Try going to the first attribute scope.
        if (kv.GotoFirstSubKey(false))
        {
            do
            {
                // Read name and float value, add the pair to the attributes array.
                TFAttribute attrib;
                kv.GetSectionName(attrib.m_szName, sizeof(attrib.m_szName));
                attrib.m_flValue = kv.GetFloat(NULL_STRING);
                buffer.m_Attributes.PushArray(attrib);
            }
            while (kv.GotoNextKey(false));
            kv.GoBack();
        }
        kv.GoBack();
    }
}

/**
 * Load bot cosmetics definitions from config.
 */
void Config_LoadCosmeticsFromKV(KeyValues kv)
{
    Config_DisposeOfBotItemArrayList(g_hBotCosmetics);
    g_hBotCosmetics = new ArrayList(sizeof(BotItem));

    if (kv.GotoFirstSubKey(false))
    {
        do
        {
            // Create bot cosmetic definition.
            BotItem item;
            Config_LoadItemFromKV(kv, item);
            g_hBotCosmetics.PushArray(item);
        }
        while (kv.GotoNextKey(false));

        kv.GoBack();
    }
}

/**
 * Load bot cosmetics definitions from config.
 */
void Config_LoadWeaponsFromKV(KeyValues kv)
{
    Config_DisposeOfBotItemArrayList(g_hPrimaryWeapons);
    Config_DisposeOfBotItemArrayList(g_hSecondaryWeapons);
    Config_DisposeOfBotItemArrayList(g_hMeleeWeapons);

    if (kv.JumpToKey("Primary"))
    {
        Config_LoadWeaponsFromKVToArray(kv, g_hPrimaryWeapons);
        kv.GoBack();
    }

    if (kv.JumpToKey("Secondary"))
    {
        Config_LoadWeaponsFromKVToArray(kv, g_hSecondaryWeapons);
        kv.GoBack();
    }

    if (kv.JumpToKey("Melee"))
    {
        Config_LoadWeaponsFromKVToArray(kv, g_hMeleeWeapons);
        kv.GoBack();
    }
}

/**
 * Load bot cosmetics definitions from config.
 */
void Config_LoadWeaponsFromKVToArray(KeyValues kv, ArrayList& array)
{
    array = new ArrayList(sizeof(BotItem));

    if (kv.GotoFirstSubKey(false))
    {
        do
        {
            // Create bot cosmetic definition.
            BotItem item;
            Config_LoadItemFromKV(kv, item);
            array.PushArray(item);
        }
        while (kv.GotoNextKey(false));

        kv.GoBack();
    }
}

void Config_DisposeOfBotItemArrayList(ArrayList array)
{
    if (array)
    {
        for (int i = 0; i < array.Length; i++)
        {
            BotItem item;
            array.GetArray(i, item);
            delete item.m_Attributes;
        }
    }

    delete array;
}

//-------------------------------------------------------//
// GAMEMODE STOCKS
//-------------------------------------------------------//

// Give bot a name from the config
void PVE_RenameBotClient(int client)
{
    // Figure out the name of the bot.
    // Make a static variable to store current local name index.
    static int currentName = -1;
    // Rotate the names
    int        maxNames    = g_hBotNames.Length;
    currentName++;
    currentName = currentName % maxNames;

    char szName[PLATFORM_MAX_PATH];
    g_hBotNames.GetString(currentName, szName, sizeof(szName));
    SetClientName(client, szName);
}

// Equip bots with appropriate weapons
void PVE_EquipBotItems(int client)
{
    for (int i = 0; i < g_hBotCosmetics.Length; i++)
    {
        BotItem cosmetic;
        g_hBotCosmetics.GetArray(i, cosmetic);

        int hat = PVE_GiveWearableToClient(client, cosmetic.m_iItemDefinitionIndex);
        if (hat <= 0)
        {
            continue;
        }

        PVE_ApplyBotItemAttributesOnEntity(hat, cosmetic);
    }

    PVE_GiveBotRandomSlotWeaponFromArrayList(client, TFWeaponSlot_Primary, g_hPrimaryWeapons);
    PVE_GiveBotRandomSlotWeaponFromArrayList(client, TFWeaponSlot_Secondary, g_hSecondaryWeapons);
    PVE_GiveBotRandomSlotWeaponFromArrayList(client, TFWeaponSlot_Melee, g_hMeleeWeapons);

    for (int i = TFWeaponSlot_Primary; i <= TFWeaponSlot_Melee; i++)
    {
        int weapon = GetPlayerWeaponSlot(client, i);
        if (!IsValidEntity(weapon))
            continue;

        int specKs = GetRandomInt(2002, 2008);
        int profKs = GetRandomInt(1, 7);

        TF2Attrib_SetByName(weapon, "killstreak tier", 3.0);
        TF2Attrib_SetByName(weapon, "killstreak effect", float(specKs));
        TF2Attrib_SetByName(weapon, "killstreak idleeffect", float(profKs));
    }
}

// Give a bot a random weapon in slot from an array defined in ArrayList
void PVE_GiveBotRandomSlotWeaponFromArrayList(int client, int slot, ArrayList array)
{
    if (array == INVALID_HANDLE)
    {
        return;
    }

    int     rndInt = GetRandomInt(0, array.Length - 1);
    BotItem item;
    array.GetArray(rndInt, item);

    int  wepDefId    = item.m_iItemDefinitionIndex;
    bool isGoldenPan = false;

    // Golden Pan Easter Egg!!!
    if (slot == TFWeaponSlot_Melee)
    {
        if (GetRandomInt(0, 100) < GOLDEN_PAN_CHANCE)
        {
            // Bot has 1% chance to have Golden Pan
            // as their melee.
            wepDefId    = GOLDEN_PAN_DEFID;
            isGoldenPan = true;
        }
    }

    char szClassName[64];
    TF2Econ_GetItemClassName(wepDefId, szClassName, sizeof(szClassName));
    TF2Econ_TranslateWeaponEntForClass(szClassName, sizeof(szClassName), TF2_GetPlayerClass(client));

    Handle hWeapon = TF2Items_CreateItem(OVERRIDE_ALL | FORCE_GENERATION | PRESERVE_ATTRIBUTES);
    TF2Items_SetClassname(hWeapon, szClassName);
    TF2Items_SetItemIndex(hWeapon, wepDefId);

    int iWeapon = TF2Items_GiveNamedItem(client, hWeapon);
    delete hWeapon;

    if (isGoldenPan)
    {
        TF2Attrib_SetByName(iWeapon, "item style override", 0.0);
    }

    int prevWeapon = GetPlayerWeaponSlot(client, slot);
    if (prevWeapon != -1)
    {
        int accountId = GetEntProp(prevWeapon, Prop_Send, "m_iAccountID");
        SetEntProp(iWeapon, Prop_Send, "m_iAccountID", accountId);
    }

    TF2_RemoveWeaponSlot(client, slot);
    EquipPlayerWeapon(client, iWeapon);

    PVE_ApplyBotItemAttributesOnEntity(iWeapon, item);
}

// Apply attributes from config item defintion on entity.
void PVE_ApplyBotItemAttributesOnEntity(int entity, BotItem item)
{
    if (item.m_Attributes)
    {
        for (int j = 0; j < item.m_Attributes.Length; j++)
        {
            TFAttribute attrib;
            item.m_Attributes.GetArray(j, attrib);
            TF2Attrib_SetByName(entity, attrib.m_szName, attrib.m_flValue);
        }
    }
}

// Apply player attributes from config on a given client
void PVE_ApplyPlayerAttributes(int client)
{
    for (int i = 0; i < g_hPlayerAttributes.Length; i++)
    {
        TFAttribute attrib;
        g_hPlayerAttributes.GetArray(i, attrib);
        TF2Attrib_SetByName(client, attrib.m_szName, attrib.m_flValue);
    }
}

// Create and give wearable to client with a given item definition
int PVE_GiveWearableToClient(int client, int itemDef)
{
    int hat = CreateEntityByName("tf_wearable");
    if (!IsValidEntity(hat))
    {
        return -1;
    }

    SetEntProp(hat, Prop_Send, "m_iItemDefinitionIndex", itemDef);
    SetEntProp(hat, Prop_Send, "m_bInitialized", 1);
    SetEntProp(hat, Prop_Send, "m_iEntityLevel", 50);
    SetEntProp(hat, Prop_Send, "m_bValidatedAttachedEntity", 1);
    SetEntProp(hat, Prop_Send, "m_iAccountID", GetSteamAccountID(client));
    SetEntPropEnt(hat, Prop_Send, "m_hOwnerEntity", client);
    DispatchSpawn(hat);
    ActivateEntity(hat);

    SDKCall(g_SdkEquipWearable, client, hat);
    return hat;
}

void PVE_DisableCTFBLUFlag()
{
    int flag_count = 0;
    int flag_blu = -1;
    int entity = -1;

    while ((entity = FindEntityByClassname(entity, "item_teamflag")) != -1)
    {
        flag_count++;
        int team = GetEntProp(entity, Prop_Send, "m_iTeamNum");
        int flagtype = GetEntProp(entity, Prop_Send, "m_nType");
        
        // Find defending team's flag (BLU)
        if (team == ((flagtype != 0 && flagtype != 5) ? 2 : 3))
        {
            flag_blu = entity;
        }
    }
    
    if (flag_count > 1 && flag_blu != -1)
    {
        AcceptEntityInput(flag_blu, "ForceResetAndDisableSilent");
    }
}

void PVE_SetupMapControlPoints()
{
    if (g_bIsSteel)
    {
        return;
    }

    char mapname[128];
    GetCurrentMap(mapname, sizeof(mapname));
    bool isHydro = (StrContains(mapname, "tc_hydro") != -1);
    
    if (isHydro)
    {
        int roundEnt = -1;
        while ((roundEnt = FindEntityByClassname(roundEnt, "team_control_point_round")) != -1)
        {
            AcceptEntityInput(roundEnt, "Kill");
        }
    }
    
    // Prevent RED from winning by setting m_iInvalidCapWinner on master
    int master = FindEntityByClassname(-1, "team_control_point_master");
    if (master != -1)
    {
        SetEntProp(master, Prop_Data, "m_iInvalidCapWinner", 2); // 2 is RED
    }

    int points[16];
    int pointCount = 0;
    
    int cp = -1;
    while ((cp = FindEntityByClassname(cp, "team_control_point")) != -1 && pointCount < 16)
    {
        points[pointCount++] = cp;
    }
    
    if (pointCount <= 1) return;
    
    // Sort points by m_iPointIndex
    for (int i = 0; i < pointCount - 1; i++)
    {
        for (int j = 0; j < pointCount - i - 1; j++)
        {
            int idx1 = GetEntProp(points[j], Prop_Data, "m_iPointIndex");
            int idx2 = GetEntProp(points[j+1], Prop_Data, "m_iPointIndex");
            if (idx1 > idx2)
            {
                int temp = points[j];
                points[j] = points[j+1];
                points[j+1] = temp;
            }
        }
    }
    
    int or = FindEntityByClassname(-1, "tf_objective_resource");
    
    // Give all points to RED and setup linear capture for BLU
    int bluStartPoint = -1;
    if (GetEntProp(points[pointCount - 1], Prop_Data, "m_iTeamNum") == 3 || GetEntProp(points[pointCount - 1], Prop_Data, "m_iDefaultOwner") == 3)
    {
        bluStartPoint = pointCount - 1;
    }
    else
    {
        bluStartPoint = 0; // Fallback to 0 if we can't tell, or if BLU owns 0.
    }

    for (int i = 0; i < pointCount; i++)
    {
        int ent = points[i];
        int point_index = GetEntProp(ent, Prop_Data, "m_iPointIndex");
        
        int state = GameRules_GetProp("m_iRoundState");
        GameRules_SetProp("m_iRoundState", 4); // GR_STATE_RND_RUNNING
        
        SetVariantString("2");
        AcceptEntityInput(ent, "SetOwner", ent, ent);
        SetVariantInt(2);
        AcceptEntityInput(ent, "SetOwner", ent, ent);
        
        SetEntProp(ent, Prop_Data, "m_iTeamNum", 2);
        SetEntProp(ent, Prop_Data, "m_iDefaultOwner", 2);
        
        GameRules_SetProp("m_iRoundState", state);
        
        char prevName[128] = "";
        int prev_point_index = -1;
        
        if (bluStartPoint == pointCount - 1)
        {
            // BLU captures from highest index down to 0
            if (i < pointCount - 1)
            {
                GetEntPropString(points[i+1], Prop_Data, "m_iName", prevName, sizeof(prevName));
                prev_point_index = GetEntProp(points[i+1], Prop_Data, "m_iPointIndex");
            }
        }
        else
        {
            // BLU captures from 0 up to highest index
            if (i > 0)
            {
                GetEntPropString(points[i-1], Prop_Data, "m_iName", prevName, sizeof(prevName));
                prev_point_index = GetEntProp(points[i-1], Prop_Data, "m_iPointIndex");
            }
        }
        
        DispatchKeyValue(ent, "team_previouspoint_3_0", prevName);
        DispatchKeyValue(ent, "team_previouspoint_3_1", "");
        DispatchKeyValue(ent, "team_previouspoint_3_2", "");
        
        // Prevent RED from ever capturing by requiring an impossible point
        DispatchKeyValue(ent, "team_previouspoint_2_0", "PVE_LOCKED_POINT_IMPOSSIBLE");
        DispatchKeyValue(ent, "team_previouspoint_2_1", "");
        DispatchKeyValue(ent, "team_previouspoint_2_2", "");

        if (or != -1)
        {
            SetEntProp(or, Prop_Send, "m_iOwner", 2, _, point_index);
            
            // Allow BLU (Team 3) to cap
            SetEntProp(or, Prop_Send, "m_bTeamCanCap", 1, _, point_index + 3 * 8);
            // Prevent RED (Team 2) from capping
            SetEntProp(or, Prop_Send, "m_bTeamCanCap", 0, _, point_index + 2 * 8);
            
            int iIntIndexBLU = (3 * 8 * 3) + (point_index * 3); // 72 + point_index * 3
            
            SetEntProp(or, Prop_Send, "m_iPreviousPoints", prev_point_index, _, iIntIndexBLU + 0);
            SetEntProp(or, Prop_Send, "m_iPreviousPoints", -1, _, iIntIndexBLU + 1);
            SetEntProp(or, Prop_Send, "m_iPreviousPoints", -1, _, iIntIndexBLU + 2);
        }
    }
}

public Action Timer_SetupMapControlPoints(Handle timer)
{
    PVE_SetupMapControlPoints();
    return Plugin_Stop;
}

//-------------------------------------------------------//
// Commands
//-------------------------------------------------------//

// sv_danepve_reload
Action cReload(int client, int args)
{
    Config_Load();
    ReplyToCommand(client, "[SM] Engineer PVE config was reloaded!");
    return Plugin_Handled;
}

Action cJoinTeam(int client, const char[] command, int argc)
{
    // A human wishes to change their team.
    char szTeamArg[11];
    GetCmdArg(1, szTeamArg, sizeof(szTeamArg));

    // Whitelist spectator commands.
    if (StrEqual(szTeamArg, "spec", false) || StrEqual(szTeamArg, "spectate", false) || StrEqual(szTeamArg, "spectator", false) || StrEqual(szTeamArg, "blue", false))
    {
        return Plugin_Continue;
    }

    ClientCommand(client, "jointeam blue");
    return Plugin_Handled;
}

Action cAutoTeam(int client, const char[] command, int argc)
{
    ClientCommand(client, "jointeam blue");
    return Plugin_Handled;
}

// sm_becomeengibot
Action cBecomeEngiBot(int client, int args)
{
    TF2_ChangeClientTeam(client, TFTeam_Bots);
    PrintCenterText(client, "You are now an Engineer bot!");
    return Plugin_Handled;
}

//-------------------------------------------------------//
// Game Events
//-------------------------------------------------------//
public Action post_inventory_application(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));

    if (IsFakeClient(client))
    {
        PVE_EquipBotItems(client);
        PVE_ApplyPlayerAttributes(client);
    }

    return Plugin_Continue;
}

public Action player_spawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (g_bIsSteel && g_bForceBotSpawnActive && IsFakeClient(client))
    {
        // Teleport the bot to the forced spawn location after a short delay
        CreateTimer(0.1, Timer_TeleportBot, GetClientUserId(client));
    }

    return Plugin_Continue;
}

public Action Timer_TeleportBot(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client > 0 && IsClientInGame(client) && IsPlayerAlive(client) && g_bIsSteel && g_bForceBotSpawnActive)
    {
        TeleportEntity(client, g_vecForceBotSpawn, NULL_VECTOR, NULL_VECTOR);
    }
    return Plugin_Handled;
}

public Action player_death(Event event, const char[] name, bool dontBroadcast)
{
    int  client = GetClientOfUserId(event.GetInt("userid"));
    bool isBot  = IsFakeClient(client);

    // If we're on round end
    if (g_bIsRoundEnd)
    {
        // And we don't want to respawn bots during round end.
        if (!sm_engipve_respawn_bots_on_round_end.BoolValue)
        {
            // Bail out.
            return Plugin_Handled;
        }
    }

    if (isBot)
    {
        CreateTimer(0.1, Timer_RespawnBot, client);
    }

    return Plugin_Continue;
}

public Action teamplay_setup_finished(Event event, const char[] name, bool dontBroadcast)
{
    g_bIsRoundActive   = true;
    g_flRoundStartTime = GetGameTime();

    if (g_bIsMultiStageMap)
    {
        g_flRoundStartTime = GetGameTime() - g_flCurrentMapTime;
        // slightly hacky: do not change start time twice (the map would have to have reset anyways)
        g_bIsMultiStageMap = false;
    }
    g_eTeamRoundTimer  = FindEntityByClassname(-1, "team_round_timer");

    PVE_DisableCTFBLUFlag();
    CreateTimer(0.1, Timer_SetupMapControlPoints);

    return Plugin_Continue;
}

public Action teamplay_point_captured(Event event, const char[] name, bool dontBroadcast)
{
    if (g_bIsHydro)
    {
        char pointorder[6][] = {"BLUE", "A", "B", "C", "D", "RED"};
        int team = GetEventInt(event, "team");
        int point = GetEventInt(event, "cp");
        
        // Re-enable correct sign
        int entity = -1;
        while ((entity = FindEntityByClassname(entity, "prop_dynamic")) != -1)
        {
            char nameEntity[128];
            GetEntPropString(entity, Prop_Data, "m_iName", nameEntity, sizeof(nameEntity));
            if (StrContains(nameEntity, "propsign_", false) == 0)
            {
                AcceptEntityInput(entity, "Disable");
            }
        }
        
        char targetSign[64];
        char signSuffix[6][] = {"luetoa", "tob", "toc", "tod", "tored", ""};
        for (int i = 0; i < 5; i++)
        {
            Format(targetSign, sizeof(targetSign), "propsign_%s%s", pointorder[i], signSuffix[point]);
            entity = -1;
            while ((entity = FindEntityByClassname(entity, "prop_dynamic")) != -1)
            {
                char nameEntity[128];
                GetEntPropString(entity, Prop_Data, "m_iName", nameEntity, sizeof(nameEntity));
                if (StrEqual(nameEntity, targetSign, false))
                {
                    AcceptEntityInput(entity, "Enable");
                    SetVariantInt(1);
                    AcceptEntityInput(entity, "Skin");
                }
            }
        }
        
        if (point != 0 && point != 5)
        {
            PVE_SetHydroSpawnEnabled(pointorder[point - 1], team == view_as<int>(TFTeam_Red) ? view_as<int>(TFTeam_Blue) : 0, team == view_as<int>(TFTeam_Blue));
            PVE_SetHydroSpawnEnabled(pointorder[point], team, team == view_as<int>(TFTeam_Blue));
            PVE_SetHydroSpawnEnabled(pointorder[point + 1], team == view_as<int>(TFTeam_Blue) ? view_as<int>(TFTeam_Red) : 0, team == view_as<int>(TFTeam_Blue));
        }
    }

    if (g_bIsFakeSetupActive)
    {
        return Plugin_Handled;
    }

    if (!tf_gamemode_cp.BoolValue)
    {
        return Plugin_Continue;
    }

    int cp = event.GetInt("cp");
    int team = event.GetInt("team");
    
    // Dynamically clear the requirement for the next point to forcefully unlock it
    if (team == 3 && !g_bIsSteel) // BLU
    {
        int or = FindEntityByClassname(-1, "tf_objective_resource");
        if (or != -1)
        {
            for (int i = 0; i < 8; i++)
            {
                int prev_point = GetEntProp(or, Prop_Send, "m_iPreviousPoints", _, (3 * 8 * 3) + (i * 3));
                if (prev_point == cp)
                {
                    // This point (index i) required the point we just captured. Force it to unlock!
                    SetEntProp(or, Prop_Send, "m_iPreviousPoints", -1, _, (3 * 8 * 3) + (i * 3));
                    SetEntProp(or, Prop_Send, "m_bTeamCanCap", 1, _, i + 3 * 8);
                    
                    int ent = -1;
                    while ((ent = FindEntityByClassname(ent, "team_control_point")) != -1)
                    {
                        if (GetEntProp(ent, Prop_Data, "m_iPointIndex") == i)
                        {
                            DispatchKeyValue(ent, "team_previouspoint_3_0", "");
                            DispatchKeyValue(ent, "team_previouspoint_3_1", "");
                            DispatchKeyValue(ent, "team_previouspoint_3_2", "");
                            break;
                        }
                    }
                }
            }
        }
    }
    if (g_bIsSteel)
    {
        if (g_bSteelFirstCap)
        {
            g_bForceBotSpawnActive = true;
            g_vecForceBotSpawn[0] = 400.0;
            g_vecForceBotSpawn[1] = -1024.0;
            g_vecForceBotSpawn[2] = -125.0;
        }
        else
        {
            g_bForceBotSpawnActive = false;
        }
        g_bSteelFirstCap = false;
    }

    return Plugin_Continue;
}

public Action teamplay_round_win(Event event, const char[] name, bool dontBroadcast)
{
    int FullRound = event.GetInt("full_round");
    g_bIsRoundActive = false;
    g_bIsRoundEnd    = true;

    if (FullRound <= 0)
    {
        if (g_eTeamRoundTimer != -1)
        {
            g_bIsMultiStageMap = true;
            g_flCurrentMapTime = GetEntPropFloat(g_eTeamRoundTimer, Prop_Send, "m_flTimeRemaining");
        }
    }
    else
    {
        g_bIsMultiStageMap = false;
    }

    return Plugin_Continue;
}

public Action Timer_HydroRespawnAll(Handle timer)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && GetClientTeam(i) > 1) // Team 2 (RED) or 3 (BLU)
        {
            TF2_RespawnPlayer(i);
        }
    }
    return Plugin_Handled;
}

public Action teamplay_round_start(Event event, const char[] name, bool dontBroadcast)
{
    if (g_bIsHydro)
    {
        PVE_OnRoundStart_Hydro();
        // Spawns were just reconfigured, but players might have already spawned in the wrong places!
        CreateTimer(0.1, Timer_HydroRespawnAll);
    }
    
    if (g_bIsSteel)
    {
        g_bSteelFirstCap = true;
        g_bForceBotSpawnActive = false;
        PVE_SetRequiredCapturePoint("final_cap_flag", "cap_d_flag", TFTeam_Humans);
    }

    int FullReset = event.GetInt("full_reset");
    if (FullReset > 0) {
        g_bIsMultiStageMap = false;
        g_flCurrentMapTime = 0.0;
    }
    
    g_flRoundStartTime = GetGameTime();

    g_bIsRoundEnd    = false;
    g_bIsRoundActive = false;

    // Timer Modification: Find or Create a timer for all maps to act as a stopwatch
    g_eTeamRoundTimer = FindEntityByClassname(-1, "team_round_timer");
    if (g_eTeamRoundTimer == -1)
    {
        g_eTeamRoundTimer = CreateEntityByName("team_round_timer");
        if (g_eTeamRoundTimer != -1)
        {
            DispatchKeyValue(g_eTeamRoundTimer, "show_in_hud", "1");
            DispatchKeyValue(g_eTeamRoundTimer, "timer_length", "99999");
            DispatchSpawn(g_eTeamRoundTimer);
        }
    }
    
    if (g_eTeamRoundTimer != -1)
    {
        SetVariantInt(1);
        AcceptEntityInput(g_eTeamRoundTimer, "ShowInHUD");
        AcceptEntityInput(g_eTeamRoundTimer, "Enable");
    }

    // If there is no setup time on this map, start a fake setup time instead!
    if (!GameRules_GetProp("m_bInSetup"))
    {
        g_bIsFakeSetupActive = true;
        g_flFakeSetupEndTime = GetGameTime() + 90.0;
        g_bIsRoundActive   = false;
        
        PVE_SetBluSpawnDoorsState(true); // Lock the doors!
        PrintCenterTextAll("Setup time: 90 seconds!");
    }

    PVE_DisableCTFBLUFlag();
    CreateTimer(0.1, Timer_SetupMapControlPoints);

    return Plugin_Continue;
}

//-------------------------------------------------------//
// TIMERS
//-------------------------------------------------------//
public Action Timer_OnClientConnect(Handle timer, any client)
{
    if (IsFakeClient(client))
    {
        // Bots need to be renamed, and force their team to RED.
        PVE_RenameBotClient(client);
        TF2_ChangeClientTeam(client, TFTeam_Bots);
    }

    return Plugin_Handled;
}

public Action Timer_RespawnBot(Handle timer, any client)
{
    TF2_RespawnPlayer(client);
    return Plugin_Handled;
}

void PVE_SetBluSpawnDoorsState(bool bLock)
{
    // Modify team filters so BLU players are blocked by spawn room triggers/doors
    // This perfectly replicates the VScript method without locking normal 'blu' doors
    char filterClasses[2][] = {"filter_activator_tfteam", "filter_activator_team"};
    for (int i = 0; i < sizeof(filterClasses); i++)
    {
        int filter = -1;
        while ((filter = FindEntityByClassname(filter, filterClasses[i])) != -1)
        {
            if (HasEntProp(filter, Prop_Data, "m_iTeamNum"))
            {
                int currentTeam = GetEntProp(filter, Prop_Data, "m_iTeamNum");
                if (bLock)
                {
                    if (currentTeam == view_as<int>(TFTeam_Humans)) // Team 3 (BLU)
                    {
                        SetEntProp(filter, Prop_Data, "m_iTeamNum", 5); // Lock it for BLU by setting to Unassigned (5)
                    }
                }
                else
                {
                    if (currentTeam == 5) // Was overridden to 5
                    {
                        SetEntProp(filter, Prop_Data, "m_iTeamNum", view_as<int>(TFTeam_Humans)); // Restore to BLU
                    }
                }
            }
        }
    }
}

public Action Timer_EnableTriggers(Handle timer)
{
    int trigger = -1;
    while ((trigger = FindEntityByClassname(trigger, "trigger_multiple")) != -1)
    {
        if (IsValidEntity(trigger))
        {
            AcceptEntityInput(trigger, "Enable");
        }
    }
    return Plugin_Handled;
}

void PVE_RefreshDoorTriggers()
{
    // Find all trigger_multiple and Disable them, then Enable them 0.1s later.
    // This forces them to re-evaluate their Touch events, opening doors if a player is standing in them.
    int trigger = -1;
    while ((trigger = FindEntityByClassname(trigger, "trigger_multiple")) != -1)
    {
        if (IsValidEntity(trigger) && !GetEntProp(trigger, Prop_Data, "m_bDisabled"))
        {
            AcceptEntityInput(trigger, "Disable");
        }
    }
    CreateTimer(0.1, Timer_EnableTriggers);
}

public Action Timer_UpdateRoundTime(Handle timer, any ent)
{
    if (g_eTeamRoundTimer <= 0)
    {
        return Plugin_Handled;
    }

    float curTime = GetGameTime();

    if (g_bIsFakeSetupActive)
    {
        float remaining = g_flFakeSetupEndTime - curTime;
        if (remaining <= 0.0)
        {
            // Fake setup time is over!
            g_bIsFakeSetupActive = false;
            g_bIsRoundActive = true;
            g_flRoundStartTime = curTime;
            
            PVE_SetBluSpawnDoorsState(false); // Unlock doors!
            PVE_RefreshDoorTriggers(); // Force triggers to re-evaluate so doors open!
            PrintCenterTextAll("Setup time is over! Defend!");
        }
        else
        {
            // Update HUD timer to show fake setup countdown
            int iRemaining = RoundToCeil(remaining);
            SetVariantInt(iRemaining);
            AcceptEntityInput(g_eTeamRoundTimer, "SetMaxTime");
            SetVariantInt(iRemaining);
            AcceptEntityInput(g_eTeamRoundTimer, "SetTime");
            AcceptEntityInput(g_eTeamRoundTimer, "Pause");

            return Plugin_Handled;
        }
    }

    // Round is not active - do nothing.
    if (!g_bIsRoundActive)
    {
        return Plugin_Handled;
    }

    float startTime  = g_flRoundStartTime;
    float elapsTime  = curTime - startTime;
    int   iElapsTime = RoundToFloor(elapsTime);

    SetVariantInt(iElapsTime);
    AcceptEntityInput(g_eTeamRoundTimer, "SetMaxTime");
    SetVariantInt(iElapsTime);
    AcceptEntityInput(g_eTeamRoundTimer, "SetTime");
    AcceptEntityInput(g_eTeamRoundTimer, "Pause");

    return Plugin_Handled;
}

//-------------------------------------------------------//
// SDK Hooks
//-------------------------------------------------------//
public Action OnCaptureAreaTouch(int entity, int other)
{
    // Ignore non-players
    if (other <= 0 || other > MaxClients)
    {
        return Plugin_Continue;
    }

    if (!tf_gamemode_cp.BoolValue)
    {
        return Plugin_Continue;
    }

    if (g_bIsHydro && g_bIsFakeSetupActive)
    {
        // Block all captures during fake setup time
        return Plugin_Handled;
    }

    if (GetClientTeam(other) == 2) // RED team
    {
        // Block RED team entirely from even registering as standing on the capture area
        return Plugin_Handled;
    }

    return Plugin_Continue;
}

public Action OnSapperTakeDamage(int victim, int& attacker, int& inflictor, float& damage, int& damagetype)
{
    if (!sm_engipve_bot_sapper_insta_remove.BoolValue)
        return Plugin_Handled;

    if (IsClientInGame(attacker))
    {
        if (TF2_GetClientTeam(attacker) == TFTeam_Bots)
        {
            damage = 9999.0;
            return Plugin_Changed;
        }
    }

    return Plugin_Handled;
}

//-------------------------------------------------------//
// DHook
//-------------------------------------------------------//

int        g_bAllowNextHumanTeamPointCheck = false;

// CBaseObject::CreateObjectGibs
MRESReturn Detour_CreateObjectGibs(int pThis)
{
    return sm_engipve_clear_gibs.BoolValue
             ? MRES_Supercede
             : MRES_Ignored;
}

// CBaseObject::CreateObjectGibs
MRESReturn Detour_DropAmmoPack(int pThis, Handle hParams)
{
    return sm_engipve_clear_gibs.BoolValue
             ? MRES_Supercede
             : MRES_Ignored;
}

// CTFPlayer::CreateRagdollEntity
MRESReturn Detour_CreateRagdollEntity(int pThis, Handle hParams)
{
    if (sm_engipve_clear_gibs.BoolValue)
    {
        TFTeam team = TF2_GetClientTeam(pThis);
        if (team == TFTeam_Bots)
        {
            return MRES_Supercede;
        }
    }

    return MRES_Ignored;
}

// CBaseObject::EstimateValidBuildPos
MRESReturn Detour_EstimateValidBuildPos(Address pThis, Handle hReturn, Handle hParams)
{
    if (!sm_engipve_allow_respawnroom_build.BoolValue)
        return MRES_Ignored;

    g_bAllowNextHumanTeamPointCheck = true;
    return MRES_Ignored;
}

// CBaseObject::EstimateValidBuildPos
MRESReturn Detour_EstimateValidBuildPos_Post(Address pThis, Handle hReturn, Handle hParams)
{
    g_bAllowNextHumanTeamPointCheck = false;
    return MRES_Ignored;
}

// CBaseTrigger::PointIsWithin
MRESReturn Detour_OnPointIsWithin(Address pThis, Handle hReturn, Handle hParams)
{
    if (g_bAllowNextHumanTeamPointCheck)
    {
        Address addrTeam = pThis + view_as<Address>(g_nOffset_CBaseEntity_m_iTeamNum);
        TFTeam  iTeam    = view_as<TFTeam>(LoadFromAddress(addrTeam, NumberType_Int8));

        if (iTeam == TFTeam_Humans)
        {
            DHookSetReturn(hReturn, false);
            return MRES_Supercede;
        }
    }

    return MRES_Ignored;
}

// void CTFGameRules::HandleSwitchTeams( void );
public MRESReturn CTFGameRules_HandleSwitchTeams(int pThis, Handle hParams)
{
    PrintToChatAll("Team switching is disabled.");
    return MRES_Supercede;
}

// void CTFNavMesh::ComputeIncursionDistance( void );
public MRESReturn CTFNavMesh_ComputeIncursionDistance()
{
    PerformEnclosureFixes(true);
    return MRES_Ignored;
}

// void CTFNavMesh::ComputeIncursionDistance( void );
public MRESReturn CTFNavMesh_ComputeIncursionDistance_Post()
{
    PerformEnclosureFixes(false);
    return MRES_Ignored;
}

void PerformEnclosureFixes(bool apply)
{
    char szMap[32];
    GetCurrentMap(szMap, sizeof(szMap));
    const float upOffset = 48.0;

    if (!StrEqual(szMap, "pl_enclosure_final"))
    {
        return;
    }

    int point = -1;
    while ((point = FindEntityByClassname(point, "info_player_teamspawn")) != -1)
    {
        char szName[32];
        GetEntPropString(point, Prop_Data, "m_iszRoundBlueSpawn", szName, sizeof(szName));
        int teamNum  = GetEntProp(point, Prop_Send, "m_iTeamNum");
        int disabled = GetEntProp(point, Prop_Data, "m_bDisabled");

        if (!(!disabled && teamNum == 3 && StrEqual(szName, "mspl_round_2")))
        {
            continue;
        }

        float vecPos[3];
        GetEntPropVector(point, Prop_Data, "m_vecAbsOrigin", vecPos);
        vecPos[2] += apply ? upOffset : -upOffset;
        SetEntPropVector(point, Prop_Data, "m_vecAbsOrigin", vecPos);
    }
}

void PVE_SetHydroSpawnEnabled(const char[] spawnname, int team, bool bForward)
{
    char target[128];
    int entity = -1;
    
    // spawnpoints
    Format(target, sizeof(target), "spawn_%s", spawnname);
    while ((entity = FindEntityByClassname(entity, "info_player_teamspawn")) != -1)
    {
        char name[128];
        GetEntPropString(entity, Prop_Data, "m_iName", name, sizeof(name));
        if (StrEqual(name, target, false))
        {
            SetVariantInt(team != 0 ? team : 1);
            AcceptEntityInput(entity, "SetTeam");
            AcceptEntityInput(entity, team != 0 ? "Enable" : "Disable");
        }
    }
    
    // spawnrooms
    Format(target, sizeof(target), "spawn_%s_trigger", spawnname);
    entity = -1;
    while ((entity = FindEntityByClassname(entity, "func_respawnroom")) != -1)
    {
        char name[128];
        GetEntPropString(entity, Prop_Data, "m_iName", name, sizeof(name));
        if (StrEqual(name, target, false))
        {
            SetVariantInt(team);
            AcceptEntityInput(entity, "SetTeam");
            if (team != 0)
            {
                SetVariantString("3"); // Apply to BLU
                AcceptEntityInput(entity, "SetActive");
                SetVariantString("2"); // Apply to RED
                AcceptEntityInput(entity, "SetActive");
            }
            else
            {
                SetVariantString("3");
                AcceptEntityInput(entity, "SetInactive");
                SetVariantString("2");
                AcceptEntityInput(entity, "SetInactive");
            }
        }
    }
    
    // filter_team_
    Format(target, sizeof(target), "filter_team_%s", spawnname);
    entity = -1;
    while ((entity = FindEntityByClassname(entity, "filter_activator_tfteam")) != -1)
    {
        char name[128];
        GetEntPropString(entity, Prop_Data, "m_iName", name, sizeof(name));
        if (StrEqual(name, target, false))
        {
            SetEntProp(entity, Prop_Data, "m_iTeamNum", team == view_as<int>(TFTeam_Red) ? view_as<int>(TFTeam_Red) : 0); // 2 or 0
            SetEntProp(entity, Prop_Data, "m_bNegated", team != view_as<int>(TFTeam_Red) && bForward ? 1 : 0);
        }
    }
    
    // visualizers (delayed)
    CreateTimer(0.1, Timer_UpdateHydroVisualizers);
}

void PVE_SetRequiredCapturePoint(const char[] point_name, const char[] prev_point_name, TFTeam team)
{
    int point = FindEntityByClassname(-1, "team_control_point");
    int point_ent = -1;
    int prev_point_ent = -1;

    while (point != -1)
    {
        char name[64];
        GetEntPropString(point, Prop_Data, "m_iName", name, sizeof(name));
        if (StrEqual(name, point_name))
        {
            point_ent = point;
        }
        if (StrEqual(name, prev_point_name))
        {
            prev_point_ent = point;
        }
        point = FindEntityByClassname(point, "team_control_point");
    }

    if (point_ent == -1)
    {
        return;
    }

    int point_index = GetEntProp(point_ent, Prop_Data, "m_iPointIndex");
    int prev_point_index = (prev_point_ent != -1) ? GetEntProp(prev_point_ent, Prop_Data, "m_iPointIndex") : -1;

    // We must find the objective resource and update m_iPreviousPoints
    int or = FindEntityByClassname(-1, "tf_objective_resource");
    if (or != -1)
    {
        // MAX_PREVIOUS_POINTS = 3, MAX_CONTROL_POINTS = 8
        // iIntIndex = (point_index * MAX_PREVIOUS_POINTS) + (team * MAX_CONTROL_POINTS * MAX_PREVIOUS_POINTS)
        int iIntIndex = (point_index * 3) + (view_as<int>(team) * 8 * 3);
        SetEntProp(or, Prop_Send, "m_iPreviousPoints", prev_point_index, 1, iIntIndex + 0);
        SetEntProp(or, Prop_Send, "m_iPreviousPoints", -1, 1, iIntIndex + 1);
        SetEntProp(or, Prop_Send, "m_iPreviousPoints", -1, 1, iIntIndex + 2);
    }
    
    // Actually set the internal capture requirement logic so the engine enforces it
    char keyname[64];
    Format(keyname, sizeof(keyname), "team_previouspoint_%d_0", view_as<int>(team));
    DispatchKeyValue(point_ent, keyname, prev_point_ent != -1 ? prev_point_name : "");
    Format(keyname, sizeof(keyname), "team_previouspoint_%d_1", view_as<int>(team));
    DispatchKeyValue(point_ent, keyname, "");
    Format(keyname, sizeof(keyname), "team_previouspoint_%d_2", view_as<int>(team));
    DispatchKeyValue(point_ent, keyname, "");
    
    int state = GameRules_GetProp("m_iRoundState");
    GameRules_SetProp("m_iRoundState", 4);
    SetVariantString(team == TFTeam_Red ? "3" : "2"); // opposing team
    AcceptEntityInput(point_ent, "SetOwner", point_ent, point_ent);
    GameRules_SetProp("m_iRoundState", state);
}

public Action Timer_UpdateHydroVisualizers(Handle timer)
{
    int entity = -1;
    while ((entity = FindEntityByClassname(entity, "func_respawnroomvisualizer")) != -1)
    {
        if (HasEntProp(entity, Prop_Send, "m_iTeamNum"))
        {
            int team = GetEntProp(entity, Prop_Send, "m_iTeamNum");
            SetVariantInt(team == view_as<int>(TFTeam_Red) ? 1 : 0);
            AcceptEntityInput(entity, "SetSolid");
        }
    }
    return Plugin_Handled;
}
