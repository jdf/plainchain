import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: Model

    var body: some View {
        VStack(spacing: 12) {
            Header()
            EndpointView(title: "Input", kind: .input)
            ChainView()
            EndpointView(title: "Output", kind: .output)
            StatusBar()
        }
        .padding()
    }
}

// MARK: - Input / Output

enum EndpointKind { case input, output }

struct EndpointView: View {
    @EnvironmentObject private var model: Model
    let title: String
    let kind: EndpointKind

    private var devices: [Device] { kind == .input ? model.inputDevices : model.outputDevices }
    private var endpoint: Endpoint { kind == .input ? model.session.input : model.session.output }
    private var device: Device? { model.device(uid: endpoint.deviceUid) }
    private var channelCount: Int { Int(kind == .input ? device?.inputChannels ?? 0 : device?.outputChannels ?? 0) }

    private func set(_ mutate: (inout Endpoint) -> Void) {
        model.update { cfg in
            if kind == .input { mutate(&cfg.input) } else { mutate(&cfg.output) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            VStack(alignment: .leading, spacing: 8) {
                Picker("Device", selection: Binding(
                    get: { endpoint.deviceUid },
                    set: { uid in
                        let n = kind == .input ? model.device(uid: uid)?.inputChannels : model.device(uid: uid)?.outputChannels
                        set { $0.deviceUid = uid; $0.channels = Array(0..<min(n ?? 0, 2)) }
                    }
                )) {
                    if device == nil, !endpoint.deviceUid.isEmpty {
                        Text("(disconnected)").tag(endpoint.deviceUid)
                    }
                    ForEach(devices) { d in
                        Text("\(d.name)  ·  \(Int(d.sampleRate)) Hz").tag(d.uid)
                    }
                }
                .labelsHidden()

                if channelCount > 0 {
                    ChannelGrid(count: channelCount, selected: endpoint.channels) { ch, on in
                        set { ep in
                            if on { ep.channels.append(ch); ep.channels.sort() } else { ep.channels.removeAll { $0 == ch } }
                        }
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
        }
    }
}

/// Numbered toggle buttons, one per device channel.
struct ChannelGrid: View {
    let count: Int
    let selected: [UInt32]
    let toggle: (UInt32, Bool) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 36), spacing: 4)], alignment: .leading, spacing: 4) {
            ForEach(0..<count, id: \.self) { i in
                let ch = UInt32(i)
                let on = selected.contains(ch)
                Button("\(i + 1)") { toggle(ch, !on) }
                    .buttonStyle(ChannelButtonStyle(on: on))
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

/// Explicit colors, so a selected channel stays visibly selected when the
/// window is not key (the system's prominent style goes gray then).
struct ChannelButtonStyle: ButtonStyle {
    let on: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.monospacedDigit())
            .frame(minWidth: 36, minHeight: 22)
            .foregroundStyle(on ? .white : .primary)
            .background(on ? Color.accentColor : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(on ? Color.accentColor : Color(nsColor: .separatorColor)))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}

// MARK: - Chain

struct ChainView: View {
    @EnvironmentObject private var model: Model
    @State private var showingPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Plugins")
                Spacer()
                Button {
                    showingPicker.toggle()
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .popover(isPresented: $showingPicker, arrowEdge: .bottom) {
                    PluginPicker { model.add($0); showingPicker = false }
                        .onAppear { model.refreshPlugins() }
                }
            }
            ScrollView {
                ChainList(addAction: { showingPicker = true })
                    .padding(6)
            }
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
            .frame(minHeight: 160, maxHeight: .infinity)
        }
    }
}

/// The slots, with handle-only drag reordering. Rows have a fixed pitch so the
/// drop target is just arithmetic on the drag distance.
struct ChainList: View {
    @EnvironmentObject private var model: Model
    let addAction: () -> Void

    static let rowHeight: CGFloat = 44
    static let rowSpacing: CGFloat = 6
    private var pitch: CGFloat { Self.rowHeight + Self.rowSpacing }

