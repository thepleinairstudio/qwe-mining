-- QWE Mining — загрузчик (открытая часть).
-- Здесь НЕТ логики фермы. Весь код скрипта лежит в qwe_mining_core.dat
-- (урезанный байткод LuaJIT), поэтому игроки не могут его прочитать или изменить.
--
--  * DEV-сборка (ПК автора): если рядом лежит исходник "qwe_mining_core.src",
--    загрузчик при каждом запуске компилирует его в урезанный байткод
--    "qwe_mining_core.dat" и запускает ядро. Автообновление в dev выключено.
--  * RELEASE-сборка (игроки): поставляется только "qwe_mining_core.dat".
--    Загрузчик загружает его и сам обновляет ядро с GitHub (version.json -> .dat).
--
-- Ядро общается с загрузчиком через глобальную таблицу _G.QWE_MINING_UPD.


-- Android (MonetLoader): свой разделитель путей и своё ядро. Байткод с ПК на телефоне не грузится
-- (другая сборка LuaJIT), поэтому ядро для телефона — отдельный файл qwe_mining_core.android.dat.
local MOBILE = MONET_VERSION ~= nil
-- ПК и Android — разные репозитории (ядра разные: байткод 32 и 64 бит)
local REPO = MOBILE and 'thepleinairstudio/qwe-mining-android' or 'thepleinairstudio/qwe-mining'
local SEP  = MOBILE and '/' or '\\'
local dir  = getWorkingDirectory()
local SRC  = dir .. SEP .. 'qwe_mining_core.src'
local DAT  = dir .. SEP .. (MOBILE and 'qwe_mining_core.android.dat' or 'qwe_mining_core.dat')
local TMPJ = dir .. SEP .. 'qwe_mining_update.json'
local TMPD = DAT .. '.new'
local DEVF = dir .. SEP .. 'qwe_dev.txt' -- Android: если есть — исходник после сборки не удаляется
local CORE_DEF = MOBILE and 'monetloader/qwe_mining_core.android.dat' or 'moonloader/qwe_mining_core.dat'
local MIN_CORE = 40000
local MARK     = 'QWE_MINING_UPD'       -- по этой строке узнаём «наш» загрузчик при самообновлении
local LOG      = '[QWE Mining loader]'
local DEV_SKIP = true                   -- у автора автообновление выключено совсем

local function readFile(p) local f = io.open(p, 'rb'); if not f then return nil end local s = f:read('*a'); f:close(); return s end
local function writeFile(p, d) local f = io.open(p, 'wb'); if not f then return false end f:write(d); f:close(); return true end
local function exists(p) local f = io.open(p, 'rb'); if f then f:close(); return true end return false end
local function verNum(v)
	local a, b, c = tostring(v or ''):match('(%d+)%.?(%d*)%.?(%d*)')
	return (tonumber(a) or 0) * 1000000 + (tonumber(b) or 0) * 1000 + (tonumber(c) or 0)
end

-- Общий интерфейс для ядра. Ядро читает .code/.ver и вызывает .check().
-- .code — короткий код состояния, ядро превращает его в свой локализованный текст.
local UPD = { busy = false, code = nil, ver = nil, dev = false }
_G.QWE_MINING_UPD = UPD
local function setStatus(code, ver) UPD.code, UPD.ver = code, ver end

-- ===================== автообновление (общий блок QWE, загрузчик v2) =====================
-- Одинаковый во всех загрузчиках QWE (источник: _tools/qwe-updater/updater.part.lua).
-- Перед блоком загрузчик задаёт: REPO, DAT, TMPJ, TMPD, CORE_DEF, MIN_CORE, MARK, LOG, DEV_SKIP,
-- UPD, setStatus, readFile, writeFile, exists, verNum.
--
-- Что чинит по сравнению с v1:
--  * raw.githubusercontent.com 5 минут отдаёт старые файлы и не смотрит на «?t=». Ядро и
--    version.json качаем по ссылке на свежий коммит (api.github.com) — там кэша нет.
--  * API недоступен и качаем с main — сверяем "size" ядра из version.json: не совпал (старый кэш) —
--    ядро не ставим, пробуем ещё раз через 15 с.
--  * ошибка сети / 404 / зависание больше не оставляет «Проверяю…» навсегда.
--  * все скачивания идут из одного потока загрузчика, не из колбэков и не из потоков ядра.
--  * загрузчик обновляет сам себя, если в version.json "loader" больше LOADER_VER.
local LOADER_VER = 2

local dls = require('moonloader').download_status or {}
local ST_DATA = dls.STATUS_ENDDOWNLOADDATA or 6
local ST_END  = dls.STATUSEX_ENDDOWNLOAD
local RAW_MAIN = 'https://raw.githubusercontent.com/' .. REPO .. '/main/'

