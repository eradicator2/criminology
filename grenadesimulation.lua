local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")

local LOCAL_PLAYER = Players.LocalPlayer
local camera       = workspace.CurrentCamera

local DEBRIS = workspace:WaitForChild("Debris")
local VPARTS = DEBRIS:WaitForChild("VParts")

local GrenadeTrajectory = {}

GrenadeTrajectory.Config = {
	Enabled     = false,
	ShowLive    = true,
	ShowPreview = true,
	Occlusion   = true,
}

local DT            = 0.03
local MAX_TIME      = 20
local MIN_SPEED     = 0.01
local MAX_BOUNCES   = 30
local LINE_LIFETIME = 4
local GRAVITY       = Vector3.new(0, -workspace.Gravity * 0.55, 0)
local THROW_SPEED   = 150

local DEFAULT_SURFACE_PHYS = PhysicalProperties.new(1, 0.7, 0, 1, 1)

local liveSegments    = {}
local previewSegments = {}

local renderConn  : RBXScriptConnection? = nil
local previewConn : RBXScriptConnection? = nil
local childConn   : RBXScriptConnection? = nil

local OCCLUSION_PARAMS = RaycastParams.new()
OCCLUSION_PARAMS.FilterType = Enum.RaycastFilterType.Exclude
OCCLUSION_PARAMS.CollisionGroup = "NoCharCollide2"
OCCLUSION_PARAMS.FilterDescendantsInstances = {
	LOCAL_PLAYER.Character,
	DEBRIS,
}
OCCLUSION_PARAMS.IgnoreWater      = true
OCCLUSION_PARAMS.RespectCanCollide = true

local function clearList(list)
	for i = 1, #list do
		local seg = list[i]
		if seg.line then
			seg.line.Visible = false
			seg.line:Remove()
		end
	end
	table.clear(list)
end

local function clearPreview() clearList(previewSegments) end
local function clearLive()    clearList(liveSegments)    end

local function getSurfacePhys(part: BasePart?)
	if part and part.CustomPhysicalProperties then
		return part.CustomPhysicalProperties
	end
	return DEFAULT_SURFACE_PHYS
end

local function frictionToFactor(frict: number)
	return 1 / (1 + frict)
end

local function computeRollDecel(friction: number, normal: Vector3)
	local ROLL_DECEL_SCALE = 0.35
	local gMag = GRAVITY.Magnitude
	if gMag < 1e-3 then
		gMag = workspace.Gravity
	end

	local up       = Vector3.yAxis
	local cosTheta = math.abs(normal:Dot(up))
	local normalG  = gMag * cosTheta

	local a = friction * normalG * ROLL_DECEL_SCALE
	return math.clamp(a, 0.2, 40)
end

local mouse = LOCAL_PLAYER:GetMouse()

local function GetMousePoint()
	if getrenv()._G.M_MLCheck() then
		return camera.CFrame.Position + (camera.CFrame.LookVector * 100)
	else
		local X,Y = mouse.X,mouse.Y
		local RayMag1 = camera:ScreenPointToRay(X, Y)
		local NewRay = Ray.new(RayMag1.Origin, RayMag1.Direction * 100)
		local Target, Position = workspace:FindPartOnRayWithWhitelist(NewRay, {},true)

		Position = Vector3.new(Position.X,Position.Y,Position.Z)

		return Position
	end
end

