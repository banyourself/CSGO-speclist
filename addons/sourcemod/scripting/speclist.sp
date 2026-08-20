#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <clientprefs>

#define PLUGIN_VERSION "2.4.0"

#define SPECMODE_FIRSTPERSON 4
#define SPECMODE_3RDPERSON   5

#define POS_COUNT   6
#define COLOR_COUNT 9
#define OFFSET_STEP 0.01
#define OFFSET_MAX  0.45

// Names are capped so a long one cannot push the block off the right edge.
#define NAME_MAX 12

static const char g_sPosNames[POS_COUNT][] = {
	"Top Left",    "Top Right",
	"Middle Left", "Middle Right",
	"Bottom Left", "Bottom Right"
};

// Center column dropped: game_text is left-aligned, so a centered block collides with
// MHUD's own centered readouts. Right column is 0.55 not 0.74 because text runs
// left-to-right from the anchor with no right-alignment, so far-right pushes it off
// screen. Bottom row stops at 0.62; MHUD owns 0.72 (speed) through 0.80 (keys).
static const float g_fPosX[POS_COUNT] = { 0.02, 0.55, 0.02, 0.55, 0.02, 0.55 };
static const float g_fPosY[POS_COUNT] = { 0.00, 0.00, 0.42, 0.42, 0.62, 0.62 };

// Rough normalized height of one HUD line. Only grows the bottom row upward, so approximate is fine.
#define LINE_HEIGHT 0.035

// Top Left, hard against the corner.
#define DEFAULT_POS 0

static const char g_sColorNames[COLOR_COUNT][] = {
	"Yellow", "White", "Green", "Cyan", "Blue", "Purple", "Orange", "Red", "Pink"
};
static const int g_iColors[COLOR_COUNT][3] = {
	{255, 255,   0}, {255, 255, 255}, {  0, 255,   0},
	{  0, 255, 255}, { 80, 140, 255}, {180, 100, 255},
	{255, 150,   0}, {255,  60,  60}, {255, 105, 180}
};

ConVar cv_Default, cv_Interval;

Handle g_hCookie = null;
Handle g_hTimer = null;
// The old build passed channel -1, so the engine picked a new channel per send and
// consecutive updates drew over each other - that was the flicker. A hard-coded channel
// would fight other HUD plugins for the six slots. A synchronizer is the right answer:
// SourceMod hands out a stable per-client channel and arbitrates. MHUD uses three.
Handle g_hHudSync = null;

bool  g_bEnabled[MAXPLAYERS + 1];
int   g_iPos[MAXPLAYERS + 1];
int   g_iColor[MAXPLAYERS + 1];
float g_fOffX[MAXPLAYERS + 1];
float g_fOffY[MAXPLAYERS + 1];
bool  g_bLoaded[MAXPLAYERS + 1]; // cookies arrived; until then we do not save over them

// Preview deadline: draw a sample list while the menu is open, or position and color can't be judged.
float g_fPreviewUntil[MAXPLAYERS + 1];

// Drawing every frame is what the rebuild/draw split is for, but every frame and every
// frame with identical content are not the same thing. A HudMsg is an unreliable
// usermessage: on a full server the snapshot eats the datagram, the buffer overflows,
// and dropped HudMsgs are why MHUD blinks. This only draws while someone is spectating.
// The 0.5s hold only needs refreshing before it expires; 0.2 leaves two dropped sends of
// margin, so a drop self-heals and the old 1.0s rebuild strobe cannot come back.
#define HUD_REFRESH 0.2

char g_sHudLast[MAXPLAYERS + 1][576];
float g_fHudLastX[MAXPLAYERS + 1];
float g_fHudLastY[MAXPLAYERS + 1];
int g_iHudLastColor[MAXPLAYERS + 1];
float g_fHudLastAt[MAXPLAYERS + 1];

public Plugin myinfo = {
	name = "Spectator List",
	author = "MandoCSGO + Kevin",
	description = "Shows who is spectating you, with per-player position and colour",
	version = PLUGIN_VERSION,
	url = "id/iamarealplayer"
};

