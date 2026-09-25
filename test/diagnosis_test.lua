--- Тесты правила о ревизии конфигурации. Правило чистое: на входе снимок,
--- на выходе находки.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.ce.extras.diagnosis')

---@type any
local diagnosis

--- Словарь диагностики: уровни, области и опознание находок.
local vocabulary = helper.vocabulary()

g.before_each(function()
    diagnosis = helper.load('tnt.ce.extras.diagnosis')
end)

g.after_each(function()
    helper.unload()
end)

--- Узел, рассказавший зонду об источниках конфигурации.
---@param name string
---@param sources any Что сообщил каркас расширений: поле зонда вправе
--- оказаться чем угодно, и проверяется в том числе это
---@param overrides table|nil
---@return table
local function node(name, sources, overrides)
    local entry = helper.instance(name, { extensions = { config_sources = sources } })

    for key, value in pairs(overrides or {}) do
        entry[key] = value
    end

    return entry
end

--- Снимок кластера из перечисленных узлов.
local cluster = helper.snapshot

--- Находки правила.
---@param snapshot table
---@return table[]
local function check(snapshot)
    return diagnosis.rule(vocabulary).check(snapshot)
end

--- Единственная находка; её отсутствие — ошибка самого теста.
---@param found table[]
---@param index integer|nil
---@return table
local function at(found, index)
    local issue = found[index or 1]

    if issue == nil then
        error(('находки под номером %d нет'):format(index or 1))
    end

    return issue
end

-- ── Отставшая ревизия ────────────────────────────────────────────────

