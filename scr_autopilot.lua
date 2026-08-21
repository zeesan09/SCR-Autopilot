--[[
    SCR Autopilot — refactor
    Original concept by PlaceReporter99 (https://github.com/PlaceReporter99)

    Key differences from the original:
      * One non-blocking control loop instead of blocking while-loops inside
        event handlers. Nothing can deadlock, and a new target takes effect
        on the very next tick.
      * Continuous braking curve (v = sqrt(2*a*d)) instead of a fixed
        "slow to 45 at 0.32mi" threshold.
      * All parsing is nil-safe; a malformed HUD string pauses the loop
        instead of throwing.
      * Every connection is tracked and can be torn down.

    Console controls:
      _G.SCRAutopilot.stop()     -- full shutdown, releases keys
      _G.SCRAutopilot.enabled    -- read/write boolean
      Backslash key              -- toggle on/off in game
]]

--==========================================================================
-- CONFIG
--==========================================================================
local CONFIG = {
	-- Speed envelope (mph)
	MAX_SPEED           = 100,
	OBEY_SPEED_LIMIT    = true,

	-- Ceilings per signal aspect
	SPEED_DOUBLE_YELLOW = 60,   -- precaution; original treated this as green
	SPEED_SINGLE_YELLOW = 35,   -- caution
	SPEED_UNKNOWN       = 25,   -- aspect unreadable: assume the worst

	-- Braking model. BRAKE_RATE is how many mph you shed per second under
	-- service braking. Lower it if the train overshoots platforms.
	BRAKE_RATE          = 2.0,
	BRAKE_MARGIN_MI     = 0.04, -- distance held in reserve at every stop
	APPROACH_SPEED      = 10,   -- floor speed on the final crawl to a stop
	STOP_EPSILON_MI     = 0.005,

	-- Terminating platforms
	BUFFER_STOP_STUDS   = 100,
	BUFFER_CREEP_SPEED  = 10,
	BUFFER_URL          = "https://raw.githubusercontent.com/PlaceReporter99/SCR-Autopilot/refs/heads/main/const/RouteBuffers.lua",

	-- Speedometer calibration: rotation = mph * ANGLE_PER_MPH + ANGLE_AT_ZERO.
	-- Recalibrate per train if the needle mapping differs.
	ANGLE_PER_MPH       = 1.2,
	ANGLE_AT_ZERO       = -31,
	DEADBAND_DEG        = 1.8,  -- ~1.5 mph of slack

	-- Loop
	TICK                = 0.05,

	-- Keys
	KEY_ACCEL           = Enum.KeyCode.W,
	KEY_BRAKE           = Enum.KeyCode.S,
	KEY_ACK             = Enum.KeyCode.Q,   -- AWS acknowledge
	KEY_DISPATCH        = Enum.KeyCode.T,   -- station dispatch / doors
	KEY_TOGGLE          = Enum.KeyCode.Backslash,

	ACK_INTERVAL        = 0.5,
	DISPATCH_INTERVAL   = 2.0,

	DEBUG               = false,
}

--==========================================================================
-- SERVICES / STATE
--==========================================================================
local Players            = game:GetService("Players")
local RunService         = game:GetService("RunService")
local UserInputService   = game:GetService("UserInputService")
local VIM                = game:GetService("VirtualInputManager")

local player = Players.LocalPlayer

local Autopilot = {
	enabled     = true,
	running     = true,
	connections = {},
	override    = nil,  -- { speed = n, expires = os.clock() + t }
	lastAck     = 0,
	lastDispatch= 0,
	status      = "starting",
}

local function log(...)
	if CONFIG.DEBUG then print("[autopilot]", ...) end
end

--==========================================================================
-- GUI BINDING
--==========================================================================
-- Walks a path and returns nil (rather than erroring) if any link is missing.
local function descend(root, ...)
	local node = root
	for _, name in ipairs({ ... }) do
		if not node then return nil end
		node = node:FindFirstChild(name)
	end
	return node
end

local gui = player:WaitForChild("PlayerGui"):WaitForChild("DriveGui", 30)
if not gui then
	error("[autopilot] DriveGui never appeared — are you actually driving?")
end

local UI = {}

local function rebind()
	local advance = descend(gui, "Additional", "DetailsStack", "AdvanceContainer")
	UI.schedule  = advance and descend(advance, "Main", "ScheduleDetails")
	UI.signal    = advance and descend(advance, "Signal", "Standard")
	UI.signalDist= advance and descend(advance, "Signal", "Distance")

	UI.cluster   = descend(gui, "Cluster")
	UI.arm       = UI.cluster and descend(UI.cluster, "Spedometer", "TargetIndicator")
	UI.aws       = UI.cluster and UI.cluster:FindFirstChild("AwsIndicatorMinimal")
	UI.limit     = UI.cluster and descend(UI.cluster, "Stats", "CurrentState", "SpeedLimit", "Limit")

	UI.distance  = UI.schedule and descend(UI.schedule, "Counters", "Distance")
	UI.messages  = descend(gui, "Additional", "DetailsStack", "MessageContainer")

	return UI.arm ~= nil and UI.distance ~= nil
end

if not rebind() then
	error("[autopilot] Could not bind the drive HUD. SCR may have changed its GUI layout.")
end

--==========================================================================
-- INPUT
--==========================================================================
-- Edge-triggered: only sends an event when the key's state actually changes,
-- so holding W for thirty seconds is one event, not six hundred.
local keyState = {}

local function setKey(key, down)
	if keyState[key] == down then return end
	keyState[key] = down
	VIM:SendKeyEvent(down, key, false, nil)
end

local function tapKey(key)
	VIM:SendKeyEvent(true, key, false, nil)
	task.wait(0.03)
	VIM:SendKeyEvent(false, key, false, nil)
end

local function releaseControls()
	setKey(CONFIG.KEY_ACCEL, false)
	setKey(CONFIG.KEY_BRAKE, false)
end

--==========================================================================
-- SENSORS
--==========================================================================
local ASPECT = { PROCEED = 0, PRECAUTION = 1, CAUTION = 2, DANGER = 3, UNKNOWN = 4 }

-- Pulls the first number out of a HUD string. "0.32 mi" -> 0.32, "--" -> nil.
local function parseNumber(text)
	if type(text) ~= "string" then return nil end
	return tonumber(text:match("%-?%d+%.?%d*"))
end

local function readAspect()
	local s = UI.signal
	if not s then return ASPECT.UNKNOWN end
	-- Checked worst-first so a partially-rendered frame fails safe.
	local order = {
		{ "Danger",     ASPECT.DANGER },
		{ "Caution",    ASPECT.CAUTION },
		{ "Precaution", ASPECT.PRECAUTION },
		{ "Proceed",    ASPECT.PROCEED },
	}
	for _, entry in ipairs(order) do
		local frame = s:FindFirstChild(entry[1])
		if frame and frame.BackgroundTransparency == 0 then
			return entry[2]
		end
	end
	return ASPECT.UNKNOWN
end

local function speedLimit()
	if not CONFIG.OBEY_SPEED_LIMIT then return math.huge end
	return parseNumber(UI.limit and UI.limit.Text) or CONFIG.MAX_SPEED
end

local function currentNotchSpeed()
	if not UI.arm then return 0 end
	return (UI.arm.Rotation - CONFIG.ANGLE_AT_ZERO) / CONFIG.ANGLE_PER_MPH
end

-- Character root is far more reliable than the camera focus the original used;
-- camera focus breaks the moment you look around or go third-person.
local function trainPosition()
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if root then return root.Position end
	local cam = workspace.CurrentCamera
	return cam and cam.Focus.Position or nil
end

--==========================================================================
-- BUFFER DATA (optional — failure here must not kill the script)
--==========================================================================
local buffers = {}
do
	local ok, result = pcall(function()
		return loadstring(game:HttpGet(CONFIG.BUFFER_URL))()
	end)
	if ok and type(result) == "table" then
		buffers = result
	else
		warn("[autopilot] Buffer data unavailable; terminating platforms will use the normal stop logic.")
	end
end

local function bufferTarget()
	if not UI.schedule then return nil end
	local platformLabel = UI.schedule:FindFirstChild("Platform")
	local stopLabel     = UI.schedule:FindFirstChild("NextStop")
	if not (platformLabel and stopLabel) then return nil end

	local platform = (platformLabel.Text or ""):gsub("Platform ", "")
	local station  = stopLabel.Text
	local byStation = buffers[station]
	return byStation and byStation[platform] or nil
end

--==========================================================================
-- BRAKING CURVE
--==========================================================================
-- Max speed you can be doing and still stop in `distanceMi`, given BRAKE_RATE
-- in mph/s. v = sqrt(2 * a * d); the 3600 converts mph*seconds into miles.
local function curveSpeed(distanceMi)
	local usable = math.max(0, distanceMi - CONFIG.BRAKE_MARGIN_MI)
	return math.sqrt(2 * CONFIG.BRAKE_RATE * 3600 * usable)
end

--==========================================================================
-- DECISION
--==========================================================================
local function decideSpeed()
	-- Temporary override from a driver message ("stop alongside", "buffer").
	local ov = Autopilot.override
	if ov then
		if os.clock() < ov.expires then
			return ov.speed, "override"
		end
		Autopilot.override = nil
	end

	local stopDist = parseNumber(UI.distance and UI.distance.Text)
	local sigDist  = parseNumber(UI.signalDist and UI.signalDist.Text)
	local aspect   = readAspect()

	-- Unreadable distance: hold whatever we're doing rather than guessing.
	if not stopDist then
		return nil, "distance unreadable"
	end

	-- Arrived. Creep to the buffer if this is a terminating platform.
	if stopDist <= CONFIG.STOP_EPSILON_MI then
		local buf = bufferTarget()
		local pos = trainPosition()
		if buf and pos and (pos - buf).Magnitude > CONFIG.BUFFER_STOP_STUDS then
			return CONFIG.BUFFER_CREEP_SPEED, "creeping to buffer"
		end
		return 0, "stopped"
	end

	local v = math.min(CONFIG.MAX_SPEED, speedLimit())
	local reason = "line speed"

	-- Signal ceiling.
	if aspect == ASPECT.DANGER then
		-- Brake to a stand at the signal itself.
		local allowed = sigDist and curveSpeed(sigDist) or 0
		if allowed < v then v, reason = allowed, "red ahead" end
	elseif aspect == ASPECT.CAUTION then
		if CONFIG.SPEED_SINGLE_YELLOW < v then
			v, reason = CONFIG.SPEED_SINGLE_YELLOW, "single yellow"
		end
	elseif aspect == ASPECT.PRECAUTION then
		if CONFIG.SPEED_DOUBLE_YELLOW < v then
			v, reason = CONFIG.SPEED_DOUBLE_YELLOW, "double yellow"
		end
	elseif aspect == ASPECT.UNKNOWN then
		if CONFIG.SPEED_UNKNOWN < v then
			v, reason = CONFIG.SPEED_UNKNOWN, "aspect unknown"
		end
	end

	-- Station approach: never exceed the curve, but don't crawl from a mile out.
	local approach = math.max(curveSpeed(stopDist), CONFIG.APPROACH_SPEED)
	if approach < v then v, reason = approach, "station approach" end

	return math.max(0, math.floor(v + 0.5)), reason
end

--==========================================================================
-- CONTROLLER
--==========================================================================
-- Bang-bang with a deadband. Runs every tick, holds no loops of its own,
-- so a change of target is picked up within TICK seconds.
local function applyTarget(targetMph)
	if not UI.arm then return end
	local wanted  = targetMph * CONFIG.ANGLE_PER_MPH + CONFIG.ANGLE_AT_ZERO
	local delta   = wanted - UI.arm.Rotation

	if math.abs(delta) <= CONFIG.DEADBAND_DEG then
		releaseControls()
	elseif delta > 0 then
		setKey(CONFIG.KEY_BRAKE, false)
		setKey(CONFIG.KEY_ACCEL, true)
	else
		setKey(CONFIG.KEY_ACCEL, false)
		setKey(CONFIG.KEY_BRAKE, true)
	end
end

--==========================================================================
-- AUXILIARY KEYS
--==========================================================================
local function awsActive()
	local a = UI.aws
	if not a then return false end
	if a:IsA("GuiObject") and not a.Visible then return false end
	local ok, transparency = pcall(function() return a.BackgroundTransparency end)
	return ok and transparency < 1
end

local function handleAuxKeys(targetSpeed)
	local now = os.clock()

	-- Acknowledge AWS rather than mashing Q on every clock tick.
	if awsActive() and now - Autopilot.lastAck > CONFIG.ACK_INTERVAL then
		Autopilot.lastAck = now
		task.spawn(tapKey, CONFIG.KEY_ACK)
	end

	-- Dispatch only while genuinely stationary at a stop.
	if targetSpeed == 0 and currentNotchSpeed() < 1
		and now - Autopilot.lastDispatch > CONFIG.DISPATCH_INTERVAL then
		Autopilot.lastDispatch = now
		task.spawn(tapKey, CONFIG.KEY_DISPATCH)
	end
end

--==========================================================================
-- DRIVER MESSAGES
--==========================================================================
if UI.messages then
	table.insert(Autopilot.connections, UI.messages.ChildAdded:Connect(function(child)
		if child.Name ~= "DriveMessage" then return end
		local label = child:FindFirstChildWhichIsA("TextLabel")
		local text  = label and label.Text or ""
		if text:match("longside") or text:match("uffer") then
			-- Original used cs:fire (lowercase) here, which errors on modern
			-- Roblox — this branch never actually ran.
			Autopilot.override = { speed = 5, expires = os.clock() + 3 }
			log("override: stop alongside/buffer")
		end
	end))
end

--==========================================================================
-- TOGGLE
--==========================================================================
table.insert(Autopilot.connections, UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.KeyCode == CONFIG.KEY_TOGGLE then
		Autopilot.enabled = not Autopilot.enabled
		if not Autopilot.enabled then releaseControls() end
		print("[autopilot]", Autopilot.enabled and "engaged" or "disengaged")
	end
end))