public void OnPluginStart() {
	cv_Default = CreateConVar("sm_speclist_default", "1", "Spectator list on by default for players who have never set a preference. (1 = on, 0 = off)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	cv_Interval = CreateConVar("sm_speclist_interval", "1.0", "Seconds between rebuilds of the spectator lists. Drawing happens every frame regardless, so this only controls how fast a new spectator appears in the list.", FCVAR_NOTIFY, true, 0.2, true, 5.0);
	cv_Interval.AddChangeHook(OnIntervalChanged);

	g_hHudSync = CreateHudSynchronizer();

	g_hCookie = RegClientCookie("speclist_prefs", "Spectator list display preferences", CookieAccess_Protected);

	RegConsoleCmd("sm_speclist", Command_SpecList, "Open the spectator list settings menu.");
	RegConsoleCmd("sm_spectatorlist", Command_SpecList, "Open the spectator list settings menu.");
	RegConsoleCmd("sm_spectator", Command_SpecList, "Open the spectator list settings menu.");
	RegConsoleCmd("sm_spec", Command_SpecList, "Open the spectator list settings menu.");
	RegConsoleCmd("sm_sl", Command_SpecList, "Open the spectator list settings menu.");
	RegAdminCmd("sm_speclistreset", Command_SpecListReset, ADMFLAG_ROOT, "Reset every connected player's spectator list settings back to the defaults.");

	for(int i = 1; i <= MaxClients; i++) {
		if(IsClientInGame(i)) {
			ResetPrefs(i);
			if(AreClientCookiesCached(i)) {
				OnClientCookiesCached(i);
			}
		}
	}

	AutoExecConfig(true, "speclist");
	RestartTimer();
}

public void OnConfigsExecuted() {
	RestartTimer();
}

public void OnIntervalChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
	RestartTimer();
}

// One repeating timer for the server, not one per client. The old build ran MaxClients timers at 10 Hz.
void RestartTimer() {
	delete g_hTimer;
	g_hTimer = CreateTimer(cv_Interval.FloatValue, Timer_Rebuild, _, TIMER_REPEAT);
}

public void OnPluginEnd() {
	delete g_hTimer;
}

// Defaults seeded here, NOT in OnClientPutInServer. Clientprefs loads cookies off client
// authorization, so OnClientCookiesCached can land first. Resetting there wiped the loaded
// prefs and reset g_bLoaded, blocking every later save - why a toggle never stuck.
public void OnClientConnected(int client) {
	ResetPrefs(client);
}

void ResetPrefs(int client) {
	g_bEnabled[client] = cv_Default.BoolValue;
	g_iPos[client] = DEFAULT_POS;
	g_iColor[client] = 0;
	g_fOffX[client] = 0.0;
	g_fOffY[client] = 0.0;
	g_bLoaded[client] = false;
	g_fPreviewUntil[client] = 0.0;
	g_sHudLast[client][0] = '\0';
	g_fHudLastAt[client] = 0.0;
}

public void OnClientCookiesCached(int client) {
	char sValue[64];
	GetClientCookie(client, g_hCookie, sValue, sizeof(sValue));

	// All five settings in one cookie: five separate ones would mean five handles and round trips.
	char sParts[5][16];
	if(ExplodeString(sValue, " ", sParts, sizeof(sParts), sizeof(sParts[])) == 5) {
		g_bEnabled[client] = (StringToInt(sParts[0]) != 0);
		g_iPos[client] = ClampInt(StringToInt(sParts[1]), 0, POS_COUNT - 1);
		g_iColor[client] = ClampInt(StringToInt(sParts[2]), 0, COLOR_COUNT - 1);
		g_fOffX[client] = ClampFloat(StringToFloat(sParts[3]), -OFFSET_MAX, OFFSET_MAX);
		g_fOffY[client] = ClampFloat(StringToFloat(sParts[4]), -OFFSET_MAX, OFFSET_MAX);
	}

	g_bLoaded[client] = true;
}

void SavePrefs(int client) {
	// Never write before the load landed, or a fast menu open overwrites stored prefs with defaults.
	if(!g_bLoaded[client] || !AreClientCookiesCached(client)) {
		return;
	}

	char sValue[64];
	FormatEx(sValue, sizeof(sValue), "%d %d %d %.2f %.2f",
		g_bEnabled[client] ? 1 : 0, g_iPos[client], g_iColor[client], g_fOffX[client], g_fOffY[client]);
	SetClientCookie(client, g_hCookie, sValue);
}

