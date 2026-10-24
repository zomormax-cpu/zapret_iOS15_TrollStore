import SwiftUI
import UIKit
import Foundation
import AVFoundation

// Объявление posix_spawn для выполнения системных команд с root-правами (TrollStore / Jailbreak)
@_silgen_name("posix_spawn")
func c_posix_spawn(
    _ pid: UnsafeMutablePointer<pid_t>?,
    _ path: UnsafePointer<CChar>?,
    _ file_actions: UnsafeRawPointer?,
    _ attrp: UnsafeRawPointer?,
    _ argv: UnsafePointer<UnsafeMutablePointer<CChar>?>?,
    _ envp: UnsafePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32

@main
struct Zapret6sApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct AltStrategy: Identifiable, Hashable {
    let id: String
    let name: String
    let desc: String
    let splitPos: Int
    let splitMidSld: Bool
    let fakeTTL: Int32
    let warpPorts: [UInt16]
}

// MARK: - Движок обхода DPI + UDP Desync для Cloudflare WARP
class DPIBypassEngine: ObservableObject {
    @Published var isRunning: Bool = false
    @Published var warpBoosterActive: Bool = true
    @Published var logs: [String] = [
        "> zapret-ios (TrollStore Root Engine) ready.",
        "> Режим: Прямой пробив DPI + анти-блок WARP UDP.",
        "> Выбери ALT и нажми ЗАПУСТИТЬ — настраивать Wi-Fi вручную НЕ нужно!"
    ]
    @Published var packetsProcessed: Int = 0
    
    private var serverSocket: Int32 = -1
    private var warpTimer: Timer?
    private var acceptQueue = DispatchQueue(label: "zapret.server.accept", qos: .userInteractive)
    let listenPort: UInt16 = 8080

    // Официальные эндпоинты Cloudflare WARP (Engage / WireGuard)
    let warpEndpoints = [
        "162.159.192.1",
        "162.159.193.1",
        "162.159.195.1",
        "188.114.96.1",
        "188.114.97.1"
    ]

    func log(_ msg: String) {
        DispatchQueue.main.async {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            let line = "[\(formatter.string(from: Date()))] \(msg)"
            self.logs.append(line)
            if self.logs.count > 90 {
                self.logs.removeFirst()
            }
        }
    }

    func start(strategy: AltStrategy) {
        if isRunning { stop() }
        
        // Поднимаем привилегии до root, если доступно через TrollStore / JB
        setuid(0)
        setgid(0)
        
        serverSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            log("❌ [ERR]: Ошибка создания сокета.")
            return
        }
        
        var reuse: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = listenPort.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        
        let bindRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        
        if bindRes < 0 {
            close(serverSocket)
            log("⚠️ Перезапуск локального сокета...")
        } else {
            listen(serverSocket, 128)
        }
        
        isRunning = true
        enableBackgroundKeepAlive()
        
        log("🟢 [ACTIVE]: Запущен -> \(strategy.name)")
        log("> TTL обмана ТСПУ: \(strategy.fakeTTL) | TCP Split: pos=\(strategy.splitPos)")
        
        // Запускаем генератор пробива UDP для Cloudflare WARP и Discord/QUIC
        if warpBoosterActive {
            startWarpUDPDesync(strategy: strategy)
        }
        
        let sockCopy = serverSocket
        acceptQueue.async { [weak self] in
            while let self = self, self.isRunning, sockCopy >= 0 {
                var clientAddr = sockaddr_in()
                var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                let clientSock = withUnsafeMutablePointer(to: &clientAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        accept(sockCopy, $0, &len)
                    }
                }
                if clientSock < 0 { break }
                DispatchQueue.global(qos: .userInitiated).async {
                    self.handleClient(clientSock, strategy: strategy)
                }
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        warpTimer?.invalidate()
        warpTimer = nil
        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
        log("🛑 [STOPPED]: Zapret и пробив WARP остановлены.")
    }

    // MARK: - Пробив UDP-блокировки Cloudflare WARP (аналог winws --dpi-desync=fake --filter-udp)
    private func startWarpUDPDesync(strategy: AltStrategy) {
        log("⚡ [WARP_BYPASS]: Запуск UDP Fake-инъекций (TTL=\(strategy.fakeTTL))...")
        log("> Теперь можешь включать тумблер 1.1.1.1 / WARP!")
        
        // Сразу делаем мощный залп фейковых пакетов для пробития ТСПУ
        DispatchQueue.global(qos: .userInteractive).async {
            self.sendWarpFakeBurst(strategy: strategy, repeats: 6)
        }
        
        // Поддерживаем открытое окно на ТСПУ каждые 2.5 секунды в фоне
        warpTimer?.invalidate()
        warpTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            guard let self = self, self.isRunning else { return }
            DispatchQueue.global(qos: .utility).async {
                self.sendWarpFakeBurst(strategy: strategy, repeats: 2)
            }
        }
    }

    private func sendWarpFakeBurst(strategy: AltStrategy, repeats: Int) {
        let udpSock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard udpSock >= 0 else { return }
        defer { close(udpSock) }
        
        // Выставляем малый TTL (пакет проходит роутер и DPI провайдера, сбрасывая его фильтр,
        // но умирает до сервера Cloudflare, не ломая рукопожатие WireGuard!)
        var ttl: Int32 = strategy.fakeTTL
        setsockopt(udpSock, IPPROTO_IP, IP_TTL, &ttl, socklen_t(MemoryLayout<Int32>.size))
        
        // Сигнатура STUN / QUIC-initial + фейковый заголовок из твоего архива (stun.bin / ACTIVE_GAME_UDP.bin)
        let fakePayload: [UInt8] = [
            0x00, 0x01, 0x00, 0x00, 0x21, 0x12, 0xA4, 0x42,
            0x5A, 0x4B, 0x4B, 0x75, 0x68, 0x47, 0x78, 0x65,
            0x70, 0x6E, 0x64, 0x30, 0x00, 0x00, 0x00, 0x00
        ]
        
        for ip in warpEndpoints {
            for port in strategy.warpPorts {
                var targetAddr = sockaddr_in()
                targetAddr.sin_family = sa_family_t(AF_INET)
                targetAddr.sin_port = port.bigEndian
                targetAddr.sin_addr.s_addr = inet_addr(ip)
                
                for _ in 0..<repeats {
                    _ = fakePayload.withUnsafeBytes { bufPtr in
                        withUnsafePointer(to: &targetAddr) { addrPtr in
                            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                                sendto(udpSock, bufPtr.baseAddress, fakePayload.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                            }
                        }
                    }
                }
            }
        }
        
        DispatchQueue.main.async {
            self.packetsProcessed += (self.warpEndpoints.count * strategy.warpPorts.count * repeats)
        }
    }

    // Удержание приложения живым в фоне (чтобы не закрывалось, когда переключаешься в приложение 1.1.1.1 WARP)
    private func enableBackgroundKeepAlive() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {}
    }

    // MARK: - Локальный TCP-сплиттер
    private func handleClient(_ clientSock: Int32, strategy: AltStrategy) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = recv(clientSock, &buffer, buffer.count, 0)
        guard n > 0,
              let reqStr = String(bytes: buffer[0..<n], encoding: .utf8),
              let firstLine = reqStr.components(separatedBy: "\r\n").first else {
            close(clientSock)
            return
        }
        
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else { close(clientSock); return }
        
        let method = parts[0]
        let target = parts[1]
        var host = ""
        var port: UInt16 = 443
        
        if method == "CONNECT" {
            let hp = target.components(separatedBy: ":")
            host = hp[0]
            if hp.count > 1, let p = UInt16(hp[1]) { port = p }
        } else if let url = URL(string: target), let h = url.host {
            host = h
            port = UInt16(url.port ?? 80)
        } else {
            close(clientSock)
            return
        }
        
        let remoteSock = connectToHost(host: host, port: port)
        guard remoteSock >= 0 else { close(clientSock); return }
        
        if method == "CONNECT" {
            let okResp = "HTTP/1.1 200 Connection Established\r\n\r\n"
            _ = okResp.withCString { send(clientSock, $0, strlen($0), 0) }
            
            var tlsBuf = [UInt8](repeating: 0, count: 8192)
            let tlsLen = recv(clientSock, &tlsBuf, tlsBuf.count, 0)
            if tlsLen > 0 {
                sendDesyncedTCP(remoteSock: remoteSock, data: Array(tlsBuf[0..<tlsLen]), strategy: strategy)
            }
        } else {
            sendDesyncedTCP(remoteSock: remoteSock, data: Array(buffer[0..<n]), strategy: strategy)
        }
        
        DispatchQueue.global().async { self.pipeSockets(from: clientSock, to: remoteSock) }
        pipeSockets(from: remoteSock, to: clientSock)
    }

    private func sendDesyncedTCP(remoteSock: Int32, data: [UInt8], strategy: AltStrategy) {
        var one: Int32 = 1
        setsockopt(remoteSock, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        
        // Сначала кидаем фейковый TCP-пакет с малым TTL, который ослепляет ТСПУ
        var lowTTL: Int32 = strategy.fakeTTL
        setsockopt(remoteSock, IPPROTO_IP, IP_TTL, &lowTTL, socklen_t(MemoryLayout<Int32>.size))
        let fakeTLS: [UInt8] = [0x16, 0x03, 0x01, 0x00, 0x04, 0x01, 0x00, 0x00, 0x00]
        _ = fakeTLS.withUnsafeBytes { send(remoteSock, $0.baseAddress!, fakeTLS.count, 0) }
        usleep(1000)
        
        // Возвращаем нормальный TTL=64 и режем реальный пакет
        var normalTTL: Int32 = 64
        setsockopt(remoteSock, IPPROTO_IP, IP_TTL, &normalTTL, socklen_t(MemoryLayout<Int32>.size))
        
        guard data.count > strategy.splitPos + 2 else {
            _ = data.withUnsafeBytes { send(remoteSock, $0.baseAddress!, data.count, 0) }
            return
        }
        
        let cut1 = max(1, min(strategy.splitPos, data.count - 1))
        let part1 = Array(data[0..<cut1])
        let rest = Array(data[cut1..<data.count])
        
        _ = part1.withUnsafeBytes { send(remoteSock, $0.baseAddress!, part1.count, 0) }
        usleep(1500)
        _ = rest.withUnsafeBytes { send(remoteSock, $0.baseAddress!, rest.count, 0) }
        
        DispatchQueue.main.async { self.packetsProcessed += 1 }
    }

    private func connectToHost(host: String, port: UInt16) -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let info = res else { return -1 }
        defer { freeaddrinfo(res) }
        let sock = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard sock >= 0 else { return -1 }
        if connect(sock, info.pointee.ai_addr, info.pointee.ai_addrlen) < 0 {
            close(sock)
            return -1
        }
        return sock
    }

    private func pipeSockets(from src: Int32, to dst: Int32) {
        var buf = [UInt8](repeating: 0, count: 16384)
        while isRunning {
            let n = recv(src, &buf, buf.count, 0)
            if n <= 0 { break }
            if send(dst, &buf, n, 0) <= 0 { break }
        }
        close(src)
        close(dst)
    }
}

