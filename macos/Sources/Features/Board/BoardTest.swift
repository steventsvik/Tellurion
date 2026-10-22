#if os(macOS)
import AppKit
import WebKit
import GhosttyKit

/// Test-only: `GHOSTTY_EXTREME_TEST_BOARD=<file>` plays a timed script against the boards, like
/// `DemoDirector` does for tabs. Each line is `<seconds since launch> <action> [args]`; `#`
/// starts a comment. Actions go to the key board (or the first one). Tiles are 1-based, in
/// the order they were added. Mouse and key actions are real events sent to the window, so
/// they go through hit-testing, gestures and key equivalents as a person's would.
///
///     tile                       a new terminal tile
///     shells <n> [folder]        launch n shells as a block, as the composer does
///     agents <bin>:<n>,… <folder> [task]  launch agents as the composer does (claude:1,codex:1)
///     type <n> <text>            type text plus Enter into tile n
///     act <n> <action>           run a Ghostty keybinding action in tile n (new_split:right…)
///     zoom <factor> | fit | actual | focus <n> | move <n> <dx> <dy> | close <n>
///     dragtile <n> <dx> <dy>     drag tile n's title bar by screen points
///     resizetile <n> <dx> <dy>   drag tile n's corner
///     pan <dx> <dy>              drag empty board
///     clicktile <n> header|body [clicks]
///     scrollzoom <dy>            ⌘-scroll over empty board
///     keys <combo>               e.g. cmd+opt+9, cmd+t, cmd+z
///     camera <x> <y>             put the view's top-left corner at a board point
///     composer | sidebar | rename <name> | newboard | closeboard | undo
///     edition classic|board | newwindow | settings | welcome
///     snapwindow <title prefix> <file.png>   draw any window into a PNG
///     state                      log the boards, tiles and windows to GHOSTTY_EXTREME_TEST_LOG
///     tool <name> [n]            open a tool for tile n (editor, visualfix, history, palette,
///                                mission, race, handoff, loop, localhost, review, activity, memory)
///     tilemenu <n>               log tile n's menu
///     tiletitle <n> <name>       name tile n
///     session <kind>             a new session from the New menu (claude, codex, terminal, hermes)
///     tools                      log which tools are open and what they see
///     snapshot <file.png>        draw the window (or its sheet) into a PNG, frames in <file>.txt
///     ask <text> | agentdo <reply JSON> | agentconfirm | agentcancel | agentlog | agentcontext
///                                the board's agent (see BoardAssistant)
///     pause|resume [n…] | procs <n>  pause tiles; log tile n's process states
///     orchnew [n…] | orchconnect | orchdone | orchclick <n> | orchgroup <n> | orchstate
///     orchcanned <reply JSON> | orchcmd <text> | orchclose    orchestrators (see BoardTeams)
///     minsize                    log the window's minimum and fitting sizes
@MainActor
enum BoardTest {
    private static var started = false