int ClampInt(int v, int lo, int hi) {
	return (v < lo) ? lo : ((v > hi) ? hi : v);
}

float ClampFloat(float v, float lo, float hi) {
	return (v < lo) ? lo : ((v > hi) ? hi : v);
}

// Backs off a byte at a time rather than cutting mid UTF-8, which would leave a broken glyph.
void TruncateName(char[] sName, int iMax) {
	if(strlen(sName) <= iMax) {
		return;
	}
	int i = iMax;
	while(i > 0 && (sName[i] & 0xC0) == 0x80) {
		i--;
	}
	sName[i] = '\0';
}

// Position and color are part of the message, so either changing forces a resend.
bool HudNeedsSend(int client, const char[] text, float fX, float fY) {
	float fNow = GetEngineTime();

	if((fNow - g_fHudLastAt[client]) < HUD_REFRESH
		&& fX == g_fHudLastX[client] && fY == g_fHudLastY[client]
		&& g_iHudLastColor[client] == g_iColor[client]
		&& StrEqual(g_sHudLast[client], text)) {
		return false;
	}

	strcopy(g_sHudLast[client], sizeof(g_sHudLast[]), text);
	g_fHudLastX[client] = fX;
	g_fHudLastY[client] = fY;
	g_iHudLastColor[client] = g_iColor[client];
	g_fHudLastAt[client] = fNow;
	return true;
}

// ---- Drawing -------------------------------------------------------------

// Who is watching each client, newline separated. Rebuilt on the timer, drawn every frame.
// Splitting rebuild from draw is what stops the flicker: replacing a HUD message blanks its
// channel for a frame, so redrawing once a second strobes once a second - the slow refresh
// made it worse, not better. MHUD redraws every tick and looks solid, so match it. Building
// the list is the expensive half and stays on cv_Interval.
char g_sSpecList[MAXPLAYERS + 1][512];
bool g_bAnyList;              // any client has spectators at all
float g_fAnyPreviewUntil;     // latest preview deadline across all clients


public Action Timer_Rebuild(Handle timer) {
	for(int i = 1; i <= MaxClients; i++) {
		g_sSpecList[i][0] = '\0';
	}
	g_bAnyList = false;

	for(int i = 1; i <= MaxClients; i++) {
		if(!IsClientInGame(i) || IsFakeClient(i) || !IsClientObserver(i)) {
			continue;
		}

		int iMode = GetEntProp(i, Prop_Send, "m_iObserverMode");
		if(iMode != SPECMODE_FIRSTPERSON && iMode != SPECMODE_3RDPERSON) {
			continue; // free-look / roaming: not watching anyone in particular
		}

		int iTarget = GetEntPropEnt(i, Prop_Send, "m_hObserverTarget");
		if(iTarget < 1 || iTarget > MaxClients || !IsClientInGame(iTarget)) {
			continue;
		}

		char sName[MAX_NAME_LENGTH];
		GetClientName(i, sName, sizeof(sName));
		TruncateName(sName, NAME_MAX);
		Format(g_sSpecList[iTarget], sizeof(g_sSpecList[]), "%s%s\n", g_sSpecList[iTarget], sName);
		g_bAnyList = true;
	}

	return Plugin_Continue;
}

