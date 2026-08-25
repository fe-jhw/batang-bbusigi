import AVFoundation

@MainActor
final class SoundEngine {
    var isMuted = false

    private let engine = AVAudioEngine()
    private let format: AVAudioFormat
    private var players: [AVAudioPlayerNode] = []
    private var nextPlayer = 0

    init() {
        format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!

        for _ in 0..<10 {
            let player = AVAudioPlayerNode()
            players.append(player)
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
        }

        engine.mainMixerNode.outputVolume = 0.72
        engine.prepare()
        try? engine.start()
    }

    func playHammer() {
        play(duration: 0.32) { index, total in
            let t = Float(index) / 44_100
            let progress = Float(index) / Float(total)
            let envelope = pow(1 - progress, 3.2)
            let thump = sin(2 * .pi * 72 * t) * 0.82
            let crack = Float.random(in: -1...1) * pow(1 - progress, 8) * 0.85
            return (thump + crack) * envelope
        }
    }

    func playGunshot() {
        play(duration: 0.095) { index, total in
            let t = Float(index) / 44_100
            let progress = Float(index) / Float(total)
            let envelope = pow(1 - progress, 5.5)
            let body = sin(2 * .pi * 118 * t) * 0.5
            let snap = Float.random(in: -1...1) * 1.25
            return (body + snap) * envelope
        }
    }

    func playFlameBurst() {
        play(duration: 0.18) { index, total in
            let progress = Float(index) / Float(total)
            let attack = min(progress * 12, 1)
            let release = pow(1 - progress, 1.4)
            let noise = Float.random(in: -1...1)
            let rumble = sin(Float(index) * 0.035) * 0.25
            return (noise * 0.38 + rumble) * attack * release
        }
    }

    func playBombArmed() {
        play(duration: 0.14) { index, total in
            let t = Float(index) / 44_100
            let progress = Float(index) / Float(total)
            let envelope = sin(progress * .pi)
            return sin(2 * .pi * 920 * t) * envelope * 0.52
        }
    }

    func playExplosion() {
        play(duration: 0.72) { index, total in
            let t = Float(index) / 44_100
            let progress = Float(index) / Float(total)
            let envelope = pow(1 - progress, 2.15)
            let blast = Float.random(in: -1...1) * 0.92
            let frequency: Float = 52 - progress * 18
            let phase = 2 * Float.pi * frequency * t
            let sub = sin(phase) * 0.9
            let mixed = blast + sub
            return mixed * envelope
        }
    }

    func playSawBurst() {
        play(duration: 0.15) { index, total in
            let t = Float(index) / 44_100
            let progress = Float(index) / Float(total)
            let envelope = min(progress * 16, 1) * pow(1 - progress, 0.5)
            let motor = sin(2 * .pi * 118 * t) + sin(2 * .pi * 236 * t) * 0.45
            let teeth = Float.random(in: -1...1) * 0.38
            return (motor * 0.28 + teeth) * envelope
        }
    }

    func playLightning() {
        play(duration: 0.3) { index, total in
            let t = Float(index) / 44_100
            let progress = Float(index) / Float(total)
            let snap = Float.random(in: -1...1) * pow(1 - progress, 7) * 1.2
            let hum = sin(2 * .pi * 76 * t) * pow(1 - progress, 2.2) * 0.48
            return snap + hum
        }
    }

    private func play(duration: Double, generator: (Int, Int) -> Float) {
        guard !isMuted else { return }
        guard !players.isEmpty else { return }
        if !engine.isRunning {
            try? engine.start()
        }

        let frameCount = max(1, Int(format.sampleRate * duration))
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ), let samples = buffer.floatChannelData?[0] else {
            return
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        for index in 0..<frameCount {
            samples[index] = max(-1, min(1, generator(index, frameCount)))
        }

        let player = players[nextPlayer]
        nextPlayer = (nextPlayer + 1) % players.count
        player.stop()
        player.scheduleBuffer(buffer)
        player.play()
    }
}