    @State private var dragIndex: Int?
    @State private var dragOffset: CGFloat = 0

    /// Where the dragged row would land.
    private var target: Int? {
        guard let d = dragIndex else { return nil }
        let count = model.session.chain.count
        return min(max(d + Int((dragOffset / pitch).rounded()), 0), count - 1)
    }

    private func offset(for i: Int) -> CGFloat {
        guard let d = dragIndex, let t = target else { return 0 }
        if i == d { return dragOffset }
        if d < t, i > d, i <= t { return -pitch }
        if d > t, i >= t, i < d { return pitch }
        return 0
    }

    var body: some View {
        VStack(spacing: Self.rowSpacing) {
            ForEach(Array(model.session.chain.enumerated()), id: \.element.id) { index, item in
                ChainRow(index: index, item: item, handle: handleGesture(index))
                    .slot()
                    .offset(y: offset(for: index))
                    .zIndex(dragIndex == index ? 1 : 0)
                    .shadow(color: .black.opacity(dragIndex == index ? 0.25 : 0), radius: 6, y: 2)
                    .animation(.easeOut(duration: 0.15), value: dragIndex == index ? 0 : offset(for: index))
            }
            EmptySlot(action: addAction)
                .slot(empty: true)
        }
    }

    private func handleGesture(_ index: Int) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("chain"))
            .onChanged { g in
                if dragIndex == nil { dragIndex = index }
                dragOffset = g.translation.height
            }
            .onEnded { _ in
                if let d = dragIndex, let t = target, t != d {
                    model.move(from: IndexSet(integer: d), to: t > d ? t + 1 : t)
                }
                dragIndex = nil
                dragOffset = 0
            }
    }
}

/// The next place a plugin will go.
struct EmptySlot: View {
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle.dashed").foregroundStyle(.tertiary)
            Text("Empty slot").foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .help("Add a plugin here")
    }
}

private extension View {
    /// Rack-slot framing for a chain row: a raised card inside the chain area.
    func slot(empty: Bool = false) -> some View {
        self
            .padding(.horizontal, 10)
            .frame(height: ChainList.rowHeight)
            .background(empty ? Color.clear : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(nsColor: .separatorColor), style: StrokeStyle(lineWidth: 1, dash: empty ? [4, 3] : []))
            )
    }
}

struct ChainRow<Handle: Gesture>: View {
    @EnvironmentObject private var model: Model
    @EnvironmentObject private var levels: Levels
    let index: Int
    let item: ChainItem
    let handle: Handle

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .frame(width: 20, height: ChainList.rowHeight)
                .contentShape(Rectangle())
                .gesture(handle)
                .onHover { inside in inside ? NSCursor.openHand.push() : NSCursor.pop() }
                .help("Drag to reorder")
            Knob(value: Binding(
                get: { item.inputGainDb },
                set: { v in model.update { $0.chain[index].inputGainDb = v } }
            ))
            MeterView(peaks: levels.peaks[item.id] ?? Array(repeating: 0, count: max(model.session.input.channels.count, 1)))
            PowerButton(on: !item.bypass) { model.update { $0.chain[index].bypass.toggle() } }
            VStack(alignment: .leading) {
                Text(model.name(of: item.plugin))
                Text(model.plugin(item.plugin)?.manufacturer ?? item.plugin.manufacturer)
                    .font(.caption).foregroundStyle(.secondary)
            }
            .opacity(item.bypass ? 0.5 : 1)
            Spacer(minLength: 8)
            if let gr = levels.reduction[item.id] {
                ReductionView(db: gr)
            }
            if model.isEditorOpen(item.id) {
                Image(systemName: "macwindow").foregroundStyle(Color.accentColor).help("Editor is open")
            }
            Button {
                model.remove(at: [index])
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove plugin")
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { model.openEditor(item) }
        .help("Click to open the editor")
    }
}