public void OnGameFrame() {
	float fNow = GetEngineTime();
	if(!g_bAnyList && g_fAnyPreviewUntil < fNow) {
		return; // idle server draws nothing and costs nothing
	}

	for(int client = 1; client <= MaxClients; client++) {
		if(!g_bEnabled[client] || !IsClientInGame(client) || IsFakeClient(client)) {
			continue;
		}

		bool bPreview = (g_fPreviewUntil[client] > fNow);

		// A player spectating, dead, or on the spectator team cannot be spectated, so there is
		// nothing to tell them. The preview is exempt so settings stay adjustable while dead.
		if(!bPreview && (IsClientObserver(client) || !IsPlayerAlive(client))) {
			continue;
		}

		char sText[576];
		if(g_sSpecList[client][0] != '\0') {
			FormatEx(sText, sizeof(sText), "Spectators:\n%s", g_sSpecList[client]);
		}
		else if(bPreview) {
			FormatEx(sText, sizeof(sText), "Spectators:\n%N\n(preview)\n", client);
		}
		else {
			continue;
		}

		int iLines = 0;
		for(int i = 0; sText[i] != '\0'; i++) {
			if(sText[i] == '\n') {
				iLines++;
			}
		}

		float fX, fY;
		ResolvePosition(client, iLines, fX, fY);

		if(!HudNeedsSend(client, sText, fX, fY)) {
			continue;
		}

		int iIdx = g_iColor[client];
		SetHudTextParams(fX, fY, 0.5,
			g_iColors[iIdx][0], g_iColors[iIdx][1], g_iColors[iIdx][2], 255,
			0, 0.0, 0.0, 0.0); // no fade in/out, same params MHUD draws with

		// %s matters: a name containing % would be parsed as a format specifier. The old build passed the string directly.
		ShowSyncHudText(client, g_hHudSync, "%s", sText);
	}
}

void ResolvePosition(int client, int iLines, float &fX, float &fY) {
	int iPos = g_iPos[client];
	fX = ClampFloat(g_fPosX[iPos] + g_fOffX[client], 0.0, 0.98);

	// Bottom row grows upward from its anchor instead of running off screen as the count climbs.
	float fBaseY = g_fPosY[iPos];
	if(iPos >= 4 && iLines > 1) {
		fBaseY -= float(iLines - 1) * LINE_HEIGHT;
	}

	fY = ClampFloat(fBaseY + g_fOffY[client], 0.0, 0.98);
}

// SourcePawn's Format has no + flag, so %+.2f emits almost literally - that is where the
// menu's garbled title came from. A negative value prints its own sign, so only add the plus.
void FormatOffset(float fValue, char[] sOut, int iMaxLen) {
	FormatEx(sOut, iMaxLen, "%s%.2f", fValue >= 0.0 ? "+" : "", fValue);
}

void Preview(int client) {
	g_fPreviewUntil[client] = GetEngineTime() + 6.0;
	if(g_fPreviewUntil[client] > g_fAnyPreviewUntil) {
		g_fAnyPreviewUntil = g_fPreviewUntil[client]; // keeps OnGameFrame's early-out honest
	}
}

// ---- Menus ---------------------------------------------------------------

public Action Command_SpecList(int client, int args) {
	if(client < 1) {
		ReplyToCommand(client, "[SM] This command is in-game only.");
		return Plugin_Handled;
	}

	// Closes the remaining window: if the cookie query is still in flight the save would be
	// refused, so pull values in now rather than open a menu whose changes cannot persist.
	if(!g_bLoaded[client] && AreClientCookiesCached(client)) {
		OnClientCookiesCached(client);
	}
	if(!g_bLoaded[client]) {
		ReplyToCommand(client, "[SM] Your preferences are still loading, try again in a moment.");
		return Plugin_Handled;
	}

	OpenMainMenu(client);
	return Plugin_Handled;
}

// Only reaches connected players - clientprefs has no bulk API, so offline players keep their cookie.
public Action Command_SpecListReset(int client, int args) {
	int iCount = 0;
	for(int i = 1; i <= MaxClients; i++) {
		if(!IsClientInGame(i) || IsFakeClient(i)) {
			continue;
		}

		ResetPrefs(i);
		g_bLoaded[i] = true; // defaults are authoritative now, so saves stay allowed
		if(AreClientCookiesCached(i)) {
			SetClientCookie(i, g_hCookie, ""); // empty parses as "never configured"
		}
		iCount++;
	}

	ReplyToCommand(client, "[SM] Reset spectator list settings for %d player%s.", iCount, iCount == 1 ? "" : "s");
	LogAction(client, -1, "\"%L\" reset all spectator list settings (%d players).", client, iCount);
	return Plugin_Handled;
}

