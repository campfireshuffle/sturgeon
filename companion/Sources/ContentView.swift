import SwiftUI

struct ContentView: View {
    @ObservedObject var model: PilotModel

    private var pct: String { "\(Int((model.scale * 100).rounded()))%" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            statusGrid
            if let refusal = model.doctorRefusal, model.doctorOK == false {
                Text(refusal)
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(refusal)
            }
            Divider()
            controls
            Divider()
            actions
            if model.setupNeeded {
                setupBanner
            }
            if model.axNeeded {
                axBanner
            }
            footer
        }
        .padding(13)
        .frame(width: 392)
    }

    // MARK: - header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.3.group.fill")
                .font(.system(size: 15))
                .foregroundColor(.secondary)
            Text("Sturgeon")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(model.armed ? "ARMED" : "DISARMED")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(model.armed ? .white : .secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(
                    Capsule().fill(model.armed ? Color.green : Color.secondary.opacity(0.18))
                )
                .accessibilityIdentifier("stateBadge")
        }
    }

    // MARK: - status

    private var statusGrid: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("WindowManager",
                value: "\(model.build)  ·  pid \(model.pid.map(String.init) ?? "—")",
                color: .primary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Doctor")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(width: 92, alignment: .leading)
                Circle()
                    .fill(doctorColor)
                    .frame(width: 7, height: 7)
                Text(model.doctorLine)
                    .font(.system(size: 11))
                    .foregroundColor(doctorColor)
                    .accessibilityIdentifier("doctorVerdict")
            }
            row("Payload",
                value: model.armed
                    ? "\(model.sitesPatched)/\(model.sitesTotal) sites patched"
                    : (model.reason ?? "not installed"),
                color: model.armed ? .primary : .secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Debugger")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(width: 92, alignment: .leading)
                Text(model.debugger)
                    .font(.system(size: 11))
                    .foregroundColor(model.debugger == "none" ? .primary : .red)
                    .accessibilityIdentifier("debuggerValue")
            }
        }
    }

    private func row(_ label: String, value: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .foregroundColor(color)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(value)
        }
    }

    private var doctorColor: Color {
        switch model.doctorOK {
        case .some(true): return .green
        case .some(false): return .orange
        case .none: return .secondary
        }
    }

    // MARK: - payload controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { model.births }, set: { model.setBirths($0) })) {
                Text("New windows join the current stage").font(.system(size: 12))
            }
            .toggleStyle(.checkbox)
            .disabled(!model.armed || model.busy)
            .accessibilityIdentifier("birthsToggle")

            Toggle(isOn: Binding(get: { model.onTop }, set: { model.setOnTop($0) })) {
                Text("Keep the strip visible on top").font(.system(size: 12))
            }
            .toggleStyle(.checkbox)
            .disabled(!model.armed || model.busy)
            .accessibilityIdentifier("onTopToggle")

            Toggle(isOn: Binding(get: { model.level3 }, set: { model.setLevel3($0) })) {
                Text("Raise strip tiles to level 3").font(.system(size: 12))
            }
            .toggleStyle(.checkbox)
            .disabled(!model.armed || model.busy)
            .accessibilityIdentifier("levelToggle")

            HStack(spacing: 8) {
                Text("Strip size")
                    .font(.system(size: 12))
                    .frame(width: 92, alignment: .leading)
                Slider(value: Binding(get: { model.scale },
                                      set: { model.sliderChanged($0) }),
                       in: 0.4...1.5,
                       step: 0.01,
                       onEditingChanged: { editing in
                           model.isEditingScale = editing
                           if !editing { model.applyScale(model.scale) }
                       })
                .disabled(!model.armed || model.busy)
                .accessibilityIdentifier("scaleSlider")
                Text(pct)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(.secondary)
                    .frame(width: 38, alignment: .trailing)
                    .accessibilityIdentifier("scaleReadout")
            }
            HStack {
                Button("Reset to 100%") { model.resetScale() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                    .disabled(!model.armed || model.busy)
                    .accessibilityIdentifier("resetButton")
                Spacer()
            }
        }
    }

    // MARK: - actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Menu {
                if model.stages.isEmpty {
                    Text("no stages (Accessibility permission?)")
                }
                ForEach(model.stages) { stage in
                    Button(stage.label) { model.move(to: stage) }
                        .disabled(!stage.addressable)
                }
            } label: {
                Label("Move front window to…", systemImage: "arrow.right.square")
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .disabled(!model.armed || model.stages.isEmpty || model.busy)
            .accessibilityIdentifier("moveMenu")

            HStack(spacing: 8) {
                Button("Start") { model.start() }
                    .disabled(model.armed || model.busy)
                    .accessibilityIdentifier("startButton")
                Button("Stop") { model.stop() }
                    .disabled(!model.armed || model.busy)
                    .accessibilityIdentifier("stopButton")
                Button("Doctor") { model.runDoctor() }
                    .disabled(model.busy)
                    .accessibilityIdentifier("doctorButton")
                Spacer()
                if model.busy {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    private var setupBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.shield")
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Not set up").font(.system(size: 11, weight: .semibold))
                Text("Sturgeon needs one administrator approval to grant root to the bundled tool.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Set Up…") { model.setup() }
                .disabled(model.busy)
                .accessibilityIdentifier("setupButton")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.10)))
    }

    private var axBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "hand.raised")
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Stage names need Accessibility").font(.system(size: 11, weight: .semibold))
                Text("Grant Sturgeon Accessibility to list stages and use Move.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("Open…") { model.openAccessibilitySettings() }
                .accessibilityIdentifier("axButton")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text(model.footer)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(model.footer)
                .accessibilityIdentifier("footerLine")
            Spacer(minLength: 4)
            Button("Quit") { model.quit() }
                .buttonStyle(.link)
                .font(.system(size: 10))
                .accessibilityIdentifier("quitButton")
        }
    }
}
