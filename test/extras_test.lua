--- Тесты каркаса расширений конфигурации.
---
--- Настоящие схемы Tarantool не трогаются: патч необратим и действует на
--- весь процесс, поэтому источник схем подменяется поддельным деревом.

local t = require('luatest')

local g = t.group('tnt.ce.extras')

local helper = dofile('test/helper.lua')

--- Отказ проверки редакции — тем текстом, каким его пишет ядро 3.8.
local ENTERPRISE_ONLY = 'This configuration parameter is available only in Tarantool Enterprise Edition'

--- Проверка редакции, какой ядро цепляет к узлу с меткой: пустое значение
--- пропускает, любое другое отвергает.
---@param data any
---@param w table
local function edition_check(data, w)
    if data ~= nil then
        w.error(ENTERPRISE_ONLY)
    end
end

--- Своя проверка узла `config.etcd`, какой её держит ядро: раздел
--- с данными обязан назвать `prefix`.
---@param data table
---@param w table
local function etcd_check(data, w)
    if next(data) ~= nil and data.prefix == nil then
        w.error('No config.etcd.prefix provided')
    end
end

--- Две проверки подряд: так ядро сцепляет свою проверку узла
--- с проверкой редакции.
---@param first fun(data: any, w: table)
---@param second fun(data: any, w: table)
---@return fun(data: any, w: table)
local function chain(first, second)
    return function(data, w)
        first(data, w)
        second(data, w)
    end
end

--- Второй аргумент проверки узла, каким его собирает ядро: путь до узла
--- и отказ, который бросает текст с подставленными значениями без места.
---@param path string[]
---@return table w
local function kernel_w(path)
    return {
        path = path,
        error = function(message, ...)
            error(message:format(...), 0)
        end,
    }
end

--- Собирает поддельное дерево схемы с узлами, помеченными как
--- доступные только в Enterprise.
---@return table
local function build_schema()
    local function ee_node()
        return {
            enterprise_edition = true,
            validate = edition_check,
            apply_default_if = function()
                return false
            end,
        }
    end

    return {
        fields = {
            config = {
                fields = {
                    etcd = {
                        enterprise_edition = true,
                        validate = chain(etcd_check, edition_check),
                        apply_default_if = function()
                            return false
                        end,
                        fields = {
                            endpoints = ee_node(),
                        },
                    },
                    storage = ee_node(),
                },
            },
            iproto = {
                fields = {
                    listen = ee_node(),
                },
            },
            -- Массивы, словари и обычные узлы: обход обязан заходить в них,
            -- но метку снимать только под разрешёнными путями.
            memtx = {
                items = ee_node(),
                key = ee_node(),
                value = ee_node(),
            },
        },
    }
end

--- Заново загружает каркас с подставленным деревом схемы.
---@param schema table|nil
---@return table extras
---@return table schema
local function load_extras(schema)
    schema = schema or build_schema()

    local extras = helper.load('tnt.ce.extras')
    extras._set_schema_provider(function()
        return { schema }
    end)

    return extras, schema
end

--- Двойник модуля конфигурации Tarantool: запоминает переданные источники
--- и отвечает на вопрос о применённой конфигурации.
---@param info table|nil Что ядро отдаёт на `config:info('v2')`
---@return table config
---@return table[] registered
local function fake_config(info)
    local sources = {}

    return {
        _register_source = function(_, source)
            table.insert(sources, source)
        end,

        info = function(_, version)
            -- Второе поколение ответа обязательно: только в нём ядро
            -- отличает прочитанное от применённого.
            t.assert_equals(version, 'v2')

            return info or { status = 'ready', meta = {}, alerts = {} }
        end,
    },
        sources
end

--- Задаёт список расширений в окружении, которое видит каркас.
---@param value string|nil
local function set_extensions(value)
    g.vars.TNT_CE_EXTENSIONS = value
end

-- Окружение каркас читает через `tnt-env`, и оно подменяется его внешней зависимостью:
-- настоящая переменная процесса делала бы проверку зелёной ровно до тех
-- пор, пока её не задали на машине, а настоящий `.env` рядом — чужой.
-- Чтение собирается заново до каркаса, чтобы `require` внутри каркаса
-- нашёл именно его.
g.before_each(function()
    g.vars = {}
    g.env = helper.env()
    g.env._set_source(helper.world({ vars = g.vars }))
    g.extras = load_extras()
end)

