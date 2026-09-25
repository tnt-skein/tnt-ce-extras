--- Тест точки входа, которую вызывает сам Tarantool.
---
--- Ядро проверяет контракт тремя assert в load_extras: модуль обязан быть
--- таблицей с функциями initialize и post_apply. Если контракт разойдётся,
--- инстанс не поднимется вовсе, поэтому проверка отдельная.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.ce.extras.entrypoint')

-- Окружение подменено пустым миром: точка входа зовёт инициализацию
-- каркаса, а та читает список расширений, и настоящая переменная
-- или `.env` рядом сделали бы проверку зависимой от машины.
g.before_each(function()
    g.env = helper.env()
    g.env._set_source(helper.world({}))
    g.extras = helper.load('tnt.ce.extras')
end)

g.after_each(function()
    g.env._set_source(nil)
    helper.unload()
end)

-- Модуль отдаёт ровно то, чего ждёт load_extras ядра.
g.test_matches_core_contract = function()
    local entry = helper.entrypoint()

    t.assert_equals(type(entry), 'table')
    t.assert_equals(type(entry.initialize), 'function')
    t.assert_equals(type(entry.post_apply), 'function')
end

-- Вызовы делегируются реестру и не падают на пустом реестре: установленный
-- пакет без заявленных расширений обязан вести себя как отсутствующий.
g.test_delegates_without_extensions = function()
    local entry = helper.entrypoint()

    local config = {
        _register_source = function()
            error('источников быть не должно')
        end,
    }

    t.assert_equals(pcall(entry.initialize, config), true)
    t.assert_equals(pcall(entry.post_apply, config), true)
end

-- Инициализацию ядро зовёт у точки входа, а источник регистрирует реестр:
-- без передачи вызова заявленный источник до ядра не дошёл бы.
g.test_initialize_is_handed_to_the_registry = function()
    local entry = helper.entrypoint()
    local source = { name = 'проба' }
    local registered = {}

    g.extras.register('проба', {
        source = function()
            return source
        end,
    })

    entry.initialize({
        _register_source = function(_, given)
            table.insert(registered, given)
        end,
    })

    t.assert_equals(registered, { source })
end

-- То же после применения: хук расширения получает модуль конфигурации,
-- который ядро отдало точке входа.
g.test_post_apply_is_handed_to_the_registry = function()
    local entry = helper.entrypoint()
    local config = {}
    local seen = {}

    g.extras.register('проба', {
        post_apply = function(given)
            table.insert(seen, given)
        end,
    })

    entry.post_apply(config)

    t.assert_equals(seen, { config })
end

-- На Enterprise точка входа отказывает уже при загрузке: там модуль
-- встроен в бинарник, и подмена отключила бы штатные источники
-- конфигурации. Ждать инициализации нельзя — к ней подмена уже случилась.
g.test_refuses_to_load_on_enterprise = function()
    g.extras._set_edition_provider(function()
        return 'Tarantool Enterprise'
    end)

    t.assert_error_msg_contains('предназначен только для Community Edition', helper.entrypoint)
end