/// Power control: green when on, gray when off.
struct PowerButton: View {
    let on: Bool
    var size: CGFloat = 20
    var help: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "power")
                .font(.system(size: size * 0.55, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(on ? Color.green : Color(nsColor: .tertiaryLabelColor), in: Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .focusEffectDisabled()
        .help(help ?? (on ? "On (click to bypass)" : "Bypassed (click to enable)"))
    }
}

/// Engine power and what it is running on.
struct Header: View {
    @EnvironmentObject private var model: Model

    var body: some View {
        HStack(spacing: 10) {
            PowerButton(on: model.enabled, size: 28, help: model.enabled ? "Running (click to stop)" : "Stopped (click to start)") {
                model.enabled.toggle()
            }
            Text(model.title).font(.title3)
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .help(error)
            }
            Spacer()
            if model.busy { ProgressView().controlSize(.small) }
        }
    }
}

/// Small rotary trim knob, ±24 dB. Drag up or down; double-click resets to 0.
/// An AppKit view, so its mouse handling does not depend on SwiftUI gesture
/// arbitration against the row's tap and the list's scrolling.
struct Knob: NSViewRepresentable {
    @Binding var value: Float

    func makeNSView(context: Context) -> KnobView {
        let v = KnobView()
        v.onChange = { value = $0 }
        return v
    }

    func updateNSView(_ v: KnobView, context: Context) {
        v.onChange = { value = $0 }
        if v.value != value { v.value = value }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: KnobView, context: Context) -> CGSize? { CGSize(width: 22, height: 22) }
}

final class KnobView: NSView {
    var value: Float = 0 { didSet { needsDisplay = true; toolTip = String(format: "Input trim %+.1f dB (drag; double-click resets)", value) } }
    var onChange: ((Float) -> Void)?
    private let range: ClosedRange<Float> = -24...24
    private var dragStart: Float = 0
    private var dragY: CGFloat = 0

    override var intrinsicContentSize: NSSize { NSSize(width: 22, height: 22) }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { set(0); return }
        dragStart = value
        dragY = convert(event.locationInWindow, from: nil).y
    }

    override func mouseDragged(with event: NSEvent) {
        let dy = convert(event.locationInWindow, from: nil).y - dragY
        set(dragStart + Float(dy) * 0.25)
    }

    override func scrollWheel(with event: NSEvent) {
        set(value - Float(event.scrollingDeltaY) * 0.1)
    }

    private func set(_ raw: Float) {
        let v = min(max((raw * 2).rounded() / 2, range.lowerBound), range.upperBound)
        guard v != value else { return }
        value = v
        onChange?(v)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(ovalIn: r).fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(ovalIn: r).stroke()
        // Indicator: −135° at minimum, +135° at maximum, straight up at the midpoint.
        let t = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
        let angle = (CGFloat.pi / 2) - (-0.75 * .pi + 1.5 * .pi * t)
        let c = NSPoint(x: r.midX, y: r.midY)
        let inner = r.width * 0.2, outer = r.width * 0.42
        let p = NSBezierPath()
        p.move(to: NSPoint(x: c.x + inner * cos(angle), y: c.y + inner * sin(angle)))
        p.line(to: NSPoint(x: c.x + outer * cos(angle), y: c.y + outer * sin(angle)))
        p.lineWidth = 2
        p.lineCapStyle = .round
        NSColor.labelColor.setStroke()
        p.stroke()
    }
}

/// Vertical peak meter, one bar per channel: green to −12 dB, yellow to −3, red above.
struct MeterView: View {
    let peaks: [Float]

    private func fraction(_ db: Float) -> CGFloat { CGFloat(min(max((db + 60) / 60, 0), 1)) }

