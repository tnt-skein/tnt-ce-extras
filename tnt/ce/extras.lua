--- Каркас расширений конфигурации для Community Edition.
---
--- Tarantool при старте вызывает require('internal.config.extras'). В
--- Enterprise этот модуль встроен в бинарник и добавляет проприетарные
--- источники конфигурации; в Community его нет, и комментарий в самом ядре
--- прямо разрешает подставить свой: «Tarantool Community Edition may be
--- extended using the same mechanism».
---
--- Точка входа одна на процесс, поэтому владеть ею должен один пакет.
--- Этот модуль — реестр: расширения объявляют, какие узлы схемы им нужно
--- открыть и какой источник конфигурации зарегистрировать, а каркас
--- применяет заявки в нужный момент загрузки.
---
--- Расширения перечисляются в TNT_CE_EXTENSIONS через запятую. Без этой
--- переменной каркас не делает ничего: установка пакета сама по себе
--- не должна менять поведение инстанса.
---
--- Переменная читается через `tnt-env`, а не `os.getenv`: ядро зовёт
--- каркас раньше всего приложения, и узел, поднятый без оболочки,
--- которая читает `.env`, иначе не увидел бы записанного там списка.
--- Цена — негодный `.env` в каталоге запуска останавливает старт уже
--- здесь, даже без расширений: это договор `tnt-env`, и приложение,
--- читающее окружение тем же пакетом, отказало бы на нём же при первом
--- применении конфигурации.

local env = require('tnt.env')
local fail = require('tnt.must.fail')

local diagnosis = require('tnt.ce.extras.diagnosis')

local Module = {}

--- Правило диагностики о ревизии конфигурации: его регистрируют в реестре
--- правил, а оно само берёт то, что каркас рассказал зонду.
Module.diagnosis = diagnosis

--- Переменная окружения со списком подключаемых расширений.
local ENV_EXTENSIONS = 'TNT_CE_EXTENSIONS'

--- Отказ списка, в котором имена разделены пробелом.
local SPACED =
    'переменная окружения %s: в имени расширения «%s» пробел, а разделитель — запятая'

--- Заявки расширений в порядке регистрации.
--- Каждая запись: имя расширения и его заявка — открываемые пути схемы,
--- фабрика источника конфигурации и хук после применения.
---@type { name: string, spec: table }[]
local registry = {}

--- Имена уже зарегистрированных расширений: повторная регистрация — ошибка.
---@type table<string, boolean>
local registered = {}

--- Источники конфигурации, созданные расширениями.
---
--- Запоминаются потому, что ядру они отдаются безвозвратно: `_register_source`
--- ничего не возвращает, и спросить источник о себе потом неоткуда.
--- А спрашивать есть о чём — какую ревизию он прочитал и не живёт ли узел
--- на устаревшем снимке.
---@type table<string, table>
local sources = {}

--- Модуль конфигурации, который ядро отдало каркасу при инициализации.
---
--- Держится ради одного вопроса — какая ревизия применена. Ответ знает
--- только ядро: источник рассказывает ему прочитанную, а применённой ядро
--- её называет лишь после удачного применения (`config:info('v2')`).
--- Спрашивается тот же модуль, который зовёт каркас, а не `require`:
--- другого ядра у процесса нет, а аргумент проверка подменяет без обходов.
---@type any
local kernel = nil

--- Признак того, что схема уже пропатчена: обход дерева необратим,
--- повторять его бессмысленно.
local schema_patched = false

--- Сколько узлов схемы было открыто при инициализации.
local relaxed_nodes = 0

--- Отказ, которым проверка редакции отвергает в Community узел с меткой
--- «только Enterprise».
---
--- Сверяется всем текстом: другого признака у этого отказа нет — проверка
--- редакции зовёт `w.error` тем же путём, что и своя проверка узла.
--- Сменит ядро текст — открытый узел снова отвергнется словами
--- о редакции, громко, на первом же старте, а проверка пакета на настоящей
--- цепочке ядра упадёт раньше.
local ENTERPRISE_ONLY = 'This configuration parameter is available only in Tarantool Enterprise Edition'