    static func startIfRequested(_ controller: BoardController) {
        guard !started, let path = ProcessInfo.processInfo.environment["GHOSTTY_EXTREME_TEST_BOARD"],
              let script = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        started = true
        for raw in script.split(separator: "\n") {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces)
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, let time = Double(parts[0]) else { continue }
            let command = parts[1]
            DispatchQueue.main.asyncAfter(deadline: .now() + time) {
                MainActor.assumeIsolated {
                    DemoDirector.note("board \(command)")
                    run(command)
                    // An event after each command, so it's its own step to undo as a real
                    // click's would be (the undo manager closes its group after an event).
                    if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                        NSApp.postEvent(wake, atStart: false)
                    }
                }
            }
        }
    }

    private static var board: BoardController? {
        BoardController.all.first { $0.window?.isKeyWindow == true } ?? BoardController.front
    }

    private static func tile(_ n: String, of controller: BoardController) -> Ghostty.SurfaceView? {
        guard let index = Int(n), index >= 1, index <= controller.model.surfaces.count else { return nil }
        return controller.model.surfaces[index - 1]
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private static func run(_ command: String) {
        let parts = command.split(separator: " ").map(String.init)
        guard let action = parts.first else { return }
        let args = Array(parts.dropFirst())
        let ghostty = (NSApp.delegate as? AppDelegate)?.ghostty

        // Actions that don't need a board.
        switch action {
        case "edition":
            ExtremeEdition.set(args.first == "board" ? .board : .classic)
            return
        case "newwindow":
            (NSApp.delegate as? AppDelegate)?.newWindow(nil)
            return
        case "newboard":
            if let ghostty { Board.newBoard(ghostty) }
            return
        case "switchboard", "boardwindow":
            // switchboard <name>: as clicking it in the list; boardwindow: Open in New Window.
            let name = args.joined(separator: " ")
            if let ghostty, let saved = BoardStore.all().first(where: { $0.name == name }) {
                Board.reopen(ghostty, saved, newWindow: action == "boardwindow")
            }
            return
        case "deleteboard":
            let name = args.joined(separator: " ")
            if let saved = BoardStore.all().first(where: { $0.name == name }), let front = BoardController.front {
                Board.delete(saved, from: front)
            }
            return
        case "sheetbutton":
            // sheetbutton <title>: clicks a button on an open sheet (a confirmation).
            let title = args.joined(separator: " ")
            for window in NSApp.windows {
                guard let sheet = window.attachedSheet else { continue }
                let button = sheet.contentView?.descendants.compactMap { $0 as? NSButton }.first { $0.title == title }
                DemoDirector.note("sheet \"\(sheet.title)\" button \(title): \(button == nil ? "missing" : "clicked")")
                button?.performClick(nil)
            }
            return
        case "boards":
            for board in BoardController.all {
                let window = board.window
                DemoDirector.note("boards \"\(board.workspace.name)\" sketches=\(board.model.sketches.count) visible=\(window?.isVisible ?? false) key=\(window?.isKeyWindow ?? false) "
                                  + "tabs=\(window?.tabGroup?.windows.count ?? 1) tabbar=\(window?.tabGroup?.isTabBarVisible ?? false) frame=\(window?.frame ?? .zero)")
            }
            DemoDirector.note("boards saved=\(BoardStore.all().map(\.name).sorted().joined(separator: ", "))")
            return
        case "state":
            state()
            return
        case "keys":
            keys(args.first ?? "")
            return
        case "settings":
            ExtremeSettingsWindow.show()
            return
        case "welcome":
            WelcomeWindow.show()
            return
        case "snapwindow":
            // snapwindow <title prefix> <file.png>
            guard args.count >= 2, let window = NSApp.windows.first(where: { $0.isVisible && $0.title.hasPrefix(args[0]) }),
                  let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[1]))
            return
        default:
            break
        }

        guard let controller = board else {
            DemoDirector.note("board: no board for \(action)")
            return
        }
        switch action {
        case "tile":
            controller.addTile()
        case "shells":
            let n = Int(args.first ?? "") ?? 1
            controller.launch(Array(repeating: (agent: nil, command: ""), count: n), folder: args.count > 1 ? args[1] : nil)
        case "agents":
            let folder = args.count > 1 ? args[1] : nil
            let task = args.dropFirst(2).joined(separator: " ")
            var lines: [(agent: BoardAgent?, command: String)] = []
            for spec in (args.first ?? "").split(separator: ",") {
                let pair = spec.split(separator: ":").map(String.init)
                guard let agent = BoardAgent.catalog.first(where: { $0.binary == pair.first }) else { continue }
                for _ in 0..<(Int(pair.last ?? "") ?? 1) {
                    lines.append((agent, agent.command(prompt: task.isEmpty ? nil : task)))
                }
            }
            controller.launch(lines, folder: folder)
        case "type":
            guard args.count >= 2, let surface = tile(args[0], of: controller) else { return }
            surface.surfaceModel?.sendText(args.dropFirst().joined(separator: " "))
            surface.surfaceModel?.sendKeyEvent(.init(key: .enter, action: .press, text: "\r"))
            surface.surfaceModel?.sendKeyEvent(.init(key: .enter, action: .release))
        case "enter":
            // enter <n>: presses Return in tile n (answers a prompt's default).
            guard let surface = tile(args.first ?? "", of: controller) else { return }
            surface.surfaceModel?.sendKeyEvent(.init(key: .enter, action: .press, text: "\r"))
            surface.surfaceModel?.sendKeyEvent(.init(key: .enter, action: .release))
        case "down":
            // down <n>: presses ↓ in tile n (moves a prompt's choice).
            guard let surface = tile(args.first ?? "", of: controller) else { return }
            surface.surfaceModel?.sendKeyEvent(.init(key: .arrowDown, action: .press))
            surface.surfaceModel?.sendKeyEvent(.init(key: .arrowDown, action: .release))
        case "act":
            guard args.count == 2, let surface = tile(args[0], of: controller) else { return }
            let ok = surface.surfaceModel?.perform(action: args[1]) ?? false
            DemoDirector.note("board act \(args[1]) -> \(ok)")
        case "zoom":
            controller.zoom(by: CGFloat(Double(args.first ?? "") ?? 1))
        case "fit":
            controller.fitAll()
        case "actual":
            controller.zoomToActualSize()
        case "focus":
            if let surface = tile(args.first ?? "", of: controller) { controller.focusTile(surface) }
        case "close":
            if let surface = tile(args.first ?? "", of: controller) { controller.close(surface) }
        case "move":
            guard args.count == 3, let surface = tile(args[0], of: controller),
                  let frame = controller.model.frames[surface.id],
                  let dx = Double(args[1]), let dy = Double(args[2]) else { return }
            controller.move(id: surface.id, to: frame.offsetBy(dx: dx, dy: dy))
            controller.tileDidSettle()
        case "dragtile", "resizetile":
            guard args.count == 3, let surface = tile(args[0], of: controller),
                  let dx = Double(args[1]), let dy = Double(args[2]),
                  let rect = windowRect(of: surface, in: controller) else { return }
            let start = action == "dragtile" ? CGPoint(x: rect.midX, y: rect.minY + 15 * zoom(controller))
                : CGPoint(x: rect.maxX - 12 * zoom(controller), y: rect.maxY - 12 * zoom(controller))
            drag(from: start, by: CGSize(width: dx, height: dy), in: controller)
        case "pan":
            guard args.count == 2, let dx = Double(args[0]), let dy = Double(args[1]),
                  let start = emptyPoint(in: controller) else { return }
            drag(from: start, by: CGSize(width: dx, height: dy), in: controller)
        case "clicktile":
            guard args.count >= 2, let surface = tile(args[0], of: controller),
                  let rect = windowRect(of: surface, in: controller), let window = controller.window else { return }
            let z = zoom(controller)
            let point: CGPoint
            switch args[1] {
            case "header": point = CGPoint(x: rect.minX + rect.width * 0.4, y: rect.minY + 15 * z)
            case "close": point = CGPoint(x: rect.maxX - 19 * z, y: rect.minY + 15 * z)
            default: point = CGPoint(x: rect.midX, y: rect.midY)
            }
            let clicks = Int(args.count > 2 ? args[2] : "1") ?? 1
            for count in 1...clicks {
                mouse(.leftMouseDown, point, in: window, clicks: count)
                mouse(.leftMouseUp, point, in: window, clicks: count)
            }
        case "scrolltile":
            // scrolltile <tile> <dy>: two fingers over the middle of a tile.
            guard args.count == 2, let surface = tile(args[0], of: controller), let dy = Double(args[1]),
                  let window = controller.window else { return }
            let height = window.contentView?.bounds.height ?? 0
            let center = surface.convert(CGPoint(x: surface.bounds.midX, y: surface.bounds.midY), to: nil)
            scroll(dy, at: CGPoint(x: center.x, y: height - center.y), in: window, command: false)
        case "map":
            controller.showAgentMap()
        case "closemap":
            if let card = controller.model.cards.last(where: { $0.kind == .map }) { controller.removeCard(card.id) }
        case "mapstate":
            for card in controller.model.cards where card.kind == .map {
                DemoDirector.note(controller.cardView(card.id)?.mapState ?? "map: no view")
            }
            if !controller.model.cards.contains(where: { $0.kind == .map }) { DemoDirector.note("map: none") }
        case "showtile":
            guard let surface = tile(args.first ?? "", of: controller), let frame = controller.model.frames[surface.id] else { return }
            controller.zoom(toFit: frame.insetBy(dx: -200, dy: -200), animated: false)
        case "focusproject":
            // focusproject <folder name>: the first tile in that project gets the keyboard.
            guard let surface = controller.model.surfaces.first(where: {
                controller.model.projects[$0.id].map(BoardProjects.name) == args.first
            }) else { return }
            controller.focusSurface(surface)
        case "unfocus":
            controller.window?.makeFirstResponder(nil)
        case "spam":
            // spam <n>: new terminals as fast as the button can be pressed.
            for _ in 0..<(Int(args.first ?? "") ?? 3) { controller.addTile() }
        case "scrollzoom":
            guard let dy = Double(args.first ?? ""), let point = emptyPoint(in: controller), let window = controller.window else { return }
            scroll(dy, at: point, in: window, command: true)
        case "camera":
            guard args.count == 2, let x = Double(args[0]), let y = Double(args[1]), let canvas = controller.canvas else { return }
            canvas.contentView.scroll(to: CGPoint(x: x, y: y))
            canvas.reflectScrolledClipView(canvas.contentView)
        case "composer":
            controller.model.showComposer = true
        case "sidebar":
            controller.model.showSidebar.toggle()
        case "rename":
            controller.rename(args.joined(separator: " "))
        case "closeboard":
            controller.window?.performClose(nil)
        case "undo":
            if let undo = controller.undoManager {
                DemoDirector.note("undo can=\(undo.canUndo) name=\(undo.undoActionName) level=\(undo.groupingLevel)")
            }
            controller.undoManager?.undo()
        case "snapshot":
            guard let path = args.first else { return }
            snapshot(controller, to: path)
        case "tool":
            guard let name = args.first else { return }
            if args.count > 1, let surface = tile(args[1], of: controller) { controller.focusTile(surface) }
            openTool(name, on: controller)
        case "tilemenu":
            guard let surface = tile(args.first ?? "", of: controller) else { return }
            let titles = BoardTileMenu.actions(for: surface, in: controller)
                .map { $0.map { $0.enabled ? $0.title : "(\($0.title))" } ?? "—" }
            DemoDirector.note("tilemenu " + titles.joined(separator: " | "))
        case "tiletitle":
            guard args.count >= 2, let surface = tile(args[0], of: controller) else { return }
            controller.setTitle(args.dropFirst().joined(separator: " "), for: surface)
        case "session":
            guard let kind = NewSessionKind.allCases.first(where: { "\($0)" == args.first }) else { return }
            kind.open(from: controller)
        case "tools":
            tools(controller)
        case "arrange":
            controller.arrangeByProject()
        case "card":
            guard let kind = BoardCard.Kind(rawValue: args.first ?? "") else { return }
            controller.addCard(kind)
        case "carditem":
            // carditem <text…>: adds to the last card (column 0 on a kanban).
            guard let card = controller.model.cards.last else { return }
            controller.updateCard(card.id) { $0.items.append(CardItem(text: args.joined(separator: " "))) }
        case "cardhand":
            // cardhand <item number> <tile number>: hands an item of the last kanban to a tile.
            guard let card = controller.model.cards.last(where: { $0.kind == .kanban }), let n = Int(args.first ?? ""), n >= 1, n <= card.items.count,
                  args.count > 1, let surface = tile(args[1], of: controller) else { return }
            controller.hand(card.items[n - 1].id, in: card.id, to: surface)
        case "kanbandrag":
            // kanbandrag <item number> <column 0-2>: drags a card of the last kanban there.
            guard let card = controller.model.cards.last(where: { $0.kind == .kanban }), let n = Int(args.first ?? ""),
                  n >= 1, n <= card.items.count, let column = Int(args.count > 1 ? args[1] : ""),
                  let view = controller.cardView(card.id), let window = controller.window else { return }
            let id = card.items[n - 1].id
            guard let cardView = view.descendants.compactMap({ $0 as? KanbanCard }).first(where: { $0.itemID == id }),
                  let content = cardView.superview else { return }
            let height = window.contentView?.bounds.height ?? 0
            let from = cardView.convert(CGPoint(x: cardView.bounds.midX, y: cardView.bounds.midY), to: nil)
            let columnX = content.bounds.width * (CGFloat(column) * 2 + 1) / 6
            let to = content.convert(CGPoint(x: columnX, y: content.bounds.height - 40), to: nil)
            drag(from: CGPoint(x: from.x, y: height - from.y), by: CGSize(width: to.x - from.x, height: from.y - to.y), in: controller)
        case "showcard":
            guard let card = controller.model.cards.first(where: { $0.kind.rawValue == args.first }),
                  let frame = controller.model.frames[card.id] else { return }
            controller.zoom(toFit: frame.insetBy(dx: -30, dy: -30), animated: false)
        case "ask":
            // ask <text>: the board's bar, as if typed and sent (runs the real agent).
            controller.assistant.send(args.joined(separator: " "))
        case "agentdo":
            // agentdo <reply JSON>: carries out a reply as if the board's agent had answered.
            let context = controller.assistantContext(agents: BoardAgent.catalog)
            guard let reply = BoardAssistantReply.decode(args.joined(separator: " ")) else {
                DemoDirector.note("agent bad reply")
                return
            }
            controller.assistant.apply(reply, handles: context.handles)
        case "minsize":
            guard let window = controller.window else { return }
            DemoDirector.note("minsize window=\(window.minSize) content=\(window.contentMinSize) fitting=\(window.contentView?.fittingSize ?? .zero)")
        case "groupnew":
            // groupnew <tile n…> [name]: a named group of those tiles.
            let tiles = args.compactMap { tile($0, of: controller)?.id }
            let name = args.last.flatMap { Int($0) == nil ? $0 : nil }
            controller.createGroup(tiles, name: name, role: .backend)
        case "groupspawn":
            // groupspawn <name> <role> <agent,agent,…> [skip]: the composer's Spawn.
            guard args.count >= 3 else { return }
            controller.spawnGroup(name: args[0], role: BoardRole(rawValue: args[1]) ?? .general,
                                  slots: args[2].split(separator: ",").map(String.init), folder: nil, task: nil,
                                  skip: args.count > 3 && args[3] == "skip")
        case "groupcollapse":
            guard let group = controller.model.groups.first else { return }
            controller.toggleCollapsed(group.id)
        case "groupcompose":
            controller.model.showGroupComposer = true
        case "grouptidy":
            guard let group = controller.model.groups.first else { return }
            controller.tidyGroup(group.id)
        case "groupstate":
            let number = { (id: UUID) in (controller.model.surfaces.firstIndex { $0.id == id }).map { "\($0 + 1)" } ?? "?" }
            for group in controller.model.groups {
                let display = controller.namedGroupDisplays().first { $0.id == group.id }
                DemoDirector.note("group \(group.name) role=\(group.role.rawValue) collapsed=\(group.collapsed) tiles="
                                  + group.tiles.map(number).joined(separator: ",")
                                  + " running=\(display?.running ?? -1) frame=\(display.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "-")")
            }
            DemoDirector.note("group count=\(controller.model.groups.count) projectAreas=\(BoardTiles.groups(controller.model).count) hidden="
                              + controller.collapsedTiles.map(number).sorted().joined(separator: ","))
            for surface in controller.model.surfaces {
                DemoDirector.note("tile \(number(surface.id)) title=\(controller.model.titles[surface.id] ?? "-") skip=\(controller.skipsPermissions(surface.id))")
            }
        case "drop":
            // drop <n> <dx> <dy>: moves tile n by that much and lets it settle (joins or leaves groups).
            guard args.count == 3, let surface = tile(args[0], of: controller), let frame = controller.model.frames[surface.id],
                  let dx = Double(args[1]), let dy = Double(args[2]) else { return }
            controller.move(id: surface.id, to: frame.offsetBy(dx: dx, dy: dy))
            controller.settleDrop(id: surface.id, from: frame)
        case "droponto":
            // droponto <n> <m>: drops tile n at tile m's group, beside m.
            guard args.count == 2, let a = tile(args[0], of: controller), let b = tile(args[1], of: controller),
                  let fa = controller.model.frames[a.id], let fb = controller.model.frames[b.id] else { return }
            controller.move(id: a.id, to: CGRect(x: fb.maxX + 20, y: fb.minY, width: fa.width, height: fa.height))
            controller.settleDrop(id: a.id)
        case "tilerestart":
            guard let surface = tile(args.first ?? "", of: controller) else { return }
            controller.restartTile(surface)
        case "tiledup":
            guard let surface = tile(args.first ?? "", of: controller) else { return }
            controller.duplicateTile(surface)
        case "pick":
            // pick <name>: picks a palette tool (select, pen, eraser, text, web, agent, terminal…).
            guard let tool = BoardTool(rawValue: args.first ?? "") else { return }
            controller.choose(tool)
        case "inkline":
            // inkline <tile n | 0> <dx> <dy>: drags the mouse with the current tool from tile n's middle
            // (0: the view's middle) by that many board points.
            guard args.count == 3, let dx = Double(args[1]), let dy = Double(args[2]),
                  let window = controller.window, let document = controller.groupsView?.superview,
                  let visible = controller.canvas?.documentVisibleRect else { return }
            let from = tile(args[0], of: controller).flatMap { controller.model.frames[$0.id] } ?? visible
            let x = from.midX, y = from.midY
            let height = window.contentView?.bounds.height ?? 0
            let start = document.convert(CGPoint(x: x, y: y), to: nil)
            let end = document.convert(CGPoint(x: x + dx, y: y + dy), to: nil)
            drag(from: CGPoint(x: start.x, y: height - start.y), by: CGSize(width: end.x - start.x, height: start.y - end.y), in: controller)
        case "tileorigin":
            // tileorigin <n>: logs tile n's frame (to aim inklines).
            guard let surface = tile(args.first ?? "", of: controller) else { return }
            DemoDirector.note("tile frame \(controller.model.frames[surface.id] ?? .zero)")
        case "inkstate":
            DemoDirector.note("ink strokes=\(controller.model.ink.count) anchored=\(controller.model.ink.filter { $0.anchor != nil }.count) "
                              + controller.model.ink.compactMap { controller.inkPoints($0)?.first }.map { "(\(Int($0.x)),\(Int($0.y)))" }.joined(separator: " "))
            DemoDirector.note("labels " + controller.model.labels.map { "\($0.text)@\(Int($0.frame.minX)),\(Int($0.frame.minY))" }.joined(separator: " "))
        case "labelnew":
            guard let rect = controller.canvas?.documentVisibleRect else { return }
            controller.addLabel(at: CGPoint(x: rect.midX, y: rect.minY + 120), text: args.joined(separator: " "), edit: false)
        case "radial":
            guard let rect = controller.canvas?.documentVisibleRect, let content = controller.window?.contentView else { return }
            controller.model.radial = (CGPoint(x: content.bounds.midX, y: content.bounds.midY), CGPoint(x: rect.midX, y: rect.midY))
        case "webnew":
            guard let rect = controller.canvas?.documentVisibleRect else { return }
            controller.addWebTile(at: CGPoint(x: rect.midX, y: rect.midY), url: args.first)
        case "webstate":
            for card in controller.model.cards where card.kind == .web {
                DemoDirector.note("web \(card.title) tabs=\(card.tabs ?? []) tab=\(card.tab ?? -1) viewport=\(card.viewport ?? "-") frame=\(controller.model.frames[card.id].map { "\(Int($0.width))x\(Int($0.height))" } ?? "-")")
            }
        case "webviewport":
            // webviewport <preset name…|fit>: the first web tile's viewport.
            guard let content = controller.window?.contentView?.descendants.compactMap({ $0 as? WebContent }).first else { return }
            let name = args.joined(separator: " ")
            content.setViewport(name == "fit" ? nil : name)
        case "webinspect":
            guard let content = controller.window?.contentView?.descendants.compactMap({ $0 as? WebContent }).first else { return }
            let before = NSApp.windows.filter(\.isVisible).count
            content.inspect()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                DemoDirector.note("webinspect content " + (content.subviews + content.subviews.flatMap(\.subviews)).map { "\(type(of: $0)) \(Int($0.frame.minY)) \(Int($0.frame.width))x\(Int($0.frame.height))" }.joined(separator: ", "))
                DemoDirector.note("webinspect windows \(before) -> \(NSApp.windows.filter(\.isVisible).count): "
                                  + NSApp.windows.map { "\(type(of: $0))[\($0.isVisible ? "v" : "-")\($0.isKeyWindow ? "k" : "")] \(Int($0.frame.width))x\(Int($0.frame.height)) '\($0.title)'" }.joined(separator: ", "))
            }
        case "webeval":
            // webeval <js>: runs script in the first web tile's page and logs the result.
            guard let page = controller.window?.contentView?.descendants.compactMap({ $0 as? WKWebView }).first(where: { !$0.isHidden }) else { return }
            page.evaluateJavaScript(args.joined(separator: " ")) { result, error in
                DemoDirector.note("webeval \(result.map { "\($0)" } ?? "nil") \(error.map { "\($0.localizedDescription)" } ?? "")")
            }
        case "docs":
            // docs <project folder>: opens Documents on that project.
            controller.showDocuments()
            if let folder = args.first { controller.documents.project = folder; controller.documents.refresh() }
        case "docsgen":
            // docsgen <template id> <quick|balanced|thorough> [codex]: writes it (real run).
            let docs = controller.documents
            docs.template = StudioDocs.templates.first { $0.id == args.first } ?? docs.template
            docs.effort = StudioDocs.Effort(rawValue: args.count > 1 ? args[1] : "quick") ?? .quick
            docs.engine = args.count > 2 && args[2] == "codex" ? .codex : .claude
            docs.generate()
        case "docsstate":
            let docs = controller.documents
            let stats = MarkdownHTML.stats(docs.markdown)
            DemoDirector.note("docs running=\(docs.running) phase=\(String(describing: docs.phase)) words=\(stats.words) title=\(MarkdownHTML.title(docs.markdown) ?? "-") file=\(docs.file?.lastPathComponent ?? "-") error=\(docs.error ?? "-") library=\(docs.library.count)")
        case "docsplace":
            if let file = controller.documents.file {
                controller.model.showDocuments = false
                controller.placeDocument(file)
            }
        case "docspdf":
            // docspdf <out.pdf>: exports what's shown, without asking where.
            guard let path = args.first else { return }
            PDFExporter.shared.export(html: MarkdownHTML.page(controller.documents.markdown), to: URL(fileURLWithPath: path))
        case "diagramgen":
            // diagramgen <project folder> <preset title…>: draws it (real run).
            guard args.count >= 2 else { return }
            controller.setFolder(args[0])
            let title = args.dropFirst().joined(separator: " ")
            guard let preset = StudioDiagram.presets.first(where: { $0.title == title }) else { return }
            controller.diagrams.generate(preset.ask, title: preset.title)
        case "diagramstarter":
            // diagramstarter <name…> [colorful]
            controller.diagrams.ink = args.last != "colorful"
            controller.diagrams.starter(args.filter { $0 != "colorful" }.joined(separator: " "))
        case "diagramjson":
            // diagramjson <file.json> [colorful]: draws a diagram spec without a model.
            guard let path = args.first, let data = FileManager.default.contents(atPath: path),
                  let spec = try? JSONDecoder().decode(StudioDiagram.Spec.self, from: data) else { return }
            let drawn = StudioDiagram.elements(spec, ink: args.last != "colorful")
            let id = controller.addSketch(elements: drawn.elements, at: nil, size: drawn.size, focus: false)
            controller.renameSketch(id, to: spec.title ?? "Diagram")
        case "diagramstate":
            DemoDirector.note("diagram drawing=\(controller.diagrams.drawing != nil) error=\(controller.diagrams.error ?? "-") sketches="
                              + controller.model.sketches.map { "\($0.title):\($0.elements.count)" }.joined(separator: ","))
        case "accountadd":
            // accountadd <claude|codex> <name…>: a profile, and a tile to sign it in.
            guard let provider = BoardAccount.Provider(rawValue: args.first ?? "") else { return }
            controller.connect(BoardAccounts.shared.add(provider, name: args.dropFirst().joined(separator: " ")))
        case "accountuse":
            // accountuse <claude|codex> <name…|usual>
            guard let provider = BoardAccount.Provider(rawValue: args.first ?? "") else { return }
            let name = args.dropFirst().joined(separator: " ")
            BoardAccounts.shared.use(BoardAccounts.shared.accounts.first { $0.name == name }?.id, for: provider)
        case "accountremove":
            for account in BoardAccounts.shared.accounts where account.name == args.joined(separator: " ") { BoardAccounts.shared.remove(account.id) }
        case "accountstate":
            DemoDirector.note("accounts " + BoardAccounts.shared.accounts.map { "\($0.provider.rawValue):\($0.name)(\($0.initials)) signedIn=\($0.signedIn)" }.joined(separator: ", ")
                              + " active=" + BoardAccounts.shared.active.map { "\($0.key.rawValue)=\(BoardAccounts.shared.account($0.value)?.name ?? "?")" }.joined(separator: ","))
            for (index, surface) in controller.model.surfaces.enumerated() {
                let chosen = controller.model.tileAccounts[surface.id] ?? [:]
                DemoDirector.note("tile \(index + 1) accounts=" + chosen.map { "\($0.key.rawValue)=\(BoardAccounts.shared.account($0.value)?.name ?? "?")" }.joined(separator: ","))
            }
        case "tileenv":
            // tileenv <n> <VAR>: the variable as tile n's processes have it.
            guard args.count == 2, let surface = tile(args[0], of: controller) else { return }
            let name = args[1], id = surface.id.uuidString
            DispatchQueue.global().async {
                let found = ProcessProbe.userPIDs().compactMap { pid -> String? in
                    guard ProcessProbe.environment(pid, BoardPause.surfaceKey) == id else { return nil }
                    return ProcessProbe.environment(pid, name).map { ($0 as NSString).abbreviatingWithTildeInPath }
                }
                DispatchQueue.main.async { DemoDirector.note("tileenv \(args[0]) \(name)=\(Set(found).sorted())") }
            }
        case "home":
            BoardHome.show()
        case "mission":
            controller.model.showMissionMap = args.first != "off"
        case "orchnew":
            // orchnew [tile n…]: an orchestrator wired to those tiles.
            let tiles = args.compactMap { tile($0, of: controller)?.id }
            controller.newOrchestrator(wiring: tiles)
        case "orchconnect":
            guard let team = controller.model.teams.first else { return }
            controller.startWiring(team.id)
        case "orchbutton":
            // orchbutton: a real click on the first orchestrator's Connect / Done button.
            guard let team = controller.model.teams.first, let frame = controller.model.frames[team.id] else { return }
            let point = CGPoint(x: frame.maxX - 45, y: frame.minY + BoardNodeView.header + 21)
            if let view = controller.cardView(team.id), let document = controller.groupsView?.superview {
                let local = view.convert(document.convert(point, to: nil), from: nil)
                DemoDirector.note("orch button local=\(local) bounds=\(view.bounds) frame=\(frame) zoom=\(controller.model.zoom)")
            }
            click(board: point, in: controller)
        case "orchdone":
            controller.endWiring()
        case "orchclick":
            // orchclick <n>: a real click in the middle of tile n's terminal.
            guard let surface = tile(args.first ?? "", of: controller), let frame = controller.model.frames[surface.id] else { return }
            click(board: CGPoint(x: frame.midX, y: frame.midY), in: controller)
        case "orchgroup":
            // orchgroup <n>: a real click on the wire pill of tile n's group.
            guard let surface = tile(args.first ?? "", of: controller), let project = controller.model.projects[surface.id],
                  let rect = controller.groupsView?.pillRect(of: project) else {
                DemoDirector.note("orch no pill")
                return
            }
            click(board: CGPoint(x: rect.midX, y: rect.midY), in: controller)
        case "orchstate":
            let number = { (id: UUID) in (controller.model.surfaces.firstIndex { $0.id == id }).map { "\($0 + 1)" } ?? "?" }
            for team in controller.model.teams {
                let brain = controller.orchestratorBrain(team.id)
                DemoDirector.note("orch \(controller.orchestratorName(team.id)) color=\(team.color) wiring=\(controller.model.wiring == team.id) "
                                  + "members=" + team.members.map { "\(number($0.tile)):\($0.role ?? "-")" }.joined(separator: ",")
                                  + " groups=" + team.groups.map(controller.groupTitle).joined(separator: ",")
                                  + " agents=" + controller.wiredAgents(team).map { number($0.surface.id) }.joined(separator: ",")
                                  + " running=\(brain.running) busy=\(brain.busy) turn=\(brain.turn)")
            }
            DemoDirector.note("orch links=\(controller.teamLinks().count) teams=\(controller.model.teams.count)")
        case "orchcanned":
            // orchcanned <reply JSON>: the first orchestrator's next turn answers this instead.
            guard let team = controller.model.teams.first,
                  let data = HeadlessAgent.object(in: args.joined(separator: " ")),
                  let reply = try? JSONDecoder().decode(OrchestratorReply.self, from: data) else {
                DemoDirector.note("orch bad reply")
                return
            }
            controller.orchestratorBrain(team.id).canned.append(reply)
        case "orchwiregroup":
            // orchwiregroup <n>: wires tile n's project group to the first orchestrator.
            guard let team = controller.model.teams.first, let surface = tile(args.first ?? "", of: controller),
                  let project = controller.model.projects[surface.id] else {
                DemoDirector.note("orch no group")
                return
            }
            controller.toggleGroup(project, in: team.id)
        case "orchturns":
            guard let team = controller.model.teams.first, let turns = Int(args.first ?? "") else { return }
            controller.setTurns(turns, for: team.id)
        case "orchcmd":
            guard let team = controller.model.teams.first else { return }
            controller.orchestratorBrain(team.id).command(args.joined(separator: " "))
        case "orchclose":
            guard let team = controller.model.teams.first else { return }
            controller.removeCard(team.id)
        case "agentconfirm":
            controller.assistant.confirm()
        case "agentcancel":
            controller.assistant.cancel()
        case "agentcontext":
            DemoDirector.note("agent context\n" + controller.assistantContext(agents: BoardAgent.catalog).text)
        case "agentlog":
            let assistant = controller.assistant
            DemoDirector.note("agent busy=\(assistant.busy) engine=\(assistant.engine?.rawValue ?? "-") engines=\(assistant.engines?.map(\.rawValue) ?? [])")
            for message in assistant.messages {
                DemoDirector.note("agent \(message.role): \(message.text) \(message.done)")
            }
            if let pending = assistant.pending { DemoDirector.note("agent pending \(pending.lines)") }
        case "pause", "resume":
            // pause|resume [tile numbers…]: all tiles without numbers.
            let ids = args.isEmpty ? nil : args.compactMap { tile($0, of: controller)?.id }
            controller.setPaused(action == "pause", ids)
        case "procs":
            // procs <n>: the state of tile n's processes (T = stopped).
            guard let surface = tile(args.first ?? "", of: controller) else { return }
            let pids = ProcessProbe.userPIDs().filter { ProcessProbe.environment($0, BoardPause.surfaceKey) == surface.id.uuidString }
            guard !pids.isEmpty else {
                DemoDirector.note("procs none paused=\(controller.model.paused.contains(surface.id))")
                return
            }
            let result = ToolPath.run("/bin/ps", ["-o", "stat=,comm=", "-p", pids.map(String.init).joined(separator: ",")], in: "/")
            let states = result.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            DemoDirector.note("procs paused=\(controller.model.paused.contains(surface.id)) \(states.joined(separator: " | "))")
        case "cardstate":
            for card in controller.model.cards {
                DemoDirector.note("card \(card.kind.rawValue) \(card.title) text=\(card.text.prefix(40)) items=\(card.items.count)")
                for item in card.items {
                    DemoDirector.note("card   \(item.text) column=\(item.column) done=\(item.done) agent=\(item.agent != nil)")
                }
            }
        case "menubar":
            let menu = NSMenu()
            MenuBarStatus.shared.menuNeedsUpdate(menu)
            let titles = menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
            DemoDirector.note("menubar \(titles.joined(separator: " | "))")
        case "sketch":
            controller.addSketch()
        case "closesketch":
            if let sketch = controller.model.sketches.last { controller.removeSketch(sketch.id) }
        case "sketchtool":
            guard let view = sketch(controller), let tool = SketchCanvasView.Tool(rawValue: args.first ?? "") else { return }
            view.canvas.tool = tool
        case "sketchdrag", "sketchclick":
            // Points in the drawing's own coordinates.
            guard let view = sketch(controller), let window = controller.window else { return }
            let numbers = args.compactMap { Double($0) }.map { CGFloat($0) }
            guard numbers.count >= 2 else { return }
            let height = window.contentView?.bounds.height ?? 0
            func onWindow(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                let p = view.canvas.convert(CGPoint(x: x, y: y), to: nil)
                return CGPoint(x: p.x, y: height - p.y)
            }
            let start = onWindow(numbers[0], numbers[1])
            if action == "sketchclick" {
                let clicks = numbers.count > 2 ? Int(numbers[2]) : 1
                for count in 1...max(clicks, 1) {
                    mouse(.leftMouseDown, start, in: window, clicks: count)
                    mouse(.leftMouseUp, start, in: window, clicks: count)
                }
            } else if numbers.count >= 4 {
                let end = onWindow(numbers[2], numbers[3])
                drag(from: start, by: CGSize(width: end.x - start.x, height: end.y - start.y), in: controller)
            }
        case "sketchtype":
            guard let responder = controller.window?.firstResponder as? NSTextView else {
                DemoDirector.note("sketch: no label being edited")
                return
            }
            responder.insertText(args.joined(separator: " "), replacementRange: responder.selectedRange())
            if let view = sketch(controller) { controller.window?.makeFirstResponder(view.canvas) }
        case "sketchstate":
            for sketch in controller.model.sketches {
                DemoDirector.note("sketch \(sketch.title) frame=\(controller.model.frames[sketch.id] ?? .zero) items=\(sketch.elements.count)")
                for element in sketch.elements {
                    let ends = element.kind.isConnector ? " ends=\(element.connectorEnds(in: sketch.elements))" : ""
                    let attached = element.kind.isConnector ? " attached=\(element.start != nil)/\(element.end != nil)" : ""
                    DemoDirector.note("sketch   \(element.kind.rawValue) frame=\(element.frame) text=\(element.text ?? "-")\(attached)\(ends)")
                }
            }
        case "sketchexport":
            guard let id = controller.model.sketches.first?.id else { return }
            DemoDirector.note("sketch export -> \(controller.exportSketch(id)?.lastPathComponent ?? "failed")")
        case "sketchundo":
            sketch(controller)?.canvas.undoManager?.undo()
        case "groups":
            let model = controller.model
            for (index, surface) in model.surfaces.enumerated() {
                let project = model.projects[surface.id].map(BoardProjects.name) ?? "-"
                DemoDirector.note("groups tile \(index + 1) project=\(project) color=\(model.color(of: surface.id).map(String.init) ?? "-") frame=\(model.frames[surface.id] ?? .zero)")
            }
            for group in BoardTiles.groups(model) {
                DemoDirector.note("groups group \(BoardProjects.name(group.project)) color=\(group.color) tiles=\(group.tiles.count) frame=\(group.frame)")
            }
        default:
            DemoDirector.note("board: unknown action \(action)")
        }
    }

    // MARK: Events

    private static func zoom(_ controller: BoardController) -> CGFloat { controller.canvas?.magnification ?? 1 }

    /// A tile's rect in window points, from the top-left of the window.
    private static func windowRect(of surface: Ghostty.SurfaceView, in controller: BoardController) -> CGRect? {
        guard let frame = controller.model.frames[surface.id], let document = controller.canvas?.documentView,
              let window = controller.window, let height = window.contentView?.bounds.height else { return nil }
        let rect = document.convert(frame, to: nil)
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// A point over empty board, in window points from the top-left.
    private static func emptyPoint(in controller: BoardController) -> CGPoint? {
        guard let canvas = controller.canvas, let window = controller.window,
              let height = window.contentView?.bounds.height else { return nil }
        let visible = canvas.convert(canvas.bounds, to: nil)
        let tiles = controller.model.surfaces.compactMap { windowRect(of: $0, in: controller) }
        let candidates = stride(from: 0.2, through: 0.8, by: 0.1).flatMap { fx in
            stride(from: 0.3, through: 0.9, by: 0.1).map { fy in
                CGPoint(x: visible.minX + visible.width * fx, y: height - visible.maxY + visible.height * fy)
            }
        }
        return candidates.first { point in !tiles.contains { $0.insetBy(dx: -4, dy: -4).contains(point) } }
    }

    private static func sketch(_ controller: BoardController) -> BoardSketchView? {
        guard let id = controller.model.sketches.last?.id else { return nil }
        return controller.sketchView(id)
    }

    private static func mouse(_ type: NSEvent.EventType, _ point: CGPoint, in window: NSWindow, clicks: Int = 1) {
        let height = window.contentView?.bounds.height ?? window.frame.height
        if type == .leftMouseDown, let hit = window.contentView?.hitTest(NSPoint(x: point.x, y: height - point.y)) {
            DemoDirector.note("board mouse down at \(point) hits \(Swift.type(of: hit))")
        }
        guard let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: point.x, y: height - point.y),
                                             modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1) else { return }
        // Through the app's queue, as a real click arrives (it sets `NSApp.currentEvent`).
        NSApp.postEvent(event, atStart: false)
        // A posted event can wait in the queue until the next one comes: wake it after a click.
        if type == .leftMouseUp, let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                                                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                                subtype: 0, data1: 0, data2: 0) {
            NSApp.postEvent(wake, atStart: false)
        }
    }

    /// Press, move in steps over about a third of a second, release.
    /// A click at a board point, as the mouse would.
    private static func click(board point: CGPoint, in controller: BoardController) {
        guard let window = controller.window, let document = controller.groupsView?.superview else { return }
        let inWindow = document.convert(point, to: nil)
        mouse(.leftMouseDown, CGPoint(x: inWindow.x, y: (window.contentView?.bounds.height ?? 0) - inWindow.y), in: window)
        mouse(.leftMouseUp, CGPoint(x: inWindow.x, y: (window.contentView?.bounds.height ?? 0) - inWindow.y), in: window)
    }

    private static func drag(from start: CGPoint, by delta: CGSize, in controller: BoardController) {
        guard let window = controller.window else { return }
        mouse(.leftMouseDown, start, in: window)
        let steps = 20
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(x: start.x + delta.width * t, y: start.y + delta.height * t)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.016 * Double(step)) {
                mouse(.leftMouseDragged, point, in: window)
                if step == steps {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { mouse(.leftMouseUp, point, in: window) }
                }
            }
        }
    }

    private static func scroll(_ dy: Double, at point: CGPoint, in window: NSWindow, command: Bool) {
        let height = window.contentView?.bounds.height ?? window.frame.height
        let inWindow = NSPoint(x: point.x, y: height - point.y)
        let onScreen = window.convertPoint(toScreen: inWindow)
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(dy), wheel2: 0, wheel3: 0)
        else { return }
        cg.location = CGPoint(x: onScreen.x, y: screenHeight - onScreen.y)
        if command { cg.flags = .maskCommand }
        guard let event = NSEvent(cgEvent: cg) else { return }
        NSApp.postEvent(event, atStart: false)
    }

    private static let keyCodes: [String: UInt16] = [
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
        "=": 24, "-": 27, "t": 17, "w": 13, "n": 45, "d": 2, "z": 6, "\\": 42,
        "e": 14, "p": 35, "s": 1, "b": 11, "v": 9, "m": 46, "a": 0, "escape": 53, "return": 36,
    ]

    /// A key with modifiers, sent through the app as a real key press.
    private static func keys(_ combo: String) {
        let parts = combo.lowercased().split(separator: "+").map(String.init)
        guard let key = parts.last, let code = keyCodes[key], let window = NSApp.keyWindow else {
            DemoDirector.note("board: can't press \(combo)")
            return
        }
        let text = key == "escape" ? "\u{1b}" : key == "return" ? "\r" : key
        var flags: NSEvent.ModifierFlags = []
        for mod in parts.dropLast() {
            switch mod {
            case "cmd": flags.insert(.command)
            case "opt": flags.insert(.option)
            case "ctrl": flags.insert(.control)
            case "shift": flags.insert(.shift)
            default: break
            }
        }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil,
                                               characters: text, charactersIgnoringModifiers: text,
                                               isARepeat: false, keyCode: code) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }

    private static func openTool(_ name: String, on controller: BoardController) {
        let surface = controller.focusedSurface
        switch name {
        case "editor": EditorPanel.shared.toggle(from: controller)
        case "visualfix": VisualFixPanel.shared.toggle(controller)
        case "history": CommandBlocksPanel.shared.toggle(controller)
        case "palette": controller.toggleCommandPalette(nil)
        case "mission": MissionControl.toggle()
        case "race": AgentRaces.showSetup(from: controller)
        case "handoff": if let surface { AgentHandoff.showWindow(from: surface, in: controller) }
        case "loop": if let surface { PipelineSetup.show(writer: surface, in: controller) }
        case "localhost": LocalhostManager.toggle()
        case "review": ReviewInbox.toggle()
        case "activity": ActivityDashboard.toggle()
        case "memory": MemoryWindow.showForFrontTab()
        default: DemoDirector.note("board: unknown tool \(name)")
        }
    }

    private static func tools(_ controller: BoardController) {
        let tiles = controller.model.surfaces
        let agents = tiles.filter { VerticalTabsAgents.shared.info(for: $0) != nil }
        let found = tiles.allSatisfy { (NSApp.delegate as? AppDelegate)?.findSurface(forUUID: $0.id) === $0 }
        let jumps = TerminalWindows.surfaces.filter { $0.controller === controller }.count
        let others = agents.first.map { AgentHandoff.runningAgents(excluding: $0).count } ?? 0
        let titles = tiles.map { TerminalWindows.title(of: $0, in: controller) ?? "-" }
        let windows = NSApp.windows.filter(\.isVisible).map { "\"\($0.title)\"" }
        let hermes = tiles.filter { HermesSessions.shared.isHermes(surface: $0) }.count
        let panels: [String] = [
            "editor=\(EditorPanel.shared.isVisible(controller))",
            "visualfix=\(VisualFixPanel.shared.isVisible(controller))",
            "history=\(CommandBlocksPanel.shared.isVisible(controller))",
            "palette=\(controller.commandPaletteIsShowing)",
        ]
        let reach: [String] = [
            "front=\(TerminalWindows.front === controller)",
            "findSurface=\(found)",
            "surfaces=\(jumps)/\(tiles.count)",
            "handoffTargets=\(others)",
            "waiting=\(PaletteExtras.waitingOptions().count)",
            "hermes=\(hermes)",
            "localhost=\(LocalhostSessions.shared.sessions.count)",
            "busy=\(ExtremeUpdates.workingAgents())",
        ]
        DemoDirector.note("tools " + (panels + reach).joined(separator: " "))
        DemoDirector.note("tools titles=\(titles) windows=\(windows)")
    }

    // MARK: Reports

    private static func state() {
        var lines: [String] = []
        for window in NSApp.windows where window.isVisible {
            lines.append("window \(type(of: window)) controller=\(window.windowController.map { "\(type(of: $0))" } ?? "-") "
                         + "title=\"\(window.title)\" frame=\(window.frame) key=\(window.isKeyWindow) "
                         + "tabs=\(window.tabGroup?.windows.count ?? 1)")
        }
        for controller in TerminalController.all {
            let grids = controller.surfaceTree.map { $0.surfaceSize.map { "\($0.columns)x\($0.rows)" } ?? "-" }
            lines.append("classic \"\(controller.window?.title ?? "")\" frame=\(controller.window?.frame ?? .zero) grids=\(grids)")
        }
        lines.append("edition \(ExtremeEdition.current.rawValue) boards=\(BoardController.all.count) "
                     + "classic=\(TerminalController.all.count) saved=\(BoardStore.all().count)")
        for controller in BoardController.all {
            lines.append("board \"\(controller.workspace.name)\" zoom=\(String(format: "%.3f", zoom(controller))) "
                         + "origin=\(controller.cameraOrigin) tiles=\(controller.model.surfaces.count) "
                         + "focused=\(controller.focusedSurface.flatMap { f in controller.model.surfaces.firstIndex { $0 === f }.map { $0 + 1 } } ?? 0) "
                         + "sidebar=\(controller.model.showSidebar)")
            for (index, surface) in controller.model.surfaces.enumerated() {
                let info = VerticalTabsAgents.shared.info(for: surface)
                let frame = controller.model.frames[surface.id] ?? .zero
                lines.append("  tile \(index + 1) frame=\(frame) visible=\(controller.visible[surface.id].map { "\($0)" } ?? "-") "
                             + "grid=\(surface.surfaceSize.map { "\($0.columns)x\($0.rows)" } ?? "-") "
                             + "agent=\(info.map { "\($0.kind.rawValue)/\($0.activity.label)" } ?? "-") "
                             + "session=\(info.flatMap(ResumeAfterUpdate.session(for:)) ?? "-") title=\"\(surface.title)\"")
            }
        }
        for line in lines { DemoDirector.note(line) }
    }

    private static func snapshot(_ controller: BoardController, to path: String) {
        // An open sheet (the composer) instead of the board under it.
        guard let window = controller.window.map({ $0.attachedSheet ?? $0 }), let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        var lines: [String] = ["zoom \(zoom(controller)) origin \(controller.cameraOrigin)"]
        for (index, surface) in controller.model.surfaces.enumerated() {
            lines.append("tile \(index + 1) \(controller.model.frames[surface.id].map { "\($0)" } ?? "-") pwd \(surface.pwd ?? "-")")
        }
        func walk(_ view: NSView, _ depth: Int) {
            guard depth < 9 else { return }
            lines.append(String(repeating: "  ", count: depth) + "\(type(of: view)) \(view.frame) hidden=\(view.isHidden)")
            for sub in view.subviews { walk(sub, depth + 1) }
        }
        walk(view, 0)
        try? lines.joined(separator: "\n").write(toFile: path + ".txt", atomically: true, encoding: .utf8)
    }
}
#endif
