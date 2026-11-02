"""Gera windows/painel.ico (Gyarados vermelho) a partir de windows/icone/gyarados.png.

O branco que toca a borda da imagem vira transparente (o branco de dentro do contorno, como o
brilho dos olhos, fica). Ampliações usam vizinho mais próximo para manter o pixel art nítido;
os outros tamanhos são ampliados 4x assim e depois reduzidos com Lanczos.

Também regrava a constante $IconePainel do windows/Painel.ps1.

Uso: python3 tools/gerar_icone.py
"""
import base64
import io
import re
import struct
from collections import deque
from pathlib import Path

from PIL import Image

RAIZ = Path(__file__).resolve().parent.parent
ORIGEM = RAIZ / 'windows' / 'icone' / 'gyarados.png'
SEM_FUNDO = RAIZ / 'windows' / 'icone' / 'gyarados-sem-fundo.png'
DESTINO = RAIZ / 'windows' / 'painel.ico'
PAINEL = RAIZ / 'windows' / 'Painel.ps1'
TAMANHOS = (16, 20, 24, 32, 40, 48, 64, 96, 128, 256)


def tirar_fundo(im):
    im = im.convert('RGBA')
    w, h = im.size
    px = im.load()
    branco = lambda p: p[0] >= 240 and p[1] >= 240 and p[2] >= 240
    fila = deque((x, y) for x in range(w) for y in (0, h - 1))
    fila.extend((x, y) for y in range(h) for x in (0, w - 1))
    visto = set()
    while fila:
        x, y = fila.popleft()
        if (x, y) in visto or not (0 <= x < w and 0 <= y < h):
            continue
        visto.add((x, y))
        if not branco(px[x, y]):
            continue
        px[x, y] = (0, 0, 0, 0)
        fila.extend(((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)))
    return im.crop(im.getbbox())


def quadro(sprite, lado):
    w, h = sprite.size
    escala = lado / max(w, h)
    n = int(escala)
    if n >= 1 and n / escala >= 0.85:
        # fator inteiro: pixels continuam quadrados e nítidos
        img = sprite.resize((w * n, h * n), Image.NEAREST)
    else:
        # amplia 4x sem suavizar e só então reduz, para o contorno não borrar demais
        grande = sprite.resize((w * 4, h * 4), Image.NEAREST)
        img = grande.resize((max(1, round(w * escala)), max(1, round(h * escala))), Image.LANCZOS)
    tela = Image.new('RGBA', (lado, lado), (0, 0, 0, 0))
    tela.paste(img, ((lado - img.width) // 2, (lado - img.height) // 2), img)
    return tela


def quadro_bmp(img):
    # DIB clássico de 32 bits (BGRA de baixo para cima) + máscara AND de 1 bit, o formato que
    # qualquer Windows e o System.Drawing do .NET Framework leem com transparência.
    w, h = img.size
    px = img.load()
    cores = bytearray()
    mascara = bytearray()
    linha_mascara = ((w + 31) // 32) * 4
    for y in range(h - 1, -1, -1):
        bits = bytearray(linha_mascara)
        for x in range(w):
            r, g, b, a = px[x, y]
            cores += bytes((b, g, r, a))
            if a == 0:
                bits[x // 8] |= 0x80 >> (x % 8)
        mascara += bits
    cabecalho = struct.pack('<IiiHHIIiiII', 40, w, h * 2, 1, 32, 0, len(cores) + len(mascara), 0, 0, 0, 0)
    return cabecalho + bytes(cores) + bytes(mascara)


def quadro_png(img):
    saida = io.BytesIO()
    img.save(saida, format='PNG', optimize=True)
    return saida.getvalue()


def montar_ico(quadros):
    # Até 48 px em BMP (é o que a janela, a barra de tarefas e a bandeja usam); maiores em PNG,
    # como o Windows faz com os próprios ícones, para o arquivo embutido não crescer demais.
    dados = [quadro_bmp(q) if q.width <= 48 else quadro_png(q) for q in quadros]
    saida = bytearray(struct.pack('<HHH', 0, 1, len(quadros)))
    deslocamento = 6 + 16 * len(quadros)
    for q, d in zip(quadros, dados):
        lado = q.width if q.width < 256 else 0
        saida += struct.pack('<BBBBHHII', lado, lado, 0, 0, 1, 32, len(d), deslocamento)
        deslocamento += len(d)
    for d in dados:
        saida += d
    return bytes(saida)


def main():
    sprite = tirar_fundo(Image.open(ORIGEM))
    sprite.save(SEM_FUNDO)
    quadros = [quadro(sprite, t) for t in TAMANHOS]
    DESTINO.write_bytes(montar_ico(quadros))
    # O Painel.ps1 leva o mesmo .ico em base64 (o Atualizar só baixa esse arquivo).
    fonte = PAINEL.read_text(encoding='utf-8-sig')
    b64 = base64.b64encode(DESTINO.read_bytes()).decode()
    fonte, n = re.subn(r"^\$IconePainel = '[A-Za-z0-9+/=]*'$", lambda _: f"$IconePainel = '{b64}'", fonte, flags=re.M)
    if n != 1:
        raise SystemExit('Painel.ps1 sem a linha $IconePainel')
    with open(PAINEL, 'w', encoding='utf-8-sig', newline='') as f:
        f.write(fonte)
    print(f'{DESTINO.relative_to(RAIZ)}: {DESTINO.stat().st_size} bytes, sprite {sprite.size}')


if __name__ == '__main__':
    main()
