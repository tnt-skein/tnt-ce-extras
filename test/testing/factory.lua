--- Фабрики: образец записи, счётчик и приёмник.
---
--- Записи для проверок — узел кластера, ответ зонда, запрос — собираются
--- одинаково: образец с разумными умолчаниями и поля, которые проверка
--- меняет. Повторённый в каждом помощнике, этот цикл по `overrides`
--- однажды разъезжается: один помощник копирует образец, другой отдаёт
--- общий на все проверки, и проверка, изменившая запись, портит соседнюю.
--- Здесь образец копируется на каждую сборку целиком.

local Module = {}

--- Отметка в подмене, по которой поле убирается из записи.
---
--- Пустота в таблице подмены неотличима от отсутствия ключа, а «молчащий
--- узел» — это запись, у которой полей зонда нет вовсе, а не запись
--- с пустыми полями.
Module.ABSENT = setmetatable({}, {
    __tostring = function()
        return 'tnt.testing.ABSENT'
    end,
})

---@alias TntTestingDefaults table|fun(number: integer): table

---@class TntTestingFactory
---@field build fun(overrides: table|nil): table Запись по образцу с изменёнными полями
---@field many fun(count: integer, overrides: table|nil): table[] Столько записей по образцу
---@field built fun(): integer Сколько записей собрано

--- Фабрика записей по образцу.
---
--- Образец — таблица либо функция от номера записи: номер растёт с каждой
--- сборкой, и по нему записи различаются именем или ключом. Таблица
--- копируется целиком, вложенные тоже: записи не делят между собой ничего.
--- Подмена ложится поверх сверху, поле целиком; `ABSENT` убирает поле.
---@param defaults TntTestingDefaults
---@return TntTestingFactory
function Module.define(defaults)
    local built = 0

    local function build(overrides)
        built = built + 1

        local sample = defaults

        if type(defaults) == 'function' then
            sample = defaults(built)
        end

        local entry = table.deepcopy(sample)

        for key, value in pairs(overrides or {}) do
            if value == Module.ABSENT then
                entry[key] = nil
            else
                entry[key] = value
            end
        end

        return entry
    end

    return {
        build = build,

        many = function(count, overrides)
            local list = {}

            for _ = 1, count do
                table.insert(list, build(overrides))
            end

            return list
        end,

        built = function()
            return built
        end,
    }
end

--- Счётчик: выдаёт значения по порядку.
---
--- С приставкой — строки `приставка-1`, `приставка-2`: так выдаются
--- опознаватели, которые проверка потом ищет глазами. Без приставки —
--- числа.
---@param prefix string|nil
---@return fun(): string|integer
function Module.sequence(prefix)
    local issued = 0

    return function()
        issued = issued + 1

        if prefix == nil then
            return issued
        end

        return ('%s-%d'):format(prefix, issued)
    end
end

--- Приёмник, запоминающий всё, что ему сказали.
---
--- Аргументы каждого вызова складываются списком: так проверяется и то,
--- что приёмник позвали, и с чем, и сколько раз.
---@return fun(...): nil observe
---@return table[] seen Аргументы каждого вызова списком, по порядку
function Module.recorder()
    local seen = {}

    return function(...)
        table.insert(seen, { ... })
    end, seen
end

return Module