-- скачать и дождаться (только внутри потока). Вернёт содержимое или nil.
local function fetch(url, path, sec)
	os.remove(path)
	local job = { done = false, ok = false }
	local called = pcall(downloadUrlToFile, url, path, function(_, st)
		if st == ST_DATA then job.ok = true; job.done = true
		elseif ST_END and st == ST_END then job.done = true end
	end)
	if not called then return nil end
	local n = (sec or 25) * 10
	while not job.done and n > 0 do wait(100); n = n - 1 end
	-- конец без данных: на всякий случай даём долететь STATUS_ENDDOWNLOADDATA
	if job.done and not job.ok then wait(300) end
	wait(100)
	local s = readFile(path); os.remove(path)
	if job.ok and s and #s > 0 then return s end
	return nil
end

local function parseJson(s)
	-- decodeJson('') в MoonLoader пробивает pcall — сначала убеждаемся, что это JSON
	if not s or not s:find('{', 1, true) or s:find('<html', 1, true) then return nil end
	local ok, j = pcall(decodeJson, s)
	if ok and type(j) == 'table' then return j end
	return nil
end

-- адрес файлов на свежем коммите main (или nil, если API недоступен)
local function freshBase()
	local s = fetch('https://api.github.com/repos/' .. REPO .. '/commits/main?t=' .. os.time(), TMPJ, 20)
	local sha = s and s:match('^%s*{%s*"sha"%s*:%s*"(%x+)"')
	if sha and #sha == 40 then return 'https://raw.githubusercontent.com/' .. REPO .. '/' .. sha .. '/' end
	return nil
end

local function goodCore(bc, size)
	if not bc or #bc < MIN_CORE then return false end
	if tonumber(size) and #bc ~= tonumber(size) then return false end
	return loadstring(bc) ~= nil
end

-- новый загрузчик: пишем поверх себя; не записался целиком — возвращаем старый
local function installLoader(s)
	local okp, path = pcall(function() return thisScript().path end)
	if not okp or type(path) ~= 'string' then return false end
	local old = readFile(path)
	if not old or old == s then return false end
	if writeFile(path, s) and readFile(path) == s then return true end
	writeFile(path, old)
	return false
end

local function runCheck(manual, curVer)
	local j = parseJson(fetch(RAW_MAIN .. 'version.json?t=' .. os.time(), TMPJ))
	if not j or not j.version then
		-- raw недоступен — пробуем через свежий коммит
		local base = freshBase()
		j = base and parseJson(fetch(base .. 'version.json?t=' .. os.time(), TMPJ))
		if not j or not j.version then setStatus('neterr', curVer); return end
	end
	UPD.latest = j.version
	local coreNew = verNum(j.version) > verNum(curVer)
	local loaderNew = (tonumber(j.loader) or 0) > LOADER_VER
	if not coreNew and not loaderNew then setStatus('uptodate', curVer); return end
	if UPD.dev then
		setStatus(coreNew and 'devnewer' or 'uptodate', coreNew and j.version or curVer); return
	end

	-- version.json с main мог прийти из кэша: берём пару version.json + ядро с одного свежего коммита
	local base = freshBase()
	if base then
		local j2 = parseJson(fetch(base .. 'version.json?t=' .. os.time(), TMPJ))
		if j2 and j2.version then
			j = j2; UPD.latest = j.version
			coreNew = verNum(j.version) > verNum(curVer)
			loaderNew = (tonumber(j.loader) or 0) > LOADER_VER
		else
			base = nil
		end
	end
	if not coreNew and not loaderNew then setStatus('uptodate', curVer); return end

	local bc
	if coreNew then
		setStatus('updating', j.version)
		-- по коммиту — 2 попытки; через main (кэш до 5 минут) — 3 попытки с паузой
		local tries, pause = base and 2 or 3, base and 2000 or 15000
		local got = false
		for i = 1, tries do
			local s = fetch((base or RAW_MAIN) .. (j.core or CORE_DEF) .. '?t=' .. os.time(), TMPD, 90)
			got = got or s ~= nil
			-- размер сверяем только для main: по ссылке на коммит пара version.json + ядро и так из одного коммита
			if goodCore(s, not base and j.size) then bc = s; break end
			if i < tries then wait(pause) end
		end
		if not bc then
			print(LOG .. ' core download failed (' .. (got and 'bad data' or 'network') .. ')')
			setStatus(got and 'baddata' or 'neterr', j.version); return
		end
	end

	-- загрузчик: не скачался — не беда, ядро всё равно ставим, загрузчик в следующий раз
	if loaderNew and j.file then
		local s = fetch((base or RAW_MAIN) .. j.file .. '?t=' .. os.time(), TMPD, 30)
		if s and #s > 2000 and s:find(MARK, 1, true) and loadstring(s) then
			if installLoader(s) then print(LOG .. ' loader updated to v' .. tostring(j.loader)) end
		end
	end

	if not bc then setStatus('uptodate', curVer); return end
	if exists(DAT) then writeFile(DAT .. '.bak', readFile(DAT) or '') end
	if not writeFile(DAT, bc) or readFile(DAT) ~= bc then
		local old = readFile(DAT .. '.bak'); if old then writeFile(DAT, old) end
		setStatus('writeerr', j.version); return
	end
	setStatus('updated', j.version)
	return 'reload' -- перезапуск делает updWorker, вне pcall
