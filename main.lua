--// ============================================================
--// CORE GAME ROUND CONTROLLER
--// This script owns the entire round lifecycle:
--// Intermission → Team assignment → Teleport → TNT spawning
--// → Round timer → Loss evaluation → Rewards → Cleanup
--// ============================================================

--// =========================
--// Roblox Services
--// =========================
-- Players: authoritative list of connected players and lifecycle events
-- Teams: used for server-side team assignment and filtering
-- Workspace: spatial authority for spawns, map bounds, and TNT containers
-- ReplicatedStorage: shared runtime assets (modules + remotes)
-- ServerStorage: reserved for server-only assets (not used directly here)
local Players = game:GetService("Players")
local Teams = game:GetService("Teams")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

--// =========================
--// Modules
--// =========================
-- TNTModule is responsible for:
--  • Spawning TNT instances
--  • Tracking them internally
--  • Cleaning them up safely between rounds
-- This script treats TNTModule as a black-box service.
local TNTModule = require(
	ReplicatedStorage:WaitForChild("Modules"):WaitForChild("TNTModule")
)

--// =========================
--// Match Configuration
--// =========================
-- ROUND_TIME: active gameplay duration
-- INTERMISSION_TIME: downtime between rounds
-- TEAM_NAMES: logical team identifiers (must exist in Teams + Map)
-- TEAM_PREFIX: used when teams are named "Team Red", etc.
-- TNT_LIMIT: absolute cap to prevent server overload
-- TNT_PER_PLAYER: scaling factor per population
-- MARGIN: spatial padding to avoid wall/edge spawns
local ROUND_TIME = 240
local INTERMISSION_TIME = 30
local TEAM_NAMES = { "Red", "Yellow", "Green", "Blue" }
local TEAM_PREFIX = "Team "
local TNT_LIMIT = 250
local TNT_PER_PLAYER = 16
local MARGIN = 50

--// =========================
--// World References
--// =========================
-- All references are resolved once and reused for performance
local LobbySpawn = Workspace:WaitForChild("LobbySpawn")
local GameSpawn = Workspace:WaitForChild("GameSpawn")

local Map = Workspace:WaitForChild("Map")
local Center = Map:WaitForChild("Center")
local Roof = Map:WaitForChild("Roof")
local TNTFolder = Workspace:WaitForChild("TNTs")

--// =========================
--// Teams
--// =========================
-- Lobby team represents non-participating / idle players
local LOBBY_TEAM = Teams:WaitForChild("Lobby")

--// =========================
--// Remote Events
--// =========================
-- UpdateCoins: server → client currency sync
-- UpdateWin: server-side win counter increment
-- BotRefreshEvent: forces AI/bots to reset state between rounds
local UpdateCoins = ReplicatedStorage:WaitForChild("UpdateCoins")
local UpdateWin = ReplicatedStorage:WaitForChild("UpdateWin")
local BotRefreshEvent = ReplicatedStorage:WaitForChild("RefreshBot")

--// =========================
--// Runtime State Flags
--// =========================
-- Prevents duplicate round starts and controls join behavior
local roundInProgress = false

--// =========================
--// Character / Movement Utilities
--// =========================
-- These helpers normalize common character access patterns
-- and protect against race conditions during respawn.

local function getCharacter(player)
	return player.Character or player.CharacterAdded:Wait()
end

local function getHRP(player)
	local char = getCharacter(player)
	return char:WaitForChild("HumanoidRootPart", 2)
end

-- Determines correct spawn based on team state
local function getSpawnForPlayer(player)
	if player.Team == LOBBY_TEAM then
		return LobbySpawn
	end
	return GameSpawn
end

-- Resolves a team object from logical name
local function getTeamByName(name)
	return Teams:FindFirstChild(TEAM_PREFIX .. name)
end

-- Dynamically scales TNT count with population,
-- while enforcing a hard upper bound for server safety
local function getTNTCount()
	local players = #Players:GetPlayers()
	return math.min(TNT_LIMIT, TNT_PER_PLAYER * (players + 10))
