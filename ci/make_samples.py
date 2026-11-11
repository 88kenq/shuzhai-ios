"""產生 CI 截圖用的範例書：一本簡體 TXT（測試切目錄與簡轉繁）、一本 EPUB（測試封面、粗斜體、插圖）。"""
import os, sys, zlib, struct, zipfile

out = sys.argv[1]
os.makedirs(out, exist_ok=True)

body = ("他走进房间，看见桌上放着一封信。“这是我们的事情，你不用管。”她说着，把头发拢到耳后，"
        "转身望向窗外。软件公司的信息部门今晚灯火通明，大家都在等一个消息。") * 6
chapters = ["第一章 初见", "第二章 重逢", "第三章 远行", "第四章 归来", "第五章 终局"]
txt = "贞观憨婿\n作者：大眼小金鱼\n\n简介：这是一段示范用的简介文字。\n\n"
for i, c in enumerate(chapters):
    txt += c + "\n" + "\n".join(["　　" + body] * (4 + i)) + "\n\n"
open(os.path.join(out, "a-示范小说.txt"), "w", encoding="utf-8").write(txt)

def png(w, h, rgb):
    raw = b"".join(b"\x00" + bytes(rgb) * w for _ in range(h))
    def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")

with zipfile.ZipFile(os.path.join(out, "b-範例電子書.epub"), "w") as z:
    z.writestr("mimetype", "application/epub+zip")
    z.writestr("META-INF/container.xml", '<?xml version="1.0"?><container><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>')
    z.writestr("OEBPS/content.opf", '<?xml version="1.0"?><package><metadata><dc:title>春江花月夜</dc:title><dc:creator>張若虛</dc:creator><meta name="cover" content="cov"/></metadata>'
               '<manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="cov" href="cover.png" media-type="image/png"/>'
               '<item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/><item id="pic" href="pic.png" media-type="image/png"/></manifest><spine><itemref idref="c1"/></spine></package>')
    z.writestr("OEBPS/nav.xhtml", '<html><body><nav epub:type="toc"><ol><li><a href="c1.xhtml">第一篇 春江</a></li></ol></nav></body></html>')
    z.writestr("OEBPS/cover.png", png(120, 160, (60, 90, 120)))
    z.writestr("OEBPS/pic.png", png(400, 220, (180, 140, 90)))
    p = "".join(f"<p>春江潮水連海平，<b>海上明月共潮生</b>。灩灩隨波千萬里，<i>何處春江無月明</i>。第 {i} 段。</p>" for i in range(1, 6))
    z.writestr("OEBPS/c1.xhtml", f'<html><body><h1>第一篇 春江</h1>{p}<div><img src="pic.png"/></div>{p}</body></html>')
print("samples:", os.listdir(out))
