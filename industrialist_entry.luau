-- Industrialist guided setup entry
--
-- This file never places an object. It observes and verifies one placement the
-- player performs normally, applies a small allowlisted setup profile, and then
-- opens the main Industrialist Blueprint Placer interface.
--
-- Optional executor configuration (set before running this entry):
-- getgenv().IndustrialistEntryConfig = {
--     MainLocalPath = "industrialist_blueprint_placer.luau",
--     MainURL = "https://raw.githubusercontent.com/OWNER/REPO/0123456789abcdef0123456789abcdef01234567/main.luau",
--     ExpectedMainSHA256 = "", -- optional for a full Git object; otherwise required
-- }

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
local environment = type(getgenv) == "function" and getgenv() or _G
local entryConfiguration = type(environment.IndustrialistEntryConfig) == "table"
	and environment.IndustrialistEntryConfig
	or {}

local ENTRY_VERSION = 1
local REQUIRED_MAIN_VERSION = "2.0.0-production"
local REQUIRED_CONTRACT_VERSION = "guided-entry-v2"
local REQUIRED_CAPTURE_HOOK_VERSION = "post-call-placement-v6"
local DEFAULT_LOCAL_PATH = "industrialist_blueprint_placer.luau"
local MAX_MAIN_BYTES = math.clamp(tonumber(entryConfiguration.MaxMainBytes) or 1500000, 100000, 5000000)
local MAIN_MARKER = "Industrialist Blueprint Placer"
local GUI_NAME = "__IndustrialistGuidedSetup"

local previousEntry = environment.IndustrialistEntry
if type(previousEntry) == "table" and type(previousEntry.Destroy) == "function" then
	pcall(previousEntry.Destroy, previousEntry, true)
end

local BootstrapConfig = type(environment.IndustrialistBootstrapConfig) == "table"
	and environment.IndustrialistBootstrapConfig
	or {}
BootstrapConfig.Format = "IndustrialistBootstrapConfig"
BootstrapConfig.Version = ENTRY_VERSION
BootstrapConfig.PlaceId = game.PlaceId
BootstrapConfig.GameId = game.GameId
BootstrapConfig.DeferUI = true
BootstrapConfig.SetupComplete = false
BootstrapConfig.Settings = type(BootstrapConfig.Settings) == "table" and BootstrapConfig.Settings or {}
environment.IndustrialistBootstrapConfig = BootstrapConfig

local Controller = {
	Version = ENTRY_VERSION,
	destroyed = false,
	generation = 1,
	connections = {},
	api = nil,
	scanGeneration = nil,
	previousCapture = nil,
	scanOwned = false,
	retryAction = nil,
	launching = false,
}
environment.IndustrialistEntry = Controller

local function track(connection)
	if connection then
		table.insert(Controller.connections, connection)
	end
	return connection
end

local function disconnect(connection)
	if connection then
		pcall(function()
			connection:Disconnect()
		end)
	end
end

local function executorFunction(name)
	for _, source in ipairs({ environment, _G }) do
		if type(source) == "table" then
			local ok, value = pcall(function()
				return source[name]
			end)
			if ok and type(value) == "function" then
				return value
			end
		end
	end
	return nil
end

local function validAPI(candidate)
	return type(candidate) == "table"
		and candidate.Ready == true
		and candidate.Version == REQUIRED_MAIN_VERSION
		and candidate.ContractVersion == REQUIRED_CONTRACT_VERSION
		and candidate.CaptureHookVersion == REQUIRED_CAPTURE_HOOK_VERSION
		and type(candidate.State) == "table"
		and candidate.State.destroyed ~= true
		and type(candidate.CaptureNextPlacement) == "function"
		and type(candidate.CancelPlacementScan) == "function"
		and type(candidate.ApplySetupOptions) == "function"
		and type(candidate.AutoFitBlueprintToCharacter) == "function"
		and type(candidate.AutoFitDuplicateToCharacter) == "function"
		and type(candidate.CreateRayfieldInterface) == "function"
end

local function new(className, properties, parent)
	local instance = Instance.new(className)
	for property, value in pairs(properties or {}) do
		instance[property] = value
	end
	instance.Parent = parent
	return instance
end

local COLORS = {
	backdrop = Color3.fromRGB(4, 9, 13),
	panel = Color3.fromRGB(16, 23, 29),
	panelSoft = Color3.fromRGB(22, 31, 38),
	panelRaised = Color3.fromRGB(28, 39, 47),
	border = Color3.fromRGB(54, 72, 83),
	text = Color3.fromRGB(239, 247, 242),
	muted = Color3.fromRGB(158, 176, 168),
	accent = Color3.fromRGB(74, 222, 128),
	accentDark = Color3.fromRGB(22, 101, 52),
	blue = Color3.fromRGB(96, 165, 250),
	warning = Color3.fromRGB(251, 191, 36),
	error = Color3.fromRGB(248, 113, 113),
}

local function corner(parent, radius)
	return new("UICorner", { CornerRadius = UDim.new(0, radius or 10) }, parent)
end

