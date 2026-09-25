--- Правило диагностики: одну ли конфигурацию применили узлы.
---
--- Сравнение содержимого отвечает на этот вопрос лишь там, где содержимое
--- обязано совпадать: роутер и хранилище различаются ролями по замыслу,
--- и отпечатки у них законно разные. Общего у всех узлов ровно одно — номер
--- ревизии, под которым конфигурация лежит в хранилище. Узел, применивший
--- сорок первую, когда в хранилище сорок вторая, отстал — кем бы он ни был
--- и в какой бы группе ни состоял.
---
--- Номер — ревизия ключа конфигурации в хранилище, а не всего хранилища:
--- ту двигает любая запись в etcd — назначение лидера, замок, — и узлы,
--- прочитавшие одну и ту же конфигурацию в разные мгновения, разошлись бы
--- номерами на пустом месте. Источник рассказывает номер ядру, а ядро
--- помнит два: прочитанный (`config:info('v2').meta.last`) и применённый
--- (`meta.active`) — второй оно переписывает только после удачного
--- применения. Судят по применённому: узел, прочитавший сорок вторую
--- и упавший на её применении, живёт на сорок первой. Такой узел —
--- отдельная находка, с причиной отказа из замечаний ядра: одного
--- отставания мало, оператору нужно знать, почему узел не догнал.
---
--- Что конфигурация взята из снимка, ядро не знает — это знает только
--- источник. Поэтому рассказ о каждом источнике складывается из двух
--- половин: своей у источника и применённой у ядра, — и правило
--- принадлежит тому пакету, который источники ведёт: реестр правил открыт
--- как раз для этого.
---
--- Третье, о чём здесь говорится, — подъём на снимке. Узел, не достучавшийся
--- до хранилища при старте, поднимается на последней сохранённой копии:
--- это осознанная поблажка, иначе отказ хранилища не пускал бы кластер
--- подняться вовсе. Но жить так неделями нельзя — никто не знает, что
--- на таком узле применено.
---
--- У конфигурации из файла ревизии нет и быть не может: файл читается
--- при старте и при перечитывании, номера ему никто не выдаёт, а время
--- изменения — свойство диска, а не конфигурации. Поэтому на таком
--- кластере правило молчит: узел не рассказывает об источниках ничего,
--- и сравнивать нечего. Это не пробел — там, где ревизии нет, за то же
--- самое отвечает сравнение отпечатков применённой конфигурации, а не
--- номеров. Сравнения дополняют друг друга и по цене ошибки: отпечаток
--- говорит «применено разное», ревизия — «применено старое», и второе
--- без первого случается ровно тогда, когда узел не услышал хранилище.

local Module = {}

--- Как называется это правило в реестре.
Module.RULE = 'config_revision'

--- Имя поля в ответе зонда.
Module.PROBE_FIELD = 'config_sources'

--- Узел применил не самую свежую ревизию.
Module.BEHIND = 'behind'

--- Узел поднялся на сохранённом снимке конфигурации.
Module.SNAPSHOT = 'snapshot'

--- Узел прочитал конфигурацию, но не применил её.
Module.UNAPPLIED = 'unapplied'

--- Состояние ядра, в котором последнее применение не удалось.
local FAILED = 'check_errors'

--- Состояния ядра, в которых применение ещё идёт.
---
--- Прочитанная ревизия в них законно новее применённой, и судить об отказе
--- рано: применение, которое затянулось, — находка о сроке, а не о ревизии,
--- и её дело другого правила.
local SETTLING = { startup_in_progress = true, reload_in_progress = true }

--- Ревизия из сведений ядра об одном источнике.
---
--- Ядро складывает сведения по имени источника, и чужие имена здесь
--- не нужны: ревизию каждого источника спрашивают у него же.
---@param facts any `meta.active` либо `meta.last` из ответа ядра
---@param name string|nil Имя источника у ядра
---@return number|nil
local function revision_in(facts, name)
    local told = type(facts) == 'table' and facts[name] or nil

    return type(told) == 'table' and tonumber(told.revision) or nil
end

--- Тексты замечаний ядра уровня error — почему конфигурация не применена.
---@param alerts any Замечания из ответа ядра
---@return string[]
local function errors_in(alerts)
    local found = {}

    for _, alert in ipairs(type(alerts) == 'table' and alerts or {}) do
        if type(alert) == 'table' and alert.type == 'error' then
            table.insert(found, tostring(alert.message))
        end
    end

    return found
end

--- Что узел рассказывает зонду об одном источнике.
---
--- Своё источник говорит сам: взята ли конфигурация из снимка, откуда
--- и когда прочитана. Ревизии — у ядра: `revision` — применённая,
--- `fetched_revision` — прочитанная; рядом состояние ядра и тексты его
--- отказов, без них находку о неприменённой конфигурации нечем объяснить.
--- Ревизия, которую назвал сам источник, заменяется применённой: судить
--- по прочитанной значило бы считать догнавшим узел, упавший на
--- применении.
---@param name string|nil Имя источника у ядра
---@param own table Что источник сказал о себе
---@param info table Ответ ядра `config:info('v2')`
---@return table
function Module.describe(name, own, info)
    local described = {}

    for key, value in pairs(own) do
        described[key] = value
    end

    local meta = type(info.meta) == 'table' and info.meta or {}

    described.revision = revision_in(meta.active, name)
    described.fetched_revision = revision_in(meta.last, name)
    described.status = info.status
    described.errors = errors_in(info.alerts)

    return described
end

