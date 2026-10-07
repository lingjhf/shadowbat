import SwiftUI
import AppKit
import Combine

struct TrayPanelView: View {
    @ObservedObject var model: ConnectionViewModel
    let openMainWindow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Shadowbat").font(.headline)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.state.label).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            proxySwitch("代理服务", symbol: "power", binding: Binding(
                get: { model.serviceEnabled }, set: { model.setServiceEnabled($0) }
            ))
            .disabled(model.state == .stopping || model.systemProxyBusy ||
                      (!model.serviceEnabled && !model.canConnect))
            proxySwitch("系统代理", symbol: "globe", binding: Binding(
                get: { model.systemProxySwitch }, set: { model.setSystemProxy($0) }
            )).disabled(model.busy)
            proxySwitch("终端代理", symbol: "terminal", binding: Binding(
                get: { model.useTerminalProxy }, set: { model.setTerminalProxy($0) }
            )).disabled(model.busy)
            proxySwitch("TUN 隧道", symbol: "lock.shield", binding: Binding(
                get: { model.useTun }, set: { value in
                    do { try model.setTun(value) } catch { model.errorMessage = error.localizedDescription }
                }
            )).disabled(!model.canChangeSelection)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Picker("节点选择", selection: Binding(
                    get: { model.selectionMode }, set: { model.setSelectionMode($0) }
                )) {
                    ForEach(NodeSelectionMode.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: .infinity)
                    .disabled(!model.canChangeSelection)
                if model.selectionMode == .manual {
                    Picker("固定节点", selection: Binding(
                        get: { model.manualID }, set: { model.setManualNode($0) }
                    )) {
                        Text("请选择节点").tag(nil as UUID?)
                        ForEach(model.profiles) { Text($0.name).tag(Optional($0.id)) }
                    }.disabled(!model.canChangeSelection)
                } else {
                    Text(model.connectionDescription).font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.recoveryNeeded {
                Button("恢复系统代理", systemImage: "exclamationmark.triangle") { model.recoverSystemProxy() }
                    .disabled(model.busy)
            }
            Divider()
            HStack {
                Button("打开 Shadowbat", systemImage: "macwindow") { openMainWindow() }
                Spacer()
                Button("退出") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }.buttonStyle(.borderless)
        }
        .padding(20)
        .frame(width: 300)
    }

    private func proxySwitch(_ title: String, symbol: String, binding: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
            Text(title).font(.callout)
            Spacer()
            Toggle(title, isOn: binding).labelsHidden().toggleStyle(.switch)
                .accessibilityLabel(title)
        }
    }
}

/// A native, arrowless status-item panel with the same SwiftUI tray content.
@MainActor
final class NativeTrayPanel {
    let contentViewController: NSHostingController<TrayPanelView>
    private let window = TrayPanelWindow(contentRect: .zero, styleMask: .borderless,
                                         backing: .buffered, defer: false)
    private weak var anchorButton: NSStatusBarButton?
    private var observation: AnyCancellable?
    private var layoutScheduled = false
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var menuTracking = false

    var isShown: Bool { window.isVisible }
    var contentSize: NSSize { contentViewController.view.frame.size }

    init(content: TrayPanelView) {
        contentViewController = NSHostingController(rootView: content)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.hidesOnDeactivate = true
        window.level = .popUpMenu
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.dismiss = { [weak self] in self?.close() }
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        let view = contentViewController.view
        view.autoresizingMask = [.width, .height]
        background.addSubview(view)
        window.contentView = background
        observation = content.model.objectWillChange.sink { [weak self] in
            guard let self, self.isShown, !self.layoutScheduled else { return }
            self.layoutScheduled = true
            // objectWillChange precedes the SwiftUI layout update.
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(33)) { [weak self] in
                guard let self else { return }
                self.layoutScheduled = false
                if self.isShown { self.refreshLayout() }
            }
        }
    }

    func showBelowStatusItem(_ button: NSStatusBarButton) {
        guard button.window != nil else { return }
        close()
        anchorButton = button
        refreshLayout()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(contentViewController.view)
        installDismissalHandlers()
    }

    func refreshLayout() {
        guard let button = anchorButton, let anchorWindow = button.window else { return }
        let content = contentViewController.view
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        let anchor = anchorWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = anchorWindow.screen?.visibleFrame ?? anchor
        let width = min(size.width, screen.width - 16)
        let height = min(size.height, screen.height - 16)
        let x = min(max(anchor.midX - width / 2, screen.minX + 8), screen.maxX - width - 8)
        let top = min(anchor.minY - 6, screen.maxY)
        let y = max(top - height, screen.minY + 8)
        window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        content.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
    }

    func close() {
        window.orderOut(nil)
        if let monitor = localMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = globalMonitor { NSEvent.removeMonitor(monitor) }
        localMonitor = nil
        globalMonitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        anchorButton = nil
        menuTracking = false
    }

    private func installDismissalHandlers() {
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            guard let self else { return event }
            // Picker menus can extend outside the panel; leave their tracking intact.
            if !self.menuTracking && event.window !== self.window && event.window !== self.anchorButton?.window {
                self.close()
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in self?.close() }
        observe(NSApplication.didResignActiveNotification, object: NSApp) { [weak self] in self?.close() }
        observe(NSMenu.didBeginTrackingNotification) { [weak self] in self?.menuTracking = true }
        observe(NSMenu.didEndTrackingNotification) { [weak self] in self?.menuTracking = false }
        observe(NSApplication.didChangeScreenParametersNotification) { [weak self] in self?.refreshLayout() }
        if let anchorWindow = anchorButton?.window {
            observe(NSWindow.didMoveNotification, object: anchorWindow) { [weak self] in self?.refreshLayout() }
            observe(NSWindow.didResizeNotification, object: anchorWindow) { [weak self] in self?.refreshLayout() }
        }
    }

    private func observe(_ name: Notification.Name, object: AnyObject? = nil, action: @escaping () -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { _ in action() })
    }
}

@MainActor
private final class TrayPanelWindow: NSPanel {
    var dismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { dismiss?() }
}