local function stroke(parent, color, transparency, thickness)
	return new("UIStroke", {
		Color = color or COLORS.border,
		Transparency = transparency or 0,
		Thickness = thickness or 1,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, parent)
end

local function padding(parent, left, right, top, bottom)
	return new("UIPadding", {
		PaddingLeft = UDim.new(0, left or 0),
		PaddingRight = UDim.new(0, right or left or 0),
		PaddingTop = UDim.new(0, top or left or 0),
		PaddingBottom = UDim.new(0, bottom or top or left or 0),
	}, parent)
end

local CoreGui = game:GetService("CoreGui")
local existingGui
pcall(function()
	existingGui = CoreGui:FindFirstChild(GUI_NAME)
end)
if existingGui then
	pcall(function()
		existingGui:Destroy()
	end)
end
local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui") or LocalPlayer:WaitForChild("PlayerGui")
local playerGuiCopy = playerGui:FindFirstChild(GUI_NAME)
if playerGuiCopy then
	playerGuiCopy:Destroy()
end
local Screen = new("ScreenGui", {
	Name = GUI_NAME,
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	DisplayOrder = 1000000,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}, nil)
local protectGui = executorFunction("protectgui")
if protectGui then
	pcall(protectGui, Screen)
end
local coreOK = pcall(function()
	Screen.Parent = CoreGui
end)
if not coreOK then
	Screen.Parent = playerGui
end
Controller.gui = Screen

local Backdrop = new("Frame", {
	Name = "Backdrop",
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = COLORS.backdrop,
	BackgroundTransparency = 0.24,
	BorderSizePixel = 0,
}, Screen)

local Panel = new("Frame", {
	Name = "SetupPanel",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(590, 570),
	BackgroundColor3 = COLORS.panel,
	BorderSizePixel = 0,
	ClipsDescendants = true,
}, Backdrop)
corner(Panel, 18)
stroke(Panel, COLORS.border, 0.05, 1.2)
new("UIGradient", {
	Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(20, 31, 38)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(12, 18, 23)),
	}),
	Rotation = 90,
}, Panel)

local Scale = new("UIScale", { Scale = 1 }, Panel)
local function updateScale()
	local camera = workspace.CurrentCamera
	local viewport = camera and camera.ViewportSize or Vector2.new(1280, 720)
	Scale.Scale = math.clamp(math.min((viewport.X - 28) / 590, (viewport.Y - 28) / 570), 0.64, 1)
end
updateScale()
if workspace.CurrentCamera then
	track(workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale))
end

local Header = new("Frame", {
	Name = "Header",
	Size = UDim2.new(1, 0, 0, 78),
	BackgroundTransparency = 1,
	Active = true,
}, Panel)

local Mark = new("Frame", {
	Position = UDim2.fromOffset(22, 19),
	Size = UDim2.fromOffset(40, 40),
	BackgroundColor3 = COLORS.accentDark,
	BorderSizePixel = 0,
}, Header)
corner(Mark, 12)
stroke(Mark, COLORS.accent, 0.35, 1)
new("TextLabel", {
	Size = UDim2.fromScale(1, 1),
	BackgroundTransparency = 1,
	Text = "I",
	TextColor3 = COLORS.accent,
	TextSize = 24,
	Font = Enum.Font.GothamBold,
}, Mark)

new("TextLabel", {
	Position = UDim2.fromOffset(76, 15),
	Size = UDim2.new(1, -140, 0, 28),
	BackgroundTransparency = 1,
	Text = "INDUSTRIALIST SETUP",
	TextColor3 = COLORS.text,
	TextSize = 19,
	TextXAlignment = Enum.TextXAlignment.Left,
	Font = Enum.Font.GothamBold,
}, Header)
new("TextLabel", {
	Position = UDim2.fromOffset(76, 42),
	Size = UDim2.new(1, -140, 0, 20),
	BackgroundTransparency = 1,
	Text = "Verified placement calibration",
	TextColor3 = COLORS.muted,
	TextSize = 13,
	TextXAlignment = Enum.TextXAlignment.Left,
	Font = Enum.Font.Gotham,
}, Header)

local CloseButton = new("TextButton", {
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -18, 0, 18),
	Size = UDim2.fromOffset(40, 40),
	BackgroundColor3 = COLORS.panelRaised,
	Text = "x",
	TextColor3 = COLORS.muted,
	TextSize = 18,
	Font = Enum.Font.GothamBold,
	AutoButtonColor = false,
	BorderSizePixel = 0,
}, Header)
corner(CloseButton, 11)
stroke(CloseButton, COLORS.border, 0.25, 1)

local StepBar = new("Frame", {
	Position = UDim2.fromOffset(22, 82),
	Size = UDim2.new(1, -44, 0, 46),
	BackgroundColor3 = COLORS.panelSoft,
	BorderSizePixel = 0,
}, Panel)
corner(StepBar, 12)
padding(StepBar, 12, 12, 8, 8)
new("UIListLayout", {
	FillDirection = Enum.FillDirection.Horizontal,
	HorizontalAlignment = Enum.HorizontalAlignment.Center,
	VerticalAlignment = Enum.VerticalAlignment.Center,
	Padding = UDim.new(0, 8),
	SortOrder = Enum.SortOrder.LayoutOrder,
}, StepBar)

local stepPills = {}
for index, label in ipairs({ "1  CORE", "2  PLACEMENT", "3  OPTIONS" }) do
	local pill = new("Frame", {
		LayoutOrder = index,
		Size = UDim2.new(1 / 3, -6, 1, 0),
		BackgroundColor3 = index == 1 and COLORS.accentDark or COLORS.panelRaised,
		BorderSizePixel = 0,
	}, StepBar)
	corner(pill, 8)
	local pillLabel = new("TextLabel", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Text = label,
		TextColor3 = index == 1 and COLORS.accent or COLORS.muted,
		TextSize = 11,
		Font = Enum.Font.GothamBold,
	}, pill)
	stepPills[index] = { Frame = pill, Label = pillLabel }
end

local function setStep(activeStep)
	for index, pill in ipairs(stepPills) do
		local complete = index < activeStep
		local active = index == activeStep
		pill.Frame.BackgroundColor3 = (complete or active) and COLORS.accentDark or COLORS.panelRaised
		pill.Label.TextColor3 = complete and Color3.fromRGB(187, 247, 208)
			or active and COLORS.accent
			or COLORS.muted
	end
