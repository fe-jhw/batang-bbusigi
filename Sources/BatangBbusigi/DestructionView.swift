import AppKit

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }

    mutating func unit() -> CGFloat {
        CGFloat(Double(next()) / Double(UInt64.max))
    }

    mutating func range(_ limits: ClosedRange<CGFloat>) -> CGFloat {
        limits.lowerBound + unit() * (limits.upperBound - limits.lowerBound)
    }
}

private struct DamageMark {
    enum Kind {
        case hammer
        case bullet
        case scorch
        case explosion
        case lightning
    }

    let kind: Kind
    let point: CGPoint
    let radius: CGFloat
    let rotation: CGFloat
    let seed: UInt64
}

private struct PendingBomb {
    let point: CGPoint
    var life: CGFloat
    let maximumLife: CGFloat
    let seed: UInt64
}

private struct Particle {
    enum Kind {
        case shard
        case spark
        case smoke
        case flame
    }

    let kind: Kind
    var position: CGPoint
    var velocity: CGVector
    var life: CGFloat
    let maximumLife: CGFloat
    let size: CGFloat
    let rotation: CGFloat
}

private struct ImpactPulse {
    let point: CGPoint
    var life: CGFloat
    let maximumLife: CGFloat
    let radius: CGFloat
    let color: NSColor
}

@MainActor
final class DestructionView: NSView {
    var selectedTool: DestructionTool = .hammer {
        didSet {
            stopContinuousAction()
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }

    private let soundEngine: SoundEngine
    private var damageImage: NSImage
    private var particles: [Particle] = []
    private var pulses: [ImpactPulse] = []
    private var bombs: [PendingBomb] = []
    private var animationTimer: Timer?
    private var actionTimer: Timer?
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var pointer = CGPoint.zero
    private var pointerIsVisible = false
    private var isPressed = false
    private var lastHammerPoint: CGPoint?
    private var lastSawPoint: CGPoint?
    private var lastFlameSoundTime: TimeInterval = 0
    private var lastSawSoundTime: TimeInterval = 0
    private var screenFlashAlpha: CGFloat = 0
    private var screenFlashColor = NSColor.white

    init(frame frameRect: NSRect, soundEngine: SoundEngine) {
        self.soundEngine = soundEngine
        damageImage = NSImage(size: frameRect.size)
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        let timer = Timer(timeInterval: 1.0 / 60.0, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        animationTimer?.invalidate()
        actionTimer?.invalidate()
    }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: selectedTool.cursor)
    }