g.after_each(function()
    g.env._set_source(nil)
    helper.unload()
end)

-- Заявка с именем и префиксами принимается.
g.test_register_accepts_valid_spec = function()
    g.extras.register('etcd', { relax_prefixes = { 'config.etcd' } })

    t.assert_equals(g.extras.registered_names(), { 'etcd' })
end

-- Порядок регистрации сохраняется: расширения применяются в нём же.
g.test_register_keeps_order = function()
    g.extras.register('первое', {})
    g.extras.register('второе', {})

    t.assert_equals(g.extras.registered_names(), { 'первое', 'второе' })
end

-- Пустое или нестроковое имя отвергается.
g.test_register_rejects_blank_name = function()
    t.assert_error_msg_contains('непустой строкой', g.extras.register, '', {})
    t.assert_error_msg_contains('непустой строкой', g.extras.register, 42, {})
end

-- Повторная регистрация под тем же именем — ошибка, а не тихая замена.
g.test_register_rejects_duplicate = function()
    g.extras.register('etcd', {})

    t.assert_error_msg_contains('уже зарегистрировано', g.extras.register, 'etcd', {})
end

-- Заявка обязана быть таблицей.
g.test_register_rejects_non_table_spec = function()
    t.assert_error_msg_contains('должна быть таблицей', g.extras.register, 'etcd', 'строка')
end

-- Неверные типы полей заявки отвергаются поимённо.
g.test_register_validates_spec_fields = function()
    t.assert_error_msg_contains('relax_prefixes', g.extras.register, 'a', { relax_prefixes = 'строка' })
    -- Текст сверяется целиком: по нему программист узнаёт, чего от поля ждут.
    t.assert_error_msg_contains(
        'source расширения b должен быть функцией-фабрикой',
        g.extras.register,
        'b',
        { source = 'строка' }
    )
    t.assert_error_msg_contains('post_apply', g.extras.register, 'c', { post_apply = 'строка' })
end