end

local Pages = new("Frame", {
	Position = UDim2.fromOffset(22, 142),
	Size = UDim2.new(1, -44, 1, -212),
	BackgroundTransparency = 1,
}, Panel)

local Footer = new("Frame", {
	AnchorPoint = Vector2.new(0, 1),
	Position = UDim2.new(0, 22, 1, -16),
	Size = UDim2.new(1, -44, 0, 42),
	BackgroundColor3 = COLORS.panelSoft,
	BorderSizePixel = 0,
}, Panel)
corner(Footer, 11)
local FooterDot = new("Frame", {
	AnchorPoint = Vector2.new(0, 0.5),
	Position = UDim2.new(0, 14, 0.5, 0),
	Size = UDim2.fromOffset(9, 9),
	BackgroundColor3 = COLORS.blue,
	BorderSizePixel = 0,
}, Footer)
corner(FooterDot, 99)
local FooterText = new("TextLabel", {
	Position = UDim2.fromOffset(34, 0),
	Size = UDim2.new(1, -46, 1, 0),
	BackgroundTransparency = 1,
	Text = "Preparing setup...",
	TextColor3 = COLORS.muted,
	TextSize = 12,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextTruncate = Enum.TextTruncate.AtEnd,
	Font = Enum.Font.Gotham,
}, Footer)

local function setFooter(text, color)
	FooterText.Text = tostring(text)
	FooterDot.BackgroundColor3 = color or COLORS.blue
end

local function page(name)
	local frame = new("Frame", {
		Name = name,
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Visible = false,
	}, Pages)
	return frame
end

local LoadingPage = page("Loading")
local ScanPage = page("Placement")
local OptionsPage = page("Options")
local ErrorPage = page("Error")
local allPages = { LoadingPage, ScanPage, OptionsPage, ErrorPage }

local function showPage(target)
	for _, candidate in ipairs(allPages) do
		candidate.Visible = candidate == target
	end
end

local Spinner = new("Frame", {
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 38),
	Size = UDim2.fromOffset(62, 62),
	BackgroundTransparency = 1,
}, LoadingPage)
local SpinnerStroke = new("UIStroke", {
	Color = COLORS.accent,
	Thickness = 5,
	Transparency = 0.12,
}, Spinner)
corner(Spinner, 99)
new("UIGradient", {
	Color = ColorSequence.new(COLORS.accent, COLORS.panelSoft),
	Rotation = 0,
}, SpinnerStroke)

new("TextLabel", {
	Position = UDim2.fromOffset(0, 124),
	Size = UDim2.new(1, 0, 0, 32),
	BackgroundTransparency = 1,
	Text = "Loading placement core",
	TextColor3 = COLORS.text,
	TextSize = 23,
	Font = Enum.Font.GothamBold,
}, LoadingPage)
local LoadingDetail = new("TextLabel", {
	Position = UDim2.fromOffset(35, 166),
	Size = UDim2.new(1, -70, 0, 68),
	BackgroundTransparency = 1,
	Text = "Checking for a trusted local release...",
	TextColor3 = COLORS.muted,
	TextSize = 14,
	TextWrapped = true,
	TextYAlignment = Enum.TextYAlignment.Top,
	Font = Enum.Font.Gotham,
}, LoadingPage)

new("TextLabel", {
	Position = UDim2.fromOffset(0, 16),
	Size = UDim2.new(1, 0, 0, 24),
	BackgroundTransparency = 1,
	Text = "PLACEMENT SCAN ARMED",
	TextColor3 = COLORS.accent,
	TextSize = 12,
	Font = Enum.Font.GothamBold,
}, ScanPage)
new("TextLabel", {
	Position = UDim2.fromOffset(0, 48),
	Size = UDim2.new(1, 0, 0, 34),
	BackgroundTransparency = 1,
	Text = "Place one test object",
	TextColor3 = COLORS.text,
	TextSize = 25,
	Font = Enum.Font.GothamBold,
}, ScanPage)
new("TextLabel", {
	Position = UDim2.fromOffset(36, 92),
	Size = UDim2.new(1, -72, 0, 68),
	BackgroundTransparency = 1,
	Text = "Choose any inexpensive building, pump, or pipe and place it normally in clear space. After clicking, do not move your mouse until Success appears.",
	TextColor3 = COLORS.muted,
	TextSize = 14,
	TextWrapped = true,
	TextYAlignment = Enum.TextYAlignment.Top,
	Font = Enum.Font.Gotham,
}, ScanPage)
local ScanStatusCard = new("Frame", {
	Position = UDim2.fromOffset(28, 178),
	Size = UDim2.new(1, -56, 0, 74),
	BackgroundColor3 = COLORS.panelSoft,
	BorderSizePixel = 0,
}, ScanPage)
corner(ScanStatusCard, 12)
stroke(ScanStatusCard, COLORS.border, 0.2, 1)
local ScanPulse = new("Frame", {
	AnchorPoint = Vector2.new(0, 0.5),
	Position = UDim2.new(0, 18, 0.5, 0),
	Size = UDim2.fromOffset(12, 12),
	BackgroundColor3 = COLORS.warning,
	BorderSizePixel = 0,
}, ScanStatusCard)
corner(ScanPulse, 99)
local ScanStatusText = new("TextLabel", {
	Position = UDim2.fromOffset(48, 0),
	Size = UDim2.new(1, -64, 1, 0),
	BackgroundTransparency = 1,
	Text = "Waiting for your placement...",
	TextColor3 = COLORS.text,
	TextSize = 13,
	TextWrapped = true,
	TextXAlignment = Enum.TextXAlignment.Left,
	Font = Enum.Font.GothamMedium,
}, ScanStatusCard)

