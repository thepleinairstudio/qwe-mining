-- QWE Mining Ч загрузчик (открыта€ часть).
-- «десь Ќ≈“ логики фермы. ¬есь код скрипта лежит в qwe_mining_core.dat
-- (урезанный байткод LuaJIT), поэтому игроки не могут его прочитать или изменить.
--
--  * DEV-сборка (ѕ  автора): если р€дом лежит исходник "qwe_mining_core.src",
--    загрузчик при каждом запуске компилирует его в урезанный байткод
--    "qwe_mining_core.dat" и запускает €дро. јвтообновление в dev выключено.
--  * RELEASE-сборка (игроки): поставл€етс€ только "qwe_mining_core.dat".
--    «агрузчик загружает его и сам обновл€ет €дро с GitHub (version.json -> .dat).
--
-- ядро общаетс€ с загрузчиком через глобальную таблицу _G.QWE_MINING_UPD.

local REPO_RAW = 'https://raw.githubusercontent.com/thepleinairstudio/qwe-mining/main/'

local dir  = getWorkingDirectory()
local SRC  = dir .. '\\qwe_mining_core.src'
local DAT  = dir .. '\\qwe_mining_core.dat'
local TMPJ = dir .. '\\qwe_mining_update.json'
local TMPD = dir .. '\\qwe_mining_core.dat.new'

local dlstatus = require('moonloader').download_status

local function readFile(p) local f = io.open(p, 'rb'); if not f then return nil end local s = f:read('*a'); f:close(); return s end
local function writeFile(p, d) local f = io.open(p, 'wb'); if not f then return false end f:write(d); f:close(); return true end
local function exists(p) local f = io.open(p, 'rb'); if f then f:close(); return true end return false end
local function verNum(v)
	local a, b, c = tostring(v or ''):match('(%d+)%.?(%d*)%.?(%d*)')
	return (tonumber(a) or 0) * 1000000 + (tonumber(b) or 0) * 1000 + (tonumber(c) or 0)
end

-- ќбщий интерфейс дл€ €дра. ядро читает .code/.ver и вызывает .check().
-- .code Ч короткий код состо€ни€, €дро превращает его в свой локализованный текст.
local UPD = { busy = false, code = nil, ver = nil, dev = false }
_G.QWE_MINING_UPD = UPD
local function setStatus(code, ver) UPD.code, UPD.ver = code, ver end

function UPD.check(manual, curVer)
	if UPD.dev then setStatus('devbuild', curVer); return end
	if UPD.busy and os.clock() - (UPD.at or 0) < 30 then return end
	UPD.busy, UPD.at = true, os.clock()
	setStatus('checking', curVer)
	downloadUrlToFile(REPO_RAW .. 'version.json?t=' .. os.time(), TMPJ, function(_, status)
		if status ~= dlstatus.STATUS_ENDDOWNLOADDATA then return end
		local s = readFile(TMPJ); os.remove(TMPJ)
		local ok, j = pcall(decodeJson, s or '')
		if not ok or type(j) ~= 'table' or not j.version then
			UPD.busy = false; setStatus('neterr', curVer); return
		end
		if verNum(j.version) <= verNum(curVer) then
			UPD.busy = false; setStatus('uptodate', curVer); return
		end
		setStatus('updating', j.version)
		local coreName = j.core or 'moonloader/qwe_mining_core.dat'
		downloadUrlToFile(REPO_RAW .. coreName .. '?t=' .. os.time(), TMPD, function(_, st2)
			if st2 ~= dlstatus.STATUS_ENDDOWNLOADDATA then return end
			local bc = readFile(TMPD)
			-- проверка: достаточно большой и грузитс€ как валидный чанк (байткод или исходник)
			local good = bc and #bc > 40000 and loadfile(TMPD) ~= nil
			if not good then
				os.remove(TMPD); UPD.busy = false; setStatus('baddata', j.version); return
			end
			if exists(DAT) then writeFile(DAT .. '.bak', readFile(DAT) or '') end
			local okw = writeFile(DAT, bc)
			os.remove(TMPD)
			if not okw then UPD.busy = false; setStatus('writeerr', j.version); return end
			setStatus('updated', j.version); UPD.busy = false
			thisScript():reload()
		end)
	end)
end

-- ============================ запуск ============================
local chunk, srcChunk

-- DEV: есть исходник Ч компилируем его в урезанный байткод и перезаписываем .dat
local code = readFile(SRC)
if code then
	local c, err = loadstring(code, '@qwe_mining_core')
	if not c then print('[QWE Mining loader] ошибка компил€ции исходника: ' .. tostring(err)); return end
	srcChunk = c
	local ok, bc = pcall(string.dump, c, true) -- true = убрать отладочную информацию
	if ok and type(bc) == 'string' and #bc > 0 then
		writeFile(DAT, bc)
	else
		print('[QWE Mining loader] string.dump не сработал, запуск из исходника')
	end
	UPD.dev = true
end

local c, err = loadfile(DAT)
if c then
	chunk = c
elseif srcChunk then
	print('[QWE Mining loader] байткод не загрузилс€ (' .. tostring(err) .. '), запуск из исходника')
	chunk = srcChunk
else
	-- Ќет ни исходника, ни €дра (например, поставили только загрузчик): один раз
	-- скачиваем €дро с GitHub и перезапускаемс€. ќбычна€ установка идЄт с .dat.
	print('[QWE Mining loader] €дро не найдено, качаю с GitHub...')
	UPD.busy = true; setStatus('updating')
	function main()
		wait(3000)
		downloadUrlToFile(REPO_RAW .. 'moonloader/qwe_mining_core.dat?t=' .. os.time(), DAT, function(_, st)
			if st == dlstatus.STATUS_ENDDOWNLOADDATA then
				UPD.busy = false
				thisScript():reload()
			end
		end)
		while true do wait(1000) end
	end
	return
end

chunk()