void OpenMainMenu(int client) {
	Preview(client);

	Menu menu = new Menu(MenuHandler_Main);
	menu.SetTitle("Spectator List");

	char sItem[64];
	FormatEx(sItem, sizeof(sItem), "Toggle: %s", g_bEnabled[client] ? "ON" : "OFF");
	menu.AddItem("toggle", sItem);

	FormatEx(sItem, sizeof(sItem), "Position: %s", g_sPosNames[g_iPos[client]]);
	menu.AddItem("pos", sItem);

	char sOffX[16], sOffY[16];
	FormatOffset(g_fOffX[client], sOffX, sizeof(sOffX));
	FormatOffset(g_fOffY[client], sOffY, sizeof(sOffY));
	FormatEx(sItem, sizeof(sItem), "Adjust X/Y (%s, %s)", sOffX, sOffY);
	menu.AddItem("xy", sItem);

	FormatEx(sItem, sizeof(sItem), "Color: %s", g_sColorNames[g_iColor[client]]);
	menu.AddItem("color", sItem);

	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_Main(Menu menu, MenuAction action, int param1, int param2) {
	if(action == MenuAction_End) {
		delete menu;
		return 0;
	}
	if(action != MenuAction_Select) {
		return 0;
	}

	char sInfo[16];
	menu.GetItem(param2, sInfo, sizeof(sInfo));

	if(StrEqual(sInfo, "toggle")) {
		g_bEnabled[param1] = !g_bEnabled[param1];
	}
	else if(StrEqual(sInfo, "pos")) {
		g_iPos[param1] = (g_iPos[param1] + 1) % POS_COUNT;
	}
	else if(StrEqual(sInfo, "color")) {
		g_iColor[param1] = (g_iColor[param1] + 1) % COLOR_COUNT;
	}
	else if(StrEqual(sInfo, "xy")) {
		OpenOffsetMenu(param1);
		return 0;
	}

	SavePrefs(param1);
	OpenMainMenu(param1);
	return 0;
}

void OpenOffsetMenu(int client) {
	Preview(client);

	Menu menu = new Menu(MenuHandler_Offset);

	char sOffX[16], sOffY[16];
	FormatOffset(g_fOffX[client], sOffX, sizeof(sOffX));
	FormatOffset(g_fOffY[client], sOffY, sizeof(sOffY));

	char sTitle[128];
	FormatEx(sTitle, sizeof(sTitle), "Fine Position\n%s\nX %s   Y %s",
		g_sPosNames[g_iPos[client]], sOffX, sOffY);
	menu.SetTitle(sTitle);

	menu.AddItem("xplus",  "X + (right)");
	menu.AddItem("xminus", "X - (left)");
	menu.AddItem("yplus",  "Y + (down)");
	menu.AddItem("yminus", "Y - (up)");
	menu.AddItem("reset",  "Reset X/Y");
	menu.AddItem("back",   "Back");

	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_Offset(Menu menu, MenuAction action, int param1, int param2) {
	if(action == MenuAction_End) {
		delete menu;
		return 0;
	}
	if(action != MenuAction_Select) {
		return 0;
	}

	char sInfo[16];
	menu.GetItem(param2, sInfo, sizeof(sInfo));

	if(StrEqual(sInfo, "back")) {
		OpenMainMenu(param1);
		return 0;
	}

	if(StrEqual(sInfo, "xplus")) {
		g_fOffX[param1] = ClampFloat(g_fOffX[param1] + OFFSET_STEP, -OFFSET_MAX, OFFSET_MAX);
	}
	else if(StrEqual(sInfo, "xminus")) {
		g_fOffX[param1] = ClampFloat(g_fOffX[param1] - OFFSET_STEP, -OFFSET_MAX, OFFSET_MAX);
	}
	else if(StrEqual(sInfo, "yplus")) {
		g_fOffY[param1] = ClampFloat(g_fOffY[param1] + OFFSET_STEP, -OFFSET_MAX, OFFSET_MAX);
	}
	else if(StrEqual(sInfo, "yminus")) {
		g_fOffY[param1] = ClampFloat(g_fOffY[param1] - OFFSET_STEP, -OFFSET_MAX, OFFSET_MAX);
	}
	else if(StrEqual(sInfo, "reset")) {
		g_fOffX[param1] = 0.0;
		g_fOffY[param1] = 0.0;
	}

	SavePrefs(param1);
	OpenOffsetMenu(param1);
	return 0;
}