end

--// =========================
--// UI Synchronization Helpers
--// =========================
-- UI is fully server-driven to prevent desync or exploit risk.

local function updatePlayerGUI(player, bottomText, topText)
	local gui = player:FindFirstChild("PlayerGui")
	if not gui then return end

	local timer = gui:FindFirstChild("Timer")
	if not timer then return end

	local main = timer:FindFirstChild("Main")
	if not main then return end

	local topLabel = main:FindFirstChild("Top") and main.Top:FindFirstChildOfClass("TextLabel")
	local bottomLabel = main:FindFirstChild("Bottom") and main.Bottom:FindFirstChildOfClass("TextLabel")

	if topLabel then
		topLabel.Text = topText or ""
	end

	if bottomLabel then
		bottomLabel.Text = bottomText or ""
	end
end

-- Broadcasts UI state atomically to all players
local function broadcastUI(topText, bottomText)
	for _, player in ipairs(Players:GetPlayers()) do
		updatePlayerGUI(player, bottomText, topText)
	end
end

-- Victory/Defeat overlay controller
-- Color and text are server-authoritative
local function winStatusUI(player, bottomText, topText, show, isVictory)
	local gui = player:FindFirstChild("PlayerGui")
	if not gui then return end

	local victoryUI = gui:FindFirstChild("Victory")
	if not victoryUI then return end

	victoryUI.Enabled = show
	if not show then return end

	local canvas = victoryUI:FindFirstChild("Canvas")
	if not canvas then return end

	local top = canvas:FindFirstChild("Top")
	local bottom = canvas:FindFirstChild("Bottom")

	if top and top:IsA("TextLabel") then
		top.Text = topText or ""
		top.TextColor3 = isVictory and Color3.new(1, 1, 1) or Color3.new(1, 0, 0)
	end

	if bottom and bottom:IsA("TextLabel") then
		bottom.Text = bottomText or ""
	end
end

--// =========================
--// Team Assignment Logic
--// =========================
-- Deterministic team distribution based on UserId ordering
-- ensures fairness and avoids bias across server restarts.