g.test_node_on_an_older_revision_is_reported = function()
    -- Общего у роутера с хранилищем ровно одно — номер ревизии: по нему
    -- и видно, одну ли конфигурацию применил кластер.
    local found = check(
        cluster(
            node('storage-001-a', { ['tnt-stand'] = { revision = 42, ready = true } }),
            node('router-001-a', { ['tnt-stand'] = { revision = 41, ready = true } }, {
                replicaset_name = 'router-001',
            })
        )
    )

    t.assert_equals(#found, 1)
    t.assert_equals(at(found).instance, 'router-001-a')
    t.assert_equals(at(found).replicaset, 'router-001')
    t.assert_equals(at(found).severity, 'critical')
    t.assert_equals(at(found).id, 'config_revision:instance:router-001-a:behind')
    t.assert_str_contains(at(found).message, 'применена ревизия 41')
    t.assert_str_contains(at(found).message, 'в кластере уже 42')
end

g.test_matching_revisions_are_silent = function()
    local found = check(
        cluster(
            node('storage-001-a', { ['tnt-stand'] = { revision = 42 } }),
            node('storage-001-b', { ['tnt-stand'] = { revision = 42 } })
        )
    )

    t.assert_equals(found, {})
end

g.test_sources_are_compared_each_with_its_own = function()
    -- Источников бывает несколько, и ревизии у них свои: сравнивать их
    -- между собой бессмысленно.
    local found = check(
        cluster(
            node('storage-001-a', { ['tnt-stand'] = { revision = 42 }, ['общий'] = { revision = 7 } }),
            node('storage-001-b', { ['tnt-stand'] = { revision = 42 }, ['общий'] = { revision = 7 } })
        )
    )

    t.assert_equals(found, {})
end

g.test_newest_revision_is_the_measure = function()
    -- За норму принимается наибольшая, а не мнение большинства: ревизия
    -- растёт монотонно, и та, что больше, заведомо новее.
    local found = check(
        cluster(
            node('storage-001-a', { ['tnt-stand'] = { revision = 41 } }),
            node('storage-001-b', { ['tnt-stand'] = { revision = 41 } }),
            node('storage-001-c', { ['tnt-stand'] = { revision = 42 } })
        )
    )

    t.assert_equals(#found, 2)
    t.assert_equals(at(found).instance, 'storage-001-a')
    t.assert_equals(at(found, 2).instance, 'storage-001-b')
end

g.test_findings_are_ordered_by_node_and_source = function()
    -- Находки читают люди: без порядка список перетасовывался бы от обхода
    -- к обходу, и «то же самое» отличить от «нового» стало бы нельзя.
    local found = check(cluster(
        node('storage-001-b', {
            ['второй'] = { revision = 1 },
            ['первый'] = { revision = 1 },
        }),
        node('storage-001-a', {
            ['второй'] = { revision = 1 },
            ['первый'] = { revision = 1 },
        }),
        node('storage-001-c', {
            ['второй'] = { revision = 2 },
            ['первый'] = { revision = 2 },
        })
    ))

    local order = {}

    for _, issue in ipairs(found) do
        table.insert(order, ('%s/%s'):format(issue.instance, issue.message:match('источника (%S+),')))
    end

    t.assert_equals(order, {
        'storage-001-a/второй',
        'storage-001-a/первый',
        'storage-001-b/второй',
        'storage-001-b/первый',
    })
end

g.test_revision_zero_is_still_a_revision = function()
    -- Ноль — такой же номер, как любой другой: узел, применивший нулевую
    -- ревизию, отстал от первой, а не «не назвал ревизии вовсе».
    local found = check(
        cluster(
            node('storage-001-a', { ['tnt-stand'] = { revision = 0 } }),
            node('storage-001-b', { ['tnt-stand'] = { revision = 1 } })
        )
    )

    t.assert_equals(#found, 1)
    t.assert_equals(at(found).instance, 'storage-001-a')
    t.assert_str_contains(at(found).message, 'применена ревизия 0')
end

-- ── Подъём на снимке ─────────────────────────────────────────────────

g.test_node_raised_from_a_snapshot_is_reported = function()
    -- Узел, не достучавшийся до хранилища при старте, поднялся на
    -- сохранённой копии. Поблажка осознанная, но жить так неделями нельзя:
    -- никто не знает, что на таком узле применено.
    local found = check(
        cluster(
            node('storage-001-a', { ['tnt-stand'] = { revision = 42 } }),
            node('storage-001-b', { ['tnt-stand'] = { stale = true, revision = nil } })
        )
    )

    t.assert_equals(#found, 1)
    t.assert_equals(at(found).instance, 'storage-001-b')
    t.assert_equals(at(found).severity, 'warning')
    t.assert_equals(at(found).key, 'snapshot')
    t.assert_str_contains(at(found).message, 'взята из снимка')
end

g.test_stale_node_is_not_accused_of_lagging_twice = function()
    -- О подъёме на снимке сказано, и второй находкой про ревизию это
    -- не повторяется: ревизии у такого узла нет вовсе.
    local found = check(
        cluster(
            node('storage-001-a', { ['tnt-stand'] = { revision = 42 } }),
            node('storage-001-b', { ['tnt-stand'] = { stale = true, revision = 7 } })
        )
    )

    t.assert_equals(#found, 1)
    t.assert_equals(at(found).key, 'snapshot')
end

-- ── Прочитанная, но не применённая ревизия ───────────────────────────

--- Ответ ядра об одном источнике etcd.
---@param status string|nil Состояние ядра
---@param last number|nil Прочитанная ревизия
---@param active number|nil Применённая ревизия
---@param alerts table[]|nil Замечания ядра
---@return table
local function kernel(status, last, active, alerts)
    return {
        status = status,
        meta = {
            last = { etcd = { revision = last } },
            active = { etcd = { revision = active } },
        },
        alerts = alerts or {},
    }
end

--- Рассказ узла об источнике etcd — так же, как его собирает каркас.
---@param info table Ответ ядра
---@return table
local function told(info)
    return { etcd = diagnosis.describe('etcd', { stale = false, ready = true }, info) }
end

g.test_node_that_read_but_did_not_apply_is_reported = function()
    -- Ядро прочитало пятую ревизию и не применило её: узел живёт на
    -- четвёртой. По прочитанной он сошёл бы за догнавшего — а он и есть
    -- тот, о ком надо сказать, и с причиной.
    local found = check(
        cluster(
            node('storage-001-a', told(kernel('ready', 5, 5))),
            node(
                'storage-001-b',
                told(kernel('check_errors', 5, 4, {
                    { type = 'warn', message = 'предупреждение не причина' },
                    { type = 'error', message = 'роли missing.role нет' },
                    { type = 'error', message = 'второй отказ' },
                }))
            )
        )
    )

    t.assert_equals(#found, 1, 'об отставании второй находкой не говорится')
    t.assert_equals(at(found).instance, 'storage-001-b')
    t.assert_equals(at(found).severity, 'critical')
    t.assert_equals(at(found).id, 'config_revision:instance:storage-001-b:unapplied')
    t.assert_equals(
        at(found).message,
        'конфигурация не применена: источник etcd, прочитана ревизия 5, действует 4, '
            .. 'ядро в состоянии check_errors: роли missing.role нет; второй отказ'
    )
end

g.test_fetched_revision_is_not_the_measure = function()
    -- Норма — самая свежая применённая ревизия. Прочитанная, но ещё
    -- применяемая мерой не служит: иначе отставшим назвали бы узел,
    -- применивший всё, что записано.
    local found = check(
        cluster(
            node('storage-001-a', told(kernel('reload_in_progress', 6, 5))),
            node('storage-001-b', told(kernel('ready', 5, 5)))
        )
    )

    t.assert_equals(found, {})
end

g.test_configuration_being_applied_is_not_judged = function()
    -- Пока ядро применяет, прочитанная законно новее применённой: о том,
    -- что применение затянулось, говорит правило о сроке, а не это.
    local found = check(
        cluster(
            node('storage-001-a', told(kernel('startup_in_progress', 5, 4))),
            node('storage-001-b', told(kernel('reload_in_progress', 5, 4)))
        )
    )

    t.assert_equals(found, {})
end

g.test_revisions_alone_reveal_an_unapplied_configuration = function()
    -- Без отказа ядра судят по номерам: прочитанная новее применённой,
    -- а применение не идёт. Причины назвать нечем, и хвоста нет.
    local found = check(cluster(node('storage-001-a', told(kernel('ready', 5, 4)))))

    t.assert_equals(#found, 1)
    t.assert_equals(at(found).key, 'unapplied')
    t.assert_equals(
        at(found).message,
        'конфигурация не применена: источник etcd, прочитана ревизия 5, действует 4, '
            .. 'ядро в состоянии ready'
    )
end

g.test_equal_revisions_are_applied = function()
    local found = check(cluster(node('storage-001-a', told(kernel('check_warnings', 5, 5)))))

    t.assert_equals(found, {})
end

g.test_read_without_any_applied_revision_is_reported = function()
    -- Применённой ревизии нет вовсе, а прочитанная есть: применено не то,
    -- что прочитано. Неизвестное названо прочерком, а не словом nil.
    local found = check(cluster(node('storage-001-a', told(kernel(nil, 5, nil)))))

    t.assert_equals(#found, 1)
    t.assert_equals(
        at(found).message,
        'конфигурация не применена: источник etcd, прочитана ревизия 5, действует —, '
            .. 'ядро в состоянии —'
    )
end

g.test_failed_apply_is_reported_whatever_was_read = function()
    -- Отказ ядра говорит сам за себя: последнее применение не удалось,
    -- даже если прочитанной ревизии ядро не знает.
    local found = check(cluster(node(
        'storage-001-a',
        told(kernel('check_errors', nil, 4, {
            { type = 'error', message = 'etcd недоступен' },
        }))
    )))

    t.assert_equals(#found, 1)
    t.assert_equals(
        at(found).message,
        'конфигурация не применена: источник etcd, прочитана ревизия —, действует 4, '
            .. 'ядро в состоянии check_errors: etcd недоступен'
    )
end

g.test_nothing_read_and_nothing_failed_is_silent = function()
    local found = check(cluster(node('storage-001-a', told(kernel('ready', nil, nil)))))

    t.assert_equals(found, {})
end

g.test_reasons_that_came_over_the_wire_are_named_as_is = function()
    -- Поле пришло по сети: чужая запись в списке называется как есть,
    -- а список не того вида не роняет разбор.
    local found = check(
        cluster(
            node('storage-001-a', { etcd = { revision = 4, fetched_revision = 5, errors = { 'отказ', 42 } } }),
            node('storage-001-b', { etcd = { revision = 4, fetched_revision = 5, errors = 'не список' } })
        )
    )

    t.assert_str_contains(at(found, 1).message, 'ядро в состоянии —: отказ; 42')
    t.assert_equals(
        at(found, 2).message,
        'конфигурация не применена: источник etcd, прочитана ревизия 5, действует 4, '
            .. 'ядро в состоянии —',
        'хвоста без причин нет'
    )
end

g.test_snapshot_is_told_before_a_failed_apply = function()
    -- О подъёме на снимке сказано: что ещё не применилось, на таком узле
    -- не знает никто, и вторая находка ничего не добавила бы.
    local state = diagnosis.describe('etcd', { stale = true }, kernel('check_errors', 5, 4))
    local found = check(cluster(node('storage-001-a', { etcd = state })))

    t.assert_equals(#found, 1)
    t.assert_equals(at(found).key, 'snapshot')
end

-- ── Рассказ узла об источнике ────────────────────────────────────────

g.test_description_keeps_the_own_words_of_the_source = function()
    local own = { revision = 9, stale = false, endpoint = 'http://etcd:2379' }
    local described = diagnosis.describe('etcd', own, kernel('ready', 5, 4))

    t.assert_equals(described, {
        revision = 4,
        fetched_revision = 5,
        stale = false,
        endpoint = 'http://etcd:2379',
        status = 'ready',
        errors = {},
    })
    t.assert_equals(own.revision, 9, 'своё источника не переписывается')
end

g.test_description_takes_only_its_own_source = function()
    local described = diagnosis.describe('etcd', {}, {
        status = 'ready',
        meta = {
            last = { other = { revision = 8 } },
            active = { other = { revision = 7 } },
        },
    })

    t.assert_equals(described.revision, nil)
    t.assert_equals(described.fetched_revision, nil)
end

g.test_description_reads_revisions_as_numbers = function()
    local described = diagnosis.describe('etcd', {}, {
        meta = {
            last = { etcd = { revision = '12' } },
            active = { etcd = { revision = '11' } },
        },
    })

    t.assert_equals(described.revision, 11)
    t.assert_equals(described.fetched_revision, 12)
end

g.test_description_survives_a_kernel_of_another_shape = function()
    -- Ответ ядра старого поколения или чужого вида: ревизий в нём нет,
    -- и выдумывать их нельзя.
    for _, info in ipairs({
        {},
        { meta = 'не таблица' },
        { meta = { active = 'не таблица', last = { etcd = 'не таблица' } } },
    }) do
        local described = diagnosis.describe('etcd', { revision = 9 }, info)

        t.assert_equals(described.revision, nil)
        t.assert_equals(described.fetched_revision, nil)
        t.assert_equals(described.errors, {})
    end
end

g.test_description_takes_only_errors_as_reasons = function()
    local described = diagnosis.describe('etcd', {}, {
        alerts = {
            { type = 'warn', message = 'предупреждение' },
            'не таблица',
            { type = 'error', message = 42 },
            { type = 'error', message = 'отказ' },
        },
    })

    t.assert_equals(described.errors, { '42', 'отказ' })
end

g.test_description_survives_alerts_of_another_shape = function()
    local described = diagnosis.describe('etcd', {}, { alerts = 'не список' })

    t.assert_equals(described.errors, {})
end

-- ── Молчание там, где сказать нечего ─────────────────────────────────

g.test_node_without_sources_is_not_judged = function()
    -- Кластер, чья конфигурация лежит файлом: источников нет, и ревизии
    -- тоже. Правило молчит.
    local found = check(cluster(node('storage-001-a', {}), node('storage-001-b', nil)))

    t.assert_equals(found, {})
end

g.test_silent_node_is_not_judged = function()
    -- О молчащем узле известно только имя: сравнивать нечего.
    local found = check(
        cluster(
            node('storage-001-a', { ['tnt-stand'] = { revision = 42 } }),
            node('storage-001-b', { ['tnt-stand'] = { revision = 7 } }, { reachable = false })
        )
    )

    t.assert_equals(found, {})
end

g.test_source_that_answered_with_an_error_is_not_judged = function()
    -- Сборщик расширения отказал: зонд помечает поле ошибкой, и ревизии
    -- в нём нет. Это не отставание.
    local found = check(
        cluster(
            node('storage-001-a', { ['tnt-stand'] = { revision = 42 } }),
            node('storage-001-b', { ['tnt-stand'] = { err = 'источник не отвечает' } })
        )
    )

    t.assert_equals(found, {})
end

g.test_probe_field_that_is_not_a_table_is_ignored = function()
    local found = check(cluster(node('storage-001-a', 'нет источников')))

    t.assert_equals(found, {})
end

g.test_source_state_that_is_not_a_table_is_ignored = function()
    local found = check(cluster(node('storage-001-a', { ['tnt-stand'] = 42 })))

    t.assert_equals(found, {})
end

g.test_empty_snapshot_yields_nothing = function()
    t.assert_equals(check({}), {})
end

-- ── Договор с реестром ───────────────────────────────────────────────

g.test_findings_are_personal = function()
    t.assert_equals(diagnosis.rule(vocabulary).personal, true)
end
