rockspec_format = '3.0'

package = 'tnt-ce-extras'
version = 'scm-1'

source = {
    url = 'git+https://github.com/tnt-skein/tnt-ce-extras.git',
    branch = 'main',
}

description = {
    summary = 'Расширения конфигурации Tarantool Community Edition: свои источники и открытые узлы схемы',
    detailed = [[
        Tarantool при старте конфигурации зовёт модуль
        internal.config.extras. В Enterprise он встроен в бинарник и
        добавляет свои источники конфигурации, в Community Edition его нет,
        а ядро прямо разрешает подставить свой. Пакет занимает это место
        и ведёт реестр расширений: каждое объявляет, какие узлы схемы,
        помеченные «только Enterprise», ему открыть, какой источник
        конфигурации зарегистрировать и что сделать после применения.
        Узлы открываются точечно, по путям: всё, что не заявлено, ядро
        по-прежнему отвергает.

        Расширения перечисляются в переменной окружения TNT_CE_EXTENSIONS
        через запятую; годится и строка в .env каталога запуска. Без
        переменной установка пакета ничего не меняет. Незагрузившееся
        расширение и пробел внутри имени — отказ на старте, а не узел,
        молча поднятый без обещанного источника.

        Рядом — правило диагностики о ревизии конфигурации: узел
        рассказывает зонду, какую ревизию прочитал и какую применил, взята
        ли конфигурация из снимка и почему ядро её отвергло, а правило
        находит отставших, поднятых на снимке и не применивших прочитанное.

        Только для Community Edition: в Enterprise пакет отказывается
        загружаться. Зависит от tnt-must и tnt-env. Покрытие строк
        и убитых мутантов — 100 %.
    ]],
    homepage = 'https://github.com/tnt-skein/tnt-ce-extras',
    issues_url = 'https://github.com/tnt-skein/tnt-ce-extras/issues',
    maintainer = 'tnt-skein',
    license = 'MIT',
    labels = { 'tarantool', 'config', 'configuration', 'community-edition', 'diagnostics' },
}

dependencies = {
    'lua >= 5.1',
    -- Бросок без места: отказ о списке расширений уходит оператору,
    -- и приписка строки пакета отправила бы искать причину не там.
    'tnt-must',
    -- Список расширений из окружения процесса и .env каталога запуска
    -- по общему правилу списков.
    'tnt-env',
}

build = {
    type = 'builtin',
    modules = {
        ['tnt.ce.extras'] = 'tnt/ce/extras.lua',
        ['tnt.ce.extras.diagnosis'] = 'tnt/ce/extras/diagnosis.lua',
        -- Точка входа ядра: путь фиксирован, менять его нельзя.
        ['internal.config.extras'] = 'internal/config/extras.lua',
    },
}
