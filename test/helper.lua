--- Общие средства проверок каркаса: исходники, чтение окружения,
--- словарь диагностики и снимок кластера.
---
--- Исходники пакета читаются с диска, а не через `require`: у Tarantool
--- свой загрузчик `.rocks`, он идёт раньше `package.path` и подсунул бы
--- установленную копию пакета, если она есть. Проверки тогда шли бы
--- против вчерашнего кода, а покрытие считалось бы по нему. Зависимости
--- пакета — `tnt.env`, `tnt.must`, `tnt.external` — стоят в `.rocks`:
--- проверяется этот пакет, а не они.
---
--- Реестр диагностики `tnt.cluster.issues` из `tnt-cluster-health` нужен
--- только проверкам: правило проверяется против договора, по которому
--- его находки читают. Он тоже стоит в `.rocks` (`make deps`).
---
--- Оснастка в `test/testing/` — загрузчик исходников и фабрика записей —
--- грузится файлами и один раз на процесс: второй экземпляр загрузчика
--- не знал бы, что вытеснил первый, и не вернул бы вытесненное на место.
---
--- Проверки берут всё отсюда и ничего — из оснастки напрямую: так
--- у каждого средства одно место, и его можно подменить целиком, не трогая
--- ни одного файла проверок.

local fio = require('fio')

--- Модули оснастки. Друг от друга они не зависят.
local TESTING = {
    { name = 'tnt.testing.sources', path = 'test/testing/sources.lua' },
    { name = 'tnt.testing.factory', path = 'test/testing/factory.lua' },
}

for _, module in ipairs(TESTING) do
    if package.loaded[module.name] == nil then
        local chunk, failure = loadfile(fio.abspath(module.path))

        if chunk == nil then
            error(('оснастка %s не читается: %s'):format(module.name, tostring(failure)))
        end

        package.loaded[module.name] = chunk()
    end
end

--- Оснастка проверок под теми именами, что зовёт помощник.
local testing = {
    load_sources = package.loaded['tnt.testing.sources'].load,
    unload_sources = package.loaded['tnt.testing.sources'].unload,
    factory = package.loaded['tnt.testing.factory'].define,
}

local helper = {}

--- Модули пакета в порядке зависимостей.
---
--- Правило диагностики каркас подключает сам, и оно тоже берётся
--- из исходника: иначе `require` изнутри каркаса нашёл бы соседа
--- в `.rocks`.
helper.MODULES = {
    { name = 'tnt.ce.extras.diagnosis', path = 'tnt/ce/extras/diagnosis.lua' },
    { name = 'tnt.ce.extras', path = 'tnt/ce/extras.lua' },
}

--- Точка входа, которую ядро берёт под именем `internal.config.extras`.
---
--- Отдельно от модулей пакета: она зовёт проверку редакции при загрузке,
--- и проверке отказа на Enterprise нужно подменить редакцию у уже
--- загруженного каркаса, а потом загрузить поверх него одну точку входа.
helper.ENTRYPOINT = {
    { name = 'internal.config.extras', path = 'internal/config/extras.lua' },
}

--- Чтение окружения из `.rocks` — файлами, в порядке зависимостей.
---
--- Файлами, а не `require`: у чтения есть общее на процесс, и каждой
--- проверке нужен свой экземпляр, а `require` отдал бы один на всех.
--- Путь — тот, куда `make deps` ставит `tnt-env`.
local ENVIRONMENT = {
    { name = 'tnt.env.cast', path = '.rocks/share/tarantool/tnt/env/cast.lua' },
    { name = 'tnt.env.example', path = '.rocks/share/tarantool/tnt/env/example.lua' },
    { name = 'tnt.env.parse', path = '.rocks/share/tarantool/tnt/env/parse.lua' },
    { name = 'tnt.env.secret', path = '.rocks/share/tarantool/tnt/env/secret.lua' },
    { name = 'tnt.env', path = '.rocks/share/tarantool/tnt/env.lua' },
}