local function assignPlayersToTeams()
	local allPlayers = Players:GetPlayers()
	table.sort(allPlayers, function(a, b)
		return a.UserId < b.UserId
	end)

	for index, player in ipairs(allPlayers) do
		local teamName = TEAM_NAMES[((index - 1) % #TEAM_NAMES) + 1]
		local team = Teams:FindFirstChild(teamName)
		if team then
			player.Team = team
		end
	end
end

-- Used for late-joiners during an active round
-- Keeps team sizes as balanced as possible
local function assignToSmallestTeam(player)
	local smallestTeam
	local smallestCount = math.huge

	for _, name in ipairs(TEAM_NAMES) do
		local team = Teams:FindFirstChild(name)
		if team then
			local count = #team:GetPlayers()
			if count < smallestCount then
				smallestCount = count
				smallestTeam = team
			end
		end
	end

	if smallestTeam then
		player.Team = smallestTeam
	end
end

--// =========================
--// Teleportation System
--// =========================
-- Uses Model:PivotTo to ensure full character reposition
-- without physics drift or partial CFrame updates.

local function teleportPlayer(player)
	local spawn = getSpawnForPlayer(player)
	if not spawn then return end

	local hrp = getHRP(player)
	if not hrp then return end

	hrp.Parent:PivotTo(spawn.CFrame + Vector3.new(0, 5, 0))
end

local function teleportAllToLobby()
	for _, player in ipairs(Players:GetPlayers()) do
		player.Team = LOBBY_TEAM
		teleportPlayer(player)
	end
end

local function teleportPlayersToGame()
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Team ~= LOBBY_TEAM then
			teleportPlayer(player)
		end
	end
end

--// =========================
--// TNT Spawn & Evaluation Logic
--// =========================
-- Bounding box is computed once for efficiency.

local minX = Center.Position.X - Center.Size.X / 2 + MARGIN
local maxX = Center.Position.X + Center.Size.X / 2 - MARGIN
local minZ = Center.Position.Z - Center.Size.Z / 2 + MARGIN
local maxZ = Center.Position.Z + Center.Size.Z / 2 - MARGIN
local minY = Center.Position.Y + Center.Size.Y / 2
local maxY = Roof.Position.Y - Roof.Size.Y / 2

local function spawnTNTs()
	for _ = 1, getTNTCount() do
		local pos = Vector3.new(
			math.random() * (maxX - minX) + minX,
			math.random() * (maxY - minY) + minY,
			math.random() * (maxZ - minZ) + minZ
		)
		TNTModule.spawnTNT(pos)
	end
end

-- Determines losing team based on accumulated TNT mass/value
local function getTeamWithMostTNT()
	local highest = -1
	local losingTeam

	for _, name in ipairs(TEAM_NAMES) do
		local model = Map:FindFirstChild(name)
		local base = model and model:FindFirstChild("Base")
		local amount = base and base:FindFirstChild("Amount")

		if amount and amount.Value > highest then
			highest = amount.Value
			losingTeam = name
		end
	end

	return losingTeam
end

-- Eliminates a team by:
--  • Removing them from gameplay
--  • Killing characters
--  • Returning them to lobby state
local function eliminateTeam(teamName)
	local team = getTeamByName(teamName)
	if not team then return end

	for _, player in ipairs(team:GetPlayers()) do
		player.Team = LOBBY_TEAM
		teleportPlayer(player)

		if player.Character then
			local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
			if humanoid then
				humanoid.Health = 0
			end
		end
	end
end

--// =========================
--// Round Lifecycle Controller
--// =========================
local function runRound()
	roundInProgress = true

	BotRefreshEvent:Fire()
	assignPlayersToTeams()
	broadcastUI("Spawning TNT", "Get Ready...")
	task.wait(2)

	teleportPlayersToGame()
	spawnTNTs()

	for timeLeft = ROUND_TIME, 0, -1 do
		broadcastUI("Game in progress", timeLeft .. "s")
		task.wait(1)
	end

	local losingTeam = getTeamWithMostTNT()

	if losingTeam then
		broadcastUI("Round Over", "Team " .. losingTeam .. " loses!")

		for _, player in ipairs(Players:GetPlayers()) do
			local lost = player.Team and player.Team.Name == losingTeam
			local coins = lost and 150 or 500

			winStatusUI(
				player,
				"You earned +" .. coins .. " coins",
				lost and "Defeat" or "Victory",
				true,
				not lost
			)

			UpdateCoins:Fire(player, coins)
			if not lost then
				UpdateWin:Fire(player)
			end
		end

		task.wait(10)
		eliminateTeam(losingTeam)
	else
		broadcastUI("Round Over", "No team lost")
	end

	for _, player in ipairs(Players:GetPlayers()) do
		winStatusUI(player, "", "", false)
	end

	task.wait(5)
	TNTModule.clearTNT()
	teleportAllToLobby()

	roundInProgress = false
end

--// =========================
--// Intermission Loop
--// =========================
local function intermission()
	for timeLeft = INTERMISSION_TIME, 0, -1 do
		broadcastUI("Intermission", timeLeft .. "s")
		task.wait(1)
	end
	runRound()
end

--// =========================
--// Player Lifecycle Handling
--// =========================
Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function()
		task.wait(0.25)
		teleportPlayer(player)
	end)

	task.wait(1)

	if roundInProgress then
		assignToSmallestTeam(player)
		updatePlayerGUI(player, "Joining...", "Game in progress")
	else
		player.Team = LOBBY_TEAM
		updatePlayerGUI(player, INTERMISSION_TIME .. "s", "Intermission")
	end

	teleportPlayer(player)
end)

--// =========================
--// Main Server Loop
--// =========================
while true do
	intermission()
end