--- Проверка открытого узла: прежняя цепочка ядра без отказа о редакции.
---
--- Ядро сцепляет свою проверку значения узла с проверкой редакции в одну
--- функцию, и разнять цепочку снаружи нечем. Зато обе половины отказывают
--- одним путём — вызовом `w.error`, — поэтому цепочка зовётся целиком,
--- а в `w` глохнет ровно отказ о редакции. Своя проверка ядра остаётся:
--- `config.etcd` без `prefix` отвергается, как и в Enterprise, а не
--- всплывает ошибкой позже, в самом источнике. Проверка редакции бросает
--- последним своим шагом, поэтому заглушённый вызов просто возвращается,
--- и цепочка идёт дальше.
---
--- Подменяется копия `w`, а не он сам: остальное в нём — путь и схема
--- узла — нужно проверкам ядра как есть, а объект ядра незачем править.
---@param validate fun(data: any, w: table) Цепочка проверок узла
---@return fun(data: any, w: table)
local function without_edition_check(validate)
    return function(data, w)
        local muted = table.copy(w)

        muted.error = function(message, ...)
            if message ~= ENTERPRISE_ONLY then
                w.error(message, ...)
            end
        end

        validate(data, muted)
    end
end

--- Умолчание применяется всегда, а не только в Enterprise.
---
--- Умолчание узла, в отличие от проверки, заменяется целиком: проверка
--- редакции отвечает в нём значением, а не отказом, и заглушить её нечем.
--- Своего условия там нет — на 3.8 у каждого из 370 узлов с меткой
--- умолчание решает одна проверка редакции.
local function always_true()
    return true
end

--- Подходит ли путь узла под один из открываемых префиксов.
---
--- Ответ — `true` либо ничего: он идёт только в условие, а явная ложь
--- в конце ничем не отличалась бы от пустоты, и проверить её было бы нечем.
---
--- Начало пути сверяет `startswith` Tarantool, буквально и без чисел:
--- у среза `path:sub(1, #prefix + 1)` мутанты начала `0` и `1-1` давали
--- ту же строку и были неотличимы.
---@param path string
---@param prefixes string[]
---@return true|nil
local function path_allowed(path, prefixes)
    for _, prefix in ipairs(prefixes) do
        if path == prefix or path:startswith(prefix .. '.') then
            return true
        end
    end
end

--- Рекурсивно снимает enterprise-гейт с узлов схемы под разрешёнными путями.
--- Всё, что вне списка, сохраняет проверки и по-прежнему отвергается в CE,
--- а открытый узел теряет из своей проверки только отказ о редакции.
---@param node any Узел схемы
---@param path string Путь от корня схемы через точку
---@param prefixes string[] Открываемые пути
---@return integer relaxed Сколько узлов открыто
local function relax_ee_nodes(node, path, prefixes)
    if type(node) ~= 'table' then
        return 0
    end

    local relaxed = 0

    if node.enterprise_edition == true and path_allowed(path, prefixes) then
        node.validate = without_edition_check(node.validate)
        node.apply_default_if = always_true
        -- Метка снимается, иначе схема считается собранной не до конца.
        node.enterprise_edition = false
        relaxed = 1
    end

    -- Записи хранят потомков в fields, массивы и словари — в items,
    -- key и value. Обходятся все формы, которыми пользуется схема.
    if type(node.fields) == 'table' then
        for name, child in pairs(node.fields) do
            local child_path = path == '' and name or (path .. '.' .. name)
            relaxed = relaxed + relax_ee_nodes(child, child_path, prefixes)
        end
    end

    if type(node.items) == 'table' then
        relaxed = relaxed + relax_ee_nodes(node.items, path .. '.*', prefixes)
    end

    if type(node.key) == 'table' then
        relaxed = relaxed + relax_ee_nodes(node.key, path .. '.[key]', prefixes)
    end

    if type(node.value) == 'table' then
        relaxed = relaxed + relax_ee_nodes(node.value, path .. '.[value]', prefixes)
    end

    return relaxed
end