    var body: some View {
        let bars = max(peaks.count, 1)
        Canvas { ctx, size in
            let barW = (size.width - CGFloat(bars - 1)) / CGFloat(bars)
            for c in 0..<bars {
                let x = CGFloat(c) * (barW + 1)
                ctx.fill(Path(CGRect(x: x, y: 0, width: barW, height: size.height)), with: .color(Color(nsColor: .quaternaryLabelColor)))
                let p = c < peaks.count ? peaks[c] : 0
                let db = p > 0 ? 20 * log10f(p) : -200
                let level = fraction(db)
                let bands: [(CGFloat, CGFloat, Color)] = [(0, fraction(-12), .green), (fraction(-12), fraction(-3), .yellow), (fraction(-3), 1, .red)]
                for (lo, hi, color) in bands where level > lo {
                    let top = min(level, hi)
                    let rect = CGRect(x: x, y: size.height * (1 - top), width: barW, height: size.height * (top - lo))
                    ctx.fill(Path(rect), with: .color(color))
                }
            }
        }
        .frame(width: CGFloat(bars * 4 + (bars - 1)), height: 22)
        .help("Input level")
    }
}

/// Gain reduction, filling from the right: 0 to −20 dB.
struct ReductionView: View {
    let db: Float

    var body: some View {
        HStack(spacing: 4) {
            Text(String(format: "%.1f", db)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(nsColor: .quaternaryLabelColor)))
                let w = size.width * CGFloat(min(max(-db, 0), 20) / 20)
                ctx.fill(Path(CGRect(x: size.width - w, y: 0, width: w, height: size.height)), with: .color(.orange))
            }
            .frame(width: 60, height: 8)
        }
        .help("Gain reduction")
    }
}

/// Searchable list of installed Audio Units, grouped by manufacturer.
struct PluginPicker: View {
    @EnvironmentObject private var model: Model
    @State private var query = ""
    let choose: (Plugin) -> Void

    private var filtered: [Plugin] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.plugins }
        return model.plugins.filter { $0.name.lowercased().contains(q) || $0.manufacturer.lowercased().contains(q) }
    }

    private var grouped: [(String, [Plugin])] {
        Dictionary(grouping: filtered, by: \.manufacturer)
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search plugins", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            List {
                ForEach(grouped, id: \.0) { manufacturer, plugins in
                    Section(manufacturer) {
                        ForEach(plugins) { p in
                            Button(p.name) { choose(p) }
                                .buttonStyle(.plain)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .frame(width: 320, height: 420)
    }
}

// MARK: - Status

/// Sample rate, buffer, and latency of the running graph.
struct StatusBar: View {
    @EnvironmentObject private var model: Model

    private static let hz: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 0; return f
    }()

    var body: some View {
        let s = model.status
        HStack(spacing: 16) {
            stat("Sample rate", "\(Self.hz.string(from: s.sampleRate as NSNumber) ?? "0") Hz")
            VStack(alignment: .leading, spacing: 1) {
                Text("Buffer").foregroundStyle(.tertiary)
                HStack(spacing: 4) {
                    Picker("", selection: Binding(get: { s.bufferFrames }, set: { model.setBufferSize($0) })) {
                        ForEach(model.bufferSizeChoices, id: \.self) { Text("\($0)").tag($0) }
                        if !model.bufferSizeChoices.contains(s.bufferFrames) { Text("\(s.bufferFrames)").tag(s.bufferFrames) }
                    }
                    .labelsHidden()
                    .controlSize(.mini)
                    .fixedSize()
                    .disabled(!s.running)
                    Text(String(format: "samples · %.1f ms", s.bufferMs))
                }
            }
            .help("Device IO buffer. Smaller is lower latency but more CPU; this setting is shared with other apps using the device.")
            stat("Latency", String(format: "≈ %.1f ms round trip", s.ms(s.roundTripFrames)))
                .help(String(format: "Input buffer %.1f + device in %.1f + plugins %.1f + device out %.1f + output buffer %.1f ms",
                             s.bufferMs, s.ms(s.inputLatencyFrames), s.ms(s.pluginLatencyFrames), s.ms(s.outputLatencyFrames), s.bufferMs))
            stat("Plugins", String(format: "%.1f ms", s.ms(s.pluginLatencyFrames)))
            if s.renderErrors > 0 {
                stat("Input errors", "\(s.renderErrors)").foregroundStyle(.red)
            }
            Spacer()
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(s.running ? .primary : .tertiary)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).foregroundStyle(.tertiary)
            Text(value)
        }
    }
}
