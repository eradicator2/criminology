local matrix = {}
matrix.__index = matrix

function matrix.new(inheritedFromVector, compData)
	if not compData and not inheritedFromVector then
		compData = {
			{1,0,0,0};
			{0,1,0,0};
			{0,0,1,0};
			{0,0,0,1}
		}
	end
	if inheritedFromVector then

		if typeof(compData) == "Vector3" then
			compData = {
				{compData.X,0,0,0};
				{compData.Y,0,0,0};
				{compData.Z,0,0,0};
				{1,0,0,0}
			}
		else
			compData = 
				{{0,0,0,0};
			{0,0,0,0};
			{0,0,0,0};
			{1,0,0,0}}
		end
	end
	return setmetatable(compData, matrix)
end

function matrix:perspective(fov,n,f)
	local s = 1/math.tan(fov*0.00872664625998)
	local mtx = {
		{s,0,0,0};
		{0,s,0,0};
		{0,0,-f/(f-n),-1};
		{0,0,-f*n/(f-n), 0}
	}
	return matrix.new(false, mtx)
end

function matrix:lookAt(eye, target)
	local forward = (eye-target).Unit
	local right = Vector3.new(0,1,0):Cross(forward)
	local up = forward:Cross(right)
	local coordSpace = matrix.new(false, {
		{right.X, right.Y, right.Z, 0};
		{up.X, up.Y, up.Z, 0};
		{forward.X, forward.Y, forward.Z, 0};
		{0,0,0,1}
	})
	local invertedCameraPosition = matrix.new(false, {
		{1,0,0,-eye.X};
		{0,1,0,-eye.Y};
		{0,0,1,-eye.Z};
		{0,0,0,1}
	})
	return coordSpace*invertedCameraPosition
end

matrix.__mul = function(m1, m2)
	local mtx = {}
	for i = 1,#m1 do
		mtx[i] = {}
		for j = 1,#m2[1] do
			local num = m1[i][1] * m2[1][j]
			for n = 2,#m1[1] do
				num = num + m1[i][n] * m2[n][j]
			end
			mtx[i][j] = num
		end
	end
	return matrix.new(false, mtx)
end

return matrix