end

-- ядро просит проверку — только ставим заявку; выполняет её поток загрузчика (updWorker)
function UPD.check(manual, curVer)
	if UPD.dev and DEV_SKIP then setStatus('devbuild', curVer); return end
	if UPD.busy or UPD.req then return end
	UPD.req = { manual, curVer }
	setStatus('checking', curVer)
end

local function updWorker()
	while true do
		wait(200)
		local r = UPD.req
		if r then
			UPD.busy, UPD.at = true, os.clock()
			local ok, res = pcall(runCheck, r[1], r[2])
			if not ok then print(LOG .. ' update error: ' .. tostring(res)); setStatus('neterr', r[2]) end
			UPD.req, UPD.busy = nil, false
			if ok and res == 'reload' then wait(300); thisScript():reload(); wait(5000) end
		end
	end
end

-- ядра нет совсем (поставили только загрузчик): скачать с GitHub и перезапуститься
local function firstInstall()
	wait(3000)
	for _ = 1, 3 do
		local base = freshBase()
		local j = base and parseJson(fetch(base .. 'version.json?t=' .. os.time(), TMPJ))
		local s = fetch((base or RAW_MAIN) .. ((j and j.core) or CORE_DEF) .. '?t=' .. os.time(), TMPD, 90)
		if goodCore(s, not base and j and j.size) and writeFile(DAT, s) then
			UPD.busy = false
			wait(300)
			thisScript():reload()
			return
		end
		wait(10000)
	end
	UPD.busy = false; setStatus('neterr')
	print(LOG .. ' core not found and could not be downloaded')
end
-- ===================== конец общего блока =====================

-- ============================ запуск ============================
local chunk, srcChunk

-- DEV: есть исходник — компилируем его в урезанный байткод и перезаписываем .dat
local code = readFile(SRC)
if code then
	local c, err = loadstring(code, '@qwe_mining_core')
	if not c then print('[QWE Mining loader] ошибка компиляции исходника: ' .. tostring(err)); return end
	srcChunk = c
	local ok, bc = pcall(string.dump, c, true) -- true = убрать отладочную информацию
	if ok and type(bc) == 'string' and #bc > 0 then
		writeFile(DAT, bc)
	else
		print('[QWE Mining loader] string.dump не сработал, запуск из исходника')
	end
	UPD.dev = true
	-- Android (тест у игроков): ядро собрано — исходник убираем, дальше работает только .dat.
	-- У разработчика рядом лежит qwe_dev.txt — исходник остаётся.
	if MOBILE and ok and type(bc) == 'string' and #bc > 0 and not exists(DEVF) and loadfile(DAT) then
		os.remove(SRC)
		UPD.dev = false
	end
end

local c, err = loadfile(DAT)
if c then
	chunk = c
elseif srcChunk then
	print('[QWE Mining loader] байткод не загрузился (' .. tostring(err) .. '), запуск из исходника')
	chunk = srcChunk
else
	-- Нет ни исходника, ни ядра (например, поставили только загрузчик): один раз
	-- скачиваем ядро с GitHub и перезапускаемся. Обычная установка идёт с .dat.
	if MOBILE then
		-- ядра для телефона на GitHub пока нет — не качаем, иначе перезапуск по кругу
		function main()
			while not isSampAvailable() do wait(500) end
			sampAddChatMessage('[QWE Mining] Не найден файл qwe_mining_core.src / .android.dat — положите его рядом со скриптом.', 0xFF69B4)
		end
		return
	end
	print(LOG .. ' core not found, downloading from GitHub...')
	UPD.busy = true; setStatus('updating')
	function main()
		firstInstall()
		while true do wait(1000) end
	end
	return
end

chunk()

-- поток автообновления запускаем рядом с main() ядра
local coreMain = main
function main()
	lua_thread.create(updWorker)
	if coreMain then return coreMain() end
	while true do wait(1000) end
end
