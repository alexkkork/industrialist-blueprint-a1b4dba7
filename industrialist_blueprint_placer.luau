-- Industrialist Blueprint Placer
-- Use only in places where you are allowed to automate placement.
--
-- Dump findings that shape this implementation:
--   * The client sends exact, small packets to Place / PlaceBind /
--     OptimizedPlaceBind. Rebuilding those packets is safer than recursively
--     editing arbitrary captured values.
--   * The dumped client has no active machine-overlap validator. Its unused
--     checkCollision closure checks workspace.Limits, not other machines.
--   * Every one of the 419 dumped building templates has a direct Base and a
--     PrimaryPart. Placement snapping and schematic matching both use Base.
--   * Base is often offset from the model pivot. Always PivotTo first, then
--     read the resulting Base.CFrame; never center Base.Size on the target.
--   * PipeBind is only the short link between nearby pipe nodes. Long plumbing
--     routes must place physical 2-stud pipe models first, then bind every
--     adjacent node. WireBind can connect power nodes directly within range.

-- Blueprints are loaded at runtime from the paste field. Nothing is bundled
-- or placed merely by executing this script.
local Blueprint = {}
local AuthoredPlumbing = {}
local AuthoredPipeLinks = {}
local Plumbing = AuthoredPipeLinks
local Wiring = {}
local AutoPlumb = {}

local Config = {
	-- Rayfield is fetched from one immutable Git object, never the mutable
	-- sirius.menu/main redirect. Compatible executor hash APIs additionally
	-- verify the exact reviewed bytes before loadstring executes them.
	RayfieldURL = "https://raw.githubusercontent.com/SiriusSoftwareLtd/Rayfield/5f83e2300acfd8e39d543eef09c7e55d45eda9a1/source.lua",
	RayfieldSHA256 = "565abd6d2498ef0080ba878ceeecedea325b105301f34bd7c149b9035176b720",
	PlacementY = 2.0750000476837158,
	EdgeEpsilon = 0.02, -- Edge contact is allowed; only positive-area overlap fails.
	VerifyRadius = 1.25, -- Nearby-candidate search only; never a success tolerance.
	VerifyPositionTolerance = 0.12,
	-- The server expands many 0.45-stud template Bases to 1.0 downward while
	-- preserving their top surface. Verify that stable top plane, not Base center Y.
	VerifyHeightTolerance = 0.25,
	VerifyFootprintTolerance = 0.1,
	VerifyRotationTolerance = 3,
	CollisionBucketSize = 16, -- Build-local broad phase; exact OBB checks still decide every collision.
	VerifyTimeout = 2.5,
	-- A successful server call can replicate after the normal fast window. This
	-- grace is used only when no definitive correct-model mismatch appeared, and
	-- never resends the remote, so delayed replication cannot create duplicates.
	VerifyLateReplicationGrace = 2.5,
	-- Scan starts only after the intercepted placement call returns, then allows
	-- a separate replication window. Bulk-build failures keep the faster timeout.
	ScanVerifyTimeout = 6.0,
	ScanOptimisticSettleTime = 0.35,
	ScanVerifyHeightTolerance = 0.75,
	ConnectionVerifyTimeout = 2.5,
	-- Mirror placement recovery for PipeBind/WireBind: repair missed ChildAdded
	-- events and allow a bounded late-decoration window without resending.
	ConnectionVerifyLateReplicationGrace = 2.5,
	ConnectionDecorationCount = 2,
	-- A remembered exact edge may briefly disappear while its source plot streams.
	-- A stable empty two-frame scan must remain empty for this additional bounded
	-- window before it can supersede a nonempty decoration-proven registry graph.
	LiveConnectionEmptyQuietTime = 0.4,
	DuplicateConnectionAuditBatch = 12,
	-- Duplicate graph recovery inspects every selected connector family twice for
	-- stability. Cache each placed model's connector/path inventory so the second
	-- frame and later Preview/Export/Build audits do not walk detailed models again.
	ConnectionRecoveryModelYieldEvery = 48,
	PreviewRenderYieldEvery = 32,
	-- A fresh bind can reuse an endpoint cap when several short pipe edges share
	-- one PipeA node. The new segment is the authoritative post-call evidence;
	-- any matching live cap may complete its visual pair.
	ConnectionMinimumSendInterval = 0.12,
	-- Never automatically replay a bind that timed out. A delayed partial server
	-- effect cannot be distinguished from a true no-op without a transaction ID;
	-- Build/Resume performs a fresh exact-edge preflight before an explicit retry.
	-- Saved-world evidence: every bind creates one invisible segment Part and
	-- one endpoint UnionOperation. These tolerances cover all 325 complete
	-- pairs in the available client dump, with a small replication margin.
	PipeDecorationSegmentTolerance = 0.25,
	PipeDecorationCapTolerance = 0.55,
	PipeDecorationLengthBiasMin = 0.45,
	PipeDecorationLengthBiasMax = 1.0,
	-- Existing saved connections can be recovered without proximity guessing:
	-- the segment end and cap must both satisfy the same geometry proof used for
	-- a newly-created PipeBind. This radius only narrows candidate lookups.
	PipeDecorationPairSearchRadius = 1.8,
	PowerDecorationSegmentTolerance = 0.75,
	PowerDecorationCapTolerance = 1.2,
	PowerDecorationLengthBiasMin = 1.25,
	PowerDecorationLengthBiasMax = 2.2,
	PowerDecorationPairSearchRadius = 3.0,
	-- Server-visible verification already serializes every action. Keep only a
	-- tiny anti-burst pause by default; the UI delay control can still raise it.
	PlacementDelay = 0.03,
	ConnectionDelay = 0.03,
	VerboseRemoteLogging = false,
	VerboseValidationLogging = false,
	ProgressLogEvery = 10,
	-- Pollution input matches the placed meters' player-facing percentage.
	-- Internally, 100% maps to the live NumberValue Max attribute; the retained
	-- client falls back to 1M raw points when Max is absent. Unlike the old
	-- placer, even extreme percentages never add an opaque black ScreenGui.
	PollutionFallbackMaximum = 1000000,
	PollutionPercentAtMaximum = 100,
	PollutionSpoofHeartbeat = 0.1, -- Matches Environment.POLLUTION_VISUALS.UPDATE_INTERVAL.
	PollutionMeterScanInterval = 1, -- Catches catalog attributes that replicate after parenting.
	-- User-chosen layout origins stay on the saved plot's even/even anchor
	-- phase. Portable blueprint entries are anchor-local whole-stud offsets and
	-- may use any parity; generated short-pipe route nodes use odd/odd below.
	OriginGrid = 2,
	OriginGridPhase = 0,
	-- Move-to-me searches a bounded set of server-grid transforms and commits one
	-- exact result before Preview. Build never silently changes that transform.
	SmartTurnEnabled = true,
	AutoFitSearchRadius = 48,
	-- Industrialist machines use a 2-stud anchor lattice. Search every legal
	-- phase instead of skipping the +/-2 neighbors with a coarser 4-stud ring.
	AutoFitSearchStep = 2,
	AutoFitYieldEvery = 64,
	-- Auto-fit is intentionally bounded. Small builds may inspect the entire
	-- search area; very large exports receive a fair per-rotation budget so one
	-- click cannot freeze the client while walking thousands of Base footprints.
	AutoFitMaxDetailedCandidates = 9604,
	AutoFitMaxDescriptorChecks = 1500000,
	AutoFitMinimumCandidatesPerRotation = 24,
	AutoFitDescriptorChecksPerYield = 12000,
	AutoFitClearance = 0.5,
	GameStyleConnectionPreview = true,
	PipeGrid = 2,
	PipeGridPhase = 1,
	-- Auto-Plumb may only join neighboring 2-stud route nodes. Do not raise this:
	-- it is the router's adjacency limit, not Industrialist's server bind limit.
	PipeBindRange = 2.4,
	-- The saved client dump contains 153 exact server Pipe segment/cap pairs.
	-- Nine legitimate binds exceed 2.4 studs and the longest is 4.915 studs
	-- (RustyFluidPipeAndItemIntersection -> IngotMolder). Existing authored,
	-- decoration-proven, and duplicate-replayed links may use that observed range.
	VerifiedPipeBindRange = 5.0,
	AutoPlumbEndpointRange = 2.38, -- Standard ports can sit ~2.35 studs from the nearest valid pipe cell.
	AutoPlumbSearchMargin = 56,
	AutoPlumbBendPenalty = 0.35,
	AutoPlumbMaxVisited = 18000,
	AutoPlumbSearchYieldEvery = 384,
	AutoPlumbMaxEndpointCandidates = 24,
	AutoPlumbMaxPairAttempts = 16,
	MaxBlueprintMachines = 1024,
	MaxSavedPlumbingPieces = 4096,
	MaxAutoPlumbRoutes = 512,
	MaxConnections = 8192,
	MaxConnectorPathSegments = 64,
	MaxVisibleConnectionPreviewLines = 256,
	MaxReasonsPerPreview = 8,
	MaxInvalidPreviewWarnings = 50,
	MaxDuplicateSelection = 1024,
	MaxBlueprintTextBytes = 500000,
	DefaultWireRange = 40,
	HardModeWireRange = 60,
}

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer
local PlacementSystem = ReplicatedStorage:WaitForChild("PlacementSystem")
local Buildings = PlacementSystem:WaitForChild("Buildings")
local Plots = workspace:WaitForChild("Plots")
local ConnectionDecorations = Plots:WaitForChild("PipeConnectionDecoration")

local Place = PlacementSystem:WaitForChild("Place")
local PlaceBind = PlacementSystem:WaitForChild("PlaceBind")
local OptimizedPlaceBind = PlacementSystem:WaitForChild("OptimizedPlaceBind")
local PipeBind = PlacementSystem:WaitForChild("PipeBind")
local WireBind = PlacementSystem:WaitForChild("WireBind")

local GREEN = Color3.fromRGB(61, 255, 125)
local RED = Color3.fromRGB(255, 64, 83)
local PREFIX = "[Industrialist Blueprint] "
local Runtime = {}
Runtime.CaptureHookVersion = "post-call-placement-v6"

local State = {
	originX = 0,
	originZ = 0,
	layoutRotation = 0,
	smartTurnEnabled = Config.SmartTurnEnabled,
	autoFitClearance = Config.AutoFitClearance,
	autoFitInProgress = false,
	autoFitGeneration = 0,
	autoFitMode = nil,
	blueprintRevision = 0,
	gameStyleConnectionPreview = Config.GameStyleConnectionPreview,
	previews = {},
	authoredPlacementPreviews = {},
	authoredLinkPreviews = {},
	connectionPreviews = {},
	connectionPreviewDonorCache = {},
	previewConnectionLinesUsed = 0,
	previewInProgress = false,
	previewEpoch = 0,
	activePreviewEpoch = nil,
	validated = false,
	building = false,
	buildRemoteAttempted = false,
	cancelRequested = false,
	destroyed = false,
	captureArmed = false,
	captureGeneration = 0,
	pendingCapture = nil,
	captureProcessing = false,
	captureInFlight = false,
	captureInFlightGeneration = nil,
	captureFallback = nil,
	captureRemembered = false,
	captureProfileStatus = "No remembered placement profile loaded.",
	runtimePumpConnection = nil,
	replaying = false,
	captured = nil,
	scanComplete = false,
	scanMode = "None",
	scanMatchedEntry = nil,
	scanPlacedModel = nil,
	scanPlacedSnapshot = {},
	blueprintText = "",
	loadedBlueprintText = nil,
	blueprintLoaded = false,
	blueprintDirty = false,
	sourceAuthoredPlumbing = {},
	sourceAuthoredPipeLinks = {},
	autoPlumbMode = "Off",
	autoPlumbQuality = "Good",
	autoPlumbErrors = {},
	autoPlumbSummary = "Auto-Plumb is off until the pasted document or Auto-Plumb button enables it.",
	autoPlumbGeneratedPlacements = 0,
	autoPlumbGeneratedLinks = 0,
	knownConnections = {},
	knownConnectionIndex = { Pipe = {}, Wire = {} },
	connectionDecorationRegistry = nil,
	connectionConnectorCache = setmetatable({}, { __mode = "k" }),
	completeConnectionModels = setmetatable({}, { __mode = "k" }),
	physicalPlumbingModels = setmetatable({}, { __mode = "k" }),
	exactTemplateCache = {},
	canonicalTemplateCache = {},
	templateBaseTransformCache = setmetatable({}, { __mode = "k" }),
	ghostTemplateCache = setmetatable({}, { __mode = "k" }),
	pipeConnectorCountCache = setmetatable({}, { __mode = "k" }),
	powerConnectorCountCache = setmetatable({}, { __mode = "k" }),
	plannedPipeConnectorOffsetCache = setmetatable({}, { __mode = "k" }),
	autoPipePortsCache = setmetatable({}, { __mode = "k" }),
	sourceReferenceByModel = setmetatable({}, { __mode = "k" }),
	sourceReferenceMachineSet = nil,
	sourceReferencePlumbingSet = nil,
	saveFolder = "industrialist/saves",
	saveFolderReady = false,
	saveStatus = "Local save folder has not been checked yet.",
	lastSaveName = nil,
	filesystemBusy = false,
	blueprintParagraph = nil,
	blueprintInputSync = nil,
	originXInput = nil,
	originZInput = nil,
	layoutRotationInput = nil,
	syncingLayoutControls = false,
	delaySeconds = Config.PlacementDelay,
	delayExplicit = false,
	activePlacementWatches = {},
	activeConnectionWatches = {},
	lastConnectionInvokeAt = nil,
	buildLeaseToken = nil,
	activePlacedCaches = {},
	placedRegistry = nil,
	hookInstalled = false,
	statusParagraph = nil,
	lastBuildFailure = nil,
	buildProgress = {
		stage = "Idle",
		startedAt = nil,
		startingCompleted = 0,
		completed = 0,
		total = 0,
	},
	pollutionRemover = {
		enabled = false,
		snapshots = {},
		connections = {},
		previewConnectionLinesUsed = 0,
		cleanTargets = nil,
	},
	pollutionSpoof = {
		enabled = false,
		targetValue = 0,
		draftText = "0",
		source = nil,
		latestLiveValue = nil,
		latestLiveDisplayedFactor = nil,
		latestLiveDisplayedFactorPresent = false,
		writing = false,
		reapplyQueued = false,
		generation = 0,
		connections = {},
		sourceConnections = {},
		presentationSnapshots = setmetatable({}, { __mode = "k" }),
		presentationConfig = nil,
		meterModels = setmetatable({}, { __mode = "k" }),
		shadeGui = nil,
		shadeFrame = nil,
		input = nil,
		toggle = nil,
		statusParagraph = nil,
		syncingControls = false,
		lastMessage = "Pollution spoof is off; Industrialist is showing the live value.",
	},
	duplicate = {
		selected = {},
		byModel = {},
		highlights = {},
		selectionBoxes = {},
		selectionVersion = 0,
		sourceAnchorX = nil,
		sourceAnchorZ = nil,
		destinationX = nil,
		destinationZ = nil,
		rotation = 0,
		previews = {},
		connections = {},
		connectionStats = nil,
		validated = false,
		clickConnection = nil,
		clickGeneration = 0,
		armedAction = nil,
		selecting = false,
		hoverBox = nil,
		hoverConnection = nil,
		releaseConnection = nil,
		marqueeArmed = false,
		marqueeDragging = false,
		marqueeStartX = nil,
		marqueeStartZ = nil,
		marqueePart = nil,
		marqueeBox = nil,
		shiftConnection = nil,
		statusParagraph = nil,
		exportStatusParagraph = nil,
		lastExportJSON = nil,
		lastExportPath = nil,
		exportSerial = 0,
		lastReportedFailure = nil,
		connectionAuditInProgress = false,
		previewInProgress = false,
	},
	rayfield = nil,
	interface = nil,
	uiGeneration = 0,
	notificationSafeDestroyAt = 0,
}

local updateBlueprintParagraph
local syncLayoutControls
local generateAutoPlumbing
local setAutoPlumbQuality

function Runtime.autoFitBusyReason()
	if State.autoFitInProgress then
		return string.format(
			"%s auto-fit is still checking the map. Wait for it to finish.",
			tostring(State.autoFitMode or "Layout")
		)
	end
	return nil
end

function Runtime.beginAutoFit(mode)
	local busyReason = Runtime.autoFitBusyReason()
	if busyReason then
		return nil, busyReason
	elseif State.destroyed then
		return nil, "The script has been destroyed; execute it again to restart."
	elseif State.building then
		return nil, "A placement build is currently running."
	end
	State.autoFitGeneration += 1
	State.autoFitInProgress = true
	State.autoFitMode = tostring(mode or "Layout")
	return State.autoFitGeneration
end

function Runtime.autoFitOwns(token)
	return State.autoFitInProgress
		and State.autoFitGeneration == token
		and not State.destroyed
end

function Runtime.finishAutoFit(token)
	if State.autoFitGeneration ~= token then
		return false
	end
	State.autoFitInProgress = false
	State.autoFitMode = nil
	return true
end

local function roundToLattice(value, spacing, phase)
	return phase + math.floor(((value - phase) / spacing) + 0.5) * spacing
end

local function snapBlueprintOriginCoordinate(value)
	return roundToLattice(value, Config.OriginGrid, Config.OriginGridPhase)
end

local function snapPipeGridCoordinate(value)
	return roundToLattice(value, Config.PipeGrid, Config.PipeGridPhase)
end

local function setBlueprintOrigin(x, z)
	local requestedX = assert(tonumber(x), "origin X must be numeric")
	local requestedZ = assert(tonumber(z), "origin Z must be numeric")
	local snappedX = snapBlueprintOriginCoordinate(requestedX)
	local snappedZ = snapBlueprintOriginCoordinate(requestedZ)
	State.originX = snappedX
	State.originZ = snappedZ
	return snappedX, snappedZ,
		math.abs(snappedX - requestedX) > 0.0001 or math.abs(snappedZ - requestedZ) > 0.0001
end

local function snapLayoutRotation(value)
	local requested = assert(tonumber(value), "layout rotation must be numeric")
	local snapped = math.round(requested / 90) * 90
	local normalized = ((snapped % 360) + 360) % 360
	return normalized, math.abs(snapped - requested) > 0.001
end

local function setLayoutRotation(value)
	local rotation, adjusted = snapLayoutRotation(value)
	State.layoutRotation = rotation
	return rotation, adjusted
end

local function rotateBlueprintOffset(x, z, rotation)
	local quarterTurn = ((math.round((rotation or 0) / 90) % 4) + 4) % 4
	if quarterTurn == 0 then
		return x, z
	elseif quarterTurn == 1 then
		return z, -x
	elseif quarterTurn == 2 then
		return -x, -z
	end
	return -z, x
end

local function blueprintOffsetFromWorld(worldX, worldZ)
	local deltaX = worldX - State.originX
	local deltaZ = worldZ - State.originZ
	return rotateBlueprintOffset(deltaX, deltaZ, -State.layoutRotation)
end

syncLayoutControls = function()
	State.draftOriginX = string.format("%.0f", State.originX)
	State.draftOriginZ = string.format("%.0f", State.originZ)
	State.draftLayoutRotation = tostring(State.layoutRotation)
	State.syncingLayoutControls = true
	if State.originXInput then
		State.originXInput:Set(State.draftOriginX)
	end
	if State.originZInput then
		State.originZInput:Set(State.draftOriginZ)
	end
	if State.layoutRotationInput then
		State.layoutRotationInput:Set(State.draftLayoutRotation)
	end
	State.syncingLayoutControls = false
end

local function formatMessage(formatString, ...)
	if select("#", ...) == 0 then
		return tostring(formatString)
	end
	return string.format(formatString, ...)
end

local function setStatus(message)
	print(PREFIX .. message)
	if State.statusParagraph then
		pcall(function()
			State.statusParagraph:Set({
				Title = "Status",
				Content = message,
			})
		end)
	end
end

local function log(formatString, ...)
	setStatus(formatMessage(formatString, ...))
end

local function notify(title, content, duration)
	if State.rayfield then
		local displayDuration = math.max(0, tonumber(duration) or 6)
		State.notificationSafeDestroyAt = math.max(
			tonumber(State.notificationSafeDestroyAt) or 0,
			os.clock() + displayDuration + 1
		)
		pcall(function()
			State.rayfield:Notify({
				Title = title,
				Content = content,
				Duration = displayDuration,
			})
		end)
	else
		warn(PREFIX .. title .. ": " .. content)
	end
end

function Runtime.retireInterfaceObject(interfaceObject, minimumDelay)
	if interfaceObject == nil then
		return false
	end
	local hideOK, hideError = pcall(function()
		if typeof(interfaceObject) == "Instance" then
			if interfaceObject:IsA("LayerCollector") then
				interfaceObject.Enabled = false
			elseif interfaceObject:IsA("GuiObject") then
				interfaceObject.Visible = false
			end
		elseif type(interfaceObject) == "table"
			and type(interfaceObject.SetVisibility) == "function"
		then
			interfaceObject:SetVisibility(false)
		end
	end)
	if not hideOK then
		warn(PREFIX .. "Interface hide failed during retirement: " .. tostring(hideError))
	end
	local waitSeconds = math.max(
		math.max(0, tonumber(minimumDelay) or 0),
		math.max(0, (tonumber(State.notificationSafeDestroyAt) or 0) - os.clock())
	)
	local function destroyWhenSafe()
		local remaining = math.max(
			0,
			(tonumber(State.notificationSafeDestroyAt) or 0) - os.clock()
		)
		if remaining > 0 then
			task.delay(remaining, destroyWhenSafe)
			return
		end
		local destroyOK, destroyError = pcall(function()
			if typeof(interfaceObject) == "Instance" then
				if interfaceObject.Parent then
					interfaceObject:Destroy()
				end
			elseif type(interfaceObject) == "table"
				and type(interfaceObject.Destroy) == "function"
			then
				interfaceObject:Destroy()
			end
		end)
		if not destroyOK then
			warn(PREFIX .. "Interface destroy failed during retirement: " .. tostring(destroyError))
		end
	end
	task.delay(waitSeconds, destroyWhenSafe)
	return true
end

-- The spoof owns only named pollution presentation objects, the local
-- Pollution NumberValue, and its DisplayedFactor. It never invokes a remote.
do
local function finitePollutionNumber(value)
	local candidate = value
	if type(candidate) == "string" then
		candidate = candidate:gsub(",", ""):match("^%s*(.-)%s*$")
	end
	local number = tonumber(candidate)
	if not number or number ~= number or number == math.huge or number == -math.huge then
		return nil, "Pollution must be a finite number."
	elseif number < 0 then
		return nil, "Pollution cannot be negative."
	end
	return number
end

local function formatPollutionNumber(value)
	local number = finitePollutionNumber(value)
	if not number or number == 0 then
		return "0"
	end

	local raw = string.format("%.15g", number)
	if raw:find("e", 1, true) or raw:find("E", 1, true) then
		return raw
	end
	local whole, fraction = raw:match("^(%d+)(%.%d+)$")
	whole = whole or raw
	local grouped = whole:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
	return grouped .. (fraction or "")
end

local function resolvePollutionValueSource()
	local source = ReplicatedStorage:FindFirstChild("Pollution")
	if source and source:IsA("NumberValue") then
		return source
	end
	return nil
end

local function positiveFinitePollutionNumber(value)
	local number = finitePollutionNumber(value)
	return number and number > 0 and number or nil
end

local function resolvePollutionMaximum(source)
	if source and typeof(source) == "Instance" then
		local readOK, sourceMaximum = pcall(function()
			return source:GetAttribute("Max")
		end)
		local parsedMaximum = readOK and positiveFinitePollutionNumber(sourceMaximum) or nil
		if parsedMaximum then
			return parsedMaximum, "ReplicatedStorage.Pollution.Max"
		end
	end

	-- The retained client uses Environment.POLLUTION.MAX as its own fallback
	-- normalization. Prefer that value when this game version exposes it.
	local modules = ReplicatedStorage:FindFirstChild("Modules")
	local enums = modules and modules:FindFirstChild("Enums")
	local environmentModule = enums and enums:FindFirstChild("Environment")
	if environmentModule and environmentModule:IsA("ModuleScript") then
		local requireOK, environmentConfig = pcall(require, environmentModule)
		local pollution = requireOK and type(environmentConfig) == "table" and environmentConfig.POLLUTION or nil
		local environmentMaximum = type(pollution) == "table"
			and positiveFinitePollutionNumber(pollution.MAX)
			or nil
		if environmentMaximum then
			return environmentMaximum, "Environment.POLLUTION.MAX"
		end
	end

	return Config.PollutionFallbackMaximum, "Industrialist fallback"
end

local function pollutionVisualFactor(value)
	local percentage = finitePollutionNumber(value) or 0
	return percentage / Config.PollutionPercentAtMaximum
end

local function pollutionRawValue(value, source)
	local maximum, maximumSource = resolvePollutionMaximum(source)
	return pollutionVisualFactor(value) * maximum, maximum, maximumSource
end

local function disconnectConnectionList(connections)
	for _, connection in ipairs(connections) do
		pcall(function()
			connection:Disconnect()
		end)
	end
	table.clear(connections)
end

local function updatePollutionSpoofStatus(message)
	local spoof = State.pollutionSpoof
	if message then
		spoof.lastMessage = message
	end
	if spoof.statusParagraph then
		pcall(function()
			spoof.statusParagraph:Set({
				Title = spoof.enabled and "Pollution spoof active" or "Pollution spoof off",
				Content = spoof.lastMessage,
			})
		end)
	end
end

local function syncPollutionSpoofControls()
	local spoof = State.pollutionSpoof
	spoof.syncingControls = true
	if spoof.input then
		pcall(function()
			spoof.input:Set(spoof.draftText)
		end)
	end
	if spoof.toggle then
		pcall(function()
			spoof.toggle:Set(spoof.enabled)
		end)
	end
	spoof.syncingControls = false
end

local function disconnectPollutionSpoofSource()
	disconnectConnectionList(State.pollutionSpoof.sourceConnections)
end

local function disconnectPollutionSpoofConnections()
	disconnectConnectionList(State.pollutionSpoof.connections)
	disconnectPollutionSpoofSource()
end

local Presentation = {}

Presentation.destroyOwnedShades = function()
	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return
	end
	for _, child in ipairs(playerGui:GetChildren()) do
		local owned = false
		pcall(function()
			owned = child.Name == "__IndustrialistBlueprintPollutionShade"
				and child:GetAttribute("IndustrialistBlueprintOwned") == true
		end)
		if owned then
			pcall(function()
				child:Destroy()
			end)
		end
	end
end

Presentation.rememberAndSet = function(instance, property, value)
	if not instance or value == nil then
		return false
	end
	local snapshots = State.pollutionSpoof.presentationSnapshots
	local properties = snapshots[instance]
	if not properties then
		properties = {}
		snapshots[instance] = properties
	end
	if properties[property] == nil then
		local readOK, current = pcall(function()
			return instance[property]
		end)
		if not readOK then
			return false
		end
		properties[property] = current
	end
	return pcall(function()
		if instance[property] ~= value then
			instance[property] = value
		end
	end)
end

Presentation.restore = function()
	local spoof = State.pollutionSpoof
	local restoredAll = true
	for instance, properties in pairs(State.pollutionSpoof.presentationSnapshots) do
		if typeof(instance) == "Instance" then
			for property, value in pairs(properties) do
				local restored = pcall(function()
					instance[property] = value
				end)
				if restored then
					properties[property] = nil
				else
					restoredAll = false
				end
			end
		else
			restoredAll = false
		end
	end
	-- Keep only failed restores so a repeated Destroy can retry them.
	for instance, properties in pairs(State.pollutionSpoof.presentationSnapshots) do
		if next(properties) == nil then
			State.pollutionSpoof.presentationSnapshots[instance] = nil
		end
	end
	State.pollutionSpoof.meterModels = setmetatable({}, { __mode = "k" })
	local shadeGui = spoof.shadeGui
	if shadeGui then
		pcall(function()
			shadeGui:Destroy()
		end)
	end
	spoof.shadeGui = nil
	spoof.shadeFrame = nil
	-- Also remove any owned shade left behind by a partial apply or stale state
	-- reference. An unowned object with the same name is deliberately preserved.
	Presentation.destroyOwnedShades()
	-- Baseline colors include live Lighting/Terrain values. Resolve them again
	-- on the next activation instead of carrying an old world's baseline.
	State.pollutionSpoof.presentationConfig = nil
	return restoredAll
end

Presentation.resolveConfig = function()
	local spoof = State.pollutionSpoof
	if spoof.presentationConfig then
		return spoof.presentationConfig
	end

	local atmosphere = Lighting:FindFirstChild("PollutionAtmosphere")
	local terrain = workspace:FindFirstChildOfClass("Terrain")
	local clouds = terrain and terrain:FindFirstChildOfClass("Clouds")
	local config = {
		low = 0.66,
		medium = 1,
		high = 2.5,
		black = 3,
		colors = {
			WATER_BASE = terrain and terrain.WaterColor or Color3.fromRGB(20, 60, 90),
			WATER_DEAD = Color3.fromRGB(75, 63, 52),
			WATER_BLACK = Color3.fromRGB(15, 12, 10),
			CLOUDS_BASE = clouds and clouds.Color or Color3.fromRGB(255, 255, 255),
			CLOUDS_DARK = Color3.fromRGB(58, 49, 48),
			CLOUDS_BLACK = Color3.fromRGB(20, 20, 20),
			AMBIENT_CLEAN = Color3.fromRGB(67, 98, 95),
			AMBIENT_LOW = Lighting.Ambient,
			AMBIENT_MEDIUM = Color3.fromRGB(98, 98, 98),
			AMBIENT_HIGH = Color3.fromRGB(98, 81, 48),
			AMBIENT_BLACK = Color3.fromRGB(0, 0, 0),
			ATMOSPHERE_LOW = atmosphere and atmosphere.Color or Color3.fromRGB(140, 180, 220),
			ATMOSPHERE_DECAY_LOW = atmosphere and atmosphere.Decay or Color3.fromRGB(100, 180, 190),
			ATMOSPHERE_MEDIUM = Color3.fromRGB(127, 127, 127),
			ATMOSPHERE_DECAY_MEDIUM = Color3.fromRGB(144, 144, 144),
			ATMOSPHERE_HIGH = Color3.fromRGB(129, 110, 69),
			ATMOSPHERE_DECAY_HIGH = Color3.fromRGB(144, 118, 89),
			ATMOSPHERE_BLACK = Color3.fromRGB(10, 10, 10),
			ATMOSPHERE_DECAY_BLACK = Color3.fromRGB(15, 15, 15),
			COLOR_CORRECTION_LOW = Color3.fromRGB(255, 255, 255),
			COLOR_CORRECTION_HIGH = Color3.fromRGB(198, 180, 136),
			COLOR_CORRECTION_BLACK = Color3.fromRGB(60, 60, 60),
		},
		atmosphere = {
			DENSITY = atmosphere and atmosphere.Density or 0.45,
			OFFSET = atmosphere and atmosphere.Offset or 0,
			GLARE = atmosphere and atmosphere.Glare or 0.175,
			HAZE = atmosphere and atmosphere.Haze or 1.17,
		},
	}

	local modules = ReplicatedStorage:FindFirstChild("Modules")
	local enums = modules and modules:FindFirstChild("Enums")
	local environmentModule = enums and enums:FindFirstChild("Environment")
	if environmentModule and environmentModule:IsA("ModuleScript") then
		local requireOK, environmentConfig = pcall(require, environmentModule)
		if requireOK and type(environmentConfig) == "table" then
			local pollution = environmentConfig.POLLUTION
			local thresholds = type(pollution) == "table" and pollution.THRESHOLDS or nil
			if type(thresholds) == "table" then
				config.low = tonumber(thresholds.LOW_POLLUTION) or config.low
				config.medium = tonumber(thresholds.MEDIUM_POLLUTION) or config.medium
				config.high = tonumber(thresholds.HIGH_POLLUTION) or config.high
				config.black = tonumber(thresholds.NO_POLLUTION_SOUNDS) or config.black
			end
			local visuals = environmentConfig.POLLUTION_VISUALS
			local colors = type(visuals) == "table" and visuals.COLORS or nil
			if type(colors) == "table" then
				for key, fallback in pairs(config.colors) do
					if typeof(colors[key]) == "Color3" then
						config.colors[key] = colors[key]
					else
						config.colors[key] = fallback
					end
				end
			end
			local atmosphereConfig = type(visuals) == "table" and visuals.ATMOSPHERE or nil
			if type(atmosphereConfig) == "table" then
				for key, fallback in pairs(config.atmosphere) do
					local value = tonumber(atmosphereConfig[key])
					config.atmosphere[key] = value or fallback
				end
			end
		end
	end

	spoof.presentationConfig = config
	return config
end

Presentation.tierColor = function(factor, stops)
	if factor <= stops[1][1] then
		return stops[1][2]
	end
	for index = 2, #stops do
		local previous = stops[index - 1]
		local current = stops[index]
		if factor <= current[1] then
			local width = current[1] - previous[1]
			local alpha = width > 0 and math.clamp((factor - previous[1]) / width, 0, 1) or 1
			return previous[2]:Lerp(current[2], alpha)
		end
	end
	return stops[#stops][2]
end

Presentation.overlayTransparency = function(factor, startFactor, targetTransparency)
	local alpha
	if factor >= startFactor + 0.4 then
		alpha = 1
	else
		alpha = math.clamp((factor / (startFactor + 0.4)) ^ startFactor, 0, 1)
	end
	return 1 + (targetTransparency - 1) * alpha
end

local PollutionMeterSpecsByID = {
	["175"] = { kind = "AdvancedPollutionMeter", displayRoot = "Screen" },
	["186"] = { kind = "PollutionMeter", displayRoot = "Pollution" },
	["343"] = { kind = "FancyPollutionMeter", displayRoot = "Screen" },
}

local PollutionMeterSpecsByName = {
	AdvancedPollutionMeter = PollutionMeterSpecsByID["175"],
	PollutionMeter = PollutionMeterSpecsByID["186"],
	FancyPollutionMeter = PollutionMeterSpecsByID["343"],
}

Presentation.resolveMeterSpec = function(instance)
	if not instance or not instance:IsA("Model") then
		return nil
	end

	local category
	local catalogID
	local catalogName
	pcall(function()
		category = instance:GetAttribute("Category")
		catalogID = instance:GetAttribute("ID")
		catalogName = instance:GetAttribute("Name")
	end)
	if category ~= nil and tostring(category) ~= "" and string.lower(tostring(category)) ~= "misc" then
		return nil
	end

	-- Stable catalog ID wins over the runtime name. FancyPollutionMeter is a
	-- PollutionMeter skin (ID 343), so name-only routing points at the wrong part.
	local byID = catalogID ~= nil and PollutionMeterSpecsByID[tostring(catalogID)] or nil
	if byID then
		return byID
	end
	local byAttributeName = type(catalogName) == "string" and PollutionMeterSpecsByName[catalogName] or nil
	return byAttributeName or PollutionMeterSpecsByName[instance.Name]
end

Presentation.isMeterModel = function(instance)
	return Presentation.resolveMeterSpec(instance) ~= nil
end

Presentation.trackMeterDescendant = function(instance)
	local cursor = instance
	while cursor and cursor ~= Plots do
		local spec = Presentation.resolveMeterSpec(cursor)
		if spec then
			State.pollutionSpoof.meterModels[cursor] = spec
			return cursor
		end
		cursor = cursor.Parent
	end
	return nil
end

Presentation.scanMeters = function()
	for _, descendant in ipairs(Plots:GetDescendants()) do
		local spec = Presentation.resolveMeterSpec(descendant)
		if spec then
			State.pollutionSpoof.meterModels[descendant] = spec
		end
	end
end

Presentation.applyMeter = function(model, spec, displayText, targetValue)
	spec = spec or Presentation.resolveMeterSpec(model)
	if not spec then
		return 0
	end

	local roots = {}
	local seenRoots = {}
	for _, rootName in ipairs({ spec.displayRoot, spec.displayRoot == "Screen" and "Pollution" or "Screen" }) do
		local root = model:FindFirstChild(rootName, true)
		if root and not seenRoots[root] then
			seenRoots[root] = true
			table.insert(roots, root)
		end
	end
	if #roots == 0 then
		return 0
	end

	local labels = {}
	local labelSet = {}
	local touched = 0
	local function inspect(instance)
		if (instance:IsA("TextLabel") or instance:IsA("TextBox") or instance:IsA("TextButton"))
			and not labelSet[instance]
		then
			labelSet[instance] = true
			table.insert(labels, instance)
		elseif instance:IsA("NumberValue") then
			local lowerName = string.lower(instance.Name)
			if lowerName == "value" or lowerName == "pollution" or lowerName == "reading" or lowerName == "amount" then
				if Presentation.rememberAndSet(instance, "Value", targetValue) then
					touched += 1
				end
			end
		elseif instance:IsA("StringValue") then
			local lowerName = string.lower(instance.Name)
			if lowerName == "value" or lowerName == "pollution" or lowerName == "reading" or lowerName == "amount" then
				if Presentation.rememberAndSet(instance, "Value", displayText) then
					touched += 1
				end
			end
		end
	end

	for _, displayRoot in ipairs(roots) do
		inspect(displayRoot)
		for _, descendant in ipairs(displayRoot:GetDescendants()) do
			inspect(descendant)
		end
		-- Some SurfaceGuis live elsewhere in the model and point at the display
		-- part through Adornee instead of being parented beneath it.
		for _, descendant in ipairs(model:GetDescendants()) do
			if descendant:IsA("SurfaceGui") and descendant.Adornee == displayRoot then
				inspect(descendant)
				for _, guiDescendant in ipairs(descendant:GetDescendants()) do
					inspect(guiDescendant)
				end
			end
		end
	end
	-- Some meters expose their numeric driver beside the display hierarchy.
	-- Keep this whole-model pass restricted to narrowly named value objects.
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("NumberValue") or descendant:IsA("StringValue") then
			inspect(descendant)
		end
	end

	for _, label in ipairs(labels) do
		local lowerName = string.lower(label.Name)
		local currentText = tostring(label.Text or "")
		local eligible = #labels == 1
			or currentText:find("%d") ~= nil
			or lowerName == "value"
			or lowerName == "pollution"
			or lowerName == "reading"
			or lowerName == "amount"
		if eligible then
			local replacement, replacements = currentText:gsub("[%d,]+%.?%d*", displayText, 1)
			if Presentation.rememberAndSet(label, "Text", replacements > 0 and replacement or displayText) then
				touched += 1
			end
		end
	end
	return touched
end

Presentation.applyMeters = function(targetValue)
	local displayText = formatPollutionNumber(targetValue)
	for model, priorSpec in pairs(State.pollutionSpoof.meterModels) do
		local inPlots = false
		pcall(function()
			inPlots = model:IsDescendantOf(Plots)
		end)
		local spec = inPlots and (Presentation.resolveMeterSpec(model) or priorSpec) or nil
		if spec then
			State.pollutionSpoof.meterModels[model] = spec
			pcall(Presentation.applyMeter, model, spec, displayText, targetValue)
		else
			State.pollutionSpoof.meterModels[model] = nil
		end
	end
end

Presentation.apply = function(factor, targetValue)
	local config = Presentation.resolveConfig()
	local colors = config.colors
	local atmosphere = Lighting:FindFirstChild("PollutionAtmosphere")
	local colorCorrection = Lighting:FindFirstChild("PollutionColorCorrection")
	local terrain = workspace:FindFirstChildOfClass("Terrain")
	local clouds = terrain and terrain:FindFirstChildOfClass("Clouds")

	Presentation.rememberAndSet(Lighting, "Ambient", Presentation.tierColor(factor, {
		{ 0, colors.AMBIENT_CLEAN },
		{ config.low, colors.AMBIENT_LOW },
		{ config.medium, colors.AMBIENT_MEDIUM },
		{ config.high, colors.AMBIENT_HIGH },
		{ config.black, colors.AMBIENT_BLACK },
	}))
	if terrain then
		Presentation.rememberAndSet(terrain, "WaterColor", Presentation.tierColor(factor, {
			{ 0, colors.WATER_BASE },
			{ config.low, colors.WATER_BASE },
			{ config.high, colors.WATER_DEAD },
			{ config.black, colors.WATER_BLACK },
		}))
	end
	if clouds then
		Presentation.rememberAndSet(clouds, "Color", Presentation.tierColor(factor, {
			{ 0, colors.CLOUDS_BASE },
			{ config.low, colors.CLOUDS_BASE },
			{ config.high, colors.CLOUDS_DARK },
			{ config.black, colors.CLOUDS_BLACK },
		}))
	end
	if atmosphere and atmosphere:IsA("Atmosphere") then
		Presentation.rememberAndSet(atmosphere, "Color", Presentation.tierColor(factor, {
			{ 0, colors.ATMOSPHERE_LOW },
			{ config.low, colors.ATMOSPHERE_LOW },
			{ config.medium, colors.ATMOSPHERE_MEDIUM },
			{ config.high, colors.ATMOSPHERE_HIGH },
			{ config.black, colors.ATMOSPHERE_BLACK },
		}))
		Presentation.rememberAndSet(atmosphere, "Decay", Presentation.tierColor(factor, {
			{ 0, colors.ATMOSPHERE_DECAY_LOW },
			{ config.low, colors.ATMOSPHERE_DECAY_LOW },
			{ config.medium, colors.ATMOSPHERE_DECAY_MEDIUM },
			{ config.high, colors.ATMOSPHERE_DECAY_HIGH },
			{ config.black, colors.ATMOSPHERE_DECAY_BLACK },
		}))
		local atmosphereAlpha = math.clamp(factor / config.high, 0, 1)
		Presentation.rememberAndSet(atmosphere, "Density", config.atmosphere.DENSITY * atmosphereAlpha)
		Presentation.rememberAndSet(atmosphere, "Offset", config.atmosphere.OFFSET * atmosphereAlpha)
		Presentation.rememberAndSet(atmosphere, "Glare", config.atmosphere.GLARE * atmosphereAlpha)
		Presentation.rememberAndSet(atmosphere, "Haze", config.atmosphere.HAZE * atmosphereAlpha)
	end
	if colorCorrection and colorCorrection:IsA("ColorCorrectionEffect") then
		Presentation.rememberAndSet(colorCorrection, "Enabled", factor > 0)
		Presentation.rememberAndSet(colorCorrection, "TintColor", Presentation.tierColor(factor, {
			{ 0, colors.COLOR_CORRECTION_LOW },
			{ config.medium, colors.COLOR_CORRECTION_LOW },
			{ config.high, colors.COLOR_CORRECTION_HIGH },
			{ config.black, colors.COLOR_CORRECTION_BLACK },
		}))
	end

	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	local visualEffects = playerGui and playerGui:FindFirstChild("VisualEffects")
	local pollutionGui = visualEffects and visualEffects:FindFirstChild("Pollution")
	if pollutionGui then
		for childName, settings in pairs({
			Noise = { "ImageTransparency", 1.75, 0.9 },
			Dither = { "ImageTransparency", 1.75, 0.95 },
			Bar = { "BackgroundTransparency", 2.4, 0.85 },
			Vignette = { "ImageTransparency", 2.4, 0.8 },
		}) do
			local child = pollutionGui:FindFirstChild(childName)
			if child then
				Presentation.rememberAndSet(
					child,
					settings[1],
					Presentation.overlayTransparency(factor, settings[2], settings[3])
				)
			end
		end
	end

	-- The retained client exposes exact gain endpoints but not the server's
	-- factor-to-EQ mapping. Scale them across the documented 0..3 pollution
	-- presentation range, while keeping every gain finite and reversible.
	local eqAlpha = math.clamp(factor / config.black, 0, 1)
	local character = LocalPlayer.Character
	if character then
		for _, descendant in ipairs(character:GetDescendants()) do
			if descendant:IsA("EqualizerSoundEffect") and descendant.Name == "PollutionEQ" then
				Presentation.rememberAndSet(descendant, "Enabled", true)
				Presentation.rememberAndSet(descendant, "HighGain", -80 * eqAlpha)
				Presentation.rememberAndSet(descendant, "LowGain", 4.6 * eqAlpha)
				Presentation.rememberAndSet(descendant, "MidGain", -35.9 * eqAlpha)
			end
		end
	end
	Presentation.applyMeters(targetValue)
	-- Native Industrialist pollution uses atmosphere, color correction, audio,
	-- and translucent overlays. Remove the opaque shade made by older versions
	-- of this placer instead of recreating it.
	State.pollutionSpoof.shadeGui = nil
	State.pollutionSpoof.shadeFrame = nil
	pcall(Presentation.destroyOwnedShades)
end

local function restorePollutionSpoofSource(source)
	local spoof = State.pollutionSpoof
	if not source or typeof(source) ~= "Instance" then
		return false
	end

	spoof.writing = true
	local restored = pcall(function()
		if spoof.latestLiveValue ~= nil and source.Value ~= spoof.latestLiveValue then
			source.Value = spoof.latestLiveValue
		end
		if spoof.latestLiveDisplayedFactorPresent then
			source:SetAttribute("DisplayedFactor", spoof.latestLiveDisplayedFactor)
		else
			source:SetAttribute("DisplayedFactor", nil)
		end
	end)
	spoof.writing = false
	return restored
end

local applyPollutionSpoof

local function queuePollutionSpoofReapply()
	local spoof = State.pollutionSpoof
	if spoof.reapplyQueued or not spoof.enabled then
		return
	end
	spoof.reapplyQueued = true
	local generation = spoof.generation
	task.defer(function()
		if spoof.generation ~= generation then
			return
		end
		spoof.reapplyQueued = false
		if spoof.enabled then
			applyPollutionSpoof()
		end
	end)
end

local function attachPollutionSpoofSource(source)
	local spoof = State.pollutionSpoof
	if spoof.source == source then
		return true
	end

	disconnectPollutionSpoofSource()
	spoof.source = source
	if not source then
		spoof.latestLiveValue = nil
		spoof.latestLiveDisplayedFactor = nil
		spoof.latestLiveDisplayedFactorPresent = false
		return false
	end

	local readOK, liveValue, displayedFactor = pcall(function()
		return source.Value, source:GetAttribute("DisplayedFactor")
	end)
	if not readOK then
		spoof.source = nil
		return false
	end
	spoof.latestLiveValue = liveValue
	spoof.latestLiveDisplayedFactor = displayedFactor
	spoof.latestLiveDisplayedFactorPresent = displayedFactor ~= nil

	table.insert(spoof.sourceConnections, source:GetPropertyChangedSignal("Value"):Connect(function()
		if not spoof.enabled or spoof.source ~= source or spoof.writing then
			return
		end
		local current = source.Value
		local desiredRawValue = pollutionRawValue(spoof.targetValue, source)
		if current ~= desiredRawValue then
			spoof.latestLiveValue = current
			queuePollutionSpoofReapply()
		end
	end))
	table.insert(spoof.sourceConnections, source:GetAttributeChangedSignal("DisplayedFactor"):Connect(function()
		if not spoof.enabled or spoof.source ~= source or spoof.writing then
			return
		end
		local current = source:GetAttribute("DisplayedFactor")
		local desired = pollutionVisualFactor(spoof.targetValue)
		if current ~= desired then
			spoof.latestLiveDisplayedFactor = current
			spoof.latestLiveDisplayedFactorPresent = current ~= nil
			queuePollutionSpoofReapply()
		end
	end))
	return true
end

applyPollutionSpoof = function()
	local spoof = State.pollutionSpoof
	if not spoof.enabled then
		return false, "Pollution spoof is disabled."
	end

	local source = resolvePollutionValueSource()
	if source ~= spoof.source then
		if spoof.source then
			restorePollutionSpoofSource(spoof.source)
		end
		attachPollutionSpoofSource(source)
	end
	if not source then
		Presentation.apply(
			pollutionVisualFactor(spoof.targetValue),
			spoof.targetValue
		)
		updatePollutionSpoofStatus(string.format(
			"Spoof is armed for %s%%, but ReplicatedStorage.Pollution has not replicated yet.",
			formatPollutionNumber(spoof.targetValue)
		))
		return false, "ReplicatedStorage.Pollution is not available yet."
	end

	local displayedFactor = pollutionVisualFactor(spoof.targetValue)
	local rawValue, maximum = pollutionRawValue(spoof.targetValue, source)
	local validRawValue, rawValueError = finitePollutionNumber(rawValue)
	if not validRawValue then
		updatePollutionSpoofStatus("The entered percentage is too large for Industrialist's raw pollution value.")
		return false, rawValueError
	end
	spoof.writing = true
	local writeOK, writeError = pcall(function()
		if source.Value ~= rawValue then
			source.Value = rawValue
		end
		if source:GetAttribute("DisplayedFactor") ~= displayedFactor then
			source:SetAttribute("DisplayedFactor", displayedFactor)
		end
	end)
	spoof.writing = false
	if not writeOK then
		updatePollutionSpoofStatus("Could not apply the local pollution value: " .. tostring(writeError))
		return false, writeError
	end
	Presentation.apply(displayedFactor, spoof.targetValue)

	return true, displayedFactor, maximum
end

local function describeActivePollutionSpoof()
	local spoof = State.pollutionSpoof
	local source = resolvePollutionValueSource()
	local rawValue, maximum, maximumSource = pollutionRawValue(spoof.targetValue, source)
	local factor = pollutionVisualFactor(spoof.targetValue)
	return string.format(
		"Showing %s%% locally: %s raw points with Max %s (%s), visual factor %s. Native translucent effects stay visible; server pollution and other players are unchanged.",
		formatPollutionNumber(spoof.targetValue),
		formatPollutionNumber(rawValue),
		formatPollutionNumber(maximum),
		maximumSource,
		formatPollutionNumber(factor)
	)
end

local function forceCleanupPollutionSpoof(silent, statusMessage)
	local spoof = State.pollutionSpoof
	local source = spoof.source
	local restoredValue = spoof.latestLiveValue

	-- Invalidate asynchronous work first. This path deliberately ignores the
	-- toggle state so Destroy can repair a partial or externally corrupted apply.
	spoof.enabled = false
	spoof.generation += 1
	spoof.reapplyQueued = false
	spoof.writing = false
	disconnectPollutionSpoofConnections()

	-- Restore locally owned presentation first, then the source last. The final
	-- Value/DisplayedFactor changes let Industrialist's own listeners win.
	local presentationCallOK, presentationResult = pcall(Presentation.restore)
	local presentationOK = presentationCallOK and presentationResult ~= false
	local presentationError = presentationCallOK and "one or more properties refused restoration" or presentationResult
	local sourceOK = true
	if source then
		sourceOK = restorePollutionSpoofSource(source)
	end
	-- Presentation.restore already sweeps owned shades, but repeat the narrow
	-- orphan pass even if an unexpected snapshot restore error interrupted it.
	pcall(Presentation.destroyOwnedShades)

	spoof.source = nil
	spoof.latestLiveValue = nil
	spoof.latestLiveDisplayedFactor = nil
	spoof.latestLiveDisplayedFactorPresent = false
	spoof.writing = false
	updatePollutionSpoofStatus(statusMessage or (restoredValue ~= nil
		and string.format(
			"Restored Industrialist's latest live pollution value (%s).",
			formatPollutionNumber(restoredValue)
		)
		or "Pollution spoof is off; Industrialist is showing the live value."))
	syncPollutionSpoofControls()

	if not silent then
		notify(
			"Pollution changes removed",
			"The local meter and environment are following Industrialist again; any legacy blackout layer was removed.",
			6
		)
	end
	if not presentationOK then
		return false, "Could not restore every pollution presentation property: " .. tostring(presentationError)
	elseif not sourceOK then
		return false, "Could not restore the previous local Pollution source."
	end
	return true
end

local setPollutionSpoofEnabled

local function setPollutionSpoofValue(value, silent)
	if State.destroyed then
		return false, "Industrialist Blueprint Placer has been destroyed. Re-run the script first."
	end
	local parsed, parseError = finitePollutionNumber(value)
	if not parsed then
		return false, parseError
	end

	local spoof = State.pollutionSpoof
	spoof.targetValue = parsed
	spoof.draftText = formatPollutionNumber(parsed)
	if spoof.enabled then
		local applied, applyError = applyPollutionSpoof()
		if applied then
			updatePollutionSpoofStatus(describeActivePollutionSpoof())
		elseif resolvePollutionValueSource() then
			syncPollutionSpoofControls()
			return false, applyError
		end
		if not silent then
			notify("Pollution value applied", spoof.lastMessage, 7)
		end
	else
		updatePollutionSpoofStatus(string.format(
			"Ready to spoof %s%%. Enable the override or press APPLY POLLUTION VALUE.",
			spoof.draftText
		))
	end
	syncPollutionSpoofControls()
	return true, parsed
end

setPollutionSpoofEnabled = function(enabled, silent)
	enabled = enabled == true
	if not enabled then
		return forceCleanupPollutionSpoof(silent)
	elseif State.destroyed then
		return false, "Industrialist Blueprint Placer has been destroyed. Re-run the script first."
	end

	local spoof = State.pollutionSpoof
	if spoof.enabled then
		local applied, applyError = applyPollutionSpoof()
		if applied then
			updatePollutionSpoofStatus(describeActivePollutionSpoof())
		elseif resolvePollutionValueSource() then
			syncPollutionSpoofControls()
			return false, applyError
		end
		syncPollutionSpoofControls()
		return true
	end

	spoof.enabled = true
	spoof.generation += 1
	spoof.reapplyQueued = false
	attachPollutionSpoofSource(resolvePollutionValueSource())
	Presentation.scanMeters()

	table.insert(spoof.connections, ReplicatedStorage.ChildAdded:Connect(function(child)
		if spoof.enabled and child.Name == "Pollution" then
			queuePollutionSpoofReapply()
		end
	end))
	table.insert(spoof.connections, ReplicatedStorage.ChildRemoved:Connect(function(child)
		if spoof.enabled and child == spoof.source then
			-- Restore the detached object too. Roblox instances remain writable
			-- while temporarily parentless, and the same source may be reinserted.
			restorePollutionSpoofSource(child)
			disconnectPollutionSpoofSource()
			spoof.source = nil
			queuePollutionSpoofReapply()
		end
	end))
	table.insert(spoof.connections, Plots.DescendantAdded:Connect(function(descendant)
		if spoof.enabled then
			local meter = Presentation.trackMeterDescendant(descendant)
			if meter then
				pcall(
					Presentation.applyMeter,
					meter,
					State.pollutionSpoof.meterModels[meter],
					formatPollutionNumber(spoof.targetValue),
					spoof.targetValue
				)
			end
		end
	end))
	local elapsed = Config.PollutionSpoofHeartbeat
	local meterScanElapsed = Config.PollutionMeterScanInterval
	table.insert(spoof.connections, RunService.Heartbeat:Connect(function(deltaTime)
		elapsed += deltaTime
		meterScanElapsed += deltaTime
		if spoof.enabled and meterScanElapsed >= Config.PollutionMeterScanInterval then
			meterScanElapsed = 0
			Presentation.scanMeters()
		end
		if spoof.enabled and elapsed >= Config.PollutionSpoofHeartbeat then
			elapsed = 0
			applyPollutionSpoof()
		end
	end))

	local applied, applyError = applyPollutionSpoof()
	if applied then
		updatePollutionSpoofStatus(describeActivePollutionSpoof())
	elseif resolvePollutionValueSource() then
		forceCleanupPollutionSpoof(true, "Pollution spoof could not start: " .. tostring(applyError))
		return false, applyError
	end
	if not silent then
		notify("Pollution spoof enabled", spoof.lastMessage, 7)
	end

	syncPollutionSpoofControls()
	return true
end

local function setPollutionSpoof(value, enabled, silent)
	local applied, result = setPollutionSpoofValue(value, true)
	if not applied then
		return false, result
	end
	if enabled == false then
		return true, result
	end
	return setPollutionSpoofEnabled(true, silent)
end

-- Backwards-compatible API: the old remover is now the zero-value form of the
-- real client pollution spoof instead of a second, conflicting visible mode.
local function setPollutionRemover(enabled, silent)
	if enabled then
		local accepted, parseError = setPollutionSpoofValue(0, true)
		if not accepted then
			return false, parseError
		end
		return setPollutionSpoofEnabled(true, silent)
	end
	return setPollutionSpoofEnabled(false, silent)
end

	Runtime.parsePollutionSpoofValue = finitePollutionNumber
	Runtime.formatPollutionSpoofValue = formatPollutionNumber
	Runtime.setPollutionSpoofValue = setPollutionSpoofValue
	Runtime.setPollutionSpoofEnabled = setPollutionSpoofEnabled
	Runtime.setPollutionSpoof = setPollutionSpoof
	Runtime.forceCleanupPollutionSpoof = forceCleanupPollutionSpoof
	Runtime.setPollutionRemover = setPollutionRemover
end

local function setParagraph(paragraph, title, content)
	if paragraph then
		pcall(function()
			paragraph:Set({
				Title = title,
				Content = content,
			})
		end)
	end
end

local function describe(value, depth, seen)
	depth = depth or 0
	seen = seen or {}
	local kind = typeof(value)

	if kind == "Instance" then
		local ok, fullName = pcall(function()
			return value:GetFullName()
		end)
		return string.format("Instance<%s:%s>", value.ClassName, ok and fullName or value.Name)
	elseif kind == "CFrame" then
		local _, yaw = value:ToOrientation()
		return string.format(
			"CFrame<%.3f, %.3f, %.3f; yaw=%.1f>",
			value.X,
			value.Y,
			value.Z,
			math.deg(yaw)
		)
	elseif kind == "Vector3" then
		return string.format("Vector3<%.3f, %.3f, %.3f>", value.X, value.Y, value.Z)
	elseif kind == "Vector2" then
		return string.format("Vector2<%.3f, %.3f>", value.X, value.Y)
	elseif kind == "string" then
		return string.format("%q", value)
	elseif kind ~= "table" then
		return string.format("%s<%s>", kind, tostring(value))
	end

	if seen[value] then
		return "table<cycle>"
	elseif depth >= 2 then
		return "table<...>"
	end

	seen[value] = true
	local pieces = {}
	local count = 0
	for key, child in pairs(value) do
		count += 1
		if count > 10 then
			table.insert(pieces, "...")
			break
		end
		table.insert(pieces, string.format("[%s]=%s", tostring(key), describe(child, depth + 1, seen)))
	end
	seen[value] = nil
	return "table{" .. table.concat(pieces, ", ") .. "}"
end

local function dumpArgs(label, args)
	if not Config.VerboseRemoteLogging then
		return
	end
	print(PREFIX .. label .. string.format(" argc=%d", args.n))
	for index = 1, args.n do
		print(PREFIX .. string.format("  [%d] %s = %s", index, typeof(args[index]), describe(args[index])))
	end
end

local function resolveTemplate(entry)
	if type(entry) ~= "table" then
		return nil, "entry is not a table"
	end
	if type(entry.Category) ~= "string" or type(entry.Name) ~= "string" then
		return nil, "Category and Name must be strings"
	end

	-- PlacementSystem.Buildings is a static replicated catalog for the life of
	-- this runtime. Preview, Auto-Plumb, and duplicate planning resolve the same
	-- names many times, so retain both successful and failed exact lookups. A
	-- nested key preserves arbitrary category/model strings without delimiter
	-- collisions, and the cache naturally expires with State/API.Destroy.
	local categoryCache = State.exactTemplateCache[entry.Category]
	if categoryCache then
		local cached = categoryCache[entry.Name]
		if cached then
			return cached.template, cached.error
		end
	else
		categoryCache = {}
		State.exactTemplateCache[entry.Category] = categoryCache
	end

	local category = Buildings:FindFirstChild(entry.Category)
	if not category then
		local templateError = string.format("unknown category %q", entry.Category)
		categoryCache[entry.Name] = { error = templateError }
		return nil, templateError
	end

	local template = category:FindFirstChild(entry.Name)
	if not template or not template:IsA("Model") then
		local templateError = string.format("missing model %s/%s", entry.Category, entry.Name)
		categoryCache[entry.Name] = { error = templateError }
		return nil, templateError
	end
	if not template.PrimaryPart then
		local templateError = string.format("%s/%s has no PrimaryPart", entry.Category, entry.Name)
		categoryCache[entry.Name] = { error = templateError }
		return nil, templateError
	end
	if not template:FindFirstChild("Base") or not template.Base:IsA("BasePart") then
		local templateError = string.format("%s/%s has no direct Base", entry.Category, entry.Name)
		categoryCache[entry.Name] = { error = templateError }
		return nil, templateError
	end

	categoryCache[entry.Name] = { template = template }
	return template
end

local function blueprintCFrame(entry)
	local x = tonumber(entry.X)
	local z = tonumber(entry.Z)
	local rotation = tonumber(entry.Rotation) or 0
	if not x or not z then
		return nil, "X and Z must be numbers"
	end
	local rotatedX, rotatedZ = rotateBlueprintOffset(x, z, State.layoutRotation)
	return CFrame.new(State.originX + rotatedX, Config.PlacementY, State.originZ + rotatedZ)
		* CFrame.Angles(0, math.rad(rotation + State.layoutRotation), 0)
end

local function getPreviewFolder()
	local folder = workspace:FindFirstChild("__IndustrialistBlueprintPreview")
	if folder and not folder:IsA("Folder") then
		return nil, "workspace.__IndustrialistBlueprintPreview is not a Folder"
	end
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "__IndustrialistBlueprintPreview"
		folder.Parent = workspace
	end
	return folder
end

local function clearPreview()
	if State.building then
		notify("Clear refused", "A blueprint build is currently running.", 6)
		return false
	end
	State.previewEpoch += 1
	local folder = workspace:FindFirstChild("__IndustrialistBlueprintPreview")
	if folder and folder:IsA("Folder") then
		folder:ClearAllChildren()
	end
	State.previews = {}
	State.authoredPlacementPreviews = {}
	State.authoredLinkPreviews = {}
	State.connectionPreviews = {}
	State.previewConnectionLinesUsed = 0
	State.validated = false
	log("Preview cleared")
	return true
end

local function styleGhost(model)
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BaseScript") then
			descendant.Disabled = true
		elseif descendant:IsA("ParticleEmitter") or descendant:IsA("Trail") or descendant:IsA("Beam") then
			descendant.Enabled = false
		elseif descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
			if descendant.Transparency < 1 then
				descendant.Transparency = math.max(descendant.Transparency, 0.55)
			end
		end
	end
end

function Runtime.cloneStyledGhost(template)
	local cached = State.ghostTemplateCache[template]
	if not cached then
		-- Styling is descendant-heavy on detailed factory models. Cache one
		-- unparented, inert shell per canonical template so a repeated farm pays
		-- that traversal once while every visible preview remains an independent
		-- clone that can be moved and destroyed normally.
		cached = template:Clone()
		styleGhost(cached)
		State.ghostTemplateCache[template] = cached
	end
	return cached:Clone()
end

local function entrySignature(entry)
	if type(entry) ~= "table" then
		return type(entry) .. "\0" .. tostring(entry)
	end
	return table.concat({
		tostring(entry.Category),
		tostring(entry.Name),
		tostring(entry.X),
		tostring(entry.Z),
		tostring(entry.Rotation),
	}, "\0")
end

local function createPreview(index, entry, folder)
	local preview = {
		index = index,
		entry = entry,
		originX = State.originX,
		originZ = State.originZ,
		layoutRotation = State.layoutRotation,
		entrySignature = entrySignature(entry),
		reasons = {},
		valid = false,
		built = false,
	}

	local template, templateError = resolveTemplate(entry)
	if not template then
		preview.setupError = templateError
		return preview
	end

	local target, cframeError = blueprintCFrame(entry)
	if not target then
		preview.setupError = cframeError
		return preview
	end

	local ghost = Runtime.cloneStyledGhost(template)
	ghost.Name = string.format("%02d_%s", index, entry.Name)

	local ok, pivotError = pcall(function()
		ghost:PivotTo(target)
	end)
	if not ok then
		ghost:Destroy()
		preview.setupError = "PivotTo failed: " .. tostring(pivotError)
		return preview
	end

	local base = ghost:FindFirstChild("Base")
	if not base or not base:IsA("BasePart") then
		ghost:Destroy()
		preview.setupError = "cloned model lost its direct Base"
		return preview
	end

	local highlight = Instance.new("Highlight")
	highlight.Name = "BlueprintValidity"
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.FillTransparency = 0.72
	highlight.OutlineTransparency = 0.05
	-- Highlight only the exact collision/placement Base. Adorning a detailed
	-- factory Model makes Roblox traverse thousands of decorative parts per
	-- preview even though validity is decided solely by Base geometry.
	highlight.Adornee = base
	highlight.Parent = ghost

	ghost.Parent = folder
	preview.template = template
	preview.model = ghost
	preview.base = base
	preview.expectedBase = {
		Position = base.Position,
		CFrame = base.CFrame,
		Size = base.Size,
	}
	preview.highlight = highlight
	preview.targetCFrame = target
	return preview
end

local function horizontalUnit(vector, fallback)
	local result = Vector2.new(vector.X, vector.Z)
	if result.Magnitude < 0.0001 then
		return fallback
	end
	return result.Unit
end

local function baseTopHeightDelta(actualBase, expectedBase)
	local actualTop = actualBase.Position.Y + actualBase.Size.Y * 0.5
	local expectedTop = expectedBase.Position.Y + expectedBase.Size.Y * 0.5
	return actualTop - expectedTop
end

local function expectedPlacementBase(preview)
	return preview and (preview.base or preview.expectedBase) or nil
end

-- Geometry acceptance lives in one place so Scan, reuse, live replication, and
-- timeout reconciliation cannot drift to different grid/height rules again.
-- Identity and freshness are deliberately handled by each caller.
function Runtime.classifyPlacementGeometry(preview, actualBase, heightTolerance)
	local expectedBase = expectedPlacementBase(preview)
	if not expectedBase or not actualBase then
		return "missing_geometry", nil
	end
	local deltaX = actualBase.Position.X - expectedBase.Position.X
	local centerDeltaY = actualBase.Position.Y - expectedBase.Position.Y
	local topDeltaY = baseTopHeightDelta(actualBase, expectedBase)
	local deltaZ = actualBase.Position.Z - expectedBase.Position.Z
	local distanceSquared = deltaX * deltaX + deltaZ * deltaZ
	local actualLook = horizontalUnit(actualBase.CFrame.LookVector, Vector2.new(0, 1))
	local expectedLook = horizontalUnit(expectedBase.CFrame.LookVector, Vector2.new(0, 1))
	local rotationDot = expectedLook:Dot(actualLook)
	local sizeDeltaX = actualBase.Size.X - expectedBase.Size.X
	local sizeDeltaZ = actualBase.Size.Z - expectedBase.Size.Z
	local footprintDifference = math.sqrt(sizeDeltaX * sizeDeltaX + sizeDeltaZ * sizeDeltaZ)
	local metrics = {
		deltaX = deltaX,
		centerDeltaY = centerDeltaY,
		topDeltaY = topDeltaY,
		deltaZ = deltaZ,
		distanceSquared = distanceSquared,
		rotationDot = rotationDot,
		footprintDifference = footprintDifference,
	}
	if distanceSquared > Config.VerifyRadius * Config.VerifyRadius then
		return "outside_radius", metrics
	elseif math.abs(deltaX) > Config.VerifyPositionTolerance
		or math.abs(deltaZ) > Config.VerifyPositionTolerance
	then
		return "position", metrics
	elseif math.abs(topDeltaY) > (heightTolerance or Config.VerifyHeightTolerance) then
		return "height", metrics
	elseif rotationDot < math.cos(math.rad(Config.VerifyRotationTolerance)) then
		return "rotation", metrics
	elseif footprintDifference > Config.VerifyFootprintTolerance then
		return "footprint", metrics
	end
	return nil, metrics
end

function Runtime.footprintFromGeometry(cframe, size)
	return {
		center = Vector2.new(cframe.Position.X, cframe.Position.Z),
		xAxis = horizontalUnit(cframe.RightVector, Vector2.new(1, 0)),
		zAxis = horizontalUnit(cframe.LookVector, Vector2.new(0, 1)),
		xHalf = size.X * 0.5,
		zHalf = size.Z * 0.5,
	}
end

local function footprint(base)
	return Runtime.footprintFromGeometry(base.CFrame, base.Size)
end

local function projectedRadius(rectangle, axis)
	return rectangle.xHalf * math.abs(rectangle.xAxis:Dot(axis))
		+ rectangle.zHalf * math.abs(rectangle.zAxis:Dot(axis))
end

local function footprintsOverlap(a, b)
	local delta = b.center - a.center
	local axis = a.xAxis
	if math.abs(delta:Dot(axis)) >= projectedRadius(a, axis) + projectedRadius(b, axis) - Config.EdgeEpsilon then
		return false
	end
	axis = a.zAxis
	if math.abs(delta:Dot(axis)) >= projectedRadius(a, axis) + projectedRadius(b, axis) - Config.EdgeEpsilon then
		return false
	end
	axis = b.xAxis
	if math.abs(delta:Dot(axis)) >= projectedRadius(a, axis) + projectedRadius(b, axis) - Config.EdgeEpsilon then
		return false
	end
	axis = b.zAxis
	if math.abs(delta:Dot(axis)) >= projectedRadius(a, axis) + projectedRadius(b, axis) - Config.EdgeEpsilon then
		return false
	end
	return true
end

function Runtime.geometryInsideLimits(cframe, size)
	local limits = workspace:FindFirstChild("Limits")
	if not limits or not limits:IsA("BasePart") then
		return false, "workspace.Limits is missing"
	end

	for _, xSign in ipairs({ -1, 1 }) do
		for _, zSign in ipairs({ -1, 1 }) do
			local corner = cframe:PointToWorldSpace(Vector3.new(
				xSign * size.X * 0.5,
				0,
				zSign * size.Z * 0.5
			))
			local localCorner = limits.CFrame:PointToObjectSpace(corner)
			if math.abs(localCorner.X) > limits.Size.X * 0.5 + Config.EdgeEpsilon
				or math.abs(localCorner.Z) > limits.Size.Z * 0.5 + Config.EdgeEpsilon
			then
				return false, "Base extends outside workspace.Limits"
			end
		end
	end
	return true
end

local function baseInsideLimits(base)
	return Runtime.geometryInsideLimits(base.CFrame, base.Size)
end

function Runtime.nonEmptyAttributeString(instance, attributeName)
	local value = instance:GetAttribute(attributeName)
	if type(value) == "string" and value ~= "" then
		return value
	end
	return nil
end

function Runtime.disconnectPlacedRegistryConnections(connections)
	for _, connection in ipairs(connections or {}) do
		pcall(function()
			connection:Disconnect()
		end)
	end
	table.clear(connections or {})
end

function Runtime.refreshPlacedRegistryIdentity(record)
	local model = record and record.model
	local descriptor = record and record.descriptor
	if not model or not descriptor then
		return
	end
	local attributeName = Runtime.nonEmptyAttributeString(model, "Name")
	descriptor.name = attributeName or model.Name
	descriptor.modelName = model.Name
	descriptor.attributeName = attributeName
	descriptor.category = Runtime.nonEmptyAttributeString(model, "Category")
	descriptor.id = model:GetAttribute("ID")
end

function Runtime.removePlacedRegistryRecord(registry, record)
	if not registry or not record or not record.active then
		return
	end
	record.active = false
	Runtime.disconnectPlacedRegistryConnections(record.modelConnections)
	Runtime.disconnectPlacedRegistryConnections(record.baseConnections)
	if registry.byModel[record.model] == record then
		registry.byModel[record.model] = nil
	end
	for index = #registry.ordered, 1, -1 do
		if registry.ordered[index] == record then
			table.remove(registry.ordered, index)
			break
		end
	end
end

function Runtime.refreshPlacedRegistryModel(registry, model)
	if not registry or registry.released or State.placedRegistry ~= registry
		or not model or not model:IsA("Model")
	then
		return nil
	end
	local record = registry.byModel[model]
	if not model.Parent or not model:IsDescendantOf(Plots) then
		registry.pendingModels[model] = nil
		Runtime.removePlacedRegistryRecord(registry, record)
		return nil
	end
	local base = model:FindFirstChild("Base")
	if not base or not base:IsA("BasePart") then
		-- Keep only the Model as a cheap pending candidate. If an existing direct
		-- child is later renamed to Base, no descendant event fires; the next
		-- collection rechecks this Model and preserves fresh-scan semantics.
		registry.pendingModels[model] = model:FindFirstChildWhichIsA("BasePart") and true or nil
		Runtime.removePlacedRegistryRecord(registry, record)
		return nil
	end
	registry.pendingModels[model] = nil

	if not record then
		record = {
			model = model,
			base = base,
			descriptor = {
				model = model,
				base = base,
			},
			modelConnections = {},
			baseConnections = {},
			active = true,
		}
		registry.byModel[model] = record
		table.insert(registry.ordered, record)

		local function refreshIdentity()
			if record.active and State.placedRegistry == registry and not registry.released then
				Runtime.refreshPlacedRegistryIdentity(record)
			end
		end
		table.insert(record.modelConnections, model:GetPropertyChangedSignal("Name"):Connect(refreshIdentity))
		table.insert(record.modelConnections, model.AttributeChanged:Connect(function(attributeName)
			if attributeName == "Name" or attributeName == "Category" or attributeName == "ID" then
				refreshIdentity()
			end
		end))
	end

	if record.base ~= base then
		Runtime.disconnectPlacedRegistryConnections(record.baseConnections)
		record.base = base
		record.descriptor.base = base
		record.descriptor.cachedFootprint = nil
		record.descriptor.cachedCFrame = nil
		record.descriptor.cachedSize = nil
	end
	if #record.baseConnections == 0 then
		table.insert(record.baseConnections, base:GetPropertyChangedSignal("Name"):Connect(function()
			task.defer(function()
				if record.active and State.placedRegistry == registry and not registry.released then
					Runtime.refreshPlacedRegistryModel(registry, model)
				end
			end)
		end))
	end
	Runtime.refreshPlacedRegistryIdentity(record)
	return record
end

function Runtime.trackPlacedRegistryObject(registry, object)
	if not registry or registry.released or State.placedRegistry ~= registry or not object then
		return
	end
	if object:IsA("Model") then
		Runtime.refreshPlacedRegistryModel(registry, object)
	elseif object:IsA("BasePart") then
		local parent = object.Parent
		if parent and parent:IsA("Model") then
			if object.Name == "Base" then
				Runtime.refreshPlacedRegistryModel(registry, parent)
			else
				registry.pendingModels[parent] = true
			end
		end
	end
end

function Runtime.invalidateConnectionConnectorCache(object)
	local cache = State.connectionConnectorCache
	local cursor = object
	while cursor and cursor ~= Plots do
		if cursor:IsA("Model") and cache[cursor] ~= nil then
			cache[cursor] = nil
			return
		end
		cursor = cursor.Parent
	end
end

function Runtime.releasePlacedRegistry()
	local registry = State.placedRegistry
	if not registry then
		return
	end
	registry.released = true
	Runtime.disconnectPlacedRegistryConnections(registry.connections)
	for _, record in ipairs(registry.ordered) do
		record.active = false
		Runtime.disconnectPlacedRegistryConnections(record.modelConnections)
		Runtime.disconnectPlacedRegistryConnections(record.baseConnections)
	end
	registry.byModel = {}
	registry.ordered = {}
	registry.pendingModels = {}
	State.placedRegistry = nil
end

function Runtime.ensurePlacedRegistry()
	local current = State.placedRegistry
	if current and not current.released then
		return current
	end
	local registry = {
		byModel = {},
		ordered = {},
		pendingModels = setmetatable({}, { __mode = "k" }),
		connections = {},
		released = false,
	}
	State.placedRegistry = registry

	-- Subscribe first, then take the one authoritative snapshot. Objects added
	-- during initialization are therefore seen by either the event or snapshot;
	-- byModel makes that race idempotent.
	table.insert(registry.connections, Plots.DescendantAdded:Connect(function(object)
		Runtime.invalidateConnectionConnectorCache(object)
		Runtime.trackPlacedRegistryObject(registry, object)
	end))
	table.insert(registry.connections, Plots.DescendantRemoving:Connect(function(object)
		if registry.released or State.placedRegistry ~= registry then
			return
		end
		Runtime.invalidateConnectionConnectorCache(object)
		if object:IsA("Model") then
			-- DescendantRemoving is emitted for each nested Model. Remove the direct
			-- record in O(1); the collection-time validity pass also closes any
			-- event-order gap for an outer container move.
			registry.pendingModels[object] = nil
			Runtime.removePlacedRegistryRecord(registry, registry.byModel[object])
		elseif object:IsA("BasePart") and object.Name == "Base" then
			local parent = object.Parent
			local record = parent and registry.byModel[parent]
			if record and record.base == object then
				task.defer(function()
					if not registry.released and State.placedRegistry == registry then
						Runtime.refreshPlacedRegistryModel(registry, parent)
					end
				end)
			end
		end
	end))
	for _, object in ipairs(Plots:GetDescendants()) do
		Runtime.trackPlacedRegistryObject(registry, object)
	end
	return registry
end

function Runtime.rescanPlacedRegistry()
	local registry = Runtime.ensurePlacedRegistry()
	local discovered = 0
	-- DescendantAdded is the fast path, but streamed plot replication and some
	-- executor event bridges can miss or reorder an event. Scan performs only a
	-- few bounded authoritative passes to heal that cache before timing out.
	for _, object in ipairs(Plots:GetDescendants()) do
		if object:IsA("Model") then
			local wasTracked = registry.byModel[object] ~= nil
			local record = Runtime.refreshPlacedRegistryModel(registry, object)
			if record and not wasTracked then
				discovered += 1
			end
		end
	end
	return discovered
end

local function collectPlacedMachines()
	local registry = Runtime.ensurePlacedRegistry()
	local machines = {}
	for model in pairs(registry.pendingModels) do
		if not model.Parent or not model:IsDescendantOf(Plots) then
			registry.pendingModels[model] = nil
		else
			-- Recalculate candidate eligibility too: if its last non-Base direct
			-- BasePart was removed, refresh drops this Model from the pending set.
			Runtime.refreshPlacedRegistryModel(registry, model)
		end
	end
	-- Direct-child validation is cheap and closes the tiny event/defer window
	-- around a replaced Base without returning a stale descriptor to validation.
	for index = #registry.ordered, 1, -1 do
		local record = registry.ordered[index]
		local model = record.model
		local base = model.Parent and model:FindFirstChild("Base")
		if not model.Parent or not model:IsDescendantOf(Plots)
			or not base or not base:IsA("BasePart")
		then
			-- Route every invalid transition through the authoritative refresh so a
			-- Base renamed away in this same scheduler turn becomes pending before
			-- its deferred Name callback can be disconnected.
			Runtime.refreshPlacedRegistryModel(registry, model)
		elseif base ~= record.base then
			Runtime.refreshPlacedRegistryModel(registry, model)
		end
	end
	for _, record in ipairs(registry.ordered) do
		if record.active then
			local descriptor = record.descriptor
			-- Each caller owns footprint/cache fields on its descriptors. Returning
			-- a small copy preserves that isolation while the registry owns only the
			-- authoritative model/Base/identity snapshot.
			table.insert(machines, {
				model = descriptor.model,
				base = descriptor.base,
				name = descriptor.name,
				modelName = descriptor.modelName,
				attributeName = descriptor.attributeName,
				category = descriptor.category,
				id = descriptor.id,
			})
		end
	end
	return machines
end

function Runtime.placedModelMatchesTemplate(placed, template)
	local expectedName = template.Name
	local expectedCategory = template.Parent.Name
	local nameMatches = placed.modelName == expectedName or placed.attributeName == expectedName
	if not nameMatches then
		local expectedID = template:GetAttribute("ID")
		nameMatches = expectedID ~= nil and placed.id ~= nil and tostring(placed.id) == tostring(expectedID)
	end
	return nameMatches and (placed.category == nil or placed.category == expectedCategory)
end

function Runtime.placedModelUnchangedFromSnapshot(placed, snapshot)
	if snapshot == nil then
		return false
	elseif snapshot == true then
		-- Backward compatibility for an in-flight Scan restored from the prior
		-- script version, whose baseline stored only model presence.
		return true
	elseif type(snapshot) ~= "table" or not placed or not placed.model or not placed.base then
		return true
	end
	local idsMatch = snapshot.ID == nil and placed.id == nil
		or (snapshot.ID ~= nil and placed.id ~= nil
			and tostring(snapshot.ID) == tostring(placed.id))
	return snapshot.Base == placed.base
		and snapshot.Parent == placed.model.Parent
		and snapshot.BaseCFrame == placed.base.CFrame
		and snapshot.BaseSize == placed.base.Size
		and snapshot.ModelName == placed.model.Name
		and snapshot.AttributeName == Runtime.nonEmptyAttributeString(placed.model, "Name")
		and snapshot.Category == Runtime.nonEmptyAttributeString(placed.model, "Category")
		and idsMatch
end

local function addReason(preview, reason)
	if table.find(preview.reasons, reason) then
		return
	elseif #preview.reasons < Config.MaxReasonsPerPreview then
		table.insert(preview.reasons, reason)
	elseif #preview.reasons == Config.MaxReasonsPerPreview then
		table.insert(preview.reasons, string.format(
			"additional issues omitted after the first %d",
			Config.MaxReasonsPerPreview
		))
	end
end

local function applyValidityStyle(preview)
	if not preview.highlight or not preview.highlight.Parent then
		return
	end
	local color = preview.valid and GREEN or RED
	preview.highlight.FillColor = color
	preview.highlight.OutlineColor = color
	preview.highlight.Enabled = true
end

local function activePreviews()
	local active = {}
	for _, preview in ipairs(State.previews) do
		if not preview.built then
			table.insert(active, preview)
		end
	end
	return active
end

local function activeAuthoredPlacementPreviews()
	local active = {}
	for _, preview in ipairs(State.authoredPlacementPreviews) do
		if not preview.built then
			table.insert(active, preview)
		end
	end
	return active
end

local function hasPendingBuildWork()
	local counts = Runtime.buildWorkCounts and Runtime.buildWorkCounts()
	if counts then
		return counts.remaining > 0
	end
	return #activePreviews() > 0 or #activeAuthoredPlacementPreviews() > 0
end

function Runtime.buildWorkCounts()
	local groups = {
		State.previews,
		State.authoredPlacementPreviews,
		State.authoredLinkPreviews,
		State.connectionPreviews,
	}
	local total = 0
	local completed = 0
	for _, group in ipairs(groups) do
		for _, item in ipairs(group) do
			total += 1
			if item.built then
				completed += 1
			end
		end
	end
	return {
		total = total,
		completed = completed,
		remaining = total - completed,
	}
end

local function builtItemCount(items)
	local count = 0
	for _, item in ipairs(items or {}) do
		if item.built then
			count += 1
		end
	end
	return count
end

local function compactDuration(seconds)
	seconds = math.max(0, tonumber(seconds) or 0)
	if seconds < 60 then
		return string.format("%.1fs", seconds)
	end
	return string.format("%dm %02ds", math.floor(seconds / 60), math.floor(seconds % 60))
end

function Runtime.beginBuildProgress()
	local counts = Runtime.buildWorkCounts()
	State.buildProgress = {
		stage = "Starting",
		startedAt = os.clock(),
		startingCompleted = counts.completed,
		completed = counts.completed,
		total = counts.total,
	}
	State.lastBuildFailure = nil
	return counts
end

function Runtime.reportBuildProgress(stage, stageCompleted, stageTotal, detail)
	local counts = Runtime.buildWorkCounts()
	local progress = State.buildProgress
	if type(progress) ~= "table" then
		progress = {}
		State.buildProgress = progress
	end
	progress.stage = tostring(stage or "Building")
	progress.completed = counts.completed
	progress.total = counts.total
	local percentage = counts.total > 0 and math.floor((counts.completed / counts.total) * 100 + 0.5) or 100
	local stageText = ""
	if tonumber(stageCompleted) and tonumber(stageTotal) and stageTotal > 0 then
		stageText = string.format(" • %s %d/%d", progress.stage, stageCompleted, stageTotal)
	else
		stageText = " • " .. progress.stage
	end
	local timingText = ""
	local startedAt = tonumber(progress.startedAt)
	local startingCompleted = tonumber(progress.startingCompleted) or 0
	local sessionCompleted = counts.completed - startingCompleted
	if startedAt and sessionCompleted > 0 and counts.remaining > 0 then
		local elapsed = math.max(0, os.clock() - startedAt)
		local eta = (elapsed / sessionCompleted) * counts.remaining
		timingText = " • ETA " .. compactDuration(eta)
	end
	local message = string.format(
		"Build%s • Overall %d/%d (%d%%)%s%s",
		stageText,
		counts.completed,
		counts.total,
		percentage,
		timingText,
		detail and (" • " .. tostring(detail)) or ""
	)
	setStatus(message)
	if updateBlueprintParagraph then
		updateBlueprintParagraph()
	end
	return message, counts
end

function Runtime.buildCancellationReason()
	return State.destroyed and "cancelled by Destroy" or "cancelled by user"
end

function Runtime.requestBuildCancel(silent)
	if State.destroyed then
		return false, "The script is already being destroyed."
	elseif not State.building then
		return false, "No blueprint or duplicate build is currently active."
	elseif State.cancelRequested then
		return true
	end
	State.cancelRequested = true
	setStatus("Stopping safely after the current server call or verification step...")
	if updateBlueprintParagraph then
		updateBlueprintParagraph("Cancellation requested; completed work will be kept for Resume.")
	end
	if not silent then
		notify(
			"Build stopping",
			"The current remote cannot be interrupted, but no next placement or connection will be sent. Completed work is preserved.",
			8
		)
	end
	return true
end

local function connectionLabel(connection)
	return string.format("%s #%d", connection.kind, connection.index)
end

local function findNamedConnector(model, connectorName)
	if not model or not model.Parent then
		return nil, "machine model is unavailable"
	end
	if type(connectorName) ~= "string" or connectorName == "" then
		return nil, "Connector must be a non-empty string"
	end

	local direct = model:FindFirstChild(connectorName)
	if direct and direct:IsA("BasePart") then
		return direct
	end

	local matches = {}
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") and descendant.Name == connectorName then
			table.insert(matches, descendant)
		end
	end
	if #matches == 0 then
		return nil, string.format("connector %q was not found", connectorName)
	elseif #matches > 1 then
		return nil, string.format("connector %q is ambiguous (%d matches)", connectorName, #matches)
	end
	return matches[1]
end

function Runtime.resolveStoredConnectorPath(model, path)
	if not model or not model.Parent or type(path) ~= "table" or #path == 0 then
		return nil, "stored connector path is unavailable"
	end
	local current = model
	for _, segment in ipairs(path) do
		if type(segment) ~= "table"
			or type(segment.Name) ~= "string"
			or segment.Name == ""
		then
			return nil, "stored connector path is malformed"
		end
		local wantedOrdinal = tonumber(segment.Ordinal)
		if not wantedOrdinal or wantedOrdinal < 1 or wantedOrdinal % 1 ~= 0 then
			return nil, "stored connector path ordinal is malformed"
		end
		local ordinal = 0
		local matched
		for _, child in ipairs(current:GetChildren()) do
			if child.Name == segment.Name
				and (segment.ClassName == nil or child.ClassName == segment.ClassName)
			then
				ordinal += 1
				if ordinal == wantedOrdinal then
					matched = child
					break
				end
			end
		end
		if not matched then
			return nil, string.format("connector path segment %s[%d] is missing", segment.Name, wantedOrdinal)
		end
		current = matched
	end
	if not current:IsA("BasePart") then
		return nil, "stored connector path did not resolve to a BasePart"
	end
	return current
end

function Runtime.resolveConnectorReference(model, reference)
	if type(reference) == "table"
		and type(reference.ConnectorPath) == "table"
		and #reference.ConnectorPath > 0
	then
		return Runtime.resolveStoredConnectorPath(model, reference.ConnectorPath)
	end
	return findNamedConnector(model, reference and reference.Connector)
end

local function resolveConnectionEndpoint(reference, usePlacedModel)
	if type(reference) ~= "table" then
		return nil, "endpoint must be a table"
	end
	local machineIndex = tonumber(reference.Machine)
	if not machineIndex or machineIndex % 1 ~= 0 or machineIndex < 1 then
		return nil, "endpoint Machine must be a positive blueprint index"
	end
	local machinePreview = State.previews[machineIndex]
	if not machinePreview then
		return nil, string.format("blueprint machine #%d does not exist", machineIndex)
	end

	local model = usePlacedModel
		and machinePreview.placedModel
		or (machinePreview.model or machinePreview.placedModel)
	if not model or not model.Parent then
		return nil, string.format(
			"blueprint machine #%d %s is unavailable",
			machineIndex,
			tostring(machinePreview.entry and machinePreview.entry.Name)
		)
	end
	return Runtime.resolveConnectorReference(model, reference)
end

local function resolveAuthoredEndpoint(reference, usePlacedModel)
	if type(reference) ~= "table" then
		return nil, "endpoint must be a table"
	end

	local preview
	local label
	local machineIndex = tonumber(reference.Machine)
	local pieceIndex = tonumber(reference.Piece)
	if machineIndex and machineIndex % 1 == 0 and machineIndex >= 1 then
		preview = State.previews[machineIndex]
		label = string.format("blueprint machine #%d", machineIndex)
	elseif pieceIndex and pieceIndex % 1 == 0 and pieceIndex >= 1 then
		preview = State.authoredPlacementPreviews[pieceIndex]
		label = string.format("authored plumbing piece #%d", pieceIndex)
	else
		return nil, "endpoint must contain one positive Machine or Piece index"
	end
	if not preview then
		return nil, label .. " does not exist"
	end

	local model = usePlacedModel
		and preview.placedModel
		or (preview.model or preview.placedModel)
	if not model or not model.Parent then
		return nil, label .. " is unavailable"
	end
	return Runtime.resolveConnectorReference(model, reference)
end

local function authoredEndpointLabel(reference)
	if type(reference) ~= "table" then
		return "invalid endpoint"
	elseif reference.Machine then
		return string.format("machine #%s.%s", tostring(reference.Machine), tostring(reference.Connector))
	end
	return string.format("piece #%s.%s", tostring(reference.Piece), tostring(reference.Connector))
end

local function connectorFolder(connector, kind)
	local folderName = kind == "Pipe" and "Pipe" or "Power"
	local folder = connector and connector:FindFirstChild(folderName)
	if not folder or not folder:IsA("Folder") then
		return nil, string.format("%s has no %s metadata Folder", connector and connector.Name or "connector", folderName)
	end
	return folder
end

local function booleanValue(folder, name)
	local value = folder:FindFirstChild(name)
	return value and value:IsA("BoolValue") and value.Value == true
end

local function pipeLiquidKind(metadata)
	local buffer = metadata and metadata:FindFirstChild("Buffer")
	if not buffer then
		return nil, "Pipe metadata has no Buffer"
	end
	local liquid = buffer:GetAttribute("Liquid")
	if typeof(liquid) ~= "boolean" then
		return nil, "Pipe Buffer has no boolean Liquid attribute"
	end
	return liquid and "Fluid" or "Item"
end

local function connectorNamesCompatible(kind, firstName, secondName)
	if firstName == secondName then
		return true
	end
	if kind == "Pipe" then
		return firstName == "Pipe"
			or secondName == "Pipe"
			or string.find(firstName, "MainPipe", 1, true) ~= nil
			or string.find(secondName, "MainPipe", 1, true) ~= nil
	end
	return firstName == "Connector"
		or secondName == "Connector"
		or firstName == "HVConnector"
		or secondName == "HVConnector"
		or string.find(firstName, "MainConnector", 1, true) ~= nil
		or string.find(secondName, "MainConnector", 1, true) ~= nil
end

local function connectionHasExactEndpointPaths(entry)
	return type(entry) == "table"
		and type(entry.From) == "table"
		and type(entry.From.ConnectorPath) == "table"
		and #entry.From.ConnectorPath > 0
		and type(entry.To) == "table"
		and type(entry.To.ConnectorPath) == "table"
		and #entry.To.ConnectorPath > 0
end

local function connectionDistance(kind, fromConnector, toConnector)
	if kind == "Pipe" then
		return (fromConnector.Position - toConnector.Position).Magnitude
	end
	local first = Vector2.new(fromConnector.Position.X, fromConnector.Position.Z)
	local second = Vector2.new(toConnector.Position.X, toConnector.Position.Z)
	return (first - second).Magnitude
end

local function maximumConnectionDistance(kind, fromConnector)
	assert(kind == "Wire", "physical pipes do not use a direct connection range")
	local difficulty = tonumber(workspace:GetAttribute("Difficulty")) or 0
	local defaultRange = difficulty >= 4 and Config.HardModeWireRange or Config.DefaultWireRange
	return tonumber(fromConnector:GetAttribute("WireRange")) or defaultRange
end

local function inspectConnection(connection, usePlacedModel)
	local reasons = {}
	if type(connection.entry) ~= "table" then
		return false, nil, nil, { "connection entry must be a table" }
	end
	local fromConnector, fromError = resolveConnectionEndpoint(connection.entry.From, usePlacedModel)
	local toConnector, toError = resolveConnectionEndpoint(connection.entry.To, usePlacedModel)
	if not fromConnector then
		table.insert(reasons, "From: " .. fromError)
	end
	if not toConnector then
		table.insert(reasons, "To: " .. toError)
	end
	if not fromConnector or not toConnector then
		return false, fromConnector, toConnector, reasons
	end
	if fromConnector == toConnector then
		table.insert(reasons, "From and To resolve to the same connector")
	end

	local fromMetadata, fromMetadataError = connectorFolder(fromConnector, connection.kind)
	local toMetadata, toMetadataError = connectorFolder(toConnector, connection.kind)
	if not fromMetadata then
		table.insert(reasons, "From: " .. fromMetadataError)
	elseif booleanValue(fromMetadata, "Input") then
		table.insert(reasons, "From connector is marked Input")
	end
	if not toMetadata then
		table.insert(reasons, "To: " .. toMetadataError)
	elseif booleanValue(toMetadata, "Output") then
		table.insert(reasons, "To connector is marked Output")
	end
	if connection.kind == "Pipe" and fromMetadata and toMetadata then
		local fromKind, fromKindError = pipeLiquidKind(fromMetadata)
		local toKind, toKindError = pipeLiquidKind(toMetadata)
		if not fromKind then
			table.insert(reasons, "From: " .. fromKindError)
		end
		if not toKind then
			table.insert(reasons, "To: " .. toKindError)
		end
		if fromKind and toKind and fromKind ~= toKind then
			table.insert(reasons, string.format("cannot connect %s pipe to %s pipe", fromKind, toKind))
		end
	end

	-- Exact normalized paths identify both catalog holes without relying on the
	-- incomplete connector-name heuristic. Direction, liquid, and range checks
	-- above/below remain mandatory.
	if not connectionHasExactEndpointPaths(connection.entry)
		and not connectorNamesCompatible(connection.kind, fromConnector.Name, toConnector.Name)
	then
		table.insert(reasons, string.format(
			"incompatible connector names %s -> %s",
			fromConnector.Name,
			toConnector.Name
		))
	end
	if connection.kind == "Wire" then
		local distance = connectionDistance(connection.kind, fromConnector, toConnector)
		local maximum = maximumConnectionDistance(connection.kind, fromConnector)
		if distance > maximum + Config.EdgeEpsilon then
			table.insert(reasons, string.format("distance %.2f exceeds %.2f stud range", distance, maximum))
		end
	end
	return #reasons == 0, fromConnector, toConnector, reasons
end

function Runtime.gameConnectionPreviewDonor(kind)
	local cached = State.connectionPreviewDonorCache[kind]
	if cached and cached:IsA("BasePart") then
		return cached
	end
	local expectedName = kind == "Pipe" and "Pipe" or "Power"
	for _, candidate in ipairs(ConnectionDecorations:GetDescendants()) do
		-- Native decoration pairs contain a scalable Part segment plus an endpoint
		-- cap. The canonical ghost already supplies the real connector endpoints,
		-- so Preview needs only an inert snapshot of that game's segment geometry.
		if candidate:IsA("Part") and candidate.Name == expectedName then
			local cloneOK, snapshot = pcall(function()
				return candidate:Clone()
			end)
			if cloneOK and snapshot and snapshot:IsA("BasePart") then
				snapshot.Parent = nil
				for _, descendant in ipairs(snapshot:GetDescendants()) do
					if descendant:IsA("LuaSourceContainer") or descendant:IsA("Constraint") then
						descendant:Destroy()
					end
				end
				State.connectionPreviewDonorCache[kind] = snapshot
				return snapshot
			end
		end
	end
	return nil
end

function Runtime.createConnectionPreviewLine(folder, name, budgetOwner, kind)
	local used = tonumber(budgetOwner.previewConnectionLinesUsed) or 0
	if used >= Config.MaxVisibleConnectionPreviewLines then
		return nil
	end
	budgetOwner.previewConnectionLinesUsed = used + 1
	local wantsGameStyle = State.gameStyleConnectionPreview == true
	local donor = wantsGameStyle and Runtime.gameConnectionPreviewDonor(kind) or nil
	local line
	if donor then
		local cloned, cloneResult = pcall(function()
			return donor:Clone()
		end)
		if cloned and cloneResult and cloneResult:IsA("BasePart") then
			line = cloneResult
		end
	end
	local usedNativeDonor = line ~= nil
	line = line or Instance.new("Part")
	for _, descendant in ipairs(line:GetDescendants()) do
		if descendant:IsA("LuaSourceContainer") or descendant:IsA("Constraint") then
			descendant:Destroy()
		end
	end
	line.Name = name
	line.Anchored = true
	line.CanCollide = false
	line.CanTouch = false
	line.CanQuery = false
	line.CastShadow = false
	if usedNativeDonor or wantsGameStyle then
		-- SmoothPlastic, the observed Pipe/Power proportions below, and the
		-- canonical endpoint ghosts keep a clean plot game-like even before any
		-- live connection exists to donate its exact server decoration Part.
		line.Material = Enum.Material.SmoothPlastic
	else
		line.Material = Enum.Material.Neon
	end
	line.Size = Vector3.new(0.1, 0.1, 0.1)
	line.Transparency = 1
	line.Color = RED
	line:SetAttribute("IndustrialistGameStyle", wantsGameStyle)
	line:SetAttribute(
		"IndustrialistGameStyleSource",
		usedNativeDonor and "NativeDecoration" or wantsGameStyle and "CanonicalFallback" or "Lightweight"
	)
	line.Parent = folder
	return line
end

local function updateConnectionLine(connection, fromConnector, toConnector)
	if not connection.line or not connection.line.Parent or not fromConnector or not toConnector then
		return
	end
	connection.line.Transparency = 0.25
	local delta = toConnector.Position - fromConnector.Position
	local distance = delta.Magnitude
	if distance < 0.001 then
		connection.line.Size = Vector3.new(0.2, 0.2, 0.2)
		connection.line.CFrame = CFrame.new(fromConnector.Position)
	else
		local thickness = connection.kind == "Pipe" and 0.34 or 0.16
		connection.line.Size = Vector3.new(thickness, thickness, distance)
		connection.line.CFrame = CFrame.lookAt(
			(fromConnector.Position + toConnector.Position) * 0.5,
			toConnector.Position
		)
	end
	connection.line.Color = connection.valid and GREEN or RED
end

local function inspectAuthoredPipeLink(link, usePlacedModel)
	local reasons = {}
	if type(link.entry) ~= "table" then
		return false, nil, nil, { "link entry must be a table" }
	end
	local fromConnector, fromError = resolveAuthoredEndpoint(link.entry.From, usePlacedModel)
	local toConnector, toError = resolveAuthoredEndpoint(link.entry.To, usePlacedModel)
	if not fromConnector then
		table.insert(reasons, "From: " .. tostring(fromError))
	end
	if not toConnector then
		table.insert(reasons, "To: " .. tostring(toError))
	end
	if not fromConnector or not toConnector then
		return false, fromConnector, toConnector, reasons
	elseif fromConnector == toConnector then
		table.insert(reasons, "From and To resolve to the same connector")
	end

	local fromMetadata, fromMetadataError = connectorFolder(fromConnector, "Pipe")
	local toMetadata, toMetadataError = connectorFolder(toConnector, "Pipe")
	if not fromMetadata then
		table.insert(reasons, "From: " .. fromMetadataError)
	elseif booleanValue(fromMetadata, "Input") then
		table.insert(reasons, "From connector is marked Input")
	end
	if not toMetadata then
		table.insert(reasons, "To: " .. toMetadataError)
	elseif booleanValue(toMetadata, "Output") then
		table.insert(reasons, "To connector is marked Output")
	end
	if fromMetadata and toMetadata then
		local fromKind, fromKindError = pipeLiquidKind(fromMetadata)
		local toKind, toKindError = pipeLiquidKind(toMetadata)
		if not fromKind then
			table.insert(reasons, "From: " .. fromKindError)
		end
		if not toKind then
			table.insert(reasons, "To: " .. toKindError)
		end
		if fromKind and toKind and fromKind ~= toKind then
			table.insert(reasons, string.format("cannot bind %s pipe to %s pipe", fromKind, toKind))
		end
	end
	if not connectionHasExactEndpointPaths(link.entry)
		and not connectorNamesCompatible("Pipe", fromConnector.Name, toConnector.Name)
	then
		table.insert(reasons, string.format(
			"incompatible connector names %s -> %s",
			fromConnector.Name,
			toConnector.Name
		))
	end
	local distance = connectionDistance("Pipe", fromConnector, toConnector)
	if distance > Config.VerifiedPipeBindRange + Config.EdgeEpsilon then
		table.insert(reasons, string.format(
			"exact authored bind is %.2f studs; observed server range is %.2f",
			distance,
			Config.VerifiedPipeBindRange
		))
	end
	return #reasons == 0, fromConnector, toConnector, reasons
end

local function createAuthoredLinkPreviews(folder)
	State.authoredLinkPreviews = {}
	for index, entry in ipairs(AuthoredPipeLinks) do
		local link = {
			kind = "Pipe",
			index = index,
			entry = entry,
			reasons = {},
			valid = false,
			built = false,
		}
		link.line = Runtime.createConnectionPreviewLine(
			folder,
			string.format("AuthoredPipeLink_%02d", index),
			State,
			"Pipe"
		)
		table.insert(State.authoredLinkPreviews, link)
	end
end

local function validateAuthoredLinkPreviews()
	local allValid = #State.authoredLinkPreviews == #AuthoredPipeLinks
	local seenPairs = {}
	if not allValid then
		warn(PREFIX .. "authored pipe links changed; regenerate preview")
	end
	for _, link in ipairs(State.authoredLinkPreviews) do
		local valid, fromConnector, toConnector, reasons = inspectAuthoredPipeLink(link, false)
		if AuthoredPipeLinks[link.index] ~= link.entry then
			table.insert(reasons, "authored link changed; regenerate preview")
			valid = false
		end
		if fromConnector and toConnector then
			local first = seenPairs[fromConnector] or {}
			local duplicate = first[toConnector]
				or (seenPairs[toConnector] and seenPairs[toConnector][fromConnector])
			if duplicate then
				table.insert(reasons, "duplicates authored link #" .. duplicate)
				valid = false
			else
				seenPairs[fromConnector] = first
				first[toConnector] = link.index
			end
		end
		if link.built and Runtime.committedConnectionError then
			local committedError = Runtime.committedConnectionError(link, inspectAuthoredPipeLink)
			if committedError then
				table.insert(reasons, committedError)
				valid = false
			end
		end
		link.reasons = reasons
		link.valid = valid and #reasons == 0
		updateConnectionLine(link, fromConnector, toConnector)
		if link.valid then
			if Config.VerboseValidationLogging then
				print(PREFIX .. string.format(
					"authored pipe link #%d valid | %s -> %s | %.2f studs",
					link.index,
					authoredEndpointLabel(link.entry.From),
					authoredEndpointLabel(link.entry.To),
					connectionDistance("Pipe", fromConnector, toConnector)
				))
			end
		else
			allValid = false
			warn(PREFIX .. string.format(
				"authored pipe link #%d invalid: %s",
				link.index,
				table.concat(reasons, "; ")
			))
		end
	end
	return allValid
end

-- Saved and generated physical pipe models share this exact preview/link
-- validator. Auto-Plumb has already materialized its route arrays by here.

local function createConnectionPreviews(folder)
	State.connectionPreviews = {}
	for index, entry in ipairs(Wiring) do
		local connection = {
			kind = "Wire",
			index = index,
			entry = entry,
			reasons = {},
			valid = false,
			built = false,
		}
		connection.line = Runtime.createConnectionPreviewLine(
			folder,
			string.format("WirePreview_%02d", index),
			State,
			"Wire"
		)
		table.insert(State.connectionPreviews, connection)
	end
end

local function validateConnectionPreviews()
	local allValid = true
	local seenPairs = {}
	if #State.connectionPreviews ~= #Wiring then
		warn(PREFIX .. "wire definitions changed; regenerate preview")
		allValid = false
	end
	for _, connection in ipairs(State.connectionPreviews) do
		local definitionChanged = Wiring[connection.index] ~= connection.entry
		local valid, fromConnector, toConnector, reasons = inspectConnection(connection, false)
		if definitionChanged then
			table.insert(reasons, "wire definitions changed; regenerate preview")
			valid = false
		end
		connection.reasons = reasons
		if fromConnector and toConnector then
			local forward = seenPairs[fromConnector]
			local reverse = seenPairs[toConnector]
			local duplicate = (forward and forward[toConnector]) or (reverse and reverse[fromConnector])
			if duplicate then
				table.insert(connection.reasons, "duplicates " .. duplicate)
				valid = false
			else
				forward = forward or {}
				seenPairs[fromConnector] = forward
				forward[toConnector] = connectionLabel(connection)
			end
		end
		if connection.built and Runtime.committedConnectionError then
			local committedError = Runtime.committedConnectionError(connection, inspectConnection)
			if committedError then
				table.insert(reasons, committedError)
				valid = false
			end
		end
		connection.valid = valid and #connection.reasons == 0
		updateConnectionLine(connection, fromConnector, toConnector)
		if connection.valid then
			if Config.VerboseValidationLogging then
				print(PREFIX .. string.format(
					"%s valid | %s -> %s | %.2f studs",
					connectionLabel(connection),
					fromConnector.Name,
					toConnector.Name,
					connectionDistance(connection.kind, fromConnector, toConnector)
				))
			end
		else
			allValid = false
			warn(PREFIX .. string.format(
				"%s invalid: %s",
				connectionLabel(connection),
				table.concat(connection.reasons, "; ")
			))
		end
	end
	return allValid
end

local function matchingExistingMachine(preview, existing, excludedModels)
	if not preview.template or not preview.base then
		return nil
	end
	local candidates = Runtime.placedNearbyCandidates
		and Runtime.placedNearbyCandidates(existing, preview.base.Position, Config.VerifyRadius)
		or existing
	for _, cachedPlaced in ipairs(candidates) do
		local model = cachedPlaced.model
		local base = model and model.Parent and model:FindFirstChild("Base")
		if model and base and base:IsA("BasePart") and model:IsDescendantOf(Plots) then
			-- Spatial records cache geometry for speed, but identity attributes can
			-- change without touching Base. Rebuild the small descriptor here so
			-- last-second reuse always reads live Name/Category/ID evidence.
			local placed = Runtime.placedDescriptor(model, base)
			if (not excludedModels
				or not Runtime.placedModelUnchangedFromSnapshot(placed, excludedModels[model]))
				and Runtime.placedModelMatchesTemplate(placed, preview.template)
			then
				local geometryIssue = Runtime.classifyPlacementGeometry(
					preview,
					base,
					Config.VerifyHeightTolerance
				)
				if geometryIssue == nil then
					return model
				end
			end
		end
	end
	return nil
end

function Runtime.snapshotKnownPlacedModels(knownModels)
	local snapshot = {}
	for model, known in pairs(type(knownModels) == "table" and knownModels or {}) do
		if known then
			snapshot[model] = true
		end
	end
	return snapshot
end

function Runtime.matchFreshPlacementSinceBaseline(preview, existing)
	local baseline = preview and preview.recoveryKnownModels
	if type(baseline) ~= "table" then
		return nil
	end
	local candidates = Runtime.placedNearbyCandidates(
		existing,
		expectedPlacementBase(preview).Position,
		Config.VerifyRadius
	)
	local exactMatches = {}
	local seen = {}
	for _, cachedPlaced in ipairs(candidates) do
		local model = cachedPlaced.model
		local base = model and model.Parent and model:FindFirstChild("Base")
		if model and not seen[model] and not baseline[model]
			and base and base:IsA("BasePart") and model:IsDescendantOf(Plots)
		then
			seen[model] = true
			local placed = Runtime.placedDescriptor(model, base)
			local geometryIssue = Runtime.classifyPlacementGeometry(
				preview,
				base,
				Config.VerifyHeightTolerance
			)
			if Runtime.placedModelMatchesTemplate(placed, preview.template)
				and geometryIssue == nil
			then
				table.insert(exactMatches, model)
			end
		end
	end
	if #exactMatches > 1 then
		return nil, string.format(
			"%d fresh exact placements now occupy the duplicate destination; recovery is ambiguous",
			#exactMatches
		)
	end
	return exactMatches[1]
end

function Runtime.pinnedScannedReuse(preview, previewKind, existing)
	local matchedEntry = State.scanMatchedEntry
	local scannedModel = State.scanPlacedModel
	if not State.scanComplete
		or type(matchedEntry) ~= "table"
		or matchedEntry.Kind ~= previewKind
		or matchedEntry.Index ~= preview.index
		or not scannedModel
		or not scannedModel.Parent
	then
		return nil
	end
	for _, placed in ipairs(existing) do
		if placed.model == scannedModel then
			return matchingExistingMachine(preview, { placed })
		end
	end
	return nil
end

local function validateAuthoredPlacementPreviews(existing)
	local allValid = #State.authoredPlacementPreviews == #AuthoredPlumbing
	local machineSpatial = Runtime.newTransientSpatialIndex()
	for _, machinePreview in ipairs(State.previews) do
		if machinePreview.base and machinePreview.model and machinePreview.model.Parent then
			Runtime.addTransientSpatialEntry(
				machineSpatial,
				machinePreview,
				machinePreview.cachedFootprint or footprint(machinePreview.base)
			)
		end
	end
	if not allValid then
		warn(PREFIX .. "authored plumbing placements changed; regenerate preview")
	end

	for _, preview in ipairs(State.authoredPlacementPreviews) do
		preview.reasons = {}
		preview.overlapInvalid = false
		preview.reuseModel = nil
		if AuthoredPlumbing[preview.index] ~= preview.entry
			or preview.entrySignature ~= entrySignature(preview.entry)
			or math.abs(preview.originX - State.originX) > 0.0001
			or math.abs(preview.originZ - State.originZ) > 0.0001
			or preview.layoutRotation ~= State.layoutRotation
		then
			addReason(preview, "authored placement, origin, or layout rotation changed; regenerate preview")
		elseif preview.built then
			local committedError = Runtime.committedPlacementError
				and Runtime.committedPlacementError(preview)
			if committedError then
				addReason(preview, committedError)
			end
		elseif preview.setupError then
			addReason(preview, preview.setupError)
		elseif not preview.model or not preview.model.Parent or not preview.base then
			addReason(preview, "authored plumbing preview is missing")
		else
			local inside, limitsError = baseInsideLimits(preview.base)
			if not inside then
				addReason(preview, limitsError)
			end
			preview.reuseModel = Runtime.pinnedScannedReuse(preview, "Plumbing", existing)
				or matchingExistingMachine(preview, existing)
			local candidate = footprint(preview.base)
			preview.cachedFootprint = candidate
			for _, placed in ipairs(Runtime.placedCollisionCandidates(existing, candidate)) do
				local existingFootprint = Runtime.placedFootprint(placed)
				if placed.model ~= preview.reuseModel
					and existingFootprint
					and footprintsOverlap(candidate, existingFootprint)
				then
					addReason(preview, "overlaps existing " .. placed.name)
					preview.overlapInvalid = true
					break
				end
			end
			if not preview.overlapInvalid then
				Runtime.visitSpatialIndex(machineSpatial, candidate, function(machinePreview)
					if footprintsOverlap(
						candidate,
						machinePreview.cachedFootprint or footprint(machinePreview.base)
					)
					then
						addReason(preview, string.format(
							"overlaps blueprint machine #%d %s",
							machinePreview.index,
							tostring(machinePreview.entry and machinePreview.entry.Name)
						))
						preview.overlapInvalid = true
						return false
					end
					return true
				end)
			end
		end
	end

	local authoredSpatial = Runtime.newTransientSpatialIndex()
	for _, second in ipairs(State.authoredPlacementPreviews) do
		if second.base then
			local secondFootprint = second.cachedFootprint or footprint(second.base)
			Runtime.visitSpatialIndex(authoredSpatial, secondFootprint, function(first)
				if not (first.overlapInvalid and second.overlapInvalid)
					and footprintsOverlap(first.cachedFootprint or footprint(first.base), secondFootprint)
				then
					if not first.overlapInvalid then
						addReason(first, "overlaps authored plumbing piece #" .. second.index)
					end
					if not second.overlapInvalid then
						addReason(second, "overlaps authored plumbing piece #" .. first.index)
					end
					first.overlapInvalid = true
					second.overlapInvalid = true
				end
				return true
			end)
			Runtime.addTransientSpatialEntry(authoredSpatial, second, secondFootprint)
		end
	end

	local invalidPreviewCount = 0
	for _, preview in ipairs(State.authoredPlacementPreviews) do
		preview.valid = #preview.reasons == 0
		applyValidityStyle(preview)
		if preview.valid then
			if Config.VerboseValidationLogging then
				print(PREFIX .. string.format(
					"authored plumbing piece #%d %s valid%s",
					preview.index,
					tostring(preview.entry and preview.entry.Name),
					preview.reuseModel and " | matching server model will be reused" or ""
				))
			end
		else
			allValid = false
			invalidPreviewCount += 1
			if invalidPreviewCount <= Config.MaxInvalidPreviewWarnings then
				warn(PREFIX .. string.format(
					"authored plumbing piece #%d %s invalid: %s",
					preview.index,
					tostring(preview.entry and preview.entry.Name),
					table.concat(preview.reasons, "; ")
				))
			end
		end
	end
	if invalidPreviewCount > Config.MaxInvalidPreviewWarnings then
		warn(PREFIX .. string.format(
			"%d additional invalid plumbing preview warning(s) omitted",
			invalidPreviewCount - Config.MaxInvalidPreviewWarnings
		))
	end
	return allValid
end

local function previewFailureSummary()
	local invalidCount = 0
	local firstFailure
	local groups = {
		{
			items = State.previews,
			label = function(item)
				return string.format("machine #%d %s", item.index, tostring(item.entry and item.entry.Name))
			end,
		},
		{
			items = State.authoredPlacementPreviews,
			label = function(item)
				return string.format("plumbing piece #%d %s", item.index, tostring(item.entry and item.entry.Name))
			end,
		},
		{
			items = State.authoredLinkPreviews,
			label = function(item)
				return string.format("pipe link #%d", item.index)
			end,
		},
		{
			items = State.connectionPreviews,
			label = function(item)
				return connectionLabel(item)
			end,
		},
	}
	for _, group in ipairs(groups) do
		for _, item in ipairs(group.items) do
			if type(item.reasons) == "table" and #item.reasons > 0 then
				invalidCount += 1
				if not firstFailure then
					firstFailure = group.label(item) .. ": " .. tostring(item.reasons[1])
				end
			end
		end
	end
	return invalidCount, firstFailure
end

local function validatePreviews(existing)
	if State.building then
		notify("Validation refused", "A blueprint build is currently running.", 6)
		return false
	end
	local previews = activePreviews()
	local suppliedIndex = type(existing) == "table" and existing._spatialIndex
	local ownsExisting = type(suppliedIndex) ~= "table"
		or suppliedIndex.released == true
		or State.activePlacedCaches[existing] ~= true
	if ownsExisting then
		existing = Runtime.preparePlacedCache(collectPlacedMachines())
	end
	local allValid = #previews > 0
		or #activeAuthoredPlacementPreviews() > 0
		or #State.authoredLinkPreviews > 0
		or #State.connectionPreviews > 0
	if #State.previews ~= #Blueprint then
		warn(PREFIX .. "machine definitions changed; regenerate preview")
		allValid = false
	end
	for _, preview in ipairs(State.previews) do
		if preview.built then
			preview.reasons = {}
			local committedError = Runtime.committedPlacementError
				and Runtime.committedPlacementError(preview)
			if committedError then
				addReason(preview, committedError)
				allValid = false
				warn(PREFIX .. string.format(
					"built machine #%d %s changed after verification: %s",
					preview.index,
					tostring(preview.entry and preview.entry.Name),
					committedError
				))
			end
		end
	end

	for _, preview in ipairs(previews) do
		preview.reasons = {}
		preview.overlapInvalid = false
		preview.reuseModel = nil
		local currentSignature = entrySignature(preview.entry)
		if Blueprint[preview.index] ~= preview.entry
			or preview.entrySignature ~= currentSignature
			or math.abs(preview.originX - State.originX) > 0.0001
			or math.abs(preview.originZ - State.originZ) > 0.0001
			or preview.layoutRotation ~= State.layoutRotation
		then
			addReason(preview, "blueprint, origin, or layout rotation changed; regenerate preview")
		elseif preview.setupError then
			addReason(preview, preview.setupError)
		elseif not preview.model or not preview.model.Parent or not preview.base then
			addReason(preview, "preview model is missing")
		else
			local inside, limitsError = baseInsideLimits(preview.base)
			if not inside then
				addReason(preview, limitsError)
			end

			preview.reuseModel = Runtime.pinnedScannedReuse(preview, "Machine", existing)
				or matchingExistingMachine(preview, existing)
			local candidate = footprint(preview.base)
			preview.cachedFootprint = candidate
			for _, placed in ipairs(Runtime.placedCollisionCandidates(existing, candidate)) do
				local existingFootprint = Runtime.placedFootprint(placed)
				if placed.model ~= preview.reuseModel
					and existingFootprint
					and footprintsOverlap(candidate, existingFootprint)
				then
					addReason(preview, "overlaps existing " .. placed.name)
					preview.overlapInvalid = true
					break
				end
			end
		end
	end

	local previewSpatial = Runtime.newTransientSpatialIndex()
	for _, second in ipairs(previews) do
		if second.base then
			local secondFootprint = second.cachedFootprint or footprint(second.base)
			Runtime.visitSpatialIndex(previewSpatial, secondFootprint, function(first)
				if not (first.overlapInvalid and second.overlapInvalid)
					and footprintsOverlap(first.cachedFootprint or footprint(first.base), secondFootprint)
				then
					if not first.overlapInvalid then
						addReason(first, "overlaps blueprint #" .. second.index .. " " .. tostring(second.entry.Name))
					end
					if not second.overlapInvalid then
						addReason(second, "overlaps blueprint #" .. first.index .. " " .. tostring(first.entry.Name))
					end
					first.overlapInvalid = true
					second.overlapInvalid = true
				end
				return true
			end)
			Runtime.addTransientSpatialEntry(previewSpatial, second, secondFootprint)
		end
	end

	local invalidPreviewCount = 0
	for _, preview in ipairs(previews) do
		preview.valid = #preview.reasons == 0
		applyValidityStyle(preview)
		if preview.valid then
			if Config.VerboseValidationLogging then
				local offset = preview.targetCFrame:PointToObjectSpace(preview.base.Position)
				print(PREFIX .. string.format(
					"#%d %s valid%s | Base %.2fx%.2f | pivot offset (%.2f, %.2f)",
					preview.index,
					preview.entry.Name,
					preview.reuseModel and " | matching server model will be reused" or "",
					preview.base.Size.X,
					preview.base.Size.Z,
					offset.X,
					offset.Z
				))
			end
		else
			allValid = false
			invalidPreviewCount += 1
			if invalidPreviewCount <= Config.MaxInvalidPreviewWarnings then
				warn(PREFIX .. string.format(
					"#%d %s invalid: %s",
					preview.index,
					tostring(preview.entry.Name),
					table.concat(preview.reasons, "; ")
				))
			end
		end
	end
	if invalidPreviewCount > Config.MaxInvalidPreviewWarnings then
		warn(PREFIX .. string.format(
			"%d additional invalid machine preview warning(s) omitted",
			invalidPreviewCount - Config.MaxInvalidPreviewWarnings
		))
	end
	if not validateAuthoredPlacementPreviews(existing) then
		allValid = false
	end
	if not validateAuthoredLinkPreviews() then
		allValid = false
	end
	if not validateConnectionPreviews() then
		allValid = false
	end

	State.validated = allValid
	if allValid then
		log(
			"Validation passed: %d machine(s), %d exact plumbing placement(s), %d exact pipe bind(s)",
			#State.previews,
			#State.authoredPlacementPreviews,
			#State.authoredLinkPreviews
		)
	else
		local invalidCount, firstFailure = previewFailureSummary()
		log(
			"Preview blocked: %d item(s)%s",
			invalidCount,
			firstFailure and (" • first: " .. firstFailure) or "; inspect console details"
		)
	end
	if ownsExisting then
		Runtime.releasePlacedCache(existing)
	end
	return allValid
end

function Runtime.previewAndValidateCore()
	if State.destroyed then
		return false
	elseif State.autoFitInProgress then
		local message = Runtime.autoFitBusyReason()
		notify("Preview waiting", message, 6)
		return false, message
	elseif State.building then
		notify("Preview refused", "A blueprint build is currently running.", 6)
		return false
	end
	State.previewEpoch += 1
	local previewEpoch = State.previewEpoch
	State.activePreviewEpoch = previewEpoch
	local requestedX = State.originX
	local requestedZ = State.originZ
	local snappedX, snappedZ, originAdjusted = setBlueprintOrigin(requestedX, requestedZ)
	if originAdjusted then
		notify("Origin snapped to grid", string.format(
			"X %.3f, Z %.3f -> X %.0f, Z %.0f for the machine placement grid.",
			requestedX,
			requestedZ,
			snappedX,
			snappedZ
		), 7)
	end
	local folder, folderError = getPreviewFolder()
	if not folder then
		notify("Preview failed", folderError, 8)
		return false
	end

	folder:ClearAllChildren()
	State.previews = {}
	State.authoredPlacementPreviews = {}
	State.authoredLinkPreviews = {}
	State.connectionPreviews = {}
	State.previewConnectionLinesUsed = 0
	State.validated = false

	for index, entry in ipairs(Blueprint) do
		table.insert(State.previews, createPreview(index, entry, folder))
		if index % Config.PreviewRenderYieldEvery == 0 then
			RunService.Heartbeat:Wait()
			if State.destroyed or State.previewEpoch ~= previewEpoch then
				return false, "Preview was cancelled because its source/settings changed."
			end
		end
	end

	-- Saved physical plumbing is kept for backwards compatibility. New compact
	-- blueprints normally contain only machines plus AutoPlumb route intent.
	-- Generate the physical pieces now so the exact same strict preview/build
	-- pipeline handles both saved and calculated plumbing.
	local savedPlacementCount = #State.sourceAuthoredPlumbing
	for index, entry in ipairs(State.sourceAuthoredPlumbing) do
		local preview = createPreview(index, entry, folder)
		preview.kind = "AuthoredPlumbing"
		if preview.model then
			preview.model.Name = string.format("Plumbing_%02d_%s", index, entry.Name)
		end
		table.insert(State.authoredPlacementPreviews, preview)
		if index % Config.PreviewRenderYieldEvery == 0 then
			RunService.Heartbeat:Wait()
			if State.destroyed or State.previewEpoch ~= previewEpoch then
				return false, "Preview was cancelled because its source/settings changed."
			end
		end
	end
	local plumbingOK = true
	local plumbingError = nil
	if generateAutoPlumbing then
		plumbingOK, plumbingError = generateAutoPlumbing()
	end
	if State.destroyed or State.previewEpoch ~= previewEpoch then
		return false, "Preview was cancelled because its source/settings changed."
	end
	-- generateAutoPlumbing resets the effective arrays transactionally. Rebind
	-- the saved preview records to those copied entries so the later identity
	-- guard detects real edits rather than the intentional reset itself.
	for index = 1, savedPlacementCount do
		local preview = State.authoredPlacementPreviews[index]
		local effectiveEntry = AuthoredPlumbing[index]
		if preview and effectiveEntry then
			preview.entry = effectiveEntry
			preview.entrySignature = entrySignature(effectiveEntry)
		end
	end
	for index = savedPlacementCount + 1, #AuthoredPlumbing do
		local entry = AuthoredPlumbing[index]
		local preview = createPreview(index, entry, folder)
		preview.kind = "AutoPlumbing"
		if preview.model then
			preview.model.Name = string.format("AutoPipe_%03d_%s", index, entry.Name)
		end
		table.insert(State.authoredPlacementPreviews, preview)
		if index % Config.PreviewRenderYieldEvery == 0 then
			RunService.Heartbeat:Wait()
			if State.destroyed or State.previewEpoch ~= previewEpoch then
				return false, "Preview was cancelled because its source/settings changed."
			end
		end
	end
	createAuthoredLinkPreviews(folder)
	createConnectionPreviews(folder)
	local totalConnectionPreviews = #State.authoredLinkPreviews + #State.connectionPreviews
	if totalConnectionPreviews > State.previewConnectionLinesUsed then
		log(
			"Preview validated all %d connection(s); visual lines are capped at %d for performance",
			totalConnectionPreviews,
			State.previewConnectionLinesUsed
		)
	end

	if #State.previews == 0 and #State.authoredPlacementPreviews == 0 then
		log("Blueprint is empty")
		return false
	end
	local valid = validatePreviews()
	if not plumbingOK then
		State.validated = false
		log("Auto-Plumb failed: %s", tostring(plumbingError))
		notify("Auto-Plumb needs attention", tostring(plumbingError), 10)
		return false
	end
	return valid
end

local function previewAndValidate()
	if State.previewInProgress then
		return false, "A blueprint preview is already being prepared."
	end
	State.previewInProgress = true
	local ok, result, detail = pcall(Runtime.previewAndValidateCore)
	State.previewInProgress = false
	State.activePreviewEpoch = nil
	if not ok then
		warn(PREFIX .. "preview error: " .. tostring(result))
		notify("Preview failed", tostring(result), 9)
		return false, tostring(result)
	end
	return result, detail
end

local REMOTE_SPECS = {
	[Place] = { Kind = "Place", Method = "FireServer" },
	[PlaceBind] = { Kind = "PlaceBind", Method = "InvokeServer" },
	[OptimizedPlaceBind] = { Kind = "OptimizedPlaceBind", Method = "InvokeServer" },
}

function Runtime.resolveCapturedTemplateByName(categoryName, modelName)
	if type(categoryName) ~= "string" or categoryName == "" then
		return nil, "category argument must be a non-empty string"
	elseif type(modelName) ~= "string" or modelName == "" then
		return nil, "model argument must be a non-empty string"
	end
	return resolveTemplate({ Category = categoryName, Name = modelName })
end

function Runtime.resolveCapturedTemplateInstance(value)
	if typeof(value) ~= "Instance" or not value:IsA("Model") then
		return nil, nil, nil, "template argument must be a Model"
	end
	local category = value.Parent
	if not category or category.Parent ~= Buildings then
		return nil, nil, nil, "template must be a direct child of a Buildings category"
	end
	local canonical, templateError = Runtime.resolveCapturedTemplateByName(category.Name, value.Name)
	if not canonical then
		return nil, nil, nil, templateError
	elseif canonical ~= value then
		return nil, nil, nil, "template argument is not the canonical Buildings model"
	end
	return canonical, category.Name, canonical.Name
end

function Runtime.decodeCapturedPlacement(captured)
	if type(captured) ~= "table" or type(captured.Args) ~= "table" then
		return nil, "capture is missing its packed argument table"
	end
	local spec = REMOTE_SPECS[captured.Remote]
	if not spec
		or captured.Kind ~= spec.Kind
		or captured.Method ~= spec.Method
	then
		return nil, "capture remote, method, and kind do not agree"
	end
	local args = captured.Args
	if type(args.n) ~= "number" or args.n < 0 or args.n % 1 ~= 0 then
		return nil, "capture argument count is invalid"
	end

	local template
	local categoryName
	local modelName
	local targetCFrame
	local autoBuy = false
	local autoConnect = false
	local templateError
	if captured.Kind == "Place" then
		if args.n ~= 4 or args[3] ~= nil or type(args[4]) ~= "boolean" then
			return nil, "Place must be (template, CFrame, nil, autobuy)"
		elseif typeof(args[2]) ~= "CFrame" then
			return nil, "Place argument #2 must be a CFrame"
		end
		template, categoryName, modelName, templateError = Runtime.resolveCapturedTemplateInstance(args[1])
		targetCFrame = args[2]
		autoBuy = args[4]
	elseif captured.Kind == "PlaceBind" then
		if args.n ~= 6
			or args[3] ~= nil
			or type(args[4]) ~= "boolean"
			or args[5] ~= true
			or type(args[6]) ~= "boolean"
		then
			return nil, "PlaceBind must be (template, CFrame, nil, autobuy, true, autoConnect)"
		elseif typeof(args[2]) ~= "CFrame" then
			return nil, "PlaceBind argument #2 must be a CFrame"
		end
		template, categoryName, modelName, templateError = Runtime.resolveCapturedTemplateInstance(args[1])
		targetCFrame = args[2]
		autoBuy = args[4]
		autoConnect = args[6]
	elseif captured.Kind == "OptimizedPlaceBind" then
		if args.n ~= 5
			or type(args[1]) ~= "string"
			or type(args[2]) ~= "string"
			or typeof(args[3]) ~= "CFrame"
			or type(args[4]) ~= "boolean"
			or args[5] ~= true
		then
			return nil, "OptimizedPlaceBind must be (category, model, CFrame, autoConnect, true)"
		end
		categoryName = args[1]
		modelName = args[2]
		template, templateError = Runtime.resolveCapturedTemplateByName(categoryName, modelName)
		targetCFrame = args[3]
		autoConnect = args[4]
	else
		return nil, "unsupported captured remote kind " .. tostring(captured.Kind)
	end
	if not template then
		return nil, "captured template is unsupported: " .. tostring(templateError)
	end

	return {
		Remote = captured.Remote,
		Method = captured.Method,
		Kind = captured.Kind,
		Args = args,
		Generation = captured.Generation,
		PlacedSnapshot = type(captured.PlacedSnapshot) == "table" and captured.PlacedSnapshot or {},
		ArmPlacedSnapshot = type(captured.ArmPlacedSnapshot) == "table"
			and captured.ArmPlacedSnapshot
			or nil,
		Template = template,
		Category = categoryName,
		Name = modelName,
		TargetCFrame = targetCFrame,
		AutoBuy = autoBuy,
		AutoConnect = autoConnect,
	}
end

local function capturedSample(captured)
	return captured.Category, captured.Name
end

local function capturedPlacementCFrame(captured)
	return captured.TargetCFrame
end

local function scanBlueprintCandidates()
	local candidates = {}
	if not State.blueprintLoaded or State.blueprintDirty then
		return candidates
	end
	for index, entry in ipairs(Blueprint) do
		table.insert(candidates, { entry = entry, kind = "Machine", index = index })
	end
	for index, entry in ipairs(State.sourceAuthoredPlumbing) do
		table.insert(candidates, { entry = entry, kind = "Plumbing", index = index })
	end
	return candidates
end

local function scannedBlueprintAnchor()
	local candidates = scanBlueprintCandidates()
	return candidates[1] and candidates[1].entry or nil
end

function Runtime.captureIsCurrent(captured)
	return type(captured) == "table" and captured.Generation == State.captureGeneration
end

local function capturedAnchorCandidate(category, name, targetCFrame)
	local actualLook = horizontalUnit(targetCFrame.LookVector, Vector2.new(0, 1))
	local matches = {}
	local phaseMismatch
	for _, candidate in ipairs(scanBlueprintCandidates()) do
		local entry = candidate.entry
		if tostring(entry.Category) == category and tostring(entry.Name) == name then
			local expectedRotation = ((tonumber(entry.Rotation) or 0) + State.layoutRotation) % 360
			local expectedLook = CFrame.Angles(0, math.rad(expectedRotation), 0).LookVector
			local expectedHorizontal = horizontalUnit(expectedLook, Vector2.new(0, 1))
			if actualLook:Dot(expectedHorizontal) >= math.cos(math.rad(Config.VerifyRotationTolerance)) then
				local rotatedX, rotatedZ = rotateBlueprintOffset(
					tonumber(entry.X) or 0,
					tonumber(entry.Z) or 0,
					State.layoutRotation
				)
				local rawOriginX = targetCFrame.X - rotatedX
				local rawOriginZ = targetCFrame.Z - rotatedZ
				local originX = snapBlueprintOriginCoordinate(rawOriginX)
				local originZ = snapBlueprintOriginCoordinate(rawOriginZ)
				local phaseError = math.max(math.abs(rawOriginX - originX), math.abs(rawOriginZ - originZ))
				if phaseError > 0.001 then
					if not phaseMismatch or phaseError < phaseMismatch.error then
						phaseMismatch = {
							error = phaseError,
							rawOriginX = rawOriginX,
							rawOriginZ = rawOriginZ,
							originX = originX,
							originZ = originZ,
						}
					end
				else
					candidate.expectedRotation = expectedRotation
					candidate.originX = originX
					candidate.originZ = originZ
					candidate.expectedTargetCFrame = CFrame.new(
						originX + rotatedX,
						targetCFrame.Y,
						originZ + rotatedZ
					) * CFrame.Angles(0, math.rad(expectedRotation), 0)
					candidate.score = math.abs(originX - State.originX) + math.abs(originZ - State.originZ)
					table.insert(matches, candidate)
				end
			end
		end
	end
	table.sort(matches, function(first, second)
		if math.abs(first.score - second.score) > 0.0001 then
			return first.score < second.score
		elseif first.kind ~= second.kind then
			return first.kind == "Machine"
		end
		return first.index < second.index
	end)
	if #matches == 1 then
		return matches[1]
	elseif #matches > 1 then
		local currentOriginMatches = {}
		for _, candidate in ipairs(matches) do
			if candidate.score <= 0.001 then
				table.insert(currentOriginMatches, candidate)
			end
		end
		if #currentOriginMatches == 1 then
			return currentOriginMatches[1]
		end
		return nil, string.format(
			"%d %s/%s entries match this rotation, so Scan cannot safely decide which relative offset should calibrate Base X/Z.",
			#matches,
			category,
			name
		)
	elseif phaseMismatch then
		return nil, string.format(
			"The detected %s/%s would produce off-grid blueprint origin X %.4f, Z %.4f; the machine origin must be even/even (nearest X %.0f, Z %.0f).",
			category,
			name,
			phaseMismatch.rawOriginX,
			phaseMismatch.rawOriginZ,
			phaseMismatch.originX,
			phaseMismatch.originZ
		)
	end
	return nil
end

function Runtime.matchScannedPlacement(
	preview,
	existing,
	placedSnapshot,
	exactIdentityOnly,
	requiredUnchangedSnapshot
)
	local expectedID = preview.template:GetAttribute("ID")
	local expectedCategory = preview.template.Parent.Name
	local exactMatches = {}
	local geometryFallbacks = {}
	local closestMismatch
	local closestDistanceSquared = math.huge

	for _, placed in ipairs(existing) do
		local unchangedFromFreshnessBaseline = Runtime.placedModelUnchangedFromSnapshot(
			placed,
			placedSnapshot and placedSnapshot[placed.model]
		)
		local requiredSnapshot = requiredUnchangedSnapshot
			and requiredUnchangedSnapshot[placed.model]
		local matchesRequiredSnapshot = requiredUnchangedSnapshot == nil
			or (requiredSnapshot ~= nil
				and Runtime.placedModelUnchangedFromSnapshot(placed, requiredSnapshot))
		if not unchangedFromFreshnessBaseline and matchesRequiredSnapshot then
			local geometryIssue, metrics = Runtime.classifyPlacementGeometry(
				preview,
				placed.base,
				Config.ScanVerifyHeightTolerance
			)
			if geometryIssue ~= "outside_radius" then
				local mismatch
				if geometryIssue == "position" then
					mismatch = string.format(
						"fresh %s appeared off target (Base delta X %.3f, Z %.3f)",
						placed.name,
						metrics.deltaX,
						metrics.deltaZ
					)
				elseif geometryIssue == "height" then
					mismatch = string.format(
						"fresh %s had unexpected Base top height (delta Y %.3f)",
						placed.name,
						metrics.topDeltaY
					)
				elseif geometryIssue == "rotation" then
					mismatch = "fresh " .. tostring(placed.name) .. " appeared with the wrong rotation"
				elseif geometryIssue == "footprint" then
					mismatch = string.format(
						"fresh %s had Base %.2fx%.2f instead of %.2fx%.2f",
						placed.name,
						placed.base.Size.X,
						placed.base.Size.Z,
						preview.base.Size.X,
						preview.base.Size.Z
					)
				elseif geometryIssue == nil then
					local idContradicts = expectedID ~= nil
						and placed.id ~= nil
						and tostring(expectedID) ~= tostring(placed.id)
					local categoryContradicts = placed.category ~= nil
						and placed.category ~= expectedCategory
					local attributeNameContradicts = placed.attributeName ~= nil
						and placed.attributeName ~= preview.template.Name
					local modelNameIsKnownOther = false
					if placed.modelName ~= preview.template.Name then
						for _, categoryFolder in ipairs(Buildings:GetChildren()) do
							local namedTemplate = categoryFolder:FindFirstChild(placed.modelName)
							if namedTemplate and namedTemplate:IsA("Model") then
								modelNameIsKnownOther = true
								break
							end
						end
					end
					if idContradicts
						or categoryContradicts
						or attributeNameContradicts
						or modelNameIsKnownOther
					then
						mismatch = string.format(
							"wrong fresh model appeared: expected %s/%s (ID %s), got %s/%s (ID %s)",
							expectedCategory,
							preview.template.Name,
							tostring(expectedID),
							tostring(placed.category or "?"),
							tostring(placed.name),
							tostring(placed.id)
						)
					elseif Runtime.placedModelMatchesTemplate(placed, preview.template) then
						table.insert(exactMatches, placed)
					elseif not exactIdentityOnly then
						table.insert(geometryFallbacks, placed)
					end
				end
				if mismatch and metrics and metrics.distanceSquared < closestDistanceSquared then
					closestDistanceSquared = metrics.distanceSquared
					closestMismatch = mismatch
				end
			end
		end
	end

	if #exactMatches == 1 then
		return exactMatches[1].model, exactIdentityOnly
			and "Accepted the exact model that became fresh after Scan was armed and was already present immediately before its placement remote ran."
			or nil
	elseif #exactMatches > 1 then
		return nil, nil, string.format(
			"%d fresh objects shared the exact expected catalog identity and Base geometry, so Scan refused to guess which one was placed",
			#exactMatches
		)
	elseif not exactIdentityOnly and #geometryFallbacks == 1 then
		return geometryFallbacks[1].model,
			"The server changed or omitted model identity metadata; accepted the one fresh object with the exact Base pose and footprint."
	elseif not exactIdentityOnly and #geometryFallbacks > 1 then
		closestMismatch = string.format(
			"%d fresh objects shared the exact expected Base geometry, so Scan refused to guess which one was placed",
			#geometryFallbacks
		)
	end
	return nil, nil, closestMismatch
end

local function verifyScannedPlacement(entry, targetCFrame, captured)
	if not Runtime.captureIsCurrent(captured) then
		return nil, "The scanned placement was superseded by a newer Scan or load."
	end
	local template, templateError = resolveTemplate(entry)
	if not template then
		return nil, "The detected placement is not a supported template: " .. tostring(templateError)
	end
	local probe = template:Clone()
	local pivotOK, pivotError = pcall(function()
		probe:PivotTo(targetCFrame)
	end)
	if not pivotOK then
		probe:Destroy()
		return nil, "Could not inspect the detected placement: " .. tostring(pivotError)
	end
	local probeBase = probe:FindFirstChild("Base")
	if not probeBase or not probeBase:IsA("BasePart") then
		probe:Destroy()
		return nil, "The detected template has no direct Base."
	end
	local probePreview = { template = template, base = probeBase }
	local matchedModel
	local matchNote
	local closestMismatch
	local startedAt = os.clock()
	local deadline = startedAt + Config.ScanVerifyTimeout
	local refreshSchedule = { startedAt + 0.35, startedAt + 1.5 }
	local refreshIndex = 1
	local optimisticCandidate
	local optimisticFirstSeenAt
	local optimisticPollCount = 0
	local optimisticContradictionSeen = false

	local function tryCurrentPlot()
		local existing = collectPlacedMachines()
		local currentMatch
		local currentNote
		local currentMismatch
		currentMatch, currentNote, currentMismatch = Runtime.matchScannedPlacement(
			probePreview,
			existing,
			captured.PlacedSnapshot
		)
		if currentMismatch then
			-- A contradictory model appearing after the remote is stronger evidence
			-- than an optimistic pre-call candidate. Never let the narrow fallback
			-- hide that conflict on a later poll.
			optimisticContradictionSeen = true
		end
		-- Industrialist can optimistically parent the just-clicked model into the
		-- plot before its placement remote runs. That exact instance is therefore
		-- excluded by the call-time baseline even though it is the real placement.
		-- The second pass is deliberately narrow: it must be fresh since Scan was
		-- armed, retain exact catalog identity/pose/footprint, and remain unchanged
		-- across every recorded field in the immediate pre-call snapshot.
		if not currentMatch
			and not currentMismatch
			and not optimisticContradictionSeen
			and type(captured.ArmPlacedSnapshot) == "table"
		then
			local optimisticMatch
			local optimisticNote
			local optimisticMismatch
			optimisticMatch, optimisticNote, optimisticMismatch = Runtime.matchScannedPlacement(
				probePreview,
				existing,
				captured.ArmPlacedSnapshot,
				true,
				captured.PlacedSnapshot
			)
			if optimisticMatch then
				if optimisticCandidate ~= optimisticMatch then
					optimisticCandidate = optimisticMatch
					optimisticFirstSeenAt = os.clock()
					optimisticPollCount = 1
				else
					optimisticPollCount += 1
				end
				-- InvokeServer/FireServer success is not enough: a client-owned preview
				-- can remain briefly before a rejection replicates back. Require the same
				-- exact snapshot-stable instance across multiple polls and a settle window.
				if optimisticPollCount >= 2
					and os.clock() - optimisticFirstSeenAt >= Config.ScanOptimisticSettleTime
				then
					currentMatch = optimisticMatch
					currentNote = optimisticNote or currentNote
				end
			else
				optimisticCandidate = nil
				optimisticFirstSeenAt = nil
				optimisticPollCount = 0
			end
			currentMismatch = currentMismatch or optimisticMismatch
			if optimisticMismatch then
				optimisticContradictionSeen = true
			end
		elseif not currentMatch then
			optimisticCandidate = nil
			optimisticFirstSeenAt = nil
			optimisticPollCount = 0
		end
		matchedModel = currentMatch
		matchNote = currentNote or matchNote
		closestMismatch = currentMismatch or closestMismatch
	end

	repeat
		if not Runtime.captureIsCurrent(captured) then
			probe:Destroy()
			return nil, "The scanned placement was superseded by a newer Scan or load."
		end
		tryCurrentPlot()
		local now = os.clock()
		if not matchedModel
			and refreshIndex <= #refreshSchedule
			and now >= refreshSchedule[refreshIndex]
		then
			Runtime.rescanPlacedRegistry()
			refreshIndex += 1
			tryCurrentPlot()
		end
		if not matchedModel then
			task.wait(0.05)
		end
	until matchedModel or os.clock() >= deadline
	if not matchedModel then
		-- One final authoritative cache repair closes a missed DescendantAdded or
		-- late direct-Base replication at the timeout boundary.
		Runtime.rescanPlacedRegistry()
		tryCurrentPlot()
	end
	probe:Destroy()
	if matchedModel and matchNote then
		log("Scan identity fallback: %s", matchNote)
	end
	if not matchedModel then
		if closestMismatch then
			return nil, string.format(
				"The detected %s/%s reached the plot but failed verification: %s",
				entry.Category,
				entry.Name,
				closestMismatch
			)
		end
		return nil, string.format(
			"The detected %s/%s did not appear in the plot within %.1f seconds; its placement may have been rejected.",
			entry.Category,
			entry.Name,
			Config.ScanVerifyTimeout
		)
	end
	return matchedModel
end

local function calibrateCapturedScan(captured)
	if not Runtime.captureIsCurrent(captured) then
		return false, "The scanned placement was superseded by a newer Scan or load.", "superseded"
	end
	local category, name = capturedSample(captured)
	local targetCFrame = capturedPlacementCFrame(captured)
	if not targetCFrame then
		return false,
			"The placement packet did not contain a CFrame. Press Scan and try a normal placement again.",
			"missing position"
	end
	local detectedEntry = { Category = category, Name = name }
	local anchorCandidate, nonCalibratingReason = capturedAnchorCandidate(category, name, targetCFrame)
	if anchorCandidate then
		local anchor = anchorCandidate.entry
		local matchedModel, verifyError = verifyScannedPlacement(
			anchor,
			-- The packet's actual CFrame is authoritative for proving what the
			-- player just placed. Anchor matching calibrates only X/Z; it must not
			-- reintroduce a hardcoded Y or rounded pose into verification.
			targetCFrame,
			captured
		)
		if not matchedModel then
			if not Runtime.captureIsCurrent(captured) then
				return false, verifyError, "superseded"
			end
			return false, verifyError, "placement was not verified"
		end
		if not Runtime.captureIsCurrent(captured) then
			return false, "The scanned placement was superseded by a newer Scan or load.", "superseded"
		end
		local originX, originZ = setBlueprintOrigin(anchorCandidate.originX, anchorCandidate.originZ)
		syncLayoutControls()
		State.scanComplete = true
		State.scanMode = "BlueprintEntry"
		State.scanPlacedModel = matchedModel
		State.scanMatchedEntry = {
			Kind = anchorCandidate.kind,
			Index = anchorCandidate.index,
			Category = anchor.Category,
			Name = anchor.Name,
		}
		return true, string.format(
			"Matched %s #%d %s/%s. Origin set to X %.0f, Z %.0f with layout rotation %d°.",
			anchorCandidate.kind,
			anchorCandidate.index,
			anchor.Category,
			anchor.Name,
			originX,
			originZ,
			State.layoutRotation
		)
	end

	-- A valid placement that is not part of the current blueprint is still a
	-- useful packet sample. This is what lets a rusty pipe, good pipe, pump, or
	-- any other catalog template teach the placer how this server is placing
	-- objects without silently moving the user's configured blueprint origin.
	local matchedModel, verifyError = verifyScannedPlacement(detectedEntry, targetCFrame, captured)
	if not matchedModel then
		if not Runtime.captureIsCurrent(captured) then
			return false, verifyError, "superseded"
		end
		return false, verifyError, "placement was not verified"
	end
	if not Runtime.captureIsCurrent(captured) then
		return false, "The scanned placement was superseded by a newer Scan or load.", "superseded"
	end
	State.scanComplete = true
	State.scanMode = "PacketOnly"
	State.scanMatchedEntry = nil
	State.scanPlacedModel = matchedModel
	return true, string.format(
		"Learned a verified placement packet from %s/%s. %s Base X/Z stayed %.0f, %.0f.",
		category,
		name,
		nonCalibratingReason
			or "No unique on-grid blueprint entry at this rotation was found.",
		State.originX,
		State.originZ
	)
end

local function captureFallbackSnapshot()
	if not State.captured or State.scanComplete ~= true then
		return nil
	end
	local matched
	if type(State.scanMatchedEntry) == "table" then
		matched = {
			Kind = State.scanMatchedEntry.Kind,
			Index = State.scanMatchedEntry.Index,
			Category = State.scanMatchedEntry.Category,
			Name = State.scanMatchedEntry.Name,
		}
	end
	return {
		captured = State.captured,
		scanComplete = true,
		scanMode = State.scanMode,
		scanMatchedEntry = matched,
		scanPlacedModel = State.scanPlacedModel,
		captureRemembered = State.captureRemembered == true,
	}
end

local function restoreCaptureFallback(keepForRetry)
	local fallback = State.captureFallback
	if not fallback or type(fallback.captured) ~= "table" then
		State.captureFallback = nil
		return false
	end
	fallback.captured.Generation = State.captureGeneration
	State.captured = fallback.captured
	State.scanComplete = fallback.scanComplete == true
	State.scanMode = tostring(fallback.scanMode or "PacketOnly")
	State.scanMatchedEntry = fallback.scanMatchedEntry
	State.scanPlacedModel = fallback.scanPlacedModel
	State.captureRemembered = fallback.captureRemembered == true
	if not keepForRetry then
		State.captureFallback = nil
	end
	return true
end

local function reportCapture(captured)
	if not Runtime.captureIsCurrent(captured) then
		return
	end
	local category, name = capturedSample(captured)
	if updateBlueprintParagraph then
		updateBlueprintParagraph("Scan captured; verifying the placed entry in the plot...")
	end
	local calibrated, message, shortReason = calibrateCapturedScan(captured)
	if shortReason == "superseded" or not Runtime.captureIsCurrent(captured) then
		return
	end
	dumpArgs("captured arguments", captured.Args)
	if not calibrated then
		State.scanComplete = false
		State.scanMode = "None"
		State.scanMatchedEntry = nil
		State.scanPlacedModel = nil
		if shortReason == "waiting for blueprint" then
			log("Scan captured from %s/%s; paste a blueprint to calibrate it", category, name)
			if updateBlueprintParagraph then
				updateBlueprintParagraph("Scan captured; paste a blueprint to calibrate it.")
			end
			notify("Scan captured", message, 9)
			if restoreCaptureFallback(false) then
				if updateBlueprintParagraph then
					updateBlueprintParagraph("Previous verified Scan restored.")
				end
			end
		else
			log("Scan rejected: %s", message)
			if restoreCaptureFallback(false) then
				if updateBlueprintParagraph then
					updateBlueprintParagraph("Previous verified Scan restored after the rejected placement.")
				end
				notify("Scan rejected", message .. " Previous verified Scan restored.", 10)
			else
				State.captured = nil
				State.captureRemembered = false
				State.scanPlacedSnapshot = Runtime.authoritativePlacedSnapshot()
				State.captureArmed = true
				if updateBlueprintParagraph then
					updateBlueprintParagraph(
						"SCAN STILL ARMED: that placement was not verified. Place another catalog item normally."
					)
				end
				notify(
					"Scan still armed",
					message .. " Try another catalog item in clear space; you do not need to press Scan again.",
					10
				)
			end
		end
		return
	end
	State.captureFallback = nil
	State.captureRemembered = false
	local persistenceDetail = "Session-only: persistent placement capture is unavailable."
	if type(Runtime.rememberCaptureProfile) == "function" then
		local remembered, rememberResult = Runtime.rememberCaptureProfile(captured)
		if not remembered then
			persistenceDetail = "Session-only: " .. tostring(rememberResult)
			log("Placement profile stayed session-only: %s", tostring(rememberResult))
		else
			persistenceDetail = "Remembered for later sessions at " .. tostring(rememberResult) .. "."
		end
	end
	if not Runtime.captureIsCurrent(captured) or State.destroyed then
		return
	end
	clearPreview()
	log(
		"Scan complete: captured %s:%s from %s/%s. %s",
		captured.Remote.Name,
		captured.Method,
		category,
		name,
		message
	)
	if updateBlueprintParagraph then
		updateBlueprintParagraph("Scan complete. " .. message .. " " .. persistenceDetail)
	end
	notify(
		"Scan complete",
		captured.Remote.Name .. ":" .. captured.Method .. ". " .. message .. " " .. persistenceDetail,
		7
	)
end

local function reportRuntimeWorkError(kind, errorValue, captured)
	if captured and not Runtime.captureIsCurrent(captured) then
		return
	end
	local message = tostring(errorValue)
	warn(PREFIX .. kind .. " processing error: " .. message)
	State.scanComplete = false
	State.scanMode = "None"
	State.scanMatchedEntry = nil
	State.scanPlacedModel = nil
	restoreCaptureFallback(false)
	if updateBlueprintParagraph then
		updateBlueprintParagraph("Scan processing failed: " .. message)
	end
	notify(
		"Scan failed",
		"The placement was detected, but processing failed: " .. message,
		10
	)
end

local function rearmAfterMalformedCapture(captured, errorValue)
	if not Runtime.captureIsCurrent(captured) then
		return
	end
	local message = tostring(errorValue)
	State.captured = nil
	State.scanComplete = false
	State.scanMode = "None"
	State.scanMatchedEntry = nil
	State.scanPlacedModel = nil
	State.scanPlacedSnapshot = Runtime.authoritativePlacedSnapshot()
	State.captureArmed = true
	restoreCaptureFallback(true)
	warn(PREFIX .. "ignored malformed placement packet: " .. message)
	if updateBlueprintParagraph then
		updateBlueprintParagraph("SCAN STILL ARMED: ignored a malformed placement call. Place one catalog item normally.")
	end
	notify(
		"Scan still armed",
		"Ignored a malformed placement call: " .. message,
		9
	)
end

local function processPendingRuntimeWork()
	if State.pendingCapture and not State.captureProcessing then
		local rawCapture = State.pendingCapture
		State.pendingCapture = nil
		if not Runtime.captureIsCurrent(rawCapture) then
			return
		end
		State.captureProcessing = true
		local decodeOK, captured, decodeError = pcall(Runtime.decodeCapturedPlacement, rawCapture)
		if not decodeOK then
			decodeError = captured
			captured = nil
		end
		if not captured then
			State.captureProcessing = false
			rearmAfterMalformedCapture(rawCapture, decodeError)
			return
		end
		State.captured = captured
		local ok, errorValue = pcall(reportCapture, captured)
		State.captureProcessing = false
		if not ok then
			reportRuntimeWorkError("scan", errorValue, captured)
		end
	end
end

local function ensureRuntimePump()
	local connection = State.runtimePumpConnection
	if connection and connection.Connected then
		return true
	end
	State.runtimePumpConnection = RunService.Heartbeat:Connect(processPendingRuntimeWork)
	return true
end

function Runtime.reportCapturedPlacementRejection(sourceState, captured, detail)
	if sourceState ~= State
		or State.destroyed
		or type(captured) ~= "table"
		or captured.Generation ~= State.captureGeneration
		or not State.captureArmed
	then
		return
	end
	-- A rejected placement can leave its optimistic client model in Plots for a
	-- moment. Repair and refresh the baseline before accepting the next retry so
	-- that stale object cannot be misclassified as the next successful placement.
	State.scanPlacedSnapshot = Runtime.authoritativePlacedSnapshot()
	local message = "Industrialist rejected or errored that placement; Scan is still armed. Place one catalog item normally."
	warn(PREFIX .. message .. " Server detail: " .. tostring(detail))
	if updateBlueprintParagraph then
		updateBlueprintParagraph("SCAN STILL ARMED: " .. message)
	end
	notify("Scan still armed", message, 9)
end

function Runtime.disableCaptureController(controller)
	if type(controller) ~= "table" then
		return
	end
	-- A hookmetamethod closure cannot be removed. Clearing the controller makes
	-- an older closure a transparent pass-through; a versioned outer hook can
	-- then be installed without both generations capturing the same call.
	controller.Disabled = true
	controller.State = nil
	controller.RemoteSpecs = nil
	controller.ConnectionRemotes = nil
	controller.RecordConnection = nil
	controller.BeginConnectionWatch = nil
	controller.StopConnectionWatch = nil
	controller.RecordVerifiedConnection = nil
	controller.SnapshotPlacedModels = nil
	controller.ReportPlacementRejected = nil
end

local function installCaptureHook()
	if State.hookInstalled then
		return true
	end
	if type(hookmetamethod) ~= "function" or type(getnamecallmethod) ~= "function" then
		return false, "executor does not expose hookmetamethod/getnamecallmethod"
	end

	local sharedEnvironment = type(getgenv) == "function" and getgenv() or _G
	local controller = sharedEnvironment.__IndustrialistBlueprintCaptureController
	if type(controller) == "table"
		and controller.Installed == true
		and controller.Version == Runtime.CaptureHookVersion
	then
		controller.Disabled = false
		controller.State = State
		controller.RemoteSpecs = REMOTE_SPECS
		controller.ConnectionRemotes = { [PipeBind] = "Pipe", [WireBind] = "Wire" }
		controller.RecordConnection = Runtime.rememberKnownConnection
		controller.BeginConnectionWatch = Runtime.beginConnectionWatch
		controller.StopConnectionWatch = Runtime.stopConnectionWatch
		controller.RecordVerifiedConnection = Runtime.recordVerifiedManualConnection
		controller.SnapshotPlacedModels = Runtime.authoritativePlacedSnapshot
		controller.ReportPlacementRejected = Runtime.reportCapturedPlacementRejection
		State.hookInstalled = true
		return true
	elseif type(controller) == "table" and controller.Installed == true then
		Runtime.disableCaptureController(controller)
		controller = nil
	end

	local wrap = type(newcclosure) == "function" and newcclosure or function(callback)
		return callback
	end
	controller = {
		Installed = false,
		Disabled = false,
		Version = Runtime.CaptureHookVersion,
		State = State,
		RemoteSpecs = REMOTE_SPECS,
		ConnectionRemotes = { [PipeBind] = "Pipe", [WireBind] = "Wire" },
		RecordConnection = Runtime.rememberKnownConnection,
		BeginConnectionWatch = Runtime.beginConnectionWatch,
		StopConnectionWatch = Runtime.stopConnectionWatch,
		RecordVerifiedConnection = Runtime.recordVerifiedManualConnection,
		SnapshotPlacedModels = Runtime.authoritativePlacedSnapshot,
		ReportPlacementRejected = Runtime.reportCapturedPlacementRejection,
	}
	sharedEnvironment.__IndustrialistBlueprintCaptureController = controller
	local hookOK, hookError = pcall(function()
		local oldNamecall
		oldNamecall = hookmetamethod(game, "__namecall", wrap(function(remote, ...)
			local activeState = controller.State
			local connectionKind = activeState
				and not activeState.replaying
				and controller.ConnectionRemotes
				and controller.ConnectionRemotes[remote]
			if connectionKind and getnamecallmethod() == "InvokeServer" then
				local arguments = table.pack(...)
				-- Pin this call to the controller generation that opened its watch.
				-- Reinjection can replace controller.State/callbacks while InvokeServer
				-- yields; an old watch must never mutate the new runtime's registry.
				local ownerState = activeState
				local ownerBeginWatch = controller.BeginConnectionWatch
				local ownerStopWatch = controller.StopConnectionWatch
				local ownerRecordVerified = controller.RecordVerifiedConnection
				local ownerRecordConnection = controller.RecordConnection
				local watch
				if type(ownerBeginWatch) == "function" then
					local watchOK, createdWatch = pcall(ownerBeginWatch, connectionKind)
					if watchOK then
						watch = createdWatch
					end
				end
				local results = table.pack(pcall(oldNamecall, remote, ...))
				local ownerStillCurrent = controller.Disabled ~= true
					and controller.State == ownerState
				local function stopOwnerWatch()
					if watch and type(ownerStopWatch) == "function" then
						pcall(ownerStopWatch, watch)
					end
				end
				if not results[1] then
					-- A post-send client error is uncertain. Keep the before-call watch
					-- alive long enough to attribute an exact replicated segment/cap pair;
					-- the original game error is still rethrown to its caller.
					if watch and ownerStillCurrent and type(ownerRecordVerified) == "function" then
						task.spawn(
							ownerRecordVerified,
							watch,
							connectionKind,
							arguments[1],
							arguments[2]
						)
					else
						stopOwnerWatch()
					end
					error(results[2], 0)
				end
				if results[2] ~= false then
					if watch and ownerStillCurrent and type(ownerRecordVerified) == "function" then
						task.spawn(
							ownerRecordVerified,
							watch,
							connectionKind,
							arguments[1],
							arguments[2]
						)
					elseif ownerStillCurrent and type(ownerRecordConnection) == "function" then
						task.defer(ownerRecordConnection, connectionKind, arguments[1], arguments[2])
					else
						stopOwnerWatch()
					end
				else
					stopOwnerWatch()
				end
				return table.unpack(results, 2, results.n)
			end
			if activeState
				and activeState.captureArmed
				and not activeState.captureInFlight
				and not activeState.replaying
			then
				local specs = controller.RemoteSpecs
				local spec = specs and specs[remote]
				if spec then
					local method = getnamecallmethod()
					if method == spec.Method then
						local captureGeneration = activeState.captureGeneration
						activeState.captureInFlight = true
						activeState.captureInFlightGeneration = captureGeneration
						-- Take the exclusion baseline immediately before the real call.
						-- Scan may have been armed for minutes, so its button-time snapshot
						-- must not classify unrelated intervening objects as this placement.
						local armPlacedSnapshot = activeState.scanPlacedSnapshot
						local placedSnapshot = armPlacedSnapshot
						if type(controller.SnapshotPlacedModels) == "function" then
							local snapshotOK, freshSnapshot = pcall(controller.SnapshotPlacedModels)
							if snapshotOK and type(freshSnapshot) == "table" then
								placedSnapshot = freshSnapshot
							end
						end
						local captured = {
							Remote = remote,
							Method = method,
							Kind = spec.Kind,
							Args = table.pack(...),
							Generation = captureGeneration,
							PlacedSnapshot = placedSnapshot,
							ArmPlacedSnapshot = armPlacedSnapshot,
						}
						-- InvokeServer can yield for longer than the verification window.
						-- Call the original exactly once, then verify either a normal return
						-- or an uncertain post-send error while preserving every return/error.
						local results = table.pack(pcall(oldNamecall, remote, ...))
						local ownsFlight = activeState.captureInFlight == true
							and activeState.captureInFlightGeneration == captureGeneration
						if ownsFlight then
							activeState.captureInFlight = false
							activeState.captureInFlightGeneration = nil
						end
						if not results[1] then
							if ownsFlight
								and controller.State == activeState
								and activeState.captureGeneration == captureGeneration
							then
								-- Verify against the exact pre-call plot baseline even though the
								-- client saw an error. If the server effect is absent, normal Scan
								-- verification rearms after its bounded timeout.
								activeState.scanPlacedSnapshot = placedSnapshot
								activeState.captureArmed = false
								activeState.pendingCapture = captured
							end
							error(results[2], 0)
						end
						if results[2] ~= false
							and ownsFlight
							and controller.State == activeState
							and activeState.captureArmed
							and activeState.captureGeneration == captured.Generation
						then
							activeState.scanPlacedSnapshot = placedSnapshot
							activeState.captureArmed = false
							activeState.pendingCapture = captured
						elseif results[2] == false
							and ownsFlight
							and controller.State == activeState
							and activeState.captureGeneration == captureGeneration
							and type(controller.ReportPlacementRejected) == "function"
						then
							task.defer(
								controller.ReportPlacementRejected,
								activeState,
								captured,
								"server returned false"
							)
						end
						return table.unpack(results, 2, results.n)
					end
				end
			end
			return oldNamecall(remote, ...)
		end))
	end)
	if not hookOK then
		if sharedEnvironment.__IndustrialistBlueprintCaptureController == controller then
			sharedEnvironment.__IndustrialistBlueprintCaptureController = nil
		end
		return false, "capture hook failed: " .. tostring(hookError)
	end
	controller.Installed = true
	State.hookInstalled = true
	return true
end

local function captureNextPlacement()
	if State.destroyed then
		return false, "The script has been destroyed; execute it again to restart."
	elseif State.building then
		notify("Capture refused", "A blueprint build is currently running.", 6)
		return false
	elseif State.captureProcessing then
		notify("Scan is still verifying", "Wait for the current scanned placement to finish checking.", 6)
		return false
	elseif State.captureInFlight then
		notify("Scan placement is still sending", "Wait for the current Industrialist placement call to return, or press Cancel Scan.", 7)
		return false
	end
	ensureRuntimePump()
	local ok, hookError = installCaptureHook()
	if not ok then
		log("Capture unavailable: %s", hookError)
		notify("Capture unavailable", hookError, 8)
		return false
	end
	-- Re-arming an already armed Scan must not discard the verified packet that
	-- was saved by the first arm. Prefer a currently active verified packet, but
	-- retain the existing transaction backup when the active slot is empty.
	local fallback = captureFallbackSnapshot() or State.captureFallback
	State.captureGeneration = (tonumber(State.captureGeneration) or 0) + 1
	State.captureFallback = fallback
	State.captured = nil
	State.pendingCapture = nil
	State.captureInFlight = false
	State.captureInFlightGeneration = nil
	State.scanPlacedSnapshot = Runtime.authoritativePlacedSnapshot()
	State.captureArmed = true
	State.scanComplete = false
	State.scanMode = "None"
	State.scanMatchedEntry = nil
	State.scanPlacedModel = nil
	State.captureRemembered = false
	local anchor = scannedBlueprintAnchor()
	if updateBlueprintParagraph then
		updateBlueprintParagraph(anchor
			and "SCAN ARMED: place any building, pipe, or pump. A matching blueprint entry also calibrates Base X/Z."
			or "SCAN ARMED: place any building, pipe, or pump to learn the server placement packet.")
	end
	log("Scan armed: place exactly one catalog building, pipe, or pump normally")
	notify(
		"Any-placement scan armed",
		anchor
			and "Place anything from the build menu—even a rusty pipe. Matching blueprint items calibrate the origin; other items still teach the packet safely."
			or "Place anything from the build menu—even a rusty pipe. The verified packet can place every supported catalog template.",
		10
	)
	return true
end

function Runtime.invalidateCapturedPlacement()
	State.captureGeneration = (tonumber(State.captureGeneration) or 0) + 1
	State.captureArmed = false
	State.pendingCapture = nil
	State.captureInFlight = false
	State.captureInFlightGeneration = nil
	State.captured = nil
	State.captureFallback = nil
	State.captureRemembered = false
	State.scanComplete = false
	State.scanMode = "None"
	State.scanMatchedEntry = nil
	State.scanPlacedModel = nil
	State.scanPlacedSnapshot = {}
end

function Runtime.cancelPlacementScan(silent)
	local wasActive = State.captureArmed
		or State.captureProcessing
		or State.captureInFlight
		or State.pendingCapture ~= nil
	if not wasActive then
		return false, "No placement Scan is active."
	end
	State.captureGeneration = (tonumber(State.captureGeneration) or 0) + 1
	State.captureArmed = false
	State.pendingCapture = nil
	State.captureProcessing = false
	State.captureInFlight = false
	State.captureInFlightGeneration = nil
	local restored = restoreCaptureFallback(false)
	if not restored and not (State.captured and State.scanComplete) then
		Runtime.restoreCaptureProfile(true)
	end
	updateBlueprintParagraph(State.scanComplete
		and "Scan cancelled; previous remembered placement packet kept."
		or "Scan cancelled; press Scan when ready.")
	if not silent then
		notify(
			"Scan cancelled",
			State.scanComplete and "Previous verified placement packet kept." or "No previous packet was available.",
			6
		)
	end
	return true
end

local function canonicalPacket(captured, template, targetCFrame, enableAutoConnect)
	local source = captured.Args
	local autoConnect = enableAutoConnect == true
	if captured.Kind == "PlaceBind" then
		-- Dump bytecode: PlaceBind(template, cframe, nil, autobuy, true, autoConnect)
		return table.pack(
			template,
			targetCFrame,
			nil,
			source[4] == true,
			true,
			autoConnect
		)
	elseif captured.Kind == "OptimizedPlaceBind" then
		-- Dump bytecode: OptimizedPlaceBind(categoryName, modelName, cframe, autoConnect, true)
		return table.pack(
			template.Parent.Name,
			template.Name,
			targetCFrame,
			autoConnect,
			true
		)
	elseif captured.Kind == "Place" then
		-- Dump bytecode: Place(template, cframe, nil, autobuy)
		return table.pack(template, targetCFrame, nil, source[4] == true)
	end
	return nil, "unsupported captured remote kind " .. tostring(captured.Kind)
end

function Runtime.snapshotPlacedModels()
	local snapshot = {}
	for _, machine in ipairs(collectPlacedMachines()) do
		snapshot[machine.model] = {
			Base = machine.base,
			Parent = machine.model.Parent,
			BaseCFrame = machine.base.CFrame,
			BaseSize = machine.base.Size,
			ModelName = machine.model.Name,
			AttributeName = machine.attributeName,
			Category = machine.category,
			ID = machine.id,
		}
	end
	return snapshot
end

function Runtime.authoritativePlacedSnapshot()
	Runtime.rescanPlacedRegistry()
	return Runtime.snapshotPlacedModels()
end

function Runtime.spatialBucketBounds(rectangle)
	local worldX = Vector2.new(1, 0)
	local worldZ = Vector2.new(0, 1)
	local xRadius = projectedRadius(rectangle, worldX) + Config.EdgeEpsilon
	local zRadius = projectedRadius(rectangle, worldZ) + Config.EdgeEpsilon
	local size = Config.CollisionBucketSize
	return math.floor((rectangle.center.X - xRadius) / size),
		math.floor((rectangle.center.X + xRadius) / size),
		math.floor((rectangle.center.Y - zRadius) / size),
		math.floor((rectangle.center.Y + zRadius) / size)
end

function Runtime.insertSpatialRecord(index, record, rectangle)
	if not record.order then
		index.nextOrder += 1
		record.order = index.nextOrder
	end
	record.keys = record.keys or {}
	local minimumX, maximumX, minimumZ, maximumZ = Runtime.spatialBucketBounds(rectangle)
	for bucketX = minimumX, maximumX do
		local column = index.buckets[bucketX]
		if not column then
			column = {}
			index.buckets[bucketX] = column
		end
		for bucketZ = minimumZ, maximumZ do
			local bucket = column[bucketZ]
			if not bucket then
				bucket = {}
				column[bucketZ] = bucket
			end
			bucket[record] = true
			table.insert(record.keys, { bucketX, bucketZ })
		end
	end
end

function Runtime.removeSpatialRecord(index, record)
	for _, key in ipairs(record.keys or {}) do
		local bucketX = key[1]
		local bucketZ = key[2]
		local column = index.buckets[bucketX]
		local bucket = column and column[bucketZ]
		if bucket then
			bucket[record] = nil
			if not next(bucket) then
				column[bucketZ] = nil
			end
			if not next(column) then
				index.buckets[bucketX] = nil
			end
		end
	end
	record.keys = {}
end

function Runtime.querySpatialIndex(index, rectangle)
	local minimumX, maximumX, minimumZ, maximumZ = Runtime.spatialBucketBounds(rectangle)
	local seen = {}
	local records = {}
	for bucketX = minimumX, maximumX do
		local column = index.buckets[bucketX]
		if column then
			for bucketZ = minimumZ, maximumZ do
				for record in pairs(column[bucketZ] or {}) do
					if not seen[record] then
						seen[record] = true
						table.insert(records, record)
					end
				end
			end
		end
	end
	table.sort(records, function(first, second)
		return first.order < second.order
	end)
	local values = {}
	for _, record in ipairs(records) do
		table.insert(values, record.value)
	end
	return values
end

function Runtime.visitSpatialIndex(index, rectangle, visitor)
	-- Allocation-free broad-phase traversal for validity checks that only need
	-- to mark collisions. A record can span several buckets; once both previews
	-- are marked invalid the caller's cheap guard makes repeat visits inert.
	local minimumX, maximumX, minimumZ, maximumZ = Runtime.spatialBucketBounds(rectangle)
	for bucketX = minimumX, maximumX do
		local column = index.buckets[bucketX]
		if column then
			for bucketZ = minimumZ, maximumZ do
				for record in pairs(column[bucketZ] or {}) do
					if visitor(record.value) == false then
						return false
					end
				end
			end
		end
	end
	return true
end

function Runtime.newTransientSpatialIndex()
	return {
		buckets = {},
		nextOrder = 0,
	}
end

function Runtime.addTransientSpatialEntry(index, value, rectangle)
	local record = {
		value = value,
		keys = {},
	}
	Runtime.insertSpatialRecord(index, record, rectangle)
	return record
end

function Runtime.disconnectPlacedSpatialRecord(record)
	for _, connection in ipairs(record.connections or {}) do
		pcall(function()
			connection:Disconnect()
		end)
	end
	record.connections = {}
end

function Runtime.markPlacedCacheDirty(existing, placed)
	local index = existing and existing._spatialIndex
	local record = index and index.records[placed]
	if record and not index.released then
		index.dirty[record] = true
	end
end

function Runtime.attachPlacedSpatialRecord(existing, placed)
	local index = existing and existing._spatialIndex
	local base = placed and placed.base
	local model = placed and placed.model
	if not index or index.released or not base or not base.Parent
		or not model or not model.Parent or not model:IsDescendantOf(Plots)
	then
		return nil
	end
	local current = index.records[placed]
	if current then
		return current
	end
	placed.cachedFootprint = footprint(base)
	placed.cachedCFrame = base.CFrame
	placed.cachedSize = base.Size
	local record = {
		value = placed,
		keys = {},
		connections = {},
	}
	index.records[placed] = record
	index.byModel[model] = placed
	table.insert(record.connections, base:GetPropertyChangedSignal("CFrame"):Connect(function()
		Runtime.markPlacedCacheDirty(existing, placed)
	end))
	table.insert(record.connections, base:GetPropertyChangedSignal("Size"):Connect(function()
		Runtime.markPlacedCacheDirty(existing, placed)
	end))
	Runtime.insertSpatialRecord(index, record, placed.cachedFootprint)
	return record
end

function Runtime.removePlacedSpatialRecord(existing, placed)
	local index = existing and existing._spatialIndex
	local record = index and index.records[placed]
	if not record then
		return
	end
	Runtime.removeSpatialRecord(index, record)
	Runtime.disconnectPlacedSpatialRecord(record)
	index.records[placed] = nil
	index.dirty[record] = nil
	index.pendingKnown[placed.model] = nil
	if index.byModel[placed.model] == placed then
		index.byModel[placed.model] = nil
	end
end

function Runtime.trackPlacedCacheObject(existing, object)
	local index = existing and existing._spatialIndex
	if not index or index.released or not object then
		return nil
	end
	local model
	if object:IsA("Model") then
		model = object
	elseif object:IsA("BasePart") and object.Name == "Base" then
		local parent = object.Parent
		if parent and parent:IsA("Model") then
			model = parent
		end
	end
	if not model or not model:IsDescendantOf(Plots) then
		return nil
	end
	local base = model:FindFirstChild("Base")
	if not base or not base:IsA("BasePart") then
		return nil
	end
	local placed = index.byModel[model]
	if placed and placed.base ~= base then
		Runtime.removePlacedSpatialRecord(existing, placed)
		placed.base = base
		placed.cachedFootprint = nil
		placed.cachedCFrame = nil
		placed.cachedSize = nil
	elseif not placed then
		placed = Runtime.placedDescriptor(model, base)
		table.insert(existing, placed)
		index.pendingKnown[model] = true
	end
	Runtime.attachPlacedSpatialRecord(existing, placed)
	return placed
end

function Runtime.preparePlacedCache(existing)
	if existing._spatialIndex then
		Runtime.releasePlacedCache(existing)
	end
	local index = {
		buckets = {},
		nextOrder = 0,
		records = {},
		byModel = {},
		dirty = {},
		pendingKnown = {},
		connections = {},
		released = false,
	}
	existing._spatialIndex = index
	State.activePlacedCaches[existing] = true
	for _, placed in ipairs(existing) do
		Runtime.attachPlacedSpatialRecord(existing, placed)
	end
	table.insert(index.connections, Plots.DescendantAdded:Connect(function(object)
		Runtime.trackPlacedCacheObject(existing, object)
	end))
	table.insert(index.connections, Plots.DescendantRemoving:Connect(function(object)
		local model
		if object:IsA("Model") then
			model = object
		elseif object:IsA("BasePart") and object.Name == "Base" then
			local parent = object.Parent
			if parent and parent:IsA("Model") then
				model = parent
			end
		end
		local placed = model and index.byModel[model]
		local removingTrackedModel = placed and object == placed.model
		local removingTrackedBase = placed and object == placed.base
		if removingTrackedModel or removingTrackedBase then
			Runtime.removePlacedSpatialRecord(existing, placed)
			if removingTrackedBase and model and model.Parent then
				-- DescendantRemoving fires before Parent settles. Re-check on the
				-- next scheduler turn so replacing one direct Base with another
				-- cannot leave this live model absent from the broad phase.
				task.defer(function()
					if index.released or not model.Parent or not model:IsDescendantOf(Plots) then
						return
					end
					-- DescendantAdded may already have indexed a replacement Base in
					-- this same scheduler turn. Keep that one record instead of adding
					-- the old descriptor a second time.
					if index.byModel[model] then
						return
					end
					local replacement = model:FindFirstChild("Base")
					if replacement and replacement:IsA("BasePart") then
						placed.base = replacement
						placed.cachedFootprint = nil
						placed.cachedCFrame = nil
						placed.cachedSize = nil
						Runtime.attachPlacedSpatialRecord(existing, placed)
					end
				end)
			end
		end
	end))
	return existing
end

function Runtime.flushPlacedSpatialIndex(existing)
	local index = existing and existing._spatialIndex
	if not index or index.released then
		return
	end
	local dirty = index.dirty
	index.dirty = {}
	for record in pairs(dirty) do
		local placed = record.value
		if index.records[placed] == record then
			Runtime.removeSpatialRecord(index, record)
			local currentFootprint = Runtime.placedFootprint(placed)
			if currentFootprint then
				Runtime.insertSpatialRecord(index, record, currentFootprint)
			else
				Runtime.removePlacedSpatialRecord(existing, placed)
			end
		end
	end
end

function Runtime.placedCollisionCandidates(existing, rectangle)
	local index = existing and existing._spatialIndex
	if not index or index.released then
		return existing or {}
	end
	Runtime.flushPlacedSpatialIndex(existing)
	return Runtime.querySpatialIndex(index, rectangle)
end

function Runtime.placedNearbyCandidates(existing, position, radius)
	local search = {
		center = Vector2.new(position.X, position.Z),
		xAxis = Vector2.new(1, 0),
		zAxis = Vector2.new(0, 1),
		xHalf = radius,
		zHalf = radius,
	}
	return Runtime.placedCollisionCandidates(existing, search)
end

function Runtime.releasePlacedCache(existing)
	local index = existing and existing._spatialIndex
	if not index or index.released then
		return
	end
	index.released = true
	for _, connection in ipairs(index.connections) do
		pcall(function()
			connection:Disconnect()
		end)
	end
	for _, record in pairs(index.records) do
		Runtime.disconnectPlacedSpatialRecord(record)
	end
	index.connections = {}
	index.records = {}
	index.byModel = {}
	index.dirty = {}
	index.pendingKnown = {}
	index.buckets = {}
	existing._spatialIndex = nil
	State.activePlacedCaches[existing] = nil
end

function Runtime.withPreparedPlacedCache(callback)
	local existing = Runtime.preparePlacedCache(collectPlacedMachines())
	local ok, result, detail = pcall(callback, existing)
	-- The callback owns this live cache for its whole validation/build window.
	-- Always release it here, including when a last-second check or remote path
	-- throws, so State.activePlacedCaches cannot retain stale world listeners.
	Runtime.releasePlacedCache(existing)
	if not ok then
		error(result, 0)
	end
	return result, detail
end

function Runtime.placedFootprint(placed)
	local base = placed and placed.base
	if not base or not base.Parent or not placed.model or not placed.model.Parent
		or not placed.model:IsDescendantOf(Plots)
	then
		return nil
	end
	if not placed.cachedFootprint
		or placed.cachedCFrame ~= base.CFrame
		or placed.cachedSize ~= base.Size
	then
		placed.cachedFootprint = footprint(base)
		placed.cachedCFrame = base.CFrame
		placed.cachedSize = base.Size
	end
	return placed.cachedFootprint
end

function Runtime.knownPlacedModels(existing)
	local known = {}
	for _, placed in ipairs(existing) do
		known[placed.model] = true
	end
	return known
end

function Runtime.acknowledgePlacedCacheAdditions(existing, known)
	local index = existing and existing._spatialIndex
	if not index or index.released then
		return
	end
	for model in pairs(index.pendingKnown) do
		if index.byModel[model] then
			known[model] = true
		end
	end
	index.pendingKnown = {}
end

function Runtime.appendPlacedToCache(existing, known, model)
	if not model or not model.Parent then
		return nil
	end
	local index = existing and existing._spatialIndex
	local tracked = index and index.byModel[model]
	if tracked then
		if known then
			known[model] = true
		end
		index.pendingKnown[model] = nil
		return tracked
	elseif known and known[model] then
		return nil
	end
	local base = model:FindFirstChild("Base")
	if not base or not base:IsA("BasePart") then
		return nil
	end
	if known then
		known[model] = true
	end
	local placed = Runtime.placedDescriptor(model, base)
	placed.cachedFootprint = footprint(base)
	placed.cachedCFrame = base.CFrame
	placed.cachedSize = base.Size
	table.insert(existing, placed)
	Runtime.attachPlacedSpatialRecord(existing, placed)
	return placed
end

function Runtime.mergePlacementWatchCandidates(existing, known, watch)
	for _, model in ipairs(watch and watch.candidates or {}) do
		Runtime.appendPlacedToCache(existing, known, model)
	end
end

function Runtime.stopPlacementWatch(watch)
	if not watch then
		return
	end
	State.activePlacementWatches[watch] = nil
	if watch.stopped then
		return
	end
	watch.stopped = true
	if watch.connection then
		pcall(function()
			watch.connection:Disconnect()
		end)
		watch.connection = nil
	end
end

function Runtime.beginPlacementWatch(knownModels)
	local watch = {
		candidates = {},
		seen = {},
		knownModels = knownModels or {},
		connection = nil,
		stopped = false,
	}
	State.activePlacementWatches[watch] = true

	local function consider(object)
		if watch.stopped then
			return
		end
		local model
		if object:IsA("Model") then
			model = object
		elseif object:IsA("BasePart") and object.Name == "Base" then
			local parent = object.Parent
			if parent and parent:IsA("Model") then
				model = parent
			end
		end
		if not model or watch.seen[model] or watch.knownModels[model] or not model:IsDescendantOf(Plots) then
			return
		end
		local base = model:FindFirstChild("Base")
		if base and base:IsA("BasePart") then
			watch.seen[model] = true
			table.insert(watch.candidates, model)
		end
	end

	watch.consider = consider
	watch.connection = Plots.DescendantAdded:Connect(consider)
	return watch
end

local function verifyNewPlacement(watch, preview)
	local expectedName = preview.template.Name
	local nearbyMismatch
	local definitiveMismatch = false
	local stableModel
	local stablePolls = 0

	local function inspectCandidates()
		local exactMatches = {}
		for _, model in ipairs(watch.candidates) do
			local base = model.Parent
				and model:IsDescendantOf(Plots)
				and model:FindFirstChild("Base")
			if base and base:IsA("BasePart") then
				local geometryIssue, metrics = Runtime.classifyPlacementGeometry(
					preview,
					base,
					Config.VerifyHeightTolerance
				)
				local machine = Runtime.placedDescriptor(model, base)
				if geometryIssue ~= "outside_radius" and geometryIssue ~= "missing_geometry" then
					if not Runtime.placedModelMatchesTemplate(machine, preview.template) then
						nearbyMismatch = string.format(
							"wrong model appeared: expected %s, got %s",
							expectedName,
							machine.name
						)
					elseif geometryIssue == "position" or geometryIssue == "height" then
						definitiveMismatch = true
						nearbyMismatch = string.format(
							"correct model appeared off target: Base delta X %.3f, center Y %.3f, top Y %.3f, Z %.3f",
							metrics.deltaX,
							metrics.centerDeltaY,
							metrics.topDeltaY,
							metrics.deltaZ
						)
					elseif geometryIssue == "rotation" then
						definitiveMismatch = true
						nearbyMismatch = "correct model appeared with the wrong rotation"
					elseif geometryIssue == "footprint" then
						definitiveMismatch = true
						local expectedBase = expectedPlacementBase(preview)
						nearbyMismatch = string.format(
							"correct model appeared with unexpected Base footprint: expected %.2fx%.2f, got %.2fx%.2f",
							expectedBase.Size.X,
							expectedBase.Size.Z,
							machine.base.Size.X,
							machine.base.Size.Z
						)
					elseif geometryIssue == nil then
						table.insert(exactMatches, machine.model)
					end
				end
			end
		end
		if #exactMatches > 1 then
			stableModel = nil
			stablePolls = 0
			return nil, string.format(
				"%d fresh exact %s placements appeared; verification refused an ambiguous server result",
				#exactMatches,
				expectedName
			)
		elseif #exactMatches == 1 then
			if stableModel == exactMatches[1] then
				stablePolls += 1
			else
				stableModel = exactMatches[1]
				stablePolls = 1
			end
			if stablePolls >= 2 then
				return stableModel
			end
		else
			stableModel = nil
			stablePolls = 0
		end
		return nil
	end

	local function cancellationError()
		if watch.stopped then
			return "placement verification watcher was cancelled"
		elseif State.cancelRequested or State.destroyed then
			Runtime.stopPlacementWatch(watch)
			return Runtime.buildCancellationReason()
		end
		return nil
	end

	local function waitForMatch(deadline)
		repeat
			local cancelError = cancellationError()
			if cancelError then
				return nil, cancelError
			end
			local matched, terminalError = inspectCandidates()
			if matched or terminalError then
				return matched, terminalError
			end
			RunService.Heartbeat:Wait()
		until os.clock() >= deadline
		return nil
	end

	local matched, terminalError = waitForMatch(os.clock() + Config.VerifyTimeout)
	if matched or terminalError then
		Runtime.stopPlacementWatch(watch)
		return matched, terminalError
	end

	local function authoritativeRefresh()
		Runtime.rescanPlacedRegistry()
		for _, machine in ipairs(collectPlacedMachines()) do
			if not watch.knownModels[machine.model] and not watch.seen[machine.model] then
				watch.consider(machine.model)
			end
		end
	end

	-- Heal a missed/reordered DescendantAdded before deciding whether a server
	-- placement is absent. collectPlacedMachines alone only reads the registry.
	authoritativeRefresh()
	matched, terminalError = inspectCandidates()
	if matched or terminalError then
		Runtime.stopPlacementWatch(watch)
		return matched, terminalError
	elseif definitiveMismatch then
		Runtime.stopPlacementWatch(watch)
		return nil, nearbyMismatch
	end

	if Config.VerifyLateReplicationGrace > 0 then
		print(PREFIX .. string.format(
			"server accepted %s; waiting up to %.1fs for delayed plot replication...",
			expectedName,
			Config.VerifyLateReplicationGrace
		))
		matched, terminalError = waitForMatch(os.clock() + Config.VerifyLateReplicationGrace)
		if matched or terminalError then
			Runtime.stopPlacementWatch(watch)
			return matched, terminalError
		end
		authoritativeRefresh()
		-- Require the final authoritative candidate to remain valid for another
		-- heartbeat, matching the normal two-poll stability rule.
		for _ = 1, 2 do
			matched, terminalError = inspectCandidates()
			if matched or terminalError then
				Runtime.stopPlacementWatch(watch)
				return matched, terminalError
			end
			RunService.Heartbeat:Wait()
		end
	end

	Runtime.stopPlacementWatch(watch)
	if nearbyMismatch then
		return nil, nearbyMismatch
	end
	return nil, string.format(
		"%s did not appear near its expected Base within %.1fs (including delayed-replication grace)",
		expectedName,
		Config.VerifyTimeout + Config.VerifyLateReplicationGrace
	)
end

local function duplicateSourceItemSnapshotIsCurrent(item)
	local current = false
	local ok = pcall(function()
		local model = item and item.model
		local base = item and item.base
		current = typeof(model) == "Instance"
			and typeof(base) == "Instance"
			and model.Parent ~= nil
			and model:IsDescendantOf(Plots)
			and model:FindFirstChild("Base") == base
			and base.Parent == model
			and base.CFrame == item.sourceBaseCFrame
			and base.Size == item.sourceBaseSize
	end)
	return ok and current
end

local function duplicateSourceItemsOverlap(firstItem, secondItem)
	local firstFootprint = firstItem and firstItem.sourceFootprint
	local secondFootprint = secondItem and secondItem.sourceFootprint
	return duplicateSourceItemSnapshotIsCurrent(firstItem)
		and duplicateSourceItemSnapshotIsCurrent(secondItem)
		and firstFootprint ~= nil
		and secondFootprint ~= nil
		and footprintsOverlap(firstFootprint, secondFootprint)
end

local function duplicatePreviewPairInheritedOverlap(firstPreview, secondPreview)
	local duplicate = State.duplicate
	return firstPreview ~= nil
		and secondPreview ~= nil
		and firstPreview.selectionVersion == duplicate.selectionVersion
		and secondPreview.selectionVersion == duplicate.selectionVersion
		and firstPreview.destinationX == duplicate.destinationX
		and secondPreview.destinationX == duplicate.destinationX
		and firstPreview.destinationZ == duplicate.destinationZ
		and secondPreview.destinationZ == duplicate.destinationZ
		and firstPreview.duplicateRotation == duplicate.rotation
		and secondPreview.duplicateRotation == duplicate.rotation
		and firstPreview.sourceItem ~= nil
		and secondPreview.sourceItem ~= nil
		and duplicateSourceItemsOverlap(firstPreview.sourceItem, secondPreview.sourceItem)
end

local function duplicatePlacedSiblingInheritedOverlap(preview, placedModel)
	if not preview or not preview.sourceItem or not placedModel then
		return false
	end
	local duplicate = State.duplicate
	if preview.selectionVersion ~= duplicate.selectionVersion
		or preview.destinationX ~= duplicate.destinationX
		or preview.destinationZ ~= duplicate.destinationZ
		or preview.duplicateRotation ~= duplicate.rotation
	then
		return false
	end
	for _, sibling in ipairs(State.duplicate.previews) do
		if sibling ~= preview
			and sibling.built == true
			and sibling.placedModel == placedModel
			and sibling.selectionVersion == duplicate.selectionVersion
			and sibling.destinationX == duplicate.destinationX
			and sibling.destinationZ == duplicate.destinationZ
			and sibling.duplicateRotation == duplicate.rotation
			and Runtime.committedPlacementError(sibling) == nil
			and duplicatePreviewPairInheritedOverlap(preview, sibling)
		then
			return true
		end
	end
	return false
end

local function validateCurrentPlacement(preview, existing, verifiedReuseModel)
	preview.reasons = {}
	if preview.sourceItem and not duplicateSourceItemSnapshotIsCurrent(preview.sourceItem) then
		addReason(preview, "selected source object disappeared or changed before this send")
	end
	local inside, limitsError = baseInsideLimits(preview.base)
	if not inside then
		addReason(preview, limitsError)
	end
	local candidate = footprint(preview.base)
	local candidates = existing
		and Runtime.placedCollisionCandidates(existing, candidate)
		or collectPlacedMachines()
	for _, placed in ipairs(candidates) do
		local placedFootprint = Runtime.placedFootprint(placed)
		if placed.model ~= verifiedReuseModel
			and placedFootprint
			and footprintsOverlap(candidate, placedFootprint)
			and not duplicatePlacedSiblingInheritedOverlap(preview, placed.model)
		then
			addReason(preview, "now overlaps existing " .. placed.name)
		end
	end
	preview.valid = #preview.reasons == 0
	applyValidityStyle(preview)
	return preview.valid
end

function Runtime.committedPlacementError(preview)
	if not preview or not preview.built then
		return nil
	end
	local model = preview.placedModel
	if not model or not model.Parent or not model:IsDescendantOf(Plots) then
		return "verified server model disappeared from the plot"
	end
	local base = model:FindFirstChild("Base")
	if not base or not base:IsA("BasePart") then
		return "verified server model lost its direct Base"
	end
	local placed = Runtime.placedDescriptor(model, base)
	if not preview.template or not Runtime.placedModelMatchesTemplate(placed, preview.template) then
		return string.format(
			"verified server model changed identity (expected %s, got %s)",
			tostring(preview.template and preview.template.Name or preview.entry and preview.entry.Name),
			tostring(placed.name)
		)
	end
	local geometryIssue, metrics = Runtime.classifyPlacementGeometry(
		preview,
		base,
		Config.VerifyHeightTolerance
	)
	if geometryIssue then
		return string.format(
			"verified server model changed geometry (%s; Base delta X %.3f, center Y %.3f, top Y %.3f, Z %.3f)",
			geometryIssue,
			metrics and metrics.deltaX or math.huge,
			metrics and metrics.centerDeltaY or math.huge,
			metrics and metrics.topDeltaY or math.huge,
			metrics and metrics.deltaZ or math.huge
		)
	end
	return nil
end

function Runtime.auditCommittedBlueprintPlacements()
	for _, group in ipairs({
		{ label = "machine", previews = State.previews },
		{ label = "plumbing piece", previews = State.authoredPlacementPreviews },
	}) do
		for _, preview in ipairs(group.previews) do
			local placementError = Runtime.committedPlacementError(preview)
			if placementError then
				return false, string.format(
					"%s #%d %s: %s",
					group.label,
					preview.index,
					tostring(preview.entry and preview.entry.Name),
					placementError
				)
			end
		end
	end
	return true
end

function Runtime.committedConnectionError(connection, inspector)
	if not connection or not connection.built then
		return nil, false
	end
	local valid, fromConnector, toConnector, reasons = inspector(connection, true)
	if not valid or not fromConnector or not toConnector then
		return "verified endpoints changed or disappeared: " .. table.concat(reasons or {}, "; "), false
	end
	local verifiedConnection = connection.verifiedConnection
	local decorations = connection.verifiedDecorations
		or (type(verifiedConnection) == "table" and verifiedConnection.decorations)
	if type(decorations) ~= "table" or #decorations < Config.ConnectionDecorationCount then
		return "verified connection lost its exact server decoration provenance", true
	end
	local pairMatches, pairError = Runtime.connectionDecorationPairMatches(
		connection.kind,
		decorations[1],
		decorations[2],
		fromConnector,
		toConnector
	)
	if pairMatches then
		return nil, false
	end
	local refreshed, refreshError = Runtime.refreshConnectionDecorations(
		connection.kind,
		fromConnector,
		toConnector,
		decorations
	)
	if refreshed then
		connection.verifiedDecorations = refreshed
		if type(verifiedConnection) == "table" then
			verifiedConnection.decorations = refreshed
		end
		return nil, false
	end
	return "verified server decorations changed or disappeared: "
		.. tostring(pairError)
		.. "; "
		.. tostring(refreshError), true
end

function Runtime.invalidateCommittedConnection(connection, reason)
	local verifiedConnection = connection and connection.verifiedConnection
	if type(verifiedConnection) == "table" then
		verifiedConnection.confirmed = false
		Runtime.forgetKnownConnection(verifiedConnection)
	end
	connection.built = false
	connection.verifiedConnection = nil
	connection.verifiedDecorations = nil
	connection.reasons = { tostring(reason or "verified server connection disappeared") }
end

function Runtime.reuseKnownConnectionIfExact(connection, known, fromConnector, toConnector)
	if type(known) ~= "table" or known.confirmed == false then
		return false
	end
	local decorations = known.decorations
	local pairMatches = type(decorations) == "table"
		and Runtime.connectionDecorationPairMatches(
			connection.kind,
			decorations[1],
			decorations[2],
			fromConnector,
			toConnector
		)
	if not pairMatches then
		decorations = Runtime.refreshConnectionDecorations(
			connection.kind,
			fromConnector,
			toConnector,
			decorations
		)
		if not decorations then
			return false
		end
		known.decorations = decorations
	end
	connection.verifiedConnection = known
	connection.verifiedDecorations = decorations
	connection.built = true
	if connection.line then
		connection.line:Destroy()
		connection.line = nil
	end
	return true
end

function Runtime.auditCommittedBlueprintConnections(makeMissingReplayable)
	local firstError
	for _, group in ipairs({
		{
			label = "pipe link",
			connections = State.authoredLinkPreviews,
			inspector = inspectAuthoredPipeLink,
		},
		{
			label = "wire",
			connections = State.connectionPreviews,
			inspector = inspectConnection,
		},
	}) do
		for _, connection in ipairs(group.connections) do
			local connectionError, replayable = Runtime.committedConnectionError(
				connection,
				group.inspector
			)
			if connectionError then
				if makeMissingReplayable and replayable then
					Runtime.invalidateCommittedConnection(connection, connectionError)
					connectionError ..= "; marked pending for safe Resume"
				end
				firstError = firstError or string.format(
					"%s #%d: %s",
					group.label,
					connection.index,
					connectionError
				)
			end
		end
	end
	return firstError == nil, firstError
end

function Runtime.waitForNextAction(delaySeconds, actionStartedAt)
	local delay = tonumber(delaySeconds) or 0
	local remaining = delay - math.max(0, os.clock() - (actionStartedAt or os.clock()))
	if remaining <= 0 then
		return not State.cancelRequested and not State.destroyed
	end
	local deadline = os.clock() + remaining
	repeat
		if State.cancelRequested or State.destroyed then
			return false
		end
		RunService.Heartbeat:Wait()
	until os.clock() >= deadline
	return not State.cancelRequested and not State.destroyed
end

function Runtime.shouldReportProgress(completed, total)
	return completed == 1
		or completed == total
		or completed % Config.ProgressLogEvery == 0
end

function Runtime.shouldReportResumedProgress(previouslyCompleted, completedThisRun, total)
	local overallStageCompleted = previouslyCompleted + completedThisRun
	return completedThisRun == 1
		or overallStageCompleted == total
		or overallStageCompleted % Config.ProgressLogEvery == 0
end

function Runtime.setBuildLeaseRemoteInFlight(inFlight)
	local token = State.buildLeaseToken
	if not token then
		return
	end
	local sharedEnvironment = type(getgenv) == "function" and getgenv() or _G
	local lease = sharedEnvironment.__IndustrialistBlueprintBuildLease
	if type(lease) == "table" and lease.Token == token and lease.State == State then
		lease.InFlightRemote = inFlight == true
	end
end

function Runtime.acquireBuildLease()
	local sharedEnvironment = type(getgenv) == "function" and getgenv() or _G
	local lease = sharedEnvironment.__IndustrialistBlueprintBuildLease
	local now = os.clock()
	if type(lease) == "table" then
		if lease.Active == true then
			local owner = lease.State
			local ownerCancelled = type(owner) ~= "table"
				or owner.destroyed == true
				or owner.cancelRequested == true
			if not ownerCancelled then
				return nil, "A previous placer operation is still finishing. Wait for it to stop before building again."
			end
			if lease.InFlightRemote == true then
				return nil, "A cancelled placer remote is still in flight. Wait for that server call to return before building again."
			end
			lease.CancelledAt = tonumber(lease.CancelledAt) or now
			local settlingUntil = lease.CancelledAt
				+ Config.VerifyTimeout
				+ Config.VerifyLateReplicationGrace
			if settlingUntil > now then
				return nil, string.format(
					"A cancelled placement is still settling for %.2f second(s); then press Build again.",
					settlingUntil - now
				)
			end
			-- No server remote remains in flight. The old verifier has now had a full
			-- bounded settlement window, so this cancelled owner can be replaced.
			lease.Active = false
			lease.State = nil
			lease.Token = nil
		end
		local availableAt = tonumber(lease.AvailableAt) or 0
		if availableAt > now then
			return nil, string.format(
				"A cancelled placement is still settling for %.2f second(s); then press Build again.",
				availableAt - now
			)
		end
	end
	local token = {}
	sharedEnvironment.__IndustrialistBlueprintBuildLease = {
		Active = true,
		State = State,
		Token = token,
		AvailableAt = now,
		CancelledAt = nil,
		InFlightRemote = false,
	}
	return token
end

function Runtime.releaseBuildLease(token, quarantine)
	local sharedEnvironment = type(getgenv) == "function" and getgenv() or _G
	local lease = sharedEnvironment.__IndustrialistBlueprintBuildLease
	if type(lease) ~= "table" or lease.Token ~= token then
		return
	end
	lease.Active = false
	lease.State = nil
	lease.Token = nil
	lease.InFlightRemote = false
	lease.AvailableAt = os.clock()
		+ (quarantine and (Config.VerifyTimeout + Config.VerifyLateReplicationGrace) or 0)
end

local function sendPlacement(captured, packet)
	dumpArgs("transformed arguments", packet)
	State.replaying = true
	State.buildRemoteAttempted = true
	Runtime.setBuildLeaseRemoteInFlight(true)
	local ok, result = pcall(function()
		if captured.Method == "InvokeServer" then
			return captured.Remote:InvokeServer(table.unpack(packet, 1, packet.n))
		elseif captured.Method == "FireServer" then
			captured.Remote:FireServer(table.unpack(packet, 1, packet.n))
			return nil
		end
		error("unsupported method " .. tostring(captured.Method))
	end)
	Runtime.setBuildLeaseRemoteInFlight(false)
	State.replaying = false
	if Config.VerboseRemoteLogging or not ok or result == false then
		print(PREFIX .. "server call ok=" .. tostring(ok) .. " result=" .. describe(result))
	end
	return ok, result
end

local function copyPlacementEntry(entry)
	return {
		Category = entry.Category,
		Name = entry.Name,
		X = tonumber(entry.X),
		Z = tonumber(entry.Z),
		Rotation = tonumber(entry.Rotation) or 0,
	}
end

function Runtime.copyConnectorPath(path)
	if type(path) ~= "table" then
		return nil
	end
	local copied = {}
	for _, segment in ipairs(path) do
		table.insert(copied, {
			Name = segment.Name,
			ClassName = segment.ClassName,
			Ordinal = segment.Ordinal,
		})
	end
	return #copied > 0 and copied or nil
end

local function copyEndpointReference(reference)
	local copied = {
		Machine = reference.Machine,
		Piece = reference.Piece,
		Connector = reference.Connector,
	}
	copied.ConnectorPath = Runtime.copyConnectorPath(reference.ConnectorPath)
	return copied
end

local function copyPipeLinkEntry(entry)
	return {
		From = copyEndpointReference(entry.From),
		To = copyEndpointReference(entry.To),
	}
end

local function copyAutoPlumbRoute(entry)
	return {
		FromMachine = entry.FromMachine,
		ToMachine = entry.ToMachine,
		FromConnector = entry.FromConnector,
		ToConnector = entry.ToConnector,
	}
end

local function replaceArray(target, source, copier)
	for index = #target, 1, -1 do
		table.remove(target, index)
	end
	for _, entry in ipairs(source) do
		table.insert(target, copier(entry))
	end
end

local function copiedArray(source, copier)
	local result = {}
	for _, entry in ipairs(source) do
		table.insert(result, copier(entry))
	end
	return result
end

local function trimmed(text)
	return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function validateBlueprintLuaSource(source)
	if #source > Config.MaxBlueprintTextBytes then
		return false, "blueprint text is larger than 500 KB"
	end

	-- Replace quoted strings and remove line comments before checking tokens.
	-- The accepted Lua form is data-only: no calls, indexing, loops, or other
	-- executable expressions can pass this check.
	local scrubbed = {}
	local index = 1
	while index <= #source do
		local character = source:sub(index, index)
		if character == '"' or character == "'" then
			local quote = character
			table.insert(scrubbed, '""')
			index += 1
			local closed = false
			while index <= #source do
				local current = source:sub(index, index)
				if current == "\\" then
					index += 2
				elseif current == quote then
					index += 1
					closed = true
					break
				else
					index += 1
				end
			end
			if not closed then
				return false, "blueprint contains an unterminated string"
			end
		elseif character == "-" and source:sub(index + 1, index + 1) == "-" then
			index += 2
			while index <= #source and source:sub(index, index) ~= "\n" do
				index += 1
			end
			table.insert(scrubbed, "\n")
		else
			table.insert(scrubbed, character)
			index += 1
		end
	end

	local neutral = table.concat(scrubbed)
	if neutral:find("[^%s%{%}%[%],;=%+%-%d%._%a\"']") then
		return false, "Lua blueprint contains executable or unsupported punctuation"
	end

	local allowedIdentifiers = {
		["local"] = true,
		["return"] = true,
		["true"] = true,
		["false"] = true,
		["nil"] = true,
		Blueprint = true,
		Machines = true,
		AuthoredPlumbing = true,
		Pipes = true,
		AuthoredPipeLinks = true,
		Plumbing = true,
		PipeLinks = true,
		Wiring = true,
		Wires = true,
		AutoPlumb = true,
		SmartPlumbing = true,
		PipeQuality = true,
		FromMachine = true,
		ToMachine = true,
		FromConnector = true,
		ToConnector = true,
		Category = true,
		Name = true,
		X = true,
		Z = true,
		Rotation = true,
		From = true,
		To = true,
		Machine = true,
		Piece = true,
		Connector = true,
		ConnectorPath = true,
		ClassName = true,
		Ordinal = true,
		Title = true,
		Version = true,
		Format = true,
	}
	for identifier in neutral:gmatch("[_%a][_%w]*") do
		if not allowedIdentifiers[identifier] then
			return false, "Lua blueprint contains unsupported identifier " .. identifier
		end
	end
	return true
end

local function decodeLuaBlueprint(source)
	local valid, validationError = validateBlueprintLuaSource(source)
	if not valid then
		return nil, validationError
	end
	local loader = loadstring
	if type(loader) ~= "function" then
		return nil, "executor does not expose loadstring"
	end

	local clean = trimmed(source)
	local chunkSource
	if clean:sub(1, 1) == "{" then
		chunkSource = "return " .. clean
	elseif clean:match("^return[%s{]") then
		chunkSource = clean
	else
		chunkSource = [[
local Blueprint, Machines, AuthoredPlumbing, Pipes
local AuthoredPipeLinks, Plumbing, PipeLinks, Wiring, Wires
local AutoPlumb, SmartPlumbing, PipeQuality
]] .. clean .. [[

return {
	Blueprint = Blueprint or Machines,
	AuthoredPlumbing = AuthoredPlumbing or Pipes,
	AuthoredPipeLinks = AuthoredPipeLinks or Plumbing or PipeLinks,
	Wiring = Wiring or Wires,
	AutoPlumb = AutoPlumb,
	SmartPlumbing = SmartPlumbing,
	PipeQuality = PipeQuality,
}
]]
	end

	local chunk, compileError = loader(chunkSource)
	local usedDirectFallback = false
	if not chunk and chunkSource ~= clean then
		-- Also accept a complete data-only chunk such as
		-- `local Blueprint = {...}; return Blueprint`.
		local directChunk, directError = loader(clean)
		if directChunk then
			chunk = directChunk
			usedDirectFallback = true
		else
			compileError = tostring(compileError) .. " | direct form: " .. tostring(directError)
		end
	end
	if not chunk then
		return nil, "Lua blueprint did not compile: " .. tostring(compileError)
	end
	if type(setfenv) == "function" then
		pcall(setfenv, chunk, {})
	end
	local runOK, result = pcall(chunk)
	if not runOK then
		return nil, "Lua blueprint failed: " .. tostring(result)
	elseif type(result) ~= "table" then
		return nil, "Lua blueprint must return or define a table"
	end
	if usedDirectFallback
		and source:find("AutoPlumb", 1, true)
		and result.AutoPlumb == nil
		and result.SmartPlumbing == nil
	then
		return nil, "Lua chunk mentions AutoPlumb but returns a different table; return the full blueprint document so routes are not discarded"
	elseif usedDirectFallback
		and source:find("PipeQuality", 1, true)
		and result.PipeQuality == nil
	then
		return nil, "Lua chunk mentions PipeQuality but returns a different table; return the full blueprint document"
	end
	return result
end

local function decodeBlueprintText(source)
	local jsonOK, jsonResult = pcall(function()
		return HttpService:JSONDecode(source)
	end)
	if jsonOK and type(jsonResult) == "table" then
		return jsonResult, "JSON"
	end

	local luaResult, luaError = decodeLuaBlueprint(source)
	if luaResult then
		return luaResult, "Lua"
	end
	return nil, string.format(
		"Could not read blueprint as JSON or restricted Lua. Lua error: %s",
		tostring(luaError)
	)
end

local function finiteNumber(value)
	local number = tonumber(value)
	if not number or number ~= number or number == math.huge or number == -math.huge then
		return nil
	end
	return number
end

local function denseArrayCount(source, label, maximum)
	local count = 0
	local highest = 0
	for key in pairs(source) do
		if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
			return nil, label .. " must contain only positive integer array keys"
		end
		count += 1
		highest = math.max(highest, key)
	end
	if highest ~= count then
		return nil, label .. " must be dense; missing array entries are not allowed"
	elseif count > maximum then
		return nil, string.format("%s has %d entries; maximum is %d", label, count, maximum)
	end
	return count
end

local function normalizePlacementList(source, label, placementRole)
	if source == nil then
		return {}
	elseif type(source) ~= "table" then
		return nil, label .. " must be an array"
	end
	local maximum = placementRole == "Plumbing"
		and Config.MaxSavedPlumbingPieces
		or Config.MaxBlueprintMachines
	local _, arrayError = denseArrayCount(source, label, maximum)
	if arrayError then
		return nil, arrayError
	end

	local result = {}
	for index, entry in ipairs(source) do
		if type(entry) ~= "table" then
			return nil, string.format("%s #%d must be a table", label, index)
		end
		-- Compact form keeps useful blueprints readable:
		-- { "Factories", "PressMK2", 12, -8, 90 }
		local category = trimmed(entry.Category or entry[1])
		local name = trimmed(entry.Name or entry[2])
		local x = finiteNumber(entry.X ~= nil and entry.X or entry[3])
		local z = finiteNumber(entry.Z ~= nil and entry.Z or entry[4])
		local rotationValue = entry.Rotation
		if rotationValue == nil then
			rotationValue = entry[5] or 0
		end
		local rotation = finiteNumber(rotationValue)
		if category == "" or name == "" then
			return nil, string.format("%s #%d needs Category and Name", label, index)
		elseif not x or not z or not rotation then
			return nil, string.format("%s #%d needs numeric X, Z, and Rotation", label, index)
		end
		local snappedRotation = math.round(rotation / 90) * 90
		if math.abs(rotation - snappedRotation) > 0.001 then
			return nil, string.format("%s #%d Rotation must be a multiple of 90", label, index)
		end
		-- These are portable offsets from a blueprint anchor, not absolute world
		-- positions. A real selection can legitimately mix even and odd phases
		-- (for example X=33 beside X=0), so only the whole-stud packet grid is
		-- invariant here. Auto-Plumb still generates its own odd/odd route grid.
		local snappedX = math.round(x)
		local snappedZ = math.round(z)
		if math.abs(x - snappedX) > 0.001 or math.abs(z - snappedZ) > 0.001 then
			return nil, string.format(
				"%s #%d is off-grid at X=%s Z=%s; X and Z must be whole studs (nearest X=%.0f Z=%.0f)",
				label,
				index,
				tostring(x),
				tostring(z),
				snappedX,
				snappedZ
			)
		end
		table.insert(result, {
			Category = category,
			Name = name,
			X = snappedX,
			Z = snappedZ,
			Rotation = ((snappedRotation % 360) + 360) % 360,
		})
	end
	return result
end

local function normalizeAutoPlumbList(source, machineCount)
	if source == nil or source == false or source == true then
		return {}, source
	elseif type(source) ~= "table" then
		return nil, nil, "AutoPlumb must be true, false, or an array of machine routes"
	end
	local _, arrayError = denseArrayCount(source, "AutoPlumb", Config.MaxAutoPlumbRoutes)
	if arrayError then
		return nil, nil, arrayError
	end

	local result = {}
	for index, entry in ipairs(source) do
		if type(entry) ~= "table" then
			return nil, nil, string.format("AutoPlumb route #%d must be a table", index)
		end
		local fromMachine
		local toMachine
		local fromConnector
		local toConnector
		if type(entry.From) == "table" or type(entry.To) == "table" then
			fromMachine = finiteNumber(entry.From and entry.From.Machine)
			toMachine = finiteNumber(entry.To and entry.To.Machine)
			fromConnector = trimmed(entry.From and entry.From.Connector)
			toConnector = trimmed(entry.To and entry.To.Connector)
		else
			fromMachine = finiteNumber(entry.FromMachine or entry.From or entry[1])
			if entry[4] ~= nil then
				fromConnector = trimmed(entry.FromConnector or entry[2])
				toMachine = finiteNumber(entry.ToMachine or entry.To or entry[3])
				toConnector = trimmed(entry.ToConnector or entry[4])
			else
				toMachine = finiteNumber(entry.ToMachine or entry.To or entry[2])
				fromConnector = trimmed(entry.FromConnector)
				toConnector = trimmed(entry.ToConnector)
			end
		end
		if not fromMachine or fromMachine % 1 ~= 0 or fromMachine < 1 or fromMachine > machineCount then
			return nil, nil, string.format("AutoPlumb route #%d has an invalid source machine", index)
		elseif not toMachine or toMachine % 1 ~= 0 or toMachine < 1 or toMachine > machineCount then
			return nil, nil, string.format("AutoPlumb route #%d has an invalid target machine", index)
		elseif fromMachine == toMachine then
			return nil, nil, string.format("AutoPlumb route #%d cannot connect a machine to itself", index)
		end
		table.insert(result, {
			FromMachine = fromMachine,
			ToMachine = toMachine,
			FromConnector = fromConnector ~= "" and fromConnector or nil,
			ToConnector = toConnector ~= "" and toConnector or nil,
		})
	end
	return result, "Routes"
end

-- Auto-Plumb turns a tiny machine-to-machine intent list into the physical
-- 2-stud pipe pieces Industrialist actually requires. It never guesses among
-- multiple holes on the same requested machine pair: use the four-value route
-- form when a model exposes more than one compatible connector.
local AUTO_PIPE_FAMILIES = {
	Good = {
		Item = { Straight = "ShortPipe2", Turn = "PipeTurn2", Junction = "PipeJunction2" },
		Fluid = {
			Straight = "ShortFluidPipe2",
			Turn = "FluidPipeTurn2",
			Junction = "FluidPipeJunction2",
		},
	},
	Rusty = {
		Item = { Straight = "ShortPipe", Turn = "PipeTurn", Junction = "PipeJunction" },
		Fluid = {
			Straight = "ShortFluidPipe",
			Turn = "FluidPipeTurn",
			Junction = "FluidPipeJunction",
		},
	},
}

local AutoPipeConnectorOffsets = {}

local function routeCellKey(x, z)
	return string.format("%.3f:%.3f", x, z)
end

local function routeStateKey(x, z, direction)
	return string.format("%.3f:%.3f:%d", x, z, direction or 0)
end

local function autoPipeFamily(liquidKind)
	local quality = State.autoPlumbQuality
	local qualityFamily = AUTO_PIPE_FAMILIES[quality]
	return qualityFamily and qualityFamily[liquidKind]
end

local function pipeConnectorOffset(liquidKind)
	local cacheKey = State.autoPlumbQuality .. ":" .. liquidKind
	if AutoPipeConnectorOffsets[cacheKey] then
		return AutoPipeConnectorOffsets[cacheKey]
	end
	local family = autoPipeFamily(liquidKind)
	if not family then
		return nil, "no " .. tostring(liquidKind) .. " pipe family for " .. tostring(State.autoPlumbQuality)
	end
	local template, templateError = resolveTemplate({ Category = "Pipes", Name = family.Straight })
	if not template then
		return nil, templateError
	end
	local connector, connectorError = findNamedConnector(template, "PipeA")
	if not connector then
		return nil, connectorError
	end
	local offset = template:GetPivot():PointToObjectSpace(connector.Position)
	AutoPipeConnectorOffsets[cacheKey] = offset
	return offset
end

local function routeNodePosition(liquidKind, x, z)
	local offset, offsetError = pipeConnectorOffset(liquidKind)
	if not offset then
		return nil, offsetError
	end
	return CFrame.new(x, Config.PlacementY, z):PointToWorldSpace(offset)
end

local function routeCellFootprint(x, z)
	return {
		center = Vector2.new(x, z),
		xAxis = Vector2.new(1, 0),
		zAxis = Vector2.new(0, 1),
		xHalf = 1,
		zHalf = 1,
	}
end

local function autoPlumbLimitsSnapshot()
	local limits = workspace:FindFirstChild("Limits")
	if not limits or not limits:IsA("BasePart") then
		return nil
	end
	local localWorldX = limits.CFrame:VectorToObjectSpace(Vector3.new(1, 0, 0))
	local localWorldZ = limits.CFrame:VectorToObjectSpace(Vector3.new(0, 0, 1))
	return {
		cframe = limits.CFrame,
		worldY = limits.Position.Y,
		xHalf = limits.Size.X * 0.5 + Config.EdgeEpsilon,
		zHalf = limits.Size.Z * 0.5 + Config.EdgeEpsilon,
		-- Exact projection of the four axis-aligned 2x2 pipe-cell corners.
		xRadius = math.abs(localWorldX.X) + math.abs(localWorldZ.X),
		zRadius = math.abs(localWorldX.Z) + math.abs(localWorldZ.Z),
	}
end

local function routeCellInsideLimits(x, z, limitsSnapshot)
	if not limitsSnapshot then
		return false
	end
	local localCenter = limitsSnapshot.cframe:PointToObjectSpace(
		Vector3.new(x, limitsSnapshot.worldY, z)
	)
	return math.abs(localCenter.X) + limitsSnapshot.xRadius <= limitsSnapshot.xHalf
		and math.abs(localCenter.Z) + limitsSnapshot.zRadius <= limitsSnapshot.zHalf
end

function Runtime.routeCellOverlapsIndexedObstacle(index, candidate)
	local minimumX, maximumX, minimumZ, maximumZ = Runtime.spatialBucketBounds(candidate)
	for bucketX = minimumX, maximumX do
		local column = index.buckets[bucketX]
		if column then
			for bucketZ = minimumZ, maximumZ do
				for record in pairs(column[bucketZ] or {}) do
					if footprintsOverlap(candidate, record.value) then
						return true
					end
				end
			end
		end
	end
	return false
end

local function collectAutoPlumbObstacles()
	local obstacles = {}
	local spatial = Runtime.newTransientSpatialIndex()
	local function addObstacle(obstacle)
		table.insert(obstacles, obstacle)
		Runtime.addTransientSpatialEntry(spatial, obstacle, obstacle)
	end
	for _, preview in ipairs(State.previews) do
		if preview.base and preview.model and preview.model.Parent then
			addObstacle(footprint(preview.base))
		end
	end
	for _, preview in ipairs(State.authoredPlacementPreviews) do
		if preview.base and preview.model and preview.model.Parent then
			addObstacle(footprint(preview.base))
		end
	end
	for _, placed in ipairs(collectPlacedMachines()) do
		addObstacle(footprint(placed.base))
	end
	obstacles.spatial = spatial
	obstacles.limits = autoPlumbLimitsSnapshot()
	return obstacles
end

local function routeCellAvailable(x, z, obstacles, reserved, availabilityCache)
	local key = routeCellKey(x, z)
	-- Reservations grow after each committed route. Keep that dynamic decision
	-- outside the static limits/obstacle cache so even an accidentally reused
	-- cache can never route through an already claimed pipe cell.
	if reserved[key] then
		return false
	end
	local cached = availabilityCache and availabilityCache[key]
	if cached ~= nil then
		return cached
	end
	local available = routeCellInsideLimits(x, z, obstacles.limits)
	if available then
		local candidate = routeCellFootprint(x, z)
		if obstacles.spatial then
			available = not Runtime.routeCellOverlapsIndexedObstacle(obstacles.spatial, candidate)
		else
			for _, obstacle in ipairs(obstacles) do
				if footprintsOverlap(candidate, obstacle) then
					available = false
					break
				end
			end
		end
	end
	if availabilityCache then
		availabilityCache[key] = available
	end
	return available
end

local function autoPipePorts(machineIndex)
	local preview = State.previews[machineIndex]
	local model = preview and (preview.model or preview.placedModel)
	if not model or not model.Parent then
		return nil, string.format("machine #%d preview is unavailable", machineIndex)
	end
	local cached = State.autoPipePortsCache[model]
	if cached then
		return cached
	end
	local ports = {}
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			local metadata = descendant:FindFirstChild("Pipe")
			if metadata and metadata:IsA("Folder") then
				local liquidKind = pipeLiquidKind(metadata)
				if liquidKind then
					table.insert(ports, {
						connector = descendant,
						metadata = metadata,
						liquidKind = liquidKind,
						isInput = booleanValue(metadata, "Input"),
						isOutput = booleanValue(metadata, "Output"),
						sortName = descendant.Name,
						sortPath = descendant:GetFullName(),
					})
				end
			end
		end
	end
	table.sort(ports, function(first, second)
		if first.sortName ~= second.sortName then
			return first.sortName < second.sortName
		end
		return first.sortPath < second.sortPath
	end)
	State.autoPipePortsCache[model] = ports
	return ports
end

local function autoPortForName(machineIndex, connectorName, role)
	local preview = State.previews[machineIndex]
	local model = preview and (preview.model or preview.placedModel)
	local connector, connectorError = findNamedConnector(model, connectorName)
	if not connector then
		return nil, connectorError
	end
	local metadata, metadataError = connectorFolder(connector, "Pipe")
	if not metadata then
		return nil, metadataError
	elseif role == "source" and booleanValue(metadata, "Input") then
		return nil, connectorName .. " is marked Input and cannot start a route"
	elseif role == "target" and booleanValue(metadata, "Output") then
		return nil, connectorName .. " is marked Output and cannot end a route"
	end
	local liquidKind, liquidError = pipeLiquidKind(metadata)
	if not liquidKind then
		return nil, liquidError
	end
	return {
		connector = connector,
		metadata = metadata,
		liquidKind = liquidKind,
		isInput = booleanValue(metadata, "Input"),
		isOutput = booleanValue(metadata, "Output"),
	}
end

local function summarizeCompatiblePairs(pairs)
	local labels = {}
	for index, pair in ipairs(pairs) do
		if index > 8 then
			table.insert(labels, "...")
			break
		end
		table.insert(labels, pair.from.connector.Name .. " -> " .. pair.to.connector.Name)
	end
	return table.concat(labels, ", ")
end

local function resolveAutoRoutePorts(route, routeIndex)
	local fromPorts
	local toPorts
	if route.FromConnector then
		local port, portError = autoPortForName(route.FromMachine, route.FromConnector, "source")
		if not port then
			return nil, nil, string.format("route #%d source: %s", routeIndex, portError)
		end
		fromPorts = { port }
	else
		local ports, portsError = autoPipePorts(route.FromMachine)
		if not ports then
			return nil, nil, string.format("route #%d source: %s", routeIndex, portsError)
		end
		fromPorts = {}
		for _, port in ipairs(ports) do
			if not port.isInput then
				table.insert(fromPorts, port)
			end
		end
	end
	if route.ToConnector then
		local port, portError = autoPortForName(route.ToMachine, route.ToConnector, "target")
		if not port then
			return nil, nil, string.format("route #%d target: %s", routeIndex, portError)
		end
		toPorts = { port }
	else
		local ports, portsError = autoPipePorts(route.ToMachine)
		if not ports then
			return nil, nil, string.format("route #%d target: %s", routeIndex, portsError)
		end
		toPorts = {}
		for _, port in ipairs(ports) do
			if not port.isOutput then
				table.insert(toPorts, port)
			end
		end
	end

	local pairs = {}
	for _, fromPort in ipairs(fromPorts) do
		for _, toPort in ipairs(toPorts) do
			if fromPort.liquidKind == toPort.liquidKind
				and connectorNamesCompatible(
					"Pipe",
					fromPort.connector.Name,
					toPort.connector.Name
				)
			then
				table.insert(pairs, { from = fromPort, to = toPort })
			end
		end
	end
	if #pairs == 0 then
		return nil, nil, string.format(
			"route #%d has no direction/liquid-compatible connector pair between machine #%d and #%d",
			routeIndex,
			route.FromMachine,
			route.ToMachine
		)
	elseif #pairs > 1 then
		return nil, nil, string.format(
			"route #%d is ambiguous (%s). Use { %d, %q, %d, %q } with the exact holes",
			routeIndex,
			summarizeCompatiblePairs(pairs),
			route.FromMachine,
			pairs[1].from.connector.Name,
			route.ToMachine,
			pairs[1].to.connector.Name
		)
	end
	return pairs[1].from, pairs[1].to
end

local function strictAutomaticRoutes()
	local outputs = {}
	local inputIndex = {}
	local outputIndex = {}
	local inputOrder = 0
	local outputOrder = 0

	local function genericPipeName(name)
		return name == "Pipe" or string.find(name, "MainPipe", 1, true) ~= nil
	end

	local function summaryFor(index, liquidKind, key)
		local liquid = index[liquidKind]
		if not liquid then
			liquid = {
				all = { count = 0, byMachine = {} },
				generic = { count = 0, byMachine = {} },
				byName = {},
			}
			index[liquidKind] = liquid
		end
		if key == "all" or key == "generic" then
			return liquid[key]
		end
		local summary = liquid.byName[key]
		if not summary then
			summary = { count = 0, byMachine = {} }
			liquid.byName[key] = summary
		end
		return summary
	end

	local function addToSummary(summary, port)
		summary.count += 1
		summary.byMachine[port.machine] = (summary.byMachine[port.machine] or 0) + 1
		if not summary.first then
			summary.first = port
		elseif summary.first.machine ~= port.machine and not summary.firstOtherMachine then
			summary.firstOtherMachine = port
		end
	end

	local function indexPort(index, port)
		addToSummary(summaryFor(index, port.liquidKind, "all"), port)
		if genericPipeName(port.connector.Name) then
			addToSummary(summaryFor(index, port.liquidKind, "generic"), port)
		else
			addToSummary(summaryFor(index, port.liquidKind, port.connector.Name), port)
		end
	end

	local function matchingSummaries(index, port)
		local liquid = index[port.liquidKind]
		if not liquid then
			return nil, nil
		elseif genericPipeName(port.connector.Name) then
			return liquid.all, nil
		end
		return liquid.generic, liquid.byName[port.connector.Name]
	end

	local function summaryCountExcluding(summary, machine)
		return summary and summary.count - (summary.byMachine[machine] or 0) or 0
	end

	local function summaryFirstExcluding(summary, machine)
		if not summary or not summary.first then
			return nil
		elseif summary.first.machine ~= machine then
			return summary.first
		end
		return summary.firstOtherMachine
	end

	local function matchStats(index, port)
		local firstSummary, secondSummary = matchingSummaries(index, port)
		local count = summaryCountExcluding(firstSummary, port.machine)
			+ summaryCountExcluding(secondSummary, port.machine)
		local first = summaryFirstExcluding(firstSummary, port.machine)
		local second = summaryFirstExcluding(secondSummary, port.machine)
		if second and (not first or second.automaticOrder < first.automaticOrder) then
			first = second
		end
		return count, first
	end

	for machineIndex = 1, #State.previews do
		local ports, portsError = autoPipePorts(machineIndex)
		if not ports then
			return nil, portsError
		end
		for _, port in ipairs(ports) do
			port.machine = machineIndex
			if port.isOutput and not port.isInput then
				outputOrder += 1
				port.automaticOrder = outputOrder
				table.insert(outputs, port)
				indexPort(outputIndex, port)
			elseif port.isInput and not port.isOutput then
				inputOrder += 1
				port.automaticOrder = inputOrder
				indexPort(inputIndex, port)
			end
		end
	end

	local routes = {}
	local ambiguities = {}
	for _, output in ipairs(outputs) do
		local matchCount, firstMatch = matchStats(inputIndex, output)
		local targetMatchCount = firstMatch and select(1, matchStats(outputIndex, firstMatch)) or 0
		if matchCount == 1 and targetMatchCount == 1 then
			table.insert(routes, {
				FromMachine = output.machine,
				ToMachine = firstMatch.machine,
				FromConnector = output.connector.Name,
				ToConnector = firstMatch.connector.Name,
			})
		elseif matchCount > 1 then
			table.insert(ambiguities, string.format("machine #%d.%s has %d possible targets", output.machine, output.connector.Name, matchCount))
		elseif matchCount == 1 and targetMatchCount > 1 then
			table.insert(ambiguities, string.format(
				"machine #%d.%s shares target #%d.%s with %d possible sources",
				output.machine,
				output.connector.Name,
				firstMatch.machine,
				firstMatch.connector.Name,
				targetMatchCount
			))
		end
	end
	if #ambiguities > 0 then
		return nil, "automatic topology is ambiguous: " .. table.concat(ambiguities, "; ")
			.. ". Add compact AutoPlumb routes to state the intended machine pairs."
	end
	return routes
end

local function endpointCells(connector, liquidKind, obstacles, reserved, availabilityCache)
	local centerX = snapPipeGridCoordinate(connector.Position.X)
	local centerZ = snapPipeGridCoordinate(connector.Position.Z)
	local candidates = {}
	local connectorModel = connector:FindFirstAncestorOfClass("Model")
	local connectorBase = connectorModel and connectorModel:FindFirstChild("Base")
	local outward
	if connectorBase and connectorBase:IsA("BasePart") then
		local vector = Vector2.new(
			connector.Position.X - connectorBase.Position.X,
			connector.Position.Z - connectorBase.Position.Z
		)
		if vector.Magnitude > 0.05 then
			outward = vector.Unit
		end
	end
	for x = centerX - 6, centerX + 6, Config.PipeGrid do
		for z = centerZ - 6, centerZ + 6, Config.PipeGrid do
			local connectorToCell = Vector2.new(x - connector.Position.X, z - connector.Position.Z)
			-- Force the first node to the visible/outward side of the machine Base.
			-- This is the furnace/molder safeguard: a mathematically close grid cell
			-- behind the model is not a valid approach to its front-facing hole.
			local outwardFacing = not outward or connectorToCell:Dot(outward) >= -Config.EdgeEpsilon
			if outwardFacing then
				local nodePosition = routeNodePosition(liquidKind, x, z)
				if nodePosition then
					local distance = (nodePosition - connector.Position).Magnitude
					if distance <= Config.AutoPlumbEndpointRange + Config.EdgeEpsilon
						and routeCellAvailable(x, z, obstacles, reserved, availabilityCache)
					then
						table.insert(candidates, { x = x, z = z, distance = distance })
					end
				end
			end
		end
	end
	table.sort(candidates, function(first, second)
		if math.abs(first.distance - second.distance) > 0.000001 then
			return first.distance < second.distance
		elseif first.x ~= second.x then
			return first.x < second.x
		end
		return first.z < second.z
	end)
	while #candidates > Config.AutoPlumbMaxEndpointCandidates do
		table.remove(candidates)
	end
	return candidates
end

local function heapBefore(first, second)
	if math.abs(first.score - second.score) > 0.000001 then
		return first.score < second.score
	elseif math.abs(first.cost - second.cost) > 0.000001 then
		return first.cost < second.cost
	end
	return first.key < second.key
end

local function heapPush(heap, value)
	table.insert(heap, value)
	local index = #heap
	while index > 1 do
		local parent = math.floor(index / 2)
		if not heapBefore(value, heap[parent]) then
			break
		end
		heap[index] = heap[parent]
		index = parent
	end
	heap[index] = value
end

local function heapPop(heap)
	local count = #heap
	if count == 0 then
		return nil
	end
	local root = heap[1]
	local last = table.remove(heap)
	if count > 1 then
		local index = 1
		while true do
			local left = index * 2
			if left >= count then
				break
			end
			local right = left + 1
			local child = right < count and heapBefore(heap[right], heap[left]) and right or left
			if not heapBefore(heap[child], last) then
				break
			end
			heap[index] = heap[child]
			index = child
		end
		heap[index] = last
	end
	return root
end

local ROUTE_DIRECTIONS = {
	{ x = 2, z = 0, id = 1 },
	{ x = -2, z = 0, id = 2 },
	{ x = 0, z = 2, id = 3 },
	{ x = 0, z = -2, id = 4 },
}

Runtime.PipeOppositeDirections = {
	E = "W",
	W = "E",
	N = "S",
	S = "N",
}

local function routeHeuristic(x, z, goals)
	local best = math.huge
	for _, goal in ipairs(goals) do
		best = math.min(best, math.abs(goal.x - x) + math.abs(goal.z - z))
	end
	return best
end

local function findPipePath(starts, goals, obstacles, reserved, availabilityCache, expectedPreviewEpoch)
	availabilityCache = availabilityCache or {}
	local goalCells = {}
	local minimumX = math.huge
	local maximumX = -math.huge
	local minimumZ = math.huge
	local maximumZ = -math.huge
	for _, cell in ipairs(starts) do
		minimumX = math.min(minimumX, cell.x)
		maximumX = math.max(maximumX, cell.x)
		minimumZ = math.min(minimumZ, cell.z)
		maximumZ = math.max(maximumZ, cell.z)
	end
	for _, cell in ipairs(goals) do
		goalCells[routeCellKey(cell.x, cell.z)] = true
		minimumX = math.min(minimumX, cell.x)
		maximumX = math.max(maximumX, cell.x)
		minimumZ = math.min(minimumZ, cell.z)
		maximumZ = math.max(maximumZ, cell.z)
	end
	minimumX -= Config.AutoPlumbSearchMargin
	maximumX += Config.AutoPlumbSearchMargin
	minimumZ -= Config.AutoPlumbSearchMargin
	maximumZ += Config.AutoPlumbSearchMargin

	local heap = {}
	local bestScore = {}
	local nodes = {}
	for _, start in ipairs(starts) do
		local key = routeStateKey(start.x, start.z, 0)
		local cost = start.distance * 0.05
		bestScore[key] = cost
		nodes[key] = { x = start.x, z = start.z, direction = 0, parent = nil }
		heapPush(heap, {
			key = key,
			x = start.x,
			z = start.z,
			direction = 0,
			cost = cost,
			score = cost + routeHeuristic(start.x, start.z, goals),
		})
	end

	local visited = 0
	while #heap > 0 do
		local current = heapPop(heap)
		if current.cost ~= bestScore[current.key] then
			continue
		end
		visited += 1
		if visited > Config.AutoPlumbMaxVisited then
			return nil, string.format("route search exceeded %d cells", Config.AutoPlumbMaxVisited)
		end
		if visited % Config.AutoPlumbSearchYieldEvery == 0 then
			RunService.Heartbeat:Wait()
			if State.destroyed
				or (expectedPreviewEpoch ~= nil and State.previewEpoch ~= expectedPreviewEpoch)
			then
				return nil, "route search cancelled because Preview changed or the script was destroyed"
			end
		end
		if goalCells[routeCellKey(current.x, current.z)] then
			local path = {}
			local cursor = current.key
			while cursor do
				local node = nodes[cursor]
				table.insert(path, { x = node.x, z = node.z })
				cursor = node.parent
			end
			for firstIndex = 1, math.floor(#path * 0.5) do
				local secondIndex = #path - firstIndex + 1
				path[firstIndex], path[secondIndex] = path[secondIndex], path[firstIndex]
			end
			return path, nil, visited
		end

		for _, direction in ipairs(ROUTE_DIRECTIONS) do
			local x = current.x + direction.x
			local z = current.z + direction.z
			if x < minimumX or x > maximumX or z < minimumZ or z > maximumZ then
				continue
			end
			local cellKey = routeCellKey(x, z)
			local available = availabilityCache[cellKey]
			if available == nil then
				available = routeCellAvailable(x, z, obstacles, reserved, availabilityCache)
			end
			if not available then
				continue
			end
			local bend = current.direction ~= 0 and current.direction ~= direction.id
			local cost = current.cost + Config.PipeGrid + (bend and Config.AutoPlumbBendPenalty or 0)
			local key = routeStateKey(x, z, direction.id)
			if bestScore[key] == nil or cost < bestScore[key] then
				bestScore[key] = cost
				nodes[key] = {
					x = x,
					z = z,
					direction = direction.id,
					parent = current.key,
				}
				heapPush(heap, {
					key = key,
					x = x,
					z = z,
					direction = direction.id,
					cost = cost,
					score = cost + routeHeuristic(x, z, goals),
				})
			end
		end
	end
	return nil, "no collision-free pipe-grid path was found"
end

local function cardinalDirection(fromX, fromZ, toX, toZ)
	local deltaX = toX - fromX
	local deltaZ = toZ - fromZ
	if math.abs(deltaX) >= math.abs(deltaZ) and math.abs(deltaX) > 0.001 then
		return deltaX > 0 and "E" or "W"
	elseif math.abs(deltaZ) > 0.001 then
		return deltaZ > 0 and "S" or "N"
	end
	return nil
end

local function pipePieceForPath(path, index, fromConnector, toConnector, family)
	local current = path[index]
	local previous = path[index - 1]
	local following = path[index + 1]
	local firstDirection = previous
		and cardinalDirection(current.x, current.z, previous.x, previous.z)
		or cardinalDirection(current.x, current.z, fromConnector.Position.X, fromConnector.Position.Z)
	local secondDirection = following
		and cardinalDirection(current.x, current.z, following.x, following.z)
		or cardinalDirection(current.x, current.z, toConnector.Position.X, toConnector.Position.Z)
	local name
	local rotation = 0
	if firstDirection and secondDirection
		and Runtime.PipeOppositeDirections[firstDirection] == secondDirection
	then
		name = family.Straight
		rotation = (firstDirection == "E" or firstDirection == "W") and 90 or 0
	elseif firstDirection and secondDirection and firstDirection ~= secondDirection then
		name = family.Turn
		local pair = firstDirection .. secondDirection
		if pair == "WS" or pair == "SW" then
			rotation = 0
		elseif pair == "ES" or pair == "SE" then
			rotation = 90
		elseif pair == "EN" or pair == "NE" then
			rotation = 180
		else
			rotation = 270
		end
	else
		return nil, nil, "route would enter and leave one pipe cell through the same side"
	end
	return name, rotation
end

local function endpointReference(machine, piece, connector)
	return {
		Machine = machine,
		Piece = piece,
		Connector = connector,
	}
end

local function autoEndpointKey(reference)
	return string.format(
		"%s:%s:%s",
		reference.Machine and "M" or "P",
		tostring(reference.Machine or reference.Piece),
		tostring(reference.Connector)
	)
end

local function autoUndirectedPairKey(first, second)
	local firstKey = autoEndpointKey(first)
	local secondKey = autoEndpointKey(second)
	if firstKey > secondKey then
		firstKey, secondKey = secondKey, firstKey
	end
	return firstKey .. "|" .. secondKey
end

local function plannedPipeConnectorPosition(name, x, z, worldRotation)
	local template, templateError = resolveTemplate({ Category = "Pipes", Name = name })
	if not template then
		return nil, templateError
	end
	local offset = State.plannedPipeConnectorOffsetCache[template]
	if not offset then
		local connector, connectorError = findNamedConnector(template, "PipeA")
		if not connector then
			return nil, connectorError
		end
		offset = template:GetPivot():PointToObjectSpace(connector.Position)
		State.plannedPipeConnectorOffsetCache[template] = offset
	end
	local target = CFrame.new(x, Config.PlacementY, z)
		* CFrame.Angles(0, math.rad(worldRotation), 0)
	return target:PointToWorldSpace(offset)
end

local function appendAutoRoute(route, routeIndex, fromPort, toPort, path, reserved)
	if #AuthoredPlumbing + #path > Config.MaxSavedPlumbingPieces then
		return false, string.format(
			"route #%d would exceed the %d physical-piece safety cap",
			routeIndex,
			Config.MaxSavedPlumbingPieces
		)
	elseif #AuthoredPipeLinks + #path + 1 > Config.MaxConnections then
		return false, string.format(
			"route #%d would exceed the %d pipe-link safety cap",
			routeIndex,
			Config.MaxConnections
		)
	end
	local plannedPieces = {}
	local family = autoPipeFamily(fromPort.liquidKind)
	for pathIndex, cell in ipairs(path) do
		local name, worldRotation, topologyError = pipePieceForPath(
			path,
			pathIndex,
			fromPort.connector,
			toPort.connector,
			family
		)
		if not name then
			return false, string.format("route #%d %s", routeIndex, tostring(topologyError))
		end
		local relativeX, relativeZ = blueprintOffsetFromWorld(cell.x, cell.z)
		local connectorPosition, connectorError = plannedPipeConnectorPosition(
			name,
			cell.x,
			cell.z,
			worldRotation
		)
		if not connectorPosition then
			return false, string.format("route #%d cannot inspect %s: %s", routeIndex, name, connectorError)
		end
		table.insert(plannedPieces, {
			cell = cell,
			connectorPosition = connectorPosition,
			entry = {
				Category = "Pipes",
				Name = name,
				X = relativeX,
				Z = relativeZ,
				Rotation = ((worldRotation - State.layoutRotation) % 360 + 360) % 360,
			},
		})
	end

	local previousPosition = fromPort.connector.Position
	for pieceOffset, planned in ipairs(plannedPieces) do
		local distance = (previousPosition - planned.connectorPosition).Magnitude
		if distance > Config.PipeBindRange + Config.EdgeEpsilon then
			return false, string.format(
				"route #%d selected %s piece #%d at an exact %.3f-stud bind (maximum %.2f)",
				routeIndex,
				planned.entry.Name,
				pieceOffset,
				distance,
				Config.PipeBindRange
			)
		end
		previousPosition = planned.connectorPosition
	end
	local finalDistance = (previousPosition - toPort.connector.Position).Magnitude
	if finalDistance > Config.PipeBindRange + Config.EdgeEpsilon then
		return false, string.format(
			"route #%d reaches %s with an exact %.3f-stud bind (maximum %.2f)",
			routeIndex,
			toPort.connector.Name,
			finalDistance,
			Config.PipeBindRange
		)
	end

	local generatedPieceIndexes = {}
	for _, planned in ipairs(plannedPieces) do
		local pieceIndex = #AuthoredPlumbing + 1
		table.insert(AuthoredPlumbing, planned.entry)
		table.insert(generatedPieceIndexes, pieceIndex)
		reserved[routeCellKey(planned.cell.x, planned.cell.z)] = routeIndex
	end

	local previousReference = endpointReference(route.FromMachine, nil, fromPort.connector.Name)
	for _, pieceIndex in ipairs(generatedPieceIndexes) do
		local pieceReference = endpointReference(nil, pieceIndex, "PipeA")
		table.insert(AuthoredPipeLinks, {
			From = previousReference,
			To = pieceReference,
		})
		previousReference = pieceReference
	end
	table.insert(AuthoredPipeLinks, {
		From = previousReference,
		To = endpointReference(route.ToMachine, nil, toPort.connector.Name),
	})
	return true
end

local function routeCandidatePairs(starts, goals)
	local pairs = {}
	for _, start in ipairs(starts) do
		for _, goal in ipairs(goals) do
			table.insert(pairs, {
				start = start,
				goal = goal,
				score = start.distance + goal.distance
					+ math.abs(start.x - goal.x) + math.abs(start.z - goal.z),
			})
		end
	end
	table.sort(pairs, function(first, second)
		if math.abs(first.score - second.score) > 0.000001 then
			return first.score < second.score
		elseif first.start.x ~= second.start.x then
			return first.start.x < second.start.x
		elseif first.start.z ~= second.start.z then
			return first.start.z < second.start.z
		elseif first.goal.x ~= second.goal.x then
			return first.goal.x < second.goal.x
		end
		return first.goal.z < second.goal.z
	end)
	while #pairs > Config.AutoPlumbMaxPairAttempts do
		table.remove(pairs)
	end
	return pairs
end

setAutoPlumbQuality = function(quality, silent)
	quality = tostring(quality or "")
	if quality ~= "Good" and quality ~= "Rusty" then
		local message = "Auto-Plumb quality must be Good or Rusty."
		if not silent then
			notify("Invalid pipe quality", message, 6)
		end
		return false, message
	elseif State.building then
		local message = "Wait for the current build to finish before changing pipe quality."
		if not silent then
			notify("Pipe quality unchanged", message, 6)
		end
		return false, message
	end
	if State.autoPlumbQuality ~= quality then
		State.autoPlumbQuality = quality
		clearPreview()
		State.autoPlumbSummary = quality .. " pipes selected; Preview will recalculate every route."
	end
	if not silent then
		notify("Auto-Plumb: " .. quality, quality == "Good"
			and "Using the faster Tier-3 physical pipe family."
			or "Using the cheapest rusty physical pipe family.", 5)
	end
	return true
end

function Runtime.setAutoPlumbEnabled(enabled, silent)
	if State.building then
		return false, "Wait for the current build to finish before changing Auto-Plumb."
	end
	local nextMode = enabled == true and "Automatic" or "Off"
	if State.autoPlumbMode ~= nextMode then
		State.autoPlumbMode = nextMode
		clearPreview()
		State.autoPlumbSummary = nextMode == "Automatic"
			and "Smart Auto-Plumb will calculate unambiguous routes during Preview."
			or "Auto-Plumb is off; only plumbing already present in the JSON will be replayed."
	end
	if not silent then
		notify(
			"Auto-Plumb " .. (nextMode == "Automatic" and "on" or "off"),
			State.autoPlumbSummary,
			6
		)
	end
	return true, nextMode
end

function Runtime.setSmartTurnEnabled(enabled, silent)
	if State.autoFitInProgress then
		return false, Runtime.autoFitBusyReason()
	end
	State.smartTurnEnabled = enabled == true
	if not silent then
		notify(
			"Smart Turn " .. (State.smartTurnEnabled and "on" or "off"),
			State.smartTurnEnabled
				and "Move Base To Me may rotate the layout to find the nearest safe fit."
				or "Move Base To Me will keep the current rotation.",
			5
		)
	end
	return true, State.smartTurnEnabled
end

function Runtime.setAutoFitClearance(value, silent)
	if State.autoFitInProgress then
		return false, Runtime.autoFitBusyReason()
	end
	local clearance = finiteNumber(value)
	if not clearance or clearance < 0 or clearance > 8 then
		return false, "Auto-fit clearance must be a number from 0 to 8 studs."
	end
	State.autoFitClearance = clearance
	if not silent then
		notify("Auto-fit clearance", string.format("%.2f stud(s).", clearance), 5)
	end
	return true, clearance
end

function Runtime.setGameStyleConnectionPreview(enabled, silent)
	State.gameStyleConnectionPreview = enabled == true
	clearPreview()
	Runtime.clearDuplicatePreview(true)
	if not silent then
		notify(
			"Connection preview",
			State.gameStyleConnectionPreview
				and "Game-style pipe and power decorations are on; live native geometry is cached when available."
				or "Using the lightweight fallback connection lines.",
			6
		)
	end
	return true, State.gameStyleConnectionPreview
end

generateAutoPlumbing = function()
	replaceArray(AuthoredPlumbing, State.sourceAuthoredPlumbing, copyPlacementEntry)
	replaceArray(AuthoredPipeLinks, State.sourceAuthoredPipeLinks, copyPipeLinkEntry)
	State.autoPlumbErrors = {}
	State.autoPlumbGeneratedPlacements = 0
	State.autoPlumbGeneratedLinks = 0
	State.autoPipePortsCache = setmetatable({}, { __mode = "k" })
	if State.autoPlumbMode == "Off" then
		State.autoPlumbSummary = #State.sourceAuthoredPlumbing > 0
			and string.format("Using %d saved physical pipe piece(s); Auto-Plumb is off.", #State.sourceAuthoredPlumbing)
			or "Auto-Plumb is off. Add AutoPlumb routes such as { {1, 2} }."
		return true
	end

	local routes = AutoPlumb
	if State.autoPlumbMode == "Automatic" then
		local automatic, automaticError = strictAutomaticRoutes()
		if not automatic then
			State.autoPlumbErrors = { automaticError }
			State.autoPlumbSummary = automaticError
			return false, automaticError
		end
		routes = automatic
	end
	if #routes == 0 then
		State.autoPlumbSummary = "No compatible Auto-Plumb routes were requested."
		return true
	end

	local obstacles = collectAutoPlumbObstacles()
	local reserved = {}
	local usedMachineEndpoints = {}
	local usedPairs = {}
	for _, link in ipairs(State.sourceAuthoredPipeLinks) do
		usedPairs[autoUndirectedPairKey(link.From, link.To)] = "saved plumbing"
		if link.From.Machine then
			usedMachineEndpoints[autoEndpointKey(link.From)] = "saved plumbing"
		end
		if link.To.Machine then
			usedMachineEndpoints[autoEndpointKey(link.To)] = "saved plumbing"
		end
	end
	local startingPlacementCount = #AuthoredPlumbing
	local startingLinkCount = #AuthoredPipeLinks
	for routeIndex, route in ipairs(routes) do
		if routeIndex == 1 or routeIndex == #routes or routeIndex % Config.ProgressLogEvery == 0 then
			setStatus(string.format("Auto-Plumb • calculating route %d/%d", routeIndex, #routes))
		end
		local fromPort, toPort, portError = resolveAutoRoutePorts(route, routeIndex)
		if not fromPort then
			table.insert(State.autoPlumbErrors, portError)
			break
		end
		local fromReference = endpointReference(route.FromMachine, nil, fromPort.connector.Name)
		local toReference = endpointReference(route.ToMachine, nil, toPort.connector.Name)
		local sourceKey = autoEndpointKey(fromReference)
		local targetKey = autoEndpointKey(toReference)
		local pairKey = autoUndirectedPairKey(fromReference, toReference)
		if usedMachineEndpoints[sourceKey] then
			table.insert(State.autoPlumbErrors, string.format(
				"route #%d reuses machine #%d.%s already claimed by %s; branch once through a junction instead",
				routeIndex,
				route.FromMachine,
				fromPort.connector.Name,
				usedMachineEndpoints[sourceKey]
			))
			break
		elseif usedMachineEndpoints[targetKey] then
			table.insert(State.autoPlumbErrors, string.format(
				"route #%d reuses %s.%s already claimed by %s",
				routeIndex,
				"machine #" .. tostring(route.ToMachine),
				toPort.connector.Name,
				usedMachineEndpoints[targetKey]
			))
			break
		elseif usedPairs[pairKey] then
			table.insert(State.autoPlumbErrors, string.format(
				"route #%d duplicates a pair already present in %s",
				routeIndex,
				usedPairs[pairKey]
			))
			break
		end
		local directDistance = (fromPort.connector.Position - toPort.connector.Position).Magnitude
		if directDistance <= Config.PipeBindRange + Config.EdgeEpsilon then
			local appended, appendError = appendAutoRoute(route, routeIndex, fromPort, toPort, {}, reserved)
			if not appended then
				table.insert(State.autoPlumbErrors, appendError)
				break
			end
			usedMachineEndpoints[sourceKey] = "AutoPlumb route #" .. routeIndex
			usedMachineEndpoints[targetKey] = "AutoPlumb route #" .. routeIndex
			usedPairs[pairKey] = "AutoPlumb route #" .. routeIndex
			continue
		end
		-- One bounded cache serves both endpoints and every exact start/goal retry.
		-- Reservations are checked separately and never cached; a fresh table per
		-- route also keeps memory bounded near this route's A* search size.
		local availabilityCache = {}
		local starts = endpointCells(
			fromPort.connector,
			fromPort.liquidKind,
			obstacles,
			reserved,
			availabilityCache
		)
		local goals = endpointCells(
			toPort.connector,
			toPort.liquidKind,
			obstacles,
			reserved,
			availabilityCache
		)
		if #starts == 0 or #goals == 0 then
			local message = string.format(
				"route #%d cannot attach a %s pipe-grid cell within %.2f studs of %s%s",
				routeIndex,
				fromPort.liquidKind:lower(),
				Config.AutoPlumbEndpointRange,
				#starts == 0 and ("source " .. fromPort.connector.Name) or ("target " .. toPort.connector.Name),
				"; the port may be elevated, inside its Base, or blocked"
			)
			table.insert(State.autoPlumbErrors, message)
			break
		end
		local appended = false
		local appendError
		local pathError
		for _, pair in ipairs(routeCandidatePairs(starts, goals)) do
			local path
			path, pathError = findPipePath(
				{ pair.start },
				{ pair.goal },
				obstacles,
				reserved,
				availabilityCache,
				State.activePreviewEpoch
			)
			if not path then
				continue
			end
			appended, appendError = appendAutoRoute(route, routeIndex, fromPort, toPort, path, reserved)
			if appended then
				break
			end

			-- A* operates on grid cells, then the exact rotated template connector
			-- is probed before commit. Topology or real-connector misses retry only
			-- this start/goal pair, preserving every other valid combination.
			local retryable = string.find(appendError, "same side", 1, true)
				or string.find(appendError, "exact", 1, true)
				or string.find(appendError, "reaches", 1, true)
			if not retryable then
				break
			end
		end
		if not appended then
			local message = appendError or (pathError and string.format("route #%d: %s", routeIndex, pathError))
				or string.format("route #%d could not produce an exact physical route", routeIndex)
			table.insert(State.autoPlumbErrors, message)
			break
		end
		usedMachineEndpoints[sourceKey] = "AutoPlumb route #" .. routeIndex
		usedMachineEndpoints[targetKey] = "AutoPlumb route #" .. routeIndex
		usedPairs[pairKey] = "AutoPlumb route #" .. routeIndex
	end

	if #State.autoPlumbErrors > 0 then
		-- Never leave a half-generated network in the build arrays.
		replaceArray(AuthoredPlumbing, State.sourceAuthoredPlumbing, copyPlacementEntry)
		replaceArray(AuthoredPipeLinks, State.sourceAuthoredPipeLinks, copyPipeLinkEntry)
		State.autoPlumbSummary = table.concat(State.autoPlumbErrors, " | ")
		return false, State.autoPlumbSummary
	end
	State.autoPlumbGeneratedPlacements = #AuthoredPlumbing - startingPlacementCount
	State.autoPlumbGeneratedLinks = #AuthoredPipeLinks - startingLinkCount
	State.autoPlumbSummary = string.format(
		"%s Auto-Plumb ready • %d route(s) • %d physical piece(s) • %d exact bind(s)",
		State.autoPlumbQuality,
		#routes,
		State.autoPlumbGeneratedPlacements,
		State.autoPlumbGeneratedLinks
	)
	log(State.autoPlumbSummary)
	return true
end

function Runtime.normalizeConnectorPath(source, label)
	if source == nil then
		return nil
	elseif type(source) ~= "table" then
		return nil, label .. " must be an array"
	end
	local count, arrayError = denseArrayCount(source, label, Config.MaxConnectorPathSegments)
	if arrayError then
		return nil, arrayError
	elseif count == 0 then
		return nil, label .. " must not be empty"
	end
	local path = {}
	for index, segment in ipairs(source) do
		if type(segment) ~= "table" then
			return nil, string.format("%s #%d must be a table", label, index)
		end
		local name = trimmed(segment.Name)
		local className
		if segment.ClassName ~= nil then
			className = trimmed(segment.ClassName)
		end
		local ordinal = finiteNumber(segment.Ordinal)
		if name == "" then
			return nil, string.format("%s #%d needs Name", label, index)
		elseif className ~= nil and className == "" then
			return nil, string.format("%s #%d ClassName must be non-empty when provided", label, index)
		elseif not ordinal or ordinal < 1 or ordinal % 1 ~= 0 then
			return nil, string.format("%s #%d Ordinal must be a positive integer", label, index)
		end
		table.insert(path, {
			Name = name,
			ClassName = className,
			Ordinal = ordinal,
		})
	end
	return path
end

local function normalizeEndpoint(reference, label, machineCount, pieceCount, allowPiece)
	if type(reference) ~= "table" then
		return nil, label .. " must be a table"
	end
	local machine = finiteNumber(reference.Machine)
	local piece = finiteNumber(reference.Piece)
	if machine and (machine < 1 or machine % 1 ~= 0) then
		return nil, label .. ".Machine must be a positive integer"
	elseif piece and (piece < 1 or piece % 1 ~= 0) then
		return nil, label .. ".Piece must be a positive integer"
	elseif (machine ~= nil) == (piece ~= nil) then
		return nil, label .. " needs exactly one Machine or Piece index"
	elseif piece and not allowPiece then
		return nil, label .. " cannot use Piece for a wire"
	elseif machine and machine > machineCount then
		return nil, string.format("%s references missing machine #%d", label, machine)
	elseif piece and piece > pieceCount then
		return nil, string.format("%s references missing plumbing piece #%d", label, piece)
	end
	local connector = trimmed(reference.Connector)
	if connector == "" then
		return nil, label .. ".Connector must be a non-empty string"
	end
	local connectorPath, pathError = Runtime.normalizeConnectorPath(
		reference.ConnectorPath or reference.Path,
		label .. ".ConnectorPath"
	)
	if pathError then
		return nil, pathError
	end
	return {
		Machine = machine,
		Piece = piece,
		Connector = connector,
		ConnectorPath = connectorPath,
	}
end

local function normalizeConnectionList(source, label, machineCount, pieceCount, allowPiece)
	if source == nil then
		return {}
	elseif type(source) ~= "table" then
		return nil, label .. " must be an array"
	end
	local _, arrayError = denseArrayCount(source, label, Config.MaxConnections)
	if arrayError then
		return nil, arrayError
	end
	local result = {}
	for index, entry in ipairs(source) do
		if type(entry) ~= "table" then
			return nil, string.format("%s #%d must be a table", label, index)
		end
		local from, fromError = normalizeEndpoint(
			entry.From,
			string.format("%s #%d From", label, index),
			machineCount,
			pieceCount,
			allowPiece
		)
		if not from then
			return nil, fromError
		end
		local to, toError = normalizeEndpoint(
			entry.To,
			string.format("%s #%d To", label, index),
			machineCount,
			pieceCount,
			allowPiece
		)
		if not to then
			return nil, toError
		end
		table.insert(result, { From = from, To = to })
	end
	return result
end

updateBlueprintParagraph = function(extra)
	local loadState
	if State.blueprintDirty then
		loadState = "Paste changed; press Preview or Build to load it."
	elseif State.blueprintLoaded then
		loadState = string.format(
			"Loaded: %d machine(s), %d saved pipe piece(s), %d saved pipe link(s), %d wire(s). Auto-Plumb: %s.",
			#Blueprint,
			#State.sourceAuthoredPlumbing,
			#State.sourceAuthoredPipeLinks,
			#Wiring,
			State.autoPlumbMode
		)
	else
		loadState = "No blueprint loaded."
	end
	local scanState = State.captureArmed and "Scan armed."
		or State.scanComplete and (State.captureRemembered
			and "Remembered placement scan ready."
			or "Placement scan ready.")
		or State.captured and (
			State.blueprintLoaded and not State.blueprintDirty
				and "Scan does not match; press Scan and place the first entry again."
				or "Scan captured; load the paste to calibrate it."
			)
			or "Placement scan still required before Build."
	local workCounts = Runtime.buildWorkCounts()
	local previewState = workCounts.total == 0 and "not created"
		or workCounts.remaining == 0 and "complete"
		or State.validated and "valid"
		or "needs recheck"
	setParagraph(
		State.blueprintParagraph,
		"Blueprint status",
		string.format(
			"%s %s Preview: %s • remaining %d/%d. Base X %.0f, Z %.0f • rotation %d° • delay %.2fs.%s",
			loadState,
			scanState,
			previewState,
			workCounts.remaining,
			workCounts.total,
			State.originX,
			State.originZ,
			State.layoutRotation,
			State.delaySeconds,
			extra and (" " .. extra) or ""
		)
	)
end

local function loadBlueprintText(source, silent, options)
	local function reject(message, title)
		if not silent then
			notify(title or "Blueprint rejected", message, 10)
		end
		return false, message
	end

	options = type(options) == "table" and options or {}
	local requireFreshScan = options.RequireFreshScan == true
	if State.building then
		return reject("A blueprint build is currently running.", "Cannot load blueprint")
	elseif State.autoFitInProgress then
		return reject(Runtime.autoFitBusyReason(), "Cannot load blueprint")
	elseif State.captureProcessing then
		return reject("Wait for the current scanned placement to finish checking.", "Cannot load blueprint")
	elseif State.captureArmed then
		return reject("Finish or cancel the armed placement Scan before loading a blueprint.", "Cannot load blueprint")
	end
	source = trimmed(source)
	if source == "" then
		return reject("Paste a blueprint first.", "No blueprint pasted")
	elseif #source > Config.MaxBlueprintTextBytes then
		return reject("Blueprint text is larger than 500 KB.")
	end

	local decoded, formatOrError = decodeBlueprintText(source)
	if not decoded then
		return reject(formatOrError)
	end

	local machineSource = decoded.Blueprint or decoded.Machines
	if not machineSource and decoded[1] ~= nil then
		-- Compact documents may keep machines in the numeric array while placing
		-- AutoPlumb/PipeQuality beside them as named metadata fields.
		local numericCount = 0
		local highestNumericIndex = 0
		for key in pairs(decoded) do
			if type(key) == "number" then
				if key < 1 or key % 1 ~= 0 then
					return reject("Top-level machine keys must be positive integers")
				end
				numericCount += 1
				highestNumericIndex = math.max(highestNumericIndex, key)
			end
		end
		if numericCount ~= highestNumericIndex then
			return reject("Top-level compact machine array must be dense")
		end
		machineSource = {}
		for index = 1, highestNumericIndex do
			table.insert(machineSource, decoded[index])
		end
	end
	local plumbingSource = decoded.AuthoredPlumbing or decoded.Pipes or {}
	local pipeLinkSource = decoded.AuthoredPipeLinks or decoded.Plumbing or decoded.PipeLinks or {}
	local wiringSource = decoded.Wiring or decoded.Wires or {}
	local autoPlumbSource = decoded.AutoPlumb
	if autoPlumbSource == nil then
		autoPlumbSource = decoded.SmartPlumbing
	end

	local machines, machineError = normalizePlacementList(machineSource or {}, "Blueprint machine", "Machine")
	if not machines then
		return reject(machineError)
	end
	local plumbing, plumbingError = normalizePlacementList(plumbingSource, "Plumbing placement", "Plumbing")
	if not plumbing then
		return reject(plumbingError)
	elseif #machines == 0 and #plumbing == 0 then
		return reject("Blueprint has no machines or plumbing placements.")
	end
	local pipeLinks, pipeLinkError = normalizeConnectionList(
		pipeLinkSource,
		"Pipe link",
		#machines,
		#plumbing,
		true
	)
	if not pipeLinks then
		return reject(pipeLinkError)
	end
	local wires, wiringError = normalizeConnectionList(
		wiringSource,
		"Wire",
		#machines,
		#plumbing,
		false
	)
	if not wires then
		return reject(wiringError)
	end
	local autoRoutes, autoMarker, autoError = normalizeAutoPlumbList(autoPlumbSource, #machines)
	if not autoRoutes then
		return reject(autoError)
	end
	local autoMode
	if autoMarker == false then
		autoMode = "Off"
	elseif autoMarker == true then
		autoMode = "Automatic"
	elseif autoMarker == "Routes" then
		autoMode = "Routes"
	else
		-- Missing AutoPlumb is intentionally off. Pipe metadata identifies only
		-- item-vs-fluid, not recipes or materials, so old machine-only blueprints
		-- must never gain surprise purchases or guessed material links.
		autoMode = "Off"
	end
	local requestedQuality = trimmed(decoded.PipeQuality)
	if requestedQuality ~= "" then
		if requestedQuality ~= "Good" and requestedQuality ~= "Rusty" then
			return reject("PipeQuality must be Good or Rusty")
		end
		State.autoPlumbQuality = requestedQuality
	end

	clearPreview()
	replaceArray(Blueprint, machines, copyPlacementEntry)
	replaceArray(State.sourceAuthoredPlumbing, plumbing, copyPlacementEntry)
	replaceArray(State.sourceAuthoredPipeLinks, pipeLinks, copyPipeLinkEntry)
	replaceArray(AuthoredPlumbing, State.sourceAuthoredPlumbing, copyPlacementEntry)
	replaceArray(AuthoredPipeLinks, State.sourceAuthoredPipeLinks, copyPipeLinkEntry)
	replaceArray(Wiring, wires, copyPipeLinkEntry)
	replaceArray(AutoPlumb, autoRoutes, copyAutoPlumbRoute)
	State.autoPlumbMode = autoMode
	State.autoPlumbErrors = {}
	State.autoPlumbGeneratedPlacements = 0
	State.autoPlumbGeneratedLinks = 0
	State.autoPlumbSummary = autoMode == "Off"
		and "Auto-Plumb is off; saved plumbing will be replayed exactly."
		or autoMode == "Routes"
			and string.format("%d requested route(s) will be calculated during preview.", #AutoPlumb)
			or "Only globally unambiguous output/input matches will be routed; ambiguous layouts need explicit pairs."
	State.blueprintText = source
	State.loadedBlueprintText = source
	State.blueprintLoaded = true
	State.blueprintDirty = false
	State.blueprintRevision += 1
	local scanNote = ""
	if requireFreshScan then
		-- Saved files deliberately contain only blueprint data. Invalidate any
		-- live remote packet atomically at commit time so an invalid file does not
		-- destroy the current session and an old packet cannot move the new origin.
		Runtime.invalidateCapturedPlacement()
		scanNote = " Fresh Scan required."
	elseif State.captured and State.scanComplete and State.scanMode == "PacketOnly" then
		-- A paste edit demotes any old blueprint-entry match to packet-only. Keep
		-- the verified transport usable, but never let it silently move the new
		-- document's Base X/Z.
		scanNote = " Existing verified Scan kept packet-only; Base X/Z unchanged."
	elseif State.captured then
		State.scanComplete = false
		local calibrated, calibrationMessage = calibrateCapturedScan(State.captured)
		if calibrated then
			scanNote = " Scan calibrated. " .. calibrationMessage
		else
			scanNote = " Scan needs to be repeated: " .. calibrationMessage
		end
	end
	updateBlueprintParagraph("Read as " .. formatOrError .. "." .. scanNote)
	if not silent then
		notify(
			"Blueprint loaded",
			string.format(
				"%d machine(s), %d saved pipe piece(s), %d saved pipe link(s), %d wire(s). Auto-Plumb: %s.%s",
				#Blueprint,
				#State.sourceAuthoredPlumbing,
				#State.sourceAuthoredPipeLinks,
				#Wiring,
				State.autoPlumbMode,
				scanNote
			),
			8
		)
	end
	return true, formatOrError
end

local function ensurePastedBlueprintLoaded()
	if State.blueprintLoaded
		and not State.blueprintDirty
		and State.loadedBlueprintText == trimmed(State.blueprintText)
	then
		return true
	end
	local loaded, loadError = loadBlueprintText(State.blueprintText, false)
	if not loaded and loadError then
		updateBlueprintParagraph("Error: " .. loadError)
	end
	return loaded
end

local function setBuildDelaySeconds(value, silent, explicit)
	local delay = finiteNumber(value)
	if not delay or delay < 0 or delay > 30 then
		local message = "Delay must be a number from 0 to 30 seconds."
		if not silent then
			notify("Invalid delay", message, 7)
		end
		return false, message
	end
	Config.PlacementDelay = delay
	Config.ConnectionDelay = delay
	State.delaySeconds = delay
	if explicit ~= false then
		State.delayExplicit = true
	end
	updateBlueprintParagraph()
	if not silent then
		notify("Delay updated", string.format("%.2f second(s) between build actions.", delay), 5)
	end
	return true
end

local function applyLayoutSettings(x, z, rotation, silent, autoFitToken)
	if State.building then
		local message = "A blueprint build is currently running."
		if not silent then
			notify("Location unchanged", message, 6)
		end
		return false, message
	elseif State.autoFitInProgress and not Runtime.autoFitOwns(autoFitToken) then
		local message = Runtime.autoFitBusyReason()
		if not silent then
			notify("Location unchanged", message, 6)
		end
		return false, message
	end

	local parsedX = finiteNumber(x)
	local parsedZ = finiteNumber(z)
	local parsedRotation = finiteNumber(rotation)
	if not parsedX or not parsedZ then
		local message = "Base X and Base Z must both be numbers."
		if not silent then
			notify("Invalid base location", message, 7)
		end
		syncLayoutControls()
		return false, message
	elseif not parsedRotation then
		local message = "Layout rotation must be a number."
		if not silent then
			notify("Invalid layout rotation", message, 7)
		end
		syncLayoutControls()
		return false, message
	end

	local previousX = State.originX
	local previousZ = State.originZ
	local previousRotation = State.layoutRotation
	local snappedX, snappedZ, originAdjusted = setBlueprintOrigin(parsedX, parsedZ)
	local snappedRotation, rotationAdjusted = setLayoutRotation(parsedRotation)
	local changed = math.abs(previousX - snappedX) > 0.0001
		or math.abs(previousZ - snappedZ) > 0.0001
		or previousRotation ~= snappedRotation

	if changed then
		clearPreview()
	end
	syncLayoutControls()
	updateBlueprintParagraph(changed and "Preview cleared for the new transform." or "Transform unchanged.")

	local message = string.format(
		"Base X %.0f, Z %.0f • layout rotation %d°.%s",
		snappedX,
		snappedZ,
		snappedRotation,
		(originAdjusted or rotationAdjusted) and " Values were snapped to the server grid." or ""
	)
	log(message)
	if not silent then
		notify("Layout transform applied", message, 6)
	end
	return true, message
end

-- Executor-local persistence. Blueprint saves contain normalized build intent;
-- the remembered placement profile stores only an allowlisted remote shape.
-- Live Instances, raw arguments, previews, and server objects never enter JSON.
local SAVE_ROOT = "industrialist"
local SAVE_FOLDER = SAVE_ROOT .. "/saves"
local SAVE_FORMAT = "IndustrialistBlueprintSave"
local SAVE_VERSION = 1
Runtime.ExportFolder = SAVE_ROOT .. "/exports"
Runtime.CaptureProfile = {
	Path = SAVE_ROOT .. "/placement_capture.json",
	TempPath = SAVE_ROOT .. "/placement_capture.__tmp.json",
	Format = "IndustrialistPlacementCapture",
	Version = 1,
}

local function executorFileFunction(name)
	local executorEnvironment
	if type(getgenv) == "function" then
		local ok, result = pcall(getgenv)
		if ok and type(result) == "table" then
			executorEnvironment = result
		end
	end
	local candidates = {}
	if type(executorEnvironment) == "table" then
		table.insert(candidates, executorEnvironment)
	end
	table.insert(candidates, _G)
	for _, candidate in ipairs(candidates) do
		if type(candidate) == "table" then
			local ok, value = pcall(function()
				return candidate[name]
			end)
			if ok and type(value) == "function" then
				return value
			end
		end
	end
	return nil
end

local function ensureSaveFolders()
	local makeFolder = executorFileFunction("makefolder")
	local isFolder = executorFileFunction("isfolder")
	local listFiles = executorFileFunction("listfiles")
	local function folderExists(folder)
		if isFolder then
			local checkOK, result = pcall(isFolder, folder)
			if checkOK then
				return result == true
			end
		end
		if listFiles then
			local listOK, result = pcall(listFiles, folder)
			if listOK and type(result) == "table" then
				return true
			end
		end
		return nil
	end
	for _, folder in ipairs({ SAVE_ROOT, SAVE_FOLDER }) do
		local exists = folderExists(folder)
		if exists ~= true and makeFolder then
			local createOK, createError = pcall(makeFolder, folder)
			if not createOK then
				local confirmed = folderExists(folder)
				-- Some executors throw when makefolder targets an existing folder but
				-- do not expose isfolder/listfiles. Continue in that unknown case and
				-- let the later byte-verified read/write prove actual availability.
				if confirmed == false then
					local message = string.format("Could not create %s: %s", folder, tostring(createError))
					State.saveFolderReady = false
					State.saveStatus = message
					return false, message
				end
			end
		elseif exists == false and not makeFolder then
			local message = "This executor does not expose makefolder and " .. folder .. " does not exist."
			State.saveFolderReady = false
			State.saveStatus = message
			return false, message
		end
	end
	State.saveFolder = SAVE_FOLDER
	State.saveFolderReady = true
	State.saveStatus = "Save folder ready: " .. SAVE_FOLDER
	return true, SAVE_FOLDER
end

function Runtime.captureProfileDocument(captured)
	return {
		Format = Runtime.CaptureProfile.Format,
		Version = Runtime.CaptureProfile.Version,
		PlaceId = game.PlaceId,
		GameId = game.GameId,
		Kind = captured.Kind,
		Category = captured.Category,
		Name = captured.Name,
		AutoBuy = captured.AutoBuy == true,
		AutoConnect = captured.AutoConnect == true,
		SavedAtUnix = os.time(),
	}
end

function Runtime.captureRemoteSpec(kind)
	for remote, spec in pairs(REMOTE_SPECS) do
		if spec.Kind == kind then
			return remote, spec
		end
	end
	return nil
end

function Runtime.decodeCaptureProfile(text)
	if type(text) ~= "string" or #text == 0 or #text > 8192 then
		return nil, "remembered placement profile is empty or too large"
	end
	local decodeOK, document = pcall(function()
		return HttpService:JSONDecode(text)
	end)
	if not decodeOK or type(document) ~= "table" then
		return nil, "remembered placement profile is not valid JSON"
	elseif document.Format ~= Runtime.CaptureProfile.Format
		or finiteNumber(document.Version) ~= Runtime.CaptureProfile.Version
	then
		return nil, "remembered placement profile uses an unsupported format"
	elseif finiteNumber(document.PlaceId) ~= game.PlaceId then
		return nil, "remembered placement profile belongs to a different Roblox place"
	end
	local category = trimmed(document.Category)
	local name = trimmed(document.Name)
	local remote, spec = Runtime.captureRemoteSpec(document.Kind)
	if not remote or not spec then
		return nil, "remembered placement profile has an unsupported remote kind"
	end
	local template, templateError = Runtime.resolveCapturedTemplateByName(category, name)
	if not template then
		return nil, "remembered placement template is unavailable: " .. tostring(templateError)
	end
	local target = CFrame.new(0, Config.PlacementY, 0)
	local args
	if document.Kind == "Place" then
		args = table.pack(template, target, nil, document.AutoBuy == true)
	elseif document.Kind == "PlaceBind" then
		args = table.pack(
			template,
			target,
			nil,
			document.AutoBuy == true,
			true,
			document.AutoConnect == true
		)
	elseif document.Kind == "OptimizedPlaceBind" then
		args = table.pack(category, name, target, document.AutoConnect == true, true)
	else
		return nil, "remembered placement profile has an unsupported remote kind"
	end
	return Runtime.decodeCapturedPlacement({
		Remote = remote,
		Method = spec.Method,
		Kind = spec.Kind,
		Args = args,
		Generation = State.captureGeneration,
		PlacedSnapshot = {},
	})
end

function Runtime.rememberCaptureProfile(captured)
	local foldersReady, folderError = ensureSaveFolders()
	if not foldersReady then
		State.captureProfileStatus = tostring(folderError)
		return false, folderError
	end
	local writeFile = executorFileFunction("writefile")
	local readFile = executorFileFunction("readfile")
	local deleteFile = executorFileFunction("delfile")
	if not writeFile or not readFile then
		local message = "writefile/readfile unavailable; the verified Scan is remembered only for this execution"
		State.captureProfileStatus = message
		return false, message
	end
	local encodeOK, json = pcall(function()
		return HttpService:JSONEncode(Runtime.captureProfileDocument(captured))
	end)
	if not encodeOK then
		State.captureProfileStatus = "Could not encode placement profile: " .. tostring(json)
		return false, State.captureProfileStatus
	end
	-- A reinjection can leave an older writefile call in flight. Serialize this
	-- tiny profile transaction through getgenv so the cancelled writer finishes
	-- (and rolls back) before a newer Scan is allowed to replace the same files.
	local fileEnvironment = type(getgenv) == "function" and getgenv() or _G
	local lockDeadline = os.clock() + 5
	while fileEnvironment.__IndustrialistBlueprintCaptureProfileWriteOwner ~= nil
		and os.clock() < lockDeadline
	do
		RunService.Heartbeat:Wait()
	end
	if fileEnvironment.__IndustrialistBlueprintCaptureProfileWriteOwner ~= nil then
		local message = "another placement profile write is still finishing; this verified Scan remains session-only"
		State.captureProfileStatus = message
		return false, message
	elseif not Runtime.captureIsCurrent(captured) or State.destroyed then
		return false, "placement capture changed before its profile could be saved"
	end
	local writeOwner = {}
	fileEnvironment.__IndustrialistBlueprintCaptureProfileWriteOwner = writeOwner
	local function finishProfileWrite(ok, detail)
		if fileEnvironment.__IndustrialistBlueprintCaptureProfileWriteOwner == writeOwner then
			fileEnvironment.__IndustrialistBlueprintCaptureProfileWriteOwner = nil
		end
		return ok, detail
	end
	local function readProfilePath(path)
		local readOK, text = pcall(readFile, path)
		if not readOK then
			return nil, nil, true
		end
		local decodeOK, profile = pcall(Runtime.decodeCaptureProfile, text)
		if not decodeOK then
			return nil, text, false
		end
		return profile, text, true
	end
	local function invalidateProfilePath(path)
		if deleteFile then
			pcall(deleteFile, path)
		end
		local profile, _, safelyDecoded = readProfilePath(path)
		if safelyDecoded and not profile then
			return true
		end
		-- delfile is optional and can itself report success without removing the
		-- file. Tombstone it and prove startup decoding now rejects the contents.
		pcall(writeFile, path, "")
		profile, _, safelyDecoded = readProfilePath(path)
		return safelyDecoded and not profile
	end
	local function restorePreviousFinal(previousText)
		if not previousText then
			return invalidateProfilePath(Runtime.CaptureProfile.Path)
		end
		pcall(writeFile, Runtime.CaptureProfile.Path, previousText)
		local readOK, restoredText = pcall(readFile, Runtime.CaptureProfile.Path)
		return readOK and restoredText == previousText
	end
	local function rollbackStaleProfile(previousText)
		local finalSafe = restorePreviousFinal(previousText)
		local temporarySafe = invalidateProfilePath(Runtime.CaptureProfile.TempPath)
		return finalSafe and temporarySafe
	end
	local temporaryWriteOK, temporaryWriteError = pcall(writeFile, Runtime.CaptureProfile.TempPath, json)
	if not temporaryWriteOK then
		State.captureProfileStatus = "Could not stage placement profile: " .. tostring(temporaryWriteError)
		if not invalidateProfilePath(Runtime.CaptureProfile.TempPath) then
			State.captureProfileStatus ..= "; staged-file cleanup could not be verified"
		end
		return finishProfileWrite(false, State.captureProfileStatus)
	end
	local temporaryProfile, temporaryText, temporaryDecodeSafe = readProfilePath(Runtime.CaptureProfile.TempPath)
	if not temporaryDecodeSafe or not temporaryProfile or temporaryText ~= json then
		local temporarySafe = invalidateProfilePath(Runtime.CaptureProfile.TempPath)
		State.captureProfileStatus = "Staged placement profile failed byte verification"
		if not temporarySafe then
			State.captureProfileStatus ..= "; staged-file cleanup could not be verified"
		end
		return finishProfileWrite(false, State.captureProfileStatus)
	end
	if not Runtime.captureIsCurrent(captured) or State.destroyed then
		local temporarySafe = invalidateProfilePath(Runtime.CaptureProfile.TempPath)
		local message = "placement capture changed while its profile was staged"
		if not temporarySafe then
			message ..= "; stale staged-file cleanup could not be verified"
		end
		return finishProfileWrite(false, message)
	end
	local previousProfile, previousText, previousDecodeSafe = readProfilePath(Runtime.CaptureProfile.Path)
	if not previousDecodeSafe then
		invalidateProfilePath(Runtime.CaptureProfile.TempPath)
		local message = "existing placement profile could not be decoded safely; refusing to replace it"
		State.captureProfileStatus = message
		return finishProfileWrite(false, message)
	end
	if not previousProfile then
		previousText = nil
	end
	if not Runtime.captureIsCurrent(captured) or State.destroyed then
		local temporarySafe = invalidateProfilePath(Runtime.CaptureProfile.TempPath)
		local message = "placement capture changed before its final profile write"
		if not temporarySafe then
			message ..= "; stale staged-file cleanup could not be verified"
		end
		return finishProfileWrite(false, message)
	end
	local finalWriteOK, finalWriteError = pcall(writeFile, Runtime.CaptureProfile.Path, json)
	if not finalWriteOK then
		-- A failed executor write can still have modified the target. Restore and
		-- prove the previous final bytes; retain staged recovery only if this Scan
		-- is still current.
		local finalSafe = restorePreviousFinal(previousText)
		local stale = not Runtime.captureIsCurrent(captured) or State.destroyed
		local temporarySafe = not stale or invalidateProfilePath(Runtime.CaptureProfile.TempPath)
		State.captureProfileStatus = "Could not save placement profile: " .. tostring(finalWriteError)
		if not finalSafe or not temporarySafe then
			State.captureProfileStatus ..= "; rollback could not be verified"
		end
		return finishProfileWrite(false, State.captureProfileStatus)
	end
	local finalProfile, finalText, finalDecodeSafe = readProfilePath(Runtime.CaptureProfile.Path)
	if not finalDecodeSafe or not finalProfile or finalText ~= json then
		local finalSafe = restorePreviousFinal(previousText)
		local stale = not Runtime.captureIsCurrent(captured) or State.destroyed
		local temporarySafe = not stale or invalidateProfilePath(Runtime.CaptureProfile.TempPath)
		State.captureProfileStatus = "Saved placement profile failed byte verification"
		if not finalSafe or not temporarySafe then
			State.captureProfileStatus ..= "; rollback could not be verified"
		end
		return finishProfileWrite(false, State.captureProfileStatus)
	end
	-- Cleanup can yield in executor implementations. Perform it before the last
	-- generation check so a Cancel during cleanup is caught and rolled back.
	local temporaryCleanupSafe = invalidateProfilePath(Runtime.CaptureProfile.TempPath)
	-- File primitives supplied by executors are not guaranteed to be
	-- synchronous. If Cancel/Destroy/reinjection invalidated this packet while
	-- the write yielded, put the previously verified profile back on disk so a
	-- stale Scan can never become the remembered capture.
	if not Runtime.captureIsCurrent(captured) or State.destroyed then
		if not rollbackStaleProfile(previousText) then
			local message = "placement capture changed, but stale profile rollback could not be verified; remove "
				.. Runtime.CaptureProfile.Path
			State.captureProfileStatus = message
			return finishProfileWrite(false, message)
		end
		return finishProfileWrite(false, "placement capture changed while profile was saving")
	end
	State.captureRemembered = true
	State.captureProfileStatus = "Remembered verified placement profile: " .. Runtime.CaptureProfile.Path
	if not temporaryCleanupSafe then
		State.captureProfileStatus ..= " (staged cleanup unavailable; final profile is verified)"
	end
	return finishProfileWrite(true, Runtime.CaptureProfile.Path)
end

function Runtime.restoreCaptureProfile(silent)
	local fileEnvironment = type(getgenv) == "function" and getgenv() or _G
	local readFile = executorFileFunction("readfile")
	if not readFile then
		return false, "readfile is unavailable"
	end
	if fileEnvironment.__IndustrialistBlueprintCaptureProfileWriteOwner ~= nil then
		local message = "a placement profile write is still finishing; retry Restore Remembered Capture shortly"
		State.captureProfileStatus = message
		return false, message
	end
	-- Readers take the same mutex as writers. The check-and-assignment cannot
	-- yield, so no writer can expose transient staged/final bytes while either
	-- readfile call below is suspended by an executor implementation.
	local restoreOwner = {}
	fileEnvironment.__IndustrialistBlueprintCaptureProfileWriteOwner = restoreOwner
	local function finishProfileRestore(ok, detail)
		if fileEnvironment.__IndustrialistBlueprintCaptureProfileWriteOwner == restoreOwner then
			fileEnvironment.__IndustrialistBlueprintCaptureProfileWriteOwner = nil
		end
		return ok, detail
	end
	local captured
	local profileError
	local restoredPath
	for _, path in ipairs({ Runtime.CaptureProfile.Path, Runtime.CaptureProfile.TempPath }) do
		local readOK, text = pcall(readFile, path)
		if readOK then
			local decodeOK, decoded, decodeError = pcall(Runtime.decodeCaptureProfile, text)
			if decodeOK then
				captured, profileError = decoded, decodeError
			else
				captured, profileError = nil, tostring(decoded)
			end
			if captured then
				restoredPath = path
				break
			end
		end
	end
	if not captured then
		State.captureProfileStatus = tostring(profileError or "no remembered placement profile was found")
		return finishProfileRestore(false, State.captureProfileStatus)
	end
	State.captureGeneration = (tonumber(State.captureGeneration) or 0) + 1
	captured.Generation = State.captureGeneration
	State.captured = captured
	State.captureFallback = nil
	State.captureArmed = false
	State.captureProcessing = false
	State.captureInFlight = false
	State.captureInFlightGeneration = nil
	State.scanComplete = true
	State.scanMode = "PacketOnly"
	State.scanMatchedEntry = nil
	State.scanPlacedModel = nil
	State.captureRemembered = true
	State.captureProfileStatus = "Restored remembered placement profile from " .. tostring(restoredPath)
	local restored, restoredCapture = finishProfileRestore(true, captured)
	if not silent then
		notify("Placement Scan remembered", "Restored the verified packet profile for this Roblox place.", 7)
	end
	return restored, restoredCapture
end

local WINDOWS_RESERVED_SAVE_NAMES = {
	con = true,
	prn = true,
	aux = true,
	nul = true,
}

local function sanitizeSaveName(value, generateWhenEmpty)
	local name = trimmed(value):lower()
	if name:sub(-5) == ".json" then
		name = name:sub(1, -6)
	end
	name = name:gsub("[^%w%s_%-]", "")
	name = name:gsub("%s+", "_"):gsub("_+", "_")
	name = name:gsub("^[_%-]+", ""):gsub("[_%-]+$", "")
	name = name:sub(1, 48)
	if name == "" and generateWhenEmpty then
		name = "factory_" .. tostring(os.time())
	end
	if name == "" then
		return nil, "Enter a save name using letters, numbers, spaces, _ or -."
	elseif WINDOWS_RESERVED_SAVE_NAMES[name]
		or name:match("^com[1-9]$")
		or name:match("^lpt[1-9]$")
	then
		return nil, "That filename is reserved by the operating system."
	end
	return name
end

local function savedAutoPlumbValue()
	if State.autoPlumbMode == "Automatic" then
		return true
	elseif State.autoPlumbMode == "Routes" then
		return copiedArray(AutoPlumb, copyAutoPlumbRoute)
	end
	return false
end

local function buildSaveDocument(saveName)
	return {
		Format = SAVE_FORMAT,
		Version = SAVE_VERSION,
		Name = saveName,
		SavedAtUnix = os.time(),
		PlaceId = game.PlaceId,
		Blueprint = copiedArray(Blueprint, copyPlacementEntry),
		AuthoredPlumbing = copiedArray(State.sourceAuthoredPlumbing, copyPlacementEntry),
		AuthoredPipeLinks = copiedArray(State.sourceAuthoredPipeLinks, copyPipeLinkEntry),
		Wiring = copiedArray(Wiring, copyPipeLinkEntry),
		AutoPlumb = savedAutoPlumbValue(),
		PipeQuality = State.autoPlumbQuality,
	}
end

local function decodeSaveJSON(text)
	if type(text) ~= "string" then
		return nil, "save file did not contain text"
	elseif #text > Config.MaxBlueprintTextBytes then
		return nil, "save file is larger than 500 KB"
	end
	local decodeOK, document = pcall(function()
		return HttpService:JSONDecode(text)
	end)
	if not decodeOK or type(document) ~= "table" then
		return nil, "save file is not valid JSON"
	elseif document.Format ~= SAVE_FORMAT then
		return nil, "save file has an unsupported Format"
	elseif finiteNumber(document.Version) ~= SAVE_VERSION then
		return nil, "save file uses an unsupported Version"
	elseif type(document.Blueprint) ~= "table"
		or type(document.AuthoredPlumbing) ~= "table"
		or type(document.AuthoredPipeLinks) ~= "table"
		or type(document.Wiring) ~= "table"
	then
		return nil, "save file is missing canonical blueprint arrays"
	end
	return document
end

local function runFilesystemOperation(callback)
	if State.filesystemBusy then
		return false, "Another save operation is already running."
	end
	State.filesystemBusy = true
	local callOK, result, first, second = pcall(callback)
	State.filesystemBusy = false
	if not callOK then
		local message = "Filesystem operation failed: " .. tostring(result)
		State.saveStatus = message
		return false, message
	end
	return result, first, second
end

local function saveGameToJSON(requestedName, overwrite, silent)
	return runFilesystemOperation(function()
		if State.building then
			return false, "Wait for the current build to finish before saving."
		end
		if not State.blueprintLoaded or State.blueprintDirty then
			local loaded, loadError = loadBlueprintText(State.blueprintText, true)
			if not loaded then
				return false, "Current paste is invalid: " .. tostring(loadError)
			end
		end
		local saveName, nameError = sanitizeSaveName(requestedName, true)
		if not saveName then
			return false, nameError
		end
		local foldersReady, folderError = ensureSaveFolders()
		if not foldersReady then
			return false, folderError
		end
		local writeFile = executorFileFunction("writefile")
		local readFile = executorFileFunction("readfile")
		local deleteFile = executorFileFunction("delfile")
		local isFile = executorFileFunction("isfile")
		local listFiles = executorFileFunction("listfiles")
		if not writeFile or not readFile then
			return false, "This executor needs writefile and readfile for verified JSON saves."
		end

		local encodeOK, json = pcall(function()
			return HttpService:JSONEncode(buildSaveDocument(saveName))
		end)
		if not encodeOK then
			return false, "Could not encode the save as JSON: " .. tostring(json)
		elseif #json > Config.MaxBlueprintTextBytes then
			return false, "Encoded save is larger than 500 KB."
		end

		local finalPath = string.format("%s/%s.json", SAVE_FOLDER, saveName)
		-- Keep staging files JSON-compatible: a few executors reject hidden files
		-- or non-whitelisted extensions. The save-list filter excludes these names.
		local temporaryPath = string.format("%s/%s.__tmp.json", SAVE_FOLDER, saveName)
		local backupPath = string.format("%s/%s.__bak.json", SAVE_FOLDER, saveName)
		local previousText
		local knownExisting
		if isFile then
			local checkOK, result = pcall(isFile, finalPath)
			if checkOK then
				knownExisting = result == true
			end
		elseif listFiles then
			local listOK, paths = pcall(listFiles, SAVE_FOLDER)
			if listOK and type(paths) == "table" then
				knownExisting = false
				for _, rawPath in ipairs(paths) do
					local normalizedPath = tostring(rawPath):gsub("\\", "/")
					if normalizedPath == finalPath
						or normalizedPath:sub(-#finalPath - 1) == "/" .. finalPath
					then
						knownExisting = true
						break
					end
				end
			end
		end
		local existingOK, existingValue = pcall(readFile, finalPath)
		if existingOK and type(existingValue) == "string" then
			previousText = existingValue
			if overwrite ~= true then
				return false, saveName .. ".json already exists. Use Save / Overwrite to replace it."
			end
		elseif knownExisting == true then
			return false, saveName .. ".json exists but could not be read; refusing to overwrite it without a recoverable backup."
		elseif knownExisting == nil and overwrite ~= true then
			return false, "Could not prove that " .. saveName .. ".json is absent. Use Save / Overwrite if replacement is intended."
		end

		local function restoreOrRemoveFinal()
			if previousText then
				return pcall(writeFile, finalPath, previousText)
			elseif deleteFile then
				return pcall(deleteFile, finalPath)
			end
			return false
		end

		local temporaryWriteOK, temporaryWriteError = pcall(writeFile, temporaryPath, json)
		if not temporaryWriteOK then
			return false, "Temporary save write failed: " .. tostring(temporaryWriteError)
		end
		local temporaryReadOK, temporaryText = pcall(readFile, temporaryPath)
		local temporaryDocument = temporaryReadOK and decodeSaveJSON(temporaryText) or nil
		if not temporaryDocument or temporaryText ~= json then
			if deleteFile then
				pcall(deleteFile, temporaryPath)
			end
			return false, "Temporary save verification failed; the existing save was not changed."
		end

		if previousText then
			pcall(writeFile, backupPath, previousText)
		end
		local finalWriteOK, finalWriteError = pcall(writeFile, finalPath, json)
		if not finalWriteOK then
			restoreOrRemoveFinal()
			if deleteFile then
				pcall(deleteFile, temporaryPath)
			end
			return false, "Final save write failed; the prior file was restored when possible: " .. tostring(finalWriteError)
		end
		local finalReadOK, finalText = pcall(readFile, finalPath)
		local finalDocument = finalReadOK and decodeSaveJSON(finalText) or nil
		if not finalDocument or finalText ~= json then
			restoreOrRemoveFinal()
			if deleteFile then
				pcall(deleteFile, temporaryPath)
			end
			return false, "Final save verification failed; the prior file was restored when possible."
		end
		if deleteFile then
			pcall(deleteFile, temporaryPath)
			pcall(deleteFile, backupPath)
		end
		State.lastSaveName = saveName
		State.saveStatus = "Saved and verified: " .. finalPath
		if not silent then
			notify("Blueprint saved", finalPath, 7)
		end
		return true, finalPath, json
	end)
end

local function listGameSaves()
	return runFilesystemOperation(function()
		local foldersReady, folderError = ensureSaveFolders()
		if not foldersReady then
			return false, folderError
		end
		local listFiles = executorFileFunction("listfiles")
		if not listFiles then
			return false, "This executor does not expose listfiles; type a save name to load it directly."
		end
		local listOK, paths = pcall(listFiles, SAVE_FOLDER)
		if not listOK or type(paths) ~= "table" then
			return false, "Could not list " .. SAVE_FOLDER
		end
		local names = {}
		local seen = {}
		for _, rawPath in ipairs(paths) do
			local normalizedPath = tostring(rawPath):gsub("\\", "/")
			local fileName = normalizedPath:match("([^/]+)%.json$")
			if fileName
				and #fileName <= 48
				and fileName:match("^[a-z0-9][a-z0-9_%-]*$")
				and not seen[fileName]
			then
				seen[fileName] = true
				table.insert(names, fileName)
			end
		end
		table.sort(names)
		State.saveStatus = string.format("%d JSON save(s) in %s", #names, SAVE_FOLDER)
		return true, names
	end)
end

local function loadGameFromJSON(requestedName, silent)
	return runFilesystemOperation(function()
		if State.building then
			return false, "Wait for the current build to finish before loading a save."
		end
		local saveName, nameError = sanitizeSaveName(requestedName, false)
		if not saveName then
			return false, nameError
		end
		local foldersReady, folderError = ensureSaveFolders()
		if not foldersReady then
			return false, folderError
		end
		local readFile = executorFileFunction("readfile")
		if not readFile then
			return false, "This executor does not expose readfile."
		end
		local path = string.format("%s/%s.json", SAVE_FOLDER, saveName)
		local readOK, text = pcall(readFile, path)
		if not readOK then
			return false, "Could not read " .. path .. ": " .. tostring(text)
		end
		local document, decodeError = decodeSaveJSON(text)
		if not document then
			return false, decodeError
		end
		local encodeOK, canonicalJSON = pcall(function()
			return HttpService:JSONEncode(document)
		end)
		if not encodeOK then
			return false, "Could not normalize saved JSON: " .. tostring(canonicalJSON)
		end
		local keptVerifiedCapture = State.captured ~= nil and State.scanComplete == true
		if keptVerifiedCapture then
			-- A packet learned from the previous document remains a valid transport
			-- sample, but its old entry match must never move the newly loaded origin.
			State.scanMode = "PacketOnly"
			State.scanMatchedEntry = nil
		end
		local loaded, loadError = loadBlueprintText(canonicalJSON, true, {
			RequireFreshScan = not keptVerifiedCapture,
		})
		if not loaded then
			return false, "Saved blueprint failed validation: " .. tostring(loadError)
		end

		State.lastSaveName = saveName
		local scanNote = keptVerifiedCapture
			and " • remembered placement packet kept"
			or " • fresh Scan required"
		State.saveStatus = "Loaded: " .. path .. scanNote
		if type(State.blueprintInputSync) == "function" then
			pcall(State.blueprintInputSync, canonicalJSON)
		end
		updateBlueprintParagraph(keptVerifiedCapture
			and "Loaded local save; remembered placement packet kept."
			or "Loaded local save; run Scan before building.")
		if not silent then
			notify(
				"Blueprint loaded",
				path .. (keptVerifiedCapture
					and ". Remembered placement packet kept."
					or ". Run Scan before building."),
				8
			)
		end
		return true, canonicalJSON, path
	end)
end

function Runtime.ensureConnectionDecorationRegistry()
	local current = State.connectionDecorationRegistry
	if current and not current.released then
		return current
	end
	local registry = {
		byName = {
			Pipe = { list = {}, set = {}, dirty = false },
			Power = { list = {}, set = {}, dirty = false },
		},
		connections = {},
		childConnections = {},
		memberName = {},
		released = false,
	}
	State.connectionDecorationRegistry = registry
	local function removeMembership(decoration)
		local priorName = registry.memberName[decoration]
		local priorBucket = priorName and registry.byName[priorName]
		if priorBucket and priorBucket.set[decoration] then
			priorBucket.set[decoration] = nil
			priorBucket.dirty = true
		end
		registry.memberName[decoration] = nil
	end
	local function classify(decoration)
		if registry.released then
			return
		end
		local nextName = decoration:IsA("BasePart")
			and decoration.Parent == ConnectionDecorations
			and registry.byName[decoration.Name]
			and decoration.Name
			or nil
		local priorName = registry.memberName[decoration]
		if priorName == nextName then
			return
		end
		removeMembership(decoration)
		if nextName then
			local nextBucket = registry.byName[nextName]
			if not nextBucket.set[decoration] then
				nextBucket.set[decoration] = true
				table.insert(nextBucket.list, decoration)
			end
			registry.memberName[decoration] = nextName
		end
	end
	local function untrack(decoration)
		removeMembership(decoration)
		local connection = registry.childConnections[decoration]
		if connection then
			connection:Disconnect()
			registry.childConnections[decoration] = nil
		end
	end
	local function track(decoration)
		if registry.released or not decoration:IsA("BasePart") then
			return
		end
		if not registry.childConnections[decoration] then
			registry.childConnections[decoration] = decoration
				:GetPropertyChangedSignal("Name")
				:Connect(function()
					classify(decoration)
				end)
		end
		classify(decoration)
	end
	for _, decoration in ipairs(ConnectionDecorations:GetChildren()) do
		track(decoration)
	end
	table.insert(registry.connections, ConnectionDecorations.ChildAdded:Connect(track))
	table.insert(registry.connections, ConnectionDecorations.ChildRemoved:Connect(untrack))
	return registry
end

function Runtime.connectionDecorationChildren(expectedName)
	local registry = Runtime.ensureConnectionDecorationRegistry()
	local bucket = registry.byName[expectedName]
	if not bucket then
		return {}
	end
	local needsCompact = bucket.dirty
	if not needsCompact then
		for _, decoration in ipairs(bucket.list) do
			if not bucket.set[decoration]
				or decoration.Parent ~= ConnectionDecorations
				or decoration.Name ~= expectedName
			then
				needsCompact = true
				break
			end
		end
	end
	if needsCompact then
		local compacted = {}
		local compactedSet = {}
		for _, decoration in ipairs(bucket.list) do
			if bucket.set[decoration]
				and decoration.Parent == ConnectionDecorations
				and decoration.Name == expectedName
				and decoration:IsA("BasePart")
			then
				compactedSet[decoration] = true
				table.insert(compacted, decoration)
			end
		end
		bucket.list = compacted
		bucket.set = compactedSet
		bucket.dirty = false
	end
	return bucket.list
end

function Runtime.releaseConnectionDecorationRegistry()
	local registry = State.connectionDecorationRegistry
	if not registry then
		return
	end
	registry.released = true
	for _, connection in ipairs(registry.connections) do
		pcall(function()
			connection:Disconnect()
		end)
	end
	for decoration, connection in pairs(registry.childConnections) do
		pcall(function()
			connection:Disconnect()
		end)
		registry.childConnections[decoration] = nil
	end
	registry.connections = {}
	registry.memberName = {}
	registry.byName = {}
	State.connectionDecorationRegistry = nil
end

function Runtime.stopConnectionWatch(watch)
	if not watch then
		return
	end
	State.activeConnectionWatches[watch] = nil
	if watch.stopped then
		return
	end
	watch.stopped = true
	if watch.connection then
		pcall(function()
			watch.connection:Disconnect()
		end)
		watch.connection = nil
	end
end

function Runtime.beginConnectionWatch(kind)
	local expectedName = kind == "Pipe" and "Pipe" or "Power"
	local watch = {
		expectedName = expectedName,
		added = {},
		seen = {},
		baseline = {},
		connection = nil,
		stopped = false,
	}
	for _, decoration in ipairs(Runtime.connectionDecorationChildren(expectedName)) do
		watch.baseline[decoration] = true
	end
	State.activeConnectionWatches[watch] = true
	local function consider(decoration)
		if not watch.stopped
			and decoration:IsA("BasePart")
			and decoration.Name == expectedName
			and not watch.baseline[decoration]
			and not watch.seen[decoration]
		then
			watch.seen[decoration] = true
			table.insert(watch.added, decoration)
		end
	end
	watch.consider = consider
	watch.connection = ConnectionDecorations.ChildAdded:Connect(consider)
	return watch
end

function Runtime.connectionDecorationPairMatches(kind, first, second, fromConnector, toConnector)
	if not first or not second or first == second then
		return false, "the decoration pair is incomplete"
	elseif not fromConnector or not fromConnector.Parent or not toConnector or not toConnector.Parent then
		return false, "the intended connector endpoints disappeared"
	end

	local expectedName = kind == "Pipe" and "Pipe" or "Power"
	local segment
	local cap
	for _, decoration in ipairs({ first, second }) do
		if not decoration.Parent
			or not decoration:IsDescendantOf(ConnectionDecorations)
			or decoration.Name ~= expectedName
		then
			return false, "a decoration is no longer in the expected server folder"
		elseif decoration:IsA("UnionOperation") then
			if cap then
				return false, "the server created two endpoint caps instead of a segment/cap pair"
			end
			cap = decoration
		elseif decoration:IsA("Part") then
			if segment then
				return false, "the server created two segments instead of a segment/cap pair"
			end
			segment = decoration
		else
			return false, "the server created an unexpected decoration class " .. decoration.ClassName
		end
	end
	if not segment or not cap then
		return false, "the server did not create the expected segment/cap pair"
	end

	local halfLength = segment.Size.Z * 0.5
	local firstEnd = segment.CFrame:PointToWorldSpace(Vector3.new(0, 0, halfLength))
	local secondEnd = segment.CFrame:PointToWorldSpace(Vector3.new(0, 0, -halfLength))
	local farEnd = (firstEnd - cap.Position).Magnitude >= (secondEnd - cap.Position).Magnitude
		and firstEnd
		or secondEnd
	local segmentTolerance = kind == "Pipe"
		and Config.PipeDecorationSegmentTolerance
		or Config.PowerDecorationSegmentTolerance
	local capTolerance = kind == "Pipe"
		and Config.PipeDecorationCapTolerance
		or Config.PowerDecorationCapTolerance
	local minimumBias = kind == "Pipe"
		and Config.PipeDecorationLengthBiasMin
		or Config.PowerDecorationLengthBiasMin
	local maximumBias = kind == "Pipe"
		and Config.PipeDecorationLengthBiasMax
		or Config.PowerDecorationLengthBiasMax
	local connectorDistance = (fromConnector.Position - toConnector.Position).Magnitude
	local lengthBias = connectorDistance - segment.Size.Z
	if lengthBias < minimumBias or lengthBias > maximumBias then
		return false, string.format(
			"segment length does not match the intended endpoints (bias %.3f, expected %.2f..%.2f)",
			lengthBias,
			minimumBias,
			maximumBias
		)
	end

	local function assignmentMatches(segmentConnector, capConnector)
		return (segmentConnector.Position - farEnd).Magnitude <= segmentTolerance
			and (capConnector.Position - cap.Position).Magnitude <= capTolerance
	end
	if assignmentMatches(fromConnector, toConnector)
		or assignmentMatches(toConnector, fromConnector)
	then
		return true
	end
	return false, string.format(
		"segment/cap anchors do not match the intended endpoints (limits %.2f/%.2f studs)",
		segmentTolerance,
		capTolerance
	)
end

-- Cheap endpoint relevance test used to detect partial replication before a
-- bind is sent. Exact acceptance still goes through the full pair matcher.
function Runtime.connectionDecorationCouldBelongToEdge(
	kind,
	decoration,
	fromConnector,
	toConnector
)
	local expectedName = kind == "Pipe" and "Pipe" or "Power"
	if not decoration
		or not decoration.Parent
		or not decoration:IsA("BasePart")
		or decoration.Name ~= expectedName
	then
		return false
	end
	if decoration:IsA("UnionOperation") then
		local capTolerance = kind == "Pipe"
			and Config.PipeDecorationCapTolerance
			or Config.PowerDecorationCapTolerance
		return (decoration.Position - fromConnector.Position).Magnitude
				<= capTolerance + Config.EdgeEpsilon
			or (decoration.Position - toConnector.Position).Magnitude
				<= capTolerance + Config.EdgeEpsilon
	elseif decoration:IsA("Part") then
		local segmentTolerance = kind == "Pipe"
			and Config.PipeDecorationSegmentTolerance
			or Config.PowerDecorationSegmentTolerance
		local minimumBias = kind == "Pipe"
			and Config.PipeDecorationLengthBiasMin
			or Config.PowerDecorationLengthBiasMin
		local maximumBias = kind == "Pipe"
			and Config.PipeDecorationLengthBiasMax
			or Config.PowerDecorationLengthBiasMax
		local connectorDistance = (fromConnector.Position - toConnector.Position).Magnitude
		local lengthBias = connectorDistance - decoration.Size.Z
		if lengthBias < minimumBias or lengthBias > maximumBias then
			return false
		end
		local halfLength = decoration.Size.Z * 0.5
		local firstEnd = decoration.CFrame:PointToWorldSpace(Vector3.new(0, 0, halfLength))
		local secondEnd = decoration.CFrame:PointToWorldSpace(Vector3.new(0, 0, -halfLength))
		local farTolerance = segmentTolerance + Config.EdgeEpsilon
		local nearTolerance = maximumBias + segmentTolerance + Config.EdgeEpsilon
		return ((firstEnd - fromConnector.Position).Magnitude <= farTolerance
				and (secondEnd - toConnector.Position).Magnitude <= nearTolerance)
			or ((secondEnd - fromConnector.Position).Magnitude <= farTolerance
				and (firstEnd - toConnector.Position).Magnitude <= nearTolerance)
			or ((firstEnd - toConnector.Position).Magnitude <= farTolerance
				and (secondEnd - fromConnector.Position).Magnitude <= nearTolerance)
			or ((secondEnd - toConnector.Position).Magnitude <= farTolerance
				and (firstEnd - fromConnector.Position).Magnitude <= nearTolerance)
	end
	return false
end

-- Resolve a connection by its segment identity, not by cap identity. Several
-- binds can share one physical PipeA position, making their endpoint caps
-- visually interchangeable. One exact segment with one or more matching live
-- caps is still one unambiguous edge; two exact segment Instances are not.
function Runtime.findExactLiveConnectionDecorations(
	kind,
	fromConnector,
	toConnector,
	eligibleSegments,
	preferredCaps
)
	local expectedName = kind == "Pipe" and "Pipe" or "Power"
	local segmentTolerance = kind == "Pipe"
		and Config.PipeDecorationSegmentTolerance
		or Config.PowerDecorationSegmentTolerance
	local capTolerance = kind == "Pipe"
		and Config.PipeDecorationCapTolerance
		or Config.PowerDecorationCapTolerance
	local minimumBias = kind == "Pipe"
		and Config.PipeDecorationLengthBiasMin
		or Config.PowerDecorationLengthBiasMin
	local maximumBias = kind == "Pipe"
		and Config.PipeDecorationLengthBiasMax
		or Config.PowerDecorationLengthBiasMax
	local connectorDistance = (fromConnector.Position - toConnector.Position).Magnitude
	local segments = {}
	local caps = {}
	for _, decoration in ipairs(Runtime.connectionDecorationChildren(expectedName)) do
		if decoration:IsA("BasePart")
			and decoration.Name == expectedName
			and decoration.Parent
		then
			if decoration:IsA("UnionOperation") then
				local nearFrom = (decoration.Position - fromConnector.Position).Magnitude
					<= capTolerance + Config.EdgeEpsilon
				local nearTo = (decoration.Position - toConnector.Position).Magnitude
					<= capTolerance + Config.EdgeEpsilon
				if nearFrom or nearTo then
					table.insert(caps, {
						instance = decoration,
						nearFrom = nearFrom,
						nearTo = nearTo,
					})
				end
			elseif decoration:IsA("Part")
				and (eligibleSegments == nil or eligibleSegments[decoration])
			then
				local lengthBias = connectorDistance - decoration.Size.Z
				if lengthBias >= minimumBias and lengthBias <= maximumBias then
					local halfLength = decoration.Size.Z * 0.5
					local firstEnd = decoration.CFrame:PointToWorldSpace(
						Vector3.new(0, 0, halfLength)
					)
					local secondEnd = decoration.CFrame:PointToWorldSpace(
						Vector3.new(0, 0, -halfLength)
					)
					local farTolerance = segmentTolerance + Config.EdgeEpsilon
					local nearTolerance = maximumBias
						+ segmentTolerance
						+ Config.EdgeEpsilon
					local farFrom = ((firstEnd - fromConnector.Position).Magnitude <= farTolerance
							and (secondEnd - toConnector.Position).Magnitude <= nearTolerance)
						or ((secondEnd - fromConnector.Position).Magnitude <= farTolerance
							and (firstEnd - toConnector.Position).Magnitude <= nearTolerance)
					local farTo = ((firstEnd - toConnector.Position).Magnitude <= farTolerance
							and (secondEnd - fromConnector.Position).Magnitude <= nearTolerance)
						or ((secondEnd - toConnector.Position).Magnitude <= farTolerance
							and (firstEnd - fromConnector.Position).Magnitude <= nearTolerance)
					if farFrom or farTo then
						table.insert(segments, {
							instance = decoration,
							farFrom = farFrom,
							farTo = farTo,
						})
					end
				end
			end
		end
	end

	local exactBySegment = {}
	local mismatchDetail
	for _, segmentRecord in ipairs(segments) do
		local matchingCaps = {}
		for _, capRecord in ipairs(caps) do
			-- A segment end at From requires its cap at To, and vice versa.
			-- This avoids an O(N^2) cartesian product at shared power/pipe nodes.
			if (segmentRecord.farFrom and capRecord.nearTo)
				or (segmentRecord.farTo and capRecord.nearFrom)
			then
				local matches, pairError = Runtime.connectionDecorationPairMatches(
					kind,
					segmentRecord.instance,
					capRecord.instance,
					fromConnector,
					toConnector
				)
				if matches then
					table.insert(matchingCaps, capRecord.instance)
				else
					mismatchDetail = pairError or mismatchDetail
				end
			end
		end
		if #matchingCaps > 0 then
			table.insert(exactBySegment, {
				segment = segmentRecord.instance,
				caps = matchingCaps,
			})
		end
	end

	local stats = {
		segmentCount = #segments,
		capCount = #caps,
		exactSegmentCount = #exactBySegment,
	}
	if #exactBySegment == 1 then
		local selectedCap = exactBySegment[1].caps[1]
		if type(preferredCaps) == "table" then
			for _, cap in ipairs(exactBySegment[1].caps) do
				if preferredCaps[cap] then
					selectedCap = cap
					break
				end
			end
		end
		return {
			exactBySegment[1].segment,
			selectedCap,
		}, nil, false, stats
	elseif #exactBySegment > 1 then
		return nil, string.format(
			"%d exact live %s segments match the intended endpoints",
			#exactBySegment,
			expectedName
		), true, stats
	end
	return nil, mismatchDetail or string.format(
		"no exact live %s segment/cap evidence matched the intended endpoints",
		expectedName
	), false, stats
end

-- A connection's segment Instance is authoritative. Caps can be geometrically
-- interchangeable at a shared connector, so refresh a missing pinned cap from
-- the live folder before deciding that the edge disappeared.
function Runtime.refreshConnectionDecorations(kind, fromConnector, toConnector, decorations)
	local segment
	for _, decoration in ipairs(type(decorations) == "table" and decorations or {}) do
		if typeof(decoration) == "Instance" and decoration:IsA("Part") then
			segment = decoration
			break
		end
	end
	if not segment then
		return nil, "verified connection lost its authoritative segment Instance"
	end
	local refreshed, refreshError, ambiguous = Runtime.findExactLiveConnectionDecorations(
		kind,
		fromConnector,
		toConnector,
		{ [segment] = true }
	)
	if refreshed then
		return refreshed
	end
	return nil, (ambiguous and "ambiguous segment refresh: " or "segment refresh failed: ")
		.. tostring(refreshError)
end

function Runtime.commitVerifiedConnection(connection, reservation, decorations)
	reservation.confirmed = true
	reservation.decorations = decorations
	connection.verifiedConnection = reservation
	connection.verifiedDecorations = decorations
	connection.built = true
	if connection.line then
		connection.line:Destroy()
		connection.line = nil
	end
	return true
end

function Runtime.waitForConnectionSendSlot()
	local lastInvokeAt = tonumber(State.lastConnectionInvokeAt)
	if lastInvokeAt then
		local remaining = Config.ConnectionMinimumSendInterval
			- math.max(0, os.clock() - lastInvokeAt)
		if remaining > 0 and not Runtime.waitForNextAction(remaining) then
			return false
		end
	end
	return not State.cancelRequested and not State.destroyed
end

function Runtime.stopAllBuildWatches()
	while next(State.activePlacementWatches) do
		local watch = next(State.activePlacementWatches)
		Runtime.stopPlacementWatch(watch)
	end
	while next(State.activeConnectionWatches) do
		local watch = next(State.activeConnectionWatches)
		Runtime.stopConnectionWatch(watch)
	end
	while next(State.activePlacedCaches) do
		local existing = next(State.activePlacedCaches)
		Runtime.releasePlacedCache(existing)
	end
end

local function verifyNewConnection(watch, connection, fromConnector, toConnector)
	local primaryDeadline = os.clock() + Config.ConnectionVerifyTimeout
	local finalDeadline = primaryDeadline + Config.ConnectionVerifyLateReplicationGrace
	local matchingCount = 0
	local freshSegmentCount = 0
	local mismatchDetail
	local authoritativeRefreshDone = false
	local evidence = {
		matchingCount = 0,
		freshSegmentCount = 0,
	}

	local function authoritativeRefresh()
		for _, decoration in ipairs(Runtime.connectionDecorationChildren(watch.expectedName)) do
			watch.consider(decoration)
		end
	end

	local function inspectCandidates()
		local freshSegments = {}
		local freshCaps = {}
		-- Recompute rather than accumulate across heartbeat polls.
		matchingCount = 0
		freshSegmentCount = 0
		for _, decoration in ipairs(watch.added) do
			if decoration.Parent
				and decoration:IsDescendantOf(ConnectionDecorations)
				and decoration.Name == watch.expectedName
			then
				matchingCount += 1
				if decoration:IsA("Part") then
					freshSegments[decoration] = true
					freshSegmentCount += 1
				elseif decoration:IsA("UnionOperation") then
					freshCaps[decoration] = true
				end
			end
		end
		evidence.matchingCount = matchingCount
		evidence.freshSegmentCount = freshSegmentCount
		if freshSegmentCount > 0 then
			local decorations, liveError, ambiguous = Runtime.findExactLiveConnectionDecorations(
				connection.kind,
				fromConnector,
				toConnector,
				freshSegments,
				freshCaps
			)
			if decorations then
				return decorations
			end
			mismatchDetail = liveError or mismatchDetail
			if ambiguous then
				return nil, "ambiguous post-call connection evidence: " .. tostring(liveError)
			end
		end
		return nil
	end

	while true do
		if watch.stopped then
			return nil, "connection verification watcher was cancelled", evidence
		elseif State.destroyed then
			Runtime.stopConnectionWatch(watch)
			return nil, Runtime.buildCancellationReason(), evidence
		end
		-- A user cancellation stops the next action, not attribution of the
		-- connection remote that already returned. Keep this bounded verifier alive
		-- so a late exact decoration pair is committed instead of resent on Resume.
		local decorations, terminalError = inspectCandidates()
		if decorations then
			Runtime.stopConnectionWatch(watch)
			return decorations, nil, evidence
		elseif terminalError then
			Runtime.stopConnectionWatch(watch)
			return nil, terminalError, evidence
		end
		local now = os.clock()
		if not authoritativeRefreshDone and now >= primaryDeadline then
			authoritativeRefreshDone = true
			authoritativeRefresh()
			decorations, terminalError = inspectCandidates()
			if decorations then
				Runtime.stopConnectionWatch(watch)
				return decorations, nil, evidence
			elseif terminalError then
				Runtime.stopConnectionWatch(watch)
				return nil, terminalError, evidence
			end
			if Config.ConnectionVerifyLateReplicationGrace > 0 then
				print(PREFIX .. string.format(
					"waiting up to %.1fs for delayed %s connection decorations...",
					Config.ConnectionVerifyLateReplicationGrace,
					watch.expectedName
				))
			end
		end
		if now >= finalDeadline then
			break
		end
		RunService.Heartbeat:Wait()
	end
	-- Close the snapshot/event race one last time before deciding the exact
	-- server effect is absent.
	authoritativeRefresh()
	local finalDecorations, terminalError = inspectCandidates()
	if finalDecorations then
		Runtime.stopConnectionWatch(watch)
		return finalDecorations, nil, evidence
	elseif terminalError then
		Runtime.stopConnectionWatch(watch)
		return nil, terminalError, evidence
	end
	Runtime.stopConnectionWatch(watch)
	if matchingCount > 0 then
		return nil, string.format(
			"server created %d new %s decoration object(s) (%d segment(s)), but no unique exact live segment/cap pair matched: %s",
			matchingCount,
			watch.expectedName,
			freshSegmentCount,
			tostring(mismatchDetail or "geometry mismatch")
		), evidence
	end
	return nil, string.format(
		"server created no new %s decoration objects within %.1fs",
		watch.expectedName,
		Config.ConnectionVerifyTimeout + Config.ConnectionVerifyLateReplicationGrace
	), evidence
end

function Runtime.recordVerifiedManualConnection(watch, kind, fromConnector, toConnector)
	if not watch or State.destroyed then
		Runtime.stopConnectionWatch(watch)
		return false
	end
	local reserved, known, inserted = Runtime.rememberKnownConnection(
		kind,
		fromConnector,
		toConnector,
		true
	)
	if not reserved then
		Runtime.stopConnectionWatch(watch)
		warn(PREFIX .. "manual connection capture ignored: " .. tostring(known))
		return false
	end
	local decorations, verifyError = verifyNewConnection(
		watch,
		{ kind = kind },
		fromConnector,
		toConnector
	)
	if not decorations then
		if inserted then
			Runtime.forgetKnownConnection(known)
		end
		warn(PREFIX .. "manual " .. kind .. " capture was not verified: " .. tostring(verifyError))
		return false
	end
	known.confirmed = true
	known.decorations = decorations
	return true, known
end

local function sendConnection(connection, fromConnector, toConnector, label)
	local remote = connection.kind == "Pipe" and PipeBind or WireBind
	local packet = connection.kind == "Pipe"
		and table.pack(fromConnector, toConnector, nil)
		or table.pack(fromConnector, toConnector)
	label = label or connectionLabel(connection)
	dumpArgs(label .. " arguments", packet)

	State.replaying = true
	State.buildRemoteAttempted = true
	-- Pace the actual PipeBind/WireBind boundary. Placement remotes use their
	-- own action delay and must not consume this connection-only send slot.
	State.lastConnectionInvokeAt = os.clock()
	Runtime.setBuildLeaseRemoteInFlight(true)
	local ok, result = pcall(function()
		return remote:InvokeServer(table.unpack(packet, 1, packet.n))
	end)
	Runtime.setBuildLeaseRemoteInFlight(false)
	State.replaying = false
	if Config.VerboseRemoteLogging or not ok or result == false then
		print(PREFIX .. string.format(
			"%s server call ok=%s result=%s",
			label,
			tostring(ok),
			describe(result)
		))
	end
	return ok, result
end

-- One shared send path keeps blueprint, duplicate, pipe, and wire behavior
-- identical. It first adopts an exact live edge (important after reinjection or
-- a late server commit), then performs one paced call. A timeout is not replayed
-- automatically because delayed partial replication cannot be attributed safely;
-- an explicit Build/Resume performs another exact pre-send recovery pass.
function Runtime.invokeAndVerifyConnection(
	connection,
	fromConnector,
	toConnector,
	label,
	rejectionMessage
)
	local existing, existingError, existingAmbiguous, existingStats = Runtime.findExactLiveConnectionDecorations(
		connection.kind,
		fromConnector,
		toConnector
	)
	if existing then
		return existing, nil, {
			reusedLive = true,
			attempts = 0,
		}
	elseif existingAmbiguous then
		return nil, "existing connection evidence is ambiguous: " .. tostring(existingError)
	elseif type(existingStats) == "table"
		and math.max(0, tonumber(existingStats.segmentCount) or 0) > 0
	then
		return nil, string.format(
			"%d target-matching segment object(s) already exist without a complete exact cap; wait for replication or remove the orphan before Build/Resume",
			math.max(0, tonumber(existingStats.segmentCount) or 0)
		)
	end

	local watch = Runtime.beginConnectionWatch(connection.kind)
	-- Open the before-call baseline before pacing can yield. This exposes any
	-- delayed exact or partial effect that arrives during the send-slot wait.
	if not Runtime.waitForConnectionSendSlot() then
		Runtime.stopConnectionWatch(watch)
		return nil, Runtime.buildCancellationReason()
	end
	for _, decoration in ipairs(Runtime.connectionDecorationChildren(watch.expectedName)) do
		watch.consider(decoration)
	end
	-- Since no request has been sent yet, a complete exact edge is safe to adopt
	-- as pre-existing. Relevant partial evidence is not safe to send across.
	local beforeSend, beforeSendError, beforeSendAmbiguous, beforeSendStats = Runtime.findExactLiveConnectionDecorations(
		connection.kind,
		fromConnector,
		toConnector
	)
	if beforeSend then
		Runtime.stopConnectionWatch(watch)
		return beforeSend, nil, {
			reusedLive = true,
			recoveredBeforeSend = true,
			attempts = 0,
		}
	elseif beforeSendAmbiguous then
		Runtime.stopConnectionWatch(watch)
		return nil, "pre-send connection evidence is ambiguous: " .. tostring(beforeSendError)
	elseif type(beforeSendStats) == "table"
		and math.max(0, tonumber(beforeSendStats.segmentCount) or 0) > 0
	then
		Runtime.stopConnectionWatch(watch)
		return nil, string.format(
			"%d target-matching segment object(s) appeared before send without a complete exact cap; wait for replication, then press Build/Resume",
			math.max(0, tonumber(beforeSendStats.segmentCount) or 0)
		)
	end
	local partialCount = 0
	for _, decoration in ipairs(watch.added) do
		if Runtime.connectionDecorationCouldBelongToEdge(
			connection.kind,
			decoration,
			fromConnector,
			toConnector
		) then
			partialCount += 1
		end
	end
	if partialCount > 0 then
		Runtime.stopConnectionWatch(watch)
		return nil, string.format(
			"%d target-relevant decoration object(s) appeared before send without a complete exact edge; wait for replication, then press Build/Resume",
			partialCount
		)
	end

	local callOK, serverResult = sendConnection(
		connection,
		fromConnector,
		toConnector,
		label
	)
	if callOK and serverResult == false then
		Runtime.stopConnectionWatch(watch)
		return nil, rejectionMessage or "server rejected the connection"
	end

	local decorations, verifyError, evidence = verifyNewConnection(
		watch,
		connection,
		fromConnector,
		toConnector
	)
	if decorations then
		return decorations, nil, {
			remoteErrored = not callOK,
			attempts = 1,
		}
	elseif State.destroyed then
		return nil, Runtime.buildCancellationReason()
	end

	local evidenceSuffix = type(evidence) == "table" and string.format(
		" (%d new decoration(s), %d new segment(s))",
		math.max(0, tonumber(evidence.matchingCount) or 0),
		math.max(0, tonumber(evidence.freshSegmentCount) or 0)
	) or ""
	if not callOK then
		return nil, string.format(
			"remote error: %s; no exact server effect was observed: %s%s",
			tostring(serverResult),
			tostring(verifyError),
			evidenceSuffix
		)
	end
	return nil, "verification failed: " .. tostring(verifyError) .. evidenceSuffix
end

local function buildWireConnection(connection)
	assert(connection.kind == "Wire", "buildWireConnection received a non-wire connection")
	local valid, fromConnector, toConnector, reasons = inspectConnection(connection, true)
	if not valid then
		return false, "last-second validation failed: " .. table.concat(reasons, "; ")
	end
	local reserved, reservation, reservationInserted = Runtime.rememberKnownConnection(
		connection.kind,
		fromConnector,
		toConnector,
		true
	)
	if not reserved then
		return false, "could not reserve the exact duplicate replay path: " .. tostring(reservation)
	end
	if not reservationInserted
		and Runtime.reuseKnownConnectionIfExact(connection, reservation, fromConnector, toConnector)
	then
		return true
	end

	local label = connectionLabel(connection)
	local decorations, verifyError, outcome = Runtime.invokeAndVerifyConnection(
		connection,
		fromConnector,
		toConnector,
		label,
		"server rejected the connection"
	)
	if not decorations then
		if reservationInserted then
			Runtime.forgetKnownConnection(reservation)
		end
		return false, tostring(verifyError)
	end
	if outcome and outcome.remoteErrored then
		print(PREFIX .. label
			.. " recovered an exact server connection after the client remote errored")
	elseif outcome and outcome.reusedLive and Config.VerboseRemoteLogging then
		print(PREFIX .. label .. " reused an exact existing live connection")
	end
	Runtime.commitVerifiedConnection(connection, reservation, decorations)
	if Config.VerboseRemoteLogging then
		print(PREFIX .. string.format(
			"verified %s %s -> %s (%d decoration objects)",
			connectionLabel(connection),
			fromConnector:GetFullName(),
			toConnector:GetFullName(),
			#decorations
		))
	end
	return true
end

local function buildAuthoredPipeLink(link)
	local valid, fromConnector, toConnector, reasons = inspectAuthoredPipeLink(link, true)
	if not valid then
		return false, "last-second exact-link validation failed: " .. table.concat(reasons, "; ")
	end
	local label = string.format(
		"Authored pipe plug #%d (%s -> %s)",
		link.index,
		authoredEndpointLabel(link.entry.From),
		authoredEndpointLabel(link.entry.To)
	)
	local reserved, reservation, reservationInserted = Runtime.rememberKnownConnection(
		"Pipe",
		fromConnector,
		toConnector,
		true
	)
	if not reserved then
		return false, "could not reserve the exact duplicate replay path: " .. tostring(reservation)
	end
	if not reservationInserted
		and Runtime.reuseKnownConnectionIfExact(link, reservation, fromConnector, toConnector)
	then
		return true
	end
	local decorations, verifyError, outcome = Runtime.invokeAndVerifyConnection(
		link,
		fromConnector,
		toConnector,
		label,
		"server rejected the exact recorded plug"
	)
	if not decorations then
		if reservationInserted then
			Runtime.forgetKnownConnection(reservation)
		end
		return false, tostring(verifyError)
	end
	if outcome and outcome.remoteErrored then
		print(PREFIX .. label
			.. " recovered an exact server connection after the client remote errored")
	elseif outcome and outcome.reusedLive and Config.VerboseRemoteLogging then
		print(PREFIX .. label .. " reused an exact existing live connection")
	end
	Runtime.commitVerifiedConnection(link, reservation, decorations)
	if Config.VerboseRemoteLogging then
		print(PREFIX .. string.format(
			"verified authored pipe plug #%d (%d decoration objects)",
			link.index,
			#decorations
		))
	end
	return true
end

function Runtime.runBlueprintBuild()
	if State.destroyed then
		return false
	elseif State.building then
		return
	end
	if State.captureArmed or State.captureProcessing then
		notify("Build refused", "Finish or cancel the active placement Scan first.", 7)
		log("Build refused: a placement Scan is still active")
		return false
	end
	if not State.captured or not State.scanComplete then
		notify("Build refused", "Press Scan and normally place any supported building, pipe, or pump before building.", 8)
		log("Build refused: the current pasted blueprint has not been scanned")
		return
	end
	-- A connection completed by an earlier partial run can be removed before the
	-- user presses Resume. Turn only a missing exact decoration pair back into
	-- pending work; endpoint/placement changes remain hard blockers.
	local committedPlacementsOK, committedPlacementError = Runtime.auditCommittedBlueprintPlacements()
	local committedConnectionsOK, committedConnectionError = Runtime.auditCommittedBlueprintConnections(true)
	if not hasPendingBuildWork() then
		local committedError = not committedPlacementsOK and committedPlacementError
			or not committedConnectionsOK and committedConnectionError
		if committedError then
			notify("Build refused", "Verified work changed: " .. tostring(committedError), 9)
			log("Build refused: verified work changed: %s", tostring(committedError))
			return false, committedError
		end
		State.lastBuildFailure = nil
		State.validated = false
		Runtime.markConnectionManifestComplete(State.previews)
		Runtime.markConnectionManifestComplete(State.authoredPlacementPreviews)
		Runtime.reportBuildProgress("Complete", nil, nil, "All server work verified")
		notify("Build complete", "There is no remaining machine, pipe, or wire work.", 6)
		log("Build complete: there is no pending machine, pipe, or wire work")
		return true
	end
	if not committedConnectionsOK then
		log("Resume repair: %s", tostring(committedConnectionError))
	end
	-- One authoritative pass per Build/Resume heals any missed plot event before
	-- collision validation or late-reuse reconciliation can decide to send.
	Runtime.rescanPlacedRegistry()
	return Runtime.withPreparedPlacedCache(function(buildExisting)
	local hasBlueprintPreview = #State.previews > 0
		or #State.authoredPlacementPreviews > 0
		or #State.authoredLinkPreviews > 0
	local validationOK = hasBlueprintPreview and validatePreviews(buildExisting) or validateConnectionPreviews()
	if not validationOK then
		notify("Build refused", "Validation failed. Live status shows the first blocker; red previews and the console contain the full list.", 8)
		return
	end

	if State.duplicate.selecting and Runtime.stopDuplicateSelecting then
		Runtime.stopDuplicateSelecting(true)
	end
	State.building = true
	State.cancelRequested = false
	local completedMachines = 0
	local reusedMachines = 0
	local completedAuthoredPlacements = 0
	local reusedAuthoredPlacements = 0
	local completedAuthoredLinks = 0
	local completedWires = 0
	local priorMachines = builtItemCount(State.previews)
	local priorAuthoredPlacements = builtItemCount(State.authoredPlacementPreviews)
	local priorAuthoredLinks = builtItemCount(State.authoredLinkPreviews)
	local priorWires = builtItemCount(State.connectionPreviews)
	local failure = nil
	local knownPlacedModels = Runtime.knownPlacedModels(buildExisting)
	Runtime.rebuildSourceReferenceIndex()
	local startingCounts = Runtime.beginBuildProgress()
	Runtime.reportBuildProgress(
		"Starting",
		nil,
		nil,
		string.format("%d remaining operation(s)", startingCounts.remaining)
	)

	for _, preview in ipairs(State.previews) do
		if State.cancelRequested then
			failure = Runtime.buildCancellationReason()
			break
		end
		if preview.built then
			continue
		end
		-- Reconcile again at the last possible moment. A prevalidated reuse can
		-- move/change, while a delayed prior placement can appear after Preview.
		-- Reusing only an exact current match avoids both stale acceptance and a
		-- duplicate remote call.
		preview.reuseModel = matchingExistingMachine(preview, buildExisting)
		if preview.reuseModel and preview.reuseModel.Parent then
			if not validateCurrentPlacement(preview, buildExisting, preview.reuseModel) then
				failure = string.format(
					"#%d %s reuse failed last-second validation: %s",
					preview.index,
					preview.entry.Name,
					table.concat(preview.reasons, "; ")
				)
				break
			end
			preview.built = true
			preview.reusedServerModel = true
			preview.placedModel = preview.reuseModel
			State.sourceReferenceByModel[preview.placedModel] = { Machine = preview.index }
			preview.model:Destroy()
			preview.model = nil
			preview.base = nil
			reusedMachines += 1
			if Runtime.shouldReportResumedProgress(
				priorMachines,
				completedMachines + reusedMachines,
				#State.previews
			) then
				Runtime.reportBuildProgress(
					"Machines",
					priorMachines + completedMachines + reusedMachines,
					#State.previews,
					string.format("%d new, %d reused", completedMachines, reusedMachines)
				)
			end
			continue
		end
		if not preview.model or not preview.model.Parent or not preview.base then
			failure = string.format("#%d preview disappeared", preview.index)
			break
		end
		if not validateCurrentPlacement(preview, buildExisting) then
			failure = string.format(
				"#%d %s failed last-second validation: %s",
				preview.index,
				preview.entry.Name,
				table.concat(preview.reasons, "; ")
			)
			break
		end

		local packet, packetError = canonicalPacket(State.captured, preview.template, preview.targetCFrame)
		if not packet then
			failure = packetError
			break
		end

		local actionStartedAt = os.clock()
		Runtime.acknowledgePlacedCacheAdditions(buildExisting, knownPlacedModels)
		local watch = Runtime.beginPlacementWatch(knownPlacedModels)
		local callOK, serverResult = sendPlacement(State.captured, packet)
		if callOK and serverResult == false then
			Runtime.stopPlacementWatch(watch)
			failure = string.format("#%d server rejected %s", preview.index, preview.entry.Name)
			break
		end

		local placed, verifyError = verifyNewPlacement(watch, preview)
		if not placed then
			failure = not callOK and string.format(
				"#%d remote error: %s; no exact server placement was observed: %s",
				preview.index,
				tostring(serverResult),
				tostring(verifyError)
			) or string.format("#%d verification failed: %s", preview.index, verifyError)
			break
		end
		if not callOK then
			print(PREFIX .. string.format(
				"#%d %s recovered an exact server placement after the client remote errored",
				preview.index,
				preview.entry.Name
			))
		end

		preview.built = true
		preview.reusedServerModel = false
		preview.placedModel = placed
		State.sourceReferenceByModel[placed] = { Machine = preview.index }
		preview.model:Destroy()
		preview.model = nil
		preview.base = nil
		completedMachines += 1
		Runtime.mergePlacementWatchCandidates(buildExisting, knownPlacedModels, watch)
		Runtime.appendPlacedToCache(buildExisting, knownPlacedModels, placed)
		if Runtime.shouldReportResumedProgress(
			priorMachines,
			completedMachines + reusedMachines,
			#State.previews
		) then
			Runtime.reportBuildProgress(
				"Machines",
				priorMachines + completedMachines + reusedMachines,
				#State.previews,
				string.format("%d new, %d reused", completedMachines, reusedMachines)
			)
		end
		if not Runtime.waitForNextAction(Config.PlacementDelay, actionStartedAt) then
			failure = Runtime.buildCancellationReason()
			break
		end
	end

	-- Electrical endpoints can only reference Machines, never authored plumbing
	-- Pieces. Commit and verify wires immediately after the machine stage so a
	-- later strict pipe failure does not discard otherwise-valid electrical work;
	-- Resume will audit and skip every wire already proven on the server.
	if not failure then
		local committedOK, committedError = Runtime.auditCommittedBlueprintPlacements()
		if not committedOK then
			failure = "pre-wiring placement audit failed: " .. tostring(committedError)
		end
	end

	if not failure then
		for _, connection in ipairs(State.connectionPreviews) do
			if State.cancelRequested then
				failure = Runtime.buildCancellationReason()
				break
			end
			if connection.built then
				continue
			end
			local actionStartedAt = os.clock()
			local connected, connectionError = buildWireConnection(connection)
			if not connected then
				failure = connectionLabel(connection) .. " " .. connectionError
				break
			end
			completedWires += 1
			if Runtime.shouldReportResumedProgress(
				priorWires,
				completedWires,
				#State.connectionPreviews
			) then
				Runtime.reportBuildProgress(
					"Wires",
					priorWires + completedWires,
					#State.connectionPreviews
				)
			end
			if not Runtime.waitForNextAction(Config.ConnectionDelay, actionStartedAt) then
				failure = Runtime.buildCancellationReason()
				break
			end
		end
	end

	if not failure then
		for _, preview in ipairs(State.authoredPlacementPreviews) do
			if State.cancelRequested then
				failure = Runtime.buildCancellationReason()
				break
			end
			if preview.built then
				continue
			end
			preview.reuseModel = matchingExistingMachine(preview, buildExisting)
			if preview.reuseModel and preview.reuseModel.Parent then
				if not validateCurrentPlacement(preview, buildExisting, preview.reuseModel) then
					failure = string.format(
						"authored plumbing piece #%d %s reuse failed last-second validation: %s",
						preview.index,
						preview.entry.Name,
						table.concat(preview.reasons, "; ")
					)
					break
				end
				preview.built = true
				preview.reusedServerModel = true
				preview.placedModel = preview.reuseModel
				State.sourceReferenceByModel[preview.placedModel] = { Piece = preview.index }
				if preview.model then
					preview.model:Destroy()
				end
				preview.model = nil
				preview.base = nil
				reusedAuthoredPlacements += 1
				if Runtime.shouldReportResumedProgress(
					priorAuthoredPlacements,
					completedAuthoredPlacements + reusedAuthoredPlacements,
					#State.authoredPlacementPreviews
				) then
					Runtime.reportBuildProgress(
						"Plumbing pieces",
						priorAuthoredPlacements + completedAuthoredPlacements + reusedAuthoredPlacements,
						#State.authoredPlacementPreviews,
						string.format(
							"%d new, %d reused",
							completedAuthoredPlacements,
							reusedAuthoredPlacements
						)
					)
				end
				continue
			end
			if not preview.model or not preview.model.Parent or not preview.base then
				failure = string.format("authored plumbing piece #%d preview disappeared", preview.index)
				break
			end
			if not validateCurrentPlacement(preview, buildExisting) then
				failure = string.format(
					"authored plumbing piece #%d %s failed last-second validation: %s",
					preview.index,
					preview.entry.Name,
					table.concat(preview.reasons, "; ")
				)
				break
			end

			local packet, packetError = canonicalPacket(State.captured, preview.template, preview.targetCFrame, false)
			if not packet then
				failure = packetError
				break
			end
			local actionStartedAt = os.clock()
			Runtime.acknowledgePlacedCacheAdditions(buildExisting, knownPlacedModels)
			local watch = Runtime.beginPlacementWatch(knownPlacedModels)
			local callOK, serverResult = sendPlacement(State.captured, packet)
			if callOK and serverResult == false then
				Runtime.stopPlacementWatch(watch)
				failure = string.format(
					"server rejected authored plumbing piece #%d %s",
					preview.index,
					preview.entry.Name
				)
				break
			end
			local placed, verifyError = verifyNewPlacement(watch, preview)
			if not placed then
				failure = not callOK and string.format(
					"authored plumbing piece #%d remote error: %s; no exact server placement was observed: %s",
					preview.index,
					tostring(serverResult),
					tostring(verifyError)
				) or string.format(
					"authored plumbing piece #%d verification failed: %s",
					preview.index,
					tostring(verifyError)
				)
				break
			end
			if not callOK then
				print(PREFIX .. string.format(
					"authored plumbing piece #%d %s recovered an exact server placement after the client remote errored",
					preview.index,
					preview.entry.Name
				))
			end

			preview.built = true
			preview.reusedServerModel = false
			preview.placedModel = placed
			State.sourceReferenceByModel[placed] = { Piece = preview.index }
			preview.model:Destroy()
			preview.model = nil
			preview.base = nil
			completedAuthoredPlacements += 1
			Runtime.mergePlacementWatchCandidates(buildExisting, knownPlacedModels, watch)
			Runtime.appendPlacedToCache(buildExisting, knownPlacedModels, placed)
			if Runtime.shouldReportResumedProgress(
				priorAuthoredPlacements,
				completedAuthoredPlacements + reusedAuthoredPlacements,
				#State.authoredPlacementPreviews
			) then
				Runtime.reportBuildProgress(
					"Plumbing pieces",
					priorAuthoredPlacements + completedAuthoredPlacements + reusedAuthoredPlacements,
					#State.authoredPlacementPreviews,
					string.format(
						"%d new, %d reused",
						completedAuthoredPlacements,
						reusedAuthoredPlacements
					)
				)
			end
			if not Runtime.waitForNextAction(Config.PlacementDelay, actionStartedAt) then
				failure = Runtime.buildCancellationReason()
				break
			end
		end
	end

	if not failure then
		local committedOK, committedError = Runtime.auditCommittedBlueprintPlacements()
		if not committedOK then
			failure = "pre-connection placement audit failed: " .. tostring(committedError)
		end
	end

	if not failure then
		for _, link in ipairs(State.authoredLinkPreviews) do
			if State.cancelRequested then
				failure = Runtime.buildCancellationReason()
				break
			end
			if link.built then
				continue
			end
			local actionStartedAt = os.clock()
			local connected, connectionError = buildAuthoredPipeLink(link)
			if not connected then
				failure = string.format("authored pipe plug #%d %s", link.index, connectionError)
				break
			end
			completedAuthoredLinks += 1
			if Runtime.shouldReportResumedProgress(
				priorAuthoredLinks,
				completedAuthoredLinks,
				#State.authoredLinkPreviews
			) then
				Runtime.reportBuildProgress(
					"Pipe links",
					priorAuthoredLinks + completedAuthoredLinks,
					#State.authoredLinkPreviews
				)
			end
			if not Runtime.waitForNextAction(Config.ConnectionDelay, actionStartedAt) then
				failure = Runtime.buildCancellationReason()
				break
			end
		end
	end

	if not failure then
		local committedOK, committedError = Runtime.auditCommittedBlueprintPlacements()
		if not committedOK then
			failure = "final placement audit failed: " .. tostring(committedError)
		end
	end
	if not failure then
		local committedOK, committedError = Runtime.auditCommittedBlueprintConnections(true)
		if not committedOK then
			failure = "final connection audit failed: " .. tostring(committedError)
		end
	end

	State.building = false
	State.validated = false
	if failure then
		State.lastBuildFailure = failure
		warn(PREFIX .. "BUILD STOPPED: " .. failure)
		if not State.destroyed then
			log(
				"BUILD STOPPED after %d new + %d reused machine(s), %d new + %d reused authored plumbing placement(s), %d exact plug(s), and %d wire(s): %s",
				completedMachines,
				reusedMachines,
				completedAuthoredPlacements,
				reusedAuthoredPlacements,
				completedAuthoredLinks,
				completedWires,
				failure
			)
			local stoppedCounts = Runtime.buildWorkCounts()
			Runtime.reportBuildProgress(
				"Stopped",
				nil,
				nil,
				string.format(
					"%d operation(s) remain • press Build / Resume Remaining • %s",
					stoppedCounts.remaining,
					failure
				)
			)
			notify("BUILD STOPPED", failure, 10)
		end
		return false, failure
	else
		State.lastBuildFailure = nil
		Runtime.markConnectionManifestComplete(State.previews)
		Runtime.markConnectionManifestComplete(State.authoredPlacementPreviews)
		log(
			"Blueprint complete: %d machine(s), %d physical plumbing placement(s), %d exact pipe plug(s), and %d wire(s) verified (this run: %d new + %d reused machine(s), %d new + %d reused plumbing placement(s))",
			#State.previews,
			#State.authoredPlacementPreviews,
			#State.authoredLinkPreviews,
			#State.connectionPreviews,
			completedMachines,
			reusedMachines,
			completedAuthoredPlacements,
			reusedAuthoredPlacements
		)
		Runtime.reportBuildProgress("Complete", nil, nil, "All server work verified")
		notify("Blueprint complete", string.format(
			"%d machine(s), %d physical plumbing placement(s), %d exact plug(s), and %d wire(s) verified.",
			#State.previews,
			#State.authoredPlacementPreviews,
			#State.authoredLinkPreviews,
			#State.connectionPreviews
		), 8)
		return true
	end
	end)
end

local function buildBlueprint()
	if State.previewInProgress then
		local message = "Wait for the active Preview to finish before building."
		notify("Build waiting", message, 6)
		return false, message
	elseif State.autoFitInProgress then
		local message = Runtime.autoFitBusyReason()
		notify("Build waiting", message, 6)
		return false, message
	elseif State.building then
		return false, "A blueprint build is already running."
	end
	local leaseToken, leaseError = Runtime.acquireBuildLease()
	if not leaseToken then
		if not State.destroyed then
			notify("Build waiting", leaseError, 7)
			log("Build waiting: %s", leaseError)
		end
		return false
	end
	State.buildLeaseToken = leaseToken
	State.buildRemoteAttempted = false
	local ok, result, detail = pcall(Runtime.runBlueprintBuild)
	Runtime.stopAllBuildWatches()
	State.replaying = false
	State.building = false
	local quarantine = State.buildRemoteAttempted
		and (not ok or result == false or State.cancelRequested or State.destroyed)
	Runtime.releaseBuildLease(leaseToken, quarantine)
	State.buildLeaseToken = nil
	State.buildRemoteAttempted = false
	if not ok then
		State.validated = false
		warn(PREFIX .. "BUILD ERROR: " .. tostring(result))
		if not State.destroyed then
			log("BUILD ERROR: %s", tostring(result))
			notify("BUILD ERROR", tostring(result), 10)
		end
		return false, tostring(result)
	end
	return result, detail
end

local function useMyPosition()
	if State.building then
		notify("Origin unchanged", "A blueprint build is currently running.", 6)
		return
	end
	local character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
	local root = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
	if not root then
		notify("Origin failed", "Character has no HumanoidRootPart/PrimaryPart.", 7)
		return
	end
	local requestedX = root.Position.X
	local requestedZ = root.Position.Z
	local applied = applyLayoutSettings(requestedX, requestedZ, State.layoutRotation, true)
	if not applied then
		return nil
	end
	notify(
		"Base moved to you",
		string.format("Base X %.0f, Z %.0f • rotation %d°.", State.originX, State.originZ, State.layoutRotation),
		6
	)
	return State.originX, State.originZ
end

-- Dedicated server-backed duplication workflow. Selection is taken from real
-- placed plot Models, but copies are always rebuilt from their canonical
-- ReplicatedStorage templates. This avoids client-only Clone() results that
-- look correct locally but do not exist for the server or other players.
Runtime.DuplicatePreviewFolder = "__IndustrialistDuplicatePreview"
Runtime.DuplicateSelectionHighlight = "__IndustrialistDuplicateSelection"

function Runtime.clearDuplicateMarquee()
	local duplicate = State.duplicate
	duplicate.marqueeArmed = false
	duplicate.marqueeDragging = false
	duplicate.marqueeStartX = nil
	duplicate.marqueeStartZ = nil
	if duplicate.marqueeBox then
		duplicate.marqueeBox:Destroy()
		duplicate.marqueeBox = nil
	end
	if duplicate.marqueePart then
		duplicate.marqueePart:Destroy()
		duplicate.marqueePart = nil
	end
end

function Runtime.disconnectDuplicateClick()
	local duplicate = State.duplicate
	duplicate.clickGeneration += 1
	duplicate.armedAction = nil
	duplicate.selecting = false
	if duplicate.clickConnection then
		pcall(function()
			duplicate.clickConnection:Disconnect()
		end)
		duplicate.clickConnection = nil
	end
	if duplicate.hoverConnection then
		pcall(function()
			duplicate.hoverConnection:Disconnect()
		end)
		duplicate.hoverConnection = nil
	end
	if duplicate.releaseConnection then
		pcall(function()
			duplicate.releaseConnection:Disconnect()
		end)
		duplicate.releaseConnection = nil
	end
	if duplicate.hoverBox then
		duplicate.hoverBox:Destroy()
		duplicate.hoverBox = nil
	end
	Runtime.clearDuplicateMarquee()
end

function Runtime.duplicateSelectionSummary()
	local duplicate = State.duplicate
	local names = {}
	for index, item in ipairs(duplicate.selected) do
		if index > 3 then
			table.insert(names, string.format("+%d more", #duplicate.selected - 3))
			break
		end
		table.insert(names, item.name)
	end
	return #names > 0 and table.concat(names, ", ") or "none"
end

function Runtime.updateDuplicateStatus(extra)
	local duplicate = State.duplicate
	local destination = duplicate.destinationX and string.format(
		"X %.0f, Z %.0f",
		duplicate.destinationX,
		duplicate.destinationZ
	) or "not picked"
	setParagraph(
		duplicate.statusParagraph,
		"Duplicate status",
		string.format(
			"Selected %d/%d: %s. Destination: %s. Rotation: %d°.%s",
			#duplicate.selected,
			Config.MaxDuplicateSelection,
			Runtime.duplicateSelectionSummary(),
			destination,
			duplicate.rotation,
			extra and (" " .. extra) or ""
		)
	)
end

function Runtime.getDuplicatePreviewFolder()
	local folder = workspace:FindFirstChild(Runtime.DuplicatePreviewFolder)
	if folder and not folder:IsA("Folder") then
		return nil, "workspace." .. Runtime.DuplicatePreviewFolder .. " is not a Folder"
	end
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = Runtime.DuplicatePreviewFolder
		folder.Parent = workspace
	end
	return folder
end

function Runtime.duplicateAuditLockReason()
	local duplicate = State.duplicate
	if duplicate.connectionAuditInProgress then
		return "The exact pipe/wire graph is currently being audited. Wait for that two-frame inspection to finish before changing the duplicate workspace."
	end
	local committedPlacements = 0
	local uncertainPlacements = 0
	local committedConnections = 0
	for _, preview in ipairs(duplicate.previews) do
		if preview.built then
			committedPlacements += 1
		elseif preview.recoveryKnownModels ~= nil then
			uncertainPlacements += 1
		end
	end
	for _, plan in ipairs(duplicate.connections) do
		if plan.built then
			committedConnections += 1
		end
	end
	if committedPlacements == 0
		and uncertainPlacements == 0
		and committedConnections == 0
	then
		return nil
	end
	return string.format(
		"Resume/audit state is locked after server progress (%d placement(s), %d uncertain placement(s), %d connection(s)). Use DUPLICATE NOW to Resume Remaining; Destroy is the explicit way to abandon this recovery history.",
		committedPlacements,
		uncertainPlacements,
		committedConnections
	)
end

function Runtime.clearDuplicatePreview(silent, force)
	if State.building then
		local message = "A placement build is currently running."
		if not silent then
			notify("Duplicate preview kept", message, 6)
		end
		return false, message
	end
	local auditLockReason = not force and Runtime.duplicateAuditLockReason() or nil
	if auditLockReason then
		if not silent then
			notify("Duplicate preview kept", auditLockReason, 9)
			Runtime.updateDuplicateStatus(auditLockReason)
		end
		return false, auditLockReason
	end
	local folder = workspace:FindFirstChild(Runtime.DuplicatePreviewFolder)
	if folder and folder:IsA("Folder") then
		folder:ClearAllChildren()
	end
	State.duplicate.previews = {}
	State.duplicate.connections = {}
	State.duplicate.connectionStats = nil
	State.duplicate.validated = false
	if not silent then
		Runtime.updateDuplicateStatus("Duplicate preview cleared.")
	end
	return true
end

function Runtime.destroyDuplicateSelectionHighlights()
	for _, highlight in pairs(State.duplicate.highlights) do
		if highlight and highlight.Parent then
			highlight:Destroy()
		end
	end
	table.clear(State.duplicate.highlights)
	for _, selectionBox in pairs(State.duplicate.selectionBoxes) do
		if selectionBox and selectionBox.Parent then
			selectionBox:Destroy()
		end
	end
	table.clear(State.duplicate.selectionBoxes)
end

function Runtime.resetDuplicateSelection(silent, force)
	if State.building then
		local message = "A placement build is currently running."
		if not silent then
			notify("Selection kept", message, 6)
		end
		return false, message
	elseif State.autoFitInProgress and not force then
		local message = Runtime.autoFitBusyReason()
		if not silent then
			notify("Selection kept", message, 6)
		end
		return false, message
	end
	local auditLockReason = not force and Runtime.duplicateAuditLockReason() or nil
	if auditLockReason then
		if not silent then
			notify("Selection kept", auditLockReason, 9)
			Runtime.updateDuplicateStatus(auditLockReason)
		end
		return false, auditLockReason
	end
	Runtime.disconnectDuplicateClick()
	Runtime.clearDuplicatePreview(true, force)
	Runtime.destroyDuplicateSelectionHighlights()
	local duplicate = State.duplicate
	table.clear(duplicate.selected)
	table.clear(duplicate.byModel)
	duplicate.selectionVersion += 1
	duplicate.sourceAnchorX = nil
	duplicate.sourceAnchorZ = nil
	duplicate.destinationX = nil
	duplicate.destinationZ = nil
	if not silent then
		Runtime.updateDuplicateStatus("Selection cleared.")
	end
	return true
end

function Runtime.placedRootFromTarget(target)
	local current = target
	while current and current ~= Plots do
		if current:IsA("Model") and current:IsDescendantOf(Plots) then
			local base = current:FindFirstChild("Base")
			if base and base:IsA("BasePart") then
				return current, base
			end
		end
		current = current.Parent
	end
	return nil, nil, "Click a server-placed machine, pump, or physical pipe inside a plot."
end

function Runtime.placedDescriptor(model, base)
	return {
		model = model,
		base = base,
		name = Runtime.nonEmptyAttributeString(model, "Name") or model.Name,
		modelName = model.Name,
		attributeName = Runtime.nonEmptyAttributeString(model, "Name"),
		category = Runtime.nonEmptyAttributeString(model, "Category"),
		id = model:GetAttribute("ID"),
	}
end

function Runtime.connectorPathInModel(model, connector)
	if not model or not connector or not connector:IsDescendantOf(model) then
		return nil, "connector is not inside its placed model"
	end
	local reversed = {}
	local current = connector
	while current and current ~= model do
		local parent = current.Parent
		if not parent then
			return nil, "connector path became detached"
		end
		local ordinal = 0
		local currentOrdinal
		for _, child in ipairs(parent:GetChildren()) do
			if child.Name == current.Name and child.ClassName == current.ClassName then
				ordinal += 1
				if child == current then
					currentOrdinal = ordinal
					break
				end
			end
		end
		if not currentOrdinal then
			return nil, "connector path could not be indexed"
		end
		table.insert(reversed, {
			Name = current.Name,
			ClassName = current.ClassName,
			Ordinal = currentOrdinal,
		})
		current = parent
	end
	local path = {}
	for index = #reversed, 1, -1 do
		table.insert(path, reversed[index])
	end
	return path
end

function Runtime.connectionConnectorRecords(model, kind)
	if not model or not model.Parent or (kind ~= "Pipe" and kind ~= "Wire") then
		return {}
	end
	local cache = State.connectionConnectorCache
	local modelCache = cache[model]
	if not modelCache then
		modelCache = {}
		cache[model] = modelCache
	end
	local cached = modelCache[kind]
	if cached then
		for _, record in ipairs(cached) do
			local connector = record.connector
			if not connector.Parent or not connector:IsDescendantOf(model) then
				modelCache[kind] = nil
				cached = nil
				break
			end
		end
	end
	if cached then
		return cached, true
	end

	local folderName = kind == "Pipe" and "Pipe" or "Power"
	local records = {}
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			local metadata = descendant:FindFirstChild(folderName)
			if metadata and metadata:IsA("Folder")
				and Runtime.placedRootFromTarget(descendant) == model
			then
				local path = Runtime.connectorPathInModel(model, descendant)
				if path then
					table.insert(records, {
						connector = descendant,
						metadata = metadata,
						path = path,
					})
				end
			end
		end
	end
	modelCache[kind] = records
	return records, false
end

function Runtime.resolveConnectorPath(model, path)
	return Runtime.resolveStoredConnectorPath(model, path)
end

function Runtime.indexKnownConnection(known)
	local kindIndex = type(known) == "table" and State.knownConnectionIndex[known.kind]
	if not kindIndex or not known.fromConnector or not known.toConnector then
		return
	end
	local targets = kindIndex[known.fromConnector]
	if not targets then
		targets = {}
		kindIndex[known.fromConnector] = targets
	end
	-- First-record semantics match the previous source-ordered linear lookup.
	targets[known.toConnector] = targets[known.toConnector] or known
end

function Runtime.unindexKnownConnection(known)
	local kindIndex = type(known) == "table" and State.knownConnectionIndex[known.kind]
	local targets = kindIndex and kindIndex[known.fromConnector]
	if not targets or targets[known.toConnector] ~= known then
		return
	end
	targets[known.toConnector] = nil
	if not next(targets) then
		kindIndex[known.fromConnector] = nil
	end
end

function Runtime.findIndexedKnownConnection(kind, fromConnector, toConnector)
	local kindIndex = State.knownConnectionIndex[kind]
	local targets = kindIndex and kindIndex[fromConnector]
	return targets and targets[toConnector]
end

function Runtime.rememberKnownConnection(kind, fromConnector, toConnector, pending)
	if kind ~= "Pipe" and kind ~= "Wire" then
		return false, "unsupported known connection kind"
	end
	local fromModel = Runtime.placedRootFromTarget(fromConnector)
	local toModel = Runtime.placedRootFromTarget(toConnector)
	if not fromModel or not toModel then
		return false, "connection endpoints are not inside placed models"
	end
	local indexed = Runtime.findIndexedKnownConnection(kind, fromConnector, toConnector)
	local fromPath, fromPathError = Runtime.connectorPathInModel(fromModel, fromConnector)
	local toPath, toPathError = Runtime.connectorPathInModel(toModel, toConnector)
	if not fromPath then
		return false, "From: " .. tostring(fromPathError)
	elseif not toPath then
		return false, "To: " .. tostring(toPathError)
	end
	if indexed then
		if pending ~= true then
			indexed.confirmed = true
		end
		return true, indexed, false
	end
	if #State.knownConnections >= Config.MaxConnections then
		for index = #State.knownConnections, 1, -1 do
			local existing = State.knownConnections[index]
			if type(existing) ~= "table"
				or not existing.fromModel
				or not existing.fromModel.Parent
				or not existing.toModel
				or not existing.toModel.Parent
			then
				Runtime.unindexKnownConnection(existing)
				table.remove(State.knownConnections, index)
			end
		end
	end
	if #State.knownConnections >= Config.MaxConnections then
		return false, "known connection registry is full"
	end
	local known = {
		kind = kind,
		fromModel = fromModel,
		toModel = toModel,
		fromConnector = fromConnector,
		toConnector = toConnector,
		fromConnectorName = fromConnector.Name,
		toConnectorName = toConnector.Name,
		fromConnectorPath = fromPath,
		toConnectorPath = toPath,
		confirmed = pending ~= true,
	}
	table.insert(State.knownConnections, known)
	Runtime.indexKnownConnection(known)
	return true, known, true
end

function Runtime.forgetKnownConnection(known)
	for index = #State.knownConnections, 1, -1 do
		if State.knownConnections[index] == known then
			Runtime.unindexKnownConnection(known)
			table.remove(State.knownConnections, index)
			return true
		end
	end
	return false
end

function Runtime.knownConnectionStillObserved(known)
	if type(known) ~= "table" or known.confirmed == false then
		return false
	elseif known.decorations == nil then
		-- Legacy/manual records created before decoration provenance was added
		-- remain usable for loaded-graph exact-path upgrades, but return unknown
		-- so they can never make a registry manifest authoritative by themselves.
		return nil
	elseif type(known.decorations) ~= "table" then
		return false
	end
	local expectedName = known.kind == "Pipe" and "Pipe" or "Power"
	local observed = 0
	for _, decoration in ipairs(known.decorations) do
		if typeof(decoration) == "Instance"
			and decoration.Parent
			and decoration.Name == expectedName
			and decoration:IsDescendantOf(ConnectionDecorations)
		then
			observed += 1
			if observed >= Config.ConnectionDecorationCount then
				return true
			end
		end
	end
	local fromConnector = known.fromConnector
	local toConnector = known.toConnector
	if typeof(fromConnector) == "Instance" and fromConnector.Parent
		and typeof(toConnector) == "Instance" and toConnector.Parent
	then
		local refreshed = Runtime.refreshConnectionDecorations(
			known.kind,
			fromConnector,
			toConnector,
			known.decorations
		)
		if refreshed then
			known.decorations = refreshed
			return true
		end
	end
	return false
end

function Runtime.restoreKnownConnections(previousConnections)
	for _, known in ipairs(type(previousConnections) == "table" and previousConnections or {}) do
		if #State.knownConnections >= Config.MaxConnections then
			break
		end
		if type(known) == "table"
			and (known.kind == "Pipe" or known.kind == "Wire")
			and known.fromModel
			and known.fromModel.Parent
			and known.toModel
			and known.toModel.Parent
			and type(known.fromConnectorPath) == "table"
			and type(known.toConnectorPath) == "table"
			and known.confirmed ~= false
		then
			local restored = {
				kind = known.kind,
				fromModel = known.fromModel,
				toModel = known.toModel,
				fromConnector = known.fromConnector,
				toConnector = known.toConnector,
				fromConnectorName = known.fromConnectorName,
				toConnectorName = known.toConnectorName,
				fromConnectorPath = Runtime.copyConnectorPath(known.fromConnectorPath),
				toConnectorPath = Runtime.copyConnectorPath(known.toConnectorPath),
				confirmed = true,
				decorations = type(known.decorations) == "table" and known.decorations or nil,
			}
			table.insert(State.knownConnections, restored)
			Runtime.indexKnownConnection(restored)
		end
	end
end

function Runtime.restoreCompleteConnectionModels(previousModels)
	for model, complete in pairs(type(previousModels) == "table" and previousModels or {}) do
		if complete == true and typeof(model) == "Instance" and model.Parent then
			State.completeConnectionModels[model] = true
		end
	end
end

function Runtime.restorePhysicalPlumbingModels(previousModels)
	for model, physical in pairs(type(previousModels) == "table" and previousModels or {}) do
		if physical == true and typeof(model) == "Instance" and model.Parent then
			State.physicalPlumbingModels[model] = true
		end
	end
end

function Runtime.markConnectionManifestComplete(previews)
	for _, preview in ipairs(type(previews) == "table" and previews or {}) do
		local model = preview and (preview.placedModel or preview.reuseModel)
		local provenanceIsComplete = preview
			and (preview.reusedServerModel ~= true or State.completeConnectionModels[model] == true)
		if model and model.Parent and provenanceIsComplete then
			State.completeConnectionModels[model] = true
			if preview.kind == "AuthoredPlumbing"
				or preview.kind == "AutoPlumbing"
				or (preview.sourceItem and preview.sourceItem.isPhysicalPlumbing == true)
			then
				State.physicalPlumbingModels[model] = true
			end
		end
	end
end

function Runtime.canonicalTemplateForPlacedModel(model, base)
	local placed = Runtime.placedDescriptor(model, base)
	local cacheKey = table.concat({
		tostring(placed.category),
		tostring(placed.modelName),
		tostring(placed.attributeName),
		tostring(placed.id),
	}, "\31")
	local cached = State.canonicalTemplateCache[cacheKey]
	if cached then
		return cached.template, cached.error
	end
	local matches = {}
	local seen = {}

	local function consider(template)
		if template
			and template:IsA("Model")
			and template.PrimaryPart
			and template:FindFirstChild("Base")
			and not seen[template]
			and Runtime.placedModelMatchesTemplate(placed, template)
		then
			seen[template] = true
			table.insert(matches, template)
		end
	end

	if placed.category then
		local category = Buildings:FindFirstChild(placed.category)
		if category then
			consider(category:FindFirstChild(placed.modelName))
			if placed.attributeName then
				consider(category:FindFirstChild(placed.attributeName))
			end
			for _, template in ipairs(category:GetChildren()) do
				consider(template)
			end
		end
	else
		for _, category in ipairs(Buildings:GetChildren()) do
			if category:IsA("Folder") then
				consider(category:FindFirstChild(placed.modelName))
				if placed.attributeName then
					consider(category:FindFirstChild(placed.attributeName))
				end
			end
		end
		if #matches == 0 and placed.id ~= nil then
			for _, category in ipairs(Buildings:GetChildren()) do
				for _, template in ipairs(category:GetChildren()) do
					consider(template)
				end
			end
		end
	end

	if #matches == 1 then
		State.canonicalTemplateCache[cacheKey] = { template = matches[1] }
		return matches[1]
	elseif #matches == 0 then
		local templateError = string.format(
			"%s does not match a canonical PlacementSystem.Buildings template.",
			model.Name
		)
		State.canonicalTemplateCache[cacheKey] = { error = templateError }
		return nil, templateError
	end
	local templateError = string.format(
		"%s matches %d catalog templates; its Category/ID is too ambiguous to duplicate safely.",
		model.Name,
		#matches
	)
	State.canonicalTemplateCache[cacheKey] = { error = templateError }
	return nil, templateError
end

function Runtime.normalizedQuarterTurnFromCFrame(cframe)
	local look = cframe.LookVector
	local raw = math.deg(math.atan2(-look.X, -look.Z))
	local snapped = math.round(raw / 90) * 90
	local difference = ((raw - snapped + 180) % 360) - 180
	if math.abs(difference) > 3 then
		return nil, string.format("placement rotation %.2f° is not on a 90° grid", raw)
	end
	return ((snapped % 360) + 360) % 360
end

function Runtime.canonicalTemplateBaseTransforms(template)
	local cached = State.templateBaseTransformCache[template]
	if cached then
		return cached
	end
	if not template or not template:IsA("Model") then
		return nil, "canonical template is not a Model"
	end
	local templateBase = template:FindFirstChild("Base")
	if not templateBase or not templateBase:IsA("BasePart") then
		return nil, template.Name .. " has no direct Base"
	end
	local baseFromPivot = template:GetPivot():ToObjectSpace(templateBase.CFrame)
	local transforms = {
		baseFromPivot = baseFromPivot,
		pivotFromBase = baseFromPivot:Inverse(),
	}
	State.templateBaseTransformCache[template] = transforms
	return transforms
end

function Runtime.rebuildSourceReferenceIndex()
	State.sourceReferenceByModel = setmetatable({}, { __mode = "k" })
	State.sourceReferenceMachineSet = State.previews
	State.sourceReferencePlumbingSet = State.authoredPlacementPreviews
	for index, preview in ipairs(State.previews) do
		local model = preview.placedModel or preview.reuseModel
		if model then
			State.sourceReferenceByModel[model] = { Machine = index }
		end
	end
	for index, preview in ipairs(State.authoredPlacementPreviews) do
		local model = preview.placedModel or preview.reuseModel
		if model then
			State.sourceReferenceByModel[model] = { Piece = index }
		end
	end
end

function Runtime.duplicateSourceReference(model)
	if State.sourceReferenceMachineSet ~= State.previews
		or State.sourceReferencePlumbingSet ~= State.authoredPlacementPreviews
	then
		Runtime.rebuildSourceReferenceIndex()
	end
	local reference = State.sourceReferenceByModel[model]
	if reference then
		return reference
	end
	-- A build can assign placedModel fields after the current preview arrays
	-- were indexed. Resolve that one new model once, then make later selection
	-- and graph-planning lookups O(1).
	for index, preview in ipairs(State.previews) do
		if preview.placedModel == model or preview.reuseModel == model then
			reference = { Machine = index }
			State.sourceReferenceByModel[model] = reference
			return reference
		end
	end
	for index, preview in ipairs(State.authoredPlacementPreviews) do
		if preview.placedModel == model or preview.reuseModel == model then
			reference = { Piece = index }
			State.sourceReferenceByModel[model] = reference
			return reference
		end
	end
	return nil
end

function Runtime.duplicateSelectionItem(model, base)
	local template, templateError = Runtime.canonicalTemplateForPlacedModel(model, base)
	if not template then
		return nil, templateError
	end
	local templateTransforms, transformError = Runtime.canonicalTemplateBaseTransforms(template)
	if not templateTransforms then
		return nil, transformError
	end
	local sourceTarget = base.CFrame * templateTransforms.pivotFromBase
	local sourceX = math.round(sourceTarget.Position.X)
	local sourceZ = math.round(sourceTarget.Position.Z)
	if math.abs(sourceTarget.Position.X - sourceX) > 0.12
		or math.abs(sourceTarget.Position.Z - sourceZ) > 0.12
	then
		return nil, string.format(
			"%s is off the server placement grid (pivot %.3f, %.3f).",
			model.Name,
			sourceTarget.Position.X,
			sourceTarget.Position.Z
		)
	end
	local sourceRotation, rotationError = Runtime.normalizedQuarterTurnFromCFrame(sourceTarget)
	if sourceRotation == nil then
		return nil, model.Name .. " " .. rotationError
	end
	return {
		model = model,
		base = base,
		-- Preserve the exact source OBB. A rigid duplicate is allowed to keep an
		-- overlap that already exists in the live source factory, but it must still
		-- reject every overlap newly introduced at the destination.
		sourceFootprint = footprint(base),
		sourceBaseCFrame = base.CFrame,
		sourceBaseSize = base.Size,
		template = template,
		category = template.Parent.Name,
		name = template.Name,
		sourceX = sourceX,
		sourceZ = sourceZ,
		sourceRotation = sourceRotation,
		sourceReference = Runtime.duplicateSourceReference(model),
	}
end

function Runtime.destroyDuplicateSelectionVisualsForModel(model)
	if not model then
		return
	end
	local duplicate = State.duplicate
	local highlight = duplicate.highlights[model]
	if highlight and highlight.Parent then
		highlight:Destroy()
	end
	duplicate.highlights[model] = nil
	local selectionBox = duplicate.selectionBoxes[model]
	if selectionBox and selectionBox.Parent then
		selectionBox:Destroy()
	end
	duplicate.selectionBoxes[model] = nil
end

function Runtime.attachDuplicateSelectionVisuals(model, base)
	Runtime.destroyDuplicateSelectionVisualsForModel(model)
	local previousHighlight = model:FindFirstChild(Runtime.DuplicateSelectionHighlight)
	if previousHighlight then
		previousHighlight:Destroy()
	end
	local highlight = Instance.new("Highlight")
	highlight.Name = Runtime.DuplicateSelectionHighlight
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.FillColor = Color3.fromRGB(57, 170, 255)
	highlight.OutlineColor = Color3.fromRGB(205, 239, 255)
	highlight.FillTransparency = 0.67
	highlight.OutlineTransparency = 0.04
	-- The SelectionBox already communicates the footprint. Keep the fill on the
	-- one Base instead of asking Highlight to traverse a detailed factory model.
	highlight.Adornee = base
	highlight.Parent = model
	State.duplicate.highlights[model] = highlight
	local selectionBox = Instance.new("SelectionBox")
	selectionBox.Name = "__IndustrialistDuplicateSelectedBox"
	selectionBox.Adornee = base
	selectionBox.Color3 = Color3.fromRGB(74, 183, 255)
	selectionBox.SurfaceColor3 = Color3.fromRGB(74, 183, 255)
	selectionBox.SurfaceTransparency = 0.93
	selectionBox.LineThickness = 0.055
	selectionBox.Parent = base
	State.duplicate.selectionBoxes[model] = selectionBox
end

function Runtime.pruneStaleDuplicateSelection(silent)
	local duplicate = State.duplicate
	local stale = {}
	local refreshed = {}
	local claimedModels = {}
	local changed = false
	local refreshedChangedCount = 0
	local anchorPoseChanged = false
	for index, item in ipairs(duplicate.selected) do
		local live = false
		local checkOK = pcall(function()
			local model = item and item.model
			local base = item and item.base
			live = typeof(model) == "Instance"
				and typeof(base) == "Instance"
				and model.Parent ~= nil
				and base.Parent ~= nil
				and model:IsDescendantOf(Plots)
				and base:IsDescendantOf(model)
				and model:FindFirstChild("Base") == base
				and base:IsA("BasePart")
		end)
		if checkOK and live then
			local current, currentError = Runtime.duplicateSelectionItem(item.model, item.base)
			if not current then
				return 0, string.format(
					"Selected source #%d %s changed into an invalid placement: %s",
					index,
					tostring(item.name),
					tostring(currentError)
				)
			elseif current.template ~= item.template then
				return 0, string.format(
					"Selected source #%d changed catalog identity from %s to %s; select it again.",
					index,
					tostring(item.name),
					tostring(current.name)
				)
			end
			current.sourceReference = current.sourceReference or item.sourceReference
			refreshed[index] = current
			claimedModels[current.model] = true
			local poseChanged = current.sourceX ~= item.sourceX
				or current.sourceZ ~= item.sourceZ
				or current.sourceRotation ~= item.sourceRotation
			local geometryChanged = current.sourceBaseCFrame ~= item.sourceBaseCFrame
				or current.sourceBaseSize ~= item.sourceBaseSize
			if poseChanged or geometryChanged then
				changed = true
				refreshedChangedCount += 1
				if index == 1 and poseChanged then
					anchorPoseChanged = true
				end
			end
		else
			table.insert(stale, index)
		end
	end

	local replacements = {}
	if #stale > 0 then
		local candidates = collectPlacedMachines()
		for _, index in ipairs(stale) do
			local oldItem = duplicate.selected[index]
			local match
			local matchCount = 0
			for _, candidate in ipairs(candidates) do
				if not claimedModels[candidate.model] then
					local candidateItem = Runtime.duplicateSelectionItem(candidate.model, candidate.base)
					if candidateItem
						and candidateItem.template == oldItem.template
						and candidateItem.sourceX == oldItem.sourceX
						and candidateItem.sourceZ == oldItem.sourceZ
						and candidateItem.sourceRotation == oldItem.sourceRotation
					then
						match = candidateItem
						matchCount += 1
					end
				end
			end
			if matchCount > 1 then
				return 0, string.format(
					"Selected source #%d %s disappeared and %d exact replacements exist at the same pose; nothing was guessed.",
					index,
					tostring(oldItem.name),
					matchCount
				)
			elseif matchCount == 1 then
				match.sourceReference = match.sourceReference or oldItem.sourceReference
				replacements[index] = match
				claimedModels[match.model] = true
				changed = true
			end
		end
	end

	local removed = {}
	for _, index in ipairs(stale) do
		if not replacements[index] then
			table.insert(removed, index)
		end
	end
	if not changed and #removed == 0 then
		return 0
	end


	-- Never discard Build/Resume bookkeeping after a server action committed.
	-- A stale source at that point must remain a visible blocker instead of
	-- silently creating a fresh preview that could resend completed work.
	local auditLockReason = Runtime.duplicateAuditLockReason()
	if auditLockReason then
		return 0, "A selected source changed, but " .. auditLockReason
	end

	for index, current in pairs(refreshed) do
		if current.model ~= duplicate.selected[index].model
			or current.base ~= duplicate.selected[index].base
		then
			changed = true
		end
		duplicate.selected[index] = current
		duplicate.byModel[current.model] = current
	end
	for index, replacement in pairs(replacements) do
		local oldItem = duplicate.selected[index]
		duplicate.byModel[oldItem.model] = nil
		Runtime.destroyDuplicateSelectionVisualsForModel(oldItem.model)
		duplicate.selected[index] = replacement
		duplicate.byModel[replacement.model] = replacement
		Runtime.attachDuplicateSelectionVisuals(replacement.model, replacement.base)
	end

	local anchorRemoved = removed[1] == 1
	for staleIndex = #removed, 1, -1 do
		local index = removed[staleIndex]
		local item = duplicate.selected[index]
		local model = item and item.model
		if model then
			duplicate.byModel[model] = nil
			Runtime.destroyDuplicateSelectionVisualsForModel(model)
		end
		table.remove(duplicate.selected, index)
	end
	duplicate.selectionVersion += 1
	Runtime.clearDuplicatePreview(true)
	local anchorReset = anchorRemoved or anchorPoseChanged
	if anchorReset then
		Runtime.refreshDuplicateAnchor(true)
	else
		Runtime.refreshDuplicateAnchor(false)
	end
	local recoveredCount = 0
	for _ in pairs(replacements) do
		recoveredCount += 1
	end
	local message = string.format(
		"Selection reconciled: recovered %d replacement(s), refreshed %d changed source(s), removed %d missing source(s)%s.",
		recoveredCount,
		refreshedChangedCount,
		#removed,
		anchorReset and "; the anchor changed, so pick the destination again" or ""
	)
	Runtime.updateDuplicateStatus(message)
	if not silent then
		notify("Duplicate selection repaired", message, 7)
	end
	return #removed, nil, anchorReset
end

function Runtime.refreshDuplicateAnchor(clearDestination)
	local duplicate = State.duplicate
	local anchor = duplicate.selected[1]
	duplicate.sourceAnchorX = anchor and anchor.sourceX or nil
	duplicate.sourceAnchorZ = anchor and anchor.sourceZ or nil
	if clearDestination then
		duplicate.destinationX = nil
		duplicate.destinationZ = nil
	end
end

function Runtime.addDuplicateSelection(model, base, bulk)
	local duplicate = State.duplicate
	local autoFitBusy = Runtime.autoFitBusyReason()
	if autoFitBusy then
		return false, autoFitBusy
	end
	-- Bulk marquee commits are just as selection-sensitive as single clicks. The
	-- marquee already batches preview invalidation and versioning, but it must
	-- never append objects while a yielded connection audit owns its snapshot.
	local auditLockReason = Runtime.duplicateAuditLockReason()
	if auditLockReason then
		return false, auditLockReason
	end
	if duplicate.byModel[model] then
		return false, model.Name .. " is already selected."
	elseif #duplicate.selected >= Config.MaxDuplicateSelection then
		return false, string.format("Duplicate selection is limited to %d objects.", Config.MaxDuplicateSelection)
	end
	local item, itemError = Runtime.duplicateSelectionItem(model, base)
	if not item then
		return false, itemError
	end
	table.insert(duplicate.selected, item)
	duplicate.byModel[model] = item
	if #duplicate.selected == 1 and not bulk then
		Runtime.refreshDuplicateAnchor(true)
	end
	Runtime.attachDuplicateSelectionVisuals(model, base)
	if not bulk then
		duplicate.selectionVersion += 1
		Runtime.clearDuplicatePreview(true)
		Runtime.updateDuplicateStatus("Selection updated; pick a destination.")
	end
	return true, item
end

function Runtime.removeDuplicateSelection(model)
	local duplicate = State.duplicate
	local autoFitBusy = Runtime.autoFitBusyReason()
	if autoFitBusy then
		return false, autoFitBusy
	end
	local auditLockReason = Runtime.duplicateAuditLockReason()
	if auditLockReason then
		return false, auditLockReason
	end
	local item = duplicate.byModel[model]
	if not item then
		return false, model.Name .. " is not selected."
	end
	local wasAnchor = duplicate.selected[1] == item
	for index, selected in ipairs(duplicate.selected) do
		if selected == item then
			table.remove(duplicate.selected, index)
			break
		end
	end
	duplicate.byModel[model] = nil
	Runtime.destroyDuplicateSelectionVisualsForModel(model)
	duplicate.selectionVersion += 1
	if wasAnchor then
		Runtime.refreshDuplicateAnchor(true)
	end
	Runtime.clearDuplicatePreview(true)
	Runtime.updateDuplicateStatus(wasAnchor and "Anchor changed; pick a new destination." or "Selection updated.")
	return true
end

function Runtime.replaceDuplicateSelection(model, base)
	local resetOK, resetError = Runtime.resetDuplicateSelection(true)
	if not resetOK then
		return false, resetError
	end
	return Runtime.addDuplicateSelection(model, base)
end

function Runtime.latticePhase(value)
	local rounded = math.round(value)
	return ((rounded % Config.OriginGrid) + Config.OriginGrid) % Config.OriginGrid
end

function Runtime.setDuplicateDestination(x, z, silent)
	local duplicate = State.duplicate
	if State.building then
		return false, "Destination is locked while a placement build is running."
	elseif State.autoFitInProgress then
		return false, Runtime.autoFitBusyReason()
	end
	local _, pruneError = Runtime.pruneStaleDuplicateSelection(true)
	if pruneError then
		return false, pruneError
	end
	local auditLockReason = Runtime.duplicateAuditLockReason()
	if auditLockReason then
		return false, auditLockReason
	end
	if #duplicate.selected == 0 or duplicate.sourceAnchorX == nil then
		local message = "Select at least one source object first."
		if not silent then
			notify("Destination not set", message, 6)
		end
		return false, message
	end
	local requestedX = tonumber(x)
	local requestedZ = tonumber(z)
	if not requestedX or not requestedZ then
		return false, "Destination X and Z must be numbers."
	end
	local phaseX = Runtime.latticePhase(duplicate.sourceAnchorX)
	local phaseZ = Runtime.latticePhase(duplicate.sourceAnchorZ)
	duplicate.destinationX = roundToLattice(requestedX, Config.OriginGrid, phaseX)
	duplicate.destinationZ = roundToLattice(requestedZ, Config.OriginGrid, phaseZ)
	Runtime.clearDuplicatePreview(true)
	Runtime.updateDuplicateStatus("Destination snapped to the source object's grid phase.")
	if not silent then
		notify(
			"Duplicate destination set",
			string.format("X %.0f, Z %.0f", duplicate.destinationX, duplicate.destinationZ),
			5
		)
	end
	return true, duplicate.destinationX, duplicate.destinationZ
end

function Runtime.setDuplicateRotation(value, silent)
	if State.building then
		return false, "Rotation is locked while a placement build is running."
	elseif State.autoFitInProgress then
		return false, Runtime.autoFitBusyReason()
	end
	local auditLockReason = Runtime.duplicateAuditLockReason()
	if auditLockReason then
		return false, auditLockReason
	end
	local rotation, adjusted = snapLayoutRotation(value)
	State.duplicate.rotation = rotation
	Runtime.clearDuplicatePreview(true)
	Runtime.updateDuplicateStatus(adjusted and "Rotation was snapped to a 90° turn." or "Rotation updated.")
	if not silent then
		notify("Duplicate rotation", tostring(rotation) .. "°", 4)
	end
	return true, rotation
end

function Runtime.duplicateTargetCFrame(item)
	local duplicate = State.duplicate
	if duplicate.destinationX == nil or duplicate.sourceAnchorX == nil then
		return nil, "Select a source and pick a destination first."
	end
	local offsetX = item.sourceX - duplicate.sourceAnchorX
	local offsetZ = item.sourceZ - duplicate.sourceAnchorZ
	local rotatedX, rotatedZ = rotateBlueprintOffset(offsetX, offsetZ, duplicate.rotation)
	return CFrame.new(
		duplicate.destinationX + rotatedX,
		Config.PlacementY,
		duplicate.destinationZ + rotatedZ
	) * CFrame.Angles(0, math.rad(item.sourceRotation + duplicate.rotation), 0)
end

function Runtime.characterPlacementRoot()
	local character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
	local root = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
	if not root then
		return nil, "Character has no HumanoidRootPart/PrimaryPart."
	end
	return root
end

function Runtime.autoFitRotationOrder(currentRotation)
	local current = select(1, snapLayoutRotation(currentRotation))
	if not State.smartTurnEnabled then
		return { current }
	end
	return {
		current,
		(current + 90) % 360,
		(current + 270) % 360,
		(current + 180) % 360,
	}
end

function Runtime.blueprintAutoFitDescriptors(rotation)
	local descriptors = {}
	local function append(entries, label)
		for index, entry in ipairs(entries) do
			local template, templateError = resolveTemplate(entry)
			if not template then
				return false, string.format("%s #%d: %s", label, index, templateError)
			end
			local transforms, transformError = Runtime.canonicalTemplateBaseTransforms(template)
			if not transforms then
				return false, string.format("%s #%d: %s", label, index, transformError)
			end
			local x = tonumber(entry.X)
			local z = tonumber(entry.Z)
			if not x or not z then
				return false, string.format("%s #%d has invalid X/Z coordinates.", label, index)
			end
			local rotatedX, rotatedZ = rotateBlueprintOffset(x, z, rotation)
			local target = CFrame.new(rotatedX, Config.PlacementY, rotatedZ)
				* CFrame.Angles(0, math.rad((tonumber(entry.Rotation) or 0) + rotation), 0)
			table.insert(descriptors, {
				name = tostring(entry.Name),
				relativeBaseCFrame = target * transforms.baseFromPivot,
				size = template.Base.Size,
			})
		end
		return true
	end
	local machinesOK, machineError = append(Blueprint, "Machine")
	if not machinesOK then
		return nil, machineError
	end
	local plumbingOK, plumbingError = append(State.sourceAuthoredPlumbing, "Plumbing")
	if not plumbingOK then
		return nil, plumbingError
	end
	if #descriptors == 0 then
		return nil, "The pasted blueprint has no placements to fit."
	end
	return descriptors
end

function Runtime.duplicateAutoFitDescriptors(rotation)
	local duplicate = State.duplicate
	if #duplicate.selected == 0 or duplicate.sourceAnchorX == nil then
		return nil, "Select at least one source object first."
	end
	local descriptors = {}
	for _, item in ipairs(duplicate.selected) do
		local transforms, transformError = Runtime.canonicalTemplateBaseTransforms(item.template)
		if not transforms then
			return nil, transformError
		end
		local offsetX = item.sourceX - duplicate.sourceAnchorX
		local offsetZ = item.sourceZ - duplicate.sourceAnchorZ
		local rotatedX, rotatedZ = rotateBlueprintOffset(offsetX, offsetZ, rotation)
		local target = CFrame.new(rotatedX, Config.PlacementY, rotatedZ)
			* CFrame.Angles(0, math.rad(item.sourceRotation + rotation), 0)
		table.insert(descriptors, {
			name = tostring(item.name),
			relativeBaseCFrame = target * transforms.baseFromPivot,
			size = item.template.Base.Size,
		})
	end
	return descriptors
end

function Runtime.autoFitInternalGeometryValid(descriptors, allowInheritedOverlap)
	if allowInheritedOverlap then
		return true
	end
	local spatial = Runtime.newTransientSpatialIndex()
	for index, descriptor in ipairs(descriptors) do
		local candidate = Runtime.footprintFromGeometry(descriptor.relativeBaseCFrame, descriptor.size)
		local overlapName
		Runtime.visitSpatialIndex(spatial, candidate, function(previous)
			if footprintsOverlap(previous.footprint, candidate) then
				overlapName = previous.name
				return false
			end
			return true
		end)
		if overlapName then
			return false, string.format(
				"%s overlaps %s inside the blueprint before it is moved.",
				descriptor.name,
				overlapName
			)
		end
		Runtime.addTransientSpatialEntry(spatial, {
			name = descriptor.name,
			footprint = candidate,
			index = index,
		}, candidate)
	end
	return true
end

function Runtime.autoFitLimitAdjustedAnchor(descriptors, requestedX, requestedZ, phaseX, phaseZ)
	local limits = workspace:FindFirstChild("Limits")
	if not limits or not limits:IsA("BasePart") then
		return nil, nil, "workspace.Limits is missing"
	end
	local clearance = tonumber(State.autoFitClearance) or 0
	local minimumX = math.huge
	local maximumX = -math.huge
	local minimumZ = math.huge
	local maximumZ = -math.huge
	for _, descriptor in ipairs(descriptors) do
		local cframe = CFrame.new(requestedX, 0, requestedZ) * descriptor.relativeBaseCFrame
		local xHalf = descriptor.size.X * 0.5 + clearance
		local zHalf = descriptor.size.Z * 0.5 + clearance
		for _, xSign in ipairs({ -1, 1 }) do
			for _, zSign in ipairs({ -1, 1 }) do
				local corner = cframe:PointToWorldSpace(Vector3.new(xSign * xHalf, 0, zSign * zHalf))
				local localCorner = limits.CFrame:PointToObjectSpace(corner)
				minimumX = math.min(minimumX, localCorner.X)
				maximumX = math.max(maximumX, localCorner.X)
				minimumZ = math.min(minimumZ, localCorner.Z)
				maximumZ = math.max(maximumZ, localCorner.Z)
			end
		end
	end
	local limitHalfX = limits.Size.X * 0.5
	local limitHalfZ = limits.Size.Z * 0.5
	if maximumX - minimumX > limits.Size.X + Config.EdgeEpsilon
		or maximumZ - minimumZ > limits.Size.Z + Config.EdgeEpsilon
	then
		return nil, nil, "This layout is larger than workspace.Limits at this rotation."
	end
	local localShiftX = 0
	local localShiftZ = 0
	if minimumX < -limitHalfX then
		localShiftX = -limitHalfX - minimumX
	elseif maximumX > limitHalfX then
		localShiftX = limitHalfX - maximumX
	end
	if minimumZ < -limitHalfZ then
		localShiftZ = -limitHalfZ - minimumZ
	elseif maximumZ > limitHalfZ then
		localShiftZ = limitHalfZ - maximumZ
	end
	local worldShift = limits.CFrame:VectorToWorldSpace(Vector3.new(localShiftX, 0, localShiftZ))
	return roundToLattice(requestedX + worldShift.X, Config.OriginGrid, phaseX),
		roundToLattice(requestedZ + worldShift.Z, Config.OriginGrid, phaseZ)
end

function Runtime.autoFitCandidateValid(descriptors, originX, originZ, placedCache)
	local clearance = tonumber(State.autoFitClearance) or 0
	for _, descriptor in ipairs(descriptors) do
		local cframe = CFrame.new(originX, 0, originZ) * descriptor.relativeBaseCFrame
		local paddedSize = Vector3.new(
			descriptor.size.X + clearance * 2,
			descriptor.size.Y,
			descriptor.size.Z + clearance * 2
		)
		local inside = Runtime.geometryInsideLimits(cframe, paddedSize)
		if not inside then
			return false, "outside the map"
		end
		local candidate = Runtime.footprintFromGeometry(cframe, paddedSize)
		for _, placed in ipairs(Runtime.placedCollisionCandidates(placedCache, candidate)) do
			local placedFootprint = Runtime.placedFootprint(placed)
			if placedFootprint and footprintsOverlap(candidate, placedFootprint) then
				return false, "touches " .. tostring(placed.name)
			end
		end
	end
	return true
end

function Runtime.autoFitOffsets()
	local offsets = { { x = 0, z = 0 } }
	local step = math.max(Config.OriginGrid, tonumber(Config.AutoFitSearchStep) or 4)
	step = math.ceil(step / Config.OriginGrid) * Config.OriginGrid
	local radius = math.max(0, tonumber(Config.AutoFitSearchRadius) or 48)
	for ring = step, radius, step do
		for x = -ring, ring, step do
			table.insert(offsets, { x = x, z = -ring })
			table.insert(offsets, { x = x, z = ring })
		end
		for z = -ring + step, ring - step, step do
			table.insert(offsets, { x = -ring, z = z })
			table.insert(offsets, { x = ring, z = z })
		end
	end
	return offsets
end

function Runtime.findSafeAutoFitWithCache(
	mode,
	requestedX,
	requestedZ,
	currentRotation,
	autoFitToken,
	placedCache
)
	if not Runtime.autoFitOwns(autoFitToken) then
		return nil, "Auto-fit was superseded before its search started."
	end
	local rotations = Runtime.autoFitRotationOrder(currentRotation)
	local offsets = Runtime.autoFitOffsets()
	local phaseX = Config.OriginGridPhase
	local phaseZ = Config.OriginGridPhase
	local descriptorBuilder = Runtime.blueprintAutoFitDescriptors
	local allowInheritedOverlap = false
	if mode == "Duplicate" then
		local duplicate = State.duplicate
		if #duplicate.selected == 0 or duplicate.sourceAnchorX == nil then
			return nil, "Select at least one source object first."
		end
		phaseX = Runtime.latticePhase(duplicate.sourceAnchorX)
		phaseZ = Runtime.latticePhase(duplicate.sourceAnchorZ)
		descriptorBuilder = Runtime.duplicateAutoFitDescriptors
		allowInheritedOverlap = true
	end
	local best
	local firstError
	local detailedCandidateChecks = 0
	local descriptorChecks = 0
	local searchBudgetReached = false
	local yieldEvery = math.max(1, math.floor(tonumber(Config.AutoFitYieldEvery) or 64))
	local descriptorChecksPerYield = math.max(
		1,
		math.floor(tonumber(Config.AutoFitDescriptorChecksPerYield) or 12000)
	)
	local maxDetailedCandidates = math.max(
		#rotations,
		math.floor(tonumber(Config.AutoFitMaxDetailedCandidates) or 2500)
	)
	local maxDescriptorChecks = math.max(
		1,
		math.floor(tonumber(Config.AutoFitMaxDescriptorChecks) or 1500000)
	)
	local minimumCandidatesPerRotation = math.max(
		1,
		math.floor(tonumber(Config.AutoFitMinimumCandidatesPerRotation) or 24)
	)
	local nearestRequestedX = roundToLattice(requestedX, Config.OriginGrid, phaseX)
	local nearestRequestedZ = roundToLattice(requestedZ, Config.OriginGrid, phaseZ)
	local theoreticalMinimumScore = (nearestRequestedX - requestedX) ^ 2
		+ (nearestRequestedZ - requestedZ) ^ 2
	for rotationIndex, rotation in ipairs(rotations) do
		if not Runtime.autoFitOwns(autoFitToken) then
			return nil, "Auto-fit was cancelled or superseded."
		end
		local descriptors, descriptorError = descriptorBuilder(rotation)
		if not descriptors then
			firstError = firstError or descriptorError
		else
			local internalOK, internalError = Runtime.autoFitInternalGeometryValid(
				descriptors,
				allowInheritedOverlap
			)
			if not internalOK then
				firstError = firstError or internalError
			else
				local centerX, centerZ, limitError = Runtime.autoFitLimitAdjustedAnchor(
					descriptors,
					requestedX,
					requestedZ,
					phaseX,
					phaseZ
				)
				if not centerX then
					firstError = firstError or limitError
				else
					local visited = {}
					local rotationDetailedChecks = 0
					local fairDetailedBudget = math.max(
						1,
						math.floor(maxDetailedCandidates / #rotations)
					)
					local descriptorBudget = math.floor(
						maxDescriptorChecks / math.max(1, #rotations * #descriptors)
					)
					local rotationBudget = math.min(
						#offsets,
						fairDetailedBudget,
						math.max(minimumCandidatesPerRotation, descriptorBudget)
					)
					local rotationYieldEvery = math.min(
						yieldEvery,
						math.max(1, math.floor(descriptorChecksPerYield / #descriptors))
					)
					for _, offset in ipairs(offsets) do
						local x = roundToLattice(centerX + offset.x, Config.OriginGrid, phaseX)
						local z = roundToLattice(centerZ + offset.z, Config.OriginGrid, phaseZ)
						local key = string.format("%.3f\31%.3f", x, z)
						if not visited[key] then
							visited[key] = true
							local score = (x - requestedX) ^ 2 + (z - requestedZ) ^ 2
							-- Once a nearer valid anchor exists, a farther anchor cannot
							-- win regardless of geometry, so avoid the expensive walk.
							if best and score > best.score + 0.0001 then
								continue
							end
							if rotationDetailedChecks >= rotationBudget then
								searchBudgetReached = true
								break
							end
							rotationDetailedChecks += 1
							detailedCandidateChecks += 1
							descriptorChecks += #descriptors
							if detailedCandidateChecks % rotationYieldEvery == 0 then
								RunService.Heartbeat:Wait()
								if not Runtime.autoFitOwns(autoFitToken) or State.building then
									return nil, State.destroyed
										and "The script was destroyed during auto-fit."
										or State.building
											and "A build started during auto-fit; try again after it finishes."
											or "Auto-fit was cancelled or superseded."
								end
							end
							local valid, candidateError = Runtime.autoFitCandidateValid(
								descriptors,
								x,
								z,
								placedCache
							)
							if valid then
								local candidate = {
									x = x,
									z = z,
									rotation = rotation,
									score = score,
									rotationRank = rotationIndex,
								}
								if not best
									or candidate.score < best.score - 0.0001
									or math.abs(candidate.score - best.score) <= 0.0001
										and candidate.rotationRank < best.rotationRank
									or math.abs(candidate.score - best.score) <= 0.0001
										and candidate.rotationRank == best.rotationRank
										and (candidate.x < best.x or candidate.x == best.x and candidate.z < best.z)
								then
									best = candidate
								end
								-- This is the closest possible anchor on the configured
								-- server lattice. Rotation order provides the stable tie-break,
								-- so no later candidate can improve the result.
								if score <= theoreticalMinimumScore + 0.0001 then
									candidate.candidateChecks = detailedCandidateChecks
									candidate.descriptorChecks = descriptorChecks
									return candidate
								end
							else
								firstError = firstError or candidateError
							end
						end
					end
				end
			end
		end
	end
	if not best then
		local budgetMessage = searchBudgetReached
			and " Auto-fit reached its safety budget; move closer to open space, lower clearance, or Preview from a manual base."
			or ""
		return nil, string.format(
			"No safe grid position was found within %d studs%s.%s",
			Config.AutoFitSearchRadius,
			firstError and (" First blocker: " .. firstError) or "",
			budgetMessage
		)
	end
	best.candidateChecks = detailedCandidateChecks
	best.descriptorChecks = descriptorChecks
	return best
end

function Runtime.findSafeAutoFit(mode, requestedX, requestedZ, currentRotation, autoFitToken)
	local callOK, best, detail = pcall(function()
		return Runtime.withPreparedPlacedCache(function(placedCache)
			return Runtime.findSafeAutoFitWithCache(
				mode,
				requestedX,
				requestedZ,
				currentRotation,
				autoFitToken,
				placedCache
			)
		end)
	end)
	if not callOK then
		return nil, "Auto-fit failed safely: " .. tostring(best)
	end
	return best, detail
end

function Runtime.autoFitBlueprintToCharacter(silent)
	if State.building then
		return false, "A blueprint build is currently running."
	elseif State.autoFitInProgress then
		return false, Runtime.autoFitBusyReason()
	end
	local root, rootError = Runtime.characterPlacementRoot()
	if not root then
		return false, rootError
	end
	local autoFitToken, beginError = Runtime.beginAutoFit("Blueprint")
	if not autoFitToken then
		return false, beginError
	end
	local blueprintRevision = State.blueprintRevision
	local smartTurnEnabled = State.smartTurnEnabled
	local clearance = State.autoFitClearance
	local best, fitError = Runtime.findSafeAutoFit(
		"Blueprint",
		root.Position.X,
		root.Position.Z,
		State.layoutRotation,
		autoFitToken
	)
	if not best then
		Runtime.finishAutoFit(autoFitToken)
		if not silent then
			notify("No safe build location", fitError, 9)
		end
		return false, fitError
	end
	if not Runtime.autoFitOwns(autoFitToken)
		or State.blueprintRevision ~= blueprintRevision
		or State.smartTurnEnabled ~= smartTurnEnabled
		or State.autoFitClearance ~= clearance
	then
		Runtime.finishAutoFit(autoFitToken)
		return false, "Blueprint or auto-fit settings changed during the search; no location was applied."
	end
	local applyCallOK, applied, applyError = pcall(
		applyLayoutSettings,
		best.x,
		best.z,
		best.rotation,
		true,
		autoFitToken
	)
	Runtime.finishAutoFit(autoFitToken)
	if not applyCallOK then
		return false, "Auto-fit could not apply its result: " .. tostring(applied)
	end
	if not applied then
		return false, applyError
	end
	local message = string.format(
		"Base X %.0f, Z %.0f • rotation %d° • %.1f stud clearance. Preview verifies generated plumbing and wiring.",
		best.x,
		best.z,
		best.rotation,
		clearance
	)
	if not silent then
		notify("Machine layout fitted", message, 8)
	end
	return true, message
end

function Runtime.autoFitDuplicateToCharacter(silent)
	local duplicate = State.duplicate
	if State.building then
		return false, "A placement build is currently running."
	elseif State.autoFitInProgress then
		return false, Runtime.autoFitBusyReason()
	end
	local _, pruneError = Runtime.pruneStaleDuplicateSelection(true)
	if pruneError then
		return false, pruneError
	end
	local auditLockReason = Runtime.duplicateAuditLockReason()
	if auditLockReason then
		return false, auditLockReason
	end
	local root, rootError = Runtime.characterPlacementRoot()
	if not root then
		return false, rootError
	end
	local autoFitToken, beginError = Runtime.beginAutoFit("Duplicate")
	if not autoFitToken then
		return false, beginError
	end
	local selectionVersion = duplicate.selectionVersion
	local selectionCount = #duplicate.selected
	local sourceAnchorX = duplicate.sourceAnchorX
	local sourceAnchorZ = duplicate.sourceAnchorZ
	local smartTurnEnabled = State.smartTurnEnabled
	local clearance = State.autoFitClearance
	local best, fitError = Runtime.findSafeAutoFit(
		"Duplicate",
		root.Position.X,
		root.Position.Z,
		duplicate.rotation,
		autoFitToken
	)
	if not best then
		Runtime.finishAutoFit(autoFitToken)
		if not silent then
			notify("No safe duplicate location", fitError, 9)
		end
		return false, fitError
	end
	if not Runtime.autoFitOwns(autoFitToken)
		or duplicate.selectionVersion ~= selectionVersion
		or #duplicate.selected ~= selectionCount
		or duplicate.sourceAnchorX ~= sourceAnchorX
		or duplicate.sourceAnchorZ ~= sourceAnchorZ
		or State.smartTurnEnabled ~= smartTurnEnabled
		or State.autoFitClearance ~= clearance
	then
		Runtime.finishAutoFit(autoFitToken)
		return false, "Duplicate selection or auto-fit settings changed during the search; no location was applied."
	end
	local commitOK, commitError = pcall(function()
		duplicate.destinationX = best.x
		duplicate.destinationZ = best.z
		duplicate.rotation = best.rotation
		Runtime.clearDuplicatePreview(true)
	end)
	Runtime.finishAutoFit(autoFitToken)
	if not commitOK then
		return false, "Auto-fit could not apply its duplicate result: " .. tostring(commitError)
	end
	local message = string.format(
		"Base X %.0f, Z %.0f • rotation %d° • %.1f stud clearance. Preview verifies copied connections.",
		best.x,
		best.z,
		best.rotation,
		clearance
	)
	Runtime.updateDuplicateStatus(message)
	if not silent then
		notify("Duplicate layout fitted", message, 8)
	end
	return true, message
end

function Runtime.createDuplicatePreview(index, item, folder)
	local target, targetError = Runtime.duplicateTargetCFrame(item)
	local preview = {
		index = index,
		entry = {
			Category = item.category,
			Name = item.name,
			X = target and target.Position.X or 0,
			Z = target and target.Position.Z or 0,
			Rotation = item.sourceRotation + State.duplicate.rotation,
		},
		template = item.template,
		sourceItem = item,
		selectionVersion = State.duplicate.selectionVersion,
		destinationX = State.duplicate.destinationX,
		destinationZ = State.duplicate.destinationZ,
		duplicateRotation = State.duplicate.rotation,
		reasons = {},
		valid = false,
		built = false,
		targetCFrame = target,
	}
	if not target then
		preview.setupError = targetError
		return preview
	end
	if not item.model or not item.model.Parent then
		preview.setupError = "selected source object disappeared"
		return preview
	end
	local ghost = Runtime.cloneStyledGhost(item.template)
	ghost.Name = string.format("Duplicate_%03d_%s", index, item.name)
	local pivotOK, pivotError = pcall(function()
		ghost:PivotTo(target)
	end)
	if not pivotOK then
		ghost:Destroy()
		preview.setupError = "PivotTo failed: " .. tostring(pivotError)
		return preview
	end
	local base = ghost:FindFirstChild("Base")
	if not base or not base:IsA("BasePart") then
		ghost:Destroy()
		preview.setupError = "cloned model lost its direct Base"
		return preview
	end
	local highlight = Instance.new("Highlight")
	highlight.Name = "DuplicateValidity"
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.FillTransparency = 0.72
	highlight.OutlineTransparency = 0.05
	highlight.Adornee = base
	highlight.Parent = ghost
	ghost.Parent = folder
	preview.model = ghost
	preview.base = base
	preview.expectedBase = {
		Position = base.Position,
		CFrame = base.CFrame,
		Size = base.Size,
	}
	preview.highlight = highlight
	return preview
end

function Runtime.duplicateReferenceKey(reference)
	if type(reference) ~= "table" then
		return nil
	elseif reference.Machine then
		return "M:" .. tostring(reference.Machine)
	elseif reference.Piece then
		return "P:" .. tostring(reference.Piece)
	end
	return nil
end

function Runtime.duplicateGraphPoseKey(category, name, x, z, rotation)
	local normalizedX = math.round((tonumber(x) or 0) * 1000) / 1000
	local normalizedZ = math.round((tonumber(z) or 0) * 1000) / 1000
	-- Quarter-turn matrix math can produce IEEE -0. string.format preserves
	-- its sign, so an exact 90-degree copy at -0.000 otherwise fails to match
	-- the loaded graph's 0.000 key.
	if math.abs(normalizedX) < 0.0005 then
		normalizedX = 0
	end
	if math.abs(normalizedZ) < 0.0005 then
		normalizedZ = 0
	end
	return string.format(
		"%s\31%s\31%.3f\31%.3f\31%d",
		tostring(category),
		tostring(name),
		normalizedX,
		normalizedZ,
		((math.round(tonumber(rotation) or 0) % 360) + 360) % 360
	)
end

function Runtime.duplicateGraphNodes()
	local nodes = {}
	for index, entry in ipairs(Blueprint) do
		if type(entry) == "table" and type(entry.Category) == "string" and type(entry.Name) == "string" then
			table.insert(nodes, {
				category = entry.Category,
				name = entry.Name,
				x = tonumber(entry.X) or 0,
				z = tonumber(entry.Z) or 0,
				rotation = ((math.round(tonumber(entry.Rotation) or 0) % 360) + 360) % 360,
				reference = { Machine = index },
			})
		end
	end
	for index, entry in ipairs(AuthoredPlumbing) do
		if type(entry) == "table" and type(entry.Category) == "string" and type(entry.Name) == "string" then
			table.insert(nodes, {
				category = entry.Category,
				name = entry.Name,
				x = tonumber(entry.X) or 0,
				z = tonumber(entry.Z) or 0,
				rotation = ((math.round(tonumber(entry.Rotation) or 0) % 360) + 360) % 360,
				reference = { Piece = index },
			})
		end
	end
	return nodes
end

function Runtime.mapDuplicateSelectionToGraph()
	local duplicate = State.duplicate
	local nodes = Runtime.duplicateGraphNodes()
	if #duplicate.selected == 0 or #nodes == 0 then
		return nil, "the loaded blueprint graph is empty"
	end

	local poseLookup = {}
	local candidatesByIdentity = {}
	for _, node in ipairs(nodes) do
		local poseKey = Runtime.duplicateGraphPoseKey(
			node.category,
			node.name,
			node.x,
			node.z,
			node.rotation
		)
		local poseMatches = poseLookup[poseKey] or {}
		poseLookup[poseKey] = poseMatches
		table.insert(poseMatches, node)
		local identityKey = node.category .. "\31" .. node.name
		local identityMatches = candidatesByIdentity[identityKey] or {}
		candidatesByIdentity[identityKey] = identityMatches
		table.insert(identityMatches, node)
	end

	local anchorIndex
	local anchorCandidates
	for selectionIndex, item in ipairs(duplicate.selected) do
		local matches = candidatesByIdentity[item.category .. "\31" .. item.name]
		if matches and (not anchorCandidates or #matches < #anchorCandidates) then
			anchorIndex = selectionIndex
			anchorCandidates = matches
		end
	end
	if not anchorIndex or not anchorCandidates then
		return nil, "selected objects do not match the loaded blueprint graph"
	end

	local anchor = duplicate.selected[anchorIndex]
	local directKeys = {}
	for selectionIndex, item in ipairs(duplicate.selected) do
		directKeys[selectionIndex] = Runtime.duplicateReferenceKey(Runtime.duplicateSourceReference(item.model))
	end
	local bestMapping
	local bestSignature
	local ambiguous = false
	for _, anchorNode in ipairs(anchorCandidates) do
		if directKeys[anchorIndex]
			and Runtime.duplicateReferenceKey(anchorNode.reference) ~= directKeys[anchorIndex]
		then
			continue
		end
		local rotationDelta = ((anchor.sourceRotation - anchorNode.rotation) % 360 + 360) % 360
		if rotationDelta % 90 ~= 0 then
			continue
		end
		local rotatedAnchorX, rotatedAnchorZ = rotateBlueprintOffset(
			anchorNode.x,
			anchorNode.z,
			rotationDelta
		)
		local translationX = anchor.sourceX - rotatedAnchorX
		local translationZ = anchor.sourceZ - rotatedAnchorZ
		local mapping = {}
		local signatureParts = {}
		local usedReferences = {}
		local valid = true
		for selectionIndex, item in ipairs(duplicate.selected) do
			local localX, localZ = rotateBlueprintOffset(
				item.sourceX - translationX,
				item.sourceZ - translationZ,
				-rotationDelta
			)
			local localRotation = ((item.sourceRotation - rotationDelta) % 360 + 360) % 360
			local poseKey = Runtime.duplicateGraphPoseKey(
				item.category,
				item.name,
				localX,
				localZ,
				localRotation
			)
			local matches = poseLookup[poseKey]
			local directKey = directKeys[selectionIndex]
			local matchedNode
			if matches then
				for _, node in ipairs(matches) do
					local referenceKey = Runtime.duplicateReferenceKey(node.reference)
					if (not directKey or referenceKey == directKey) and not usedReferences[referenceKey] then
						if matchedNode then
							matchedNode = nil
							break
						end
						matchedNode = node
					end
				end
			end
			if not matchedNode then
				valid = false
				break
			end
			local referenceKey = Runtime.duplicateReferenceKey(matchedNode.reference)
			usedReferences[referenceKey] = true
			mapping[referenceKey] = selectionIndex
			table.insert(signatureParts, referenceKey)
		end
		if valid and #signatureParts == #duplicate.selected then
			local signature = table.concat(signatureParts, "|")
			if not bestMapping then
				bestMapping = mapping
				bestSignature = signature
			elseif signature ~= bestSignature then
				ambiguous = true
			end
		end
	end
	if ambiguous then
		return nil, "selected group matches the loaded blueprint in more than one way"
	elseif not bestMapping then
		return nil, "selected group is not one rigid translated/rotated copy of the loaded blueprint"
	end
	return bestMapping, "rigid graph match"
end

function Runtime.templatePowerConnectorCount(template)
	if not template then
		return 0
	end
	local cached = State.powerConnectorCountCache[template]
	if cached ~= nil then
		return cached
	end
	local count = 0
	for _, descendant in ipairs(template:GetDescendants()) do
		if descendant:IsA("BasePart") then
			local metadata = descendant:FindFirstChild("Power")
			if metadata and metadata:IsA("Folder") then
				count += 1
			end
		end
	end
	State.powerConnectorCountCache[template] = count
	return count
end

function Runtime.duplicatePlumbingRequiredDegree(item, forcePhysical)
	if type(item) ~= "table" or not item.template then
		return nil
	end
	-- Pipes/* also contains conveyors and other non-plumbing models, while the
	-- legacy HandPump lives under Extractors. Use real connector metadata to
	-- avoid both the old substring false positive and the pump false negative.
	local name = tostring(item.name)
	local nameSuggestsInlinePlumbing = string.find(string.lower(name), "pipe", 1, true) ~= nil
	if not forcePhysical
		and State.physicalPlumbingModels[item.model] ~= true
		and tostring(item.category) ~= "Pipes"
		and name ~= "HandPump"
		and not nameSuggestsInlinePlumbing
	then
		return nil
	end
	local connectorCount = State.pipeConnectorCountCache[item.template]
	if connectorCount == nil then
		connectorCount = 0
		for _, descendant in ipairs(item.template:GetDescendants()) do
			if descendant:IsA("BasePart") then
				local metadata = descendant:FindFirstChild("Pipe")
				if metadata and metadata:IsA("Folder") then
					connectorCount += 1
				end
			end
		end
		State.pipeConnectorCountCache[item.template] = connectorCount
	end
	if connectorCount == 0 then
		return nil
	end
	-- Degree cannot be derived from connector-object count: Industrialist's
	-- straight and turn pieces intentionally bind the same PipeA node to both
	-- neighbors. Completeness therefore comes from an authoritative source
	-- graph below; this value is only the orphan-node minimum.
	return 1
end

function Runtime.isDuplicatePhysicalPlumbing(item)
	if type(item) ~= "table" or not item.model or not item.template then
		return false
	elseif Runtime.templatePowerConnectorCount(item.template) > 0 then
		-- The portable wire schema intentionally targets Machines only. Powered
		-- pipe valves/converters must remain Machines so their wiring survives.
		return false
	end
	local reference = Runtime.duplicateSourceReference(item.model) or item.sourceReference
	local referenceKey = Runtime.duplicateReferenceKey(reference)
	if referenceKey then
		return string.sub(referenceKey, 1, 2) == "P:"
	end
	local sourceX = math.round(tonumber(item.sourceX) or 0)
	local sourceZ = math.round(tonumber(item.sourceZ) or 0)
	local onPhysicalPipeGrid = ((sourceX % Config.PipeGrid) + Config.PipeGrid) % Config.PipeGrid
		== Config.PipeGridPhase
		and ((sourceZ % Config.PipeGrid) + Config.PipeGrid) % Config.PipeGrid
			== Config.PipeGridPhase
	return (State.physicalPlumbingModels[item.model] == true
		or (tostring(item.category) == "Pipes" and onPhysicalPipeGrid)
		or tostring(item.name) == "HandPump")
		and Runtime.duplicatePlumbingRequiredDegree(item, false) ~= nil
end

-- Reconstruct saved PipeBind topology from the server-created visual evidence.
-- Proximity only narrows candidates: an edge is accepted solely when the same
-- Part/UnionOperation geometry verifier used after a fresh bind proves one
-- globally unique pair of exact live connector Instances.
function Runtime.recoverLivePipeConnections(selectedByModel)
	local recovery = {
		Edges = {},
		SelectedConnectorCount = 0,
		SelectedEdgeCount = 0,
		SegmentCount = 0,
		CapCount = 0,
		MatchedSegmentCount = 0,
		UnresolvedSelectedDecorations = 0,
		AmbiguousSelectedDecorations = 0,
		UnmatchedSegments = 0,
		UnclaimedCaps = 0,
		CapAssignmentFailures = 0,
		UnmappedSelectedConnectors = 0,
		UnexpectedDecorationClasses = 0,
		Stable = true,
		Authoritative = false,
		Detail = "live pipe-decoration scan did not run",
	}
	if not ConnectionDecorations
		or not ConnectionDecorations.Parent
		or not ConnectionDecorations:IsDescendantOf(Plots)
	then
		recovery.Stable = false
		recovery.Detail = "the server pipe-decoration folder is unavailable"
		return recovery
	end

	local cellSize = 2
	local function bucketKey(x, y, z)
		return string.format(
			"%d:%d:%d",
			math.floor(x / cellSize),
			math.floor(y / cellSize),
			math.floor(z / cellSize)
		)
	end
	local function addToBucket(buckets, value)
		local position = value.position
		local key = bucketKey(position.X, position.Y, position.Z)
		local bucket = buckets[key]
		if not bucket then
			bucket = {}
			buckets[key] = bucket
		end
		table.insert(bucket, value)
	end
	local function nearby(buckets, position, radius)
		local found = {}
		local seen = {}
		local extent = math.ceil(radius / cellSize)
		local centerX = math.floor(position.X / cellSize)
		local centerY = math.floor(position.Y / cellSize)
		local centerZ = math.floor(position.Z / cellSize)
		for x = centerX - extent, centerX + extent do
			for y = centerY - extent, centerY + extent do
				for z = centerZ - extent, centerZ + extent do
					for _, value in ipairs(buckets[string.format("%d:%d:%d", x, y, z)] or {}) do
						if not seen[value]
							and (value.position - position).Magnitude <= radius + Config.EdgeEpsilon
						then
							seen[value] = true
							table.insert(found, value)
						end
					end
				end
			end
		end
		return found
	end
	local function copiedPathKey(path)
		local parts = {}
		for _, segment in ipairs(type(path) == "table" and path or {}) do
			table.insert(parts, string.format(
				"%s/%s/%d",
				tostring(segment.Name),
				tostring(segment.ClassName),
				math.max(1, math.floor(tonumber(segment.Ordinal) or 1))
			))
		end
		return table.concat(parts, "|")
	end

	local models = {}
	local modelSeen = {}
	local function includeModel(model)
		if model
			and model:IsA("Model")
			and model.Parent
			and model:IsDescendantOf(Plots)
			and not modelSeen[model]
		then
			modelSeen[model] = true
			table.insert(models, model)
		end
	end
	for _, item in ipairs(State.duplicate.selected) do
		includeModel(item.model)
	end
	for _, placed in ipairs(collectPlacedMachines()) do
		includeModel(placed.model)
	end
	table.sort(models, function(first, second)
		local firstBase = first:FindFirstChild("Base")
		local secondBase = second:FindFirstChild("Base")
		local firstPosition = firstBase and firstBase:IsA("BasePart") and firstBase.Position or Vector3.zero
		local secondPosition = secondBase and secondBase:IsA("BasePart") and secondBase.Position or Vector3.zero
		local firstKey = string.format(
			"%+.4f/%+.4f/%+.4f/%s",
			firstPosition.X,
			firstPosition.Y,
			firstPosition.Z,
			first:GetFullName()
		)
		local secondKey = string.format(
			"%+.4f/%+.4f/%+.4f/%s",
			secondPosition.X,
			secondPosition.Y,
			secondPosition.Z,
			second:GetFullName()
		)
		return firstKey < secondKey
	end)

	local connectorBuckets = {}
	local connectorRecords = {}
	local uncachedModels = 0
	for _, model in ipairs(models) do
		local inventory, wasCached = Runtime.connectionConnectorRecords(model, "Pipe")
		if not wasCached then
			uncachedModels += 1
			if uncachedModels % Config.ConnectionRecoveryModelYieldEvery == 0 then
				RunService.Heartbeat:Wait()
			end
		end
		for _, cachedConnector in ipairs(inventory) do
			local descendant = cachedConnector.connector
			local metadata = cachedConnector.metadata
			if descendant.Parent and metadata and metadata.Parent == descendant then
					local path = cachedConnector.path
					local selectedIndex = selectedByModel[model]
					local pathValid = path ~= nil
					if selectedIndex and pathValid then
						local item = State.duplicate.selected[selectedIndex]
						local canonical = item and Runtime.resolveStoredConnectorPath(item.template, path)
						pathValid = canonical ~= nil and canonical.Name == descendant.Name
					end
					local base = model:FindFirstChild("Base")
					local basePosition = base and base:IsA("BasePart") and base.Position or Vector3.zero
					local record = {
						id = #connectorRecords + 1,
						connector = descendant,
						metadata = metadata,
						model = model,
						path = path,
						pathValid = pathValid,
						selectedIndex = selectedIndex,
						position = descendant.Position,
						orderKey = string.format(
							"%+.4f/%+.4f/%+.4f/%s/%s",
							basePosition.X,
							basePosition.Y,
							basePosition.Z,
							model:GetFullName(),
							copiedPathKey(path)
						),
					}
					table.insert(connectorRecords, record)
					addToBucket(connectorBuckets, record)
					if selectedIndex then
						recovery.SelectedConnectorCount += 1
					end
			end
		end
	end

	local segmentRecords = {}
	local capRecords = {}
	local otherRecords = {}
	local capBuckets = {}
	local decorationSnapshots = {}
	for _, decoration in ipairs(Runtime.connectionDecorationChildren("Pipe")) do
		if decoration:IsA("BasePart") and decoration.Name == "Pipe" then
			local record = {
				decoration = decoration,
				position = decoration.Position,
				cframe = decoration.CFrame,
				size = decoration.Size,
				className = decoration.ClassName,
			}
			decorationSnapshots[decoration] = record
			if decoration:IsA("UnionOperation") then
				table.insert(capRecords, record)
				addToBucket(capBuckets, record)
			elseif decoration:IsA("Part") then
				table.insert(segmentRecords, record)
			else
				table.insert(otherRecords, record)
			end
		end
	end
	recovery.SegmentCount = #segmentRecords
	recovery.CapCount = #capRecords

	local function touchesSelected(records)
		for _, record in ipairs(records) do
			if record.selectedIndex then
				return true
			end
		end
		return false
	end
	local function orientedPair(first, second, liveDecorationProven)
		local forward = Runtime.validateDuplicateExportConnection(
			"Pipe",
			first.connector,
			second.connector,
			liveDecorationProven
		)
		local reverse = Runtime.validateDuplicateExportConnection(
			"Pipe",
			second.connector,
			first.connector,
			liveDecorationProven
		)
		if forward and not reverse then
			return first, second
		elseif reverse and not forward then
			return second, first
		elseif forward and reverse then
			if first.orderKey <= second.orderKey then
				return first, second
			end
			return second, first
		end
		return nil
	end

	-- Industrialist stores authoritative saved-pipe ownership directly under
	-- each live connector's Pipe/PipeDecorations folder. Each ObjectValue is one
	-- edge: its name is the opposite connector's exact position, Value is one
	-- server decoration, and its child Pipe2 points at the other decoration.
	-- Prefer this graph over global pose inference; crowded factories can have
	-- several geometrically plausible holes even though the owner record is exact.
	local function recoverFromConnectorMetadata()
		if #connectorRecords == 0 then
			return nil
		end
		local metadataFolders = {}
		for _, connectorRecord in ipairs(connectorRecords) do
			local folder = connectorRecord.metadata:FindFirstChild("PipeDecorations")
			if not folder or not folder:IsA("Folder") then
				return nil
			end
			metadataFolders[connectorRecord] = folder
		end

		local function parseTargetPosition(name)
			local components = {}
			for component in string.gmatch(tostring(name), "[^,]+") do
				local value = tonumber(component)
				if not value or value ~= value or value == math.huge or value == -math.huge then
					return nil
				end
				table.insert(components, value)
			end
			if #components ~= 3 then
				return nil
			end
			return Vector3.new(components[1], components[2], components[3])
		end

		local metadataSnapshots = {}
		local metadataRecordCount = 0
		local referencedSegments = {}
		local segmentReferenceCounts = {}
		local edgeSeen = {}
		for _, ownerRecord in ipairs(connectorRecords) do
			local folder = metadataFolders[ownerRecord]
			for _, edgeRecord in ipairs(folder:GetChildren()) do
				if edgeRecord:IsA("ObjectValue") and edgeRecord.Name ~= "Pipe2" then
					metadataRecordCount += 1
					local pipe2 = edgeRecord:FindFirstChild("Pipe2")
					local firstDecoration = edgeRecord.Value
					local secondDecoration = pipe2 and pipe2:IsA("ObjectValue") and pipe2.Value or nil
					if firstDecoration and firstDecoration:IsA("Part")
						and not firstDecoration:IsA("UnionOperation")
					then
						referencedSegments[firstDecoration] = true
						segmentReferenceCounts[firstDecoration] =
							(segmentReferenceCounts[firstDecoration] or 0) + 1
					end
					if secondDecoration and secondDecoration:IsA("Part")
						and not secondDecoration:IsA("UnionOperation")
					then
						referencedSegments[secondDecoration] = true
						segmentReferenceCounts[secondDecoration] =
							(segmentReferenceCounts[secondDecoration] or 0) + 1
					end
					local targetPosition = parseTargetPosition(edgeRecord.Name)
					metadataSnapshots[edgeRecord] = {
						folder = folder,
						name = edgeRecord.Name,
						first = firstDecoration,
						pipe2 = pipe2,
						second = secondDecoration,
					}

					local targetCandidates = targetPosition and nearby(
						connectorBuckets,
						targetPosition,
						Config.EdgeEpsilon
					) or {}
					local touchesSelection = ownerRecord.selectedIndex ~= nil
					local matches = {}
					for _, candidateRecord in ipairs(targetCandidates) do
						if candidateRecord.selectedIndex then
							touchesSelection = true
						end
						if candidateRecord.connector ~= ownerRecord.connector
							and (candidateRecord.position - targetPosition).Magnitude
								<= Config.EdgeEpsilon
							and firstDecoration
							and secondDecoration
						then
							local pairMatches = Runtime.connectionDecorationPairMatches(
								"Pipe",
								firstDecoration,
								secondDecoration,
								ownerRecord.connector,
								candidateRecord.connector
							)
							local fromRecord, toRecord
							if pairMatches then
								fromRecord, toRecord = orientedPair(ownerRecord, candidateRecord, true)
							end
							if pairMatches and fromRecord then
								table.insert(matches, {
									fromRecord = fromRecord,
									toRecord = toRecord,
								})
							end
						end
					end

					if #matches == 1 then
						local match = matches[1]
						local fromRecord = match.fromRecord
						local toRecord = match.toRecord
						local low = math.min(fromRecord.id, toRecord.id)
						local high = math.max(fromRecord.id, toRecord.id)
						local edgeKey = tostring(low) .. ":" .. tostring(high)
						local prior = edgeSeen[edgeKey]
						if prior then
							local sameDecorations = (prior.first == firstDecoration
								and prior.second == secondDecoration)
								or (prior.first == secondDecoration and prior.second == firstDecoration)
							if touchesSelection and not sameDecorations then
								recovery.AmbiguousSelectedDecorations += 1
							end
						else
							edgeSeen[edgeKey] = {
								first = firstDecoration,
								second = secondDecoration,
							}
							local edgeTouchesSelection = fromRecord.selectedIndex ~= nil
								or toRecord.selectedIndex ~= nil
							local internalSelectedEdge = fromRecord.selectedIndex ~= nil
								and toRecord.selectedIndex ~= nil
							local exportable = true
							if internalSelectedEdge then
								for _, endpoint in ipairs({ fromRecord, toRecord }) do
									if not endpoint.pathValid then
										exportable = false
										recovery.UnmappedSelectedConnectors += 1
										recovery.UnresolvedSelectedDecorations += 1
									end
								end
							end
							table.insert(recovery.Edges, {
								fromModel = fromRecord.model,
								toModel = toRecord.model,
								fromConnector = fromRecord.connector,
								toConnector = toRecord.connector,
								fromConnectorName = fromRecord.connector.Name,
								toConnectorName = toRecord.connector.Name,
								fromConnectorPath = fromRecord.path,
								toConnectorPath = toRecord.path,
								fromSelection = fromRecord.selectedIndex,
								toSelection = toRecord.selectedIndex,
								usable = exportable,
								decorations = { firstDecoration, secondDecoration },
								liveDecorationProven = true,
							})
							recovery.MatchedSegmentCount += 1
							if edgeTouchesSelection then
								recovery.SelectedEdgeCount += 1
							end
						end
					elseif touchesSelection then
						if #matches > 1 then
							recovery.AmbiguousSelectedDecorations += 1
						else
							recovery.UnmatchedSegments += 1
							recovery.UnresolvedSelectedDecorations += 1
						end
					end
				end
			end
		end
		local referencedSegmentCount = 0
		local everySegmentHasOneOwner = true
		for _ in pairs(referencedSegments) do
			referencedSegmentCount += 1
		end
		for _, segmentRecord in ipairs(segmentRecords) do
			if segmentReferenceCounts[segmentRecord.decoration] ~= 1 then
				everySegmentHasOneOwner = false
				break
			end
		end
		if metadataRecordCount ~= #segmentRecords
			or referencedSegmentCount ~= #segmentRecords
			or not everySegmentHasOneOwner
		then
			-- The connector graph is incomplete for this replication. Discard its
			-- partial result and let the stricter global segment/cap fallback prove
			-- the network rather than silently omitting an unowned segment.
			recovery.Edges = {}
			recovery.SelectedEdgeCount = 0
			recovery.MatchedSegmentCount = 0
			recovery.UnresolvedSelectedDecorations = 0
			recovery.AmbiguousSelectedDecorations = 0
			recovery.UnmatchedSegments = 0
			recovery.UnclaimedCaps = 0
			recovery.CapAssignmentFailures = 0
			recovery.UnmappedSelectedConnectors = 0
			return nil
		end

		-- Confirm that neither the connector-owned graph nor its visual evidence
		-- changed while it was being copied.
		local currentMetadataRecordCount = 0
		for connectorRecord, folder in pairs(metadataFolders) do
			if folder.Parent ~= connectorRecord.metadata then
				recovery.Stable = false
			end
			for _, child in ipairs(folder:GetChildren()) do
				if child:IsA("ObjectValue") and child.Name ~= "Pipe2" then
					currentMetadataRecordCount += 1
				end
			end
		end
		if currentMetadataRecordCount ~= metadataRecordCount then
			recovery.Stable = false
		end
		for edgeRecord, snapshot in pairs(metadataSnapshots) do
			local pipe2 = edgeRecord.Parent and edgeRecord:FindFirstChild("Pipe2")
			if edgeRecord.Parent ~= snapshot.folder
				or edgeRecord.Name ~= snapshot.name
				or edgeRecord.Value ~= snapshot.first
				or pipe2 ~= snapshot.pipe2
				or not pipe2
				or not pipe2:IsA("ObjectValue")
				or pipe2.Value ~= snapshot.second
			then
				recovery.Stable = false
			end
		end
		local currentDecorationCount = 0
		for _, decoration in ipairs(Runtime.connectionDecorationChildren("Pipe")) do
			if decoration:IsA("BasePart") and decoration.Name == "Pipe" then
				currentDecorationCount += 1
				local snapshot = decorationSnapshots[decoration]
				if not snapshot
					or snapshot.className ~= decoration.ClassName
					or snapshot.cframe ~= decoration.CFrame
					or snapshot.size ~= decoration.Size
				then
					recovery.Stable = false
				end
			end
		end
		if currentDecorationCount ~= #segmentRecords + #capRecords + #otherRecords then
			recovery.Stable = false
		end
		for decoration in pairs(decorationSnapshots) do
			if not decoration.Parent or not decoration:IsDescendantOf(ConnectionDecorations) then
				recovery.Stable = false
			end
		end
		for _, connectorRecord in ipairs(connectorRecords) do
			if not connectorRecord.connector.Parent
				or connectorRecord.connector.Position ~= connectorRecord.position
			then
				recovery.Stable = false
			end
		end

		recovery.Authoritative = recovery.Stable
			and recovery.UnresolvedSelectedDecorations == 0
			and recovery.AmbiguousSelectedDecorations == 0
		if not recovery.Stable then
			recovery.Detail = "connector-owned pipe records changed during inspection"
		elseif recovery.AmbiguousSelectedDecorations > 0 then
			recovery.Detail = string.format(
				"%d connector-owned pipe record(s) resolved to multiple exact endpoints",
				recovery.AmbiguousSelectedDecorations
			)
		elseif recovery.UnresolvedSelectedDecorations > 0 then
			recovery.Detail = string.format(
				"%d connector-owned pipe record(s) could not be verified exactly",
				recovery.UnresolvedSelectedDecorations
			)
		else
			recovery.Detail = string.format(
				"connector metadata proved %d selected pipe link(s)",
				recovery.SelectedEdgeCount
			)
		end
		return recovery
	end

	local metadataRecovery = recoverFromConnectorMetadata()
	if metadataRecovery then
		return metadataRecovery
	end

	local resolvedCandidates = {}
	local ambiguousEvidence = {}
	local unresolvedEvidence = {}
	local function capSetArray(capSet)
		local caps = {}
		for capRecord in pairs(capSet) do
			table.insert(caps, capRecord)
		end
		table.sort(caps, function(first, second)
			return first.decoration:GetFullName() < second.decoration:GetFullName()
		end)
		return caps
	end
	local function segmentHasSelectedEndpointEvidence(segment, firstEnd, secondEnd)
		local nearRadius = Config.PipeDecorationLengthBiasMax
			+ Config.PipeDecorationSegmentTolerance
		for _, ends in ipairs({
			{ far = firstEnd, near = secondEnd },
			{ far = secondEnd, near = firstEnd },
		}) do
			local farConnectors = nearby(
				connectorBuckets,
				ends.far,
				Config.PipeDecorationSegmentTolerance
			)
			local nearConnectors = nearby(connectorBuckets, ends.near, nearRadius)
			for _, farRecord in ipairs(farConnectors) do
				for _, nearRecord in ipairs(nearConnectors) do
					if farRecord.connector ~= nearRecord.connector
						and (farRecord.selectedIndex ~= nil or nearRecord.selectedIndex ~= nil)
						-- This is relevance only: an incomplete exact segment must block even
						-- for catalog ports outside the authored-name heuristic. No edge is
						-- accepted until the full segment/cap matcher succeeds below.
						and orientedPair(farRecord, nearRecord, true) ~= nil
						and Runtime.connectionDecorationCouldBelongToEdge(
							"Pipe",
							segment,
							farRecord.connector,
							nearRecord.connector
						)
					then
						return true
					end
				end
			end
		end
		return false
	end
	for _, segmentRecord in ipairs(segmentRecords) do
		local segment = segmentRecord.decoration
		local halfLength = segmentRecord.size.Z * 0.5
		local firstEnd = segmentRecord.cframe:PointToWorldSpace(Vector3.new(0, 0, halfLength))
		local secondEnd = segmentRecord.cframe:PointToWorldSpace(Vector3.new(0, 0, -halfLength))
		local nearbyCaps = {}
		local capSeen = {}
		for _, endpoint in ipairs({ firstEnd, secondEnd }) do
			for _, capRecord in ipairs(nearby(
				capBuckets,
				endpoint,
				Config.PipeDecorationPairSearchRadius
			)) do
				if not capSeen[capRecord] then
					capSeen[capRecord] = true
					table.insert(nearbyCaps, capRecord)
				end
			end
		end
		local pairByKey = {}
		local pairCount = 0
		local evidenceTouchesSelection = segmentHasSelectedEndpointEvidence(
			segment,
			firstEnd,
			secondEnd
		)
		for _, capRecord in ipairs(nearbyCaps) do
			local firstDistance = (firstEnd - capRecord.position).Magnitude
			local secondDistance = (secondEnd - capRecord.position).Magnitude
			local farEnd = firstDistance >= secondDistance and firstEnd or secondEnd
			local farConnectors = nearby(
				connectorBuckets,
				farEnd,
				Config.PipeDecorationSegmentTolerance
			)
			local capConnectors = nearby(
				connectorBuckets,
				capRecord.position,
				Config.PipeDecorationCapTolerance
			)
			for _, farRecord in ipairs(farConnectors) do
				for _, capConnectorRecord in ipairs(capConnectors) do
					if farRecord.connector ~= capConnectorRecord.connector then
						local matches = Runtime.connectionDecorationPairMatches(
							"Pipe",
							segment,
							capRecord.decoration,
							farRecord.connector,
							capConnectorRecord.connector
						)
						if matches then
							local fromRecord, toRecord = orientedPair(
								farRecord,
								capConnectorRecord,
								true
							)
							if fromRecord then
								local low = math.min(farRecord.id, capConnectorRecord.id)
								local high = math.max(farRecord.id, capConnectorRecord.id)
								local pairKey = tostring(low) .. ":" .. tostring(high)
								local pair = pairByKey[pairKey]
								if not pair then
									pair = {
										fromRecord = fromRecord,
										toRecord = toRecord,
										capSet = {},
										touchesSelection = farRecord.selectedIndex ~= nil
											or capConnectorRecord.selectedIndex ~= nil,
									}
									pairByKey[pairKey] = pair
									pairCount += 1
								end
								pair.capSet[capRecord] = true
							end
						end
					end
				end
			end
		end
		if pairCount == 1 then
			local pair = pairByKey[next(pairByKey)]
			pair.segmentRecord = segmentRecord
			pair.capOptions = capSetArray(pair.capSet)
			table.insert(resolvedCandidates, pair)
		elseif pairCount > 1 then
			local caps = {}
			local touchesSelection = evidenceTouchesSelection
			for _, pair in pairs(pairByKey) do
				touchesSelection = touchesSelection or pair.touchesSelection
				for capRecord in pairs(pair.capSet) do
					caps[capRecord] = true
				end
			end
			table.insert(ambiguousEvidence, {
				segmentRecord = segmentRecord,
				capOptions = capSetArray(caps),
				touchesSelection = touchesSelection,
			})
		else
			table.insert(unresolvedEvidence, {
				segmentRecord = segmentRecord,
				capOptions = nearbyCaps,
				touchesSelection = evidenceTouchesSelection,
			})
		end
	end

	-- Several binds can share one physical PipeA position, so their caps may be
	-- visually interchangeable. A one-to-one matching proves that enough real
	-- cap Instances exist without pretending an arbitrary cap identity matters.
	local relevantCandidates = {}
	local relevantCandidateSet = {}
	local relevantCaps = {}
	for _, candidate in ipairs(resolvedCandidates) do
		if candidate.touchesSelection then
			relevantCandidateSet[candidate] = true
			table.insert(relevantCandidates, candidate)
			for _, capRecord in ipairs(candidate.capOptions) do
				relevantCaps[capRecord] = true
			end
		end
	end
	local expanded = true
	while expanded do
		expanded = false
		for _, candidate in ipairs(resolvedCandidates) do
			if not relevantCandidateSet[candidate] then
				local sharesRelevantCap = false
				for _, capRecord in ipairs(candidate.capOptions) do
					if relevantCaps[capRecord] then
						sharesRelevantCap = true
						break
					end
				end
				if sharesRelevantCap then
					relevantCandidateSet[candidate] = true
					table.insert(relevantCandidates, candidate)
					for _, capRecord in ipairs(candidate.capOptions) do
						relevantCaps[capRecord] = true
					end
					expanded = true
				end
			end
		end
	end
	local function sharesRelevantCap(evidence)
		for _, capRecord in ipairs(evidence.capOptions or {}) do
			if relevantCaps[capRecord] then
				return true
			end
		end
		return false
	end
	for _, evidence in ipairs(ambiguousEvidence) do
		if evidence.touchesSelection or sharesRelevantCap(evidence) then
			recovery.AmbiguousSelectedDecorations += 1
		end
	end
	for _, evidence in ipairs(unresolvedEvidence) do
		if evidence.touchesSelection or sharesRelevantCap(evidence) then
			recovery.UnmatchedSegments += 1
			recovery.UnresolvedSelectedDecorations += 1
		end
	end
	table.sort(relevantCandidates, function(first, second)
		if first.touchesSelection ~= second.touchesSelection then
			return first.touchesSelection
		elseif #first.capOptions ~= #second.capOptions then
			return #first.capOptions < #second.capOptions
		end
		return first.segmentRecord.decoration:GetFullName()
			< second.segmentRecord.decoration:GetFullName()
	end)
	local capOwner = {}
	local function claimCap(candidate, visited)
		for _, capRecord in ipairs(candidate.capOptions) do
			if not visited[capRecord] then
				visited[capRecord] = true
				local owner = capOwner[capRecord]
				if not owner or claimCap(owner, visited) then
					capOwner[capRecord] = candidate
					candidate.assignedCap = capRecord
					return true
				end
			end
		end
		return false
	end
	for _, candidate in ipairs(relevantCandidates) do
		if not claimCap(candidate, {}) then
			-- Every candidate in this closure shares cap evidence (directly or
			-- transitively) with the selection. Letting an external competitor fail
			-- would arbitrarily donate its only cap to a selected segment.
			recovery.CapAssignmentFailures += 1
			recovery.UnresolvedSelectedDecorations += 1
		end
	end

	local usedCaps = {}
	local edgeSeen = {}
	for capRecord, candidate in pairs(capOwner) do
		usedCaps[capRecord] = true
		if candidate.assignedCap == capRecord then
			local fromRecord = candidate.fromRecord
			local toRecord = candidate.toRecord
			local low = math.min(fromRecord.id, toRecord.id)
			local high = math.max(fromRecord.id, toRecord.id)
			local edgeKey = tostring(low) .. ":" .. tostring(high)
			if edgeSeen[edgeKey] then
				if candidate.touchesSelection or edgeSeen[edgeKey].touchesSelection then
					recovery.AmbiguousSelectedDecorations += 1
				end
			else
				edgeSeen[edgeKey] = candidate
				local internalSelectedEdge = fromRecord.selectedIndex ~= nil
					and toRecord.selectedIndex ~= nil
				local exportable = true
				if internalSelectedEdge then
					for _, endpoint in ipairs({ fromRecord, toRecord }) do
						if not endpoint.pathValid then
							exportable = false
							recovery.UnmappedSelectedConnectors += 1
							recovery.UnresolvedSelectedDecorations += 1
						end
					end
				end
				local edge = {
					fromModel = fromRecord.model,
					toModel = toRecord.model,
					fromConnector = fromRecord.connector,
					toConnector = toRecord.connector,
					fromConnectorName = fromRecord.connector.Name,
					toConnectorName = toRecord.connector.Name,
					fromConnectorPath = fromRecord.path,
					toConnectorPath = toRecord.path,
					fromSelection = fromRecord.selectedIndex,
					toSelection = toRecord.selectedIndex,
					usable = exportable,
					decorations = {
						candidate.segmentRecord.decoration,
						capRecord.decoration,
					},
					liveDecorationProven = true,
				}
				table.insert(recovery.Edges, edge)
				recovery.MatchedSegmentCount += 1
				if candidate.touchesSelection then
					recovery.SelectedEdgeCount += 1
				end
			end
		end
	end

	for _, capRecord in ipairs(capRecords) do
		if not usedCaps[capRecord]
			and touchesSelected(nearby(
				connectorBuckets,
				capRecord.position,
				Config.PipeDecorationCapTolerance
			))
		then
			recovery.UnclaimedCaps += 1
			recovery.UnresolvedSelectedDecorations += 1
		end
	end
	for _, decorationRecord in ipairs(otherRecords) do
		if touchesSelected(nearby(
			connectorBuckets,
			decorationRecord.position,
			Config.PipeDecorationPairSearchRadius
		)) then
			recovery.UnexpectedDecorationClasses += 1
			recovery.UnresolvedSelectedDecorations += 1
		end
	end

	local currentCount = 0
	for _, decoration in ipairs(Runtime.connectionDecorationChildren("Pipe")) do
		if decoration:IsA("BasePart") and decoration.Name == "Pipe" then
			currentCount += 1
			local snapshot = decorationSnapshots[decoration]
			if not snapshot
				or snapshot.className ~= decoration.ClassName
				or snapshot.cframe ~= decoration.CFrame
				or snapshot.size ~= decoration.Size
			then
				recovery.Stable = false
			end
		end
	end
	if currentCount ~= #segmentRecords + #capRecords + #otherRecords then
		recovery.Stable = false
	end
	for decoration in pairs(decorationSnapshots) do
		if not decoration.Parent or not decoration:IsDescendantOf(ConnectionDecorations) then
			recovery.Stable = false
		end
	end

	recovery.Authoritative = recovery.Stable
		and recovery.UnresolvedSelectedDecorations == 0
		and recovery.AmbiguousSelectedDecorations == 0
	if not recovery.Stable then
		recovery.Detail = "server pipe decorations changed during inspection"
	elseif recovery.AmbiguousSelectedDecorations > 0 then
		recovery.Detail = string.format(
			"%d selected pipe decoration(s) matched more than one exact connector pair",
			recovery.AmbiguousSelectedDecorations
		)
	elseif recovery.UnresolvedSelectedDecorations > 0 then
		if recovery.UnmappedSelectedConnectors > 0 then
			recovery.Detail = string.format(
				"%d selected pipe connector path(s) did not map to the canonical template",
				recovery.UnmappedSelectedConnectors
			)
		elseif recovery.UnmatchedSegments > 0 or recovery.UnclaimedCaps > 0 then
			recovery.Detail = string.format(
				"%d live pipe link(s) lacked an exact pair (%d segment(s), %d cap(s))",
				math.max(recovery.UnmatchedSegments, recovery.UnclaimedCaps),
				recovery.UnmatchedSegments,
				recovery.UnclaimedCaps
			)
		elseif recovery.CapAssignmentFailures > 0 then
			recovery.Detail = string.format(
				"%d live pipe pair(s) could not claim distinct server caps",
				recovery.CapAssignmentFailures
			)
		elseif recovery.UnexpectedDecorationClasses > 0 then
			recovery.Detail = string.format(
				"%d nearby Pipe decoration(s) used an unsupported server class",
				recovery.UnexpectedDecorationClasses
			)
		else
			recovery.Detail = string.format(
				"%d selected pipe evidence item(s) could not be proven exactly",
				recovery.UnresolvedSelectedDecorations
			)
		end
	else
		recovery.Detail = string.format(
			"live decorations proved %d selected pipe link(s)",
			recovery.SelectedEdgeCount
		)
	end
	return recovery
end

-- Power connectors do not expose a connector-owned graph like
-- Pipe/PipeDecorations. Recover old wiring from the authoritative segment Part
-- plus cap UnionOperation pair. The saved-world oracle resolves every one of
-- its 172 Power segments uniquely with these same production tolerances.
function Runtime.recoverLiveWireConnections(selectedByModel)
	local recovery = {
		Edges = {},
		SelectedConnectorCount = 0,
		SelectedEdgeCount = 0,
		SegmentCount = 0,
		CapCount = 0,
		MatchedSegmentCount = 0,
		UnresolvedSelectedDecorations = 0,
		AmbiguousSelectedDecorations = 0,
		UnmatchedSegments = 0,
		UnclaimedCaps = 0,
		CapAssignmentFailures = 0,
		UnmappedSelectedConnectors = 0,
		UnexpectedDecorationClasses = 0,
		Stable = true,
		Authoritative = false,
		Detail = "live wire-decoration scan did not run",
	}
	if not ConnectionDecorations
		or not ConnectionDecorations.Parent
		or not ConnectionDecorations:IsDescendantOf(Plots)
	then
		recovery.Stable = false
		recovery.Detail = "the server connection-decoration folder is unavailable"
		return recovery
	end

	local cellSize = 4
	local function copiedPathKey(path)
		local parts = {}
		for _, segment in ipairs(type(path) == "table" and path or {}) do
			table.insert(parts, string.format(
				"%s/%s/%d",
				tostring(segment.Name),
				tostring(segment.ClassName),
				math.max(1, math.floor(tonumber(segment.Ordinal) or 1))
			))
		end
		return table.concat(parts, "|")
	end
	local function bucketKey(x, y, z)
		return string.format(
			"%d:%d:%d",
			math.floor(x / cellSize),
			math.floor(y / cellSize),
			math.floor(z / cellSize)
		)
	end
	local function addToBucket(buckets, value)
		local position = value.position
		local key = bucketKey(position.X, position.Y, position.Z)
		local bucket = buckets[key]
		if not bucket then
			bucket = {}
			buckets[key] = bucket
		end
		table.insert(bucket, value)
	end
	local function nearby(buckets, position, radius)
		local found = {}
		local seen = {}
		local extent = math.ceil(radius / cellSize)
		local centerX = math.floor(position.X / cellSize)
		local centerY = math.floor(position.Y / cellSize)
		local centerZ = math.floor(position.Z / cellSize)
		for x = centerX - extent, centerX + extent do
			for y = centerY - extent, centerY + extent do
				for z = centerZ - extent, centerZ + extent do
					for _, value in ipairs(buckets[string.format("%d:%d:%d", x, y, z)] or {}) do
						if not seen[value]
							and (value.position - position).Magnitude <= radius + Config.EdgeEpsilon
						then
							seen[value] = true
							table.insert(found, value)
						end
					end
				end
			end
		end
		return found
	end

	local models = {}
	local modelSeen = {}
	local function includeModel(model)
		if model
			and model:IsA("Model")
			and model.Parent
			and model:IsDescendantOf(Plots)
			and not modelSeen[model]
		then
			modelSeen[model] = true
			table.insert(models, model)
		end
	end
	for _, item in ipairs(State.duplicate.selected) do
		includeModel(item.model)
	end
	for _, placed in ipairs(collectPlacedMachines()) do
		includeModel(placed.model)
	end
	table.sort(models, function(first, second)
		local firstBase = first:FindFirstChild("Base")
		local secondBase = second:FindFirstChild("Base")
		local firstPosition = firstBase and firstBase:IsA("BasePart") and firstBase.Position or Vector3.zero
		local secondPosition = secondBase and secondBase:IsA("BasePart") and secondBase.Position or Vector3.zero
		local firstKey = string.format(
			"%+.4f/%+.4f/%+.4f/%s",
			firstPosition.X,
			firstPosition.Y,
			firstPosition.Z,
			first:GetFullName()
		)
		local secondKey = string.format(
			"%+.4f/%+.4f/%+.4f/%s",
			secondPosition.X,
			secondPosition.Y,
			secondPosition.Z,
			second:GetFullName()
		)
		return firstKey < secondKey
	end)

	local connectorBuckets = {}
	local connectorRecords = {}
	local uncachedModels = 0
	for _, model in ipairs(models) do
		local inventory, wasCached = Runtime.connectionConnectorRecords(model, "Wire")
		if not wasCached then
			uncachedModels += 1
			if uncachedModels % Config.ConnectionRecoveryModelYieldEvery == 0 then
				RunService.Heartbeat:Wait()
			end
		end
		for _, cachedConnector in ipairs(inventory) do
			local descendant = cachedConnector.connector
			local metadata = cachedConnector.metadata
			if descendant.Parent and metadata and metadata.Parent == descendant then
					local path = cachedConnector.path
					local selectedIndex = selectedByModel[model]
					local pathValid = path ~= nil
					if selectedIndex and pathValid then
						local item = State.duplicate.selected[selectedIndex]
						local canonical = item and Runtime.resolveStoredConnectorPath(item.template, path)
						pathValid = canonical ~= nil and canonical.Name == descendant.Name
					end
					local base = model:FindFirstChild("Base")
					local basePosition = base and base:IsA("BasePart") and base.Position or Vector3.zero
					local record = {
						id = #connectorRecords + 1,
						connector = descendant,
						model = model,
						path = path,
						pathValid = pathValid,
						selectedIndex = selectedIndex,
						position = descendant.Position,
						orderKey = string.format(
							"%+.4f/%+.4f/%+.4f/%s/%s",
							basePosition.X,
							basePosition.Y,
							basePosition.Z,
							model:GetFullName(),
							copiedPathKey(path)
						),
					}
					table.insert(connectorRecords, record)
					addToBucket(connectorBuckets, record)
					if selectedIndex then
						recovery.SelectedConnectorCount += 1
					end
			end
		end
	end

	local segmentRecords = {}
	local capRecords = {}
	local otherRecords = {}
	local capBuckets = {}
	local decorationSnapshots = {}
	for _, decoration in ipairs(Runtime.connectionDecorationChildren("Power")) do
		if decoration:IsA("BasePart") and decoration.Name == "Power" then
			local record = {
				decoration = decoration,
				position = decoration.Position,
				cframe = decoration.CFrame,
				size = decoration.Size,
				className = decoration.ClassName,
			}
			decorationSnapshots[decoration] = record
			if decoration:IsA("UnionOperation") then
				table.insert(capRecords, record)
				addToBucket(capBuckets, record)
			elseif decoration:IsA("Part") then
				table.insert(segmentRecords, record)
			else
				table.insert(otherRecords, record)
			end
		end
	end
	recovery.SegmentCount = #segmentRecords
	recovery.CapCount = #capRecords

	local function touchesSelected(records)
		for _, record in ipairs(records) do
			if record.selectedIndex then
				return true
			end
		end
		return false
	end
	local function orientedPair(first, second, liveDecorationProven)
		local forward = Runtime.validateDuplicateExportConnection(
			"Wire",
			first.connector,
			second.connector,
			liveDecorationProven
		)
		local reverse = Runtime.validateDuplicateExportConnection(
			"Wire",
			second.connector,
			first.connector,
			liveDecorationProven
		)
		if forward and not reverse then
			return first, second
		elseif reverse and not forward then
			return second, first
		elseif forward and reverse then
			return first.orderKey <= second.orderKey and first or second,
				first.orderKey <= second.orderKey and second or first
		end
		return nil
	end

	local resolvedCandidates = {}
	local ambiguousEvidence = {}
	local unresolvedEvidence = {}
	local function capSetArray(capSet)
		local caps = {}
		for capRecord in pairs(capSet) do
			table.insert(caps, capRecord)
		end
		table.sort(caps, function(first, second)
			return first.decoration:GetFullName() < second.decoration:GetFullName()
		end)
		return caps
	end
	local function segmentHasSelectedEndpointEvidence(segment, firstEnd, secondEnd)
		local nearRadius = Config.PowerDecorationLengthBiasMax
			+ Config.PowerDecorationSegmentTolerance
		for _, ends in ipairs({
			{ far = firstEnd, near = secondEnd },
			{ far = secondEnd, near = firstEnd },
		}) do
			local farConnectors = nearby(
				connectorBuckets,
				ends.far,
				Config.PowerDecorationSegmentTolerance
			)
			local nearConnectors = nearby(connectorBuckets, ends.near, nearRadius)
			for _, farRecord in ipairs(farConnectors) do
				for _, nearRecord in ipairs(nearConnectors) do
					if farRecord.connector ~= nearRecord.connector
						and (farRecord.selectedIndex ~= nil or nearRecord.selectedIndex ~= nil)
						-- Relevance may ignore the authored-name heuristic so a partial exact
						-- power segment cannot disappear. Acceptance still requires its cap.
						and orientedPair(farRecord, nearRecord, true) ~= nil
						and Runtime.connectionDecorationCouldBelongToEdge(
							"Wire",
							segment,
							farRecord.connector,
							nearRecord.connector
						)
					then
						return true
					end
				end
			end
		end
		return false
	end
	for _, segmentRecord in ipairs(segmentRecords) do
		local segment = segmentRecord.decoration
		local halfLength = segmentRecord.size.Z * 0.5
		local firstEnd = segmentRecord.cframe:PointToWorldSpace(Vector3.new(0, 0, halfLength))
		local secondEnd = segmentRecord.cframe:PointToWorldSpace(Vector3.new(0, 0, -halfLength))
		local nearbyCaps = {}
		local capSeen = {}
		for _, endpoint in ipairs({ firstEnd, secondEnd }) do
			for _, capRecord in ipairs(nearby(
				capBuckets,
				endpoint,
				Config.PowerDecorationPairSearchRadius
			)) do
				if not capSeen[capRecord] then
					capSeen[capRecord] = true
					table.insert(nearbyCaps, capRecord)
				end
			end
		end
		local pairByKey = {}
		local pairCount = 0
		local evidenceTouchesSelection = segmentHasSelectedEndpointEvidence(
			segment,
			firstEnd,
			secondEnd
		)
		for _, capRecord in ipairs(nearbyCaps) do
			local firstDistance = (firstEnd - capRecord.position).Magnitude
			local secondDistance = (secondEnd - capRecord.position).Magnitude
			local farEnd = firstDistance >= secondDistance and firstEnd or secondEnd
			local farConnectors = nearby(
				connectorBuckets,
				farEnd,
				Config.PowerDecorationSegmentTolerance
			)
			local capConnectors = nearby(
				connectorBuckets,
				capRecord.position,
				Config.PowerDecorationCapTolerance
			)
			for _, farRecord in ipairs(farConnectors) do
				for _, capConnectorRecord in ipairs(capConnectors) do
					if farRecord.connector ~= capConnectorRecord.connector then
						local matches = Runtime.connectionDecorationPairMatches(
							"Wire",
							segment,
							capRecord.decoration,
							farRecord.connector,
							capConnectorRecord.connector
						)
						if matches then
							local fromRecord, toRecord = orientedPair(
								farRecord,
								capConnectorRecord,
								true
							)
							if fromRecord then
								local low = math.min(farRecord.id, capConnectorRecord.id)
								local high = math.max(farRecord.id, capConnectorRecord.id)
								local pairKey = tostring(low) .. ":" .. tostring(high)
								local pair = pairByKey[pairKey]
								if not pair then
									pair = {
										fromRecord = fromRecord,
										toRecord = toRecord,
										capSet = {},
										touchesSelection = farRecord.selectedIndex ~= nil
											or capConnectorRecord.selectedIndex ~= nil,
									}
									pairByKey[pairKey] = pair
									pairCount += 1
								end
								pair.capSet[capRecord] = true
							end
						end
					end
				end
			end
		end
		if pairCount == 1 then
			local pair = pairByKey[next(pairByKey)]
			pair.segmentRecord = segmentRecord
			pair.capOptions = capSetArray(pair.capSet)
			table.insert(resolvedCandidates, pair)
		elseif pairCount > 1 then
			local caps = {}
			local touchesSelection = evidenceTouchesSelection
			for _, pair in pairs(pairByKey) do
				touchesSelection = touchesSelection or pair.touchesSelection
				for capRecord in pairs(pair.capSet) do
					caps[capRecord] = true
				end
			end
			table.insert(ambiguousEvidence, {
				capOptions = capSetArray(caps),
				touchesSelection = touchesSelection,
			})
		else
			table.insert(unresolvedEvidence, {
				capOptions = nearbyCaps,
				touchesSelection = evidenceTouchesSelection,
			})
		end
	end

	local relevantCandidates = {}
	local relevantCandidateSet = {}
	local relevantCaps = {}
	for _, candidate in ipairs(resolvedCandidates) do
		if candidate.touchesSelection then
			relevantCandidateSet[candidate] = true
			table.insert(relevantCandidates, candidate)
			for _, capRecord in ipairs(candidate.capOptions) do
				relevantCaps[capRecord] = true
			end
		end
	end
	local expanded = true
	while expanded do
		expanded = false
		for _, candidate in ipairs(resolvedCandidates) do
			if not relevantCandidateSet[candidate] then
				for _, capRecord in ipairs(candidate.capOptions) do
					if relevantCaps[capRecord] then
						relevantCandidateSet[candidate] = true
						table.insert(relevantCandidates, candidate)
						for _, sharedCap in ipairs(candidate.capOptions) do
							relevantCaps[sharedCap] = true
						end
						expanded = true
						break
					end
				end
			end
		end
	end
	local function sharesRelevantCap(evidence)
		for _, capRecord in ipairs(evidence.capOptions or {}) do
			if relevantCaps[capRecord] then
				return true
			end
		end
		return false
	end
	for _, evidence in ipairs(ambiguousEvidence) do
		if evidence.touchesSelection or sharesRelevantCap(evidence) then
			recovery.AmbiguousSelectedDecorations += 1
		end
	end
	for _, evidence in ipairs(unresolvedEvidence) do
		if evidence.touchesSelection or sharesRelevantCap(evidence) then
			recovery.UnmatchedSegments += 1
			recovery.UnresolvedSelectedDecorations += 1
		end
	end
	table.sort(relevantCandidates, function(first, second)
		if first.touchesSelection ~= second.touchesSelection then
			return first.touchesSelection
		elseif #first.capOptions ~= #second.capOptions then
			return #first.capOptions < #second.capOptions
		end
		return first.segmentRecord.decoration:GetFullName()
			< second.segmentRecord.decoration:GetFullName()
	end)
	local capOwner = {}
	local function claimCap(candidate, visited)
		for _, capRecord in ipairs(candidate.capOptions) do
			if not visited[capRecord] then
				visited[capRecord] = true
				local owner = capOwner[capRecord]
				if not owner or claimCap(owner, visited) then
					capOwner[capRecord] = candidate
					candidate.assignedCap = capRecord
					return true
				end
			end
		end
		return false
	end
	for _, candidate in ipairs(relevantCandidates) do
		if not claimCap(candidate, {}) then
			recovery.CapAssignmentFailures += 1
			recovery.UnresolvedSelectedDecorations += 1
		end
	end

	local usedCaps = {}
	local edgeSeen = {}
	for capRecord, candidate in pairs(capOwner) do
		usedCaps[capRecord] = true
		if candidate.assignedCap == capRecord then
			local fromRecord = candidate.fromRecord
			local toRecord = candidate.toRecord
			local low = math.min(fromRecord.id, toRecord.id)
			local high = math.max(fromRecord.id, toRecord.id)
			local edgeKey = tostring(low) .. ":" .. tostring(high)
			if edgeSeen[edgeKey] then
				if candidate.touchesSelection or edgeSeen[edgeKey].touchesSelection then
					recovery.AmbiguousSelectedDecorations += 1
				end
			else
				edgeSeen[edgeKey] = candidate
				local internalSelectedEdge = fromRecord.selectedIndex ~= nil
					and toRecord.selectedIndex ~= nil
				local exportable = true
				if internalSelectedEdge then
					for _, endpoint in ipairs({ fromRecord, toRecord }) do
						if not endpoint.pathValid then
							exportable = false
							recovery.UnmappedSelectedConnectors += 1
							recovery.UnresolvedSelectedDecorations += 1
						end
					end
				end
				table.insert(recovery.Edges, {
					fromModel = fromRecord.model,
					toModel = toRecord.model,
					fromConnector = fromRecord.connector,
					toConnector = toRecord.connector,
					fromConnectorName = fromRecord.connector.Name,
					toConnectorName = toRecord.connector.Name,
					fromConnectorPath = fromRecord.path,
					toConnectorPath = toRecord.path,
					fromSelection = fromRecord.selectedIndex,
					toSelection = toRecord.selectedIndex,
					usable = exportable,
					decorations = { candidate.segmentRecord.decoration, capRecord.decoration },
					liveDecorationProven = true,
				})
				recovery.MatchedSegmentCount += 1
				if candidate.touchesSelection then
					recovery.SelectedEdgeCount += 1
				end
			end
		end
	end

	for _, capRecord in ipairs(capRecords) do
		if not usedCaps[capRecord]
			and touchesSelected(nearby(
				connectorBuckets,
				capRecord.position,
				Config.PowerDecorationCapTolerance
			))
		then
			recovery.UnclaimedCaps += 1
			recovery.UnresolvedSelectedDecorations += 1
		end
	end
	for _, decorationRecord in ipairs(otherRecords) do
		if touchesSelected(nearby(
			connectorBuckets,
			decorationRecord.position,
			Config.PowerDecorationPairSearchRadius
		)) then
			recovery.UnexpectedDecorationClasses += 1
			recovery.UnresolvedSelectedDecorations += 1
		end
	end

	local currentCount = 0
	for _, decoration in ipairs(Runtime.connectionDecorationChildren("Power")) do
		if decoration:IsA("BasePart") and decoration.Name == "Power" then
			currentCount += 1
			local snapshot = decorationSnapshots[decoration]
			if not snapshot
				or snapshot.className ~= decoration.ClassName
				or snapshot.cframe ~= decoration.CFrame
				or snapshot.size ~= decoration.Size
			then
				recovery.Stable = false
			end
		end
	end
	if currentCount ~= #segmentRecords + #capRecords + #otherRecords then
		recovery.Stable = false
	end
	for decoration in pairs(decorationSnapshots) do
		if not decoration.Parent or not decoration:IsDescendantOf(ConnectionDecorations) then
			recovery.Stable = false
		end
	end
	for _, connectorRecord in ipairs(connectorRecords) do
		if not connectorRecord.connector.Parent
			or connectorRecord.connector.Position ~= connectorRecord.position
		then
			recovery.Stable = false
		end
	end

	recovery.Authoritative = recovery.Stable
		and recovery.UnresolvedSelectedDecorations == 0
		and recovery.AmbiguousSelectedDecorations == 0
	if not recovery.Stable then
		recovery.Detail = "server wire decorations changed during inspection"
	elseif recovery.AmbiguousSelectedDecorations > 0 then
		recovery.Detail = string.format(
			"%d selected wire segment(s) matched multiple exact connector pairs",
			recovery.AmbiguousSelectedDecorations
		)
	elseif recovery.UnresolvedSelectedDecorations > 0 then
		recovery.Detail = string.format(
			"%d selected wire evidence item(s) could not be proven exactly",
			recovery.UnresolvedSelectedDecorations
		)
	else
		recovery.Detail = string.format(
			"live decorations proved %d selected wire link(s)",
			recovery.SelectedEdgeCount
		)
	end
	return recovery
end

function Runtime.createDuplicateConnectionPlans(folder)
	local duplicate = State.duplicate
	if duplicate.connectionAuditInProgress then
		error("another exact pipe/wire graph audit is already running", 0)
	end
	duplicate.connectionAuditInProgress = true
	local auditOK, auditResult = pcall(function()
		duplicate.connections = {}
		duplicate.previewConnectionLinesUsed = 0
		local selectedByModel = {}
		for selectionIndex, item in ipairs(duplicate.selected) do
			selectedByModel[item.model] = selectionIndex
		end
		local knownObservationCodes = {}
		local registryCandidates = {}
		local rememberedIncidentConnections = { Pipe = {}, Wire = {} }
		local function observedKnownConnection(known)
			local code = knownObservationCodes[known]
			if code == nil then
				local observed = Runtime.knownConnectionStillObserved(known)
				if observed == true then
					code = 1
				elseif observed == false then
					code = 2
				else
					code = 3
				end
				knownObservationCodes[known] = code
			end
			if code == 1 then
				return true
			elseif code == 2 then
				return false
			end
			return nil
		end
		-- Snapshot registry provenance before the live scan. Do not downgrade it yet:
		-- a streamed-out decoration can produce two identical empty frames even though
		-- the last exact nonempty graph is about to replicate back in.
		for _, known in ipairs(State.knownConnections) do
			observedKnownConnection(known)
			-- Only edges incident to this selection can produce a plan or a boundary
			-- count. Keep them in registry source order while the required full-registry
			-- provenance refresh is already in progress.
			if selectedByModel[known.fromModel] or selectedByModel[known.toModel] then
				registryCandidates[#registryCandidates + 1] = known
				if known.confirmed ~= false
					and (known.kind == "Pipe" or known.kind == "Wire")
					and type(known.decorations) == "table"
					and #known.decorations >= Config.ConnectionDecorationCount
					and known.fromModel
					and known.fromModel.Parent
					and known.toModel
					and known.toModel.Parent
				then
					table.insert(rememberedIncidentConnections[known.kind], known)
				end
			end
		end
	local selectedByReference = {}
	local selectionHasCompleteManifest = #duplicate.selected > 0
	local pipeManifestModelCount = 0
	local pipeManifestIsComplete = true
	local selectedPowerConnectorCount = 0
	local wireManifestIsComplete = true
	for selectionIndex, item in ipairs(duplicate.selected) do
		if State.completeConnectionModels[item.model] ~= true then
			selectionHasCompleteManifest = false
		end
		-- With forcePhysical=true this includes machines at the route endpoints,
		-- not only the standalone pipe pieces. Objects with no Pipe metadata are
		-- inert for plumbing and intentionally do not affect manifest authority.
		if Runtime.duplicatePlumbingRequiredDegree(item, true) ~= nil then
			pipeManifestModelCount += 1
			if State.completeConnectionModels[item.model] ~= true then
				pipeManifestIsComplete = false
			end
		end
		local powerConnectorCount = Runtime.templatePowerConnectorCount(item.template)
		if powerConnectorCount > 0 then
			selectedPowerConnectorCount += powerConnectorCount
			if State.completeConnectionModels[item.model] ~= true then
				wireManifestIsComplete = false
			end
		end
		local storedKey = Runtime.duplicateReferenceKey(item.sourceReference)
		local currentKey = Runtime.duplicateReferenceKey(Runtime.duplicateSourceReference(item.model))
		if storedKey and storedKey == currentKey then
			selectedByReference[storedKey] = selectionIndex
		end
	end
	-- The registry proves only the last graph this script built. A manual link can
	-- be added or removed later, so every selected connector family is recovered
	-- from the current server decorations even when the old registry was complete.
	local registryPipeManifestAvailable = pipeManifestModelCount > 0 and pipeManifestIsComplete
	local registryWireManifestAvailable = selectedPowerConnectorCount > 0 and wireManifestIsComplete
		local function pathSignature(path)
			local parts = {}
			for _, segment in ipairs(type(path) == "table" and path or {}) do
				table.insert(parts, string.format(
					"%s\30%s\30%d",
					tostring(segment.Name),
					tostring(segment.ClassName),
					math.max(1, math.floor(tonumber(segment.Ordinal) or 1))
				))
			end
			return table.concat(parts, "\29")
		end
		local function authoritativeSegment(decorations)
			for _, decoration in ipairs(type(decorations) == "table" and decorations or {}) do
				if typeof(decoration) == "Instance"
					and decoration:IsA("Part")
					and not decoration:IsA("UnionOperation")
				then
					return decoration
				end
			end
			return nil
		end
		local function sameRecoveredEdge(first, second)
			return first.fromModel == second.fromModel
				and first.toModel == second.toModel
				and (first.fromConnector == nil or second.fromConnector == nil
					or first.fromConnector == second.fromConnector)
				and (first.toConnector == nil or second.toConnector == nil
					or first.toConnector == second.toConnector)
				and first.fromConnectorName == second.fromConnectorName
				and first.toConnectorName == second.toConnectorName
				and pathSignature(first.fromConnectorPath) == pathSignature(second.fromConnectorPath)
				and pathSignature(first.toConnectorPath) == pathSignature(second.toConnectorPath)
				and first.usable == second.usable
				-- Segment identity is authoritative. Endpoint caps can be exact yet
				-- interchangeable when several links share one physical node.
				and authoritativeSegment(first.decorations)
					== authoritativeSegment(second.decorations)
		end
		local function selectedRecoveredEdges(recovery)
			local edges = {}
			for _, edge in ipairs(type(recovery.Edges) == "table" and recovery.Edges or {}) do
				if edge.fromSelection ~= nil
					or edge.toSelection ~= nil
					or selectedByModel[edge.fromModel] ~= nil
					or selectedByModel[edge.toModel] ~= nil
				then
					table.insert(edges, edge)
				end
			end
			return edges
		end
		local function recoverySnapshotsEqual(first, second)
			local countFields = {
				"SelectedConnectorCount",
				"SelectedEdgeCount",
				"UnresolvedSelectedDecorations",
				"AmbiguousSelectedDecorations",
				"UnmatchedSegments",
				"UnclaimedCaps",
				"CapAssignmentFailures",
				"UnmappedSelectedConnectors",
				"UnexpectedDecorationClasses",
			}
			for _, field in ipairs(countFields) do
				if (tonumber(first[field]) or 0) ~= (tonumber(second[field]) or 0) then
					return false
				end
			end
			if first.Stable ~= second.Stable or first.Authoritative ~= second.Authoritative then
				return false
			end
			-- Only the selected component must remain identical. Other players may add
			-- or remove unrelated factory links between these two replication frames.
			local firstEdges = selectedRecoveredEdges(first)
			local secondEdges = selectedRecoveredEdges(second)
			if #firstEdges ~= #secondEdges then
				return false
			end
			local claimed = {}
			for _, firstEdge in ipairs(firstEdges) do
				local matched
				for index, secondEdge in ipairs(secondEdges) do
					if not claimed[index] and sameRecoveredEdge(firstEdge, secondEdge) then
						matched = index
						break
					end
				end
				if not matched then
					return false
				end
				claimed[matched] = true
			end
			return true
		end
		local function recoveryFailure(family, expectedConnectorCount, detail, registryConflict)
			return {
				Edges = {},
				SelectedConnectorCount = expectedConnectorCount,
				SelectedEdgeCount = 0,
				UnresolvedSelectedDecorations = 1,
				AmbiguousSelectedDecorations = 0,
				Stable = false,
				Authoritative = false,
				RegistryConflict = registryConflict == true,
				Detail = string.format("live %s-decoration inspection failed: %s", family, detail),
			}
		end
		local function recoverAcrossHeartbeat(
			recoverer,
			family,
			expectedConnectorCount,
			rememberedConnections
		)
			local firstOK, first = pcall(recoverer, selectedByModel)
			RunService.Heartbeat:Wait()
			local secondOK, second = pcall(recoverer, selectedByModel)
			if not (firstOK and secondOK
				and type(first) == "table"
				and type(second) == "table"
				and recoverySnapshotsEqual(first, second))
			then
				local detail = not firstOK and tostring(first)
					or not secondOK and tostring(second)
					or "the selected live graph changed across consecutive replication frames"
				return recoveryFailure(family, expectedConnectorCount, detail, false)
			end

			local latest = second
			local remembered = type(rememberedConnections) == "table" and rememberedConnections or {}
			if latest.Authoritative == true
				and (tonumber(latest.SelectedEdgeCount) or 0) == 0
				and expectedConnectorCount > 0
			then
				local deadline = os.clock() + Config.LiveConnectionEmptyQuietTime
				while os.clock() < deadline do
					RunService.Heartbeat:Wait()
					local nextOK, nextFrame = pcall(recoverer, selectedByModel)
					if not nextOK
						or type(nextFrame) ~= "table"
						or not recoverySnapshotsEqual(latest, nextFrame)
					then
						return recoveryFailure(
							family,
							expectedConnectorCount,
							"an empty selected graph did not remain identical through the replication quiet window",
							true
						)
					end
					latest = nextFrame
				end

				local stillObserved = 0
				for _, known in ipairs(remembered) do
					-- The earlier observation was deliberately cached for this audit. Refresh
					-- it after the quiet window before allowing an empty graph to win.
					knownObservationCodes[known] = nil
					if observedKnownConnection(known) == true then
						stillObserved += 1
					end
				end
				if stillObserved > 0 then
					return recoveryFailure(
						family,
						expectedConnectorCount,
						string.format(
							"empty live frames conflict with %d still-observed exact registry edge(s)",
							stillObserved
						),
						true
					)
				end
			end
			return latest
		end
		local livePipeRecovery = pipeManifestModelCount > 0
			and recoverAcrossHeartbeat(
				Runtime.recoverLivePipeConnections,
				"pipe",
				pipeManifestModelCount,
				rememberedIncidentConnections.Pipe
			)
			or nil
		local liveWireRecovery = selectedPowerConnectorCount > 0
			and recoverAcrossHeartbeat(
				Runtime.recoverLiveWireConnections,
				"wire",
				selectedPowerConnectorCount,
				rememberedIncidentConnections.Wire
			)
			or nil
	local livePipeRecoveryAttempted = livePipeRecovery ~= nil
	local liveWireRecoveryAttempted = liveWireRecovery ~= nil
	-- A recovery table also carries exact failure diagnostics. It is a manifest
	-- only when the two-frame scan explicitly proved itself authoritative; a
	-- failed table must not suppress the pasted graph or still-observed registry.
	local useLiveDecorationManifest = livePipeRecoveryAttempted
		and livePipeRecovery.Authoritative == true
	local useLiveWireDecorationManifest = liveWireRecoveryAttempted
		and liveWireRecovery.Authoritative == true
	local useLivePipeRegistryManifest = not useLiveDecorationManifest
		and registryPipeManifestAvailable
	-- Historical completeness is usable only when no current live inspection was
	-- possible. Once a live scan runs, a failed/ambiguous result must stay
	-- fail-closed; an older registry cannot prove that no manual wire was added.
	local useLiveWireRegistryManifest = not liveWireRecoveryAttempted
		and not useLiveWireDecorationManifest
		and registryWireManifestAvailable
	local recoveredMapping
	local recoveryDetail
	if not useLivePipeRegistryManifest or not useLiveWireRegistryManifest then
		local graphDetail
		recoveredMapping, graphDetail = Runtime.mapDuplicateSelectionToGraph()
		if livePipeRecoveryAttempted or liveWireRecoveryAttempted then
			local liveDetails = {}
			if livePipeRecoveryAttempted then
				table.insert(liveDetails, "pipes: " .. tostring(livePipeRecovery.Detail))
			end
			if liveWireRecoveryAttempted then
				table.insert(liveDetails, "wires: " .. tostring(liveWireRecovery.Detail))
			end
			recoveryDetail = table.concat(liveDetails, " • ")
				.. " • loaded graph: " .. tostring(graphDetail)
		else
			recoveryDetail = graphDetail
		end
	else
		recoveryDetail = "complete live registry manifest"
	end
	if recoveredMapping then
		for referenceKey, selectionIndex in pairs(recoveredMapping) do
			selectedByReference[referenceKey] = selectedByReference[referenceKey] or selectionIndex
		end
	end
	local physicalSelections = {}
	for referenceKey, selectionIndex in pairs(selectedByReference) do
		local item = duplicate.selected[selectionIndex]
		if string.sub(referenceKey, 1, 2) == "P:"
			and item
			and Runtime.templatePowerConnectorCount(item.template) == 0
		then
			physicalSelections[selectionIndex] = true
		end
	end
	for selectionIndex, item in ipairs(duplicate.selected) do
		if Runtime.isDuplicatePhysicalPlumbing(item) then
			physicalSelections[selectionIndex] = true
		end
	end

	local genericPlanByKey = {}
	local exactPlanByKey = {}
	local exactFamilySeen = {}
	local pipePlanCount = 0
	local wirePlanCount = 0
	local registryPlanCount = 0
	local registryWirePlanCount = 0
	local liveRecoveryPlanCount = 0
	local liveWireRecoveryPlanCount = 0
	local boundaryPipeLinks = 0
	local boundaryWireLinks = 0
	local unknownRegistryConnections = 0
	local function connectorPathSignature(path)
		if type(path) ~= "table" or #path == 0 then
			return nil
		end
		local parts = {}
		for _, segment in ipairs(path) do
			table.insert(parts, string.format(
				"%s\30%s\30%d",
				tostring(segment.Name),
				tostring(segment.ClassName),
				math.max(1, math.floor(tonumber(segment.Ordinal) or 1))
			))
		end
		return table.concat(parts, "\29")
	end
	local function applyLivePlanProvenance(plan, provenance)
		if not plan or type(provenance) ~= "table" or provenance.liveDecorationProven ~= true then
			return
		end
		plan.liveDecorationProven = true
		if type(provenance.sourceDecorations) == "table" then
			plan.sourceDecorations = {}
			for _, decoration in ipairs(provenance.sourceDecorations) do
				table.insert(plan.sourceDecorations, decoration)
			end
		end
	end
	local function addDirectPlan(
		kind,
		fromSelection,
		toSelection,
		fromConnectorName,
		toConnectorName,
		fromConnectorPath,
		toConnectorPath,
		provenance
	)
		if not fromSelection or not toSelection then
			return false
		end
		local genericKey = string.format(
			"%s:%d:%s>%d:%s",
			kind,
			fromSelection,
			tostring(fromConnectorName),
			toSelection,
			tostring(toConnectorName)
		)
		local fromPathKey = connectorPathSignature(fromConnectorPath)
		local toPathKey = connectorPathSignature(toConnectorPath)
		local exactKey = fromPathKey and toPathKey
			and (genericKey .. "\28" .. fromPathKey .. ">" .. toPathKey)
			or nil
		if exactKey and exactPlanByKey[exactKey] then
			applyLivePlanProvenance(exactPlanByKey[exactKey], provenance)
			return false
		elseif exactKey then
			-- A name-only blueprint link may already represent this connection.
			-- Upgrade that one placeholder to the first observed exact path, then
			-- allow additional same-named holes to become separate plans. This is
			-- essential for machines with two output holes bearing the same name.
			local placeholder = genericPlanByKey[genericKey]
			if placeholder then
				placeholder.fromConnectorPath = Runtime.copyConnectorPath(fromConnectorPath)
				placeholder.toConnectorPath = Runtime.copyConnectorPath(toConnectorPath)
				placeholder.fromConnectorPathSignature = fromPathKey
				placeholder.toConnectorPathSignature = toPathKey
				genericPlanByKey[genericKey] = nil
				exactPlanByKey[exactKey] = placeholder
				exactFamilySeen[genericKey] = true
				applyLivePlanProvenance(placeholder, provenance)
				return true
			end
		elseif genericPlanByKey[genericKey] or exactFamilySeen[genericKey] then
			return false
		end
		local index = #duplicate.connections + 1
		local plan = {
			kind = kind,
			index = index,
			fromSelection = fromSelection,
			toSelection = toSelection,
			fromConnectorName = fromConnectorName,
			toConnectorName = toConnectorName,
			fromConnectorPath = fromConnectorPath and Runtime.copyConnectorPath(fromConnectorPath) or nil,
			toConnectorPath = toConnectorPath and Runtime.copyConnectorPath(toConnectorPath) or nil,
			fromConnectorPathSignature = fromPathKey,
			toConnectorPathSignature = toPathKey,
			selectionVersion = duplicate.selectionVersion,
			reasons = {},
			valid = false,
			built = false,
		}
		applyLivePlanProvenance(plan, provenance)
		if folder then
			plan.line = Runtime.createConnectionPreviewLine(
				folder,
				string.format("Duplicate%s_%03d", kind, index),
				duplicate,
				kind
			)
		end
		table.insert(duplicate.connections, plan)
		if exactKey then
			exactPlanByKey[exactKey] = plan
			exactFamilySeen[genericKey] = true
		else
			genericPlanByKey[genericKey] = plan
		end
		if kind == "Pipe" then
			pipePlanCount += 1
		else
			wirePlanCount += 1
		end
		return true
	end

	local function addGraphPlan(kind, entry)
		if type(entry) ~= "table" or type(entry.From) ~= "table" or type(entry.To) ~= "table" then
			return false
		end
		local fromSelection = selectedByReference[Runtime.duplicateReferenceKey(entry.From)]
		local toSelection = selectedByReference[Runtime.duplicateReferenceKey(entry.To)]
		if kind == "Pipe" and ((fromSelection ~= nil) ~= (toSelection ~= nil)) then
			boundaryPipeLinks += 1
		elseif kind == "Wire" and ((fromSelection ~= nil) ~= (toSelection ~= nil)) then
			boundaryWireLinks += 1
		end
		return addDirectPlan(
			kind,
			fromSelection,
			toSelection,
			entry.From.Connector,
			entry.To.Connector,
			entry.From.ConnectorPath,
			entry.To.ConnectorPath
		)
	end

	-- Pipe and wire provenance are independent. Prefer the current server's
	-- exact live manifests; use pasted graph arrays only for a family that has no
	-- authoritative live source.
	if not useLivePipeRegistryManifest and not useLiveDecorationManifest then
		for _, entry in ipairs(AuthoredPipeLinks) do
			addGraphPlan("Pipe", entry)
		end
	end
	if not useLiveWireRegistryManifest and not useLiveWireDecorationManifest then
		for _, entry in ipairs(Wiring) do
			addGraphPlan("Wire", entry)
		end
	end
	if useLiveWireDecorationManifest then
		for _, edge in ipairs(liveWireRecovery.Edges or {}) do
			local fromSelection = selectedByModel[edge.fromModel]
			local toSelection = selectedByModel[edge.toModel]
			if (fromSelection ~= nil) ~= (toSelection ~= nil) then
				boundaryWireLinks += 1
			elseif edge.usable ~= false and addDirectPlan(
				"Wire",
				fromSelection,
				toSelection,
				edge.fromConnectorName,
				edge.toConnectorName,
				edge.fromConnectorPath,
				edge.toConnectorPath,
				{
					liveDecorationProven = edge.liveDecorationProven == true,
					sourceDecorations = edge.decorations,
				}
			) then
				liveWireRecoveryPlanCount += 1
			end
		end
	end
	if useLiveDecorationManifest then
		for _, edge in ipairs(livePipeRecovery.Edges or {}) do
			local fromSelection = selectedByModel[edge.fromModel]
			local toSelection = selectedByModel[edge.toModel]
			if (fromSelection ~= nil) ~= (toSelection ~= nil) then
				boundaryPipeLinks += 1
			elseif edge.usable ~= false and addDirectPlan(
				"Pipe",
				fromSelection,
				toSelection,
				edge.fromConnectorName,
				edge.toConnectorName,
				edge.fromConnectorPath,
				edge.toConnectorPath,
				{
					liveDecorationProven = edge.liveDecorationProven == true,
					sourceDecorations = edge.decorations,
				}
			) then
				liveRecoveryPlanCount += 1
			end
		end
	end

	-- Connections verified by this script are also kept as exact source-model
	-- paths. This makes plumbing survive Clear, reinjection, and duplicating a
	-- previous duplicate without guessing links from nearby pipe holes.
	for _, known in ipairs(registryCandidates) do
		local stillObserved = observedKnownConnection(known)
		local preserveRegistryEvidence = known.kind == "Pipe"
			and livePipeRecovery
			and livePipeRecovery.RegistryConflict == true
			or known.kind == "Wire"
				and liveWireRecovery
				and liveWireRecovery.RegistryConflict == true
		if not preserveRegistryEvidence and known.confirmed ~= false and stillObserved == false then
			known.confirmed = false
			State.completeConnectionModels[known.fromModel] = nil
			State.completeConnectionModels[known.toModel] = nil
		elseif not preserveRegistryEvidence and known.confirmed ~= false and stillObserved == nil then
			State.completeConnectionModels[known.fromModel] = nil
			State.completeConnectionModels[known.toModel] = nil
		end
		local fromSelection = selectedByModel[known.fromModel]
		local toSelection = selectedByModel[known.toModel]
		if known.confirmed ~= false
			and stillObserved == nil
			and (fromSelection or toSelection)
		then
			-- Old injections could remember the requested endpoint pair without
			-- retaining the server-created decorations. Report that uncertainty,
			-- but never serialize the unprovable (and potentially deleted) edge.
			unknownRegistryConnections += 1
		end
		local registryEdgeIsEligible = known.confirmed ~= false and stillObserved == true
		if registryEdgeIsEligible
			and known.fromModel
			and known.fromModel.Parent
			and known.toModel
			and known.toModel.Parent
		then
			if known.kind == "Pipe"
				and not useLiveDecorationManifest
				and ((fromSelection ~= nil) ~= (toSelection ~= nil))
			then
				boundaryPipeLinks += 1
			elseif known.kind == "Wire"
				and not useLiveWireDecorationManifest
				and ((fromSelection ~= nil) ~= (toSelection ~= nil))
			then
				boundaryWireLinks += 1
			end
			local graphFamilyKey = fromSelection and toSelection and string.format(
				"%s:%d:%s>%d:%s",
				known.kind,
				fromSelection,
				tostring(known.fromConnectorName),
				toSelection,
				tostring(known.toConnectorName)
			) or nil
			local hasPreferredLiveManifest = known.kind == "Pipe"
				and useLivePipeRegistryManifest
				or known.kind == "Wire"
					and (useLiveWireRegistryManifest or useLiveWireDecorationManifest)
			local failedLiveFamilyCanUseExactRegistry = known.kind == "Pipe"
				and livePipeRecoveryAttempted
				and not useLiveDecorationManifest
				or known.kind == "Wire"
					and liveWireRecoveryAttempted
					and not useLiveWireDecorationManifest
			local contributesToRecoveredGraph = hasPreferredLiveManifest
				or failedLiveFamilyCanUseExactRegistry
				or not recoveredMapping
				or (graphFamilyKey
					and (genericPlanByKey[graphFamilyKey] or exactFamilySeen[graphFamilyKey]))
			local registryPlanAllowed = not (
				known.kind == "Pipe" and useLiveDecorationManifest
				or known.kind == "Wire" and useLiveWireDecorationManifest
			)
			if registryPlanAllowed and contributesToRecoveredGraph and addDirectPlan(
				known.kind,
				fromSelection,
				toSelection,
					known.fromConnectorName,
					known.toConnectorName,
					known.fromConnectorPath,
					known.toConnectorPath,
					{
						liveDecorationProven = true,
						sourceDecorations = known.decorations,
					}
				) then
				registryPlanCount += 1
				if known.kind == "Wire" then
					registryWirePlanCount += 1
				end
			end
		end
	end
	local pipeManifestSourceIsAuthoritative
	if useLivePipeRegistryManifest then
		pipeManifestSourceIsAuthoritative = true
	elseif useLiveDecorationManifest then
		pipeManifestSourceIsAuthoritative = livePipeRecovery.Authoritative == true
	else
		pipeManifestSourceIsAuthoritative = recoveredMapping ~= nil
	end
	local wireManifestSourceIsAuthoritative
	if selectedPowerConnectorCount == 0 then
		wireManifestSourceIsAuthoritative = true
	elseif useLiveWireRegistryManifest then
		wireManifestSourceIsAuthoritative = true
	elseif useLiveWireDecorationManifest then
		wireManifestSourceIsAuthoritative = liveWireRecovery.Authoritative == true
	else
		wireManifestSourceIsAuthoritative = false
	end
	duplicate.connectionStats = {
		Pipe = pipePlanCount,
		Wire = wirePlanCount,
		Recovery = recoveryDetail,
		GraphRecovered = recoveredMapping ~= nil,
		LiveDecorationManifest = useLiveDecorationManifest,
		LiveDecorationLinks = liveRecoveryPlanCount,
		LiveDecorationStable = livePipeRecovery and livePipeRecovery.Stable == true or false,
		UnresolvedPipeDecorations = livePipeRecovery
			and (livePipeRecovery.UnresolvedSelectedDecorations or 0)
			or 0,
		UnmatchedPipeSegments = livePipeRecovery
			and (livePipeRecovery.UnmatchedSegments or 0)
			or 0,
		UnclaimedPipeCaps = livePipeRecovery
			and (livePipeRecovery.UnclaimedCaps or 0)
			or 0,
		PipeCapAssignmentFailures = livePipeRecovery
			and (livePipeRecovery.CapAssignmentFailures or 0)
			or 0,
		UnmappedSelectedPipeConnectors = livePipeRecovery
			and (livePipeRecovery.UnmappedSelectedConnectors or 0)
			or 0,
		UnexpectedPipeDecorationClasses = livePipeRecovery
			and (livePipeRecovery.UnexpectedDecorationClasses or 0)
			or 0,
		AmbiguousPipeDecorations = livePipeRecovery
			and (livePipeRecovery.AmbiguousSelectedDecorations or 0)
			or 0,
		SelectedPipeConnectors = livePipeRecovery
			and (livePipeRecovery.SelectedConnectorCount or 0)
			or pipeManifestModelCount,
		SelectedPipeEdges = livePipeRecovery
			and (livePipeRecovery.SelectedEdgeCount or 0)
			or 0,
		LiveWireDecorationManifest = useLiveWireDecorationManifest,
		LiveWireDecorationLinks = liveWireRecoveryPlanCount,
		LiveWireDecorationStable = liveWireRecovery and liveWireRecovery.Stable == true or false,
		UnresolvedWireDecorations = liveWireRecovery
			and (liveWireRecovery.UnresolvedSelectedDecorations or 0)
			or 0,
		UnmatchedWireSegments = liveWireRecovery
			and (liveWireRecovery.UnmatchedSegments or 0)
			or 0,
		UnclaimedWireCaps = liveWireRecovery
			and (liveWireRecovery.UnclaimedCaps or 0)
			or 0,
		WireCapAssignmentFailures = liveWireRecovery
			and (liveWireRecovery.CapAssignmentFailures or 0)
			or 0,
		UnmappedSelectedWireConnectors = liveWireRecovery
			and (liveWireRecovery.UnmappedSelectedConnectors or 0)
			or 0,
		UnexpectedWireDecorationClasses = liveWireRecovery
			and (liveWireRecovery.UnexpectedDecorationClasses or 0)
			or 0,
		AmbiguousWireDecorations = liveWireRecovery
			and (liveWireRecovery.AmbiguousSelectedDecorations or 0)
			or 0,
		SelectedPowerConnectors = liveWireRecovery
			and (liveWireRecovery.SelectedConnectorCount or 0)
			or selectedPowerConnectorCount,
		SelectedWireEdges = liveWireRecovery
			and (liveWireRecovery.SelectedEdgeCount or 0)
			or 0,
		WireAuthoritative = wireManifestSourceIsAuthoritative,
		RegistryWireFallbackAuthoritative = useLiveWireRegistryManifest,
		SelectionManifestComplete = selectionHasCompleteManifest,
		Registry = registryPlanCount,
		RegistryWire = registryWirePlanCount,
		UnknownRegistryConnections = unknownRegistryConnections,
		VisibleConnectionLines = duplicate.previewConnectionLinesUsed,
		BoundaryPipeLinks = boundaryPipeLinks,
		BoundaryWireLinks = boundaryWireLinks,
		RegistryManifestComplete = pipeManifestIsComplete,
		-- Authority describes the selected graph. Exact links whose other endpoint
		-- was not selected are deliberately omitted, just like external wires; they
		-- do not make the internal links uncertain.
		Authoritative = pipeManifestSourceIsAuthoritative,
		SelectedPipePieces = 0,
		LinkedPipePieces = 0,
		UnlinkedPipePieces = 0,
		MissingPipePlugs = 0,
	}
	local pipeEndpointKeys = {}
	local function markPipeEndpoint(selectionIndex, connectorName, connectorPath, pathSignature)
		local endpoints = pipeEndpointKeys[selectionIndex]
		if not endpoints then
			endpoints = {}
			pipeEndpointKeys[selectionIndex] = endpoints
		end
		local endpointKey = pathSignature or connectorPathSignature(connectorPath)
			or ("name:" .. tostring(connectorName))
		endpoints[endpointKey] = true
	end
	for _, plan in ipairs(duplicate.connections) do
		if plan.kind == "Pipe" then
			markPipeEndpoint(
				plan.fromSelection,
				plan.fromConnectorName,
				plan.fromConnectorPath,
				plan.fromConnectorPathSignature
			)
			markPipeEndpoint(
				plan.toSelection,
				plan.toConnectorName,
				plan.toConnectorPath,
				plan.toConnectorPathSignature
			)
		end
	end
	for selectionIndex, item in ipairs(duplicate.selected) do
		local isPhysical = physicalSelections[selectionIndex] == true
			and Runtime.duplicatePlumbingRequiredDegree(item, true) ~= nil
		local requiredDegree = isPhysical and 1 or nil
		item.isPhysicalPlumbing = isPhysical
		if requiredDegree then
			duplicate.connectionStats.SelectedPipePieces += 1
			local endpointCount = 0
			for _ in pairs(pipeEndpointKeys[selectionIndex] or {}) do
				endpointCount += 1
			end
			if endpointCount >= requiredDegree then
				duplicate.connectionStats.LinkedPipePieces += 1
			else
				duplicate.connectionStats.UnlinkedPipePieces += 1
				duplicate.connectionStats.MissingPipePlugs += requiredDegree - endpointCount
			end
		end
	end
		return duplicate.connections
	end)
	duplicate.connectionAuditInProgress = false
	if not auditOK then
		error(auditResult, 0)
	end
	return auditResult
end

function Runtime.duplicateConnectionPlanManifest(plans)
	local function connectorPathKey(path)
		local parts = {}
		for _, segment in ipairs(type(path) == "table" and path or {}) do
			table.insert(parts, string.format(
				"%s\30%s\30%d",
				tostring(segment.Name),
				tostring(segment.ClassName),
				math.max(1, math.floor(tonumber(segment.Ordinal) or 1))
			))
		end
		return #parts > 0 and table.concat(parts, "\29") or "<name-only>"
	end
	local keys = {}
	for _, plan in ipairs(type(plans) == "table" and plans or {}) do
		table.insert(keys, table.concat({
			tostring(plan.kind),
			tostring(plan.fromSelection),
			tostring(plan.fromConnectorName),
			connectorPathKey(plan.fromConnectorPath),
			tostring(plan.toSelection),
			tostring(plan.toConnectorName),
			connectorPathKey(plan.toConnectorPath),
			plan.liveDecorationProven == true and "live-proven" or "authored",
		}, "\28"))
	end
	table.sort(keys)
	return table.concat(keys, "\27")
end

function Runtime.refreshDuplicateConnectionPlans(folder)
	local duplicate = State.duplicate
	local selectionVersion = duplicate.selectionVersion
	local selectionCount = #duplicate.selected
	for index, item in ipairs(duplicate.selected) do
		if not duplicateSourceItemSnapshotIsCurrent(item) then
			return false, string.format(
				"Selected source #%d %s disappeared or changed before the connection graph audit.",
				index,
				tostring(item.name)
			)
		end
	end

	local priorConnections = duplicate.connections
	local priorConnectionStats = duplicate.connectionStats
	local priorLinesUsed = duplicate.previewConnectionLinesUsed
	local connectionProgress = false
	for _, plan in ipairs(priorConnections) do
		if plan.built then
			connectionProgress = true
			break
		end
	end
	local refreshFolder = folder
	if connectionProgress then
		refreshFolder = nil
	end
	local planOK, planError = pcall(
		Runtime.createDuplicateConnectionPlans,
		refreshFolder
	)
	local refreshedConnections = duplicate.connections
	local refreshedStats = duplicate.connectionStats
	local function destroyPlanLines(plans)
		for _, plan in ipairs(type(plans) == "table" and plans or {}) do
			if plan.line and plan.line.Parent then
				plan.line:Destroy()
			end
		end
	end
	if not planOK then
		destroyPlanLines(refreshedConnections)
		duplicate.connections = priorConnections
		duplicate.connectionStats = priorConnectionStats
		duplicate.previewConnectionLinesUsed = priorLinesUsed
		return false, "Could not refresh source connections: " .. tostring(planError)
	end
	if selectionVersion ~= duplicate.selectionVersion or selectionCount ~= #duplicate.selected then
		destroyPlanLines(refreshedConnections)
		duplicate.connections = priorConnections
		duplicate.connectionStats = priorConnectionStats
		duplicate.previewConnectionLinesUsed = priorLinesUsed
		return false, "Selection changed while the connection graph was being audited."
	end
	for index, item in ipairs(duplicate.selected) do
		if not duplicateSourceItemSnapshotIsCurrent(item) then
			destroyPlanLines(refreshedConnections)
			duplicate.connections = priorConnections
			duplicate.connectionStats = priorConnectionStats
			duplicate.previewConnectionLinesUsed = priorLinesUsed
			return false, string.format(
				"Selected source #%d %s changed while the connection graph was being audited.",
				index,
				tostring(item.name)
			)
		end
	end
	local plumbingError = Runtime.duplicatePlumbingBlockReason(refreshedStats, selectionCount)
	if plumbingError then
		if connectionProgress then
			destroyPlanLines(refreshedConnections)
			duplicate.connections = priorConnections
			duplicate.connectionStats = priorConnectionStats
			duplicate.previewConnectionLinesUsed = priorLinesUsed
		end
		return false, plumbingError
	end
	if connectionProgress then
		local priorManifest = Runtime.duplicateConnectionPlanManifest(priorConnections)
		local refreshedManifest = Runtime.duplicateConnectionPlanManifest(refreshedConnections)
		destroyPlanLines(refreshedConnections)
		duplicate.connections = priorConnections
		duplicate.connectionStats = refreshedStats
		duplicate.previewConnectionLinesUsed = priorLinesUsed
		if type(duplicate.connectionStats) == "table" then
			duplicate.connectionStats.VisibleConnectionLines = priorLinesUsed
		end
		if priorManifest ~= refreshedManifest then
			duplicate.connectionStats = priorConnectionStats
			return false,
				"The source pipe/wire graph changed after destination connection progress was committed. Existing Resume history was preserved; select and duplicate the updated graph in a new session."
		end
		return true, "Committed connection manifest is unchanged."
	end

	-- No destination connection has committed yet, so replacing the pending plan
	-- with the newest two-frame live graph is safe and prevents copying stale links.
	destroyPlanLines(priorConnections)
	return true, "Pending connection manifest refreshed from the live source graph."
end

function Runtime.snapshotDuplicateConnectionDecorationWorld(plans)
	local snapshot = { decorations = {} }
	for _, plan in ipairs(type(plans) == "table" and plans or {}) do
		for _, decoration in ipairs(type(plan.sourceDecorations) == "table"
			and plan.sourceDecorations or {})
		do
			if typeof(decoration) == "Instance"
				and decoration:IsA("Part")
				and not decoration:IsA("UnionOperation")
				and decoration.Parent
				and decoration:IsDescendantOf(ConnectionDecorations)
			then
				snapshot.decorations[decoration] = {
					className = decoration.ClassName,
					name = decoration.Name,
					cframe = decoration.CFrame,
					size = decoration.Size,
				}
			end
		end
	end
	return snapshot
end

function Runtime.auditDuplicateConnectionDecorationWorld(snapshot)
	if type(snapshot) ~= "table" then
		return false, "the connection-decoration audit baseline is missing"
	elseif not ConnectionDecorations.Parent or not ConnectionDecorations:IsDescendantOf(Plots) then
		return false, "the server connection-decoration folder disappeared"
	end
	local decorations = type(snapshot.decorations) == "table" and snapshot.decorations or {}
	for decoration, expected in pairs(decorations) do
		if not decoration.Parent
			or not decoration:IsDescendantOf(ConnectionDecorations)
			or decoration.ClassName ~= expected.className
			or decoration.Name ~= expected.name
			or decoration.CFrame ~= expected.cframe
			or decoration.Size ~= expected.size
		then
			return false, "a Pipe/Power decoration changed or disappeared during replay"
		end
	end
	return true
end

function Runtime.admitVerifiedDuplicateConnectionDecorations(snapshot, plan)
	for _, decoration in ipairs(type(plan.verifiedDecorations) == "table"
		and plan.verifiedDecorations or {})
	do
		if typeof(decoration) == "Instance"
			and decoration:IsA("Part")
			and not decoration:IsA("UnionOperation")
			and decoration.Parent
			and decoration:IsDescendantOf(ConnectionDecorations)
			and (decoration.Name == "Pipe" or decoration.Name == "Power")
		then
			snapshot.decorations[decoration] = {
				className = decoration.ClassName,
				name = decoration.Name,
				cframe = decoration.CFrame,
				size = decoration.Size,
			}
		end
	end
end

function Runtime.duplicatePlumbingBlockReason(connectionStats, selectionCount)
	local stats = type(connectionStats) == "table" and connectionStats or {}
	if (tonumber(selectionCount) or 0) <= 0 then
		return nil
	end
	local ambiguous = tonumber(stats.AmbiguousPipeDecorations) or 0
	if ambiguous > 0 then
		return string.format(
			"%d pipe decoration(s) match multiple exact connector holes. Nothing was guessed or exported.",
			ambiguous
		)
	end
	local unresolved = tonumber(stats.UnresolvedPipeDecorations) or 0
	if unresolved > 0 then
		local unmapped = tonumber(stats.UnmappedSelectedPipeConnectors) or 0
		local unmatchedSegments = tonumber(stats.UnmatchedPipeSegments) or 0
		local unclaimedCaps = tonumber(stats.UnclaimedPipeCaps) or 0
		local capAssignmentFailures = tonumber(stats.PipeCapAssignmentFailures) or 0
		local unexpectedClasses = tonumber(stats.UnexpectedPipeDecorationClasses) or 0
		if stats.LiveDecorationStable ~= true then
			return "The live pipe decorations changed while they were being read. Retry after the plot finishes replicating."
		elseif unmapped > 0 then
			return string.format(
				"%d selected pipe connector path(s) do not map uniquely to the canonical building template; export stayed fail-closed.",
				unmapped
			)
		elseif unmatchedSegments > 0 or unclaimedCaps > 0 then
			return string.format(
				"%d live pipe link(s) could not be reconstructed exactly (%d unmatched segment(s), %d unclaimed cap(s)).",
				math.max(unmatchedSegments, unclaimedCaps),
				unmatchedSegments,
				unclaimedCaps
			)
		elseif capAssignmentFailures > 0 then
			return string.format(
				"%d live pipe pair(s) could not be assigned distinct server caps; export stayed fail-closed.",
				capAssignmentFailures
			)
		elseif unexpectedClasses > 0 then
			return string.format(
				"%d nearby Pipe decoration(s) use an unsupported server class; export stayed fail-closed.",
				unexpectedClasses
			)
		end
		return string.format(
			"%d selected pipe evidence item(s) could not be proven exactly; export stayed fail-closed.",
			unresolved
		)
	end
	local hasPipeScope = (tonumber(stats.SelectedPipePieces) or 0) > 0
		or (tonumber(stats.SelectedPipeConnectors) or 0) > 0
		or (tonumber(stats.SelectedPipeEdges) or 0) > 0
		or (tonumber(stats.Pipe) or 0) > 0
	if hasPipeScope and stats.Authoritative ~= true then
		return "The exact live plumbing graph could not be proven. No connector was guessed; retry after the plot finishes loading."
	end
	local exactWireRegistryFallback = stats.RegistryWireFallbackAuthoritative == true
	local ambiguousWire = tonumber(stats.AmbiguousWireDecorations) or 0
	if ambiguousWire > 0 and not exactWireRegistryFallback then
		return string.format(
			"%d power-line segment(s) match multiple exact connector pairs. Nothing was guessed or exported.",
			ambiguousWire
		)
	end
	local unresolvedWire = tonumber(stats.UnresolvedWireDecorations) or 0
	if unresolvedWire > 0 and not exactWireRegistryFallback then
		local unmapped = tonumber(stats.UnmappedSelectedWireConnectors) or 0
		local unmatchedSegments = tonumber(stats.UnmatchedWireSegments) or 0
		local unclaimedCaps = tonumber(stats.UnclaimedWireCaps) or 0
		local capAssignmentFailures = tonumber(stats.WireCapAssignmentFailures) or 0
		local unexpectedClasses = tonumber(stats.UnexpectedWireDecorationClasses) or 0
		if stats.LiveWireDecorationStable ~= true then
			return "The live power-line decorations changed while they were being read. Retry after the plot finishes replicating."
		elseif unmapped > 0 then
			return string.format(
				"%d selected power connector path(s) do not map uniquely to the canonical building template; export stayed fail-closed.",
				unmapped
			)
		elseif unmatchedSegments > 0 or unclaimedCaps > 0 then
			return string.format(
				"%d live power-line link(s) could not be reconstructed exactly (%d unmatched segment(s), %d unclaimed cap(s)).",
				math.max(unmatchedSegments, unclaimedCaps),
				unmatchedSegments,
				unclaimedCaps
			)
		elseif capAssignmentFailures > 0 then
			return string.format(
				"%d live power-line pair(s) could not be assigned distinct server caps; export stayed fail-closed.",
				capAssignmentFailures
			)
		elseif unexpectedClasses > 0 then
			return string.format(
				"%d nearby Power decoration(s) use an unsupported server class; export stayed fail-closed.",
				unexpectedClasses
			)
		end
		return string.format(
			"%d selected power-line evidence item(s) could not be proven exactly; export stayed fail-closed.",
			unresolvedWire
		)
	end
	local hasWireScope = (tonumber(stats.SelectedPowerConnectors) or 0) > 0
		or (tonumber(stats.SelectedWireEdges) or 0) > 0
		or (tonumber(stats.Wire) or 0) > 0
	if hasWireScope and stats.WireAuthoritative ~= true then
		return "The exact live electrical graph could not be proven. No power connector was guessed; retry after the plot finishes loading."
	end
	return nil
end

function Runtime.duplicateExportEndpoint(reference, connectorName, connectorPath)
	local endpoint = {
		Machine = reference.Machine,
		Piece = reference.Piece,
		Connector = connectorName,
	}
	endpoint.ConnectorPath = Runtime.copyConnectorPath(connectorPath)
	return endpoint
end

function Runtime.duplicateExportConnector(item, connectorName, connectorPath, label)
	if not item or not item.model or not item.model.Parent then
		return nil, nil, label .. " source object disappeared"
	end
	local connector
	local connectorError
	local path = Runtime.copyConnectorPath(connectorPath)
	if path then
		connector, connectorError = Runtime.resolveStoredConnectorPath(item.model, path)
	else
		connector, connectorError = findNamedConnector(item.model, connectorName)
		if connector then
			path, connectorError = Runtime.connectorPathInModel(item.model, connector)
		end
	end
	if not connector or not path then
		return nil, nil, label .. " cannot resolve an exact connector path: " .. tostring(connectorError)
	end
	local canonicalConnector, canonicalError = Runtime.resolveStoredConnectorPath(item.template, path)
	if not canonicalConnector then
		return nil, nil, label .. " path does not exist in the canonical template: " .. tostring(canonicalError)
	elseif canonicalConnector.Name ~= connector.Name then
		return nil, nil, label .. " resolves to different connector names in source and template"
	end
	return connector.Name, path, connector
end

function Runtime.validateDuplicateExportConnection(
	kind,
	fromConnector,
	toConnector,
	liveDecorationProven
)
	local reasons = {}
	if fromConnector == toConnector then
		table.insert(reasons, "From and To resolve to the same connector")
	end
	local fromMetadata, fromMetadataError = connectorFolder(fromConnector, kind)
	local toMetadata, toMetadataError = connectorFolder(toConnector, kind)
	if not fromMetadata then
		table.insert(reasons, "From: " .. tostring(fromMetadataError))
	elseif booleanValue(fromMetadata, "Input") then
		table.insert(reasons, "From connector is marked Input")
	end
	if not toMetadata then
		table.insert(reasons, "To: " .. tostring(toMetadataError))
	elseif booleanValue(toMetadata, "Output") then
		table.insert(reasons, "To connector is marked Output")
	end
	if kind == "Pipe" and fromMetadata and toMetadata then
		local fromKind, fromKindError = pipeLiquidKind(fromMetadata)
		local toKind, toKindError = pipeLiquidKind(toMetadata)
		if not fromKind then
			table.insert(reasons, "From: " .. tostring(fromKindError))
		end
		if not toKind then
			table.insert(reasons, "To: " .. tostring(toKindError))
		end
		if fromKind and toKind and fromKind ~= toKind then
			table.insert(reasons, string.format("cannot bind %s pipe to %s pipe", fromKind, toKind))
		end
	end
	-- Connector names are a conservative authored-blueprint heuristic, not a
	-- server rule. Only an exact live segment/cap pair may bypass it; direction,
	-- liquid compatibility, and range remain mandatory below.
	if liveDecorationProven ~= true
		and not connectorNamesCompatible(kind, fromConnector.Name, toConnector.Name)
	then
		table.insert(reasons, string.format(
			"incompatible connector names %s -> %s",
			fromConnector.Name,
			toConnector.Name
		))
	end
	local distance = connectionDistance(kind, fromConnector, toConnector)
	if kind == "Pipe" then
		if distance > Config.VerifiedPipeBindRange + Config.EdgeEpsilon then
			table.insert(reasons, string.format(
				"pipe bind is %.2f studs; observed server range is %.2f",
				distance,
				Config.VerifiedPipeBindRange
			))
		end
	else
		local maximum = maximumConnectionDistance("Wire", fromConnector)
		if distance > maximum + Config.EdgeEpsilon then
			table.insert(reasons, string.format("wire distance %.2f exceeds %.2f stud range", distance, maximum))
		end
	end
	if #reasons > 0 then
		return false, table.concat(reasons, "; ")
	end
	return true
end

function Runtime.buildDuplicateExportDocument()
	if State.destroyed then
		return nil, "The script has been destroyed; execute it again to restart."
	elseif State.building then
		return nil, "Wait for the active build to finish before exporting."
	end
	local duplicate = State.duplicate
	local _, pruneError = Runtime.pruneStaleDuplicateSelection(true)
	if pruneError then
		return nil, pruneError
	end
	if #duplicate.selected == 0 then
		return nil, "Select at least one source object first."
	end
	local selectionVersion = duplicate.selectionVersion
	local selectionCount = #duplicate.selected
	for index, item in ipairs(duplicate.selected) do
		if not item.model or not item.model.Parent or not item.base or not item.base.Parent then
			return nil, string.format("Selected object #%d disappeared; select the group again.", index)
		end
	end

	-- Plan exact internal edges without creating preview Parts or requiring a
	-- destination. Preserve any already-visible Duplicate preview afterwards.
	local priorConnections = duplicate.connections
	local priorConnectionStats = duplicate.connectionStats
	local priorLinesUsed = duplicate.previewConnectionLinesUsed
	local planOK, plansOrError = pcall(Runtime.createDuplicateConnectionPlans, nil)
	local exportPlans = duplicate.connections
	local exportStats = duplicate.connectionStats or {}
	duplicate.connections = priorConnections
	duplicate.connectionStats = priorConnectionStats
	duplicate.previewConnectionLinesUsed = priorLinesUsed
	if not planOK then
		return nil, "Could not inspect selected connections: " .. tostring(plansOrError)
	end
	if selectionVersion ~= duplicate.selectionVersion or selectionCount ~= #duplicate.selected then
		return nil, "Selection changed during export; try again."
	end
	local plumbingBlockReason = Runtime.duplicatePlumbingBlockReason(exportStats, selectionCount)
	if plumbingBlockReason then
		return nil, plumbingBlockReason
	end

	local anchor = duplicate.selected[1]
	-- Use one nearby even/even frame for the entire selection. This keeps Scan
	-- and Base X/Z replay compatible while preserving every pairwise delta and
	-- each model's real parity. Never snap an individual exported placement.
	local exportOriginX = roundToLattice(anchor.sourceX, Config.OriginGrid, Config.OriginGridPhase)
	local exportOriginZ = roundToLattice(anchor.sourceZ, Config.OriginGrid, Config.OriginGridPhase)
	local inverseAnchorRotation = (360 - anchor.sourceRotation) % 360
	local document = {
		Format = SAVE_FORMAT,
		Version = SAVE_VERSION,
		Name = "duplicate_export",
		Title = "Industrialist duplicate selection",
		SavedAtUnix = os.time(),
		PlaceId = game.PlaceId,
		GridMode = "CanonicalEvenOriginWholeStud",
		Blueprint = {},
		AuthoredPlumbing = {},
		AuthoredPipeLinks = {},
		Wiring = {},
		AutoPlumb = false,
		PipeQuality = State.autoPlumbQuality,
	}
	local referenceBySelection = {}
	local selectedPowerModels = 0
	for selectionIndex, item in ipairs(duplicate.selected) do
		if Runtime.templatePowerConnectorCount(item.template) > 0 then
			selectedPowerModels += 1
		end
		local deltaX = item.sourceX - exportOriginX
		local deltaZ = item.sourceZ - exportOriginZ
		local localX, localZ = rotateBlueprintOffset(deltaX, deltaZ, inverseAnchorRotation)
		if math.abs(localX) < 0.0005 then
			localX = 0
		end
		if math.abs(localZ) < 0.0005 then
			localZ = 0
		end
		local entry = {
			Category = item.category,
			Name = item.name,
			X = math.round(localX),
			Z = math.round(localZ),
			Rotation = ((item.sourceRotation - anchor.sourceRotation) % 360 + 360) % 360,
		}
		local currentReference = Runtime.duplicateSourceReference(item.model) or item.sourceReference
		local sourceReferenceKey = Runtime.duplicateReferenceKey(currentReference)
		local physicalPipe = item.isPhysicalPlumbing == true
			or Runtime.isDuplicatePhysicalPlumbing(item)
			or (sourceReferenceKey
				and string.sub(sourceReferenceKey, 1, 2) == "P:"
				and Runtime.templatePowerConnectorCount(item.template) == 0)
		if physicalPipe then
			table.insert(document.AuthoredPlumbing, entry)
			referenceBySelection[selectionIndex] = { Piece = #document.AuthoredPlumbing }
		else
			table.insert(document.Blueprint, entry)
			referenceBySelection[selectionIndex] = { Machine = #document.Blueprint }
		end
	end

	for _, plan in ipairs(exportPlans) do
		if selectionVersion ~= duplicate.selectionVersion then
			return nil, "Selection changed during export; try again."
		end
		local fromItem = duplicate.selected[plan.fromSelection]
		local toItem = duplicate.selected[plan.toSelection]
		local fromReference = referenceBySelection[plan.fromSelection]
		local toReference = referenceBySelection[plan.toSelection]
		if not fromItem or not toItem or not fromReference or not toReference then
			return nil, "An internal connection references an object outside the selected group."
		elseif plan.kind == "Wire" and (fromReference.Piece or toReference.Piece) then
			return nil, "A selected wire terminates on an object classified as a physical plumbing piece; this cannot be represented safely."
		end
		local fromName, fromPath, fromConnectorOrError = Runtime.duplicateExportConnector(
			fromItem,
			plan.fromConnectorName,
			plan.fromConnectorPath,
			string.format("%s #%d From", plan.kind, plan.index)
		)
		if not fromName then
			return nil, fromConnectorOrError
		end
		local toName, toPath, toConnectorOrError = Runtime.duplicateExportConnector(
			toItem,
			plan.toConnectorName,
			plan.toConnectorPath,
			string.format("%s #%d To", plan.kind, plan.index)
		)
		if not toName then
			return nil, toConnectorOrError
		end
		local semanticallyValid, semanticError = Runtime.validateDuplicateExportConnection(
			plan.kind,
			fromConnectorOrError,
			toConnectorOrError,
			plan.liveDecorationProven == true
		)
		if not semanticallyValid then
			return nil, string.format("%s #%d is invalid: %s", plan.kind, plan.index, semanticError)
		end
		local exportedConnection = {
			From = Runtime.duplicateExportEndpoint(fromReference, fromName, fromPath),
			To = Runtime.duplicateExportEndpoint(toReference, toName, toPath),
		}
		if plan.kind == "Pipe" then
			table.insert(document.AuthoredPipeLinks, exportedConnection)
		else
			table.insert(document.Wiring, exportedConnection)
		end
	end

	local warnings = {}
	-- A rigid pose match proves which pasted entry a model resembles; it does
	-- not prove that the live server wiring still equals that pasted document.
	-- Only the decoration-verified live manifest can make electricity complete.
	local electricalManifestAuthoritative = exportStats.WireAuthoritative == true
	if selectedPowerModels > 0 and not electricalManifestAuthoritative then
		table.insert(warnings, string.format(
			"Electrical graph is not authoritative for %d powered selected object(s); no unverified wire was exported.",
			selectedPowerModels
		))
	end
	if (exportStats.BoundaryWireLinks or 0) > 0 then
		table.insert(warnings, string.format(
			"%d wire(s) leave the selected group and were intentionally not exported.",
			exportStats.BoundaryWireLinks
		))
	end
	if (exportStats.BoundaryPipeLinks or 0) > 0 then
		table.insert(warnings, string.format(
			"%d pipe link(s) leave the selected group and were intentionally not exported.",
			exportStats.BoundaryPipeLinks
		))
	end
	if (exportStats.UnknownRegistryConnections or 0) > 0 then
		table.insert(warnings, string.format(
			"%d legacy captured connection(s) lacked live server-decoration proof and were omitted instead of guessing.",
			exportStats.UnknownRegistryConnections
		))
	end
	if exportStats.Authoritative == true and (exportStats.UnlinkedPipePieces or 0) > 0 then
		table.insert(warnings, string.format(
			"%d selected physical pipe piece(s) are currently disconnected and were exported that way.",
			exportStats.UnlinkedPipePieces
		))
	end
	document.ExportMetadata = {
		Kind = "DuplicateSelection",
		GeneratedBy = "Industrialist Blueprint Placer",
		CoordinateSystem = "whole-stud X/Z in one nearby even/even selection frame with the first selection rotation normalized to 0 degrees",
		SelectionVersion = selectionVersion,
		AnchorRotationRemoved = anchor.sourceRotation,
		Counts = {
			Machines = #document.Blueprint,
			Pieces = #document.AuthoredPlumbing,
			PipeLinks = #document.AuthoredPipeLinks,
			Wires = #document.Wiring,
		},
		ConnectionRecovery = tostring(exportStats.Recovery or "none"),
		ManifestAuthoritative = exportStats.Authoritative == true,
		ElectricalManifestAuthoritative = electricalManifestAuthoritative,
		SelectedPowerModels = selectedPowerModels,
		Warnings = warnings,
	}

	-- Validate the portable arrays without mutating the currently pasted build.
	local checkedMachines, machineError = normalizePlacementList(document.Blueprint, "Export machine", "Machine")
	if not checkedMachines then
		return nil, machineError
	end
	local checkedPieces, pieceError = normalizePlacementList(document.AuthoredPlumbing, "Export plumbing", "Plumbing")
	if not checkedPieces then
		return nil, pieceError
	end
	local checkedPipes, pipeError = normalizeConnectionList(
		document.AuthoredPipeLinks,
		"Export pipe link",
		#checkedMachines,
		#checkedPieces,
		true
	)
	if not checkedPipes then
		return nil, pipeError
	end
	local checkedWires, wireError = normalizeConnectionList(
		document.Wiring,
		"Export wire",
		#checkedMachines,
		#checkedPieces,
		false
	)
	if not checkedWires then
		return nil, wireError
	end
	return document
end

function Runtime.ensureExportFolder()
	local rootReady, rootError = ensureSaveFolders()
	if not rootReady then
		return false, rootError
	end
	local makeFolder = executorFileFunction("makefolder")
	local isFolder = executorFileFunction("isfolder")
	if isFolder then
		local checkOK, exists = pcall(isFolder, Runtime.ExportFolder)
		if checkOK and exists == true then
			return true, Runtime.ExportFolder
		end
	end
	if not makeFolder then
		return false, "makefolder is unavailable for " .. Runtime.ExportFolder
	end
	local createOK, createError = pcall(makeFolder, Runtime.ExportFolder)
	if not createOK and isFolder then
		local checkOK, exists = pcall(isFolder, Runtime.ExportFolder)
		if not checkOK or exists ~= true then
			return false, "Could not create " .. Runtime.ExportFolder .. ": " .. tostring(createError)
		end
	end
	return true, Runtime.ExportFolder
end

function Runtime.copyExportToClipboard(json)
	for _, name in ipairs({ "setclipboard", "toclipboard", "set_clipboard" }) do
		local clipboard = executorFileFunction(name)
		if clipboard then
			local copied, result = pcall(clipboard, json)
			if copied and result ~= false then
				return true, name
			end
			warn(PREFIX .. name .. " failed: " .. tostring(result))
		end
	end
	return false, "clipboard function unavailable"
end

function Runtime.exportDuplicateJSON()
	local document, documentError = Runtime.buildDuplicateExportDocument()
	if not document then
		return false, documentError
	end
	local encodeOK, json = pcall(function()
		return HttpService:JSONEncode(document)
	end)
	if not encodeOK then
		return false, "Could not encode duplicate export: " .. tostring(json)
	elseif #json > Config.MaxBlueprintTextBytes then
		return false, "Duplicate export is larger than 500 KB; select a smaller group."
	end
	local clipboardOK = Runtime.copyExportToClipboard(json)
	local savedPath
	local folderOK = Runtime.ensureExportFolder()
	local writeFile = executorFileFunction("writefile")
	local readFile = executorFileFunction("readfile")
	if folderOK and writeFile and readFile then
		State.duplicate.exportSerial = (tonumber(State.duplicate.exportSerial) or 0) + 1
		local path = string.format(
			"%s/duplicate_%d_%03d.json",
			Runtime.ExportFolder,
			os.time(),
			State.duplicate.exportSerial
		)
		local writeOK = pcall(writeFile, path, json)
		local readOK, readText = pcall(readFile, path)
		if writeOK and readOK and readText == json then
			savedPath = path
		end
	end
	State.duplicate.lastExportJSON = json
	State.duplicate.lastExportPath = savedPath
	local counts = document.ExportMetadata.Counts
	local summary = string.format(
		"%d machine(s), %d physical piece(s), %d pipe link(s), %d wire(s)",
		counts.Machines,
		counts.Pieces,
		counts.PipeLinks,
		counts.Wires
	)
	if #document.ExportMetadata.Warnings > 0 then
		summary ..= string.format(" • %d warning(s)", #document.ExportMetadata.Warnings)
	end
	local delivery
	if clipboardOK and savedPath then
		delivery = "Copied to clipboard and saved to " .. savedPath .. "."
	elseif clipboardOK then
		delivery = "Copied to clipboard."
	elseif savedPath then
		delivery = "Saved to " .. savedPath .. "."
	else
		delivery = "Clipboard/files are unavailable; JSON is in IndustrialistBlueprintPlacer.State.duplicate.lastExportJSON."
	end
	local warningDetail = #document.ExportMetadata.Warnings > 0
		and (" Warning: " .. table.concat(document.ExportMetadata.Warnings, " "))
		or ""
	setParagraph(State.duplicate.exportStatusParagraph, "AI export", summary .. ". " .. delivery .. warningDetail)
	if clipboardOK or savedPath then
		if clipboardOK then
			notify("Copied to clipboard", "Blueprint JSON is ready to paste.", 6)
		else
			notify("Export JSON saved", tostring(savedPath), 7)
		end
		return true, json, savedPath
	end
	return false, delivery
end

function Runtime.duplicateConnectionEndpoints(plan, usePlacedModel)
	local fromPreview = State.duplicate.previews[plan.fromSelection]
	local toPreview = State.duplicate.previews[plan.toSelection]
	if not fromPreview or not toPreview then
		return nil, nil, "duplicate endpoint preview is missing"
	end
	local fromModel = usePlacedModel
		and fromPreview.placedModel
		or (fromPreview.model or fromPreview.placedModel)
	local toModel = usePlacedModel
		and toPreview.placedModel
		or (toPreview.model or toPreview.placedModel)
	if not fromModel or not fromModel.Parent then
		return nil, nil, "duplicate From model is unavailable"
	elseif not toModel or not toModel.Parent then
		return nil, nil, "duplicate To model is unavailable"
	end
	local fromConnector, fromError
	if plan.fromConnectorPath then
		fromConnector, fromError = Runtime.resolveConnectorPath(fromModel, plan.fromConnectorPath)
	else
		fromConnector, fromError = findNamedConnector(fromModel, plan.fromConnectorName)
	end
	local toConnector, toError
	if plan.toConnectorPath then
		toConnector, toError = Runtime.resolveConnectorPath(toModel, plan.toConnectorPath)
	else
		toConnector, toError = findNamedConnector(toModel, plan.toConnectorName)
	end
	if not fromConnector then
		return nil, toConnector, "From: " .. tostring(fromError)
	elseif not toConnector then
		return fromConnector, nil, "To: " .. tostring(toError)
	end
	return fromConnector, toConnector
end

function Runtime.inspectDuplicateConnection(plan, usePlacedModel)
	local reasons = {}
	if plan.selectionVersion ~= State.duplicate.selectionVersion then
		table.insert(reasons, "selection changed; regenerate duplicate preview")
	end
	local fromConnector, toConnector, endpointError = Runtime.duplicateConnectionEndpoints(plan, usePlacedModel)
	if endpointError then
		table.insert(reasons, endpointError)
	end
	if not fromConnector or not toConnector then
		return false, fromConnector, toConnector, reasons
	elseif fromConnector == toConnector then
		table.insert(reasons, "From and To resolve to the same connector")
	end
	local fromMetadata, fromMetadataError = connectorFolder(fromConnector, plan.kind)
	local toMetadata, toMetadataError = connectorFolder(toConnector, plan.kind)
	if not fromMetadata then
		table.insert(reasons, "From: " .. fromMetadataError)
	elseif booleanValue(fromMetadata, "Input") then
		table.insert(reasons, "From connector is marked Input")
	end
	if not toMetadata then
		table.insert(reasons, "To: " .. toMetadataError)
	elseif booleanValue(toMetadata, "Output") then
		table.insert(reasons, "To connector is marked Output")
	end
	if plan.kind == "Pipe" and fromMetadata and toMetadata then
		local fromKind, fromKindError = pipeLiquidKind(fromMetadata)
		local toKind, toKindError = pipeLiquidKind(toMetadata)
		if not fromKind then
			table.insert(reasons, "From: " .. fromKindError)
		end
		if not toKind then
			table.insert(reasons, "To: " .. toKindError)
		end
		if fromKind and toKind and fromKind ~= toKind then
			table.insert(reasons, string.format("cannot bind %s pipe to %s pipe", fromKind, toKind))
		end
	end
	if plan.liveDecorationProven ~= true
		and not connectorNamesCompatible(plan.kind, fromConnector.Name, toConnector.Name)
	then
		table.insert(reasons, string.format(
			"incompatible connector names %s -> %s",
			fromConnector.Name,
			toConnector.Name
		))
	end
	local distance = connectionDistance(plan.kind, fromConnector, toConnector)
	if plan.kind == "Pipe" then
		if distance > Config.VerifiedPipeBindRange + Config.EdgeEpsilon then
			table.insert(reasons, string.format(
				"pipe bind is %.2f studs; observed server range is %.2f",
				distance,
				Config.VerifiedPipeBindRange
			))
		end
	else
		local maximum = maximumConnectionDistance("Wire", fromConnector)
		if distance > maximum + Config.EdgeEpsilon then
			table.insert(reasons, string.format("wire distance %.2f exceeds %.2f stud range", distance, maximum))
		end
	end
	return #reasons == 0, fromConnector, toConnector, reasons
end

function Runtime.activeDuplicateConnections()
	local active = {}
	for _, plan in ipairs(State.duplicate.connections) do
		if not plan.built then
			table.insert(active, plan)
		end
	end
	return active
end

function Runtime.validateDuplicateConnections(usePlacedModel)
	local allValid = true
	for _, plan in ipairs(State.duplicate.connections) do
		if plan.built and Runtime.committedConnectionError then
			local committedError = Runtime.committedConnectionError(
				plan,
				Runtime.inspectDuplicateConnection
			)
			if committedError then
				plan.reasons = { committedError }
				plan.valid = false
				allValid = false
				warn(PREFIX .. string.format(
					"built duplicate %s #%d changed after verification: %s",
					plan.kind,
					plan.index,
					committedError
				))
			end
		end
	end
	for _, plan in ipairs(Runtime.activeDuplicateConnections()) do
		local valid, fromConnector, toConnector, reasons = Runtime.inspectDuplicateConnection(
			plan,
			usePlacedModel == true
		)
		plan.reasons = reasons
		plan.valid = valid and #reasons == 0
		updateConnectionLine(plan, fromConnector, toConnector)
		if not plan.valid then
			allValid = false
			warn(PREFIX .. string.format(
				"duplicate %s #%d invalid: %s",
				plan.kind,
				plan.index,
				table.concat(reasons, "; ")
			))
		end
	end
	return allValid
end

function Runtime.buildDuplicateConnection(plan)
	local valid, fromConnector, toConnector, reasons = Runtime.inspectDuplicateConnection(plan, true)
	if not valid then
		return false, "last-second validation failed: " .. table.concat(reasons, "; ")
	end
	local reserved, reservation, reservationInserted = Runtime.rememberKnownConnection(
		plan.kind,
		fromConnector,
		toConnector,
		true
	)
	if not reserved then
		return false, "could not reserve the exact next-copy replay path: " .. tostring(reservation)
	end
	if not reservationInserted
		and Runtime.reuseKnownConnectionIfExact(plan, reservation, fromConnector, toConnector)
	then
		return true
	end
	local label = string.format("Duplicate %s #%d", plan.kind, plan.index)
	local decorations, verifyError, outcome = Runtime.invokeAndVerifyConnection(
		plan,
		fromConnector,
		toConnector,
		label,
		"server rejected the connection"
	)
	if not decorations then
		if reservationInserted then
			Runtime.forgetKnownConnection(reservation)
		end
		return false, tostring(verifyError)
	end
	if outcome and outcome.remoteErrored then
		print(PREFIX .. label
			.. " recovered an exact server connection after the client remote errored")
	elseif outcome and outcome.reusedLive and Config.VerboseRemoteLogging then
		print(PREFIX .. label .. " reused an exact existing live connection")
	end
	Runtime.commitVerifiedConnection(plan, reservation, decorations)
	return true
end

function Runtime.auditCommittedDuplicatePlacements()
	for _, preview in ipairs(State.duplicate.previews) do
		local placementError = Runtime.committedPlacementError(preview)
		if placementError then
			return false, string.format(
				"duplicate #%d %s: %s",
				preview.index,
				tostring(preview.entry and preview.entry.Name),
				placementError
			)
		end
	end
	return true
end

function Runtime.auditCommittedDuplicateConnections(makeMissingReplayable)
	local firstError
	for _, plan in ipairs(State.duplicate.connections) do
		local connectionError, replayable = Runtime.committedConnectionError(
			plan,
			Runtime.inspectDuplicateConnection
		)
		if connectionError then
			if makeMissingReplayable and replayable then
				Runtime.invalidateCommittedConnection(plan, connectionError)
				connectionError ..= "; marked pending for safe Resume"
			end
			firstError = firstError or string.format(
				"duplicate %s #%d: %s",
				plan.kind,
				plan.index,
				connectionError
			)
		end
	end
	return firstError == nil, firstError
end

function Runtime.activeDuplicatePreviews()
	local active = {}
	for _, preview in ipairs(State.duplicate.previews) do
		if not preview.built then
			table.insert(active, preview)
		end
	end
	return active
end

function Runtime.validateDuplicatePreviews(existing)
	if State.building then
		return false, "A placement build is currently running."
	end
	local duplicate = State.duplicate
	local previews = Runtime.activeDuplicatePreviews()
	local pendingConnections = Runtime.activeDuplicateConnections()
	if #previews == 0 and #pendingConnections == 0 then
		duplicate.validated = false
		return false, "Create a duplicate preview first."
	end
	local suppliedIndex = type(existing) == "table" and existing._spatialIndex
	local ownsExisting = type(suppliedIndex) ~= "table"
		or suppliedIndex.released == true
		or State.activePlacedCaches[existing] ~= true
	if ownsExisting then
		existing = Runtime.preparePlacedCache(collectPlacedMachines())
	end
	local allValid = true
	for _, preview in ipairs(duplicate.previews) do
		if preview.built then
			preview.reasons = {}
			local committedError = Runtime.committedPlacementError(preview)
			if committedError then
				addReason(preview, committedError)
				allValid = false
				warn(PREFIX .. string.format(
					"built duplicate #%d %s changed after verification: %s",
					preview.index,
					tostring(preview.entry and preview.entry.Name),
					committedError
				))
			end
		end
	end
	for _, preview in ipairs(previews) do
		preview.reasons = {}
		preview.overlapInvalid = false
		preview.recoveryModel = nil
		if preview.selectionVersion ~= duplicate.selectionVersion
			or preview.destinationX ~= duplicate.destinationX
			or preview.destinationZ ~= duplicate.destinationZ
			or preview.duplicateRotation ~= duplicate.rotation
		then
			addReason(preview, "selection, destination, or rotation changed; regenerate preview")
		elseif not duplicateSourceItemSnapshotIsCurrent(preview.sourceItem) then
			addReason(preview, "selected source object disappeared or changed; regenerate preview")
		elseif preview.setupError then
			addReason(preview, preview.setupError)
		elseif not preview.model or not preview.model.Parent or not preview.base then
			addReason(preview, "duplicate preview model is missing")
		else
			local inside, limitsError = baseInsideLimits(preview.base)
			if not inside then
				addReason(preview, limitsError)
			end
			if preview.recoveryKnownModels then
				local recovered, recoveryError = Runtime.matchFreshPlacementSinceBaseline(preview, existing)
				if recoveryError then
					addReason(preview, recoveryError)
				else
					preview.recoveryModel = recovered
				end
			end
			local candidate = footprint(preview.base)
			preview.cachedFootprint = candidate
			for _, placed in ipairs(Runtime.placedCollisionCandidates(existing, candidate)) do
				local existingFootprint = Runtime.placedFootprint(placed)
				if placed.model ~= preview.recoveryModel
					and existingFootprint
					and footprintsOverlap(candidate, existingFootprint)
					and not duplicatePlacedSiblingInheritedOverlap(preview, placed.model)
				then
					addReason(preview, "overlaps existing " .. placed.name)
					preview.overlapInvalid = true
					break
				end
			end
		end
	end
	local previewSpatial = Runtime.newTransientSpatialIndex()
	for _, second in ipairs(previews) do
		if second.base then
			local secondFootprint = second.cachedFootprint or footprint(second.base)
			Runtime.visitSpatialIndex(previewSpatial, secondFootprint, function(first)
				if not (first.overlapInvalid and second.overlapInvalid)
					and footprintsOverlap(first.cachedFootprint or footprint(first.base), secondFootprint)
					and not duplicatePreviewPairInheritedOverlap(first, second)
				then
					if not first.overlapInvalid then
						addReason(first, "overlaps duplicate #" .. second.index .. " " .. second.entry.Name)
					end
					if not second.overlapInvalid then
						addReason(second, "overlaps duplicate #" .. first.index .. " " .. first.entry.Name)
					end
					first.overlapInvalid = true
					second.overlapInvalid = true
				end
				return true
			end)
			Runtime.addTransientSpatialEntry(previewSpatial, second, secondFootprint)
		end
	end
	local invalidPreviewCount = 0
	for _, preview in ipairs(previews) do
		preview.valid = #preview.reasons == 0
		applyValidityStyle(preview)
		if not preview.valid then
			allValid = false
			invalidPreviewCount += 1
			if invalidPreviewCount <= Config.MaxInvalidPreviewWarnings then
				warn(PREFIX .. string.format(
					"duplicate #%d %s invalid: %s",
					preview.index,
					preview.entry.Name,
					table.concat(preview.reasons, "; ")
				))
			end
		end
	end
	if invalidPreviewCount > Config.MaxInvalidPreviewWarnings then
		warn(PREFIX .. string.format(
			"%d additional invalid duplicate preview warning(s) omitted",
			invalidPreviewCount - Config.MaxInvalidPreviewWarnings
		))
	end
	if not Runtime.validateDuplicateConnections(false) then
		allValid = false
	end
	local connectionStats = duplicate.connectionStats or {}
	local plumbingBlockReason = Runtime.duplicatePlumbingBlockReason(
		connectionStats,
		#duplicate.selected
	)
	local missingSelectedPlumbing = plumbingBlockReason ~= nil
	if missingSelectedPlumbing then
		allValid = false
		warn(PREFIX .. "duplicate connection copy refused: " .. plumbingBlockReason)
	end
	local totalConnections = (connectionStats.Pipe or 0) + (connectionStats.Wire or 0)
	local lineNote = totalConnections > (connectionStats.VisibleConnectionLines or 0)
		and string.format(
			" First %d/%d connection lines shown for performance.",
			connectionStats.VisibleConnectionLines or 0,
			totalConnections
		)
		or ""
	local boundaryPipeNote = (connectionStats.BoundaryPipeLinks or 0) > 0
		and string.format(
			" %d external pipe link(s) intentionally omitted.",
			connectionStats.BoundaryPipeLinks
		)
		or ""
	local boundaryWireNote = (connectionStats.BoundaryWireLinks or 0) > 0
		and string.format(
			" %d external power line(s) intentionally omitted.",
			connectionStats.BoundaryWireLinks
		)
		or ""
	duplicate.validated = allValid
	Runtime.updateDuplicateStatus(allValid
		and string.format(
			"Preview valid: %d placement(s), %d exact pipe plug(s), and %d wire(s) ready.%s%s%s",
			#previews,
			connectionStats.Pipe or 0,
			connectionStats.Wire or 0,
			lineNote,
			boundaryPipeNote,
			boundaryWireNote
		)
		or missingSelectedPlumbing
			and ("Preview refused: " .. plumbingBlockReason)
			or "Preview invalid; red ghosts and console messages show why.")
	if ownsExisting then
		Runtime.releasePlacedCache(existing)
	end
	return allValid
end

function Runtime.previewDuplicateCore(existing)
	if State.destroyed then
		return false, "The script has been destroyed; execute it again to restart."
	elseif State.building then
		return false, "A placement build is currently running."
	end
	local duplicate = State.duplicate
	local previewSelectionVersion = duplicate.selectionVersion
	local auditLockReason = Runtime.duplicateAuditLockReason()
	if auditLockReason then
		return false, auditLockReason
	end
	local removed, pruneError, anchorRemoved = Runtime.pruneStaleDuplicateSelection(true)
	if pruneError then
		return false, pruneError
	elseif #duplicate.selected == 0 then
		return false, removed > 0
			and "Every selected source object disappeared; select the group again."
			or "Select at least one source object first."
	elseif anchorRemoved or duplicate.destinationX == nil then
		return false, anchorRemoved
			and "The source anchor disappeared; the remaining group was kept. Pick the destination again."
			or "Pick a destination first."
	end
	local folder, folderError = Runtime.getDuplicatePreviewFolder()
	if not folder then
		return false, folderError
	end
	folder:ClearAllChildren()
	duplicate.previews = {}
	duplicate.validated = false
	for index, item in ipairs(duplicate.selected) do
		table.insert(duplicate.previews, Runtime.createDuplicatePreview(index, item, folder))
		if index % Config.PreviewRenderYieldEvery == 0 then
			RunService.Heartbeat:Wait()
			if State.destroyed or duplicate.selectionVersion ~= previewSelectionVersion then
				return false, "Duplicate selection changed while the preview was rendering; press Preview again."
			end
		end
	end
	if duplicate.selectionVersion ~= previewSelectionVersion then
		Runtime.clearDuplicatePreview(true, true)
		return false, "Duplicate selection changed while the preview was rendering; press Preview again."
	end
	Runtime.createDuplicateConnectionPlans(folder)
	if duplicate.selectionVersion ~= previewSelectionVersion then
		Runtime.clearDuplicatePreview(true, true)
		return false, "Duplicate selection changed while connections were being audited; press Preview again."
	end
	local valid = Runtime.validateDuplicatePreviews(existing)
	local validationError
	if valid then
		local connectionStats = duplicate.connectionStats or {}
		local boundaryPipeNote = (connectionStats.BoundaryPipeLinks or 0) > 0
			and string.format(
				" %d external pipe link(s) omitted.",
				connectionStats.BoundaryPipeLinks
			)
			or ""
		local boundaryWireNote = (connectionStats.BoundaryWireLinks or 0) > 0
			and string.format(
				" %d external power line(s) omitted.",
				connectionStats.BoundaryWireLinks
			)
			or ""
		notify(
			"Duplicate preview ready",
			string.format(
				"%d object(s), %d exact pipe plug(s), %d wire(s).%s%s",
				#duplicate.selected,
				connectionStats.Pipe or 0,
				connectionStats.Wire or 0,
				boundaryPipeNote,
				boundaryWireNote
			),
			6
		)
	else
		local connectionStats = duplicate.connectionStats or {}
		local plumbingError = Runtime.duplicatePlumbingBlockReason(
			connectionStats,
			#duplicate.selected
		)
		if plumbingError then
			validationError = plumbingError
			notify(
				"Connection copy stopped",
				plumbingError,
				10
			)
		end
		if not validationError then
			for _, preview in ipairs(duplicate.previews) do
				if preview.valid == false and type(preview.reasons) == "table" and #preview.reasons > 0 then
					validationError = string.format(
						"Duplicate #%d %s: %s",
						preview.index,
						tostring(preview.entry and preview.entry.Name),
						table.concat(preview.reasons, "; ")
					)
					break
				end
			end
		end
		if not validationError then
			for _, plan in ipairs(duplicate.connections) do
				if plan.valid == false and type(plan.reasons) == "table" and #plan.reasons > 0 then
					validationError = string.format(
						"%s connection #%d: %s",
						tostring(plan.kind),
						plan.index,
						table.concat(plan.reasons, "; ")
					)
					break
				end
			end
		end
	end
	return valid, validationError or (not valid and "Duplicate preview failed validation; inspect the red ghosts and console details." or nil)
end

function Runtime.previewDuplicate(existing)
	local duplicate = State.duplicate
	if duplicate.previewInProgress then
		return false, "A duplicate preview is already being prepared."
	end
	duplicate.previewInProgress = true
	local ok, result, detail = pcall(Runtime.previewDuplicateCore, existing)
	duplicate.previewInProgress = false
	if not ok then
		warn(PREFIX .. "duplicate preview error: " .. tostring(result))
		return false, tostring(result)
	end
	return result, detail
end

function Runtime.useMyPositionForDuplicate()
	local character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
	local root = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
	if not root then
		return false, "Character has no HumanoidRootPart/PrimaryPart."
	end
	return Runtime.setDuplicateDestination(root.Position.X, root.Position.Z, false)
end

function Runtime.handleDuplicateWorldClick(action, mouse)
	if State.destroyed then
		return false, "The script has been destroyed."
	elseif State.autoFitInProgress then
		return false, Runtime.autoFitBusyReason()
	elseif State.building then
		return false, "Selection is locked while a build is running."
	end
	if action ~= "destination" then
		local auditLockReason = Runtime.duplicateAuditLockReason()
		if auditLockReason then
			return false, auditLockReason
		end
	end
	if action == "destination" then
		local hit = mouse.Hit
		if typeof(hit) ~= "CFrame" then
			return false, "No world position was found under the cursor."
		end
		return Runtime.setDuplicateDestination(hit.Position.X, hit.Position.Z, false)
	end
	local model, base, targetError = Runtime.placedRootFromTarget(mouse.Target)
	if not model then
		return false, targetError
	end
	if action == "replace" then
		return Runtime.replaceDuplicateSelection(model, base)
	elseif action == "toggle" then
		if State.duplicate.byModel[model] then
			return Runtime.removeDuplicateSelection(model)
		end
		return Runtime.addDuplicateSelection(model, base)
	end
	return false, "Unknown duplicate click action."
end

function Runtime.armDuplicateMarquee()
	local duplicate = State.duplicate
	if State.destroyed then
		return false, "The script has been destroyed."
	elseif State.autoFitInProgress then
		return false, Runtime.autoFitBusyReason()
	elseif State.building then
		return false, "Selection is locked while a build is running."
	elseif Runtime.duplicateAuditLockReason() then
		return false, Runtime.duplicateAuditLockReason()
	elseif not duplicate.selecting then
		return false, "Start Selecting before using Shift-drag box selection."
	elseif duplicate.marqueeDragging then
		return true
	end
	duplicate.marqueeArmed = true
	if duplicate.hoverBox then
		duplicate.hoverBox.Adornee = nil
	end
	Runtime.updateDuplicateStatus(
		"BOX SELECT ARMED: hold the left mouse button, drag a blue box, then release."
	)
	notify("Box selection armed", "Drag over every machine or pipe you want to duplicate.", 6)
	return true
end

function Runtime.beginDuplicateMarquee(mouse)
	local duplicate = State.duplicate
	if State.destroyed or State.building or State.autoFitInProgress
		or not duplicate.selecting or not duplicate.marqueeArmed
	then
		return false
	end
	local hit = mouse.Hit
	if typeof(hit) ~= "CFrame" then
		return false
	end
	Runtime.clearDuplicateMarquee()
	duplicate.marqueeDragging = true
	duplicate.marqueeStartX = hit.Position.X
	duplicate.marqueeStartZ = hit.Position.Z

	local part = Instance.new("Part")
	part.Name = "__IndustrialistDuplicateDragArea"
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = Vector3.new(0.2, 0.35, 0.2)
	part.CFrame = CFrame.new(hit.Position.X, Config.PlacementY, hit.Position.Z)
	part.Parent = workspace
	duplicate.marqueePart = part

	local selectionBox = Instance.new("SelectionBox")
	selectionBox.Name = "__IndustrialistDuplicateDragBox"
	selectionBox.Adornee = part
	selectionBox.Color3 = Color3.fromRGB(40, 163, 255)
	selectionBox.SurfaceColor3 = Color3.fromRGB(40, 163, 255)
	selectionBox.SurfaceTransparency = 0.82
	selectionBox.LineThickness = 0.07
	selectionBox.Parent = part
	duplicate.marqueeBox = selectionBox
	Runtime.updateDuplicateStatus("BOX SELECTING: drag across the full source build and release.")
	return true
end

function Runtime.updateDuplicateMarquee(mouse)
	local duplicate = State.duplicate
	if not duplicate.marqueeDragging or not duplicate.marqueePart then
		return
	end
	local hit = mouse.Hit
	if typeof(hit) ~= "CFrame" then
		return
	end
	local currentX = hit.Position.X
	local currentZ = hit.Position.Z
	local sizeX = math.max(math.abs(currentX - duplicate.marqueeStartX), 0.2)
	local sizeZ = math.max(math.abs(currentZ - duplicate.marqueeStartZ), 0.2)
	duplicate.marqueePart.Size = Vector3.new(sizeX, 0.35, sizeZ)
	duplicate.marqueePart.CFrame = CFrame.new(
		(duplicate.marqueeStartX + currentX) * 0.5,
		Config.PlacementY,
		(duplicate.marqueeStartZ + currentZ) * 0.5
	)
end

function Runtime.finishDuplicateMarquee()
	local duplicate = State.duplicate
	if not duplicate.marqueeDragging or not duplicate.marqueePart then
		return false
	end
	local autoFitBusy = Runtime.autoFitBusyReason()
	if autoFitBusy then
		Runtime.clearDuplicateMarquee()
		return false, autoFitBusy
	end
	local auditLockReason = Runtime.duplicateAuditLockReason()
	if auditLockReason then
		Runtime.clearDuplicateMarquee()
		Runtime.updateDuplicateStatus(auditLockReason)
		notify("Box selection stopped", auditLockReason, 9)
		return false, auditLockReason
	end
	local selectionFootprint = footprint(duplicate.marqueePart)
	-- Marquee contact is inclusive: slightly expand its half-extents so a Base
	-- exactly touching the visible blue edge is selected too. Placement overlap
	-- validation remains strict and continues to allow edge contact.
	selectionFootprint.xHalf += Config.EdgeEpsilon * 2
	selectionFootprint.zHalf += Config.EdgeEpsilon * 2
	local added = 0
	local skipped = 0
	local selectionWasEmpty = #duplicate.selected == 0
	local candidates = {}
	for _, placed in ipairs(collectPlacedMachines()) do
		if not duplicate.byModel[placed.model]
			and footprintsOverlap(selectionFootprint, footprint(placed.base))
		then
			table.insert(candidates, placed)
		end
	end
	-- GetDescendants order is not stable. When the marquee creates a brand-new
	-- group, make the Base nearest the drag origin the deterministic anchor.
	table.sort(candidates, function(first, second)
		local firstX = first.base.Position.X - duplicate.marqueeStartX
		local firstZ = first.base.Position.Z - duplicate.marqueeStartZ
		local secondX = second.base.Position.X - duplicate.marqueeStartX
		local secondZ = second.base.Position.Z - duplicate.marqueeStartZ
		local firstDistance = firstX * firstX + firstZ * firstZ
		local secondDistance = secondX * secondX + secondZ * secondZ
		if math.abs(firstDistance - secondDistance) > 0.0001 then
			return firstDistance < secondDistance
		elseif first.name ~= second.name then
			return first.name < second.name
		elseif math.abs(first.base.Position.X - second.base.Position.X) > 0.0001 then
			return first.base.Position.X < second.base.Position.X
		end
		return first.base.Position.Z < second.base.Position.Z
	end)
	for candidateIndex, placed in ipairs(candidates) do
		if #duplicate.selected >= Config.MaxDuplicateSelection then
			skipped += #candidates - candidateIndex + 1
			break
		else
			-- A large factory selection used to destroy/rebuild the preview and
			-- redraw Rayfield once per object. Batch that bookkeeping so a 1,000
			-- object drag performs one invalidation and one status update.
			local selected = Runtime.addDuplicateSelection(placed.model, placed.base, true)
			if selected then
				added += 1
			else
				skipped += 1
			end
		end
	end
	if added > 0 then
		duplicate.selectionVersion += 1
		if selectionWasEmpty then
			Runtime.refreshDuplicateAnchor(true)
		end
		Runtime.clearDuplicatePreview(true)
	end
	Runtime.clearDuplicateMarquee()
	Runtime.updateDuplicateStatus(string.format(
		"BOX COMPLETE: added %d object(s)%s. Selection mode is still active.",
		added,
		skipped > 0 and string.format("; %d unsupported/over-limit", skipped) or ""
	))
	notify("Box selection complete", string.format("%d object(s) added to the duplicate group.", added), 6)
	return true, added
end

function Runtime.updateDuplicateHover(mouse)
	local duplicate = State.duplicate
	if not duplicate.selecting or not duplicate.hoverBox then
		return
	end
	if duplicate.marqueeArmed or duplicate.marqueeDragging then
		duplicate.hoverBox.Adornee = nil
		return
	end
	local _, base = Runtime.placedRootFromTarget(mouse.Target)
	duplicate.hoverBox.Adornee = base
end

function Runtime.stopDuplicateSelecting(silent)
	local wasSelecting = State.duplicate.selecting
	Runtime.disconnectDuplicateClick()
	if not silent then
		Runtime.updateDuplicateStatus(wasSelecting
			and "Selection stopped. Blue boxes show the saved group."
			or "Selection mode is already stopped.")
		if wasSelecting then
			notify("Selection stopped", "The current duplicate group was kept.", 5)
		end
	end
	return true
end

function Runtime.startDuplicateSelecting()
	if State.destroyed then
		return false, "The script has been destroyed; execute it again to restart."
	elseif State.autoFitInProgress then
		return false, Runtime.autoFitBusyReason()
	elseif State.building then
		return false, "A placement build is currently running."
	elseif Runtime.duplicateAuditLockReason() then
		return false, Runtime.duplicateAuditLockReason()
	elseif State.duplicate.selecting then
		Runtime.updateDuplicateStatus("SELECTING: click objects to add/remove; press Stop Selecting when finished.")
		return true
	end
	Runtime.disconnectDuplicateClick()
	local duplicate = State.duplicate
	duplicate.clickGeneration += 1
	local generation = duplicate.clickGeneration
	duplicate.armedAction = "persistent"
	duplicate.selecting = true
	local mouse = LocalPlayer:GetMouse()
	local userInputService = game:GetService("UserInputService")
	local readyAt = os.clock() + 0.12

	local hoverBox = Instance.new("SelectionBox")
	hoverBox.Name = "__IndustrialistDuplicateHoverBox"
	hoverBox.Color3 = Color3.fromRGB(50, 172, 255)
	hoverBox.SurfaceColor3 = Color3.fromRGB(50, 172, 255)
	hoverBox.SurfaceTransparency = 0.9
	hoverBox.LineThickness = 0.075
	hoverBox.Parent = workspace
	duplicate.hoverBox = hoverBox
	Runtime.updateDuplicateHover(mouse)
	duplicate.hoverConnection = mouse.Move:Connect(function()
		if generation == duplicate.clickGeneration then
			Runtime.updateDuplicateMarquee(mouse)
			Runtime.updateDuplicateHover(mouse)
		end
	end)
	duplicate.clickConnection = userInputService.InputBegan:Connect(function(input, gameProcessed)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1
			or gameProcessed
			or generation ~= duplicate.clickGeneration
			or os.clock() < readyAt
		then
			return
		end
		if duplicate.marqueeArmed then
			Runtime.beginDuplicateMarquee(mouse)
			return
		elseif duplicate.marqueeDragging then
			return
		end
		task.defer(function()
			if generation ~= duplicate.clickGeneration then
				return
			end
			local ok, result, detail = pcall(Runtime.handleDuplicateWorldClick, "toggle", mouse)
			if not ok then
				warn(PREFIX .. "persistent duplicate selection failed: " .. tostring(result))
				notify("Selection failed", tostring(result), 7)
			elseif result == false then
				notify("Nothing selected", tostring(detail), 5)
			end
			if duplicate.selecting then
				Runtime.updateDuplicateStatus(
					"SELECTING: keep clicking objects; use Stop Selecting when the blue group is complete."
				)
				Runtime.updateDuplicateHover(mouse)
			end
		end)
	end)
	duplicate.releaseConnection = userInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			and generation == duplicate.clickGeneration
			and duplicate.marqueeDragging
		then
			Runtime.updateDuplicateMarquee(mouse)
			Runtime.finishDuplicateMarquee()
		end
	end)
	Runtime.updateDuplicateStatus(
		"SELECTING: click objects to add/remove. This stays active until Stop Selecting."
	)
	notify("Selection mode active", "Click machines or pipes; Stop Selecting ends the mode.", 7)
	return true
end

function Runtime.installDuplicateShiftShortcut()
	local duplicate = State.duplicate
	if duplicate.shiftConnection then
		pcall(function()
			duplicate.shiftConnection:Disconnect()
		end)
		duplicate.shiftConnection = nil
	end
	local userInputService = game:GetService("UserInputService")
	duplicate.shiftConnection = userInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed or userInputService:GetFocusedTextBox() then
			return
		end
		if input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.RightShift then
			-- Shift is only a shortcut for the marquee while explicit selection
			-- mode is already active. Never let a normal gameplay Shift press
			-- unexpectedly start capturing world clicks for duplication.
			if not duplicate.selecting then
				return
			end
			local ok, result, detail = pcall(Runtime.armDuplicateMarquee)
			if not ok then
				warn(PREFIX .. "Shift selection failed: " .. tostring(result))
			elseif result == false and detail then
				notify("Selection unavailable", tostring(detail), 6)
			end
		end
	end)
	return true
end

function Runtime.armDuplicateWorldClick(action)
	if State.building then
		return false, "A placement build is currently running."
	elseif State.autoFitInProgress then
		return false, Runtime.autoFitBusyReason()
	end
	if action == "destination" and #State.duplicate.selected == 0 then
		return false, "Select at least one source object first."
	end
	Runtime.disconnectDuplicateClick()
	local duplicate = State.duplicate
	duplicate.clickGeneration += 1
	local generation = duplicate.clickGeneration
	duplicate.armedAction = action
	local mouse = LocalPlayer:GetMouse()
	local readyAt = os.clock() + 0.12
	duplicate.clickConnection = mouse.Button1Down:Connect(function()
		if generation ~= duplicate.clickGeneration or os.clock() < readyAt then
			return
		end
		Runtime.disconnectDuplicateClick()
		task.defer(function()
			local ok, result, detail = pcall(Runtime.handleDuplicateWorldClick, action, mouse)
			if not ok then
				warn(PREFIX .. "duplicate selection click failed: " .. tostring(result))
				notify("Duplicate selection failed", tostring(result), 8)
				Runtime.updateDuplicateStatus("Click failed.")
			elseif result == false then
				notify("Duplicate selection stopped", tostring(detail), 7)
				Runtime.updateDuplicateStatus(tostring(detail))
			end
		end)
	end)
	local instruction = action == "destination"
		and "CLICK THE WORLD: choose where the blue source anchor should move."
		or action == "replace"
			and "CLICK A PLACED OBJECT: it becomes the new duplicate selection."
			or "CLICK A PLACED OBJECT: add it, or remove it if already selected."
	Runtime.updateDuplicateStatus(instruction)
	notify("Duplicate picker armed", instruction, 7)
	return true
end

function Runtime.runDuplicateBuild()
	if State.destroyed then
		return false, "The script has been destroyed; execute it again to restart."
	elseif State.building then
		return false, "A placement build is currently running."
	elseif State.captureArmed or State.captureProcessing then
		return false, "Finish or cancel the active placement Scan first."
	elseif not State.captured or not State.scanComplete then
		local message = "Press Scan Placement Packet and normally place any supported catalog object first."
		State.duplicate.lastReportedFailure = message
		notify("Duplicate refused", message, 8)
		Runtime.updateDuplicateStatus(message)
		return false, message
	end
	local duplicate = State.duplicate
	local removed, pruneError, anchorRemoved = Runtime.pruneStaleDuplicateSelection(true)
	if pruneError then
		return false, pruneError
	elseif #duplicate.selected == 0 then
		return false, removed > 0
			and "Every selected source object disappeared; select the group again."
			or "Select at least one source object first."
	elseif anchorRemoved or duplicate.destinationX == nil then
		return false, anchorRemoved
			and "The source anchor disappeared; the remaining group was kept. Pick the destination again."
			or "Pick a destination first."
	end
	Runtime.rescanPlacedRegistry()
	local committedConnectionsOK, committedConnectionError = Runtime.auditCommittedDuplicateConnections(true)
	if not committedConnectionsOK then
		Runtime.updateDuplicateStatus("Resume preflight: " .. tostring(committedConnectionError))
	end
	return Runtime.withPreparedPlacedCache(function(buildExisting)
		if #duplicate.previews == 0 then
			local previewOK, previewError = Runtime.previewDuplicate(buildExisting)
			if not previewOK then
				return false, previewError or "Duplicate preview failed validation."
			end
		else
			local allWorkCommitted = #Runtime.activeDuplicatePreviews() == 0
				and #Runtime.activeDuplicateConnections() == 0
			if allWorkCommitted then
				-- Cancellation can arrive during the final post-action delay. In that
				-- case every server action is already committed; audit and let the normal
				-- success path clear the workspace instead of demanding a new Preview.
				local placementsOK, placementError = Runtime.auditCommittedDuplicatePlacements()
				local connectionsOK, connectionError = Runtime.auditCommittedDuplicateConnections(false)
				if not placementsOK or not connectionsOK then
					return false, "Committed duplicate changed: "
						.. tostring(placementError or connectionError)
				end
			else
				-- Refresh the exact live graph across two replication frames. If any
				-- destination connection already committed, the whole manifest must remain
				-- byte-for-byte equivalent so Resume cannot mix two source topologies.
				local previewFolder = workspace:FindFirstChild(Runtime.DuplicatePreviewFolder)
				local refreshed, refreshError = Runtime.refreshDuplicateConnectionPlans(
					previewFolder and previewFolder:IsA("Folder") and previewFolder or nil
				)
				if not refreshed then
					return false, refreshError
				elseif not Runtime.validateDuplicatePreviews(buildExisting) then
					return false, "Duplicate preview failed validation."
				end
			end
		end

		Runtime.stopDuplicateSelecting(true)
		State.building = true
		State.cancelRequested = false
		local priorPlacements = builtItemCount(duplicate.previews)
		local priorConnections = builtItemCount(duplicate.connections)
		local completed = 0
		local completedConnections = 0
		local failure
		local connectionDecorationBaseline
		local knownPlacedModels = Runtime.knownPlacedModels(buildExisting)

		for _, preview in ipairs(duplicate.previews) do
			if State.cancelRequested then
				failure = Runtime.buildCancellationReason()
				break
			elseif preview.built then
				continue
			end

			if preview.recoveryKnownModels then
				local recovered, recoveryError = Runtime.matchFreshPlacementSinceBaseline(
					preview,
					buildExisting
				)
				if recoveryError then
					failure = string.format("duplicate #%d recovery stopped: %s", preview.index, recoveryError)
					break
				elseif recovered then
					if not validateCurrentPlacement(preview, buildExisting, recovered) then
						failure = string.format(
							"duplicate #%d recovered placement failed validation: %s",
							preview.index,
							table.concat(preview.reasons, "; ")
						)
						break
					end
					preview.built = true
					preview.reusedServerModel = false
					preview.placedModel = recovered
					preview.recoveryKnownModels = nil
					if preview.model then
						preview.model:Destroy()
					end
					preview.model = nil
					preview.base = nil
					completed += 1
					knownPlacedModels[recovered] = true
					Runtime.updateDuplicateStatus(string.format(
						"Recovered delayed placement #%d • overall %d/%d • no remote resent.",
						preview.index,
						priorPlacements + completed,
						#duplicate.previews
					))
					continue
				end
				-- The cancelled/error attempt has fully settled and its authoritative
				-- baseline has no fresh exact result, so one new send is now safe.
				preview.recoveryKnownModels = nil
			end

			if not preview.model or not preview.model.Parent or not preview.base then
				failure = string.format("duplicate #%d preview disappeared", preview.index)
				break
			elseif not validateCurrentPlacement(preview, buildExisting) then
				failure = string.format(
					"duplicate #%d %s failed last-second validation: %s",
					preview.index,
					preview.entry.Name,
					table.concat(preview.reasons, "; ")
				)
				break
			end
			local packet, packetError = canonicalPacket(
				State.captured,
				preview.template,
				preview.targetCFrame,
				false
			)
			if not packet then
				failure = packetError
				break
			end

			local actionStartedAt = os.clock()
			Runtime.acknowledgePlacedCacheAdditions(buildExisting, knownPlacedModels)
			local attemptKnownModels = Runtime.snapshotKnownPlacedModels(knownPlacedModels)
			-- Persist the exact pre-send baseline before any remote-reaching call. If
			-- send/verification throws, the outer build guard leaves this marker in
			-- place so UI cleanup cannot erase an effect that may replicate late.
			preview.recoveryKnownModels = attemptKnownModels
			local watch = Runtime.beginPlacementWatch(attemptKnownModels)
			local callOK, serverResult = sendPlacement(State.captured, packet)
			if callOK and serverResult == false then
				Runtime.stopPlacementWatch(watch)
				preview.recoveryKnownModels = nil
				failure = string.format("server rejected duplicate #%d %s", preview.index, preview.entry.Name)
				break
			end
			local placed, verifyError = verifyNewPlacement(watch, preview)
			if not placed then
				failure = not callOK and string.format(
					"duplicate #%d remote error: %s; no exact server placement was observed yet: %s",
					preview.index,
					tostring(serverResult),
					tostring(verifyError)
				) or string.format(
					"duplicate #%d verification failed: %s",
					preview.index,
					tostring(verifyError)
				)
				break
			end
			if not callOK then
				print(PREFIX .. string.format(
					"duplicate #%d %s recovered an exact server placement after the client remote errored",
					preview.index,
					preview.entry.Name
				))
			end
			preview.built = true
			preview.reusedServerModel = false
			preview.placedModel = placed
			preview.recoveryKnownModels = nil
			preview.model:Destroy()
			preview.model = nil
			preview.base = nil
			completed += 1
			Runtime.mergePlacementWatchCandidates(buildExisting, knownPlacedModels, watch)
			Runtime.appendPlacedToCache(buildExisting, knownPlacedModels, placed)
			if Runtime.shouldReportResumedProgress(
				priorPlacements,
				completed,
				#duplicate.previews
			) then
				Runtime.updateDuplicateStatus(string.format(
					"Placement progress: %d/%d verified.",
					priorPlacements + completed,
					#duplicate.previews
				))
			end
			if not Runtime.waitForNextAction(Config.PlacementDelay, actionStartedAt) then
				failure = Runtime.buildCancellationReason()
				break
			end
		end

		if not failure then
			local committedOK, committedError = Runtime.auditCommittedDuplicatePlacements()
			if not committedOK then
				failure = "pre-connection placement audit failed: " .. tostring(committedError)
			end
		end
		if not failure then
			-- Placement can take minutes on a large factory. Audit the source graph one
			-- final time immediately before the first PipeBind/WireBind, after every
			-- destination machine has been server-verified.
			local refreshed, refreshError = Runtime.refreshDuplicateConnectionPlans(nil)
			if not refreshed then
				failure = "pre-connection source graph audit failed: " .. tostring(refreshError)
			else
				connectionDecorationBaseline = Runtime.snapshotDuplicateConnectionDecorationWorld(
					duplicate.connections
				)
			end
		end
		if not failure then
			-- Electrical edges depend only on the verified destination machines. Send
			-- them before physical pipe plugs so a later plumbing-specific server
			-- rejection cannot prevent otherwise valid wiring from being committed.
			local orderedConnections = {}
			for _, wantedKind in ipairs({ "Wire", "Pipe" }) do
				for _, plan in ipairs(duplicate.connections) do
					if plan.kind == wantedKind then
						table.insert(orderedConnections, plan)
					end
				end
			end
			for _, plan in ipairs(orderedConnections) do
				if State.cancelRequested then
					failure = Runtime.buildCancellationReason()
					break
				elseif plan.built then
					continue
				end
				local decorationWorldStable, decorationWorldError =
					Runtime.auditDuplicateConnectionDecorationWorld(connectionDecorationBaseline)
				if not decorationWorldStable then
					failure = "source/world connection graph changed before the next send: "
						.. tostring(decorationWorldError)
					break
				end
				local actionStartedAt = os.clock()
				local connected, connectionError = Runtime.buildDuplicateConnection(plan)
				if not connected then
					failure = string.format(
						"duplicate %s #%d %s",
						plan.kind,
						plan.index,
						tostring(connectionError)
					)
					break
				end
				completedConnections += 1
				Runtime.admitVerifiedDuplicateConnectionDecorations(
					connectionDecorationBaseline,
					plan
				)
				decorationWorldStable, decorationWorldError =
					Runtime.auditDuplicateConnectionDecorationWorld(connectionDecorationBaseline)
				if not decorationWorldStable then
					failure = "connection committed, but the source/world graph changed concurrently: "
						.. tostring(decorationWorldError)
					break
				end
				local totalCommittedConnections = priorConnections + completedConnections
				if totalCommittedConnections > 0
					and totalCommittedConnections % Config.DuplicateConnectionAuditBatch == 0
				then
					local topologyStable, topologyError = Runtime.refreshDuplicateConnectionPlans(nil)
					if not topologyStable then
						failure = "selected source connection graph changed during replay: "
							.. tostring(topologyError)
						break
					end
				end
				if Runtime.shouldReportResumedProgress(
					priorConnections,
					completedConnections,
					#duplicate.connections
				) then
					Runtime.updateDuplicateStatus(string.format(
						"Connection progress: %d/%d verified.",
						priorConnections + completedConnections,
						#duplicate.connections
					))
				end
				if not Runtime.waitForNextAction(Config.ConnectionDelay, actionStartedAt) then
					failure = Runtime.buildCancellationReason()
					break
				end
			end
		end
		if not failure and connectionDecorationBaseline then
			local topologyStable, topologyError = Runtime.refreshDuplicateConnectionPlans(nil)
			if not topologyStable then
				failure = "selected source connection graph changed before final commit: "
					.. tostring(topologyError)
			end
		end
		if not failure and connectionDecorationBaseline then
			local decorationWorldStable, decorationWorldError =
				Runtime.auditDuplicateConnectionDecorationWorld(connectionDecorationBaseline)
			if not decorationWorldStable then
				failure = "connection replay graph changed before final commit: "
					.. tostring(decorationWorldError)
			end
		end
		if not failure then
			local committedOK, committedError = Runtime.auditCommittedDuplicatePlacements()
			if not committedOK then
				failure = "final placement audit failed: " .. tostring(committedError)
			end
		end
		if not failure then
			local committedOK, committedError = Runtime.auditCommittedDuplicateConnections(true)
			if not committedOK then
				failure = "final connection audit failed: " .. tostring(committedError)
			end
		end

		State.building = false
		duplicate.validated = false
		if failure then
			duplicate.lastReportedFailure = failure
			warn(PREFIX .. "DUPLICATE STOPPED: " .. failure)
			Runtime.updateDuplicateStatus(string.format(
				"STOPPED after %d new placement(s) and %d new connection(s): %s",
				completed,
				completedConnections,
				failure
			))
			notify("DUPLICATE STOPPED", failure, 10)
			return false, failure
		end

		local totalPlacements = #duplicate.previews
		local totalConnections = #duplicate.connections
		local completedStats = duplicate.connectionStats or {}
		local boundaryPipeLinks = tonumber(completedStats.BoundaryPipeLinks) or 0
		local boundaryWireLinks = tonumber(completedStats.BoundaryWireLinks) or 0
		local boundaryNote = (boundaryPipeLinks + boundaryWireLinks) > 0
			and string.format(
				" %d external pipe link(s) and %d external power line(s) were intentionally omitted.",
				boundaryPipeLinks,
				boundaryWireLinks
			)
			or ""
		Runtime.markConnectionManifestComplete(duplicate.previews)
		local folder = workspace:FindFirstChild(Runtime.DuplicatePreviewFolder)
		if folder and folder:IsA("Folder") then
			folder:ClearAllChildren()
		end
		duplicate.previews = {}
		duplicate.connections = {}
		Runtime.updateDuplicateStatus(string.format(
			"Complete: %d server-verified placement(s), %d exact connection(s).%s",
			totalPlacements,
			totalConnections,
			boundaryNote
		))
		notify("Duplicate complete", string.format(
			"%d object(s) and %d pipe/wire connection(s) verified.%s",
			totalPlacements,
			totalConnections,
			boundaryNote
		), 7)
		return true, totalPlacements
	end)
end

function Runtime.buildDuplicate()
	if State.destroyed then
		return false, "The script has been destroyed; execute it again to restart."
	elseif State.building then
		return false, "A placement build is currently running."
	end
	State.duplicate.lastReportedFailure = nil
	local leaseToken, leaseError = Runtime.acquireBuildLease()
	if not leaseToken then
		if not State.destroyed then
			State.duplicate.lastReportedFailure = tostring(leaseError)
			Runtime.updateDuplicateStatus(leaseError)
			notify("Duplicate waiting", leaseError, 7)
		end
		return false, leaseError
	end
	State.buildLeaseToken = leaseToken
	State.buildRemoteAttempted = false
	local ok, result, detail = pcall(Runtime.runDuplicateBuild)
	Runtime.stopAllBuildWatches()
	State.replaying = false
	State.building = false
	local quarantine = State.buildRemoteAttempted
		and (not ok or result == false or State.cancelRequested or State.destroyed)
	Runtime.releaseBuildLease(leaseToken, quarantine)
	State.buildLeaseToken = nil
	State.buildRemoteAttempted = false
	if not ok then
		State.duplicate.validated = false
		State.duplicate.lastReportedFailure = tostring(result)
		warn(PREFIX .. "DUPLICATE ERROR: " .. tostring(result))
		if not State.destroyed then
			Runtime.updateDuplicateStatus("ERROR: " .. tostring(result))
			notify("DUPLICATE ERROR", tostring(result), 10)
		end
		return false, tostring(result)
	end
	if result == false and detail and not State.destroyed
		and State.duplicate.lastReportedFailure ~= tostring(detail)
	then
		State.duplicate.lastReportedFailure = tostring(detail)
		Runtime.updateDuplicateStatus("STOPPED: " .. tostring(detail))
		notify("DUPLICATE STOPPED", tostring(detail), 10)
	end
	return result, detail
end

function Runtime.cleanupDuplicateFeature(silent, force)
	local wasBuilding = State.building
	if wasBuilding and not force then
		return false, "A placement build is currently running; use Stop Build and let its audit settle first."
	elseif State.autoFitInProgress and not force then
		return false, Runtime.autoFitBusyReason()
	end
	local auditLockReason = not force and Runtime.duplicateAuditLockReason() or nil
	if auditLockReason then
		if not silent then
			Runtime.updateDuplicateStatus(auditLockReason)
			notify("Duplicate workspace kept", auditLockReason, 9)
		end
		return false, auditLockReason
	end
	if wasBuilding then
		State.cancelRequested = true
	end
	Runtime.disconnectDuplicateClick()
	if State.duplicate.shiftConnection then
		pcall(function()
			State.duplicate.shiftConnection:Disconnect()
		end)
		State.duplicate.shiftConnection = nil
	end
	local previewFolder = workspace:FindFirstChild(Runtime.DuplicatePreviewFolder)
	if previewFolder and previewFolder:IsA("Folder") then
		previewFolder:ClearAllChildren()
	end
	Runtime.destroyDuplicateSelectionHighlights()
	local duplicate = State.duplicate
	duplicate.previews = {}
	duplicate.connections = {}
	duplicate.validated = false
	table.clear(duplicate.selected)
	table.clear(duplicate.byModel)
	duplicate.selectionVersion += 1
	duplicate.sourceAnchorX = nil
	duplicate.sourceAnchorZ = nil
	duplicate.destinationX = nil
	duplicate.destinationZ = nil
	duplicate.lastReportedFailure = nil
	if not silent then
		Runtime.updateDuplicateStatus(wasBuilding
			and "Duplicate workspace cleared; active build cancellation requested."
			or "Duplicate workspace cleared.")
	end
	return true
end

local function runAutoPlumbPreview()
	if State.autoPlumbMode == "Off" then
		State.autoPlumbMode = "Automatic"
	end
	return previewAndValidate()
end

local API = {
	Version = "2.0.0-production",
	ContractVersion = "guided-entry-v2",
	CaptureHookVersion = Runtime.CaptureHookVersion,
	Ready = true,
	Blueprint = Blueprint,
	Plumbing = Plumbing,
	AuthoredPlumbing = AuthoredPlumbing,
	AuthoredPipeLinks = AuthoredPipeLinks,
	Wiring = Wiring,
	AutoPlumbRoutes = AutoPlumb,
	Config = Config,
	State = State,
	Preview = previewAndValidate,
	AutoPlumb = runAutoPlumbPreview,
	GenerateSmartPlumbing = runAutoPlumbPreview,
	SetAutoPlumbQuality = setAutoPlumbQuality,
	SetAutoPlumbEnabled = Runtime.setAutoPlumbEnabled,
	SetSmartTurnEnabled = Runtime.setSmartTurnEnabled,
	SetAutoFitClearance = Runtime.setAutoFitClearance,
	SetGameStyleConnectionPreview = Runtime.setGameStyleConnectionPreview,
	AutoFitBlueprintToCharacter = Runtime.autoFitBlueprintToCharacter,
	Validate = validatePreviews,
	Build = buildBlueprint,
	CancelBuild = Runtime.requestBuildCancel,
	Clear = clearPreview,
	CaptureNextPlacement = captureNextPlacement,
	CancelPlacementScan = Runtime.cancelPlacementScan,
	RestoreRememberedCapture = Runtime.restoreCaptureProfile,
	UseMyPosition = useMyPosition,
	SetPollutionRemover = Runtime.setPollutionRemover,
	SetPollutionSpoofValue = Runtime.setPollutionSpoofValue,
	SetPollutionSpoofEnabled = Runtime.setPollutionSpoofEnabled,
	SetPollutionSpoof = Runtime.setPollutionSpoof,
	ForceCleanupPollutionSpoof = Runtime.forceCleanupPollutionSpoof,
	LoadBlueprintText = loadBlueprintText,
	SetBuildDelaySeconds = setBuildDelaySeconds,
	ApplyLayoutSettings = applyLayoutSettings,
	SaveBlueprint = saveGameToJSON,
	LoadBlueprintSave = loadGameFromJSON,
	ListBlueprintSaves = listGameSaves,
	EnsureSaveFolders = ensureSaveFolders,
	ArmDuplicateSelection = Runtime.armDuplicateWorldClick,
	StartDuplicateSelecting = Runtime.startDuplicateSelecting,
	StopDuplicateSelecting = Runtime.stopDuplicateSelecting,
	ArmDuplicateBoxSelection = Runtime.armDuplicateMarquee,
	SetDuplicateDestination = Runtime.setDuplicateDestination,
	SetDuplicateRotation = Runtime.setDuplicateRotation,
	AutoFitDuplicateToCharacter = Runtime.autoFitDuplicateToCharacter,
	PreviewDuplicate = Runtime.previewDuplicate,
	BuildDuplicate = Runtime.buildDuplicate,
	BuildDuplicateExportDocument = Runtime.buildDuplicateExportDocument,
	ExportDuplicateJSON = Runtime.exportDuplicateJSON,
	-- Public cleanup cannot receive the internal force flag. Only Destroy and a
	-- verified no-progress reinjection may bypass Resume/audit preservation.
	ClearDuplicatePreview = function(silent)
		return Runtime.clearDuplicatePreview(silent, false)
	end,
	ClearDuplicateSelection = function(silent)
		return Runtime.resetDuplicateSelection(silent, false)
	end,
	CleanupDuplicateFeature = function(silent)
		return Runtime.cleanupDuplicateFeature(silent, false)
	end,
	CancelActiveWatches = Runtime.stopAllBuildWatches,
	ReleasePlacedRegistry = Runtime.releasePlacedRegistry,
	ReleaseConnectionDecorationRegistry = Runtime.releaseConnectionDecorationRegistry,
}

function API.SetOrigin(x, z)
	local applied, message = applyLayoutSettings(x, z, State.layoutRotation, true)
	assert(applied, message)
	return State.originX, State.originZ
end

function API.SetLayoutRotation(rotation)
	local applied, message = applyLayoutSettings(State.originX, State.originZ, rotation, true)
	assert(applied, message)
	return State.layoutRotation
end

function API.ApplySetupOptions(options, silent)
	if type(options) ~= "table" then
		return false, "Setup options must be a table."
	elseif State.building then
		return false, "Wait for the active build to finish before applying setup options."
	elseif State.autoFitInProgress then
		return false, Runtime.autoFitBusyReason()
	end
	local delay = finiteNumber(options.ActionDelay)
	local quality = tostring(options.PipeQuality or "")
	if not delay or delay < 0 or delay > 30 then
		return false, "ActionDelay must be from 0 to 30 seconds."
	elseif quality ~= "Good" and quality ~= "Rusty" then
		return false, "PipeQuality must be Good or Rusty."
	elseif type(options.SmartTurn) ~= "boolean"
		or type(options.AutoPlumb) ~= "boolean"
		or type(options.GameStylePreview) ~= "boolean"
	then
		return false, "SmartTurn, AutoPlumb, and GameStylePreview must be booleans."
	end
	local delayOK, delayError = setBuildDelaySeconds(delay, true, true)
	if not delayOK then
		return false, delayError
	end
	local qualityOK, qualityError = setAutoPlumbQuality(quality, true)
	if not qualityOK then
		return false, qualityError
	end
	Runtime.setSmartTurnEnabled(options.SmartTurn, true)
	Runtime.setAutoPlumbEnabled(options.AutoPlumb, true)
	Runtime.setGameStyleConnectionPreview(options.GameStylePreview, true)
	if not silent then
		notify("Setup applied", "Placement, plumbing, and preview defaults are ready.", 6)
	end
	return true
end

local environment = type(getgenv) == "function" and getgenv() or _G
Runtime.bootstrapConfig = type(environment.IndustrialistBootstrapConfig) == "table"
	and environment.IndustrialistBootstrapConfig
	or {}
Runtime.bootstrapSettings = type(Runtime.bootstrapConfig.Settings) == "table"
	and Runtime.bootstrapConfig.Settings
	or Runtime.bootstrapConfig
local previousAPI = environment.IndustrialistBlueprintPlacer
local previousRayfieldForRetirement

-- Re-executing the file is not permission to erase a partial server build. Keep
-- the old API/UI alive when it owns a committed or uncertain duplicate so its
-- exact Build/Resume history remains the single source of truth.
if type(previousAPI) == "table" and type(previousAPI.State) == "table" then
	local previousState = previousAPI.State
	local previousDuplicate = previousState.duplicate
	local previousResumeReason
	if previousState.building == true or previousState.buildRemoteAttempted == true then
		previousResumeReason = "the previous Industrialist build still has an active or settling server action"
	elseif type(previousDuplicate) == "table" then
		if previousDuplicate.connectionAuditInProgress == true then
			previousResumeReason = "the previous duplicate is still auditing its exact pipe/wire graph"
		end
		for _, preview in ipairs(type(previousDuplicate.previews) == "table" and previousDuplicate.previews or {}) do
			if preview.built == true then
				previousResumeReason = "the previous duplicate has committed placement progress"
				break
			elseif preview.recoveryKnownModels ~= nil then
				previousResumeReason = "the previous duplicate has an uncertain placement baseline awaiting safe Resume"
				break
			end
		end
		if not previousResumeReason then
			for _, plan in ipairs(type(previousDuplicate.connections) == "table" and previousDuplicate.connections or {}) do
				if plan.built == true then
					previousResumeReason = "the previous duplicate has committed pipe/wire progress"
					break
				end
			end
		end
	end
	if previousResumeReason then
		local message = "Reinjection refused because " .. previousResumeReason
			.. ". Use the existing DUPLICATE NOW button to Resume Remaining, or its Destroy button to explicitly abandon that audit state before injecting again."
		warn(PREFIX .. message)
		pcall(function()
			if previousDuplicate and previousDuplicate.statusParagraph then
				previousDuplicate.statusParagraph:Set({
					Title = "Duplicate status",
					Content = message,
				})
			end
		end)
		pcall(function()
			if previousState.rayfield then
				previousState.rayfield:Notify({
					Title = "Resume state preserved",
					Content = message,
					Duration = 10,
				})
			end
		end)
		return previousAPI
	end
end

if type(environment.__IndustrialistBlueprintCaptureController) == "table"
	and environment.__IndustrialistBlueprintCaptureController.Installed == true
	and environment.__IndustrialistBlueprintCaptureController.Version == Runtime.CaptureHookVersion
then
	environment.__IndustrialistBlueprintCaptureController.Disabled = false
	environment.__IndustrialistBlueprintCaptureController.State = State
	environment.__IndustrialistBlueprintCaptureController.RemoteSpecs = REMOTE_SPECS
	environment.__IndustrialistBlueprintCaptureController.ConnectionRemotes = {
		[PipeBind] = "Pipe",
		[WireBind] = "Wire",
	}
	environment.__IndustrialistBlueprintCaptureController.RecordConnection = Runtime.rememberKnownConnection
	environment.__IndustrialistBlueprintCaptureController.BeginConnectionWatch = Runtime.beginConnectionWatch
	environment.__IndustrialistBlueprintCaptureController.StopConnectionWatch = Runtime.stopConnectionWatch
	environment.__IndustrialistBlueprintCaptureController.RecordVerifiedConnection = Runtime.recordVerifiedManualConnection
	environment.__IndustrialistBlueprintCaptureController.SnapshotPlacedModels = Runtime.authoritativePlacedSnapshot
	environment.__IndustrialistBlueprintCaptureController.ReportPlacementRejected = Runtime.reportCapturedPlacementRejection
	State.hookInstalled = true
end
local restoredOrigin = false
local previousRecordingWasActive = false
local restoredPollutionSpoof = false
local restoredBlueprintLoaded = false
if type(previousAPI) == "table" and type(previousAPI.State) == "table" then
	local previousState = previousAPI.State
	local restoredCaptureGeneration = (tonumber(previousState.captureGeneration) or 0) + 1
	-- Invalidate a yielded verifier from the previous injection before reusing
	-- its already-verified packet in this script instance.
	previousState.captureGeneration = restoredCaptureGeneration
	State.captureGeneration = restoredCaptureGeneration
	previousState.destroyed = true
	previousState.cancelRequested = true
	previousState.captureArmed = false
	previousState.pendingCapture = nil
	previousState.captureInFlight = false
	previousState.captureInFlightGeneration = nil
	-- The previous Rayfield object remains reachable here solely so the new
	-- runtime can retire it below. Detach every old callback-facing handle now:
	-- a yielded callback from the old generation must not update, notify, or
	-- clear world previews owned by this accepted reinjection.
	previousRayfieldForRetirement = previousState.rayfield or environment.Rayfield
	previousState.uiGeneration = (tonumber(previousState.uiGeneration) or 0) + 1
	previousState.rayfield = nil
	previousState.interface = nil
	previousState.statusParagraph = nil
	previousState.blueprintParagraph = nil
	previousState.blueprintInputSync = nil
	previousState.originXInput = nil
	previousState.originZInput = nil
	previousState.layoutRotationInput = nil
	if type(previousState.duplicate) == "table" then
		previousState.duplicate.statusParagraph = nil
		previousState.duplicate.exportStatusParagraph = nil
	end
	if type(previousState.pollutionSpoof) == "table" then
		previousState.pollutionSpoof.input = nil
		previousState.pollutionSpoof.toggle = nil
		previousState.pollutionSpoof.statusParagraph = nil
	end
	if previousState.runtimePumpConnection then
		pcall(function()
			previousState.runtimePumpConnection:Disconnect()
		end)
		previousState.runtimePumpConnection = nil
	end
	previousRecordingWasActive = previousState.recordingPlumbing == true
	if type(previousState.pollutionSpoof) == "table" then
		local restoredValue = Runtime.parsePollutionSpoofValue(previousState.pollutionSpoof.targetValue)
		if restoredValue then
			State.pollutionSpoof.targetValue = restoredValue
			State.pollutionSpoof.draftText = Runtime.formatPollutionSpoofValue(restoredValue)
		end
		restoredPollutionSpoof = previousState.pollutionSpoof.enabled == true
	elseif type(previousState.pollutionRemover) == "table"
		and previousState.pollutionRemover.enabled == true
	then
		-- One-time migration from the old clean-effects toggle.
		State.pollutionSpoof.targetValue = 0
		State.pollutionSpoof.draftText = "0"
		restoredPollutionSpoof = true
	end
	restoredBlueprintLoaded = previousState.blueprintLoaded == true
	previousState.recordingPlumbing = false
	if tonumber(previousState.originX) and tonumber(previousState.originZ) then
		setBlueprintOrigin(previousState.originX, previousState.originZ)
		restoredOrigin = true
	end
	if finiteNumber(previousState.layoutRotation) then
		setLayoutRotation(previousState.layoutRotation)
	end
	local previousCaptureSource = previousState.captured
	local previousScanSource = previousState
	if previousState.scanComplete ~= true
		and type(previousState.captureFallback) == "table"
		and type(previousState.captureFallback.captured) == "table"
		and previousState.captureFallback.scanComplete == true
	then
		previousCaptureSource = previousState.captureFallback.captured
		previousScanSource = previousState.captureFallback
	end
	if type(previousCaptureSource) == "table" then
		local decodeOK, restoredCapture = pcall(Runtime.decodeCapturedPlacement, previousCaptureSource)
		if decodeOK and restoredCapture then
			restoredCapture.Generation = State.captureGeneration
			State.captured = restoredCapture
			State.scanComplete = previousScanSource.scanComplete == true
			State.scanMode = tostring(previousScanSource.scanMode or "None")
			State.captureRemembered = previousScanSource.captureRemembered == true
			if type(previousScanSource.scanMatchedEntry) == "table" then
				State.scanMatchedEntry = {
					Kind = previousScanSource.scanMatchedEntry.Kind,
					Index = previousScanSource.scanMatchedEntry.Index,
					Category = previousScanSource.scanMatchedEntry.Category,
					Name = previousScanSource.scanMatchedEntry.Name,
				}
			end
			if typeof(previousScanSource.scanPlacedModel) == "Instance"
				and previousScanSource.scanPlacedModel.Parent
			then
				State.scanPlacedModel = previousScanSource.scanPlacedModel
			end
		end
	end
	if restoredBlueprintLoaded then
		State.blueprintText = tostring(previousState.blueprintText or "")
		State.loadedBlueprintText = previousState.loadedBlueprintText
		State.blueprintLoaded = true
		State.blueprintDirty = previousState.blueprintDirty == true
	end
	if previousState.delayExplicit == true and finiteNumber(previousState.delaySeconds) then
		setBuildDelaySeconds(previousState.delaySeconds, true, true)
	end
	if previousState.autoPlumbQuality == "Good" or previousState.autoPlumbQuality == "Rusty" then
		State.autoPlumbQuality = previousState.autoPlumbQuality
	end
	if previousState.autoPlumbMode == "Off"
		or previousState.autoPlumbMode == "Routes"
		or previousState.autoPlumbMode == "Automatic"
	then
		State.autoPlumbMode = previousState.autoPlumbMode
	end
	if type(previousState.smartTurnEnabled) == "boolean" then
		State.smartTurnEnabled = previousState.smartTurnEnabled
	end
	if finiteNumber(previousState.autoFitClearance) then
		State.autoFitClearance = math.clamp(previousState.autoFitClearance, 0, 8)
	end
	if type(previousState.gameStyleConnectionPreview) == "boolean" then
		State.gameStyleConnectionPreview = previousState.gameStyleConnectionPreview
	end
	Runtime.restoreKnownConnections(previousState.knownConnections)
	Runtime.restoreCompleteConnectionModels(previousState.completeConnectionModels)
	Runtime.restorePhysicalPlumbingModels(previousState.physicalPlumbingModels)
end

-- The guided entry script may hand off only these allowlisted options. Every
-- value goes through the same validator as the Settings tab.
do
	if Runtime.bootstrapSettings.ActionDelay ~= nil then
		pcall(setBuildDelaySeconds, Runtime.bootstrapSettings.ActionDelay, true, true)
	end
	if Runtime.bootstrapSettings.PipeQuality ~= nil then
		pcall(setAutoPlumbQuality, Runtime.bootstrapSettings.PipeQuality, true)
	end
	if Runtime.bootstrapSettings.SmartTurn ~= nil then
		Runtime.setSmartTurnEnabled(Runtime.bootstrapSettings.SmartTurn == true, true)
	end
	if Runtime.bootstrapSettings.AutoFitClearance ~= nil then
		pcall(Runtime.setAutoFitClearance, Runtime.bootstrapSettings.AutoFitClearance, true)
	end
	if Runtime.bootstrapSettings.AutoPlumb ~= nil then
		Runtime.setAutoPlumbEnabled(Runtime.bootstrapSettings.AutoPlumb == true, true)
	end
	if Runtime.bootstrapSettings.GameStylePreview ~= nil then
		Runtime.setGameStyleConnectionPreview(Runtime.bootstrapSettings.GameStylePreview == true, true)
	end
end
if restoredBlueprintLoaded and type(previousAPI) == "table" then
	if type(previousAPI.Blueprint) == "table" then
		replaceArray(Blueprint, previousAPI.Blueprint, copyPlacementEntry)
	end
	local savedPlacements
	local savedLinks
	if type(previousAPI.State.sourceAuthoredPlumbing) == "table"
		and type(previousAPI.State.sourceAuthoredPipeLinks) == "table"
	then
		savedPlacements = previousAPI.State.sourceAuthoredPlumbing
		savedLinks = previousAPI.State.sourceAuthoredPipeLinks
	elseif previousRecordingWasActive
		and type(previousAPI.State.recordingBackupPlacements) == "table"
		and type(previousAPI.State.recordingBackupLinks) == "table"
	then
		savedPlacements = previousAPI.State.recordingBackupPlacements
		savedLinks = previousAPI.State.recordingBackupLinks
	else
		savedPlacements = type(previousAPI.AuthoredPlumbing) == "table" and previousAPI.AuthoredPlumbing or {}
		savedLinks = type(previousAPI.AuthoredPipeLinks) == "table" and previousAPI.AuthoredPipeLinks or {}
	end
	replaceArray(State.sourceAuthoredPlumbing, savedPlacements, copyPlacementEntry)
	replaceArray(State.sourceAuthoredPipeLinks, savedLinks, copyPipeLinkEntry)
	replaceArray(AuthoredPlumbing, State.sourceAuthoredPlumbing, copyPlacementEntry)
	replaceArray(AuthoredPipeLinks, State.sourceAuthoredPipeLinks, copyPipeLinkEntry)
	if type(previousAPI.AutoPlumbRoutes) == "table" then
		replaceArray(AutoPlumb, previousAPI.AutoPlumbRoutes, copyAutoPlumbRoute)
	end
	if type(previousAPI.Wiring) == "table" then
		replaceArray(Wiring, previousAPI.Wiring, copyPipeLinkEntry)
	end
	if State.captured and not State.scanComplete then
		calibrateCapturedScan(State.captured)
	end
end
if type(previousAPI) == "table" then
	if type(previousAPI.CancelActiveWatches) == "function" then
		pcall(previousAPI.CancelActiveWatches)
	end
	if type(previousAPI.ReleasePlacedRegistry) == "function" then
		pcall(previousAPI.ReleasePlacedRegistry)
	end
	if type(previousAPI.ReleaseConnectionDecorationRegistry) == "function" then
		pcall(previousAPI.ReleaseConnectionDecorationRegistry)
	end
	if type(previousAPI.StopManualPlacement) == "function" then
		pcall(previousAPI.StopManualPlacement, true)
	end
	if type(previousAPI.ClearManualPlumbingGuides) == "function" then
		pcall(previousAPI.ClearManualPlumbingGuides)
	end
	if type(previousAPI.ForceCleanupPollutionSpoof) == "function" then
		pcall(previousAPI.ForceCleanupPollutionSpoof, true, "Reinjection restored live pollution.")
	elseif type(previousAPI.SetPollutionSpoofEnabled) == "function" then
		pcall(previousAPI.SetPollutionSpoofEnabled, false, true)
	elseif type(previousAPI.SetPollutionRemover) == "function" then
		pcall(previousAPI.SetPollutionRemover, false, true)
	end
	if type(previousAPI.CleanupDuplicateFeature) == "function" then
		pcall(previousAPI.CleanupDuplicateFeature, true, true)
	end
end
-- Standard machine/plumbing ghosts belong to the previous state just as much
-- as its duplicate ghosts. A reinjection starts with empty preview arrays, so
-- keeping the old folder would leave unowned, misleading models in the world.
do
	local oldPreviewFolder = workspace:FindFirstChild("__IndustrialistBlueprintPreview")
	if oldPreviewFolder and oldPreviewFolder:IsA("Folder") then
		oldPreviewFolder:ClearAllChildren()
	end
end
-- Sweep a shade orphaned by an older/partial injection even when that older
-- controller incorrectly reported itself disabled.
pcall(Runtime.forceCleanupPollutionSpoof, true, "Reinjection pollution cleanup complete.")
if not State.captured and type(Runtime.restoreCaptureProfile) == "function" then
	pcall(Runtime.restoreCaptureProfile, true)
end
environment.IndustrialistBlueprintPlacer = API

function API.Destroy()
	-- A delayed button/callback from a retired generation must never tear down a
	-- newer injection that now owns the shared environment.
	local registeredAPI = environment.IndustrialistBlueprintPlacer
	if registeredAPI ~= nil and registeredAPI ~= API then
		return true
	end
	local wasDestroyed = State.destroyed
	State.destroyed = true
	State.uiGeneration += 1
	State.autoFitGeneration += 1
	State.autoFitInProgress = false
	State.autoFitMode = nil
	-- Pollution rollback runs before every other teardown phase and even on a
	-- repeated Destroy call. This makes cleanup independent of toggle/UI state.
	pcall(
		Runtime.forceCleanupPollutionSpoof,
		true,
		"Script destroyed; all client pollution changes were removed."
	)
	if wasDestroyed then
		return true
	end
	State.cancelRequested = true
	State.captureGeneration += 1
	State.captureArmed = false
	State.pendingCapture = nil
	State.captureProcessing = false
	State.captureInFlight = false
	State.captureInFlightGeneration = nil
	State.replaying = false
	Runtime.stopAllBuildWatches()
	Runtime.releasePlacedRegistry()
	Runtime.releaseConnectionDecorationRegistry()
	local captureController = environment.__IndustrialistBlueprintCaptureController
	if type(captureController) == "table" and captureController.State == State then
		Runtime.disableCaptureController(captureController)
	end
	if State.runtimePumpConnection then
		pcall(function()
			State.runtimePumpConnection:Disconnect()
		end)
		State.runtimePumpConnection = nil
	end
	Runtime.cleanupDuplicateFeature(true, true)
	for _, folderName in ipairs({ "__IndustrialistBlueprintPreview", Runtime.DuplicatePreviewFolder }) do
		local folder = workspace:FindFirstChild(folderName)
		if folder and folder:IsA("Folder") then
			folder:Destroy()
		end
	end
	State.previews = {}
	State.authoredPlacementPreviews = {}
	State.authoredLinkPreviews = {}
	State.connectionPreviews = {}
	State.duplicate.previews = {}
	State.duplicate.connections = {}
	for template, cachedGhost in pairs(State.ghostTemplateCache) do
		if cachedGhost then
			cachedGhost:Destroy()
		end
		State.ghostTemplateCache[template] = nil
	end
	for kind, donor in pairs(State.connectionPreviewDonorCache) do
		if donor then
			donor:Destroy()
		end
		State.connectionPreviewDonorCache[kind] = nil
	end
	-- These caches are valid for one immutable Buildings catalog/runtime only.
	-- Drop their catalog references explicitly even if a caller retains API.State
	-- after Destroy.
	State.exactTemplateCache = {}
	State.templateBaseTransformCache = setmetatable({}, { __mode = "k" })
	State.connectionConnectorCache = setmetatable({}, { __mode = "k" })

	local rayfield = State.rayfield or environment.Rayfield
	local legacyInterface = environment.IndustrialistBlueprintUI
	State.rayfield = nil
	State.interface = nil
	State.statusParagraph = nil
	State.blueprintParagraph = nil
	State.duplicate.statusParagraph = nil
	State.duplicate.exportStatusParagraph = nil
	State.pollutionSpoof.input = nil
	State.pollutionSpoof.toggle = nil
	State.pollutionSpoof.statusParagraph = nil
	if environment.IndustrialistBlueprintPlacer == API then
		environment.IndustrialistBlueprintPlacer = nil
	end
	environment.IndustrialistBlueprintUI = nil
	if environment.Rayfield == rayfield then
		environment.Rayfield = nil
	end
	print(PREFIX .. "Destroy requested: builds cancelled, hooks disarmed, previews removed, UI closing")
	-- Rayfield notifications own delayed animation tasks. Hide immediately, then
	-- retire after their longest possible callback so destroying the window from
	-- its own button cannot leave an ElementIndicator/notification coroutine error.
	if legacyInterface ~= nil and legacyInterface ~= rayfield then
		Runtime.retireInterfaceObject(legacyInterface, 1)
	end
	if rayfield ~= nil then
		Runtime.retireInterfaceObject(rayfield, 12)
	end
	return true
end

if not restoredOrigin then
	pcall(function()
		local character = LocalPlayer.Character
		local root = character and (character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart)
		if root then
			setBlueprintOrigin(root.Position.X, root.Position.Z)
		end
	end)
end

-- Production interface: keep the engine's strict verification, plumbing, and
-- recovery machinery, while presenting only the decisions needed in normal use.
function Runtime.normalizedSHA256(value)
	return tostring(value or ""):lower():gsub("^sha256:", ""):gsub("[^%x]", "")
end

function Runtime.executorSHA256(source)
	local candidates = {}
	for _, root in ipairs({ environment, _G }) do
		if type(root) == "table" then
			if type(root.sha256) == "function" then
				table.insert(candidates, root.sha256)
			end
			local cryptValue = root.crypt
			if type(cryptValue) == "table" and type(cryptValue.hash) == "function" then
				table.insert(candidates, cryptValue.hash)
			end
			local synValue = root.syn
			if type(synValue) == "table"
				and type(synValue.crypt) == "table"
				and type(synValue.crypt.hash) == "function"
			then
				table.insert(candidates, synValue.crypt.hash)
			end
		end
	end
	for _, hashFunction in ipairs(candidates) do
		for _, arguments in ipairs({ { source, "sha256" }, { source } }) do
			local ok, result = pcall(hashFunction, table.unpack(arguments))
			local normalized = ok and Runtime.normalizedSHA256(result) or ""
			if #normalized == 64 then
				return normalized
			end
		end
	end
	return nil
end

function Runtime.loadPinnedRayfield(loader)
	local requestOK, source = pcall(function()
		return game:HttpGet(Config.RayfieldURL)
	end)
	if not requestOK or type(source) ~= "string" then
		return nil, "Pinned Rayfield download failed: " .. tostring(source)
	elseif #source < 10000 or #source > 500000 then
		return nil, string.format("Pinned Rayfield returned an unexpected %d bytes.", #source)
	end
	local expectedHash = Runtime.normalizedSHA256(Config.RayfieldSHA256)
	local actualHash = Runtime.executorSHA256(source)
	if actualHash and actualHash ~= expectedHash then
		return nil, string.format(
			"Pinned Rayfield SHA-256 mismatch (expected %s, received %s).",
			expectedHash,
			actualHash
		)
	elseif actualHash then
		log("Verified pinned Rayfield SHA-256 %s", actualHash)
	else
		-- The URL contains the exact reviewed 40-hex Git object. Executors with
		-- crypt.hash receive a second SHA-256 check; others still never use a
		-- mutable branch, tag, redirect, or latest-release URL.
		log("Executor has no SHA-256 API; using exact pinned Rayfield Git object.")
	end
	local compileOK, chunk, compileError = pcall(loader, source, "@industrialist/vendor/rayfield.lua")
	if not compileOK or type(chunk) ~= "function" then
		local firstError = compileOK and compileError or chunk
		local fallbackOK, fallbackChunk, fallbackError = pcall(loader, source)
		if fallbackOK and type(fallbackChunk) == "function" then
			chunk = fallbackChunk
		else
			return nil, "Pinned Rayfield did not compile: "
				.. tostring(firstError or fallbackError or fallbackChunk or "unknown error")
		end
	end
	local runOK, rayfield = pcall(chunk)
	if not runOK or type(rayfield) ~= "table" then
		return nil, "Pinned Rayfield failed to start: " .. tostring(rayfield)
	end
	return rayfield
end

function Runtime.createRayfieldInterfaceUnsafe()
	if State.destroyed then
		return false, "The script has been destroyed; execute it again to restart."
	end
	State.uiGeneration += 1
	local uiGeneration = State.uiGeneration
	local previousLegacyInterface = environment.IndustrialistBlueprintUI
	if previousLegacyInterface ~= nil then
		Runtime.retireInterfaceObject(previousLegacyInterface, 1)
	end
	environment.IndustrialistBlueprintUI = nil
	local previousRayfield = previousRayfieldForRetirement or environment.Rayfield
	previousRayfieldForRetirement = nil
	if previousRayfield ~= nil and previousRayfield ~= previousLegacyInterface then
		Runtime.retireInterfaceObject(previousRayfield, 12)
	end
	environment.Rayfield = nil
	State.rayfield = nil
	State.interface = nil

	local loader = loadstring
	if type(loader) ~= "function" then
		return false, "Executor does not expose loadstring for the Rayfield interface."
	end
	local Rayfield, rayfieldError = Runtime.loadPinnedRayfield(loader)
	if not Rayfield then
		return false, rayfieldError
	end
	if State.destroyed
		or State.uiGeneration ~= uiGeneration
		or environment.IndustrialistBlueprintPlacer ~= API
	then
		Runtime.retireInterfaceObject(Rayfield, 0)
		return false, "A newer interface request replaced this one while Rayfield was loading."
	end
	local function uiIsCurrent()
		return not State.destroyed
			and State.uiGeneration == uiGeneration
			and environment.IndustrialistBlueprintPlacer == API
			and State.rayfield == Rayfield
	end
	State.rayfield = Rayfield
	environment.Rayfield = Rayfield
	local windowOK, Window = pcall(function()
		return Rayfield:CreateWindow({
			Name = "Industrialist",
			Icon = 0,
			LoadingTitle = "Industrialist Factory Tools",
			LoadingSubtitle = "Verified placement • plumbing • power",
			ShowText = "Industrialist",
			Theme = "DarkBlue",
			ToggleUIKeybind = "K",
			DisableRayfieldPrompts = false,
			DisableBuildWarnings = false,
			ConfigurationSaving = { Enabled = false },
			KeySystem = false,
		})
	end)
	if not windowOK or type(Window) ~= "table" then
		Runtime.retireInterfaceObject(Rayfield, 0)
		if State.rayfield == Rayfield then
			State.rayfield = nil
		end
		if environment.Rayfield == Rayfield then
			environment.Rayfield = nil
		end
		return false, "Rayfield window failed: " .. tostring(Window)
	end
	if not uiIsCurrent() then
		Runtime.retireInterfaceObject(Rayfield, 0)
		return false, "A newer interface request replaced this one while its window was opening."
	end
	State.interface = Window

	local PlacerTab = Window:CreateTab("Placer", 0)
	local DuplicatorTab = Window:CreateTab("Duplicator", 0)
	local PollutionTab = Window:CreateTab("Pollution", 0)
	local SettingsTab = Window:CreateTab("Settings", 0)

	local function firstOption(value)
		return type(value) == "table" and value[1] or value
	end
	local function currentValue(element, fallback)
		local ok, value = pcall(function()
			return element.CurrentValue
		end)
		return ok and value ~= nil and value or fallback
	end
	local function guardedAction(title, callback)
		return function(...)
			if not uiIsCurrent() then
				return
			elseif State.autoFitInProgress then
				notify("Auto-fit in progress", Runtime.autoFitBusyReason(), 6)
				return
			end
			local arguments = table.pack(...)
			local ok, result, detail = pcall(function()
				return callback(table.unpack(arguments, 1, arguments.n))
			end)
			if not uiIsCurrent() then
				return
			elseif not ok then
				warn(PREFIX .. title .. " failed: " .. tostring(result))
				notify(title .. " failed", tostring(result), 9)
			elseif result == false then
				notify(title .. " stopped", tostring(detail or "The action could not be completed."), 8)
			end
		end
	end
	local function runBuildInBackground(title, callback)
		task.spawn(function()
			local ok, result, detail = pcall(callback)
			if not uiIsCurrent() then
				return
			elseif not ok then
				warn(PREFIX .. title .. " failed: " .. tostring(result))
				notify(title .. " failed", tostring(result), 10)
			elseif result == false and detail then
				notify(title .. " stopped", tostring(detail), 10)
			end
		end)
		return true
	end

	PlacerTab:CreateSection("Blueprint")
	local BlueprintInput
	local setBlueprintInput
	local syncingBlueprintInput = false
	local function acceptBlueprintText(text)
		text = tostring(text or "")
		if text == State.blueprintText then
			return
		end
		State.blueprintText = text
		State.blueprintDirty = true
		if State.captured and State.scanComplete then
			State.scanMode = "PacketOnly"
		else
			State.scanComplete = false
			State.scanMode = "None"
		end
		State.scanMatchedEntry = nil
		clearPreview()
		updateBlueprintParagraph()
	end
	BlueprintInput = PlacerTab:CreateInput({
		Name = "Blueprint JSON",
		CurrentValue = State.blueprintText,
		PlaceholderText = "Paste blueprint JSON here",
		RemoveTextAfterFocusLost = false,
		Flag = "IndustrialistBlueprintJSON",
		Callback = function(text)
			if uiIsCurrent() and not syncingBlueprintInput then
				if State.autoFitInProgress then
					notify("JSON unchanged", Runtime.autoFitBusyReason(), 6)
					task.defer(function()
						if uiIsCurrent() and setBlueprintInput then
							setBlueprintInput(State.blueprintText)
						end
					end)
				else
					acceptBlueprintText(text)
				end
			end
		end,
	})
	setBlueprintInput = function(text)
		syncingBlueprintInput = true
		BlueprintInput:Set(tostring(text or ""))
		syncingBlueprintInput = false
	end
	State.blueprintInputSync = setBlueprintInput
	local function ensureBlueprintLoaded()
		acceptBlueprintText(currentValue(BlueprintInput, State.blueprintText))
		local loaded, loadError = ensurePastedBlueprintLoaded()
		if loaded then
			setBlueprintInput(State.blueprintText)
		end
		return loaded, loadError
	end
	PlacerTab:CreateButton({
		Name = "Move Build To Me",
		Callback = guardedAction("Move build", function()
			local loaded, loadError = ensureBlueprintLoaded()
			if not loaded then
				return false, loadError or "Paste valid blueprint JSON first."
			end
			return Runtime.autoFitBlueprintToCharacter(false)
		end),
	})
	PlacerTab:CreateButton({
		Name = "Preview",
		Callback = guardedAction("Preview", function()
			local loaded, loadError = ensureBlueprintLoaded()
			if not loaded then
				return false, loadError or "Paste valid blueprint JSON first."
			end
			return previewAndValidate()
		end),
	})
	PlacerTab:CreateButton({
		Name = "Build",
		Callback = guardedAction("Build", function()
			local loaded, loadError = ensureBlueprintLoaded()
			if not loaded then
				return false, loadError or "Paste valid blueprint JSON first."
			end
			local hasPreview = #State.previews > 0
				or #State.authoredPlacementPreviews > 0
				or #State.connectionPreviews > 0
			if not hasPreview and not previewAndValidate() then
				return false, "Preview is not valid; inspect the red ghost or status message."
			end
			return runBuildInBackground("Build", buildBlueprint)
		end),
	})
	State.blueprintParagraph = PlacerTab:CreateParagraph({
		Title = "Ready",
		Content = "Paste JSON, move the build, preview it, then build.",
	})
	State.statusParagraph = State.blueprintParagraph

	DuplicatorTab:CreateSection("Select")
	DuplicatorTab:CreateButton({
		Name = "Start Selecting",
		Callback = guardedAction("Start selecting", Runtime.startDuplicateSelecting),
	})
	DuplicatorTab:CreateParagraph({
		Title = "Fast selection",
		Content = "While selecting, hold Shift and drag the blue box across a build. Selection stays active until you press Stop Selecting.",
	})
	DuplicatorTab:CreateButton({
		Name = "Stop Selecting",
		Callback = guardedAction("Stop selecting", function()
			return Runtime.stopDuplicateSelecting(false)
		end),
	})
	DuplicatorTab:CreateButton({
		Name = "Export JSON",
		Callback = guardedAction("Export JSON", Runtime.exportDuplicateJSON),
	})
	DuplicatorTab:CreateSection("Place Copy")
	DuplicatorTab:CreateButton({
		Name = "Move Base To Me",
		Callback = guardedAction("Move duplicate", function()
			return Runtime.autoFitDuplicateToCharacter(false)
		end),
	})
	DuplicatorTab:CreateButton({
		Name = "Preview",
		Callback = guardedAction("Duplicate preview", Runtime.previewDuplicate),
	})
	DuplicatorTab:CreateButton({
		Name = "Build",
		Callback = guardedAction("Duplicate build", function()
			if #State.duplicate.previews == 0 then
				local previewed, previewError = Runtime.previewDuplicate()
				if not previewed then
					return false, previewError
				end
			end
			return runBuildInBackground("Duplicate build", Runtime.buildDuplicate)
		end),
	})
	State.duplicate.statusParagraph = DuplicatorTab:CreateParagraph({
		Title = "Duplicate status",
		Content = "Press Start Selecting, then click objects in the plot.",
	})
	State.duplicate.exportStatusParagraph = nil

	PollutionTab:CreateSection("Local Pollution")
	local PollutionInput = PollutionTab:CreateInput({
		Name = "Pollution %",
		CurrentValue = State.pollutionSpoof.draftText,
		PlaceholderText = "100 = 100%",
		RemoveTextAfterFocusLost = false,
		Flag = "IndustrialistPollutionPercent",
		Callback = function(text)
			if uiIsCurrent() and not State.pollutionSpoof.syncingControls then
				State.pollutionSpoof.draftText = tostring(text or "")
			end
		end,
	})
	State.pollutionSpoof.input = PollutionInput
	State.pollutionSpoof.toggle = nil
	PollutionTab:CreateButton({
		Name = "Apply",
		Callback = guardedAction("Apply pollution", function()
			local accepted, valueOrError = Runtime.setPollutionSpoofValue(
				currentValue(PollutionInput, State.pollutionSpoof.draftText),
				true
			)
			if not accepted then
				return false, valueOrError
			end
			return Runtime.setPollutionSpoofEnabled(true, false)
		end),
	})
	PollutionTab:CreateButton({
		Name = "Reset Pollution",
		Callback = guardedAction("Reset pollution", function()
			return Runtime.forceCleanupPollutionSpoof(
				false,
				"Pollution reset; Industrialist is showing the live value."
			)
		end),
	})
	State.pollutionSpoof.statusParagraph = PollutionTab:CreateParagraph({
		Title = State.pollutionSpoof.enabled and "Pollution applied" or "Live pollution",
		Content = State.pollutionSpoof.lastMessage,
	})

	SettingsTab:CreateSection("Placement")
	SettingsTab:CreateSlider({
		Name = "Action Delay",
		Range = { 0, 30 },
		Increment = 0.01,
		Suffix = " sec",
		CurrentValue = State.delaySeconds,
		Flag = "IndustrialistActionDelayProduction",
		Callback = guardedAction("Action delay", function(value)
			return setBuildDelaySeconds(value, true, true)
		end),
	})
	SettingsTab:CreateToggle({
		Name = "Smart Turn",
		CurrentValue = State.smartTurnEnabled,
		Flag = "IndustrialistSmartTurn",
		Callback = guardedAction("Smart Turn", function(enabled)
			return Runtime.setSmartTurnEnabled(enabled, false)
		end),
	})
	SettingsTab:CreateSlider({
		Name = "Auto-Fit Clearance",
		Range = { 0, 8 },
		Increment = 0.25,
		Suffix = " studs",
		CurrentValue = State.autoFitClearance,
		Flag = "IndustrialistAutoFitClearance",
		Callback = guardedAction("Auto-fit clearance", function(value)
			return Runtime.setAutoFitClearance(value, true)
		end),
	})
	SettingsTab:CreateSection("Plumbing")
	SettingsTab:CreateToggle({
		Name = "Smart Auto-Plumb",
		CurrentValue = State.autoPlumbMode == "Automatic",
		Flag = "IndustrialistAutoPlumb",
		Callback = guardedAction("Auto-Plumb", function(enabled)
			return Runtime.setAutoPlumbEnabled(enabled, false)
		end),
	})
	SettingsTab:CreateDropdown({
		Name = "Pipe Quality",
		Options = { "Good", "Rusty" },
		CurrentOption = { State.autoPlumbQuality },
		MultipleOptions = false,
		Flag = "IndustrialistPipeQualityProduction",
		Callback = guardedAction("Pipe quality", function(options)
			return setAutoPlumbQuality(firstOption(options), false)
		end),
	})
	SettingsTab:CreateToggle({
		Name = "Game-Style Connection Preview",
		CurrentValue = State.gameStyleConnectionPreview,
		Flag = "IndustrialistGameStylePreview",
		Callback = guardedAction("Connection preview", function(enabled)
			return Runtime.setGameStyleConnectionPreview(enabled, false)
		end),
	})
	SettingsTab:CreateSection("Setup & Safety")
	SettingsTab:CreateButton({
		Name = "Run Placement Setup Again",
		Callback = guardedAction("Placement setup", captureNextPlacement),
	})
	SettingsTab:CreateButton({
		Name = "Stop Active Build",
		Callback = guardedAction("Stop build", function()
			return Runtime.requestBuildCancel(false)
		end),
	})
	SettingsTab:CreateButton({
		Name = "Clear Previews",
		Callback = guardedAction("Clear previews", function()
			local cleared = clearPreview()
			local duplicateCleared = Runtime.clearDuplicatePreview(false)
			return cleared ~= false and duplicateCleared ~= false
		end),
	})
	SettingsTab:CreateButton({
		Name = "Destroy Script & UI",
		Callback = function()
			if uiIsCurrent() then
				API.Destroy()
			end
		end,
	})

	if not uiIsCurrent() then
		Runtime.retireInterfaceObject(Rayfield, 12)
		return false, "A newer interface replaced this one."
	end
	Runtime.updateDuplicateStatus()
	Runtime.installDuplicateShiftShortcut()
	updateBlueprintParagraph()
	ensureRuntimePump()
	local hookOK, hookError = installCaptureHook()
	if hookOK then
		log("Ready. Paste JSON or select a duplicate, preview, then build.")
		notify(
			"Industrialist ready",
			"Placer, Duplicator, Pollution, and Settings are ready. Press K to hide or show the UI.",
			7
		)
	else
		log("UI ready, but placement setup is unavailable: %s", hookError)
		notify("Placement setup unavailable", hookError, 10)
	end
	return true
end

function API.CreateRayfieldInterface()
	local expectedGeneration = State.uiGeneration + 1
	local callOK, result, detail = xpcall(Runtime.createRayfieldInterfaceUnsafe, function(errorValue)
		return tostring(errorValue)
	end)
	if callOK and result ~= false then
		return result, detail
	end
	-- If this call still owns the UI generation, retire every partial object it
	-- created. A newer generation is never touched by an older failed callback.
	if State.uiGeneration == expectedGeneration then
		local partialRayfield = State.rayfield
		State.uiGeneration += 1
		State.rayfield = nil
		State.interface = nil
		if environment.Rayfield == partialRayfield then
			environment.Rayfield = nil
		end
		if partialRayfield ~= nil then
			Runtime.retireInterfaceObject(partialRayfield, 0)
		end
	end
	if callOK then
		return false, tostring(detail or "Rayfield interface construction stopped.")
	end
	return false, "Rayfield interface construction failed safely: " .. tostring(result)
end

if Runtime.bootstrapConfig.DeferUI ~= true then
	local interfaceCallOK, interfaceResult, interfaceDetail = pcall(API.CreateRayfieldInterface)
	if not interfaceCallOK or interfaceResult == false then
		local reason = interfaceCallOK and interfaceDetail or interfaceResult
		warn(PREFIX .. "Rayfield interface construction failed: " .. tostring(reason))
	end
	if not interfaceCallOK then
		pcall(API.Destroy)
	end
end

return API