--- Загружает исходники пакета заново и отдаёт модуль по имени.
---
--- Заново на каждую проверку: реестр расширений и отметка о патче схемы
--- живут в модуле, и оставленные соседней проверкой они сделали бы
--- порядок проверок частью их смысла.
---@param name string Имя модуля, например tnt.ce.extras
---@return any
function helper.load(name)
    return testing.load_sources(helper.MODULES, name)
end

--- Загружает точку входа поверх уже загруженного каркаса.
---@return table entry Таблица с initialize и post_apply
function helper.entrypoint()
    return testing.load_sources(helper.ENTRYPOINT, 'internal.config.extras')
end

--- Чтение окружения, собранное заново.
---
--- Каркас берёт его через `require` при загрузке, поэтому оно грузится
--- раньше каркаса: так подмена окружения доходит до того экземпляра,
--- который взял каркас. Заново — потому что у чтения есть общее
--- на процесс, и оставленное соседней проверкой оно считалось бы уже
--- заведённым.
---@return table env Модуль `tnt.env`
function helper.env()
    return testing.load_sources(ENVIRONMENT, 'tnt.env')
end

--- Убирает из `package.loaded` всё, что загрузили проверки, и возвращает
--- на место то, что было до них.
function helper.unload()
    testing.unload_sources(helper.ENTRYPOINT)
    testing.unload_sources(helper.MODULES)
    testing.unload_sources(ENVIRONMENT)
end

--- Окружение и файлы, в которых задано ровно то, что назвала проверка.
---
--- Настоящая переменная процесса делала бы проверку зелёной ровно до тех
--- пор, пока её не задали на машине, а настоящий `.env` рядом — чужой.
--- `files` — что лежит на диске, `vars` — что задано при запуске.
---@param world { files: table<string, string>|nil, vars: table<string, string>|nil }
---@return table
function helper.world(world)
    local files = world.files or {}
    local vars = world.vars or {}

    return {
        getenv = function(name)
            return vars[name]
        end,

        exists = function(path)
            return files[path] ~= nil
        end,

        read = function(path)
            if files[path] == nil then
                return nil, 'нет такого файла'
            end

            return files[path]
        end,
    }
end

--- Тот же мир, но считающий прочтения файлов.
---
--- Проверке бывает нужно знать, сколько раз и какие файлы открыл пакет,
--- а не только что он из них взял: сколько раз `.env` читается на одно
--- чтение конфигурации и чей именно.
---@param world table Мир от `world`
---@return table world Тот же мир: `read` записывает путь и читает дальше
---@return string[] reads Пути прочитанных файлов по порядку; пополняется
function helper.counted(world)
    local read = world.read
    local reads = {}

    world.read = function(path)
        table.insert(reads, path)

        return read(path)
    end

    return world, reads
end

--- Словарь диагностики: уровни, области, опознание и сборка находок.
---
--- Настоящий реестр правил, а не двойник: правило проверяется против
--- договора, по которому его находки читают, и двойник разошёлся бы
--- с договором молча.
---
--- Реестр свой у каждого вызывающего и под своим именем не остаётся:
--- его берут при загрузке файла проверки, и оставленный он достался бы
--- соседям вместо их собственного.
---@return table
function helper.vocabulary()
    local previous = package.loaded['tnt.cluster.issues']

    package.loaded['tnt.cluster.issues'] = nil

    local vocabulary = require('tnt.cluster.issues')

    package.loaded['tnt.cluster.issues'] = previous

    return vocabulary
end

local instance_factory = testing.factory({
    replicaset_name = 'storage-001',
    reachable = true,
    status = 'running',
    ro = true,
    vclock = { [1] = 10 },
})

--- Узел в снимке кластера: то, что знает о нём опрос. Вид записи общий
--- на все правила диагностики.
---@param name string
---@param overrides table|nil Изменения отдельных полей
---@return table
function helper.instance(name, overrides)
    local entry = instance_factory.build(overrides)

    -- Имя из подмены главнее названного: проверки задают его и так.
    if entry.name == nil then
        entry.name = name
    end

    return entry
end

--- Снимок кластера из перечисленных узлов.
---@param ... table Записи об узлах
---@return table
function helper.snapshot(...)
    local instances = {}

    for _, entry in ipairs({ ... }) do
        instances[entry.name] = entry
    end

    return { instances = instances }
end

return helper