local function simulatePath(x0: Vector3, v0: Vector3, ignoreList: {Instance})
	local positions = { { pos = x0, t = 0 } }

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = ignoreList
	rayParams.CollisionGroup   = "NoCharCollide2"
	rayParams.IgnoreWater      = false
	rayParams.RespectCanCollide = true

	local tTotal  = 0
	local bounces = 0
	local x, v    = x0, v0

	local rolling      = false
	local groundNormal : Vector3? = nil
	local rollDecel    = 0

	while tTotal < MAX_TIME and v.Magnitude >= MIN_SPEED and bounces <= MAX_BOUNCES do
		local dt = DT

		if not rolling then
			local newV = v + GRAVITY * dt
			local newX = x + v * dt + 0.5 * GRAVITY * dt * dt
			local dir  = newX - x

			local result = workspace:Raycast(x, dir, rayParams)
			if result then
				local hitPos = result.Position
				local normal = result.Normal.Unit
				local dist   = result.Distance
				if not dist or dist <= 0 then
					dist = (hitPos - x).Magnitude
				end

				local dirMag = dir.Magnitude
				local alpha  = dirMag > 1e-4 and math.clamp(dist / dirMag, 0, 1) or 0
				local tHit   = dt * alpha

				tTotal += tHit
				local vImpact = v + GRAVITY * tHit
				table.insert(positions, { pos = hitPos, t = tTotal })

				local phys          = getSurfacePhys(result.Instance)
				local elast         = phys.Elasticity
				local frict         = phys.Friction
				local frictionFact  = frictionToFactor(frict)

				local normalComp      = vImpact:Dot(normal) * normal
				local tangential      = vImpact - normalComp
				local normalSpeed     = normalComp.Magnitude
				local tangentialSpeed = tangential.Magnitude

				if normal.Y > 0.7 and tangentialSpeed > 0.1 and normalSpeed < tangentialSpeed * 0.2 then
					rolling      = true
					groundNormal = normal
					rollDecel    = computeRollDecel(frict, normal)
					v            = tangentialSpeed > 0 and tangential * frictionFact or Vector3.zero
					x            = hitPos + normal * 0.05
					bounces += 1
				else
					v = -normalComp * elast + tangential * frictionFact
					x = hitPos + normal * 0.01
					bounces += 1
				end
			else
				x = newX
				v = newV
				tTotal += dt
				table.insert(positions, { pos = x, t = tTotal })
			end
		else
			if not groundNormal then
				rolling = false
			else
				local speed = v.Magnitude
				if speed < MIN_SPEED then break end

				local dir  = speed > 1e-4 and v.Unit or Vector3.zero
				local move = dir * speed * dt
				local newX = x + move

				local downOrigin = newX + groundNormal * 0.5
				local downResult = workspace:Raycast(downOrigin, -groundNormal * 2, rayParams)

				if downResult then
					newX        = downResult.Position + groundNormal * 0.05
					local n     = downResult.Normal.Unit
					groundNormal = n
					local phys  = getSurfacePhys(downResult.Instance)
					rollDecel   = computeRollDecel(phys.Friction, n)
				else
					tTotal += dt
					table.insert(positions, { pos = newX, t = tTotal })
					break
				end

				x = newX
				tTotal += dt
				table.insert(positions, { pos = x, t = tTotal })

				local newSpeed = math.max(0, speed - rollDecel * dt)
				if newSpeed <= MIN_SPEED then break end
				v = dir * newSpeed
			end
		end
	end

	return positions
end