local function makeButton(parent, text, position, size, primary)
	local button = new("TextButton", {
		Position = position,
		Size = size,
		BackgroundColor3 = primary and COLORS.accentDark or COLORS.panelRaised,
		Text = text,
		TextColor3 = primary and Color3.fromRGB(220, 252, 231) or COLORS.text,
		TextSize = 13,
		Font = Enum.Font.GothamBold,
		AutoButtonColor = false,
		BorderSizePixel = 0,
	}, parent)
	corner(button, 10)
	stroke(button, primary and COLORS.accent or COLORS.border, primary and 0.45 or 0.2, 1)
	button:SetAttribute("EntryAccent", primary == true)
	local function accentStyle()
		return primary == true or button:GetAttribute("EntryAccent") == true
	end
	track(button.MouseEnter:Connect(function()
		if not Controller.destroyed then
			button.BackgroundColor3 = accentStyle()
				and Color3.fromRGB(27, 128, 65)
				or Color3.fromRGB(36, 50, 60)
		end
	end))
	track(button.MouseLeave:Connect(function()
		if not Controller.destroyed then
			button.BackgroundColor3 = accentStyle() and COLORS.accentDark or COLORS.panelRaised
		end
	end))
	return button
end

local RetryScanButton = makeButton(
	ScanPage,
	"RETRY SCAN",
	UDim2.new(0.5, -80, 1, -53),
	UDim2.fromOffset(160, 42),
	false
)

new("TextLabel", {
	Position = UDim2.fromOffset(0, 8),
	Size = UDim2.new(1, 0, 0, 30),
	BackgroundTransparency = 1,
	Text = "Placement verified",
	TextColor3 = COLORS.accent,
	TextSize = 23,
	Font = Enum.Font.GothamBold,
}, OptionsPage)
new("TextLabel", {
	Position = UDim2.fromOffset(0, 40),
	Size = UDim2.new(1, 0, 0, 22),
	BackgroundTransparency = 1,
	Text = "Choose your defaults, then open the main placer.",
	TextColor3 = COLORS.muted,
	TextSize = 13,
	Font = Enum.Font.Gotham,
}, OptionsPage)

local OptionsList = new("ScrollingFrame", {
	Position = UDim2.fromOffset(0, 76),
	Size = UDim2.new(1, 0, 1, -130),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	CanvasSize = UDim2.fromOffset(0, 0),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	ScrollBarThickness = 4,
	ScrollBarImageColor3 = COLORS.border,
	ScrollingDirection = Enum.ScrollingDirection.Y,
}, OptionsPage)
new("UIListLayout", {
	Padding = UDim.new(0, 8),
	SortOrder = Enum.SortOrder.LayoutOrder,
}, OptionsList)

local function optionRow(label, detail)
	local row = new("Frame", {
		Size = UDim2.new(1, 0, 0, 54),
		BackgroundColor3 = COLORS.panelSoft,
		BorderSizePixel = 0,
	}, OptionsList)
	corner(row, 11)
	new("TextLabel", {
		Position = UDim2.fromOffset(15, 7),
		Size = UDim2.new(1, -190, 0, 20),
		BackgroundTransparency = 1,
		Text = label,
		TextColor3 = COLORS.text,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = Enum.Font.GothamBold,
	}, row)
	new("TextLabel", {
		Position = UDim2.fromOffset(15, 28),
		Size = UDim2.new(1, -190, 0, 18),
		BackgroundTransparency = 1,
		Text = detail,
		TextColor3 = COLORS.muted,
		TextSize = 11,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Font = Enum.Font.Gotham,
	}, row)
	return row
end

local DelayRow = optionRow("Action delay", "Pause between server actions (0 to 30 seconds)")
local DelayInput = new("TextBox", {
	AnchorPoint = Vector2.new(1, 0.5),
	Position = UDim2.new(1, -12, 0.5, 0),
	Size = UDim2.fromOffset(110, 34),
	BackgroundColor3 = COLORS.panelRaised,
	Text = "0.03",
	PlaceholderText = "0.03",
	TextColor3 = COLORS.text,
	PlaceholderColor3 = COLORS.muted,
	TextSize = 13,
	ClearTextOnFocus = false,
	Font = Enum.Font.GothamMedium,
	BorderSizePixel = 0,
}, DelayRow)
corner(DelayInput, 8)
stroke(DelayInput, COLORS.border, 0.2, 1)

local PipeRow = optionRow("Pipe quality", "Default quality for generated Auto-Plumb routes")
local PipeChoice = "Good"
local GoodButton = makeButton(PipeRow, "GOOD", UDim2.new(1, -164, 0.5, -17), UDim2.fromOffset(70, 34), false)
local RustyButton = makeButton(PipeRow, "RUSTY", UDim2.new(1, -86, 0.5, -17), UDim2.fromOffset(70, 34), false)
local function setPipeChoice(choice)
	PipeChoice = choice == "Rusty" and "Rusty" or "Good"
	GoodButton:SetAttribute("EntryAccent", PipeChoice == "Good")
	RustyButton:SetAttribute("EntryAccent", PipeChoice == "Rusty")
	GoodButton.BackgroundColor3 = PipeChoice == "Good" and COLORS.accentDark or COLORS.panelRaised
	GoodButton.TextColor3 = PipeChoice == "Good" and Color3.fromRGB(220, 252, 231) or COLORS.text
	RustyButton.BackgroundColor3 = PipeChoice == "Rusty" and COLORS.accentDark or COLORS.panelRaised
	RustyButton.TextColor3 = PipeChoice == "Rusty" and Color3.fromRGB(220, 252, 231) or COLORS.text
