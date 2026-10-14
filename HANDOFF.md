# HANDOFF — opencode-client + opencode server patch
Fecha: 2026-10-13 ~13:15 UTC. Sesión viva: continuar aquí.

## 0. Qué es esto
Cliente nativo de OpenCode para elementary OS en **Vala (GTK4 + Granite 7,
sin libadwaita)**, alternativa liviana a OpenChamber. Habla directo con el
OpenCode v2 server API (`serve --port 4599`). Esta conversación vive en la
sesión del servidor `Greeting` (`ses_ecc21420fffeGWb9suuBiehr06`).

## 1. Estado runtime actual (verificado)
- Servidor prod: `opencode serve --port 4599 --print-logs` (PID cambia por
  reinicios), cwd `/home/haruki`. **Binario PATCHED** (fix reasoning, ver §4).
- Password actual del servidor: ver `~/.config/opencode-client/client.conf`
  (rota en CADA reinicio del servidor; hay que resync + relanzar app).
- App corriendo: `./build/io.github.haruki.openclient` (proceso `io.github.haruk`).
- Instancia vieja aparte: `opencode.exe serve --service` (PID ~6524, binario
  ORIGINAL). No tocar salvo que se quiera actualizar (requiere reiniciarla).
- TUI del usuario (`opencode2`) reconecta sola; tras cada reinicio del
  servidor puede necesitar re-anexarse.

## 2. Rutas del proyecto app (`/home/haruki/Projects/opencode-client/`)
- `meson.build`, `README.md`, `HANDOFF.md` (este archivo), `build/` (binario:
  `build/io.github.haruki.openclient`)
- `src/Application.vala` — entry, CSS + resource path de iconos
- `src/Config.vala` — lee `~/.config/opencode-client/client.conf`
- `src/MainWindow.vala` — cableado general (composer, chat, sidebar, banners)
- `src/Models/Session.vala`, `src/Models/Message.vala` (roles, parts,
  system/compaction/model-switched, `Message.user_message`),
  `src/Models/ModelInfo.vala` (**`ModelIcons.icon_for`** + fallback),
  `src/Models/FormInfo.vala`, `src/Models/CommandInfo.vala`
- `src/Services/Client.vala` — REST (`prompt`, `compact_session`, `get_diff`,
  `list_commands`, `execute_command`, `reply_permission`, `reply_form`,
  `rename_session`, `interrupt`)
- `src/Services/EventStream.vala` — SSE `/api/event`
- `src/Services/Store.vala` — hub de estado + TODOS los handlers SSE
  (compaction started/delta/ended/failed, model/agent selected, retry,
  execution.interrupted, permission.asked/replied, form.created/settled,
  reasoning/text/tool deltas)
- `src/Utils/BrailleSpinner.vala` — spinner CLI ⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏ (Box+Label;
  Gtk.Label es final en GTK4, igual que ScrolledWindow y MenuButton)
- `src/Utils/JsonUtil.vala`, `src/Utils/Markdown.vala`
- `src/Widgets/ChatView.vala` — autoscroll con intención (reveal-from-top,
  stick_to_bottom, pill Latest), bubbles + dividers + finish_live
- `src/Widgets/MessageBubble.vala` — burbuja (texto/tools/files) + `live`
  (LiveStatus) + `reasoning` (ReasoningBubble) FLAT encima, nunca dentro
- `src/Widgets/ReasoningBubble.vala` — bloque Thought plano 🧠 + spinner/check
- `src/Widgets/LiveStatus.vala` — línea de estado en vivo de 1 línea
- `src/Widgets/SystemDivider.vala` — `──── ⠿ texto ────` centrado con reglas
  (compaction, model/agent switch, retry, Interrupted) + expander Summary
- `src/Widgets/ToolCard.vala` — tool cards (spinner→✓/⚠️, `display_name`,
  `summarize_input`, `current_status`)
- `src/Widgets/ModelChooser.vala` — SOLO modelos (sin variants page)
- `src/Widgets/VariantChooser.vala` — thinking level separado (🧠 High…)
  + clase `VariantRow` (vive aquí, NO en ModelChooser)
- `src/Widgets/AgentChooser.vala`, `src/Widgets/Sidebar.vala` (lista,
  status dots, model icons, menú Compact/Rename/Fork/Diff/Delete),
  `src/Widgets/Composer.vala` (slash popup, busy_spinner, stop/send,
  variant_chooser), `src/Widgets/ConnectDialog.vala`,
  `src/Widgets/DiffDialog.vala`, `src/Widgets/FormCard.vala`
- `data/style.css` (clases: bubble, reasoning-block, live-status,
  system-divider, tool-card, braille-spinner, brain-icon, model-icon…),
  `data/openclient.gresource.xml`,
  `data/icons/*-symbolic.svg` (18 proveedores, fill `#2e3436`),
  `data/io.github.haruki.openclient.desktop`