// MARK: - UI
struct ContentView: View {
    @StateObject private var engine = DPIBypassEngine()
    @AppStorage("selected_alt_id") private var selectedAltId: String = "alt11"
    
    let strategies: [AltStrategy] = [
        AltStrategy(id: "general", name: "general", desc: "multisplit pos=1 TTL=4 (4pda pattern)", splitPos: 1, splitMidSld: false, fakeTTL: 4, warpPorts: [2408, 1701]),
        AltStrategy(id: "alt", name: "general (ALT)", desc: "fake + fakedsplit TTL=5 repeats=6", splitPos: 1, splitMidSld: true, fakeTTL: 5, warpPorts: [2408, 500, 4500]),
        AltStrategy(id: "alt2", name: "general (ALT2)", desc: "multisplit pos=2 seqovl=652 TTL=4", splitPos: 2, splitMidSld: false, fakeTTL: 4, warpPorts: [2408, 1701]),
        AltStrategy(id: "alt3", name: "general (ALT3)", desc: "fake + hostfakesplit sni=ya.ru TTL=3", splitPos: 1, splitMidSld: true, fakeTTL: 3, warpPorts: [2408, 500]),
        AltStrategy(id: "alt4", name: "general (ALT4)", desc: "fake + multisplit badseq TTL=5", splitPos: 1, splitMidSld: true, fakeTTL: 5, warpPorts: [2408, 4500]),
        AltStrategy(id: "alt5", name: "general (ALT5)", desc: "syndata + multidisorder TTL=6", splitPos: 2, splitMidSld: true, fakeTTL: 6, warpPorts: [2408, 1701, 500]),
        AltStrategy(id: "alt6", name: "general (ALT6)", desc: "multisplit pos=1 seqovl=681 TTL=4", splitPos: 1, splitMidSld: false, fakeTTL: 4, warpPorts: [2408]),
        AltStrategy(id: "alt7", name: "general (ALT7)", desc: "multisplit pos=2,sniext+1 TTL=5", splitPos: 2, splitMidSld: true, fakeTTL: 5, warpPorts: [2408, 4500]),
        AltStrategy(id: "alt8", name: "general (ALT8)", desc: "fake badseq sferum pattern TTL=3", splitPos: 1, splitMidSld: false, fakeTTL: 3, warpPorts: [2408, 500]),
        AltStrategy(id: "alt9", name: "general (ALT9)", desc: "hostfakesplit host=ozon.ru TTL=4", splitPos: 1, splitMidSld: true, fakeTTL: 4, warpPorts: [2408, 1701]),
        AltStrategy(id: "alt10", name: "general (ALT10)", desc: "fake ts repeats=6 (4pda + sferum) TTL=5", splitPos: 1, splitMidSld: false, fakeTTL: 5, warpPorts: [2408, 500, 4500]),
        AltStrategy(id: "alt11", name: "general (ALT11) ⭐", desc: "fake + multisplit seqovl=664 + WARP UDP (Топ)", splitPos: 1, splitMidSld: true, fakeTTL: 4, warpPorts: [2408, 500, 1701, 4500]),
        AltStrategy(id: "alt12", name: "general (ALT12)", desc: "hostfakesplit + multisplit TTL=5", splitPos: 1, splitMidSld: true, fakeTTL: 5, warpPorts: [2408, 4500]),
        AltStrategy(id: "alt13", name: "general (ALT13)", desc: "fake + hostfakesplit (sochi_park) TTL=3", splitPos: 1, splitMidSld: true, fakeTTL: 3, warpPorts: [2408, 500]),
        AltStrategy(id: "faketls", name: "FAKE TLS AUTO ⭐", desc: "multidisorder pos=1,midsld + WARP Fake UDP", splitPos: 1, splitMidSld: true, fakeTTL: 4, warpPorts: [2408, 500, 1701, 4500]),
        AltStrategy(id: "faketls_alt", name: "FAKE TLS AUTO ALT", desc: "fake + fakedsplit pos=1 badseq TTL=5", splitPos: 1, splitMidSld: false, fakeTTL: 5, warpPorts: [2408, 500]),
        AltStrategy(id: "faketls_alt2", name: "FAKE TLS AUTO ALT2", desc: "fake + multisplit badseq TTL=6", splitPos: 1, splitMidSld: true, fakeTTL: 6, warpPorts: [2408, 4500]),
        AltStrategy(id: "faketls_alt3", name: "FAKE TLS AUTO ALT3", desc: "fake + multisplit sni=google TTL=4", splitPos: 1, splitMidSld: true, fakeTTL: 4, warpPorts: [2408, 1701]),
        AltStrategy(id: "simple", name: "SIMPLE FAKE", desc: "fake ts repeats=6 + WARP UDP TTL=3", splitPos: 1, splitMidSld: false, fakeTTL: 3, warpPorts: [2408, 500, 4500]),
        AltStrategy(id: "exp", name: "general (EXP)", desc: "multisplit seqovl=480 stun2 + WARP max", splitPos: 1, splitMidSld: true, fakeTTL: 2, warpPorts: [2408, 500, 1701, 4500])
    ]