    override func mouseEntered(with event: NSEvent) {
        pointerIsVisible = true
        updatePointer(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        pointerIsVisible = false
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        pointerIsVisible = true
        updatePointer(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        isPressed = true
        updatePointer(with: event)

        switch selectedTool {
        case .hammer:
            smash(at: pointer)
            lastHammerPoint = pointer
        case .machineGun:
            fireBullet(at: pointer)
            startContinuousAction(interval: 0.062) { [weak self] in
                guard let self, self.isPressed else { return }
                self.fireBullet(at: self.pointer)
            }
        case .flamethrower:
            sprayFlame(at: pointer)
            startContinuousAction(interval: 0.028) { [weak self] in
                guard let self, self.isPressed else { return }
                self.sprayFlame(at: self.pointer)
            }
        case .bomb:
            placeBomb(at: pointer)
        case .chainsaw:
            lastSawPoint = pointer
            saw(at: pointer)
            startContinuousAction(interval: 0.032) { [weak self] in
                guard let self, self.isPressed else { return }
                self.saw(at: self.pointer)
            }
        case .lightning:
            strikeLightning(at: pointer)
            startContinuousAction(interval: 0.13) { [weak self] in
                guard let self, self.isPressed else { return }
                self.strikeLightning(at: self.pointer)
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        updatePointer(with: event)
        if selectedTool == .hammer {
            let distance = hypot(pointer.x - (lastHammerPoint?.x ?? pointer.x), pointer.y - (lastHammerPoint?.y ?? pointer.y))
            if distance > 82 {
                smash(at: pointer)
                lastHammerPoint = pointer
            }
        } else if selectedTool == .chainsaw {
            saw(at: pointer)
        }
    }

    override func mouseUp(with event: NSEvent) {
        updatePointer(with: event)
        isPressed = false
        lastHammerPoint = nil
        lastSawPoint = nil
        stopContinuousAction()
    }

    override func rightMouseDown(with event: NSEvent) {
        clearDamage()
    }

    func clearDamage() {
        stopContinuousAction()
        damageImage = NSImage(size: bounds.size)
        particles.removeAll(keepingCapacity: true)
        pulses.removeAll(keepingCapacity: true)
        bombs.removeAll(keepingCapacity: true)
        screenFlashAlpha = 0
        needsDisplay = true
    }

    func stopContinuousAction() {
        isPressed = false
        lastSawPoint = nil
        actionTimer?.invalidate()
        actionTimer = nil
    }

    func renderVerificationDemo() {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        smash(at: CGPoint(x: center.x - 250, y: center.y + 40))
        for index in 0..<16 {
            let angle = CGFloat(index) / 16 * 2 * .pi
            fireBullet(at: CGPoint(
                x: center.x + cos(angle) * 145,
                y: center.y + sin(angle) * 92
            ))
        }
        for index in 0..<14 {
            sprayFlame(at: CGPoint(
                x: center.x + 210 + CGFloat(index) * 8,
                y: center.y - 95 + sin(CGFloat(index) * 0.7) * 28
            ))
        }
        placeBomb(at: CGPoint(x: center.x - 360, y: center.y - 150))
        lastSawPoint = CGPoint(x: center.x - 160, y: center.y - 190)
        for index in 0..<20 {
            saw(at: CGPoint(x: center.x - 160 + CGFloat(index) * 13, y: center.y - 190 + sin(CGFloat(index) * 0.75) * 32))
        }
        strikeLightning(at: CGPoint(x: center.x + 390, y: center.y + 120))
    }

    private func updatePointer(with event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    private func startContinuousAction(interval: TimeInterval, action: @escaping () -> Void) {
        actionTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { _ in action() }
        RunLoop.main.add(timer, forMode: .common)
        actionTimer = timer
    }

    private func smash(at point: CGPoint) {
        let seed = UInt64.random(in: 1...UInt64.max)
        commitDamage(DamageMark(
            kind: .hammer,
            point: point,
            radius: CGFloat.random(in: 48...78),
            rotation: CGFloat.random(in: 0...(2 * .pi)),
            seed: seed
        ))
        pulses.append(ImpactPulse(point: point, life: 0.42, maximumLife: 0.42, radius: 125, color: .white))

        for _ in 0..<34 {
            let angle = CGFloat.random(in: 0...(2 * .pi))
            let speed = CGFloat.random(in: 180...760)
            particles.append(Particle(
                kind: .shard,
                position: point,
                velocity: CGVector(dx: cos(angle) * speed, dy: sin(angle) * speed),
                life: CGFloat.random(in: 0.45...1.15),
                maximumLife: 1.15,
                size: CGFloat.random(in: 4...14),
                rotation: angle
            ))
        }
        soundEngine.playHammer()
        enforceLimits()
    }

    private func fireBullet(at rawPoint: CGPoint) {
        let point = CGPoint(
            x: rawPoint.x + CGFloat.random(in: -4.5...4.5),
            y: rawPoint.y + CGFloat.random(in: -4.5...4.5)
        )
        commitDamage(DamageMark(
            kind: .bullet,
            point: point,
            radius: CGFloat.random(in: 9...14),
            rotation: CGFloat.random(in: 0...(2 * .pi)),
            seed: UInt64.random(in: 1...UInt64.max)
        ))
        pulses.append(ImpactPulse(point: point, life: 0.16, maximumLife: 0.16, radius: 36, color: .systemYellow))

        for _ in 0..<12 {
            let angle = CGFloat.random(in: 0...(2 * .pi))
            let speed = CGFloat.random(in: 130...520)
            particles.append(Particle(
                kind: Bool.random() ? .spark : .smoke,
                position: point,
                velocity: CGVector(dx: cos(angle) * speed, dy: sin(angle) * speed),
                life: CGFloat.random(in: 0.22...0.62),
                maximumLife: 0.62,
                size: CGFloat.random(in: 2...7),
                rotation: angle
            ))
        }
        soundEngine.playGunshot()
        enforceLimits()
    }

    private func sprayFlame(at point: CGPoint) {
        let sootPoint = CGPoint(
            x: point.x + CGFloat.random(in: -24...24),
            y: point.y + CGFloat.random(in: -18...26)
        )
        commitDamage(DamageMark(
            kind: .scorch,
            point: sootPoint,
            radius: CGFloat.random(in: 22...46),
            rotation: CGFloat.random(in: 0...(2 * .pi)),
            seed: UInt64.random(in: 1...UInt64.max)
        ))

        for _ in 0..<9 {
            particles.append(Particle(
                kind: Bool.random() ? .flame : .smoke,
                position: CGPoint(x: point.x + CGFloat.random(in: -10...10), y: point.y + CGFloat.random(in: -8...8)),
                velocity: CGVector(dx: CGFloat.random(in: -105...105), dy: CGFloat.random(in: 110...390)),
                life: CGFloat.random(in: 0.28...0.72),
                maximumLife: 0.72,
                size: CGFloat.random(in: 9...28),
                rotation: CGFloat.random(in: 0...(2 * .pi))
            ))
        }

        let now = ProcessInfo.processInfo.systemUptime
        if now - lastFlameSoundTime > 0.14 {
            soundEngine.playFlameBurst()
            lastFlameSoundTime = now
        }
        enforceLimits()
    }

    private func placeBomb(at point: CGPoint) {
        bombs.append(PendingBomb(
            point: point,
            life: 1.08,
            maximumLife: 1.08,
            seed: UInt64.random(in: 1...UInt64.max)
        ))
        soundEngine.playBombArmed()
        needsDisplay = true
    }

    private func explode(at point: CGPoint, seed: UInt64) {
        commitDamage(DamageMark(
            kind: .explosion,
            point: point,
            radius: CGFloat.random(in: 148...205),
            rotation: CGFloat.random(in: 0...(2 * .pi)),
            seed: seed
        ))

        pulses.append(ImpactPulse(point: point, life: 0.72, maximumLife: 0.72, radius: 360, color: .systemOrange))
        pulses.append(ImpactPulse(point: point, life: 0.48, maximumLife: 0.48, radius: 235, color: .white))
        screenFlashAlpha = max(screenFlashAlpha, 0.82)
        screenFlashColor = .systemOrange

        for index in 0..<145 {
            let angle = CGFloat.random(in: 0...(2 * .pi))
            let speed = CGFloat.random(in: 180...1_180)
            let kind: Particle.Kind
            switch index % 5 {
            case 0: kind = .flame
            case 1: kind = .smoke
            case 2: kind = .spark
            default: kind = .shard
            }
            particles.append(Particle(
                kind: kind,
                position: CGPoint(x: point.x + CGFloat.random(in: -12...12), y: point.y + CGFloat.random(in: -12...12)),
                velocity: CGVector(dx: cos(angle) * speed, dy: sin(angle) * speed),
                life: CGFloat.random(in: 0.48...1.65),
                maximumLife: 1.65,
                size: CGFloat.random(in: 4...24),
                rotation: angle
            ))
        }
        soundEngine.playExplosion()
        enforceLimits()
    }

    private func saw(at point: CGPoint) {
        let previous = lastSawPoint ?? CGPoint(x: point.x - 12, y: point.y)
        var destination = point
        if hypot(destination.x - previous.x, destination.y - previous.y) < 3 {
            destination.x += CGFloat.random(in: -10...10)
            destination.y += CGFloat.random(in: -10...10)
        }
        commitSawCut(from: previous, to: destination)
        lastSawPoint = destination

        let direction = atan2(destination.y - previous.y, destination.x - previous.x)
        for _ in 0..<9 {
            let angle = direction + CGFloat.random(in: -1.15...1.15)
            let speed = CGFloat.random(in: 170...690)
            particles.append(Particle(
                kind: .spark,
                position: destination,
                velocity: CGVector(dx: cos(angle) * speed, dy: sin(angle) * speed),
                life: CGFloat.random(in: 0.18...0.52),
                maximumLife: 0.52,
                size: CGFloat.random(in: 2...6),
                rotation: angle
            ))
        }

        let now = ProcessInfo.processInfo.systemUptime
        if now - lastSawSoundTime > 0.105 {
            soundEngine.playSawBurst()
            lastSawSoundTime = now
        }
        enforceLimits()
    }

    private func strikeLightning(at rawPoint: CGPoint) {
        let point = CGPoint(
            x: rawPoint.x + CGFloat.random(in: -9...9),
            y: rawPoint.y + CGFloat.random(in: -9...9)
        )
        commitDamage(DamageMark(
            kind: .lightning,
            point: point,
            radius: CGFloat.random(in: 105...165),
            rotation: CGFloat.random(in: 0...(2 * .pi)),
            seed: UInt64.random(in: 1...UInt64.max)
        ))
        pulses.append(ImpactPulse(point: point, life: 0.3, maximumLife: 0.3, radius: 115, color: .systemCyan))
        screenFlashAlpha = max(screenFlashAlpha, 0.32)
        screenFlashColor = .systemCyan

        for _ in 0..<26 {
            let angle = CGFloat.random(in: 0...(2 * .pi))
            let speed = CGFloat.random(in: 210...820)
            particles.append(Particle(
                kind: .spark,
                position: point,
                velocity: CGVector(dx: cos(angle) * speed, dy: sin(angle) * speed),
                life: CGFloat.random(in: 0.18...0.58),
                maximumLife: 0.58,
                size: CGFloat.random(in: 2...7),
                rotation: angle
            ))
        }
        soundEngine.playLightning()
        enforceLimits()
    }

    private func enforceLimits() {
        let particleLimit = 1_600
        if particles.count > particleLimit {
            particles.removeFirst(particles.count - particleLimit)
        }
    }

    private func commitSawCut(from start: CGPoint, to end: CGPoint) {
        damageImage.lockFocus()
        if let context = NSGraphicsContext.current?.cgContext {
            let dx = end.x - start.x
            let dy = end.y - start.y
            let distance = max(1, hypot(dx, dy))
            let normal = CGVector(dx: -dy / distance, dy: dx / distance)
            let segments = max(2, Int(distance / 6))
            let path = CGMutablePath()
            path.move(to: start)

            for segment in 1...segments {
                let progress = CGFloat(segment) / CGFloat(segments)
                let jitter = segment == segments ? 0 : CGFloat.random(in: -5.5...5.5)
                path.addLine(to: CGPoint(
                    x: start.x + dx * progress + normal.dx * jitter,
                    y: start.y + dy * progress + normal.dy * jitter
                ))
            }

            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.setShadow(offset: .zero, blur: 5, color: NSColor.black.cgColor)
            context.addPath(path)
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.9).cgColor)
            context.setLineWidth(11)
            context.strokePath()

            context.addPath(path)
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.78).cgColor)
            context.setLineWidth(3.2)
            context.strokePath()

            context.addPath(path)
            context.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.46).cgColor)
            context.setLineWidth(1.2)
            context.strokePath()
        }
        damageImage.unlockFocus()
        needsDisplay = true
    }

    private func commitDamage(_ mark: DamageMark) {
        damageImage.lockFocus()
        if let context = NSGraphicsContext.current?.cgContext {
            context.setLineCap(.round)
            context.setLineJoin(.round)
            switch mark.kind {
            case .hammer:
                drawHammer(mark, in: context)
            case .bullet:
                drawBullet(mark, in: context)
            case .scorch:
                drawScorch(mark, in: context)
            case .explosion:
                drawExplosion(mark, in: context)
            case .lightning:
                drawLightning(mark, in: context)
            }
        }
        damageImage.unlockFocus()
        needsDisplay = true
    }

    @objc private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let delta = CGFloat(min(0.04, now - lastTick))
        lastTick = now

        var detonations: [(CGPoint, UInt64)] = []
        for index in bombs.indices {
            bombs[index].life -= delta
            if bombs[index].life <= 0 {
                detonations.append((bombs[index].point, bombs[index].seed))
            }
        }
        bombs.removeAll { $0.life <= 0 }
        for (point, seed) in detonations {
            explode(at: point, seed: seed)
        }

        screenFlashAlpha = max(0, screenFlashAlpha - delta * 2.7)

        for index in particles.indices {
            particles[index].position.x += particles[index].velocity.dx * delta
            particles[index].position.y += particles[index].velocity.dy * delta
            particles[index].velocity.dy -= (particles[index].kind == .smoke ? -32 : 760) * delta
            particles[index].velocity.dx *= pow(0.985, delta * 60)
            particles[index].life -= delta
        }
        particles.removeAll { $0.life <= 0 }

        for index in pulses.indices {
            pulses[index].life -= delta
        }
        pulses.removeAll { $0.life <= 0 }

        if !particles.isEmpty || !pulses.isEmpty || !bombs.isEmpty || screenFlashAlpha > 0 || pointerIsVisible {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setLineCap(.round)
        context.setLineJoin(.round)

        damageImage.draw(in: bounds, from: NSRect(origin: .zero, size: damageImage.size), operation: .sourceOver, fraction: 1)

        for bomb in bombs {
            drawBomb(bomb, in: context)
        }
        for pulse in pulses {
            drawPulse(pulse, in: context)
        }
        for particle in particles {
            drawParticle(particle, in: context)
        }
        if screenFlashAlpha > 0 {
            context.saveGState()
            context.setBlendMode(.screen)
            context.setFillColor(screenFlashColor.withAlphaComponent(screenFlashAlpha).cgColor)
            context.fill(bounds)
            context.restoreGState()
        }
        if pointerIsVisible {
            drawReticle(in: context)
        }
    }

    private func drawHammer(_ mark: DamageMark, in context: CGContext) {
        var random = SeededGenerator(seed: mark.seed)
        context.saveGState()

        let craterRect = CGRect(
            x: mark.point.x - mark.radius * 0.42,
            y: mark.point.y - mark.radius * 0.42,
            width: mark.radius * 0.84,
            height: mark.radius * 0.84
        )
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                NSColor.black.withAlphaComponent(0.88).cgColor,
                NSColor.darkGray.withAlphaComponent(0.48).cgColor,
                NSColor.clear.cgColor
            ] as CFArray,
            locations: [0, 0.48, 1]
        ) {
            context.saveGState()
            context.addEllipse(in: craterRect)
            context.clip()
            context.drawRadialGradient(
                gradient,
                startCenter: mark.point,
                startRadius: 1,
                endCenter: mark.point,
                endRadius: mark.radius * 0.45,
                options: []
            )
            context.restoreGState()
        }

        context.setShadow(offset: .zero, blur: 2.5, color: NSColor.black.withAlphaComponent(0.8).cgColor)
        let rayCount = 13
        for ray in 0..<rayCount {
            let baseAngle = mark.rotation + (CGFloat(ray) / CGFloat(rayCount)) * 2 * .pi + random.range(-0.14...0.14)
            let length = mark.radius * random.range(0.85...1.95)
            let path = CGMutablePath()
            path.move(to: mark.point)
            var current = mark.point
            let segments = Int(random.range(3...6))

            for segment in 1...segments {
                let distance = length * CGFloat(segment) / CGFloat(segments)
                let bend = random.range(-0.12...0.12)
                current = CGPoint(
                    x: mark.point.x + cos(baseAngle + bend) * distance,
                    y: mark.point.y + sin(baseAngle + bend) * distance
                )
                path.addLine(to: current)
            }

            context.addPath(path)
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.88).cgColor)
            context.setLineWidth(random.range(1.0...2.4))
            context.strokePath()

            if ray.isMultiple(of: 2) {
                let branchDirection: CGFloat = random.unit() > 0.5 ? 1 : -1
                let branchAngle = baseAngle + random.range(0.34...0.72) * branchDirection
                let branchLength = length * random.range(0.16...0.38)
                let branch = CGMutablePath()
                branch.move(to: current)
                branch.addLine(to: CGPoint(
                    x: current.x + cos(branchAngle) * branchLength,
                    y: current.y + sin(branchAngle) * branchLength
                ))
                context.addPath(branch)
                context.setStrokeColor(NSColor.white.withAlphaComponent(0.62).cgColor)
                context.setLineWidth(1)
                context.strokePath()
            }
        }

        context.setStrokeColor(NSColor.white.withAlphaComponent(0.7).cgColor)
        context.setLineWidth(2.2)
        context.strokeEllipse(in: craterRect.insetBy(dx: 3, dy: 3))
        context.restoreGState()
    }

    private func drawBullet(_ mark: DamageMark, in context: CGContext) {
        var random = SeededGenerator(seed: mark.seed)
        context.saveGState()
        context.setShadow(offset: .zero, blur: 4, color: NSColor.black.cgColor)

        let outer = CGRect(
            x: mark.point.x - mark.radius,
            y: mark.point.y - mark.radius,
            width: mark.radius * 2,
            height: mark.radius * 2
        )
        context.setFillColor(NSColor.black.withAlphaComponent(0.9).cgColor)
        context.fillEllipse(in: outer)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.78).cgColor)
        context.setLineWidth(1.4)
        context.strokeEllipse(in: outer.insetBy(dx: 2.4, dy: 2.4))

        for ray in 0..<7 {
            let angle = mark.rotation + CGFloat(ray) / 7 * 2 * .pi + random.range(-0.18...0.18)
            let length = mark.radius * random.range(1.35...2.85)
            let midpoint = CGPoint(
                x: mark.point.x + cos(angle) * length * 0.58,
                y: mark.point.y + sin(angle) * length * 0.58
            )
            let end = CGPoint(
                x: mark.point.x + cos(angle + random.range(-0.13...0.13)) * length,
                y: mark.point.y + sin(angle + random.range(-0.13...0.13)) * length
            )
            context.move(to: mark.point)
            context.addLine(to: midpoint)
            context.addLine(to: end)
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.72).cgColor)
            context.setLineWidth(random.range(0.7...1.4))
            context.strokePath()
        }
        context.restoreGState()
    }

    private func drawScorch(_ mark: DamageMark, in context: CGContext) {
        context.saveGState()
        let area = CGRect(
            x: mark.point.x - mark.radius,
            y: mark.point.y - mark.radius,
            width: mark.radius * 2,
            height: mark.radius * 2
        )
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                NSColor.black.withAlphaComponent(0.54).cgColor,
                NSColor.brown.withAlphaComponent(0.32).cgColor,
                NSColor.systemOrange.withAlphaComponent(0.12).cgColor,
                NSColor.clear.cgColor
            ] as CFArray,
            locations: [0, 0.36, 0.66, 1]
        ) {
            context.addEllipse(in: area)
            context.clip()
            context.drawRadialGradient(
                gradient,
                startCenter: mark.point,
                startRadius: 0,
                endCenter: mark.point,
                endRadius: mark.radius,
                options: []
            )
        }
        context.restoreGState()
    }

    private func drawExplosion(_ mark: DamageMark, in context: CGContext) {
        var random = SeededGenerator(seed: mark.seed)
        context.saveGState()

        let area = CGRect(
            x: mark.point.x - mark.radius,
            y: mark.point.y - mark.radius,
            width: mark.radius * 2,
            height: mark.radius * 2
        )
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                NSColor.black.withAlphaComponent(0.94).cgColor,
                NSColor.darkGray.withAlphaComponent(0.76).cgColor,
                NSColor.systemRed.withAlphaComponent(0.3).cgColor,
                NSColor.systemOrange.withAlphaComponent(0.12).cgColor,
                NSColor.clear.cgColor
            ] as CFArray,
            locations: [0, 0.23, 0.49, 0.7, 1]
        ) {
            context.saveGState()
            context.addEllipse(in: area)
            context.clip()
            context.drawRadialGradient(
                gradient,
                startCenter: mark.point,
                startRadius: 0,
                endCenter: mark.point,
                endRadius: mark.radius,
                options: []
            )
            context.restoreGState()
        }

        context.setShadow(offset: .zero, blur: 4, color: NSColor.black.cgColor)
        for ray in 0..<24 {
            let angle = mark.rotation + CGFloat(ray) / 24 * 2 * .pi + random.range(-0.1...0.1)
            let length = mark.radius * random.range(0.72...1.55)
            let path = CGMutablePath()
            path.move(to: mark.point)
            let elbow = CGPoint(
                x: mark.point.x + cos(angle + random.range(-0.12...0.12)) * length * 0.57,
                y: mark.point.y + sin(angle + random.range(-0.12...0.12)) * length * 0.57
            )
            path.addLine(to: elbow)
            path.addLine(to: CGPoint(
                x: mark.point.x + cos(angle + random.range(-0.1...0.1)) * length,
                y: mark.point.y + sin(angle + random.range(-0.1...0.1)) * length
            ))
            context.addPath(path)
            context.setStrokeColor(NSColor.white.withAlphaComponent(random.range(0.38...0.78)).cgColor)
            context.setLineWidth(random.range(0.9...2.2))
            context.strokePath()
        }

        context.setStrokeColor(NSColor.systemOrange.withAlphaComponent(0.46).cgColor)
        context.setLineWidth(3)
        context.strokeEllipse(in: area.insetBy(dx: mark.radius * 0.46, dy: mark.radius * 0.46))
        context.restoreGState()
    }

    private func drawLightning(_ mark: DamageMark, in context: CGContext) {
        var random = SeededGenerator(seed: mark.seed)
        context.saveGState()

        let burnArea = CGRect(
            x: mark.point.x - 36,
            y: mark.point.y - 36,
            width: 72,
            height: 72
        )
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                NSColor.black.withAlphaComponent(0.84).cgColor,
                NSColor.systemBlue.withAlphaComponent(0.34).cgColor,
                NSColor.clear.cgColor
            ] as CFArray,
            locations: [0, 0.48, 1]
        ) {
            context.saveGState()
            context.addEllipse(in: burnArea)
            context.clip()
            context.drawRadialGradient(
                gradient,
                startCenter: mark.point,
                startRadius: 0,
                endCenter: mark.point,
                endRadius: 36,
                options: []
            )
            context.restoreGState()
        }

        for branch in 0..<11 {
            let angle = mark.rotation + CGFloat(branch) / 11 * 2 * .pi + random.range(-0.25...0.25)
            let totalLength = mark.radius * random.range(0.65...1.12)
            let path = CGMutablePath()
            path.move(to: mark.point)
            var previous = mark.point

            for segment in 1...5 {
                let distance = totalLength * CGFloat(segment) / 5
                let sideways = random.range(-13...13)
                let target = CGPoint(
                    x: mark.point.x + cos(angle) * distance + cos(angle + .pi / 2) * sideways,
                    y: mark.point.y + sin(angle) * distance + sin(angle + .pi / 2) * sideways
                )
                path.addLine(to: target)

                if segment == 3 && branch.isMultiple(of: 2) {
                    let forkAngle = angle + random.range(0.45...0.82) * (random.unit() > 0.5 ? 1 : -1)
                    let fork = CGMutablePath()
                    fork.move(to: previous)
                    fork.addLine(to: CGPoint(
                        x: previous.x + cos(forkAngle) * totalLength * 0.38,
                        y: previous.y + sin(forkAngle) * totalLength * 0.38
                    ))
                    context.addPath(fork)
                    context.setStrokeColor(NSColor.systemCyan.withAlphaComponent(0.72).cgColor)
                    context.setLineWidth(1.2)
                    context.strokePath()
                }
                previous = target
            }

            context.setShadow(offset: .zero, blur: 8, color: NSColor.systemCyan.cgColor)
            context.addPath(path)
            context.setStrokeColor(NSColor.systemCyan.withAlphaComponent(0.78).cgColor)
            context.setLineWidth(4)
            context.strokePath()
            context.addPath(path)
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.96).cgColor)
            context.setLineWidth(1.25)
            context.strokePath()
        }
        context.restoreGState()
    }

    private func drawBomb(_ bomb: PendingBomb, in context: CGContext) {
        let progress = max(0, min(1, bomb.life / bomb.maximumLife))
        let blink = sin(progress * 32) > 0
        let radius: CGFloat = 24 + (1 - progress) * 5

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -5), blur: 10, color: NSColor.black.withAlphaComponent(0.8).cgColor)
        context.setFillColor(NSColor.black.withAlphaComponent(0.94).cgColor)
        context.fillEllipse(in: CGRect(
            x: bomb.point.x - radius,
            y: bomb.point.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.46).cgColor)
        context.setLineWidth(2)
        context.strokeEllipse(in: CGRect(
            x: bomb.point.x - radius + 3,
            y: bomb.point.y - radius + 3,
            width: (radius - 3) * 2,
            height: (radius - 3) * 2
        ))

        context.move(to: CGPoint(x: bomb.point.x + 12, y: bomb.point.y + 18))
        context.addCurve(
            to: CGPoint(x: bomb.point.x + 31, y: bomb.point.y + 36),
            control1: CGPoint(x: bomb.point.x + 23, y: bomb.point.y + 22),
            control2: CGPoint(x: bomb.point.x + 22, y: bomb.point.y + 35)
        )
        context.setStrokeColor(NSColor.brown.cgColor)
        context.setLineWidth(5)
        context.strokePath()

        let sparkPoint = CGPoint(x: bomb.point.x + 32, y: bomb.point.y + 37)
        context.setShadow(offset: .zero, blur: 10, color: NSColor.systemOrange.cgColor)
        context.setFillColor((blink ? NSColor.white : NSColor.systemRed).cgColor)
        context.fillEllipse(in: CGRect(x: sparkPoint.x - 5, y: sparkPoint.y - 5, width: 10, height: 10))

        context.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.88).cgColor)
        context.setLineWidth(4)
        context.addArc(
            center: bomb.point,
            radius: radius + 9,
            startAngle: -.pi / 2,
            endAngle: -.pi / 2 + progress * 2 * .pi,
            clockwise: false
        )
        context.strokePath()
        context.restoreGState()
    }

    private func drawPulse(_ pulse: ImpactPulse, in context: CGContext) {
        let progress = 1 - pulse.life / pulse.maximumLife
        let radius = pulse.radius * progress
        context.saveGState()
        context.setStrokeColor(pulse.color.withAlphaComponent((1 - progress) * 0.7).cgColor)
        context.setLineWidth(max(1, 6 * (1 - progress)))
        context.strokeEllipse(in: CGRect(
            x: pulse.point.x - radius,
            y: pulse.point.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
        context.restoreGState()
    }

    private func drawParticle(_ particle: Particle, in context: CGContext) {
        let alpha = max(0, min(1, particle.life / particle.maximumLife))
        context.saveGState()
        context.translateBy(x: particle.position.x, y: particle.position.y)
        context.rotate(by: particle.rotation)

        switch particle.kind {
        case .shard:
            context.setFillColor(NSColor.white.withAlphaComponent(alpha * 0.72).cgColor)
            context.setStrokeColor(NSColor.black.withAlphaComponent(alpha * 0.55).cgColor)
            context.setLineWidth(1)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: -particle.size * 0.5, y: -particle.size * 0.25))
            path.addLine(to: CGPoint(x: particle.size * 0.55, y: 0))
            path.addLine(to: CGPoint(x: -particle.size * 0.2, y: particle.size * 0.6))
            path.closeSubpath()
            context.addPath(path)
            context.drawPath(using: .fillStroke)
        case .spark:
            context.setShadow(offset: .zero, blur: 7, color: NSColor.systemOrange.cgColor)
            context.setStrokeColor(NSColor.systemYellow.withAlphaComponent(alpha).cgColor)
            context.setLineWidth(max(1, particle.size * 0.45))
            context.move(to: .zero)
            context.addLine(to: CGPoint(x: -particle.velocity.dx * 0.025, y: -particle.velocity.dy * 0.025))
            context.strokePath()
        case .smoke:
            context.setFillColor(NSColor.black.withAlphaComponent(alpha * 0.28).cgColor)
            context.fillEllipse(in: CGRect(
                x: -particle.size,
                y: -particle.size,
                width: particle.size * 2,
                height: particle.size * 2
            ))
        case .flame:
            context.setShadow(offset: .zero, blur: 12, color: NSColor.systemRed.withAlphaComponent(alpha).cgColor)
            context.setFillColor(NSColor.systemOrange.withAlphaComponent(alpha * 0.9).cgColor)
            context.fillEllipse(in: CGRect(
                x: -particle.size * 0.45,
                y: -particle.size * 0.65,
                width: particle.size * 0.9,
                height: particle.size * 1.3
            ))
            context.setFillColor(NSColor.systemYellow.withAlphaComponent(alpha).cgColor)
            context.fillEllipse(in: CGRect(
                x: -particle.size * 0.18,
                y: -particle.size * 0.35,
                width: particle.size * 0.36,
                height: particle.size * 0.72
            ))
        }
        context.restoreGState()
    }

    private func drawReticle(in context: CGContext) {
        context.saveGState()
        let color: NSColor
        switch selectedTool {
        case .hammer: color = .white
        case .machineGun: color = .systemRed
        case .flamethrower: color = .systemOrange
        case .bomb: color = .systemYellow
        case .chainsaw: color = .systemPink
        case .lightning: color = .systemCyan
        }

        context.setStrokeColor(color.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(isPressed ? 2.8 : 1.6)
        context.setShadow(offset: .zero, blur: 5, color: NSColor.black.cgColor)
        let radius: CGFloat = isPressed ? 13 : 18
        context.strokeEllipse(in: CGRect(x: pointer.x - radius, y: pointer.y - radius, width: radius * 2, height: radius * 2))
        context.move(to: CGPoint(x: pointer.x - radius - 8, y: pointer.y))
        context.addLine(to: CGPoint(x: pointer.x - 5, y: pointer.y))
        context.move(to: CGPoint(x: pointer.x + 5, y: pointer.y))
        context.addLine(to: CGPoint(x: pointer.x + radius + 8, y: pointer.y))
        context.move(to: CGPoint(x: pointer.x, y: pointer.y - radius - 8))
        context.addLine(to: CGPoint(x: pointer.x, y: pointer.y - 5))
        context.move(to: CGPoint(x: pointer.x, y: pointer.y + 5))
        context.addLine(to: CGPoint(x: pointer.x, y: pointer.y + radius + 8))
        context.strokePath()
        context.restoreGState()
    }
}