- Archivos `.c` junto a cada `.vala` = artefactos generados (ignorar).

## 3. Rutas externas clave
- App config: `~/.config/opencode-client/client.conf` (host/puerto/password)
- Desktop: `~/.local/share/applications/io.github.haruki.openclient.desktop`
- Iconos instalados (theme real, recolor symbolic):
  `~/.local/share/icons/hicolor/symbolic/apps/*-symbolic.svg` (18)
- Server DB: `~/.local/share/opencode/opencode.db` (+ `-wal`/`-shm`),
  log: `~/.local/share/opencode/log/opencode.log`
- Binario servidor: `~/.bun/install/global/node_modules/@opencode/cli/bin/opencode.exe`
  (+ respaldo pre-patch: `/tmp/opencode/opencode.exe.bak-2.0.27`)
- Fork source + fix: `/tmp/opencode/opencode-src` (rama
  `fix/non-empty-reasoning-content`, commit `49c47ae`, 13 líneas en
  `packages/ai/src/protocols/openai-chat.ts`)
- Build release: `/tmp/opencode/opencode-src/packages/cli/dist/cli-linux-x64/bin/opencode`
- Logs: `/tmp/opencode/app.log`, `/tmp/opencode/serve.log`,
  `/tmp/opencode/serve-debug.log`, `/tmp/opencode/serve-src.log`
- Spec API: `/tmp/opencode/openapi.json` (v2.0.27); capturas SSE y scripts
  sueltos en `/tmp/opencode/` (`sse-*.txt`, `capture.py`, etc.)
- Backup iconos originales: `/tmp/opencode/icon-backup/`

## 4. Fix aplicado EN opencode (servidor), no en la app
**Bug**: Cat Jam Free (gateway `opencode-go`) exige `reasoning_content` no
vacío en cada assistant previo. El lowering enviaba `""` en mensajes sin
razonamiento (turnos interrumpidos, pasos solo-tools, cambios de modelo) y
el gateway lo rechaza (`missing_required_parameter`); cada intento fallido
agrega otro husk vacío (sesión auto-envenenada).
**Parche** (`lowerAssistantMessage`, `packages/ai/src/protocols/openai-chat.ts`):
si el campo quedaría vacío se reutiliza el texto propio del mensaje, o `" "`
como último recurso. Modelos no-estrictos intactos.
**Verificación**: repro dedicado (prompt+interrupt→husk→prompt fallaba 100%
con `messages[18]`); tras el parche responde `ok`, fingerprint del payload
limpio, cero 400s. Luego binario en producción + misma prueba en prod: OK.
**Pendiente**: subir el PR a `anomalyco/opencode` (falta `gh auth login` del
usuario; comandos exactos ya entregados en el chat).

## 5. Decisiones / gotchas (no redescubrir)
- `fill="currentColor"` en SVG vía gresource = NEGRO (sin recolor); la
  paleta symbolic canónica es `#2e3436` + ubicación theme real
  (`hicolor/symbolic/apps`, NO gresource: `is_symbolic=false` ahí).
- `Gtk.Image` NO tiene `use-symbolic` en GTK4 (es de VolumeButton).
- `Gtk.Label/ScrolledWindow/MenuButton` son `final`: wrapear, no heredar.
- Password del servidor ROTA cada boot (sale en stdout). Tras reiniciar
  servidor: actualizar `client.conf` + relanzar app.
- `pkill -f` con patrón que matchea la propia línea se suicida; usar
  `pkill -x io.github.haruk` y PIDs explícitos para opencode.
- ETXTBSY al reemplazar binario en uso: `rm` + `cp` (unlink), nunca `cp`
  directo; la instancia `--service` retiene el inodo viejo.
- La herramienta `edit` a veces reporta "Could not find oldString" fantasma
  habiendo aplicado el cambio: verificar con grep antes de reintentar
  (heredocs python son más confiables).
- Comandos slash: `/compact /new /diff` builtins + servidor (`/init /review`)
  vía `POST /session/:id/command`; popup con ↑/↓+Enter, Esc cierra.
- Compact API: `POST /api/session/:id/compact`; eventos
  `compaction.started/delta/ended/failed`; auto vs manual por `reason`.
- Sesión `Greeting` = ESTA conversación (el usuario mira la app en vivo).

## 6. Abierto / siguiente
1. PR upstream (bloqueado en auth del usuario).
2. Reiniciar instancia `serve --service` para que tome el binario patched
   (o dejarla; solo afecta si se usa desktop/servicio).
3. Pedido pendiente del usuario (no iniciado): shield de modo de permisos en
   el composer (read-only / always ask / always allow-yolo) vía
   `PATCH /session/:id {permissions: ruleset}` + soporte prompts de pregunta
   del modelo (forms ya existen: FormCard/dock/banner — verificar en vivo).
4. Opcional: al cambiar de modelo, el thinking level se conserva si el nuevo
   modelo lo soporta (ya implementado en MainWindow).