--- Считает узлы схемы, помеченные как доступные только в Enterprise.
--- Нужен диагностике: расхождение с ожиданием означает, что при обновлении
--- Tarantool схема изменилась и список префиксов пора пересмотреть.
---@param node any
---@return integer
local function count_ee_nodes(node)
    if type(node) ~= 'table' then
        return 0
    end

    local count = node.enterprise_edition == true and 1 or 0

    if type(node.fields) == 'table' then
        for _, child in pairs(node.fields) do
            count = count + count_ee_nodes(child)
        end
    end

    for _, key in ipairs({ 'items', 'key', 'value' }) do
        if type(node[key]) == 'table' then
            count = count + count_ee_nodes(node[key])
        end
    end

    return count
end

--- Откуда брать название редакции Tarantool. Подменяется в тестах:
--- встроенный модуль tarantool через package.loaded не подменяется.
---@type (fun(): string)|nil
local edition_provider = nil

--- Название текущей редакции Tarantool.
---@return string
local function current_edition()
    if edition_provider ~= nil then
        return edition_provider()
    end

    return require('tarantool').package
end

--- Проверяет, что пакет уместен в этой сборке Tarantool.
--- В Enterprise модуль internal.config.extras встроен в бинарник, и подмена
--- отключила бы штатные источники конфигурации.
function Module.ensure_community_edition()
    local edition = current_edition()

    if edition == 'Tarantool Enterprise' then
        error(
            'пакет tnt-ce-extras предназначен только для Community Edition: '
                .. 'в Enterprise модуль internal.config.extras встроен в бинарник'
        )
    end

    return edition
end

--- Откуда брать схемы для патча. Подменяется в тестах: патч необратим,
--- и трогать настоящие схемы процесса ради проверки нельзя.
---@type (fun(): table[])|nil
local schema_provider = nil

--- Схемы, которые надо патчить.
--- cluster_config строит свои копии схемы инстанса, и копия неглубокая —
--- узлы с меткой Enterprise там свои, поэтому обходятся обе схемы.
---
--- Модули схем берутся без страховки: оба встроены в бинарник 3.x, и ядро
--- конфигурации загружает их в своей шапке раньше, чем зовёт `initialize`.
--- Прежний молчаливый пропуск незагрузившегося модуля был недостижим,
--- а на сборке без схемы узел всё равно не поднялся бы — ядро отвергло бы
--- `config.etcd`, — только без названной причины. Ошибка загрузки здесь,
--- как и у расширений, не проглатывается.
---@return table[] schemas
local function target_schemas()
    if schema_provider ~= nil then
        return schema_provider()
    end

    local schemas = {}

    for _, name in ipairs({ 'internal.config.instance_config', 'internal.config.cluster_config' }) do
        table.insert(schemas, require(name).schema)
    end

    return schemas
end

--- Регистрирует расширение.
---@param name string Имя расширения, для диагностики и защиты от повторов
---@param spec { relax_prefixes: string[]|nil, source: (fun(): table)|nil, post_apply: (fun(config: table))|nil }
function Module.register(name, spec)
    if type(name) ~= 'string' or name == '' then
        error('имя расширения должно быть непустой строкой')
    end

    if registered[name] then
        error(('расширение %s уже зарегистрировано'):format(name))
    end

    if type(spec) ~= 'table' then
        error(('заявка расширения %s должна быть таблицей'):format(name))
    end

    if spec.relax_prefixes ~= nil and type(spec.relax_prefixes) ~= 'table' then
        error(('relax_prefixes расширения %s должен быть списком строк'):format(name))
    end

    if spec.source ~= nil and type(spec.source) ~= 'function' then
        error(('source расширения %s должен быть функцией-фабрикой'):format(name))
    end

    if spec.post_apply ~= nil and type(spec.post_apply) ~= 'function' then
        error(('post_apply расширения %s должен быть функцией'):format(name))
    end

    registered[name] = true
    table.insert(registry, { name = name, spec = spec })
end