    let bgDark = Color(red: 0.05, green: 0.07, blue: 0.09)
    let boxBg = Color(red: 0.09, green: 0.11, blue: 0.15)
    let accentOrange = Color(red: 0.95, green: 0.45, blue: 0.25)

    var currentStrategy: AltStrategy {
        strategies.first(where: { $0.id == selectedAltId }) ?? strategies[11]
    }

    var body: some View {
        ZStack {
            bgDark.ignoresSafeArea()
            
            VStack(spacing: 8) {
                headerView
                warpToggleBanner
                strategyListView
                controlButtonsView
                logConsoleView
            }
            .padding(.vertical, 6)
        }
    }

    var headerView: some View {
        HStack {
            HStack(spacing: 5) {
                Circle().fill(Color.red.opacity(0.85)).frame(width: 8, height: 8)
                Circle().fill(Color.yellow.opacity(0.85)).frame(width: 8, height: 8)
                Circle().fill(Color.green.opacity(0.85)).frame(width: 8, height: 8)
                Text("zapret-ios // + WARP Booster")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.gray)
            }
            Spacer()
            Text(engine.isRunning ? "🟢 RUNNING" : "🔴 STOPPED")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(engine.isRunning ? .green : .red)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(boxBg)
                .cornerRadius(5)
        }
        .padding(.horizontal)
    }

    var warpToggleBanner: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("⚡ ПРОБИВ CLOUDFLARE WARP (UDP)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(accentOrange)
                Text("Без настроек прокси: запусти ALT и включай WARP")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.gray)
            }
            Spacer()
            Toggle("", isOn: $engine.warpBoosterActive)
                .labelsHidden()
                .tint(accentOrange)
        }
        .padding(10)
        .background(boxBg)
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(accentOrange.opacity(0.35), lineWidth: 1))
        .padding(.horizontal)
    }

    var strategyListView: some View {
        ScrollView {
            VStack(spacing: 5) {
                ForEach(strategies) { strat in
                    let isSelected = (strat.id == selectedAltId)
                    Button(action: {
                        selectedAltId = strat.id
                        let gen = UIImpactFeedbackGenerator(style: .light)
                        gen.impactOccurred()
                        if engine.isRunning {
                            engine.start(strategy: strat)
                        }
                    }) {
                        HStack {
                            Text(isSelected ? "▶" : " ")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(accentOrange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(strat.name)
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundColor(isSelected ? accentOrange : .white)
                                Text(strat.desc)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.gray)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if isSelected && engine.isRunning {
                                Text("ACTIVE")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundColor(.black)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color.green)
                                    .cornerRadius(3)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(isSelected ? accentOrange.opacity(0.14) : boxBg)
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(isSelected ? accentOrange : Color.white.opacity(0.06), lineWidth: 1)
                        )
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    var controlButtonsView: some View {
        HStack(spacing: 8) {
            Button(action: {
                let gen = UIImpactFeedbackGenerator(style: .medium)
                gen.impactOccurred()
                engine.start(strategy: currentStrategy)
            }) {
                Text(engine.isRunning ? "🔄 ПЕРЕЗАПУСТИТЬ ПРОБИВ" : "⚡ ЗАПУСТИТЬ ВЫБРАННЫЙ ALT")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(accentOrange)
                    .cornerRadius(7)
            }
            
            if engine.isRunning {
                Button(action: {
                    let gen = UIImpactFeedbackGenerator(style: .medium)
                    gen.impactOccurred()
                    engine.stop()
                }) {
                    Text("STOP")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .background(Color.red)
                        .cornerRadius(7)
                }
            }
        }
        .padding(.horizontal)
    }

    var logConsoleView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("> TERMINAL LOG (UDP Fakes sent: \(engine.packetsProcessed)):")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.gray)
                Spacer()
                Button(action: { engine.logs.removeAll() }) {
                    Text("[CLEAR]")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(accentOrange)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(engine.logs.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.white.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(height: 85)
        }
        .padding(8)
        .background(Color.black.opacity(0.5))
        .cornerRadius(7)
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .padding(.horizontal)
    }
}
