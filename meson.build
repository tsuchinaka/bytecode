project(
  'io.github.haruki.openclient',
  'vala', 'c',
  version: '0.1.0',
  meson_version: '>= 0.58',
)

gnome = import('gnome')

dependencies = [
  dependency('glib-2.0', version: '>= 2.74'),
  dependency('gio-2.0'),
  dependency('gee-0.8'),
  dependency('gtk4', version: '>= 4.10'),
  dependency('granite-7', version: '>= 7.4.0'),
  dependency('libsoup-3.0'),
  dependency('json-glib-1.0', version: '>= 1.6'),
]

gresource = gnome.compile_resources(
  'openclient-resources',
  'data/openclient.gresource.xml',
  source_dir: 'data',
  c_name: 'openclient_resources',
)

# posix.vapi ships with valac (no pkg-config file): needed for the
# fd-passing in Portals (OpenURI takes open file descriptors).
executable(
  meson.project_name(),
  gresource,
  'src/Application.vala',
  'src/Config.vala',
  'src/MainWindow.vala',
  'src/Models/Session.vala',
  'src/Models/Message.vala',
  'src/Models/ModelInfo.vala',
  'src/Models/FormInfo.vala',
  'src/Models/CommandInfo.vala',
  'src/Services/Client.vala',
  'src/Services/EventStream.vala',
  'src/Services/Store.vala',
  'src/Utils/BrailleSpinner.vala',
  'src/Utils/JsonUtil.vala',
  'src/Utils/Markdown.vala',
  'src/Utils/Work.vala',
  'src/Utils/Portals.vala',
  'src/Widgets/ChatView.vala',
  'src/Widgets/Composer.vala',
  'src/Widgets/DiffDialog.vala',
  'src/Widgets/FormCard.vala',
  'src/Widgets/MessageBubble.vala',
  'src/Widgets/ReasoningBubble.vala',
  'src/Widgets/LiveStatus.vala',
  'src/Widgets/SystemDivider.vala',
  'src/Widgets/VariantChooser.vala',
  'src/Widgets/ToolCard.vala',
  'src/Widgets/ModelChooser.vala',
  'src/Widgets/SessionPanel.vala',
  'src/Widgets/NewSessionView.vala',
  'src/Widgets/AgentChooser.vala',
  'src/Widgets/SettingsView.vala',
  'src/Widgets/Sidebar.vala',
  dependencies: dependencies,
  vala_args: '--pkg=posix',
  install: true,
)

install_data(
  'data/' + meson.project_name() + '.desktop',
  install_dir: get_option('datadir') / 'applications',
)

install_data(
  'data/icons/hicolor/scalable/apps/' + meson.project_name() + '.svg',
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'apps',
)

# Provider icons as a real theme location: only here does GTK treat
# them as symbolic and recolor with the theme foreground. The
# gresource copies are a fallback for uninstalled dev runs.
provider_icons = [
  'anthropic-symbolic.svg',
  'copilot-symbolic.svg',
  'deepseek-symbolic.svg',
  'gemini-symbolic.svg',
  'huggingface-symbolic.svg',
  'meta-symbolic.svg',
  'minimax-symbolic.svg',
  'mistral-symbolic.svg',
  'moonshot-symbolic.svg',
  'nvidia-symbolic.svg',
  'ollama-symbolic.svg',
  'openai-symbolic.svg',
  'openrouter-symbolic.svg',
  'perplexity-symbolic.svg',
  'qwen-symbolic.svg',
  'xai-symbolic.svg',
  'xiaomi-symbolic.svg',
  'zai-symbolic.svg',
]

foreach icon : provider_icons
  install_data(
    'data/icons/' + icon,
    install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'symbolic' / 'apps',
  )
endforeach

# Colored provider brand icons (model picker): same names without the
# -symbolic suffix, installed as regular app icons so GTK treats them
# as full-color (no recolor).
foreach icon : provider_icons
  colored_icon = icon.replace('-symbolic.svg', '.svg')
  install_data(
    'data/icons/' + colored_icon,
    install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'apps',
  )
endforeach

install_data(
  'data/' + meson.project_name() + '.metainfo.xml',
  install_dir: get_option('datadir') / 'metainfo',
)
