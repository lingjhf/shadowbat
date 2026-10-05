import SwiftUI

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
