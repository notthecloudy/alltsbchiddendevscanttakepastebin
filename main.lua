-- Services
local Players = game:GetService("Players")
local Teams = game:GetService("Teams")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

-- Modules
local TNTModule = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("TNTModule"))

-- Spawns
local LobbySpawn = Workspace:WaitForChild("LobbySpawn")
local GameSpawn = Workspace:WaitForChild("GameSpawn")

-- Map Setup
local Map = Workspace:WaitForChild("Map")
local Center = Map:WaitForChild("Center")
local Roof = Map:WaitForChild("Roof")
local TNTFolder = Workspace:WaitForChild("TNTs")
local roundInProgress = false

-- Settings
local ROUND_TIME = 240
local INTERMISSION_TIME = 30
local TNT_COUNT = math.min(250, 16 * (#Players:GetPlayers() + 10))
local TEAM_NAMES = {"Red", "Yellow", "Green", "Blue"}
local LOBBY_TEAM = Teams:FindFirstChild("Lobby")

-- Remotes
local UpdateCoins = ReplicatedStorage:WaitForChild("UpdateCoins")
local UpdateWin = ReplicatedStorage:WaitForChild("UpdateWin")
local BotRefreshEvent = ReplicatedStorage:WaitForChild("RefreshBot")

-- Bounds
local MARGIN = 50
local minX = Center.Position.X - Center.Size.X / 2 + MARGIN
local maxX = Center.Position.X + Center.Size.X / 2 - MARGIN
local minZ = Center.Position.Z - Center.Size.Z / 2 + MARGIN
local maxZ = Center.Position.Z + Center.Size.Z / 2 - MARGIN
local minY = Center.Position.Y + Center.Size.Y / 2
local maxY = Roof.Position.Y - Roof.Size.Y / 2

-- GUI Update
local function updatePlayerGUI(player, bottomText, topText)
	local gui = player:FindFirstChild("PlayerGui")
	if gui then
		local timer = gui:FindFirstChild("Timer")
		if timer then
			local main = timer:FindFirstChild("Main")
			if main then
				local top = main:FindFirstChild("Top")
				local bottom = main:FindFirstChild("Bottom")
				if top and top:FindFirstChildOfClass("TextLabel") then
					top:FindFirstChildOfClass("TextLabel").Text = topText or ""
				end
				if bottom and bottom:FindFirstChildOfClass("TextLabel") then
					bottom:FindFirstChildOfClass("TextLabel").Text = bottomText or ""
				end
			end
		end
	end
end

-- WinStatus Update
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
		top.TextColor3 = isVictory == false and Color3.new(1, 0, 0) or Color3.new(1, 1, 1)
	end

	if bottom and bottom:IsA("TextLabel") then
		bottom.Text = bottomText or ""
	end
end

local function broadcastUI(top, bottom)
	for _, player in ipairs(Players:GetPlayers()) do
		updatePlayerGUI(player, bottom, top)
	end
end

-- Team Management
local function assignPlayersToTeams()
	local allPlayers = Players:GetPlayers()
	table.sort(allPlayers, function(a, b)
		return a.UserId < b.UserId
	end)

	for i, player in ipairs(allPlayers) do
		local teamName = TEAM_NAMES[((i - 1) % #TEAM_NAMES) + 1]
		local team = Teams:FindFirstChild(teamName)
		if team then
			player.Team = team
		else
			warn("Team not found:", teamName)
		end
	end
end

local function assignToSmallestTeam(player)
	local teamSizes = {}

	for _, name in ipairs(TEAM_NAMES) do
		local team = Teams:FindFirstChild(name)
		if team then
			teamSizes[team] = #team:GetPlayers()
		end
	end

	-- Find the team with the smallest player count
	local smallestTeam = nil
	local fewest = math.huge

	for team, count in pairs(teamSizes) do
		if count < fewest then
			fewest = count
			smallestTeam = team
		end
	end

	if smallestTeam then
		player.Team = smallestTeam
	end
end

-- Teleport
local function teleportToSpawn(player)
	local setSpawn = (player.Team == LOBBY_TEAM and LobbySpawn) or GameSpawn
	if not setSpawn then return end

	local char = player.Character or player.CharacterAdded:Wait()
	local hrp = char:FindFirstChild("HumanoidRootPart") or char:WaitForChild("HumanoidRootPart", 2)

	if hrp then
		-- Move character to spawn point + slight offset
		char:PivotTo(setSpawn.CFrame + Vector3.new(0, 5, 0))

		-- Attempt to stop animations
		local humanoid = char:FindFirstChildWhichIsA("Humanoid")
		if humanoid then
			local animator = humanoid:FindFirstChild("Animator")
			if animator then
				for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
					--track:Stop()
				end
			end
		end
	else
		warn("Could not teleport", player.Name, "- HumanoidRootPart missing.")
	end
end

local function teleportAllToLobby()
	for _, player in ipairs(Players:GetPlayers()) do
		player.Team = LOBBY_TEAM
		teleportToSpawn(player)
	end
end

local function teleportPlayersToGame()
	for _, player in ipairs(Players:GetPlayers()) do
		print("Teleporting", player.Name, "Team:", player.Team and player.Team.Name or "None")
		if player.Team ~= LOBBY_TEAM then
			teleportToSpawn(player)
		end
	end
end

-- TNT
local function spawnTNTs()
	for _ = 1, TNT_COUNT do
		local randX = math.random() * (maxX - minX) + minX
		local randY = math.random() * (maxY - minY) + minY
		local randZ = math.random() * (maxZ - minZ) + minZ
		TNTModule.spawnTNT(Vector3.new(randX, randY, randZ))
	end
end

local function getTeamWithMostTNT()
	local highestAmount = -1
	local losingTeamName = nil
	for _, name in ipairs(TEAM_NAMES) do
		local model = Map:FindFirstChild(name)
		if model then
			local base = model:FindFirstChild("Base")
			if base and base:FindFirstChild("Amount") then
				local amount = base.Amount.Value
				if amount > highestAmount then
					highestAmount = amount
					losingTeamName = name
				end
			end
		end
	end
	return losingTeamName
end

local function eliminateTeam(name)
	local team = Teams:FindFirstChild("Team " .. name)
	if team then
		for _, player in ipairs(team:GetPlayers()) do
			teleportToSpawn(player)
			for _, tnt in ipairs(TNTFolder:GetChildren()) do
				if tnt:IsA("BasePart") then
					TNTModule.explodeTNT(tnt)
				end
			end
			if player.Character then
				local hum = player.Character:FindFirstChildOfClass("Humanoid")
				if hum then hum.Health = 0 end
			end
			player.Team = LOBBY_TEAM
		end
	end
end

local function handleRespawn(player)
	player.CharacterAdded:Connect(function()
		task.wait(0.25)
		if player.Team == LOBBY_TEAM then
			teleportToSpawn(player)
		end
	end)
end

-- Round System
local function runRound()
	roundInProgress = true
	BotRefreshEvent:Fire()
	assignPlayersToTeams()
	broadcastUI("Spawning TNT", "Get Ready...")
	task.wait(2)

	teleportPlayersToGame()
	spawnTNTs()

	for i = ROUND_TIME, 0, -1 do
		broadcastUI("Game in progress", i .. "s")
		task.wait(1)
	end

	local loser = getTeamWithMostTNT()

	if loser then
		broadcastUI("Round Over", "Team " .. loser .. " loses!")

		for _, player in pairs(Players:GetPlayers()) do
			local isLoser = player.Team and player.Team.Name == loser
			local coins = isLoser and 150 or 500
			local topText = isLoser and "Defeat" or "Victory"
			local bottomText = "You earned +" .. tostring(coins) .. " coins"

			winStatusUI(player, bottomText, topText, true, not isLoser)

			UpdateCoins:Fire(player, coins)
			if not isLoser then
				UpdateWin:Fire(player)
			end
		end

		task.wait(10)
		eliminateTeam(loser)
	else
		broadcastUI("Round Over", "No team lost")
	end

	-- 🔻 HIDE victory/defeat screen for all players
	for _, player in pairs(Players:GetPlayers()) do
		winStatusUI(player, "", "", false)
	end

	task.wait(5)
	TNTModule.clearTNT()
	teleportAllToLobby()
	roundInProgress = false
end

local function intermission()
	for i = INTERMISSION_TIME, 0, -1 do
		broadcastUI("Intermission", i .. "s")
		task.wait(1)
	end
	runRound()
end

-- Player Join
Players.PlayerAdded:Connect(function(player)
	handleRespawn(player)
	task.wait(1)

	if roundInProgress then
		assignToSmallestTeam(player)
		updatePlayerGUI(player, "Joining...", "Game in progress")
	else
		player.Team = LOBBY_TEAM
		updatePlayerGUI(player, tostring(INTERMISSION_TIME) .. "s", "Intermission")
	end

	teleportToSpawn(player)
end)

-- Start Game Loop
while true do
	intermission()
end