--- Что узел рассказал об источниках конфигурации.
---
--- Молчащий узел не рассказывает ничего: о нём известно только имя.
--- Сборщик расширения вправе и отказать — тогда зонд помечает поле
--- ошибкой, и рассказом о себе это не является.
---@param entry table Запись об узле из снимка
---@return table<string, table>
local function sources_of(entry)
    local reported = (entry.extensions or {})[Module.PROBE_FIELD]
    local known = {}

    if not entry.reachable or type(reported) ~= 'table' then
        return known
    end

    for source, state in pairs(reported) do
        if type(state) == 'table' then
            known[source] = state
        end
    end

    return known
end

--- Самая свежая ревизия каждого источника.
---
--- За норму принимается наибольшая, а не мнение большинства: ревизия растёт
--- монотонно, и та, что больше, заведомо новее. Голосовать тут не о чем.
---@param snapshot table
---@return table<string, number>
local function newest_of(snapshot)
    local newest = {}

    for _, entry in pairs(snapshot.instances or {}) do
        for source, state in pairs(sources_of(entry)) do
            local revision = tonumber(state.revision)

            if revision ~= nil then
                newest[source] = math.max(newest[source] or revision, revision)
            end
        end
    end

    return newest
end

--- Не применил ли узел то, что прочитал.
---
--- Отказ ядра говорит сам за себя: последнее применение не удалось, что бы
--- ни было прочитано. Без отказа судят по номерам — прочитанный новее
--- применённого, — но только когда применение не идёт прямо сейчас.
---@param status any Состояние ядра
---@param fetched number|nil Прочитанная ревизия
---@param applied number|nil Применённая ревизия
---@return boolean
local function unapplied(status, fetched, applied)
    if status == FAILED then
        return true
    end

    return not SETTLING[status] and fetched ~= nil and (applied == nil or fetched > applied)
end

--- Номер или состояние для человека: неизвестное — прочерк, а не слово nil.
---@param value any
---@return string
local function shown(value)
    return tostring(value or '—')
end

--- Почему узел не применил конфигурацию — словами ядра.
---
--- Поле пришло по сети от узла, и верить его виду нельзя: чужая запись
--- в списке называется как есть, а не роняет разбор.
---@param errors any
---@return string
local function reasons_of(errors)
    local texts = {}

    for _, text in ipairs(type(errors) == 'table' and errors or {}) do
        table.insert(texts, tostring(text))
    end

    if #texts == 0 then
        return ''
    end

    return ': ' .. table.concat(texts, '; ')
end

--- Находка об одном источнике узла.
---
--- Отдаёт всё, кроме того, о каком узле речь, — это знает обход; пустота —
--- судить не о чем.
---@param vocabulary table
---@param newest table<string, number> Самые свежие ревизии источников
---@param source string
---@param state table Рассказ узла об источнике
---@return table|nil
local function judge(vocabulary, newest, source, state)
    local revision = tonumber(state.revision)
    local fetched = tonumber(state.fetched_revision)

    if state.stale == true then
        return {
            key = Module.SNAPSHOT,
            -- Поблажка осознанная: иначе отказ хранилища не пускал бы
            -- кластер подняться вовсе.
            severity = vocabulary.SEVERITY.WARNING,
            message = (
                'конфигурация взята из снимка: источник %s '
                .. 'не отвечал при старте, и что применено — '
                .. 'неизвестно'
            ):format(source),
        }
    end

    if unapplied(state.status, fetched, revision) then
        return {
            key = Module.UNAPPLIED,
            -- Отказ, как и отставание: узел живёт не на том, что прочитал,
            -- а наблюдение переприменит конфигурацию только на следующей
            -- правке. Об отставании второй находкой не говорится — эта
            -- точнее и называет причину.
            severity = vocabulary.SEVERITY.CRITICAL,
            message = (
                'конфигурация не применена: источник %s, прочитана ревизия %s, '
                .. 'действует %s, ядро в состоянии %s%s'
            ):format(source, shown(fetched), shown(revision), shown(state.status), reasons_of(state.errors)),
        }
    end

    if revision ~= nil and revision < newest[source] then
        return {
            key = Module.BEHIND,
            -- Отставшая ревизия — отказ: узел делает не то, что остальные.
            severity = vocabulary.SEVERITY.CRITICAL,
            message = (
                'конфигурация отстала: применена ревизия %d '
                .. 'источника %s, в кластере уже %d'
            ):format(revision, source, newest[source]),
        }
    end

    return nil
end

--- Правило для реестра диагностики.
---@param vocabulary table Словарь: SEVERITY и about_instance — сборка находки об узле
---@return TntClusterRule
function Module.rule(vocabulary)
    return {
        -- Личное: находка о том, что применено на самом узле. Выведенный
        -- из эксплуатации вправе о ней молчать.
        personal = true,

        check = function(snapshot)
            local newest = newest_of(snapshot)
            local found = {}

            local instances = {}

            for instance in pairs(snapshot.instances or {}) do
                table.insert(instances, instance)
            end

            -- Находки читают люди: без порядка список перетасовывался бы
            -- от обхода к обходу, и «то же самое» отличить от «нового»
            -- стало бы нельзя.
            table.sort(instances)

            for _, instance in ipairs(instances) do
                local entry = snapshot.instances[instance]
                local reported = sources_of(entry)
                local named = {}

                for source in pairs(reported) do
                    table.insert(named, source)
                end

                table.sort(named)

                for _, source in ipairs(named) do
                    local spec = judge(vocabulary, newest, source, reported[source])

                    if spec ~= nil then
                        spec.rule = Module.RULE
                        spec.name = instance
                        spec.entry = entry

                        table.insert(found, vocabulary.about_instance(spec))
                    end
                end
            end

            return found
        end,
    }
end

return Module
