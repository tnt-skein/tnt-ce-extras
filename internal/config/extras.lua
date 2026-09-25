--- Точка входа, которую Tarantool вызывает при старте конфигурации.
---
--- Модуль обязан отдать таблицу с функциями initialize и post_apply —
--- это проверяется тремя assert в load_extras ядра. Здесь он тонкий:
--- вся работа в реестре tnt.ce.extras, чтобы точку входа занимал ровно
--- один пакет, а расширения подключались через него.
---
--- Ставить на Enterprise нельзя: там свой встроенный модуль, и подмена
--- отключила бы штатные источники конфигурации.

local registry = require('tnt.ce.extras')

registry.ensure_community_edition()

return {
    initialize = function(config)
        registry.initialize(config)
    end,

    post_apply = function(config)
        registry.post_apply(config)
    end,
}
