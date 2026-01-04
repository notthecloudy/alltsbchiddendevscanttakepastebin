-- Services we need throughout the script
local Players = game:GetService("Players")
local Teams = game:GetService("Teams")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

-- Modules
local TNTModule = require(
	ReplicatedStorage:WaitForChild("Modules"):WaitForChild("TNTModule")
)

-- Constants for timing, team setup, and TNT limits
local ROUND_TIME = 240
local INTERMISSION_TIME = 30
local TEAM_NAMES = { "Red", "Yellow", "Green", "Blue" }
local TEAM_PREFIX = "Team "
local TNT_LIMIT = 250
local TNT_PER_PLAYER = 16
local MARGIN = 50

-- Workspace references
local LobbySpawn = Workspace:WaitForChild("LobbySpawn")
local GameSpawn = Workspace:WaitForChild("GameSpawn")

local Map = Workspace:WaitForChild("Map")
local Center = Map:WaitForChild("Center")
local Roof = Map:WaitForChild("Roof")
local TNTFolder = Workspace:WaitForChild("TNTs")

-- Teams
local LOBBY_TEAM = Teams:WaitForChild("Lobby")

-- Remote events
local UpdateCoins = ReplicatedStorage:WaitForChild("UpdateCoins")
local UpdateWin = ReplicatedStorage:WaitForChild("UpdateWin")
local BotRefreshEvent = ReplicatedStorage:WaitForChild("RefreshBot")

-- Track if a round is active
local roundInProgress = false

-- Utility: safely get character or wait for it
local function getCharacter(player)
	return player.Character or player.CharacterAdded:Wait()
end

-- Utility: get HumanoidRootPart, timeout if missing
local function getHRP(player)
	local char = getCharacter(player)
	return char:WaitForChild("HumanoidRootPart", 2)
end

-- Choose spawn based on team
local function getSpawnForPlayer(player)
	if player.Team == LOBBY_TEAM then
		return LobbySpawn
	end
	return GameSpawn
end

-- Find a team object by its name
local function getTeamByName(name)
	return Teams:FindFirstChild(TEAM_PREFIX .. name)
end

-- Calculate how much TNT to spawn
local function getTNTCount()
	local players = #Players:GetPlayers()
	return math.min(TNT_LIMIT, TNT_PER_PLAYER * (players + 10))
end

-- Update a player's HUD with top and bottom text
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

-- Broadcast UI update to all players
local function broadcastUI(topText, bottomText)
	for _, player in ipairs(Players:GetPlayers()) do
		updatePlayerGUI(player, bottomText, topText)
	end
end

-- Show victory/defeat screen for a player
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

-- Assign players evenly across teams at round start
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

-- Assign a single player to the team with the fewest members
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

-- Move player to the correct spawn
local function teleportPlayer(player)
	local spawn = getSpawnForPlayer(player)
	if not spawn then return end

	local hrp = getHRP(player)
	if not hrp then return end

	hrp.Parent:PivotTo(spawn.CFrame + Vector3.new(0, 5, 0))
end

-- Send everyone back to the lobby
local function teleportAllToLobby()
	for _, player in ipairs(Players:GetPlayers()) do
		player.Team = LOBBY_TEAM
		teleportPlayer(player)
	end
end

-- Teleport only game teams (exclude lobby)
local function teleportPlayersToGame()
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Team ~= LOBBY_TEAM then
			teleportPlayer(player)
		end
	end
end

-- TNT spawn area bounds
local minX = Center.Position.X - Center.Size.X / 2 + MARGIN
local maxX = Center.Position.X + Center.Size.X / 2 - MARGIN
local minZ = Center.Position.Z - Center.Size.Z / 2 + MARGIN
local maxZ = Center.Position.Z + Center.Size.Z / 2 - MARGIN
local minY = Center.Position.Y + Center.Size.Y / 2
local maxY = Roof.Position.Y - Roof.Size.Y / 2

-- Spawn TNT randomly within the allowed area
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

-- Determine which team has the most TNT (loser)
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

-- Remove all players from a team and kill their characters
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

-- Run the main round loop
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

-- Countdown between rounds
local function intermission()
	for timeLeft = INTERMISSION_TIME, 0, -1 do
		broadcastUI("Intermission", timeLeft .. "s")
		task.wait(1)
	end
	runRound()
end

-- Handle new players joining
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

-- Main loop runs forever: intermissions and rounds
while true do
	intermission()
end