--- Список расширений из окружения.
---
--- Список режется по запятой и только по ней, пробелы по краям имени
--- снимаются, пустые куски отбрасываются — правило `env.list`, одно на все
--- списки из окружения. Пустая переменная — пустой список.
---
--- Пробел внутри имени — отказ со своим текстом. Имени модуля с пробелом
--- не бывает, а до перехода на `tnt-env` пробел был разделителем, и узел
--- со старым списком `app.first app.second` иначе отказал бы словами
--- «расширение … не загрузилось: module not found» — искать пришлось бы
--- пропавший модуль, а не разделитель. Пробел в разделители не вернулся:
--- правило списков одно на всё окружение. Проверяется весь список до
--- первой загрузки: имя с пробелом значит, что неверно записан весь
--- список, и грузить до отказа его начало незачем.
---
--- Бросок без места, как у отказов самого `tnt-env`: текст уходит
--- оператору, и приписка «extras.lua:NN:» отправила бы искать причину
--- в пакете, а не в окружении.
---
--- Чтение своё, а не общее на процесс: каркас зовут раньше приложения —
--- до `box.cfg` и до перехода в `process.work_dir`, — и общее чтение,
--- заведённое здесь, закрепило бы за приложением `.env` стартового
--- каталога.
---
--- Файл — `.env` каталога запуска, и другого здесь не бывает: каркас
--- зовут раньше, чем хоть один источник назвал `process.work_dir`.
--- Читается список однажды на процесс — расширения заводятся при
--- инициализации, и ни применение конфигурации, ни `config:reload()`
--- его не перечитывают. Строка `TNT_CE_EXTENSIONS` в `.env` рабочего
--- каталога поэтому не действует никогда, а не «со второго раза»
--- (опыт на 3.8 — `docs/ce-extras.md`, «Откуда берётся список»).
---@return string[] names Имена модулей расширений
local function requested_extensions()
    local names = env.new():list(ENV_EXTENSIONS, {}) --[[@as string[] ]]

    for _, module_name in ipairs(names) do
        if module_name:find('%s') then
            fail.raise(SPACED:format(ENV_EXTENSIONS, module_name))
        end
    end

    return names
end

--- Загружает перечисленные в окружении расширения.
--- Ошибка загрузки не проглатывается: молча поднявшийся инстанс без
--- обещанного источника конфигурации хуже, чем отказ на старте.
local function load_requested_extensions()
    for _, module_name in ipairs(requested_extensions()) do
        local ok, err = pcall(require, module_name)
        if not ok then
            error(('расширение %s не загрузилось: %s'):format(module_name, tostring(err)))
        end
    end
end

--- Открывает узлы схемы по заявкам расширений.
---
--- Сколько открыто, запоминается в `relaxed_nodes`, а не возвращается:
--- спрашивает это только `status`, и ответ, который никто не читает,
--- проверить нечем.
local function apply_schema_relaxations()
    if schema_patched then
        return
    end

    local prefixes = {}
    for _, entry in ipairs(registry) do
        for _, prefix in ipairs(entry.spec.relax_prefixes or {}) do
            table.insert(prefixes, prefix)
        end
    end

    if #prefixes == 0 then
        return
    end

    local relaxed = 0
    for _, schema in ipairs(target_schemas()) do
        relaxed = relaxed + relax_ee_nodes(schema, '', prefixes)
    end

    schema_patched = true
    relaxed_nodes = relaxed
end

--- Вызывается Tarantool при инициализации конфигурации.
---@param config table Модуль конфигурации Tarantool
function Module.initialize(config)
    kernel = config

    load_requested_extensions()
    -- Отдельного выхода на пустом реестре нет: открывать тогда нечего,
    -- и apply_schema_relaxations выходит сама, не тронув ни схем, ни
    -- отметки о патче, а обход пустого реестра ничего не делает.
    apply_schema_relaxations()

    for _, entry in ipairs(registry) do
        if entry.spec.source ~= nil then
            local source = entry.spec.source()
            if type(source) ~= 'table' then
                error(
                    ('расширение %s не создало источник конфигурации'):format(
                        entry.name
                    )
                )
            end

            sources[entry.name] = source

            config:_register_source(source)
        end
    end
end

--- Источники, созданные расширениями.
---
--- Нужны приложению: по ним видно, откуда пришла конфигурация и не поднялся
--- ли узел на устаревшем снимке. Ядро помнит об источнике только то, что
--- тот ему рассказал, — ревизию, — а о снимке не знает вовсе, и сам
--- источник ядро наружу не отдаёт.
---@return table<string, table>
function Module.sources()
    local known = {}

    for name, source in pairs(sources) do
        known[name] = source
    end

    return known