-- Без расширений в окружении каркас не трогает ни схему, ни конфигурацию.
g.test_initialize_without_extensions_does_nothing = function()
    local extras, schema = load_extras()
    local config, sources = fake_config()

    extras.initialize(config)

    t.assert_equals(#sources, 0)
    t.assert_equals(schema.fields.config.fields.etcd.enterprise_edition, true)
end

-- Гейт снимается только под заявленными путями.
g.test_initialize_relaxes_only_requested_prefixes = function()
    local extras, schema = load_extras()
    extras.register('etcd', { relax_prefixes = { 'config.etcd' } })

    extras.initialize(fake_config())

    local etcd = schema.fields.config.fields.etcd
    t.assert_equals(etcd.enterprise_edition, false, 'узел под заявленным путём открыт')
    t.assert_equals(etcd.fields.endpoints.enterprise_edition, false, 'потомок тоже открыт')
    t.assert_equals(
        schema.fields.config.fields.storage.enterprise_edition,
        true,
        'config.storage не заявлен и остаётся закрытым'
    )
    t.assert_equals(
        schema.fields.iproto.fields.listen.enterprise_edition,
        true,
        'iproto.listen не заявлен и остаётся закрытым'
    )
end

-- У открытого узла из проверки уходит отказ о редакции: узел, которого
-- ядро больше ничем не проверяет, принимает значение, а умолчание
-- применяется и в Community.
g.test_relaxed_node_drops_the_edition_check = function()
    local extras, schema = load_extras()
    local etcd = schema.fields.config.fields.etcd
    local w = kernel_w({ 'config', 'etcd', 'endpoints' })

    t.assert_error_msg_equals(ENTERPRISE_ONLY, etcd.fields.endpoints.validate, { 'http://127.0.0.1:2379' }, w)

    extras.register('etcd', { relax_prefixes = { 'config.etcd' } })
    extras.initialize(fake_config())

    -- Бросок провалил бы проверку сам.
    etcd.fields.endpoints.validate({ 'http://127.0.0.1:2379' }, w)
    t.assert_equals(etcd.apply_default_if(), true, 'умолчание применяется и в Community')
end

-- Своя проверка открытого узла остаётся: ядро сцепляет её с проверкой
-- редакции в одну функцию, и раздел без `prefix` отвергается её отказом,
-- как в Enterprise, а не всплывает ошибкой позже, в самом источнике.
-- Годный и пустой раздел принимаются.
g.test_relaxed_node_keeps_its_own_check = function()
    local extras, schema = load_extras()
    local etcd = schema.fields.config.fields.etcd
    local w = kernel_w({ 'config', 'etcd' })

    extras.register('etcd', { relax_prefixes = { 'config.etcd' } })
    extras.initialize(fake_config())

    t.assert_error_msg_equals(
        'No config.etcd.prefix provided',
        etcd.validate,
        { endpoints = { 'http://127.0.0.1:2379' } },
        w
    )
    etcd.validate({ prefix = '/demo' }, w)
    etcd.validate({}, w)
end

-- Любой другой отказ доходит до ядра с подставленными значениями,
-- проверка видит путь и схему из `w` ядра, а после заглушённого отказа
-- о редакции цепочка идёт дальше. Сам `w` ядра не правится.
g.test_relaxed_node_passes_other_refusals_through = function()
    local seen = {}
    local node = {
        enterprise_edition = true,
        validate = chain(edition_check, function(data, w)
            seen = { path = w.path, schema = w.schema }
            w.error('%s: ждали строку, пришло %q', table.concat(w.path, '.'), type(data))
        end),
    }
    local extras = load_extras({ fields = { config = { fields = { etcd = node } } } })
    local w = kernel_w({ 'config', 'etcd' })
    local raise = w.error

    w.schema = node

    extras.register('etcd', { relax_prefixes = { 'config.etcd' } })
    extras.initialize(fake_config())

    t.assert_error_msg_equals('config.etcd: ждали строку, пришло "number"', node.validate, 42, w)
    t.assert_equals(seen.path, { 'config', 'etcd' })
    t.assert_is(seen.schema, node)
    t.assert_is(w.error, raise, 'отказ ядра остался его отказом')
end

-- Открытие проверяется и на настоящей цепочке ядра 3.8. Схемный объект
-- ядра строит своё дерево — копию узла `config.etcd` вместе с его
-- проверкой, — и открывается копия, а не схема процесса: открытие
-- необратимо. Сменит ядро текст отказа о редакции или разнимет цепочку
-- иначе — проверка упадёт здесь, а не на старте узла.
g.test_kernel_chain_keeps_its_own_check = function()
    ---@diagnostic disable-next-line: unresolved-require
    local kernel_schema = require('experimental.config.utils.schema')
    ---@diagnostic disable-next-line: unresolved-require
    local instance_config = require('internal.config.instance_config')
    local original = instance_config.schema.fields.config.fields.etcd
    local probe =
        kernel_schema.new('probe', kernel_schema.record({ config = kernel_schema.record({ etcd = original }) }))
    local extras = load_extras(probe.schema)

    t.assert_error_msg_equals(
        '[probe] config.etcd: ' .. ENTERPRISE_ONLY,
        probe.validate,
        probe,
        { config = { etcd = { prefix = '/demo' } } }
    )

    extras.register('etcd', { relax_prefixes = { 'config.etcd' } })
    extras.initialize(fake_config())

    t.assert_error_msg_equals(
        '[probe] config.etcd: No config.etcd.prefix provided',
        probe.validate,
        probe,
        { config = { etcd = { endpoints = { 'http://127.0.0.1:2379' } } } }
    )
    probe:validate({ config = { etcd = { endpoints = { 'http://127.0.0.1:2379' }, prefix = '/demo' } } })
    t.assert_equals(extras.status().relaxed_nodes, 1)
    t.assert_equals(original.enterprise_edition, true, 'схема процесса не тронута')
end

-- Обход заходит в массивы и словари, а не только в записи.
g.test_initialize_walks_items_key_and_value = function()
    local extras, schema = load_extras()
    extras.register('память', { relax_prefixes = { 'memtx' } })

    extras.initialize(fake_config())

    t.assert_equals(schema.fields.memtx.items.enterprise_edition, false)
    t.assert_equals(schema.fields.memtx.key.enterprise_edition, false)
    t.assert_equals(schema.fields.memtx.value.enterprise_edition, false)
end

-- Источник расширения передаётся модулю конфигурации.
g.test_initialize_registers_source = function()
    local extras = load_extras()
    local source = { name = 'etcd', type = 'cluster' }
    extras.register('etcd', {
        source = function()
            return source
        end,
    })

    local config, sources = fake_config()
    extras.initialize(config)

    t.assert_equals(sources, { source })
end

-- Расширение, не создавшее источник, роняет старт: молча поднявшийся
-- инстанс без обещанного источника хуже отказа.
g.test_initialize_fails_when_source_is_not_a_table = function()
    local extras = load_extras()
    extras.register('etcd', {
        source = function()
            return nil
        end,
    })

    t.assert_error_msg_contains('не создало источник', extras.initialize, fake_config())
end

-- Незагрузившееся расширение из окружения роняет старт.
g.test_initialize_fails_on_missing_extension = function()
    set_extensions('нет.такого.модуля')
    local extras = load_extras()

    t.assert_error_msg_contains('не загрузилось', extras.initialize, fake_config())
end

-- Список расширений разбирается через запятую, пробелы у имён снимаются.
g.test_extensions_list_is_split_by_comma = function()
    set_extensions('нет.первого , нет.второго')
    local extras = load_extras()

    -- Падение на первом имени доказывает, что список разобран, а одинарный
    -- пробел перед «не загрузилось» — что пробел у имени снят.
    t.assert_error_msg_contains(
        "расширение нет.первого не загрузилось: module 'нет.первого' not found",
        extras.initialize,
        fake_config()
    )
end

--- Отказ каркаса на пробел внутри имени расширения.
---@param name string Имя, в котором нашёлся пробел
---@return string
local function spaced(name)
    return ('переменная окружения TNT_CE_EXTENSIONS: в имени расширения «%s» пробел, а разделитель — запятая'):format(
        name
    )
end

-- Пробел внутри имени — не разделитель, но и до загрузки такое имя не
-- доходит: до перехода на `tnt-env` пробел разделял список, и старый
-- список иначе отказал бы словами «не загрузилось» о модуле, которого нет,
-- вместо слов о разделителе. Табуляция — такой же пробел. Отказ сверяется
-- целиком: он без места, как отказы самого `tnt-env`.
g.test_space_inside_a_name_is_refused_as_a_separator = function()
    for _, name in ipairs({
        'нет.первого нет.второго',
        'нет.первого\tнет.второго',
    }) do
        set_extensions(name)
        local extras = load_extras()

        t.assert_error_msg_equals(spaced(name), extras.initialize, fake_config())
    end
end

-- Весь список проверяется до первой загрузки: имя с пробелом в конце
-- отказывает раньше, чем незагружаемое имя в начале, — неверно записан
-- весь список, и грузить до отказа его начало незачем.
g.test_whole_list_is_checked_before_loading = function()
    set_extensions('нет.первого, нет.второго нет.третьего')
    local extras = load_extras()

    t.assert_error_msg_equals(spaced('нет.второго нет.третьего'), extras.initialize, fake_config())
end

-- Список берётся из `.env`, когда в окружении процесса его нет.
g.test_extensions_list_comes_from_the_env_file = function()
    g.env._set_source(helper.world({ files = { ['.env'] = 'TNT_CE_EXTENSIONS=нет.из.файла\n' } }))
    local extras = load_extras()

    t.assert_error_msg_contains(
        'расширение нет.из.файла не загрузилось',
        extras.initialize,
        fake_config()
    )
end

-- Каркас читает окружение своим чтением и общего на процесс не заводит:
-- его зовут до `box.cfg`, и общее чтение закрепило бы за приложением `.env`
-- стартового каталога. Общее, заведённое после, читает файл заново.
g.test_extensions_list_does_not_start_the_shared_reading = function()
    local world, reads = helper.counted(helper.world({ files = { ['.env'] = 'APP_NAME=панель\n' } }))

    g.env._set_source(world)
    load_extras().initialize(fake_config())

    t.assert_equals(#reads, 1, 'каркас прочитал .env сам')

    t.assert_equals(g.env('APP_NAME'), 'панель')
    t.assert_equals(#reads, 2, 'общее чтение заведено заново')
end

-- Список читается однажды — в инициализации и из `.env` текущего каталога,
-- то есть каталога запуска: ядро зовёт каркас раньше, чем хоть один
-- источник назвал `process.work_dir`. Применение конфигурации — и на
-- старте, и на каждом `config:reload()` — файла не перечитывает:
-- расширения заводятся однажды на процесс, и `.env` рабочего каталога
-- их список не меняет.
g.test_extensions_list_is_read_once_from_the_launch_directory = function()
    local world, reads = helper.counted(helper.world({
        files = {
            ['.env'] = 'TNT_CE_EXTENSIONS=\n',
            ['work/.env'] = 'TNT_CE_EXTENSIONS=нет.такого.расширения\n',
        },
    }))
    local config = fake_config()

    g.env._set_source(world)

    local extras = load_extras()

    extras.initialize(config)
    extras.post_apply(config)
    extras.post_apply(config)

    t.assert_equals(reads, { '.env' })
    t.assert_equals(extras.registered_names(), {})
end

-- Пустая переменная окружения равносильна отсутствию расширений.
g.test_blank_extensions_list_is_ignored = function()
    set_extensions('')
    local extras, schema = load_extras()

    extras.initialize(fake_config())

    t.assert_equals(schema.fields.config.fields.etcd.enterprise_edition, true)
end

-- Повторная инициализация не патчит схему второй раз.
g.test_schema_is_patched_once = function()
    local extras, schema = load_extras()
    extras.register('etcd', { relax_prefixes = { 'config.etcd' } })

    extras.initialize(fake_config())
    local patched_validate = schema.fields.config.fields.etcd.validate

    extras.initialize(fake_config())

    t.assert_equals(schema.fields.config.fields.etcd.validate, patched_validate)
end

-- post_apply расширений вызывается с модулем конфигурации.
g.test_post_apply_calls_extensions = function()
    local extras = load_extras()
    local seen = {}
    extras.register('etcd', {
        post_apply = function(config)
            table.insert(seen, config)
        end,
    })

    local config = fake_config()
    extras.post_apply(config)

    t.assert_equals(seen, { config })
end

-- Расширение без post_apply не мешает остальным.
g.test_post_apply_skips_extensions_without_hook = function()
    local extras = load_extras()
    local called = false
    extras.register('без хука', {})
    extras.register('с хуком', {
        post_apply = function()
            called = true
        end,
    })

    extras.post_apply(fake_config())

    t.assert_equals(called, true)
end

-- Сброс возвращает каркас в исходное состояние: тесты полагаются на это,
-- а без проверки поломка сброса тихо портила бы соседние проверки.
g.test_reset_clears_state = function()
    local extras, schema = load_extras()
    extras.register('etcd', { relax_prefixes = { 'config.etcd' } })
    extras.initialize(fake_config())

    extras._reset()

    t.assert_equals(extras.status(), {
        extensions = {},
        relaxed_nodes = 0,
        schema_patched = false,
        sources = {},
    })
    -- Схему сброс не восстанавливает: обход необратим, узел остаётся открытым.
    t.assert_equals(schema.fields.config.fields.etcd.enterprise_edition, false)
end

-- Сторож границы: за разделом security в CE нет кода, и гейт с него
-- снимать нельзя.
--
-- Проверка не про наш модуль, а про сборку, в которой он работает, —
-- и лежит она рядом с ним намеренно: снятие гейта живёт здесь, и здесь же
-- должно быть записано, чего снимать нельзя.
--
-- Гейт делает настройку принимаемой схемой. Исполняет её ядро, и в CE
-- исполнять нечем: cfg_set_security не объявлен вовсе, check_password
-- тоже. Сняв метку, мы не подняли бы узел вовсе: умолчания раздела ушли бы
-- в box.cfg, а CE таких опций не знает («Incorrect value for option
-- 'password_history_length': unexpected option» на 3.8, даже без раздела
-- в конфигурации).
--
-- Ловушка, которую эта проверка закрывает: код ошибки AUTH_DELAY и строка
-- «Too many authentication attempts» в CE-сборке есть. Таблица кодов
-- у редакций общая, номера расходиться не должны — и принять наличие кода
-- за наличие поведения проще всего.
--
-- Если однажды cfg_set_security появится, проверка упадёт, и решение надо
-- будет пересмотреть: ради этого она и написана.
g.test_community_edition_has_no_security_settings = function()
    -- Через промежуточную ссылку: внутренности ядра в аннотациях
    -- объявлены необязательными, а нам важно именно их отсутствие.
    ---@type any
    local internal = box.internal

    t.assert_equals(type(internal.cfg_set_security), 'nil', 'в CE раздел security исполнять нечем')
    t.assert_equals(type(internal.check_password), 'nil', 'политики паролей в CE нет')

    -- А тип аутентификации в CE исполняется: настройка рядом, а разница
    -- между ними — ровно в наличии кода.
    t.assert_equals(type(internal.cfg_set_auth_type), 'function')

    -- И код ошибки на месте в обеих редакциях: он ничего не доказывает.
    -- Через промежуточную ссылку: набор кодов в аннотациях не описан.
    ---@type any
    local codes = box.error

    t.assert_not_equals(codes.AUTH_DELAY, nil)
end

-- Без подменённого источника схемы берутся у самого Tarantool.
g.test_default_schema_provider_reads_tarantool = function()
    local extras = helper.load('tnt.ce.extras')

    -- Провайдер не задан: считаются настоящие узлы схемы инстанса и кластера.
    -- Только чтение, схема не патчится — заявок нет.
    t.assert_gt(extras.count_enterprise_nodes(), 0, 'в схеме 3.8 есть Enterprise-узлы')
end

-- Лишние запятые и пробелы в списке расширений не порождают пустых имён.
g.test_extensions_list_ignores_empty_entries = function()
    set_extensions(' , ,нет.модуля, , ')
    local extras = load_extras()

    -- Единственное непустое имя и должно попасть в загрузку.
    t.assert_error_msg_contains('нет.модуля', extras.initialize, fake_config())
end

-- Состояние показывает, сколько узлов схемы открыто.
g.test_status_reports_relaxed_nodes = function()
    local extras = load_extras()

    t.assert_equals(extras.status(), {
        extensions = {},
        relaxed_nodes = 0,
        schema_patched = false,
        sources = {},
    })

    extras.register('etcd', { relax_prefixes = { 'config.etcd' } })
    extras.initialize(fake_config())

    t.assert_equals(extras.status(), {
        extensions = { 'etcd' },
        relaxed_nodes = 2,
        schema_patched = true,
        sources = {},
    })
end

-- Открытые узлы считаются по всем схемам, а не по первой.
g.test_relaxed_nodes_counted_across_schemas = function()
    local first, second = build_schema(), build_schema()
    local extras = helper.load('tnt.ce.extras')
    extras._set_schema_provider(function()
        return { first, second }
    end)

    extras.register('etcd', { relax_prefixes = { 'config.etcd' } })
    extras.initialize(fake_config())

    t.assert_equals(extras.status().relaxed_nodes, 4, 'по два узла в каждой схеме')
end

-- Обход считает узлы во всех формах: записи, массивы, словари. Потомок,
-- который не узел, в счёт не идёт.
g.test_relaxed_nodes_counted_in_every_shape = function()
    local extras, schema = load_extras()
    schema.fields.memtx.fields = { note = 'не узел' }
    extras.register('память', { relax_prefixes = { 'memtx' } })

    extras.initialize(fake_config())

    t.assert_equals(extras.status().relaxed_nodes, 3, 'items, key и value')
end

-- Заявка без префиксов схему не трогает.
g.test_extension_without_prefixes_leaves_schema_intact = function()
    local extras, schema = load_extras()
    extras.register('без схемы', {})

    extras.initialize(fake_config())

    t.assert_equals(extras.status().relaxed_nodes, 0)
    t.assert_equals(extras.status().schema_patched, false)
    t.assert_equals(schema.fields.config.fields.etcd.enterprise_edition, true)
end

-- В Community Edition пакет работает.
g.test_community_edition_is_accepted = function()
    local extras = load_extras()
    extras._set_edition_provider(function()
        return 'Tarantool'
    end)

    t.assert_equals(extras.ensure_community_edition(), 'Tarantool')
end

-- Без подмены редакция читается у самого Tarantool. Тесты гоняются на
-- Community, поэтому проверка обязана проходить.
g.test_edition_is_read_from_tarantool = function()
    local extras = helper.load('tnt.ce.extras')

    t.assert_equals(extras.ensure_community_edition(), require('tarantool').package)
end

-- В Enterprise пакет отказывается работать: там модуль встроен в бинарник,
-- и подмена отключила бы штатные источники конфигурации.
g.test_enterprise_edition_is_rejected = function()
    local extras = load_extras()
    extras._set_edition_provider(function()
        return 'Tarantool Enterprise'
    end)

    -- Отказ сверяется целиком, вместе с именем пакета: по нему оператор
    -- узнаёт, что снять. Сверка — вхождением, потому что error здесь
    -- приписывает место броска.
    t.assert_error_msg_contains(
        'пакет tnt-ce-extras предназначен только для Community Edition: '
            .. 'в Enterprise модуль internal.config.extras встроен в бинарник',
        extras.ensure_community_edition
    )
end

-- Счётчик закрытых узлов показывает, сколько ещё помечено как Enterprise.
g.test_counts_enterprise_nodes = function()
    local extras = load_extras()

    local before = extras.count_enterprise_nodes()
    t.assert_equals(before, 7, 'в поддельной схеме семь помеченных узлов')

    extras.register('etcd', { relax_prefixes = { 'config.etcd' } })
    extras.initialize(fake_config())

    t.assert_equals(extras.count_enterprise_nodes(), before - 2, 'открыты узел и его потомок')
end

-- Под fields лежат не только узлы: у схемы встречаются скалярные значения,
-- и обход обязан их пропускать. Иначе первый же такой ключ роняет старт
-- инстанса — а падение происходило бы в модуле, который ядро грузит само,
-- то есть до любого журнала.
g.test_walk_skips_values_that_are_not_nodes = function()
    local extras, schema = load_extras({
        fields = {
            version = 3,
            config = {
                fields = {
                    etcd = {
                        enterprise_edition = true,
                        validate = function() end,
                        apply_default_if = function()
                            return false
                        end,
                    },
                },
            },
        },
    })

    t.assert_equals(extras.count_enterprise_nodes(), 1)

    extras.register('etcd', { relax_prefixes = { 'config.etcd' } })
    extras.initialize(fake_config())

    t.assert_equals(schema.fields.config.fields.etcd.enterprise_edition, false)
    t.assert_equals(extras.count_enterprise_nodes(), 0)
end

-- ── Источники ────────────────────────────────────────────────────────

g.test_created_sources_are_kept = function()
    -- Ядру источник отдаётся безвозвратно: _register_source ничего
    -- не возвращает, и спросить источник о себе потом было бы неоткуда.
    -- А спрашивать есть о чём: какую ревизию он прочитал и не живёт ли
    -- узел на устаревшем снимке.
    local extras = load_extras()
    local created = {
        status = function()
            return { revision = 42, stale = false }
        end,
    }

    extras.register('etcd', {
        relax_prefixes = { 'config.etcd' },
        source = function()
            return created
        end,
    })

    extras.initialize(fake_config())

    t.assert_equals(extras.sources().etcd, created)
    t.assert_equals(extras.status().sources.etcd, { revision = 42, stale = false })
end

g.test_source_without_a_status_is_not_asked = function()
    -- Договор ядра рассказа о себе не требует: источник вправе его
    -- не уметь, и это не повод падать.
    local extras = load_extras()

    extras.register('etcd', {
        relax_prefixes = { 'config.etcd' },
        source = function()
            return { sync = function() end }
        end,
    })

    extras.initialize(fake_config())

    t.assert_equals(extras.status().sources, {})
    t.assert_not_equals(extras.sources().etcd, nil)
end

g.test_source_that_raises_when_asked_is_reported = function()
    local extras = load_extras()

    extras.register('etcd', {
        relax_prefixes = { 'config.etcd' },
        source = function()
            return {
                status = function()
                    error('источник сломался')
                end,
            }
        end,
    })

    extras.initialize(fake_config())

    t.assert_str_contains(extras.status().sources.etcd.err, 'источник сломался')
end

g.test_sources_are_handed_out_as_a_copy = function()
    -- Список отдаётся наружу: правка у читателя не должна стирать то,
    -- что каркас отдал ядру.
    local extras = load_extras()

    extras.register('etcd', {
        relax_prefixes = { 'config.etcd' },
        source = function()
            return { status = function() end }
        end,
    })

    extras.initialize(fake_config())

    local handed = extras.sources()

    handed.etcd = nil

    t.assert_not_equals(extras.sources().etcd, nil)
end

--- Каркас с одним источником etcd и зондом, в который он рассказывает.
---@param own table Что источник говорит о себе
---@param kernel table Модуль конфигурации, который отдаёт ядро
---@param source_name string|nil Имя источника у ядра
---@return fun(): table collector Сборщик поля зонда
local function published(own, kernel, source_name)
    local extras = load_extras()
    ---@type table<string, fun(): table>
    local collectors = {}

    extras.publish_probe(function(name, collector)
        collectors[name] = collector
    end)

    extras.register('etcd', {
        relax_prefixes = { 'config.etcd' },
        source = function()
            return {
                name = source_name or 'etcd',
                sync = function() end,
                status = function()
                    return own
                end,
            }
        end,
    })

    extras.initialize(kernel)

    local collector = collectors[extras.diagnosis.PROBE_FIELD]

    t.assert_not_equals(collector, nil, 'источники обязаны попасть в зонд')

    return collector
end

g.test_sources_are_published_to_the_probe = function()
    -- Рассказ собран из двух половин: своё говорит источник, ревизии —
    -- ядро. Ревизия, которую назвал источник, — прочитанная, и её место
    -- занимает применённая: по прочитанной узел, упавший на применении,
    -- сошёл бы за догнавшего.
    local kernel = fake_config({
        status = 'check_errors',
        meta = {
            last = { etcd = { revision = 5 } },
            active = { etcd = { revision = 4 } },
        },
        alerts = {
            { type = 'error', message = 'роли missing.role нет', timestamp = 'сейчас' },
        },
    })
    local collector = published({ revision = 5, stale = false, ready = true }, kernel)

    t.assert_equals(collector(), {
        etcd = {
            revision = 4,
            fetched_revision = 5,
            stale = false,
            ready = true,
            status = 'check_errors',
            errors = { 'роли missing.role нет' },
        },
    })
end

g.test_revisions_are_taken_under_the_kernel_name_of_the_source = function()
    -- Ядро складывает сведения по имени источника, а каркас помнит
    -- источники по имени расширения: имена вправе расходиться.
    local kernel = fake_config({
        status = 'ready',
        meta = {
            last = { etcd = { revision = 1 }, store = { revision = 8 } },
            active = { etcd = { revision = 1 }, store = { revision = 7 } },
        },
        alerts = {},
    })
    local collector = published({ stale = false }, kernel, 'store')

    t.assert_equals(collector().etcd.revision, 7)
    t.assert_equals(collector().etcd.fetched_revision, 8)
end

g.test_kernel_that_cannot_answer_fails_the_collector = function()
    -- Отказ ядра не прячется за пустыми ревизиями: зонд помечает поле
    -- ошибкой, и правило о нём молчит, а не судит по неизвестному.
    local collector = published({ stale = false }, {
        _register_source = function() end,
        info = function()
            error('ядро не знает второго поколения')
        end,
    })

    local ok, err = pcall(collector)

    t.assert_equals(ok, false)
    t.assert_str_contains(tostring(err), 'ядро не знает второго поколения')
end

g.test_node_without_sources_publishes_nothing = function()
    -- Без источников ядро не спрашивается вовсе: рассказывать не о ком.
    local extras = load_extras()
    local collectors = {}

    extras.publish_probe(function(name, collector)
        collectors[name] = collector
    end)

    t.assert_equals(collectors[extras.diagnosis.PROBE_FIELD](), {})
end

g.test_revision_rule_is_added_to_the_registry = function()
    local extras = load_extras()
    local registered = {}

    extras.publish_rule({
        SEVERITY = { WARNING = 'warning', CRITICAL = 'critical' },
        SCOPE = { INSTANCE = 'instance' },
        identify = function()
            return 'id'
        end,
        register = function(name, rule)
            registered[name] = rule
        end,
    })

    t.assert_not_equals(registered[extras.diagnosis.RULE], nil)
    t.assert_type(registered[extras.diagnosis.RULE].check, 'function')
end