--==========================================================================
-- MAIN LOOP
--==========================================================================
local lastTarget = 0

task.spawn(function()
	while Autopilot.running do
		task.wait(CONFIG.TICK)

		-- Lost the HUD (respawn, left the cab): stand down.
		if not (gui.Parent and UI.arm and UI.arm.Parent) then
			releaseControls()
			if not rebind() then continue end
		end

		if not Autopilot.enabled then
			releaseControls()
			continue
		end

		local ok, target, reason = pcall(decideSpeed)
		if not ok then
			warn("[autopilot] decision error:", target)
			releaseControls()
			continue
		end

		if target then
			if target ~= lastTarget then
				log(("target %d mph (%s)"):format(target, reason or "?"))
				lastTarget = target
			end
			Autopilot.status = reason
			applyTarget(target)
			handleAuxKeys(target)
		end
	end
	releaseControls()
end)

--==========================================================================
-- TEARDOWN
--==========================================================================
function Autopilot.stop()
	Autopilot.running = false
	Autopilot.enabled = false
	for _, conn in ipairs(Autopilot.connections) do
		pcall(function() conn:Disconnect() end)
	end
	table.clear(Autopilot.connections)
	releaseControls()
	print("[autopilot] stopped")
end

_G.SCRAutopilot = Autopilot
print("[autopilot] running — backslash to toggle, _G.SCRAutopilot.stop() to quit")