end

--- Вызывается Tarantool после применения конфигурации.
---@param config table
function Module.post_apply(config)
    for _, entry in ipairs(registry) do
        if entry.spec.post_apply ~= nil then
            entry.spec.post_apply(config)
        end
    end
end

--- Состояние каркаса: что подключено и сколько узлов схемы открыто.
--- Число открытых узлов — рабочая диагностика: если после обновления
--- Tarantool оно изменилось, значит схема поехала и список префиксов
--- пора пересмотреть.
---@return { extensions: string[], relaxed_nodes: integer, schema_patched: boolean, sources: table<string, table> }
function Module.status()
    local reported = {}

    for name, source in pairs(sources) do
        -- Состояние спрашивается, только если источник умеет о себе
        -- рассказывать: договор ядра этого не требует.
        if type(source.status) == 'function' then
            local ok, state = pcall(source.status, source)

            reported[name] = ok and state or { err = tostring(state) }
        end
    end

    return {
        extensions = Module.registered_names(),
        relaxed_nodes = relaxed_nodes,
        schema_patched = schema_patched,
        sources = reported,
    }
end

--- Рассказывает зонду об источниках конфигурации.
---
--- Рассказ о каждом источнике собран из двух половин. Своё источник
--- говорит сам: взята ли конфигурация из снимка, откуда и когда прочитана.
--- Ревизии — у ядра: прочитанную ему рассказал источник, а применённой
--- ядро её называет только после удачного применения. Судить по одной
--- прочитанной нельзя: узел, прочитавший новую ревизию и упавший на
--- применении, живёт на прежней. А знать применённую надо всем — по ней
--- и видно, одну ли конфигурацию применил кластер.
---
--- Отказ ядра ответить не прячется: сборщик падает, и зонд помечает поле
--- ошибкой — судить тогда не о чем, и правило молчит.
---
--- Регистратор подаётся аргументом: каркас не зависит от того, кто ведёт зонд,
--- и работает с любым, кто умеет принять поле.
---
---     extras.publish_probe(probe.register)
---@param register fun(name: string, collector: fun(): any)
function Module.publish_probe(register)
    register(diagnosis.PROBE_FIELD, function()
        local described = {}

        for name, own in pairs(Module.status().sources) do
            described[name] = diagnosis.describe(sources[name].name, own, kernel:info('v2'))
        end

        return described
    end)
end

--- Добавляет правило о ревизии конфигурации в реестр диагностики.
---
--- Пара к публикации в зонде: там узел рассказывает, что применил, здесь
--- рассказанное превращается в находки.
---
---     extras.publish_rule(issues)
---@param issues table Реестр правил: register, SEVERITY и about_instance
function Module.publish_rule(issues)
    issues.register(diagnosis.RULE, diagnosis.rule(issues))
end

--- Сколько узлов схемы всё ещё помечено как Enterprise-только.
--- Используется тестом, который стережёт совместимость с версией Tarantool.
---@return integer
function Module.count_enterprise_nodes()
    local total = 0
    for _, schema in ipairs(target_schemas()) do
        total = total + count_ee_nodes(schema)
    end

    return total
end

--- Имена зарегистрированных расширений.
---@return string[]
function Module.registered_names()
    local names = {}
    for _, entry in ipairs(registry) do
        table.insert(names, entry.name)
    end

    return names
end

--- Подменяет источник схем. Только для тестов.
---@param provider (fun(): table[])|nil
function Module._set_schema_provider(provider)
    schema_provider = provider
end

--- Подменяет источник названия редакции. Только для тестов.
---@param provider (fun(): string)|nil
function Module._set_edition_provider(provider)
    edition_provider = provider
end

--- Сбрасывает состояние. Только для тестов.
function Module._reset()
    sources = {}
    registry = {}
    registered = {}
    schema_patched = false
    relaxed_nodes = 0
    schema_provider = nil
    edition_provider = nil
end

return Module