end

local function makeToggle(label, detail, defaultValue)
	local row = optionRow(label, detail)
	local state = defaultValue == true
	local trackFrame = new("Frame", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -14, 0.5, 0),
		Size = UDim2.fromOffset(52, 28),
		BackgroundColor3 = state and COLORS.accentDark or COLORS.panelRaised,
		BorderSizePixel = 0,
	}, row)
	corner(trackFrame, 99)
	local knob = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = state and UDim2.new(1, -14, 0.5, 0) or UDim2.new(0, 14, 0.5, 0),
		Size = UDim2.fromOffset(20, 20),
		BackgroundColor3 = state and COLORS.accent or COLORS.muted,
		BorderSizePixel = 0,
	}, trackFrame)
	corner(knob, 99)
	local hit = new("TextButton", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
	}, trackFrame)
	local function render(animated)
		local properties = {
			Position = state and UDim2.new(1, -14, 0.5, 0) or UDim2.new(0, 14, 0.5, 0),
			BackgroundColor3 = state and COLORS.accent or COLORS.muted,
		}
		trackFrame.BackgroundColor3 = state and COLORS.accentDark or COLORS.panelRaised
		if animated then
			TweenService:Create(knob, TweenInfo.new(0.14, Enum.EasingStyle.Quad), properties):Play()
		else
			for property, value in pairs(properties) do
				knob[property] = value
			end
		end
	end
	track(hit.MouseButton1Click:Connect(function()
		state = not state
		render(true)
	end))
	return function(value)
		if value ~= nil then
			state = value == true
			render(false)
		end
		return state
	end
end

local SmartTurn = makeToggle("Smart Turn", "Try 0/90/180/270 and choose a valid fit", true)
local AutoPlumb = makeToggle("Auto-Plumb", "Build requested physical pipe routes automatically", true)
local GameStylePreview = makeToggle("Game-style plumbing preview", "Use native-looking pipe and wire connection visuals", true)

local LaunchButton = makeButton(
	OptionsPage,
	"OPEN MAIN PLACER",
	UDim2.new(0.5, -105, 1, -44),
	UDim2.fromOffset(210, 42),
	true
)

new("TextLabel", {
	Position = UDim2.fromOffset(0, 24),
	Size = UDim2.new(1, 0, 0, 50),
	BackgroundTransparency = 1,
	Text = "!",
	TextColor3 = COLORS.error,
	TextSize = 42,
	Font = Enum.Font.GothamBold,
}, ErrorPage)
local ErrorTitle = new("TextLabel", {
	Position = UDim2.fromOffset(0, 82),
	Size = UDim2.new(1, 0, 0, 30),
	BackgroundTransparency = 1,
	Text = "Setup needs attention",
	TextColor3 = COLORS.text,
	TextSize = 23,
	Font = Enum.Font.GothamBold,
}, ErrorPage)
local ErrorDetail = new("TextLabel", {
	Position = UDim2.fromOffset(36, 126),
	Size = UDim2.new(1, -72, 0, 118),
	BackgroundTransparency = 1,
	Text = "Unknown setup error.",
	TextColor3 = COLORS.muted,
	TextSize = 13,
	TextWrapped = true,
	TextYAlignment = Enum.TextYAlignment.Top,
	Font = Enum.Font.Gotham,
}, ErrorPage)
local RetryButton = makeButton(
	ErrorPage,
	"RETRY",
	UDim2.new(0.5, -80, 1, -53),
	UDim2.fromOffset(160, 42),
	true
)

local function showError(title, detail, retryLabel, retryAction)
	if Controller.destroyed then
		return
	end
	ErrorTitle.Text = tostring(title or "Setup needs attention")
	ErrorDetail.Text = tostring(detail or "Unknown setup error.")
	RetryButton.Text = tostring(retryLabel or "RETRY")
	Controller.retryAction = retryAction
	showPage(ErrorPage)
	setFooter(title or "Setup stopped", COLORS.error)
end

local function normalizedHash(value)
	return tostring(value or ""):lower():gsub("^sha256:", ""):gsub("[^%x]", "")
end

local function sha256(source)
	local candidates = {}
	for _, root in ipairs({ environment, _G }) do
		if type(root) == "table" then
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
			local normalized = ok and normalizedHash(result) or ""
			if #normalized == 64 then
				return normalized
			end
		end
	end
	return nil
end