local function setPreviewPositions(positions, color: Color3)
	if #positions < 2 then
		clearPreview()
		return
	end

	local desired = #positions - 1

	while #previewSegments < desired do
		local line = Drawing.new("Line")
		line.Color        = color
		line.Thickness    = 2
		line.Transparency = 0.5
		line.Visible      = false

		table.insert(previewSegments, { p0 = Vector3.zero, p1 = Vector3.zero, line = line })
	end

	while #previewSegments > desired do
		local seg = previewSegments[#previewSegments]
		if seg.line then
			seg.line.Visible = false
			seg.line:Remove()
		end
		table.remove(previewSegments)
	end

	for i = 1, desired do
		local p0Rec = positions[i]
		local p1Rec = positions[i + 1]
		local seg   = previewSegments[i]
		seg.p0      = p0Rec.pos
		seg.p1      = p1Rec.pos
		seg.line.Color = color
	end
end

local function addLivePositions(positions, color: Color3)
	if #positions < 2 then return end

	local startTime    = tick()
	local totalSimTime = positions[#positions].t or 0
	local deathTime    = startTime + math.max(totalSimTime, LINE_LIFETIME)

	for i = 1, #positions - 1 do
		local p0Rec = positions[i]
		local p1Rec = positions[i + 1]

		local line = Drawing.new("Line")
		line.Color        = color
		line.Thickness    = 2
		line.Transparency = 0.5
		line.Visible      = false

		table.insert(liveSegments, {
			p0      = p0Rec.pos,
			p1      = p1Rec.pos,
			t0      = p0Rec.t,
			t1      = p1Rec.t,
			startAt = startTime,
			deadAt  = deathTime,
			line    = line,
		})
	end
end

local function startRenderLoop()
	if renderConn then return end

	renderConn = RunService.RenderStepped:Connect(function()
		camera = workspace.CurrentCamera or camera
		if not camera then return end

		local cfg = GrenadeTrajectory.Config
		local now = tick()
		local camPos = camera.CFrame.Position

		if not cfg.Enabled then
			for _, seg in ipairs(liveSegments) do
				if seg.line then seg.line.Visible = false end
			end
			for _, seg in ipairs(previewSegments) do
				if seg.line then seg.line.Visible = false end
			end
			if #liveSegments == 0 and #previewSegments == 0 and renderConn then
				renderConn:Disconnect()
				renderConn = nil
			end
			return
		end

		for i = #liveSegments, 1, -1 do
			local seg  = liveSegments[i]
			local line = seg.line
			if not line or now >= seg.deadAt then
				if line then
					line.Visible = false
					line:Remove()
				end
				table.remove(liveSegments, i)
			else
				if not cfg.ShowLive then
					line.Visible = false
				else
					local elapsed = now - seg.startAt
					if elapsed >= seg.t1 then
						line.Color = Color3.fromRGB(0, 255, 0)
					else
						line.Color = Color3.new(1, 0, 0)
					end

					local p0 = seg.p0
					local p1 = seg.p1

					local occluded = false
					if cfg.Occlusion then
						local mid   = (p0 + p1) * 0.5
						local toMid = mid - camPos
						local dist  = toMid.Magnitude
						if dist > 0.1 then
							local hit = workspace:Raycast(camPos, toMid, OCCLUSION_PARAMS)
							if hit then
								local hitDist = (hit.Position - camPos).Magnitude
								if hitDist < dist - 3 then
									occluded = true
								end
							end
						end
					end

					local v0, on0 = camera:WorldToViewportPoint(p0)
					local v1, on1 = camera:WorldToViewportPoint(p1)
					local offscreen = not on0 and not on1

					if not occluded and not offscreen then
						line.Visible = true
						line.From    = Vector2.new(v0.X, v0.Y)
						line.To      = Vector2.new(v1.X, v1.Y)
					else
						line.Visible = false
					end
				end
			end
		end

		for _, seg in ipairs(previewSegments) do
			local line = seg.line
			if line then
				if not cfg.ShowPreview or not cfg.Enabled then
					line.Visible = false
				else
					local p0 = seg.p0
					local p1 = seg.p1

					local occluded = false
					if cfg.Occlusion then
						local mid   = (p0 + p1) * 0.5
						local toMid = mid - camPos
						local dist  = toMid.Magnitude
						if dist > 0.1 then
							local hit = workspace:Raycast(camPos, toMid, OCCLUSION_PARAMS)
							if hit then
								local hitDist = (hit.Position - camPos).Magnitude
								if hitDist < dist - 3 then
									occluded = true
								end
							end
						end
					end

					local v0, on0 = camera:WorldToViewportPoint(p0)
					local v1, on1 = camera:WorldToViewportPoint(p1)
					local offscreen = not on0 and not on1

					if not occluded and not offscreen then
						line.Visible = true
						line.From    = Vector2.new(v0.X, v0.Y)
						line.To      = Vector2.new(v1.X, v1.Y)
					else
						line.Visible = false
					end
				end
			end
		end

		if #liveSegments == 0 and #previewSegments == 0 and renderConn then
			renderConn:Disconnect()
			renderConn = nil
		end
	end)
end

local function updatePreview()
	local cfg = GrenadeTrajectory.Config
	if not cfg.Enabled or not cfg.ShowPreview then
		clearPreview()
		return
	end

	local char = LOCAL_PLAYER.Character
	if not char then
		clearPreview()
		return
	end

	local tool = char:FindFirstChild("Grenade")
	if not tool or not tool:IsA("Tool") then
		clearPreview()
		return
	end

	local head = char:FindFirstChild("Head")
	local hrp  = char:FindFirstChild("HumanoidRootPart")
	local origin = (head and head.Position) or (hrp and hrp.Position) or Vector3.zero

	local target = GetMousePoint()
	local dir    = target - origin
	if dir.Magnitude < 1e-3 then
		clearPreview()
		return
	end
	dir = dir.Unit

	local v0 = dir * THROW_SPEED

	local ignoreList = { char, DEBRIS }
	local positions  = simulatePath(origin, v0, ignoreList)
	if #positions < 2 then
		clearPreview()
		return
	end

	setPreviewPositions(positions, Color3.fromRGB(255, 255, 0))
	startRenderLoop()
end

local function startPreviewLoop()
	if previewConn then return end
	previewConn = RunService.Heartbeat:Connect(function()
		local ok, err = pcall(updatePreview)
		if not ok then
			warn("[GrenadeTrajectory] preview error:", err)
		end
	end)
end

local function isGrenadeHandle(inst: Instance): boolean
	if not inst:IsA("BasePart") then return false end
	return inst:FindFirstChild("HB") and inst:FindFirstChild("X") ~= nil
end

local function simulateAndDraw(handle: BasePart)
	local cfg = GrenadeTrajectory.Config
	if not cfg.Enabled or not cfg.ShowLive then return end

	RunService.Heartbeat:Wait()
	if not handle or not handle.Parent then return end

	local hb = handle:FindFirstChild("HB")
	local sample: BasePart = (hb and hb:IsA("BasePart")) and hb or handle

	local x0 = sample.Position
	local v0 = sample.AssemblyLinearVelocity
	if v0.Magnitude < 1e-3 then return end

	local ignoreList = { handle }
	if hb and hb:IsA("BasePart") then
		table.insert(ignoreList, hb)
	end
	if LOCAL_PLAYER.Character then
		table.insert(ignoreList, LOCAL_PLAYER.Character)
	end

	local positions = simulatePath(x0, v0, ignoreList)
	if #positions < 2 then
		local fallbackEnd = x0 + v0.Unit * 10
		positions = {
			{ pos = x0,          t = 0   },
			{ pos = fallbackEnd, t = 0.1 },
		}
	end

	addLivePositions(positions, Color3.new(1, 0, 0))
	startRenderLoop()
end

local function startChildListener()
	if childConn then return end
	childConn = VPARTS.ChildAdded:Connect(function(child)
		if isGrenadeHandle(child) then
			simulateAndDraw(child)
		end
	end)
end

function GrenadeTrajectory:SetEnabled(value: boolean)
	self.Config.Enabled = value
	if not value then
		clearPreview()
		clearLive()
	end
end

function GrenadeTrajectory:SetShowLive(value: boolean)
	self.Config.ShowLive = value
	if not value then
		clearLive()
	end
end

function GrenadeTrajectory:SetShowPreview(value: boolean)
	self.Config.ShowPreview = value
	if not value then
		clearPreview()
	end
end

function GrenadeTrajectory:SetOcclusion(value: boolean)
	self.Config.Occlusion = value
end

function GrenadeTrajectory:Init()
	startPreviewLoop()
	startChildListener()
end

function GrenadeTrajectory:Shutdown()
	clearPreview()
	clearLive()
	if renderConn then renderConn:Disconnect();  renderConn  = nil end
	if previewConn then previewConn:Disconnect(); previewConn = nil end
	if childConn then childConn:Disconnect();    childConn   = nil end
end

GrenadeTrajectory:Init()

return GrenadeTrajectory
