#!/usr/bin/env swift
import AppKit
import Foundation

// Gera o ícone do aplicativo (AppIcon.icns) a partir de código, para que ele seja
// reproduzível a partir do repositório em vez de ser um binário opaco versionado.
//
// Uso:  gerar-icone.swift [AppIcon.icns]
//       gerar-icone.swift --web <pasta>   (ícones da página do aluno: aba e tela inicial)

let argumentos = CommandLine.arguments
let destino = argumentos.count > 1 ? argumentos[1] : "AppIcon.icns"

/// `margemRelativa` e `cantoRelativo`: o ícone do macOS tem margem e cantos próprios; o
/// da aba do navegador ocupa o quadro todo (numa aba de 16 px margem é desperdício), e o
/// da tela inicial do iPhone vai sem cantos, porque o próprio iOS os arredonda.
func desenhar(tamanho: Int, margemRelativa: CGFloat = 0.09, cantoRelativo: CGFloat = 0.2237) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: tamanho, pixelsHigh: tamanho,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let lado = CGFloat(tamanho)
    let rect = NSRect(x: 0, y: 0, width: lado, height: lado)

    // Margem e cantos no padrão dos ícones do macOS.
    let margem = lado * margemRelativa
    let corpo = rect.insetBy(dx: margem, dy: margem)
    let raio = corpo.width * cantoRelativo
    let forma = NSBezierPath(roundedRect: corpo, xRadius: raio, yRadius: raio)
    forma.addClip()

    NSGradient(
        starting: NSColor(srgbRed: 0.04, green: 0.55, blue: 1.0, alpha: 1),
        ending: NSColor(srgbRed: 0.0, green: 0.36, blue: 0.86, alpha: 1)
    )?.draw(in: corpo, angle: -90)

    // Mesmo símbolo do favicon da página do aluno: um ponto com duas ondas de transmissão.
    // O traçado abaixo reproduz o SVG de index.html, num sistema de 24x24.
    let simbolo = NSBezierPath()

    simbolo.appendOval(in: NSRect(x: 10, y: 10, width: 4, height: 4)) // circle cx=12 cy=12 r=2

    simbolo.move(to: NSPoint(x: 16.2, y: 7.8))
    simbolo.curve(
        to: NSPoint(x: 16.2, y: 16.3),
        controlPoint1: NSPoint(x: 18.5, y: 10.1),
        controlPoint2: NSPoint(x: 18.5, y: 13.9)
    )

    simbolo.move(to: NSPoint(x: 19.1, y: 4.9))
    simbolo.curve(
        to: NSPoint(x: 19.1, y: 19.1),
        controlPoint1: NSPoint(x: 23.0, y: 8.8),
        controlPoint2: NSPoint(x: 23.0, y: 15.2)
    )

    simbolo.lineWidth = 2
    simbolo.lineCapStyle = .round

    // O desenho não é simétrico (as ondas só existem à direita), então centralizamos
    // pelos limites reais do traçado em vez de pela caixa de 24x24.
    let limites = simbolo.bounds.insetBy(dx: -1, dy: -1) // inclui a espessura do traço
    let alvo = corpo.insetBy(dx: corpo.width * 0.20, dy: corpo.height * 0.20)
    let escala = min(alvo.width / limites.width, alvo.height / limites.height)

    let transformacao = NSAffineTransform()
    transformacao.translateX(
        by: alvo.midX - (limites.midX * escala),
        yBy: alvo.midY - (limites.midY * escala)
    )
    transformacao.scaleX(by: escala, yBy: escala)
    transformacao.concat()

    NSColor.white.setStroke()
    simbolo.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

if destino == "--web" {
    let pasta = URL(fileURLWithPath: argumentos.count > 2 ? argumentos[2] : ".")
    let arquivos: [(nome: String, tamanho: Int, canto: CGFloat)] = [
        ("favicon-32.png", 32, 0.2237),
        ("favicon-192.png", 192, 0.2237),
        ("apple-touch-icon.png", 180, 0)
    ]
    for arquivo in arquivos {
        guard let png = desenhar(tamanho: arquivo.tamanho, margemRelativa: 0, cantoRelativo: arquivo.canto) else {
            FileHandle.standardError.write(Data("falha ao desenhar \(arquivo.nome)\n".utf8))
            exit(1)
        }
        try png.write(to: pasta.appendingPathComponent(arquivo.nome))
        print("gerado: \(arquivo.nome)")
    }
    exit(0)
}

let pastaTemporaria = FileManager.default.temporaryDirectory
    .appendingPathComponent("AulaCast-\(UUID().uuidString).iconset")
try? FileManager.default.createDirectory(at: pastaTemporaria, withIntermediateDirectories: true)

// Nomes exigidos pelo iconutil.
let variantes: [(nome: String, tamanho: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for variante in variantes {
    guard let png = desenhar(tamanho: variante.tamanho) else {
        FileHandle.standardError.write(Data("falha ao desenhar \(variante.nome)\n".utf8))
        exit(1)
    }
    try? png.write(to: pastaTemporaria.appendingPathComponent("\(variante.nome).png"))
}

let processo = Process()
processo.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
processo.arguments = ["-c", "icns", pastaTemporaria.path, "-o", destino]
try processo.run()
processo.waitUntilExit()

try? FileManager.default.removeItem(at: pastaTemporaria)

if processo.terminationStatus == 0 {
    print("ícone gerado: \(destino)")
} else {
    FileHandle.standardError.write(Data("iconutil falhou\n".utf8))
    exit(1)
}