local function immutableURL(url, expectedHash)
	if type(url) ~= "string" or not url:match("^https://") then
		return false
	elseif normalizedHash(expectedHash) ~= "" then
		return true
	end
	-- Without an independent SHA-256, accept only raw GitHub content addressed
	-- by a full Git object. Tags and release assets can be replaced by owners.
	local commit = url:match(
		"^https://raw%.githubusercontent%.com/[%w%._%-]+/[%w%._%-]+/([%x]+)/"
	)
	return commit ~= nil and (#commit == 40 or #commit == 64)
end

local function validateMainSource(source, origin)
	if type(source) ~= "string" then
		return false, origin .. " did not return text."
	elseif #source < 1000 then
		return false, origin .. " is too small to be the Industrialist main script."
	elseif #source > MAX_MAIN_BYTES then
		return false, string.format("%s is too large (%d bytes; limit %d).", origin, #source, MAX_MAIN_BYTES)
	elseif not source:find(MAIN_MARKER, 1, true) then
		return false, origin .. " is missing the Industrialist main-script marker."
	end
	local expectedHash = normalizedHash(entryConfiguration.ExpectedMainSHA256)
	if expectedHash ~= "" then
		if #expectedHash ~= 64 then
			return false, "ExpectedMainSHA256 must contain exactly 64 hexadecimal characters."
		end
		local actualHash = sha256(source)
		if not actualHash then
			return false, "A SHA-256 was configured, but this executor exposes no compatible crypt.hash function."
		elseif actualHash ~= expectedHash then
			return false, string.format("SHA-256 mismatch for %s. Expected %s, received %s.", origin, expectedHash, actualHash)
		end
	end
	return true
end

local function localPathAllowed(path)
	return type(path) == "string"
		and #path >= 5
		and #path <= 240
		and not path:find("\0", 1, true)
		and not path:find("..", 1, true)
		and (path:match("%.luau$") ~= nil or path:match("%.lua$") ~= nil)
end

local function readMainSource()
	local errors = {}
	local configuredLocalPath = entryConfiguration.MainLocalPath
	if configuredLocalPath == nil then
		configuredLocalPath = DEFAULT_LOCAL_PATH
	end
	if configuredLocalPath ~= false then
		if not localPathAllowed(configuredLocalPath) then
			table.insert(errors, "MainLocalPath must be a .luau/.lua path without '..'.")
		else
			local readFile = executorFunction("readfile")
			if readFile then
				LoadingDetail.Text = "Checking trusted local release: " .. configuredLocalPath
				local readOK, source = pcall(readFile, configuredLocalPath)
				if readOK then
					local valid, validationError = validateMainSource(source, "Local main script")
					if valid then
						return source, "local " .. configuredLocalPath
					end
					table.insert(errors, validationError)
				else
					table.insert(errors, "Local main script unavailable: " .. tostring(source))
				end
			else
				table.insert(errors, "readfile is unavailable for the trusted local main script.")
			end
		end
	end

	local url = entryConfiguration.MainURL
	if type(url) == "string" and url ~= "" then
		if not immutableURL(url, entryConfiguration.ExpectedMainSHA256) then
			table.insert(errors, "MainURL must use a full raw.githubusercontent.com commit or an ExpectedMainSHA256.")
		else
			LoadingDetail.Text = "Downloading the configured immutable main release..."
			local downloadOK, source = pcall(function()
				return game:HttpGet(url)
			end)
			if downloadOK then
				local valid, validationError = validateMainSource(source, "Downloaded main script")
				if valid then
					return source, url
				end
				table.insert(errors, validationError)
			else
				table.insert(errors, "Main download failed: " .. tostring(source))
			end
		end
	else
		table.insert(errors, "No immutable MainURL was configured.")
	end
	return nil, table.concat(errors, "\n")
end

local function compileMain(source)
	local loader = loadstring
	if type(loader) ~= "function" then
		return nil, "This executor does not expose loadstring."
	end
	local compileOK, chunk, compileError = pcall(loader, source, "@industrialist/main.luau")
	if not compileOK then
		compileError = chunk
		chunk = nil
	elseif not chunk then
		compileError = compileError or "unknown compile error"
	end
	if not chunk then
		local fallbackOK, fallbackChunk, fallbackError = pcall(loader, source)
		if fallbackOK and fallbackChunk then
			chunk = fallbackChunk
		else
			compileError = tostring(compileError) .. " | " .. tostring(fallbackError or fallbackChunk)
		end
	end
	if not chunk then
		return nil, "Main script did not compile: " .. tostring(compileError)
	end
	return chunk
end

local function loadMainAPI()
	-- Always load the configured reviewed source. Static contract strings prove
	-- compatibility, not freshness; the main runtime's own reinjection guard is
	-- responsible for refusing replacement when verified work is still active.
	BootstrapConfig.DeferUI = true
	BootstrapConfig.SetupComplete = false
	environment.IndustrialistBootstrapConfig = BootstrapConfig
	local source, sourceOriginOrError = readMainSource()
	if not source then
		return nil, sourceOriginOrError
	end
	local chunk, compileError = compileMain(source)
	if not chunk then
		return nil, compileError
	end
	LoadingDetail.Text = "Starting the verified placement runtime..."
	local runOK, returned = pcall(chunk)
	if not runOK then
		return nil, "Main script stopped while starting: " .. tostring(returned)
	end
	local api = validAPI(returned) and returned or environment.IndustrialistBlueprintPlacer
	if not validAPI(api) then
		return nil, "Main script ran, but it did not publish a compatible IndustrialistBlueprintPlacer API."
	end
	return api, sourceOriginOrError
end

local function setScanStatus(text, color)
	ScanStatusText.Text = tostring(text)
	ScanPulse.BackgroundColor3 = color or COLORS.warning
	setFooter(text, color or COLORS.warning)
end

local scanPollConnection
local function stopScanPoll()
	disconnect(scanPollConnection)
	scanPollConnection = nil
end

local showOptions
local armPlacementScan
local retryLoadMain

retryLoadMain = function()
	if Controller.destroyed then
		return
	end
	Controller.api = nil
	showPage(LoadingPage)
	setStep(1)
	setFooter("Retrying the main placement core...", COLORS.blue)
	task.defer(function()
		local generation = Controller.generation
		local loadedAPI, detail = loadMainAPI()
		if Controller.destroyed or Controller.generation ~= generation then
			return
		elseif loadedAPI then
			Controller.api = loadedAPI
			setFooter("Placement core ready.", COLORS.accent)
			armPlacementScan()
		else
			showError("Main core could not load", detail, "RETRY LOAD", retryLoadMain)
		end
	end)
end

armPlacementScan = function()
	if Controller.destroyed then
		return
	end
	local api = Controller.api
	if not validAPI(api) then
		showError(
			"Placement core unavailable",
			"Reload the main placement core before scanning.",
			"RETRY LOAD",
			retryLoadMain
		)
		return
	end
	if api.State.building == true or api.State.buildRemoteAttempted == true then
		showError(
			"Existing build is active",
			"Finish or safely stop the existing placer build before recalibrating its placement packet.",
			"CHECK AGAIN",
			armPlacementScan
		)
		return
	end
	if api.State.captureArmed or api.State.captureProcessing or api.State.captureInFlight then
		pcall(api.CancelPlacementScan, true)
	end
	stopScanPoll()
	Controller.previousCapture = api.State.captured
	Controller.successfulCapture = nil
	Controller.successfulCaptureGeneration = nil
	local callOK, started, detail = pcall(api.CaptureNextPlacement)
	if not callOK then
		showError("Scan could not start", tostring(started), "RETRY SCAN", armPlacementScan)
		return
	elseif started == false then
		showError("Scan could not start", tostring(detail or "The placement detector refused to arm."), "RETRY SCAN", armPlacementScan)
		return
	end
	Controller.scanGeneration = api.State.captureGeneration
	Controller.scanOwned = true
	Controller.scanStartedAt = os.clock()
	setStep(2)
	showPage(ScanPage)
	setScanStatus("Waiting for your placement...", COLORS.warning)

	local updateElapsed = 0
	scanPollConnection = RunService.Heartbeat:Connect(function(deltaTime)
		if Controller.destroyed then
			stopScanPoll()
			return
		end
		local state = api.State
		if type(state) ~= "table" or state.destroyed == true then
			stopScanPoll()
			showError(
				"Placement core stopped",
				"The main runtime was destroyed while setup was waiting.",
				"RETRY LOAD",
				retryLoadMain
			)
			return
		end
		if state.captureGeneration ~= Controller.scanGeneration then
			stopScanPoll()
			showError("Scan was replaced", "Another scan or reinjection replaced this setup scan.", "RETRY SCAN", armPlacementScan)
			return
		end
		local freshCapture = type(state.captured) == "table"
			and state.captured ~= Controller.previousCapture
			and state.captured.Generation == Controller.scanGeneration
		if state.scanComplete == true and freshCapture then
			stopScanPoll()
			Controller.scanOwned = false
			Controller.successfulCapture = state.captured
			Controller.successfulCaptureGeneration = Controller.scanGeneration
			showOptions()
			return
		elseif state.scanComplete == true and state.captured == Controller.previousCapture then
			stopScanPoll()
			Controller.scanOwned = false
			showError(
				"Test placement was not verified",
				"The previous remembered placement profile was restored. Move to clear space and retry with one inexpensive catalog item.",
				"RETRY SCAN",
				armPlacementScan
			)
			return
		end
		updateElapsed += deltaTime
		if updateElapsed < 0.25 then
			return
		end
		updateElapsed = 0
		local elapsed = os.clock() - Controller.scanStartedAt
		if state.captureProcessing or state.pendingCapture ~= nil then
			setScanStatus("Placement detected. Verifying it in your plot...", COLORS.blue)
		elseif state.captureInFlight then
			setScanStatus("Placement detected. Waiting for the game server...", COLORS.blue)
		elseif state.captureArmed then
			setScanStatus(elapsed > 60
				and "Still armed. Place one supported item in clear plot space."
				or "Waiting for your placement...", COLORS.warning)
		else
			setScanStatus("Waiting for placement verification to finish...", COLORS.blue)
		end
	end)
	track(scanPollConnection)
end

showOptions = function()
	if Controller.destroyed then
		return
	end
	local state = Controller.api and Controller.api.State or {}
	DelayInput.Text = string.format("%.2f", tonumber(state.delaySeconds) or 0.03)
	setPipeChoice(state.autoPlumbQuality == "Rusty" and "Rusty" or "Good")
	local existingSettings = type(BootstrapConfig.Settings) == "table" and BootstrapConfig.Settings or {}
	SmartTurn(existingSettings.SmartTurn ~= false)
	AutoPlumb(existingSettings.AutoPlumb ~= false)
	GameStylePreview(existingSettings.GameStylePreview ~= false)
	setStep(3)
	showPage(OptionsPage)
	setFooter("Success - placement packet verified.", COLORS.accent)
end

local function copySettings(settings)
	return {
		ActionDelay = settings.ActionDelay,
		PipeQuality = settings.PipeQuality,
		SmartTurn = settings.SmartTurn,
		AutoPlumb = settings.AutoPlumb,
		GameStylePreview = settings.GameStylePreview,
	}
end

local function publishSettings(settings)
	BootstrapConfig.Format = "IndustrialistBootstrapConfig"
	BootstrapConfig.Version = ENTRY_VERSION
	BootstrapConfig.PlaceId = game.PlaceId
	BootstrapConfig.GameId = game.GameId
	BootstrapConfig.Settings = copySettings(settings)
	-- Mirrored fields keep the entry compatible with older main builds that read
	-- the first bootstrap draft before the nested Settings contract existed.
	for key, value in pairs(settings) do
		BootstrapConfig[key] = value
	end
	BootstrapConfig.SetupComplete = true
	BootstrapConfig.DeferUI = false
	environment.IndustrialistBootstrapConfig = BootstrapConfig
end

local function applySettingsToAPI(api, settings)
	local applyOK, result, detail = pcall(api.ApplySetupOptions, copySettings(settings), true)
	if not applyOK then
		return false, tostring(result)
	elseif result == false then
		return false, tostring(detail or "Main runtime refused the setup options.")
	end
	return true
end

function Controller:Destroy(cancelOwnedScan)
	if self.destroyed then
		return true
	end
	self.destroyed = true
	self.generation += 1
	stopScanPoll()
	if cancelOwnedScan and self.scanOwned and validAPI(self.api) then
		local state = self.api.State
		if state.captureGeneration == self.scanGeneration
			and (state.captureArmed or state.captureProcessing or state.captureInFlight or state.pendingCapture ~= nil)
		then
			pcall(self.api.CancelPlacementScan, true)
		end
	end
	for _, connection in ipairs(self.connections) do
		disconnect(connection)
	end
	table.clear(self.connections)
	if self.gui and self.gui.Parent then
		self.gui:Destroy()
	end
	self.gui = nil
	if environment.IndustrialistEntry == self then
		environment.IndustrialistEntry = nil
	end
	if cancelOwnedScan
		and BootstrapConfig.SetupComplete ~= true
		and environment.IndustrialistBootstrapConfig == BootstrapConfig
	then
		environment.IndustrialistBootstrapConfig = nil
	end
	return true
end

track(CloseButton.MouseButton1Click:Connect(function()
	Controller:Destroy(true)
end))
track(RetryScanButton.MouseButton1Click:Connect(function()
	armPlacementScan()
end))
track(GoodButton.MouseButton1Click:Connect(function()
	setPipeChoice("Good")
end))
track(RustyButton.MouseButton1Click:Connect(function()
	setPipeChoice("Rusty")
end))
track(RetryButton.MouseButton1Click:Connect(function()
	local action = Controller.retryAction
	if type(action) == "function" and not Controller.destroyed then
		Controller.retryAction = nil
		action()
	end
end))

local launchMain
launchMain = function()
	if Controller.destroyed or Controller.launching then
		return
	end
	local delay = tonumber(DelayInput.Text)
	if not delay or delay ~= delay or delay < 0 or delay > 30 then
		setFooter("Action delay must be a number from 0 to 30.", COLORS.error)
		DelayInput:CaptureFocus()
		return
	end
	local api = Controller.api
	local successfulCapture = Controller.successfulCapture
	local successfulGeneration = Controller.successfulCaptureGeneration
	if not validAPI(api)
		or api.State.scanComplete ~= true
		or api.State.captureGeneration ~= successfulGeneration
		or api.State.captured ~= successfulCapture
		or type(successfulCapture) ~= "table"
		or successfulCapture.Generation ~= successfulGeneration
	then
		showError("Verified scan was lost", "Run the placement scan again before opening the main placer.", "RETRY SCAN", armPlacementScan)
		return
	end
	local settings = {
		ActionDelay = delay,
		PipeQuality = PipeChoice,
		SmartTurn = SmartTurn(),
		AutoPlumb = AutoPlumb(),
		GameStylePreview = GameStylePreview(),
	}
	Controller.launching = true
	LaunchButton.Text = "OPENING..."
	setFooter("Applying setup options...", COLORS.blue)
	publishSettings(settings)
	local applied, applyError = applySettingsToAPI(api, settings)
	if not applied then
		Controller.launching = false
		LaunchButton.Text = "OPEN MAIN PLACER"
		BootstrapConfig.DeferUI = true
		BootstrapConfig.SetupComplete = false
		showError("Options could not be applied", applyError, "BACK TO OPTIONS", function()
			showPage(OptionsPage)
			setStep(3)
			setFooter("Adjust the setup options and try again.", COLORS.warning)
		end)
		return
	end
	task.defer(function()
		local openOK, result, detail = pcall(api.CreateRayfieldInterface)
		if Controller.destroyed then
			return
		end
		if not openOK or result == false then
			Controller.launching = false
			LaunchButton.Text = "OPEN MAIN PLACER"
			BootstrapConfig.DeferUI = true
			BootstrapConfig.SetupComplete = false
			showError(
				"Main interface could not open",
				tostring(openOK and (detail or "Rayfield did not initialize.") or result),
				"RETRY LAUNCH",
				launchMain
			)
			return
		end
		setFooter("Main placer ready.", COLORS.accent)
		task.delay(0.8, function()
			if not Controller.destroyed then
				Controller:Destroy(false)
			end
		end)
	end)
end
track(LaunchButton.MouseButton1Click:Connect(launchMain))

-- Native drag behavior keeps the setup usable when another in-game panel is
-- already occupying the center. It never captures gameplay input outside Header.
do
	local dragging = false
	local dragStart
	local panelStart
	track(Header.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			dragging = true
			dragStart = input.Position
			panelStart = Panel.Position
		end
	end))
	track(UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			dragging = false
		end
	end))
	track(UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch)
		then
			local delta = input.Position - dragStart
			Panel.Position = UDim2.new(
				panelStart.X.Scale,
				panelStart.X.Offset + delta.X / Scale.Scale,
				panelStart.Y.Scale,
				panelStart.Y.Offset + delta.Y / Scale.Scale
			)
		end
	end))
end

showPage(LoadingPage)
setStep(1)
local spinElapsed = 0
track(RunService.RenderStepped:Connect(function(deltaTime)
	if LoadingPage.Visible then
		spinElapsed += deltaTime
		Spinner.Rotation = (spinElapsed * 150) % 360
	end
end))

task.defer(function()
	local generation = Controller.generation
	local api, originOrError = loadMainAPI()
	if Controller.destroyed or Controller.generation ~= generation then
		return
	end
	if not api then
		showError("Main core could not load", originOrError, "RETRY LOAD", retryLoadMain)
		return
	end
	Controller.api = api
	setFooter("Placement core ready from " .. tostring(originOrError) .. ".", COLORS.accent)
	armPlacementScan()
end)

return Controller
